/*
  FinOps Multicloud, infraestrutura da interface web.

  Cria a aplicacao em App Service (padrao) ou em Azure Container Apps, com:
    - identidade gerenciada atribuida pelo sistema
    - papel Storage Blob Data Reader no storage do hub, concedido aqui mesmo
    - Application Insights e Log Analytics
    - HTTPS obrigatorio e TLS 1.2 no minimo

  Nao ha segredo em lugar nenhum: o acesso ao dado usa a identidade gerenciada.
*/

targetScope = 'resourceGroup'

@description('Prefixo dos nomes dos recursos.')
@minLength(3)
@maxLength(18)
param appName string = 'finops-web'

@description('Regiao dos recursos.')
param location string = resourceGroup().location

@description('Onde hospedar. AppService e o padrao: deploy por zip, sem Docker.')
@allowed(['AppService', 'ContainerApps'])
param hostingModel string = 'AppService'

@description('Nome da storage account do FinOps hub, de onde vem o dado.')
param hubStorageAccountName string

@description('Resource group do hub. Vazio usa o mesmo resource group desta implantacao.')
param hubResourceGroup string = ''

@description('SKU do plano do App Service. B1 e o menor que aceita Always On.')
@allowed(['B1', 'B2', 'B3', 'S1', 'S2', 'P0v3', 'P1v3'])
param appServiceSku string = 'B1'

@description('Imagem do container. Usado somente quando hostingModel = ContainerApps.')
param containerImage string = ''

@description('Servidor do Container Registry. Usado somente com ContainerApps.')
param containerRegistryServer string = ''

@description('Minimo de replicas no Container Apps. 0 permite escalar a zero, mas o agendador interno de alertas so roda com a app de pe; com 0, use um timer externo chamando POST /api/alertas/avaliar.')
@minValue(0)
@maxValue(10)
param minReplicas int = 0

@description('Maximo de replicas no Container Apps.')
@minValue(1)
@maxValue(30)
param maxReplicas int = 3

@description('Segundos que o dado fica em cache na memoria da aplicacao.')
param cacheTtlSeconds int = 1800

@description('E-mails que recebem os alertas quando a regra nao define destinatarios. Separados por virgula.')
param alertEmailTo string = ''

@description('Cria Azure Communication Services com dominio gerenciado para enviar e-mail de alerta, sem segredo.')
param enableEmail bool = false

@description('Localizacao dos dados do Communication Services. Ex.: Brazil, United States, Europe.')
param emailDataLocation string = 'United States'

@description('Hora local (0 a 23) em que os alertas sao reavaliados todo dia.')
@minValue(0)
@maxValue(23)
param alertHour int = 9

@description('Deslocamento do fuso em horas em relacao ao UTC. Brasil: -3.')
param utcOffsetHours int = -3

@description('De onde a aplicacao le o dado. storage = parquet do hub (nivel 0). kusto = Eventhouse do Fabric ou Data Explorer (nivel 1).')
@allowed(['storage', 'kusto'])
param dataBackend string = 'storage'

@description('Query URI do Eventhouse ou do cluster Data Explorer. Usado somente com dataBackend = kusto.')
param kustoQueryUri string = ''

@description('Banco de dados do hub no Kusto.')
param kustoDatabase string = 'Hub'

@description('Funcao KQL a consultar. Costs() segue a versao mais nova; Costs_v1_2() fixa a versao.')
param kustoFunction string = 'Costs()'

@description('Quantos meses a consulta Kusto traz para a memoria.')
param kustoMonths int = 13

@description('Tags aplicadas a todos os recursos.')
param tags object = {}

var sufixo = uniqueString(resourceGroup().id, appName)
var nomeCurto = take(replace(toLower(appName), '_', '-'), 18)
var rgHub = empty(hubResourceGroup) ? resourceGroup().name : hubResourceGroup

var nomeLogAnalytics = '${nomeCurto}-logs-${sufixo}'
var nomeAppInsights = '${nomeCurto}-insights-${sufixo}'
var nomePlano = '${nomeCurto}-plan-${sufixo}'
var nomeSite = '${nomeCurto}-${sufixo}'
var nomeAmbienteAca = '${nomeCurto}-env-${sufixo}'
// Registry para o caminho Container Apps: so letras e numeros, 5 a 50 caracteres.
var nomeRegistry = take('finopsacr${uniqueString(resourceGroup().id, appName)}', 50)
var papelAcrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

var ehAppService = hostingModel == 'AppService'

// Familia (tier) do SKU, explicita para o provedor nao precisar inferir. Cada familia tem cota propria na
// assinatura: quando B1 (Basic) esta com cota zero, P0v3 (PremiumV3) costuma estar liberado.
var skuMin = toLower(appServiceSku)
var tierSku = startsWith(skuMin, 'f') ? 'Free' : (startsWith(skuMin, 'b') ? 'Basic' : (startsWith(skuMin, 's') ? 'Standard' : (endsWith(skuMin, 'v4') ? 'PremiumV4' : (endsWith(skuMin, 'v2') ? 'PremiumV2' : 'PremiumV3'))))
var ehFree = startsWith(skuMin, 'f')

// Storage de ESTADO da aplicacao: centros de custo, orcamentos, regras e alertas, em Table Storage.
// Separada da storage do hub de proposito: o hub e dado; isto e configuracao da interface.
var nomeStorageEstado = take('finopsweb${uniqueString(resourceGroup().id, appName, 'state')}', 24)
var papelStorageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var nomeEmailService = '${nomeCurto}-email-${sufixo}'
var nomeAcs = '${nomeCurto}-acs-${sufixo}'

// Papel de plano de dados. Ler o conteudo do blob NAO vem de Owner nem de Contributor,
// precisa desta atribuicao explicita. E a mesma pegadinha que afeta o Power BI.
var papelStorageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

// A aplicacao le sempre pelo endpoint DFS e sempre no container ingestion.
var urlStorageHub = 'https://${hubStorageAccountName}.dfs.${environment().suffixes.storage}'

// ---------------------------------------------------------------- observabilidade
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: nomeLogAnalytics
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: nomeAppInsights
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// ---------------------------------------------------------------- estado da aplicacao
resource storageEstado 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: nomeStorageEstado
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // so identidade gerenciada, nenhuma chave
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// ---------------------------------------------------------------- e-mail (opcional)
resource emailService 'Microsoft.Communication/emailServices@2023-04-01' = if (enableEmail) {
  name: nomeEmailService
  location: 'global'
  tags: tags
  properties: { dataLocation: emailDataLocation }
}

resource emailDomain 'Microsoft.Communication/emailServices/domains@2023-04-01' = if (enableEmail) {
  parent: emailService
  name: 'AzureManagedDomain'
  location: 'global'
  properties: { domainManagement: 'AzureManaged', userEngagementTracking: 'Disabled' }
}

resource acs 'Microsoft.Communication/communicationServices@2023-04-01' = if (enableEmail) {
  name: nomeAcs
  location: 'global'
  tags: tags
  properties: { dataLocation: emailDataLocation, linkedDomains: [emailDomain.id] }
}

var acsEndpoint = enableEmail ? 'https://${acs!.properties.hostName}' : ''
var emailSender = enableEmail ? 'DoNotReply@${emailDomain!.properties.mailFromSenderDomain}' : ''

// ---------------------------------------------------------------- App Service
resource plano 'Microsoft.Web/serverfarms@2023-12-01' = if (ehAppService) {
  name: nomePlano
  location: location
  tags: tags
  sku: {
    name: appServiceSku
    tier: tierSku
  }
  kind: 'linux'
  properties: {
    reserved: true // obrigatorio para Linux
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = if (ehAppService) {
  name: nomeSite
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plano.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      alwaysOn: !ehFree // Free nao tem Always On (o agendador de alertas so roda enquanto a app estiver acordada)
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      healthCheckPath: ehFree ? null : '/api/health' // health check nao existe no Free
      // Um unico processo uvicorn: o agendador de alertas roda dentro dele e nao pode duplicar, e um so
      // cache em memoria cabe folgado no B1. Os endpoints sao sincronos e o FastAPI os executa em um
      // pool de threads, entao varios usuarios ao mesmo tempo sao atendidos normalmente.
      appCommandLine: 'python -m uvicorn main:app --host 0.0.0.0 --port 8000 --app-dir api --timeout-keep-alive 75'
      appSettings: [
        { name: 'DATA_BACKEND', value: dataBackend }
        { name: 'HUB_STORAGE_ACCOUNT', value: hubStorageAccountName }
        { name: 'HUB_STORAGE_URL', value: urlStorageHub }
        { name: 'KUSTO_QUERY_URI', value: kustoQueryUri }
        { name: 'KUSTO_DATABASE', value: kustoDatabase }
        { name: 'KUSTO_FUNCTION', value: kustoFunction }
        { name: 'KUSTO_MONTHS', value: string(kustoMonths) }
        { name: 'MPLCONFIGDIR', value: '/tmp/matplotlib' }
        { name: 'CACHE_TTL_SECONDS', value: string(cacheTtlSeconds) }
        { name: 'STATE_STORAGE_ACCOUNT', value: storageEstado.name }
        { name: 'ALERT_EMAIL_TO', value: alertEmailTo }
        { name: 'ACS_ENDPOINT', value: acsEndpoint }
        { name: 'EMAIL_SENDER', value: emailSender }
        { name: 'ALERT_HOUR', value: string(alertHour) }
        { name: 'APP_UTC_OFFSET', value: string(utcOffsetHours) }
        { name: 'APP_URL', value: 'https://${nomeSite}.azurewebsites.net' }
        { name: 'LOG_LEVEL', value: 'INFO' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'ENABLE_ORYX_BUILD', value: 'true' }
        { name: 'WEBSITES_CONTAINER_START_TIME_LIMIT', value: '600' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
      ]
    }
  }
}

// ---------------------------------------------------------------- Container Apps
resource ambiente 'Microsoft.App/managedEnvironments@2024-03-01' = if (!ehAppService) {
  name: nomeAmbienteAca
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

// O registry guarda a imagem que o instalador constroi NA NUVEM (az acr build), sem Docker na maquina.
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = if (!ehAppService) {
  name: nomeRegistry
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false // pull por identidade gerenciada (AcrPull), nenhuma senha
    publicNetworkAccess: 'Enabled'
  }
}

// Na primeira execucao ainda nao existe imagem: a app sobe com uma imagem publica de espera e o
// instalador troca pela imagem construida na etapa 5. Por isso o registry so entra na configuracao
// quando containerImage vem preenchido (segunda passada ou -CodeOnly).
var servidorRegistry = empty(containerRegistryServer) ? (ehAppService ? '' : '${nomeRegistry}.azurecr.io') : containerRegistryServer

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = if (!ehAppService) {
  name: nomeSite
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: ambiente.id
    configuration: {
      ingress: {
        external: true
        // A imagem publica de espera escuta na 80; a imagem da interface, na 8000. O instalador ajusta
        // a porta ao trocar a imagem (az containerapp ingress update).
        targetPort: empty(containerImage) ? 80 : 8000
        transport: 'auto'
        allowInsecure: false
      }
      registries: empty(containerImage) ? [] : [
        {
          server: servidorRegistry
          identity: 'system'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'finops-web'
          image: empty(containerImage) ? 'mcr.microsoft.com/k8se/quickstart:latest' : containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'DATA_BACKEND', value: dataBackend }
            { name: 'HUB_STORAGE_ACCOUNT', value: hubStorageAccountName }
            { name: 'HUB_STORAGE_URL', value: urlStorageHub }
            { name: 'KUSTO_QUERY_URI', value: kustoQueryUri }
            { name: 'KUSTO_DATABASE', value: kustoDatabase }
            { name: 'KUSTO_FUNCTION', value: kustoFunction }
            { name: 'KUSTO_MONTHS', value: string(kustoMonths) }
            { name: 'CACHE_TTL_SECONDS', value: string(cacheTtlSeconds) }
            { name: 'STATE_STORAGE_ACCOUNT', value: storageEstado.name }
            { name: 'ALERT_EMAIL_TO', value: alertEmailTo }
            { name: 'ACS_ENDPOINT', value: acsEndpoint }
            { name: 'EMAIL_SENDER', value: emailSender }
            { name: 'ALERT_HOUR', value: string(alertHour) }
            { name: 'APP_UTC_OFFSET', value: string(utcOffsetHours) }
            { name: 'LOG_LEVEL', value: 'INFO' }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
            { name: 'MPLCONFIGDIR', value: '/tmp/matplotlib' }
          ]
          probes: empty(containerImage) ? [] : [
            {
              type: 'Readiness'
              httpGet: { path: '/api/health', port: 8000 }
              initialDelaySeconds: 8
              periodSeconds: 12
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http'
            http: { metadata: { concurrentRequests: '20' } }
          }
        ]
      }
    }
  }
}

// ---------------------------------------------------------------- permissao no hub
// Concedida por modulo porque a storage do hub pode estar em outro resource group.
module papelNoStorage 'storage-role.bicep' = {
  name: 'papel-storage-${sufixo}'
  scope: resourceGroup(rgHub)
  params: {
    storageAccountName: hubStorageAccountName
    principalId: ehAppService ? site!.identity.principalId : containerApp!.identity.principalId
    roleDefinitionId: papelStorageBlobDataReader
  }
}

var principalApp = ehAppService ? site!.identity.principalId : containerApp!.identity.principalId

// O nome de um role assignment precisa ser calculavel no INICIO do deploy (BCP120), e o principalId
// da identidade so existe depois de a app ser criada. Por isso o GUID deriva do nome da app, que e
// deterministico; o principalId entra so na propriedade. Rodar de novo reaproveita a mesma atribuicao.
resource papelEstado 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageEstado.id, nomeSite, papelStorageTableDataContributor)
  scope: storageEstado
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', papelStorageTableDataContributor)
    principalId: principalApp
    principalType: 'ServicePrincipal'
  }
}

// Enviar e-mail por identidade gerenciada exige permissao de escrita no recurso do ACS.
// Escopo restrito ao proprio recurso, nao ao resource group.
resource papelAcs 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableEmail) {
  name: guid(resourceGroup().id, nomeAcs, nomeSite, 'contributor')
  scope: acs
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: principalApp
    principalType: 'ServicePrincipal'
  }
}

resource papelAcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!ehAppService) {
  name: guid(resourceGroup().id, nomeRegistry, nomeSite, 'acrpull')
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', papelAcrPull)
    principalId: principalApp
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------- saidas
output appUrl string = ehAppService ? 'https://${site!.properties.defaultHostName}' : 'https://${containerApp!.properties.configuration.ingress.fqdn}'
output appName string = nomeSite
output principalId string = ehAppService ? site!.identity.principalId : containerApp!.identity.principalId
output hostingModel string = hostingModel
output appInsightsName string = insights.name
output storageUrl string = urlStorageHub
output stateStorageAccount string = storageEstado.name
output dataBackend string = dataBackend
output registryName string = ehAppService ? '' : nomeRegistry
output registryServer string = ehAppService ? '' : '${nomeRegistry}.azurecr.io'
output emailEnabled bool = enableEmail
output emailSender string = emailSender
output acsEndpoint string = acsEndpoint
