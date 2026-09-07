// =====================================================================================
//  FinOps Multicloud extension for FinOps hubs (Azure + AWS + OCI)
//  ----------------------------------------------------------------------------------
//  O que este template faz (sempre no MESMO resource group do FinOps hub):
//   1. Cria um Key Vault (RBAC) para guardar as credenciais de AWS e OCI.
//   2. Adiciona ao Data Factory do hub (sem tocar nas pipelines nativas) os objetos
//      com prefixo "mc_" que copiam o export FOCUS da AWS (S3) para o container
//      "ingestion" do hub, seguindo a convencao Costs/yyyy/mm/aws/{payer} e o
//      padrao de nome {ingestionId}__{arquivo}.parquet + manifest.json.
//   3. Cria uma Function App (Flex Consumption, Python) que le os FOCUS reports da OCI,
//      converte para parquet tipado e grava em Costs/yyyy/mm/oci/{tenancy}.
//   4. Concede as permissoes minimas (RBAC) as identidades gerenciadas.
//  Nada aqui altera o template oficial do FinOps hub: a atualizacao do hub continua
//  sendo feita com Deploy-FinOpsHub / "Deploy to Azure".
// =====================================================================================

targetScope = 'resourceGroup'

@description('Nome do FinOps hub (o mesmo usado no Deploy-FinOpsHub). Usado para nomear os recursos.')
param hubName string = 'finops-hub'

@description('Regiao. Use a mesma do hub.')
param location string = resourceGroup().location

@description('Nome da storage account criada pelo FinOps hub (saida storageAccountName do deployment do hub).')
param hubStorageAccountName string

@description('Nome do Data Factory criado pelo FinOps hub (saida dataFactoryName).')
param hubDataFactoryName string

@description('Tags aplicadas a todos os recursos.')
param tags object = {}

// ---------------------------------------------------------------- AWS ----------------
@description('Habilita a ingestao de AWS (Data Exports FOCUS).')
param awsEnabled bool = true

@description('Bucket S3 que recebe o Data Export FOCUS.')
param awsBucketName string = ''

@description('Prefixo S3 configurado no Data Export (sem barra no final).')
param awsS3Prefix string = 'focus'

@description('Nome do Data Export FOCUS na AWS.')
param awsExportName string = 'finops-focus-1-0'

@description('ID da conta pagadora (payer). Vira o nome da pasta do escopo: aws/{payer}.')
param awsPayerAccountId string = ''

@description('Regiao do bucket S3 (ex.: us-east-1). Usada apenas para o endpoint do conector.')
param awsRegion string = 'us-east-1'

@secure()
@description('Access key ID do usuario IAM somente leitura no bucket.')
param awsAccessKeyId string = ''

@secure()
@description('Secret access key do usuario IAM somente leitura no bucket.')
param awsSecretAccessKey string = ''

@description('Quantos meses anteriores reprocessar a cada execucao diaria (1 = mes atual + mes anterior).')
param awsMonthsBack int = 1

@description('Habilita a pipeline de recomendacoes do AWS Cost Optimization Hub (export separado).')
param awsRecommendationsEnabled bool = false

@description('Nome do Data Export da tabela COST_OPTIMIZATION_RECOMMENDATIONS.')
param awsRecommendationsExportName string = 'finops-coh-recommendations'

// ---------------------------------------------------------------- OCI ----------------
@description('Habilita a ingestao de OCI (FOCUS cost reports).')
param ociEnabled bool = true

@description('OCID da tenancy OCI.')
param ociTenancyOcid string = ''

@description('OCID do usuario OCI de leitura dos relatorios.')
param ociUserOcid string = ''

@description('Fingerprint da API key do usuario OCI.')
param ociFingerprint string = ''

@description('Regiao home da tenancy OCI (ex.: sa-saopaulo-1).')
param ociRegion string = 'sa-saopaulo-1'

@secure()
@description('Chave privada (PEM) da API key do usuario OCI. Cole o conteudo completo do arquivo .pem.')
param ociPrivateKeyPem string = ''

@description('Quantos meses anteriores reprocessar a cada execucao diaria.')
param ociMonthsBack int = 1

@description('Tambem ingerir recomendacoes do OCI Cloud Advisor (Optimizer) na pasta Recommendations.')
param ociRecommendationsEnabled bool = true

// ---------------------------------------------------------------- nomes --------------
var suffix = uniqueString(resourceGroup().id, hubName)
// nomes com regras estritas (Key Vault e storage: 3 a 24 caracteres, so alfanumericos): base do hub sem hifens/underscores
var hubAlnum = toLower(replace(replace(hubName, '-', ''), '_', ''))
var keyVaultName = '${take(hubAlnum, 10)}mckv${take(suffix, 10)}'
var functionAppName = take(toLower(replace('${hubName}-mc-oci-${suffix}', '_', '-')), 60)
var planName = '${functionAppName}-plan'
var funcStorageName = '${take(hubAlnum, 9)}mcfn${take(suffix, 11)}'
var logName = '${functionAppName}-log'
var appInsightsName = '${functionAppName}-ai'
var hubIngestionContainer = 'ingestion'

// role definition ids (built-in)
var roleKeyVaultSecretsUser = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var roleStorageBlobDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var roleStorageBlobDataOwner = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var roleStorageQueueDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var roleStorageTableDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')

// ---------------------------------------------------------------- existentes ---------
resource hubStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: hubStorageAccountName
}

resource adf 'Microsoft.DataFactory/factories@2018-06-01' existing = {
  name: hubDataFactoryName
}

// ---------------------------------------------------------------- Key Vault ----------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 30
    publicNetworkAccess: 'Enabled'
  }
}

resource secretAwsKeyId 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (awsEnabled) {
  parent: kv
  name: 'aws-access-key-id'
  properties: { value: awsAccessKeyId }
}

resource secretAwsSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (awsEnabled) {
  parent: kv
  name: 'aws-secret-access-key'
  properties: { value: awsSecretAccessKey }
}

resource secretOciKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (ociEnabled) {
  parent: kv
  name: 'oci-private-key-pem'
  properties: { value: ociPrivateKeyPem }
}

// Data Factory (identidade do hub) pode ler segredos
resource kvRoleAdf 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, adf.id, 'kv-secrets-user')
  scope: kv
  properties: {
    roleDefinitionId: roleKeyVaultSecretsUser
    principalId: adf.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------- ADF: linked services
resource lsKeyVault 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = {
  parent: adf
  name: 'mc_KeyVault'
  properties: {
    type: 'AzureKeyVault'
    description: 'FinOps multicloud: segredos de AWS/OCI'
    typeProperties: {
      baseUrl: kv.properties.vaultUri
    }
  }
}

resource lsHubLake 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = {
  parent: adf
  name: 'mc_HubDataLake'
  properties: {
    type: 'AzureBlobFS'
    description: 'FinOps multicloud: storage do hub (identidade gerenciada do Data Factory)'
    typeProperties: {
      url: hubStorage.properties.primaryEndpoints.dfs
    }
  }
}

resource lsAwsS3 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = if (awsEnabled) {
  parent: adf
  name: 'mc_AwsS3'
  properties: {
    type: 'AmazonS3'
    description: 'FinOps multicloud: bucket S3 com o Data Export FOCUS'
    typeProperties: {
      authenticationType: 'AccessKey'
      serviceUrl: 'https://s3.${awsRegion}.amazonaws.com'
      accessKeyId: {
        type: 'AzureKeyVaultSecret'
        store: { referenceName: lsKeyVault.name, type: 'LinkedServiceReference' }
        secretName: 'aws-access-key-id'
      }
      secretAccessKey: {
        type: 'AzureKeyVaultSecret'
        store: { referenceName: lsKeyVault.name, type: 'LinkedServiceReference' }
        secretName: 'aws-secret-access-key'
      }
    }
  }
  dependsOn: [ secretAwsKeyId, secretAwsSecret, kvRoleAdf ]
}

// ---------------------------------------------------------------- ADF: datasets ------
resource dsHubLakeBinary 'Microsoft.DataFactory/factories/datasets@2018-06-01' = {
  parent: adf
  name: 'mc_HubLake_Binary'
  properties: {
    type: 'Binary'
    linkedServiceName: { referenceName: lsHubLake.name, type: 'LinkedServiceReference' }
    parameters: {
      container: { type: 'string', defaultValue: hubIngestionContainer }
      folderPath: { type: 'string', defaultValue: '' }
      fileName: { type: 'string', defaultValue: '' }
    }
    typeProperties: {
      location: {
        type: 'AzureBlobFSLocation'
        fileSystem: { value: '@dataset().container', type: 'Expression' }
        folderPath: { value: '@dataset().folderPath', type: 'Expression' }
        fileName: { value: '@dataset().fileName', type: 'Expression' }
      }
    }
  }
}

resource dsAwsBinary 'Microsoft.DataFactory/factories/datasets@2018-06-01' = if (awsEnabled) {
  parent: adf
  name: 'mc_AwsS3_Binary'
  properties: {
    type: 'Binary'
    linkedServiceName: { referenceName: 'mc_AwsS3', type: 'LinkedServiceReference' }
    parameters: {
      folderPath: { type: 'string', defaultValue: '' }
      fileName: { type: 'string', defaultValue: '' }
    }
    typeProperties: {
      location: {
        type: 'AmazonS3Location'
        bucketName: awsBucketName
        folderPath: { value: '@dataset().folderPath', type: 'Expression' }
        fileName: { value: '@dataset().fileName', type: 'Expression' }
      }
    }
  }
  dependsOn: [ lsAwsS3 ]
}

resource dsAwsParquet 'Microsoft.DataFactory/factories/datasets@2018-06-01' = if (awsEnabled && awsRecommendationsEnabled) {
  parent: adf
  name: 'mc_AwsS3_Parquet'
  properties: {
    type: 'Parquet'
    linkedServiceName: { referenceName: 'mc_AwsS3', type: 'LinkedServiceReference' }
    parameters: {
      folderPath: { type: 'string', defaultValue: '' }
    }
    typeProperties: {
      location: {
        type: 'AmazonS3Location'
        bucketName: awsBucketName
        folderPath: { value: '@dataset().folderPath', type: 'Expression' }
      }
      compressionCodec: 'snappy'
    }
  }
  dependsOn: [ lsAwsS3 ]
}

resource dsHubLakeParquet 'Microsoft.DataFactory/factories/datasets@2018-06-01' = if (awsEnabled && awsRecommendationsEnabled) {
  parent: adf
  name: 'mc_HubLake_Parquet'
  properties: {
    type: 'Parquet'
    linkedServiceName: { referenceName: lsHubLake.name, type: 'LinkedServiceReference' }
    parameters: {
      folderPath: { type: 'string', defaultValue: '' }
      fileName: { type: 'string', defaultValue: '' }
    }
    typeProperties: {
      location: {
        type: 'AzureBlobFSLocation'
        fileSystem: hubIngestionContainer
        folderPath: { value: '@dataset().folderPath', type: 'Expression' }
        fileName: { value: '@dataset().fileName', type: 'Expression' }
      }
      compressionCodec: 'snappy'
    }
  }
}

// ---------------------------------------------------------------- ADF: pipelines -----
// Pipeline filha: ingere UM mes (billingPeriod = yyyy-MM) do export FOCUS da AWS.
resource plAwsMonth 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = if (awsEnabled) {
  parent: adf
  name: 'mc_aws_IngestFocusMonth'
  properties: {
    description: 'Copia os parquet do Data Export FOCUS (S3) de um mes para ingestion/Costs/yyyy/mm/aws/{payer}, substituindo a carga anterior e gravando o manifest.json.'
    folder: { name: 'Multicloud' }
    parameters: {
      billingPeriod: { type: 'string' }
      exportName: { type: 'string', defaultValue: awsExportName }
      s3Prefix: { type: 'string', defaultValue: awsS3Prefix }
      payerAccountId: { type: 'string', defaultValue: awsPayerAccountId }
    }
    variables: {
      ingestionId: { type: 'String' }
      targetFolder: { type: 'String' }
      sourceFolder: { type: 'String' }
    }
    activities: [
      {
        name: 'SetIngestionId'
        type: 'SetVariable'
        typeProperties: {
          variableName: 'ingestionId'
          value: { value: '@formatDateTime(utcNow(), \'yyyyMMddHHmmss\')', type: 'Expression' }
        }
      }
      {
        name: 'SetTargetFolder'
        type: 'SetVariable'
        dependsOn: [ { activity: 'SetIngestionId', dependencyConditions: [ 'Succeeded' ] } ]
        typeProperties: {
          variableName: 'targetFolder'
          value: { value: '@concat(\'Costs/\', substring(pipeline().parameters.billingPeriod, 0, 4), \'/\', substring(pipeline().parameters.billingPeriod, 5, 2), \'/aws/\', pipeline().parameters.payerAccountId)', type: 'Expression' }
        }
      }
      {
        name: 'SetSourceFolder'
        type: 'SetVariable'
        dependsOn: [ { activity: 'SetTargetFolder', dependencyConditions: [ 'Succeeded' ] } ]
        typeProperties: {
          variableName: 'sourceFolder'
          value: { value: '@concat(pipeline().parameters.s3Prefix, \'/\', pipeline().parameters.exportName, \'/data/BILLING_PERIOD=\', pipeline().parameters.billingPeriod)', type: 'Expression' }
        }
      }
      {
        name: 'TargetFolderExists'
        type: 'GetMetadata'
        dependsOn: [ { activity: 'SetSourceFolder', dependencyConditions: [ 'Succeeded' ] } ]
        policy: { timeout: '0.00:10:00', retry: 1, retryIntervalInSeconds: 30 }
        typeProperties: {
          dataset: {
            referenceName: 'mc_HubLake_Binary'
            type: 'DatasetReference'
            parameters: { container: hubIngestionContainer, folderPath: '@variables(\'targetFolder\')', fileName: '' }
          }
          fieldList: [ 'exists' ]
          storeSettings: { type: 'AzureBlobFSReadSettings', recursive: false }
        }
      }
      {
        name: 'IfTargetExists'
        type: 'IfCondition'
        dependsOn: [ { activity: 'TargetFolderExists', dependencyConditions: [ 'Succeeded' ] } ]
        typeProperties: {
          expression: { value: '@activity(\'TargetFolderExists\').output.exists', type: 'Expression' }
          ifTrueActivities: [
            {
              name: 'DeletePreviousParquet'
              type: 'Delete'
              policy: { timeout: '0.00:30:00', retry: 1, retryIntervalInSeconds: 30 }
              typeProperties: {
                dataset: {
                  referenceName: 'mc_HubLake_Binary'
                  type: 'DatasetReference'
                  parameters: { container: hubIngestionContainer, folderPath: '@variables(\'targetFolder\')', fileName: '' }
                }
                enableLogging: false
                storeSettings: { type: 'AzureBlobFSReadSettings', recursive: false, wildcardFileName: '*.parquet', enablePartitionDiscovery: false }
              }
            }
          ]
        }
      }
      {
        name: 'ListS3Files'
        type: 'GetMetadata'
        dependsOn: [ { activity: 'IfTargetExists', dependencyConditions: [ 'Succeeded' ] } ]
        policy: { timeout: '0.00:10:00', retry: 2, retryIntervalInSeconds: 60 }
        typeProperties: {
          dataset: {
            referenceName: 'mc_AwsS3_Binary'
            type: 'DatasetReference'
            parameters: { folderPath: '@variables(\'sourceFolder\')', fileName: '' }
          }
          fieldList: [ 'childItems' ]
          storeSettings: { type: 'AmazonS3ReadSettings', recursive: false }
        }
      }
      {
        name: 'FilterParquet'
        type: 'Filter'
        dependsOn: [ { activity: 'ListS3Files', dependencyConditions: [ 'Succeeded' ] } ]
        typeProperties: {
          items: { value: '@activity(\'ListS3Files\').output.childItems', type: 'Expression' }
          condition: { value: '@and(equals(item().type, \'File\'), endswith(item().name, \'.parquet\'))', type: 'Expression' }
        }
      }
      {
        name: 'CopyEachParquet'
        type: 'ForEach'
        dependsOn: [ { activity: 'FilterParquet', dependencyConditions: [ 'Succeeded' ] } ]
        typeProperties: {
          items: { value: '@activity(\'FilterParquet\').output.Value', type: 'Expression' }
          isSequential: false
          batchCount: 8
          activities: [
            {
              name: 'CopyParquet'
              type: 'Copy'
              policy: { timeout: '0.02:00:00', retry: 2, retryIntervalInSeconds: 60 }
              inputs: [
                {
                  referenceName: 'mc_AwsS3_Binary'
                  type: 'DatasetReference'
                  parameters: { folderPath: '@variables(\'sourceFolder\')', fileName: '@item().name' }
                }
              ]
              outputs: [
                {
                  referenceName: 'mc_HubLake_Binary'
                  type: 'DatasetReference'
                  parameters: {
                    container: hubIngestionContainer
                    folderPath: '@variables(\'targetFolder\')'
                    fileName: '@concat(variables(\'ingestionId\'), \'__\', item().name)'
                  }
                }
              ]
              typeProperties: {
                source: { type: 'BinarySource', storeSettings: { type: 'AmazonS3ReadSettings', recursive: false } }
                sink: { type: 'BinarySink', storeSettings: { type: 'AzureBlobFSWriteSettings' } }
              }
            }
          ]
        }
      }
      {
        name: 'WriteManifest'
        type: 'Copy'
        dependsOn: [ { activity: 'CopyEachParquet', dependencyConditions: [ 'Succeeded' ] } ]
        policy: { timeout: '0.00:10:00', retry: 2, retryIntervalInSeconds: 30 }
        inputs: [
          {
            referenceName: 'mc_HubLake_Binary'
            type: 'DatasetReference'
            parameters: { container: 'config', folderPath: 'multicloud', fileName: 'manifest.json' }
          }
        ]
        outputs: [
          {
            referenceName: 'mc_HubLake_Binary'
            type: 'DatasetReference'
            parameters: { container: hubIngestionContainer, folderPath: '@variables(\'targetFolder\')', fileName: 'manifest.json' }
          }
        ]
        typeProperties: {
          source: { type: 'BinarySource', storeSettings: { type: 'AzureBlobFSReadSettings', recursive: false } }
          sink: { type: 'BinarySink', storeSettings: { type: 'AzureBlobFSWriteSettings' } }
        }
      }
    ]
  }
  dependsOn: [ dsHubLakeBinary, dsAwsBinary ]
}

// Pipeline pai: mes atual + N meses anteriores (a AWS corrige o mes anterior por ate duas semanas).
resource plAws 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = if (awsEnabled) {
  parent: adf
  name: 'mc_aws_IngestFocus'
  properties: {
    description: 'Orquestra a ingestao do FOCUS da AWS para o mes atual e os meses anteriores configurados.'
    folder: { name: 'Multicloud' }
    parameters: {
      monthsBack: { type: 'int', defaultValue: awsMonthsBack }
    }
    activities: [
      {
        name: 'ForEachMonth'
        type: 'ForEach'
        typeProperties: {
          items: { value: '@range(0, add(pipeline().parameters.monthsBack, 1))', type: 'Expression' }
          isSequential: true
          activities: [
            {
              name: 'IngestMonth'
              type: 'ExecutePipeline'
              typeProperties: {
                pipeline: { referenceName: 'mc_aws_IngestFocusMonth', type: 'PipelineReference' }
                waitOnCompletion: true
                parameters: {
                  billingPeriod: { value: '@formatDateTime(addToTime(utcNow(), mul(-1, item()), \'Month\'), \'yyyy-MM\')', type: 'Expression' }
                }
              }
            }
          ]
        }
      }
    ]
  }
  dependsOn: [ plAwsMonth ]
}

// Pipeline opcional: recomendacoes do AWS Cost Optimization Hub -> ingestion/Recommendations/yyyy/mm/aws/{payer}
// Le apenas arquivos entregues nas ultimas 26 horas (o export de recomendacoes nao suporta overwrite,
// cada entrega cria uma pasta nova). Mapeia as colunas para o esquema Recommendations do hub.
resource plAwsRecs 'Microsoft.DataFactory/factories/pipelines@2018-06-01' = if (awsEnabled && awsRecommendationsEnabled) {
  parent: adf
  name: 'mc_aws_IngestRecommendations'
  properties: {
    description: 'Copia as recomendacoes do Cost Optimization Hub (Data Exports) para ingestion/Recommendations, alinhadas ao esquema do hub.'
    folder: { name: 'Multicloud' }
    parameters: {
      exportName: { type: 'string', defaultValue: awsRecommendationsExportName }
      s3Prefix: { type: 'string', defaultValue: awsS3Prefix }
      payerAccountId: { type: 'string', defaultValue: awsPayerAccountId }
    }
    variables: {
      ingestionId: { type: 'String' }
      targetFolder: { type: 'String' }
    }
    activities: [
      {
        name: 'SetIngestionId'
        type: 'SetVariable'
        typeProperties: { variableName: 'ingestionId', value: { value: '@formatDateTime(utcNow(), \'yyyyMMddHHmmss\')', type: 'Expression' } }
      }
      {
        name: 'SetTargetFolder'
        type: 'SetVariable'
        dependsOn: [ { activity: 'SetIngestionId', dependencyConditions: [ 'Succeeded' ] } ]
        typeProperties: { variableName: 'targetFolder', value: { value: '@concat(\'Recommendations/\', formatDateTime(utcNow(), \'yyyy/MM\'), \'/aws/\', pipeline().parameters.payerAccountId)', type: 'Expression' } }
      }
      {
        name: 'CopyRecommendations'
        type: 'Copy'
        dependsOn: [ { activity: 'SetTargetFolder', dependencyConditions: [ 'Succeeded' ] } ]
        policy: { timeout: '0.01:00:00', retry: 2, retryIntervalInSeconds: 60 }
        inputs: [
          {
            referenceName: 'mc_AwsS3_Parquet'
            type: 'DatasetReference'
            parameters: { folderPath: '@concat(pipeline().parameters.s3Prefix, \'/\', pipeline().parameters.exportName, \'/data\')' }
          }
        ]
        outputs: [
          {
            referenceName: 'mc_HubLake_Parquet'
            type: 'DatasetReference'
            parameters: { folderPath: '@variables(\'targetFolder\')', fileName: '@concat(variables(\'ingestionId\'), \'__aws-coh-recommendations.parquet\')' }
          }
        ]
        typeProperties: {
          source: {
            type: 'ParquetSource'
            storeSettings: {
              type: 'AmazonS3ReadSettings'
              recursive: true
              wildcardFolderPath: '*'
              wildcardFileName: '*.parquet'
              modifiedDatetimeStart: { value: '@addHours(utcNow(), -26)', type: 'Expression' }
            }
            additionalColumns: [
              { name: 'ProviderName', value: 'AWS' }
              { name: 'x_SourceName', value: 'AWS Cost Optimization Hub' }
              { name: 'x_SourceProvider', value: 'AWS' }
              { name: 'x_SourceType', value: 'CostOptimizationRecommendations' }
              { name: 'x_SourceVersion', value: 'DataExports' }
            ]
          }
          sink: { type: 'ParquetSink', storeSettings: { type: 'AzureBlobFSWriteSettings', copyBehavior: 'MergeFiles' }, formatSettings: { type: 'ParquetWriteSettings' } }
          enableStaging: false
          translator: {
            type: 'TabularTranslator'
            typeConversion: true
            typeConversionSettings: { allowDataTruncation: true, treatBooleanAsNumber: false }
            mappings: [
              { source: { name: 'recommendation_id' }, sink: { name: 'x_RecommendationId' } }
              { source: { name: 'account_id' }, sink: { name: 'SubAccountId' } }
              { source: { name: 'resource_arn' }, sink: { name: 'ResourceId' } }
              { source: { name: 'resource_id' }, sink: { name: 'ResourceName' } }
              { source: { name: 'current_resource_type' }, sink: { name: 'ResourceType' } }
              { source: { name: 'action_type' }, sink: { name: 'x_RecommendationCategory' } }
              { source: { name: 'recommended_resource_summary' }, sink: { name: 'x_RecommendationDescription' } }
              { source: { name: 'estimated_monthly_savings_after_discount' }, sink: { name: 'x_EffectiveCostSavings', type: 'Double' } }
              { source: { name: 'estimated_monthly_cost_before_discount' }, sink: { name: 'x_EffectiveCostBefore', type: 'Double' } }
              { source: { name: 'estimated_monthly_cost_after_discount' }, sink: { name: 'x_EffectiveCostAfter', type: 'Double' } }
              { source: { name: 'last_refresh_timestamp' }, sink: { name: 'x_RecommendationDate', type: 'DateTime' } }
              { source: { name: 'ProviderName' }, sink: { name: 'ProviderName' } }
              { source: { name: 'x_SourceName' }, sink: { name: 'x_SourceName' } }
              { source: { name: 'x_SourceProvider' }, sink: { name: 'x_SourceProvider' } }
              { source: { name: 'x_SourceType' }, sink: { name: 'x_SourceType' } }
              { source: { name: 'x_SourceVersion' }, sink: { name: 'x_SourceVersion' } }
            ]
          }
        }
      }
      {
        name: 'WriteManifest'
        type: 'Copy'
        dependsOn: [ { activity: 'CopyRecommendations', dependencyConditions: [ 'Succeeded' ] } ]
        policy: { timeout: '0.00:10:00', retry: 2, retryIntervalInSeconds: 30 }
        inputs: [ { referenceName: 'mc_HubLake_Binary', type: 'DatasetReference', parameters: { container: 'config', folderPath: 'multicloud', fileName: 'manifest.json' } } ]
        outputs: [ { referenceName: 'mc_HubLake_Binary', type: 'DatasetReference', parameters: { container: hubIngestionContainer, folderPath: '@variables(\'targetFolder\')', fileName: 'manifest.json' } } ]
        typeProperties: {
          source: { type: 'BinarySource', storeSettings: { type: 'AzureBlobFSReadSettings', recursive: false } }
          sink: { type: 'BinarySink', storeSettings: { type: 'AzureBlobFSWriteSettings' } }
        }
      }
    ]
  }
  dependsOn: [ dsAwsParquet, dsHubLakeParquet, dsHubLakeBinary ]
}

// ---------------------------------------------------------------- ADF: triggers ------
// Os triggers sao criados parados. O script Deploy-FinOpsMulticloud.ps1 os inicia.
resource trAwsDaily 'Microsoft.DataFactory/factories/triggers@2018-06-01' = if (awsEnabled) {
  parent: adf
  name: 'mc_aws_DailySchedule'
  properties: {
    description: 'Roda a ingestao FOCUS da AWS todo dia as 07:00 UTC (o Data Export atualiza pelo menos uma vez por dia).'
    type: 'ScheduleTrigger'
    typeProperties: {
      recurrence: {
        frequency: 'Day'
        interval: 1
        startTime: '2026-01-01T07:00:00Z'
        timeZone: 'UTC'
        schedule: { hours: [ 7 ], minutes: [ 0 ] }
      }
    }
    pipelines: [
      {
        pipelineReference: { referenceName: 'mc_aws_IngestFocus', type: 'PipelineReference' }
        parameters: { monthsBack: awsMonthsBack }
      }
    ]
  }
  dependsOn: [ plAws ]
}

resource trAwsRecsDaily 'Microsoft.DataFactory/factories/triggers@2018-06-01' = if (awsEnabled && awsRecommendationsEnabled) {
  parent: adf
  name: 'mc_aws_RecommendationsDailySchedule'
  properties: {
    description: 'Roda a ingestao das recomendacoes do Cost Optimization Hub todo dia as 08:00 UTC.'
    type: 'ScheduleTrigger'
    typeProperties: {
      recurrence: {
        frequency: 'Day'
        interval: 1
        startTime: '2026-01-01T08:00:00Z'
        timeZone: 'UTC'
        schedule: { hours: [ 8 ], minutes: [ 0 ] }
      }
    }
    pipelines: [ { pipelineReference: { referenceName: 'mc_aws_IngestRecommendations', type: 'PipelineReference' } } ]
  }
  dependsOn: [ plAwsRecs ]
}

// ---------------------------------------------------------------- OCI: Function App --
resource logWs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (ociEnabled) {
  name: logName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (ociEnabled) {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logWs.id
    IngestionMode: 'LogAnalytics'
  }
}

resource funcStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (ociEnabled) {
  name: funcStorageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource funcStorageBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = if (ociEnabled) {
  parent: funcStorage
  name: 'default'
}

resource funcDeployContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = if (ociEnabled) {
  parent: funcStorageBlob
  name: 'app-package-oci-connector'
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = if (ociEnabled) {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  properties: { reserved: true }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = if (ociEnabled) {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${funcStorage.properties.primaryEndpoints.blob}app-package-oci-connector'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: 40, instanceMemoryMB: 2048 } // Flex Consumption exige minimo 40
      runtime: { name: 'python', version: '3.11' }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: funcStorage.name }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'HUB_STORAGE_ACCOUNT', value: hubStorageAccountName }
        { name: 'HUB_INGESTION_CONTAINER', value: hubIngestionContainer }
        { name: 'OCI_TENANCY_OCID', value: ociTenancyOcid }
        { name: 'OCI_USER_OCID', value: ociUserOcid }
        { name: 'OCI_FINGERPRINT', value: ociFingerprint }
        { name: 'OCI_REGION', value: ociRegion }
        { name: 'OCI_PRIVATE_KEY_PEM', value: '@Microsoft.KeyVault(VaultName=${kv.name};SecretName=oci-private-key-pem)' }
        { name: 'OCI_MONTHS_BACK', value: string(ociMonthsBack) }
        { name: 'OCI_RECOMMENDATIONS_ENABLED', value: ociRecommendationsEnabled ? 'true' : 'false' }
        { name: 'OCI_SCHEDULE', value: '0 30 6 * * *' }
      ]
    }
  }
  dependsOn: [ secretOciKey, funcDeployContainer ]
}

// Function -> storage proprio (identity-based AzureWebJobsStorage)
resource fnRoleBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (ociEnabled) {
  name: guid(funcStorage.id, functionAppName, 'blob-owner')
  scope: funcStorage
  properties: { roleDefinitionId: roleStorageBlobDataOwner, principalId: functionApp.identity.principalId, principalType: 'ServicePrincipal' }
}
resource fnRoleQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (ociEnabled) {
  name: guid(funcStorage.id, functionAppName, 'queue-contrib')
  scope: funcStorage
  properties: { roleDefinitionId: roleStorageQueueDataContributor, principalId: functionApp.identity.principalId, principalType: 'ServicePrincipal' }
}
resource fnRoleTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (ociEnabled) {
  name: guid(funcStorage.id, functionAppName, 'table-contrib')
  scope: funcStorage
  properties: { roleDefinitionId: roleStorageTableDataContributor, principalId: functionApp.identity.principalId, principalType: 'ServicePrincipal' }
}
// Function -> storage do hub (grava em ingestion/)
resource fnRoleHubStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (ociEnabled) {
  name: guid(hubStorage.id, functionAppName, 'hub-blob-contrib')
  scope: hubStorage
  properties: { roleDefinitionId: roleStorageBlobDataContributor, principalId: functionApp.identity.principalId, principalType: 'ServicePrincipal' }
}
// Function -> Key Vault (le a chave privada OCI via Key Vault reference)
resource fnRoleKv 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (ociEnabled) {
  name: guid(kv.id, functionAppName, 'kv-secrets-user')
  scope: kv
  properties: { roleDefinitionId: roleKeyVaultSecretsUser, principalId: functionApp.identity.principalId, principalType: 'ServicePrincipal' }
}

// ---------------------------------------------------------------- saidas -------------
output keyVaultName string = kv.name
output functionAppName string = ociEnabled ? functionApp.name : ''
output functionAppPrincipalId string = ociEnabled ? functionApp.identity.principalId : ''
output awsPipelineName string = awsEnabled ? 'mc_aws_IngestFocus' : ''
output awsTriggerName string = awsEnabled ? 'mc_aws_DailySchedule' : ''
output awsRecommendationsTriggerName string = (awsEnabled && awsRecommendationsEnabled) ? 'mc_aws_RecommendationsDailySchedule' : ''
