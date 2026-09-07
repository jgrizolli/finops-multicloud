# Apêndice A: todos os comandos em um lugar

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [18. Apêndice A: todos os comandos em um lugar](#18-apêndice-a-todos-os-comandos-em-um-lugar)

---

## 18. Apêndice A: todos os comandos em um lugar

Guarde esta seção. Ela funciona sem internet e cobre 95% do que você vai precisar no dia a dia.

Antes de tudo, defina as variáveis uma vez por sessão:

```powershell
$sub   = '<sub-id>'
$rg    = 'rg-finops-hub'
$sa    = '<storage-do-hub>'
$adf   = '<data-factory-do-hub>'
$scope = "/subscriptions/$sub"

Set-AzContext -Subscription $sub
$ctx = New-AzStorageContext -StorageAccountName $sa -UseConnectedAccount
```

### Instalar e reinstalar

```powershell
# instalacao completa
./Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json

# so a extensao multicloud, sem tocar no hub
./Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json -SkipHub

# so o Azure, sem AWS nem OCI
./Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json -SkipAws -SkipOci

# ver o que seria feito, sem alterar nada
./Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json -WhatIf

# alinhar a versao FOCUS dos exports com os relatorios Power BI storage
./Repair-FocusVersion.ps1 -SubscriptionId $sub -ResourceGroup $rg
```

### Descobrir os nomes dos recursos

```powershell
Get-AzResource -ResourceGroupName $rg | Select-Object Name, ResourceType

# a URL oficial para o Power BI
Get-AzResourceGroupDeployment -ResourceGroupName $rg |
  Where-Object { $_.Outputs.Keys -contains 'storageUrlForPowerBI' } |
  Sort-Object Timestamp -Descending | Select-Object -First 1 -ExpandProperty Outputs |
  ForEach-Object { $_['storageUrlForPowerBI'].Value }

# o object id da identidade do Data Factory
(Get-AzDataFactoryV2 -ResourceGroupName $rg -Name $adf).Identity.PrincipalId
```

### Exports

```powershell
# listar
Get-FinOpsCostExport -Scope $scope | Select-Object Name, Dataset, DatasetVersion, ScheduleFrequency

# executar agora, com historico
Start-FinOpsCostExport -Name '<nome>' -Scope $scope -Backfill 12

# remover
Remove-FinOpsCostExport -Name '<nome>' -Scope $scope

# criar manualmente em FOCUS 1.0r2 (o que o Power BI storage espera)
New-FinOpsCostExport -Name 'ftk-focuscost' -Scope $scope `
  -Dataset FocusCost -DatasetVersion '1.0r2' `
  -StorageAccountId (Get-AzStorageAccount -ResourceGroupName $rg -Name $sa).Id `
  -StorageContainer 'msexports' -StoragePath $scope.Trim('/') `
  -DoNotOverwrite -Backfill 12 -Execute
```

### Desligar, apagar e reinstalar

```powershell
# desligar / ligar / estado (webapp/)
./webapp/Set-FinOpsPower.ps1 -Action Status -ResourceGroup $rg
./webapp/Set-FinOpsPower.ps1 -Action Stop   -ResourceGroup $rg            # Light: para a interface, volta em segundos
./webapp/Set-FinOpsPower.ps1 -Action Stop   -ResourceGroup $rg -Level Deep # apaga app, ambiente e registry; sobra o hub
./webapp/Set-FinOpsPower.ps1 -Action Start  -ResourceGroup $rg

# apagar (deploy/): ver antes, depois apagar; -KeepHubStorage guarda o historico; -Scope Web ou Hub para parcial
./deploy/Remove-FinOpsEnvironment.ps1 -SubscriptionId $sub -ResourceGroup $rg -Scope All -WhatIf
./deploy/Remove-FinOpsEnvironment.ps1 -SubscriptionId $sub -ResourceGroup $rg -Scope All

# reinstalar, na ordem
./deploy/Deploy-FinOpsMulticloud.ps1 -ParametersFile ./deploy/parameters.json
./webapp/Deploy-FinOpsWebApp.ps1 -SubscriptionId $sub -ResourceGroup $rg -EnableAuth -EnableEmail -AlertEmailTo finops@empresa.com -Location eastus2 -HostingModel ContainerApps
./webapp/Set-FinOpsWebAuth.ps1 -ResourceGroup $rg -HostingModel ContainerApps   # so se o login nao ficou ativo
```

### Interface web (opção B)

```powershell
# ver a interface sem instalar NADA: abra webapp/FinOps-Preview.html com duplo clique
python webapp/build_preview.py                      # regerar a previa

# rodar na sua maquina com dado REAL
./webapp/Deploy-FinOpsWebApp.ps1 -RunLocal -HubStorageAccount $sa

# instalar (recomendado: login do tenant + e-mail de alertas)
./webapp/Deploy-FinOpsWebApp.ps1 -SubscriptionId $sub -ResourceGroup $rg -EnableAuth -EnableEmail -AlertEmailTo finops@empresa.com

# republicar so o codigo
./webapp/Deploy-FinOpsWebApp.ps1 -SubscriptionId $sub -ResourceGroup $rg -CodeOnly

# ler do Fabric (Eventhouse) ou do Data Explorer em vez do parquet (nivel 1)
./webapp/Deploy-FinOpsWebApp.ps1 -SubscriptionId $sub -ResourceGroup $rg -EnableAuth `
    -DataBackend Kusto -KustoQueryUri https://<eventhouse>.z0.kusto.fabric.microsoft.com -KustoDatabase Hub
# e, na janela de consulta do banco Hub (o instalador imprime o comando pronto):
#   .add database Hub viewers ('aadapp=<principalId-da-aplicacao>;<tenantId>')

# testar toda a logica sem Azure
python webapp/api/test_local.py

# operacao
./webapp/Diagnose-FinOpsWebApp.ps1 -ResourceGroup $rg -HostingModel ContainerApps   # a URL nao abre? veredito + comando
az webapp log tail -g $rg -n <nome-da-app>
az containerapp logs show -g $rg -n <nome-da-app> --type system --tail 50          # Container Apps: pull da imagem, replicas
az containerapp logs show -g $rg -n <nome-da-app> --type console --tail 50         # Container Apps: a aplicacao em si
az containerapp revision list -g $rg -n <nome-da-app> -o table                     # revisoes, saude, replicas
curl https://<url>/api/status
curl -X POST https://<url>/api/alertas/avaliar
curl -X POST https://<url>/api/centros-custo/importar?formato=csv --data-binary @centros.csv
```

### Retenção

```powershell
# ver a configuracao atual
./Set-FinOpsRetention.ps1 -SubscriptionId $sub -ResourceGroup $rg -Show

# guardar 24 meses de parquet e de tabelas finais
./Set-FinOpsRetention.ps1 -SubscriptionId $sub -ResourceGroup $rg -IngestionMonths 24 -FinalMonths 24

# guardar o arquivo bruto por 7 dias (para depurar uma carga)
./Set-FinOpsRetention.ps1 -SubscriptionId $sub -ResourceGroup $rg -MsExportsDays 7

# apagar de verdade o parquet antigo (o hub sozinho nao apaga)
./Set-FinOpsRetention.ps1 -SubscriptionId $sub -ResourceGroup $rg -IngestionMonths 24 -ApplyStorageLifecycle

# remover a regra de ciclo de vida
./Set-FinOpsRetention.ps1 -SubscriptionId $sub -ResourceGroup $rg -RemoveStorageLifecycle

# ler o settings.json na mao
Get-AzStorageBlobContent -Container config -Blob 'settings.json' -Context $ctx -Destination .\settings.json -Force
Get-Content .\settings.json -Raw
```

### Verificar o dado

```powershell
# parquet no ingestion, com tamanho e data
Get-AzStorageBlob -Container ingestion -Context $ctx -Blob "Costs/*" |
  Where-Object { $_.Name -like "*.parquet" } |
  Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}, LastModified |
  Format-Table -AutoSize

# quantos meses existem
Get-AzStorageBlob -Container ingestion -Context $ctx -Blob "Costs/*" |
  Where-Object { $_.Name -like "*.parquet" } |
  ForEach-Object { ($_.Name -split '/')[1..2] -join '-' } | Sort-Object -Unique

# a configuracao do hub
Get-AzStorageBlobContent -Container config -Blob 'settings.json' -Context $ctx -Destination .\settings.json -Force
Get-Content .\settings.json -Raw
```

### Data Factory

```powershell
# triggers (todos devem estar Started)
Get-AzDataFactoryV2Trigger -ResourceGroupName $rg -DataFactoryName $adf | Select-Object Name, RuntimeState

# ligar os que estiverem parados
Get-AzDataFactoryV2Trigger -ResourceGroupName $rg -DataFactoryName $adf |
  Where-Object { $_.RuntimeState -ne 'Started' } |
  ForEach-Object { Start-AzDataFactoryV2Trigger -ResourceGroupName $rg -DataFactoryName $adf -Name $_.Name -Force }

# execucoes recentes
Get-AzDataFactoryV2PipelineRun -ResourceGroupName $rg -DataFactoryName $adf `
  -LastUpdatedAfter (Get-Date).AddDays(-1) -LastUpdatedBefore (Get-Date).AddMinutes(10) |
  Sort-Object RunStart -Descending |
  Select-Object PipelineName, Status, RunStart, DurationInMs

# rodar uma pipeline na mao
Invoke-AzDataFactoryV2Pipeline -ResourceGroupName $rg -DataFactoryName $adf -PipelineName config_ConfigureExports
```

### Permissões

```powershell
# o que a identidade do Data Factory tem hoje
$mi = (Get-AzDataFactoryV2 -ResourceGroupName $rg -Name $adf).Identity.PrincipalId
Get-AzRoleAssignment -ObjectId $mi | Select-Object RoleDefinitionName, Scope

# dar a voce acesso de LEITURA DE DADOS no storage (nao e herdado de Owner)
New-AzRoleAssignment -ObjectId (Get-AzADUser -SignedIn).Id `
  -RoleDefinitionName 'Storage Blob Data Reader' `
  -Scope (Get-AzStorageAccount -ResourceGroupName $rg -Name $sa).Id

# dar a identidade do ADF permissao de criar exports
New-AzRoleAssignment -ObjectId $mi -RoleDefinitionName 'Cost Management Contributor' -Scope $scope
```

### Consulta M para ler o parquet direto no Power BI

Útil para validar acesso e para montar um relatório próprio, sem o template do toolkit:

```
let
    Fonte      = AzureStorage.DataLake("https://<storage-do-hub>.dfs.core.windows.net/ingestion"),
    SoCustos   = Table.SelectRows(Fonte, each Text.Contains([Folder Path], "/Costs/") and Text.EndsWith([Name], ".parquet")),
    ComTabelas = Table.AddColumn(SoCustos, "Dados", each Parquet.Document([Content])),
    Combinado  = Table.Combine(ComTabelas[Dados]),
    ComData    = Table.AddColumn(Combinado, "Data", each Date.From([ChargePeriodStart]), type date),
    ComMes     = Table.AddColumn(ComData, "Mes", each Date.StartOfMonth([Data]), type date)
in
    ComMes
```
