/*
  Concede um papel de plano de dados na storage do hub para a identidade da aplicacao.

  Existe como modulo separado porque a storage do FinOps hub costuma estar em outro
  resource group, e atribuicao de papel precisa ser feita no escopo do recurso alvo.

  Lembrete que vale repetir: Storage Blob Data Reader NAO e herdado de Owner nem de
  Contributor. Sem esta atribuicao a aplicacao recebe 403 ao tentar ler o parquet, e o
  mesmo vale para o Power BI e para voce no Storage browser.
*/

@description('Nome da storage account do hub.')
param storageAccountName string

@description('Object id da identidade gerenciada que vai ler o dado.')
param principalId string

@description('Id da definicao do papel. Padrao: Storage Blob Data Reader.')
param roleDefinitionId string = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource atribuicao 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, principalId, roleDefinitionId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output roleAssignmentId string = atribuicao.id
