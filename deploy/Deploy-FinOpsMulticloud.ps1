<#
.SYNOPSIS
    Instala (ou atualiza) a solucao FinOps Multicloud: FinOps hub + conectores AWS e OCI.

.DESCRIPTION
    O script e idempotente: pode ser executado varias vezes. Cada etapa explica o que faz.

    Etapa 1  Pre-requisitos      valida modulos (Az, FinOpsToolkit, Bicep) e faz login.
    Etapa 2  FinOps hub          Deploy-FinOpsHub (storage-only, Fabric ou Data Explorer).
    Etapa 3  Escopos Azure       managed exports (settings.json) ou exports manuais via New-FinOpsCostExport.
    Etapa 4  Extensao multicloud Bicep: Key Vault, pipelines mc_* no Data Factory (AWS) e Function App (OCI).
    Etapa 5  Configuracao        upload de config/multicloud/manifest.json e inicio dos triggers.
    Etapa 6  Codigo da Function  publica functions/oci-connector (zip deploy com build remoto).
    Etapa 7  Resumo              imprime o que falta fazer manualmente (Fabric, dashboards).

.EXAMPLE
    # Nivel 0 (custo minimo): so storage, sem Fabric/ADX, so Azure
    ./Deploy-FinOpsMulticloud.ps1 -SubscriptionId <id> -ResourceGroup rg-finops -Location brazilsouth `
        -HubName finops-hub -Mode Storage -ScopesToMonitor '/subscriptions/<sub-id>' -SkipAws -SkipOci

.EXAMPLE
    # Nivel 1 (recomendado): Fabric F2 + AWS + OCI, lendo os parametros de um arquivo
    ./Deploy-FinOpsMulticloud.ps1 -ParametersFile ./parameters.json

.EXAMPLE
    # Assinatura com politica que bloqueia chave de storage (ex.: interna da Microsoft): tag SecurityControl=Ignore no RG
    ./Deploy-FinOpsMulticloud.ps1 -ParametersFile ./parameters.json -ResourceGroupTags @{ SecurityControl = 'Ignore' }

.NOTES
    Requer PowerShell 7+, modulos Az (Accounts, Resources, Storage, DataFactory, KeyVault, Websites),
    modulo FinOpsToolkit (Install-Module FinOpsToolkit), Bicep CLI (az bicep install) e Azure CLI (az)
    para publicar o codigo da Function.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ParametersFile,

    [string] $SubscriptionId,
    [string] $ResourceGroup,
    [string] $Location = 'brazilsouth',
    [string] $HubName = 'finops-hub',

    # Storage = so storage (Power BI storage reports). Fabric = Eventhouse. DataExplorer = cluster ADX.
    [ValidateSet('Storage', 'Fabric', 'DataExplorer')]
    [string] $Mode = 'Storage',
    [string] $FabricQueryUri,
    [int]    $FabricCapacityUnits = 2,
    [string] $DataExplorerName,
    [string] $DataExplorerSku = 'Dev (No SLA)_Standard_E2a_v4',

    [string[]] $ScopesToMonitor = @(),
    [switch] $ManualExports,          # cria exports via New-FinOpsCostExport em vez de managed exports

    # Versao FOCUS dos Cost Management exports.
    # ATENCAO: os relatorios Power BI *storage* (nivel 0) leem o esquema FOCUS 1.0. Os managed exports do
    # template do hub criam 1.2-preview, e a conversao 1.2 -> 1.0 so acontece na ingestao do Data Explorer
    # ou do Fabric (nivel 1). Por isso, no modo Storage o padrao e 1.0r2 com exports manuais.
    [ValidateSet('1.0', '1.0r2', '1.2-preview')]
    [string] $FocusVersion = '1.0r2',
    # Quantos meses de historico buscar na criacao do export. Roda UMA vez, no create.
    # 12 da 13 meses de dado (12 fechados + o corrente), suficiente para comparacao ano a ano.
    # Para 24 meses, suba tambem o IngestionRetentionInMonths, senao o hub apaga o excedente.
    [ValidateRange(0, 24)]
    [int]    $BackfillMonths = 12,

    # Quanto tempo o hub guarda o dado processado no container ingestion. Precisa ser >= BackfillMonths + 1.
    [ValidateRange(1, 60)]
    [int]    $IngestionRetentionInMonths = 13,
    [switch] $EnableRecommendations,  # recomendacoes do Azure (Advisor + Resource Graph) via template

    # AWS
    [switch] $SkipAws,
    [string] $AwsBucketName,
    [string] $AwsS3Prefix = 'focus',
    [string] $AwsExportName = 'finops-focus-1-0',
    [string] $AwsPayerAccountId,
    [string] $AwsRegion = 'us-east-1',
    [string] $AwsAccessKeyId,
    [securestring] $AwsSecretAccessKey,
    [switch] $AwsRecommendations,
    [string] $AwsRecommendationsExportName = 'finops-coh-recommendations',

    # OCI
    [switch] $SkipOci,
    [string] $OciTenancyOcid,
    [string] $OciUserOcid,
    [string] $OciFingerprint,
    [string] $OciRegion = 'sa-saopaulo-1',
    [string] $OciPrivateKeyPath,    # caminho do .pem
    [switch] $OciNoRecommendations,

    [hashtable] $Tags = @{ solution = 'finops-multicloud' },
    # Tags aplicadas SO ao resource group. Em assinaturas com politicas que desligam o acesso por chave em storage
    # (ex.: assinaturas internas da Microsoft, SFI) use @{ SecurityControl = 'Ignore' }: os deployment scripts do hub
    # precisam de chave de storage e falham com KeyBasedAuthenticationNotPermitted sem essa tag.
    [hashtable] $ResourceGroupTags = @{},
    [switch] $SkipHub,
    [switch] $SkipFunctionPublish,
    # Nao executar as pipelines do hub (config_ConfigureExports e config_RunBackfillJob) ao final da etapa 3.
    [switch] $SkipExportRun,
    # Quantas vezes tentar criar os exports enquanto o RBAC propaga (intervalo de 3 minutos entre as tentativas).
    [int] $ExportRetries = 4
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

function Write-Step([string]$title, [string]$why) {
    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
    Write-Host ("  $title") -ForegroundColor Cyan
    if ($why) { Write-Host ("  Para que serve: $why") -ForegroundColor DarkGray }
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
}

# --------------------------------------------------------------------------------------
# Parametros via arquivo (parameters.json). Chaves = nomes dos parametros deste script.
# --------------------------------------------------------------------------------------
if ($ParametersFile) {
    $p = Get-Content -Raw -Path $ParametersFile | ConvertFrom-Json -AsHashtable
    foreach ($k in $p.Keys) {
        if ($k -eq 'AwsSecretAccessKey' -and $p[$k]) { $AwsSecretAccessKey = ConvertTo-SecureString $p[$k] -AsPlainText -Force; continue }
        if ($k -eq 'Tags' -and $p[$k]) { $Tags = [hashtable]$p[$k]; continue }
        if ($k -eq 'ResourceGroupTags' -and $p[$k]) { $ResourceGroupTags = [hashtable]$p[$k]; continue }
        if ($p[$k] -is [bool]) { Set-Variable -Name $k -Value ([switch]$p[$k]) -Scope Script; continue }
        Set-Variable -Name $k -Value $p[$k] -Scope Script
    }
}

if ($ParametersFile -and (Split-Path $ParametersFile -Leaf) -ieq 'parameters.example.json') {
    Write-Warning 'Voce esta usando parameters.example.json. Esse arquivo e o MODELO e e substituido quando o kit e atualizado (voce perde os seus valores).'
    Write-Warning 'Copie-o para parameters.json (Copy-Item .\parameters.example.json .\parameters.json), preencha a copia e use -ParametersFile .\parameters.json.'
}
if (-not $SubscriptionId -or -not $ResourceGroup) { throw 'Informe -SubscriptionId e -ResourceGroup (ou use -ParametersFile).' }
if ($SubscriptionId -match '^0{8}-0{4}-0{4}-0{4}-0{12}$' -or $SubscriptionId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
    throw "SubscriptionId '$SubscriptionId' ainda e o valor de exemplo ou nao e um GUID. Descubra o ID real com: Get-AzSubscription | Select-Object Name, Id, TenantId"
}
foreach ($s in $ScopesToMonitor) {
    if ($s -match '0{8}-0{4}-0{4}-0{4}-0{12}|1234567$') { throw "ScopesToMonitor contem um valor de exemplo ($s). Use o ID real da assinatura ou do billing account." }
}
if (-not $SkipAws -and $AwsAccessKeyId -like 'AKIA....*') { throw 'AwsAccessKeyId ainda e o valor de exemplo. Preencha os dados da AWS ou use "SkipAws": true.' }
if (-not $SkipOci -and $OciTenancyOcid -like '*aaaa') { throw 'OciTenancyOcid ainda e o valor de exemplo. Preencha os dados da OCI ou use "SkipOci": true.' }
if ($Mode -eq 'Fabric' -and -not $FabricQueryUri) { throw 'Modo Fabric exige -FabricQueryUri (Eventhouse > System overview > Query URI).' }
if ($Mode -eq 'DataExplorer' -and -not $DataExplorerName) { throw 'Modo DataExplorer exige -DataExplorerName.' }

# No modo Storage o consumo e feito pelos relatorios Power BI storage, que leem o esquema FOCUS 1.0.
# Os managed exports do template criam 1.2-preview e nao ha conversao nesse modo, o que quebra a consulta
# Costs com "The column 'SkuMeterName' of the table wasn't found". Por isso usamos exports manuais em 1.0r2.
if ($Mode -eq 'Storage' -and -not $ManualExports -and $ScopesToMonitor.Count -gt 0) {
    $ManualExports = $true
    Write-Host ''
    Write-Host "  Modo Storage: usando exports manuais em FOCUS $FocusVersion (em vez dos managed exports do template)." -ForegroundColor Yellow
    Write-Host '  Motivo: os relatorios Power BI storage leem o esquema FOCUS 1.0. Os managed exports criam 1.2-preview' -ForegroundColor DarkGray
    Write-Host "  e a conversao para 1.0 so acontece no nivel 1 (Data Explorer ou Fabric)." -ForegroundColor DarkGray
    Write-Host '  Para forcar o comportamento antigo, use -FocusVersion 1.2-preview junto com -ManualExports:$false.' -ForegroundColor DarkGray
}
if ($Mode -ne 'Storage' -and -not $PSBoundParameters.ContainsKey('FocusVersion')) { $FocusVersion = '1.2-preview' }

# O hub apaga do container ingestion tudo que passar da retencao. Se o backfill buscar mais meses do que a
# retencao guarda, o dado antigo entra e e apagado logo em seguida, o que confunde muito na hora de conferir.
if ($IngestionRetentionInMonths -lt ($BackfillMonths + 1)) {
    $novo = $BackfillMonths + 1
    Write-Host ''
    Write-Warning "IngestionRetentionInMonths ($IngestionRetentionInMonths) e menor que BackfillMonths + 1 ($novo)."
    Write-Warning "Ajustando a retencao para $novo meses, senao o hub apagaria o historico que o backfill acabou de trazer."
    $IngestionRetentionInMonths = $novo
}

# ======================================================================================
Write-Step 'Etapa 1 de 7: pre-requisitos e login' 'garante que as ferramentas certas existem e que estamos na assinatura correta.'
# ======================================================================================
$required = @('Az.Accounts', 'Az.Resources', 'Az.Storage', 'Az.DataFactory', 'Az.KeyVault', 'Az.Websites', 'FinOpsToolkit')
foreach ($m in $required) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Host "  Instalando modulo $m..." -ForegroundColor Yellow
        Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $m -ErrorAction Stop
}
$ftkVersion = (Get-Module FinOpsToolkit | Sort-Object Version -Descending | Select-Object -First 1).Version
Write-Host "  FinOpsToolkit $ftkVersion" -ForegroundColor Green
if ($ftkVersion -lt [version]'12.0') {
    throw "O modulo FinOpsToolkit $ftkVersion e antigo. Atualize com: Update-Module FinOpsToolkit -Force (necessario 12.0 ou superior)."
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Warning 'Azure CLI (az) nao encontrado. A publicacao do codigo da Function (etapa 6) sera pulada; use "func azure functionapp publish" depois.'
    $SkipFunctionPublish = $true
}

# --------------------------------------------------------------------------------------
# Bicep CLI: o Deploy-FinOpsHub e o New-AzResourceGroupDeployment compilam arquivos .bicep
# e exigem o executavel "bicep" no PATH. "az bicep install" instala uma copia privada da
# Azure CLI (~/.azure/bin) que NAO fica no PATH; por isso o erro
# "Cannot find Bicep. Please add Bicep to your PATH". Esta funcao resolve isso sozinha.
# --------------------------------------------------------------------------------------
function Ensure-BicepCli {
    if (Get-Command bicep -ErrorAction SilentlyContinue) {
        Write-Host "  Bicep CLI: $(& bicep --version)" -ForegroundColor Green
        return
    }
    $isWin = $IsWindows -or ($env:OS -eq 'Windows_NT')
    $exe = if ($isWin) { 'bicep.exe' } else { 'bicep' }
    $azDirs = @((Join-Path $HOME '.azure'), $env:AZURE_CONFIG_DIR) | Where-Object { $_ }
    $candidates = $azDirs | ForEach-Object { Join-Path (Join-Path $_ 'bin') $exe }
    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $found -and (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host '  Bicep nao esta no PATH. Instalando a copia da Azure CLI (az bicep install)...' -ForegroundColor Yellow
        & az bicep install 2>&1 | Out-Null
        $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $found) {
        $dir = Join-Path $HOME '.bicep'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
        $asset = if ($isWin) { "bicep-win-$arch.exe" } elseif ($IsMacOS) { "bicep-osx-$arch" } else { "bicep-linux-$arch" }
        $found = Join-Path $dir $exe
        Write-Host "  Baixando o Bicep CLI ($asset) para $dir ..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri "https://github.com/Azure/bicep/releases/latest/download/$asset" -OutFile $found
        if (-not $isWin) { & chmod +x $found }
    }
    $binDir = Split-Path $found -Parent
    $sep = [IO.Path]::PathSeparator
    if (($env:PATH -split [regex]::Escape($sep)) -notcontains $binDir) { $env:PATH = "$binDir$sep$env:PATH" }
    if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
        throw 'Bicep CLI nao encontrado. Instale com "winget install -e --id Microsoft.Bicep" (Windows), "brew install bicep" (macOS) ou https://aka.ms/bicep-install, reabra o PowerShell e rode de novo.'
    }
    Write-Host "  Bicep CLI: $(& bicep --version)  (adicionado ao PATH desta sessao: $binDir)" -ForegroundColor Green
}
Ensure-BicepCli

$ctx = Get-AzContext
if (-not $ctx -or $ctx.Subscription.Id -ne $SubscriptionId) {
    Connect-AzAccount -Subscription $SubscriptionId | Out-Null
}
Set-AzContext -Subscription $SubscriptionId | Out-Null
Write-Host "  Assinatura: $((Get-AzContext).Subscription.Name) ($SubscriptionId)" -ForegroundColor Green

$rgTags = @{} + $Tags
foreach ($k in $ResourceGroupTags.Keys) { $rgTags[$k] = $ResourceGroupTags[$k] }
$rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) {
    $rg = New-AzResourceGroup -Name $ResourceGroup -Location $Location -Tag $rgTags
    Write-Host "  Resource group $ResourceGroup criado." -ForegroundColor Green
}
elseif ($ResourceGroupTags.Count -gt 0) {
    # garante as tags do RG mesmo quando ele ja existia (ex.: SecurityControl = Ignore apos uma tentativa que falhou)
    Update-AzTag -ResourceId $rg.ResourceId -Tag $ResourceGroupTags -Operation Merge | Out-Null
    Write-Host "  Tags aplicadas ao resource group: $(($ResourceGroupTags.Keys | ForEach-Object { "$_=$($ResourceGroupTags[$_])" }) -join ', ')" -ForegroundColor Green
}

# ======================================================================================
Write-Step 'Etapa 2 de 7: FinOps hub (motor da solucao)' 'cria storage (msexports/ingestion/config), Data Factory com as pipelines oficiais e, opcionalmente, a ligacao com Fabric ou Data Explorer.'
# ======================================================================================
if (-not $SkipHub) {
    $hubArgs = @{
        Name                       = $HubName
        ResourceGroupName          = $ResourceGroup
        Location                   = $Location
        IngestionRetentionInMonths = $IngestionRetentionInMonths
        Tags                       = $Tags
    }
    if (-not $ManualExports -and $ScopesToMonitor.Count -gt 0) {
        $hubArgs.EnableManagedExports = $true
        $hubArgs.ScopesToMonitor = $ScopesToMonitor
    }
    switch ($Mode) {
        'Fabric'       { $hubArgs.FabricQueryUri = $FabricQueryUri; $hubArgs.FabricCapacityUnits = $FabricCapacityUnits }
        'DataExplorer' { $hubArgs.DataExplorerName = $DataExplorerName; $hubArgs.DataExplorerSku = $DataExplorerSku }
    }
    $recsSupported = (Get-Command Deploy-FinOpsHub).Parameters.ContainsKey('EnableRecommendations')
    if ($EnableRecommendations -and $recsSupported) { $hubArgs.EnableRecommendations = $true }
    # Uma tentativa anterior que falhou por politica pode ter deixado as storage accounts do hub sem acesso por chave.
    # Os deployment scripts do template (Azure Container Instances) montam um file share por chave; reabilita antes de tentar de novo.
    Get-AzStorageAccount -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.StorageAccountName -like "$($HubName.Replace('-',''))*" -and $_.AllowSharedKeyAccess -eq $false } |
        ForEach-Object {
            Write-Host "  Reabilitando acesso por chave em $($_.StorageAccountName) (necessario para os deployment scripts do hub)..." -ForegroundColor Yellow
            try { Set-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $_.StorageAccountName -AllowSharedKeyAccess $true | Out-Null }
            catch { Write-Warning "Nao foi possivel reabilitar: $($_.Exception.Message). Se uma politica bloqueou, aplique a tag SecurityControl=Ignore no RG (ou uma isencao) e rode de novo." }
        }

    Write-Host "  Deploy-FinOpsHub em modo $Mode..." -ForegroundColor Yellow
    try {
        $hubDeployment = Deploy-FinOpsHub @hubArgs
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'KeyBasedAuthenticationNotPermitted|Key based authentication is not permitted|DeploymentScriptOperationFailed|DeploymentScriptACIProvisioningTimeout') {
            Write-Host '' 
            Write-Host '  O deploy do hub falhou nos "deployment scripts" do template oficial. Causa mais comum: uma politica da assinatura' -ForegroundColor Red
            Write-Host '  (ex.: SFI em assinaturas internas da Microsoft, ou "Storage accounts should prevent shared key access") desliga o' -ForegroundColor Red
            Write-Host '  acesso por chave nas storage accounts, e os deployment scripts precisam dele para montar o file share.' -ForegroundColor Red
            Write-Host '' 
            Write-Host '  Como resolver (orientacao dos mantenedores do FinOps toolkit, issues #1816 e #2241):' -ForegroundColor Yellow
            Write-Host '    1. Aplique a tag SecurityControl = Ignore no resource group ANTES do deploy. Neste script:' -ForegroundColor Yellow
            Write-Host '         parameters.json  ->  "ResourceGroupTags": { "SecurityControl": "Ignore" }' -ForegroundColor Yellow
            Write-Host '         ou               ->  -ResourceGroupTags @{ SecurityControl = ''Ignore'' }' -ForegroundColor Yellow
            Write-Host '    2. Em tenants de clientes com politica propria de shared key: crie uma isencao (exemption) da politica para o resource group.' -ForegroundColor Yellow
            Write-Host '    3. Rode o script de novo. Ele reabilita o acesso por chave nas storage accounts do hub e repete o deploy.' -ForegroundColor Yellow
            Write-Host '' 
        }
        throw
    }
    if ($hubDeployment.ProvisioningState -and $hubDeployment.ProvisioningState -ne 'Succeeded') {
        throw "Deploy do hub terminou com estado $($hubDeployment.ProvisioningState)."
    }
    if ($EnableRecommendations -and -not $recsSupported) {
        Write-Host '  Observacao: esta versao do modulo FinOpsToolkit nao expoe -EnableRecommendations. Para ligar as recomendacoes do Azure' -ForegroundColor DarkGray
        Write-Host '  (Advisor + Resource Graph), reimplante o hub pelo portal (Deploy to Azure) marcando "Enable recommendations".' -ForegroundColor DarkGray
    }
}

# --------------------------------------------------------------------------------------
# Descobre os recursos do hub, do metodo mais confiavel ao menos confiavel:
#   1) outputs do deployment do template (storageAccountName, dataFactoryName)
#   2) tag cm-resource-parent que o template aplica a todos os recursos
#   3) prefixo do nome (<hub>store..., <hub>-engine-...)
# --------------------------------------------------------------------------------------
$hubStorage = $null; $hubAdf = $null; $hubOutputs = $null
if ($hubDeployment -and $hubDeployment.Outputs -and $hubDeployment.Outputs.ContainsKey('dataFactoryName')) { $hubOutputs = $hubDeployment.Outputs }
if (-not $hubOutputs) {
    $lastHubDeployment = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.ProvisioningState -eq 'Succeeded' -and $_.Outputs -and $_.Outputs.ContainsKey('dataFactoryName') } |
        Sort-Object Timestamp -Descending | Select-Object -First 1
    if ($lastHubDeployment) { $hubOutputs = $lastHubDeployment.Outputs }
}
if ($hubOutputs) {
    $saName  = $hubOutputs['storageAccountName'].Value
    $adfName = $hubOutputs['dataFactoryName'].Value
    if ($saName)  { $hubStorage = Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $saName -ErrorAction SilentlyContinue }
    if ($adfName) { $hubAdf     = Get-AzDataFactoryV2  -ResourceGroupName $ResourceGroup -Name $adfName -ErrorAction SilentlyContinue }
}
if (-not $hubStorage -or -not $hubAdf) {
    $allSa  = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue)
    $allAdf = @(Get-AzDataFactoryV2  -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue)
    $hubAlnum = $HubName.Replace('-', '').Replace('_', '').ToLower()
    if (-not $hubStorage) {
        $hubStorage = $allSa | Where-Object { $_.Tags -and $_.Tags['cm-resource-parent'] -like "*/hubs/$HubName" -and $_.StorageAccountName -notlike '*script*' } | Select-Object -First 1
        if (-not $hubStorage) { $hubStorage = $allSa | Where-Object { $_.StorageAccountName -like "${hubAlnum}store*" } | Select-Object -First 1 }
        if (-not $hubStorage) { $hubStorage = $allSa | Where-Object { $_.StorageAccountName -like '*store*' -and $_.StorageAccountName -notlike '*script*' -and $_.EnableHierarchicalNamespace } | Select-Object -First 1 }
    }
    if (-not $hubAdf) {
        $hubAdf = $allAdf | Where-Object { $_.Tags -and $_.Tags['cm-resource-parent'] -like "*/hubs/$HubName" } | Select-Object -First 1
        if (-not $hubAdf) { $hubAdf = $allAdf | Where-Object { $_.DataFactoryName -like "$HubName-engine-*" } | Select-Object -First 1 }
        if (-not $hubAdf -and $allAdf.Count -eq 1) { $hubAdf = $allAdf[0] }
    }
    if (-not $hubStorage -or -not $hubAdf) {
        Write-Host "  Storage accounts no resource group : $(($allSa  | ForEach-Object { $_.StorageAccountName }) -join ', ')" -ForegroundColor DarkGray
        Write-Host "  Data Factories no resource group   : $(($allAdf | ForEach-Object { $_.DataFactoryName })  -join ', ')" -ForegroundColor DarkGray
        throw 'Nao encontrei a storage account ou o Data Factory do hub. Confira -HubName e -ResourceGroup (a lista acima mostra o que existe no resource group).'
    }
}
Write-Host "  Storage do hub : $($hubStorage.StorageAccountName)" -ForegroundColor Green
Write-Host "  Data Factory   : $($hubAdf.DataFactoryName)" -ForegroundColor Green
Write-Host "  Identidade ADF : $($hubAdf.Identity.PrincipalId)" -ForegroundColor Green

# --------------------------------------------------------------------------------------
# Executa uma pipeline do hub e aguarda o resultado (usado para criar os exports e o backfill).
# --------------------------------------------------------------------------------------
function Invoke-HubPipeline {
    param([string]$Name, [hashtable]$Parameters, [int]$TimeoutMinutes = 20, [switch]$NoWait)
    $invokeArgs = @{ ResourceGroupName = $ResourceGroup; DataFactoryName = $hubAdf.DataFactoryName; PipelineName = $Name }
    if ($Parameters) { $invokeArgs.Parameter = $Parameters }
    $runId = Invoke-AzDataFactoryV2Pipeline @invokeArgs
    if ($NoWait) { return [pscustomobject]@{ Status = 'InProgress'; RunId = $runId } }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 15
        $run = Get-AzDataFactoryV2PipelineRun -ResourceGroupName $ResourceGroup -DataFactoryName $hubAdf.DataFactoryName -PipelineRunId $runId
    } while ($run.Status -in @('Queued', 'InProgress') -and (Get-Date) -lt $deadline)
    return [pscustomobject]@{ Status = $run.Status; RunId = $runId; Message = $run.Message }
}

# ======================================================================================
Write-Step 'Etapa 3 de 7: escopos do Azure (Cost Management exports)' 'e daqui que vem o custo do Azure em FOCUS, mais precos e reservas. Sem export nao ha dado.'
# ======================================================================================
if ($ManualExports -and $ScopesToMonitor.Count -gt 0) {
    foreach ($scope in $ScopesToMonitor) {
        $safe = ($scope.Trim('/') -replace '[^a-zA-Z0-9]', '-').ToLower()
        $isBilling = $scope -like '/providers/Microsoft.Billing/*'
        $datasets = if ($isBilling) { @('FocusCost', 'PriceSheet', 'ReservationDetails', 'ReservationRecommendations', 'ReservationTransactions') } else { @('FocusCost') }
        foreach ($ds in $datasets) {
            $name = "ftk-$($ds.ToLower())-$($safe.Substring([Math]::Max(0, $safe.Length - 30)))"
            $rotuloDs = if ($ds -eq 'FocusCost') { "$ds $FocusVersion" } else { $ds }
            Write-Host "  Export $name ($rotuloDs) em $scope" -ForegroundColor Yellow
            $exp = @{
                Name             = $name
                Scope            = $scope
                Dataset          = $ds
                StorageAccountId = $hubStorage.Id
                StorageContainer = 'msexports'
                StoragePath      = $scope.Trim('/')
                DoNotOverwrite   = $true
                Execute          = $true
            }
            if ($ds -eq 'FocusCost') { $exp.DatasetVersion = $FocusVersion; $exp.Backfill = $BackfillMonths }
            if ($PSCmdlet.ShouldProcess($name, 'New-FinOpsCostExport')) { New-FinOpsCostExport @exp | Out-Null }
        }
        if (-not $isBilling) { Write-Host '  Escopo de assinatura: apenas FocusCost (precos e reservas so existem em billing account EA ou billing profile MCA).' -ForegroundColor DarkGray }
    }
    # Segundo export mensal do mes anterior (recomendado pelo toolkit) fica a cargo do hub quando managed; aqui deixamos o daily com backfill.
}
elseif ($ScopesToMonitor.Count -gt 0) {
    $mi = $hubAdf.Identity.PrincipalId
    Write-Host "  Managed exports: a identidade do Data Factory ($mi) precisa de papeis para criar os exports." -ForegroundColor Yellow

    function Grant-Role([string]$role, [string]$scope, [string]$porque) {
        $ja = Get-AzRoleAssignment -ObjectId $mi -Scope $scope -ErrorAction SilentlyContinue |
                Where-Object { $_.Scope -eq $scope -and $_.RoleDefinitionName -eq $role }
        if ($ja) { Write-Host "    OK: $role em $scope" -ForegroundColor Green; return $true }
        try {
            New-AzRoleAssignment -ObjectId $mi -RoleDefinitionName $role -Scope $scope -ErrorAction Stop | Out-Null
            Write-Host "    Concedido: $role em $scope" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Warning "Nao consegui conceder '$role' em $scope. $porque"
            Write-Warning "  Detalhe: $($_.Exception.Message)"
            return $false
        }
    }

    # 1. O Cost Management, ao criar um export gerenciado, atribui um papel a si mesmo na storage account de destino.
    #    Quem chama a API (a identidade do Data Factory) precisa poder gravar role assignments nessa storage; sem isso o
    #    export falha com: "The user does not have authorization to perform 'Microsoft.Authorization/roleAssignments/write'
    #    action on specified storage account". O template do hub concede esse papel, mas ele pode nao ter sido aplicado.
    $uaaOk = $false
    $temUaa = Get-AzRoleAssignment -ObjectId $mi -Scope $hubStorage.Id -ErrorAction SilentlyContinue |
                Where-Object { $_.Scope -eq $hubStorage.Id -and $_.RoleDefinitionName -in @('User Access Administrator', 'Owner', 'Role Based Access Control Administrator') }
    if ($temUaa) { Write-Host "    OK: $($temUaa[0].RoleDefinitionName) na storage do hub" -ForegroundColor Green; $uaaOk = $true }
    else { $uaaOk = Grant-Role 'User Access Administrator' $hubStorage.Id 'Sem ele o Cost Management nao consegue configurar a escrita na storage.' }

    # 2. Papeis de custo em cada escopo monitorado (assinatura ou resource group). Escopos de billing (EA/MCA) sao
    #    concedidos no portal de billing, nao por RBAC do Azure, entao apenas avisamos.
    $escoposOk = $true
    foreach ($scope in $ScopesToMonitor) {
        if ($scope -like '/subscriptions/*') {
            $subScope = '/subscriptions/' + ($scope -split '/')[2]
            if (-not (Grant-Role 'Cost Management Contributor' $subScope 'Necessario para criar e rodar os exports.')) { $escoposOk = $false }
            Grant-Role 'Reader' $subScope 'Necessario para as recomendacoes do Azure Resource Graph.' | Out-Null
        }
        else {
            Write-Host "    Escopo de billing detectado ($scope): conceda Enterprise Reader (EA) ou Contributor no billing profile (MCA) a identidade $mi pelo portal de billing." -ForegroundColor Yellow
            $escoposOk = $false
        }
    }

    if (-not ($uaaOk -and $escoposOk)) {
        Write-Host '  Ha papeis pendentes acima. Conceda-os e rode este script de novo com -SkipHub.' -ForegroundColor Yellow
        Write-Host '  Alternativa que nao depende desses papeis: use "ManualExports": true no parameters.json (os exports sao criados com a sua conta).' -ForegroundColor Yellow
    }

    if ($SkipExportRun) {
        Write-Host '  -SkipExportRun informado: rode a pipeline config_ConfigureExports no Data Factory Studio quando quiser.' -ForegroundColor DarkGray
    }
    else {
        # Cria os exports no Cost Management. Como o RBAC recem-concedido leva de 5 a 30 minutos para propagar,
        # tentamos algumas vezes antes de desistir, em vez de exigir que voce rode a pipeline na mao.
        Write-Host '  Criando os exports no Cost Management (pipeline config_ConfigureExports)...' -ForegroundColor Yellow
        $exportsOk = $false
        for ($i = 1; $i -le [Math]::Max(1, $ExportRetries); $i++) {
            $run = Invoke-HubPipeline -Name 'config_ConfigureExports' -TimeoutMinutes 15
            if ($run.Status -eq 'Succeeded') { $exportsOk = $true; Write-Host "  Exports configurados (tentativa $i)." -ForegroundColor Green; break }
            if ($i -lt $ExportRetries) {
                Write-Host "  Tentativa $i terminou como $($run.Status). Isso e esperado enquanto o RBAC propaga; nova tentativa em 3 minutos..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 180
            }
            else {
                Write-Warning "A pipeline config_ConfigureExports terminou como $($run.Status) apos $i tentativas."
                Write-Warning 'Abra Data Factory Studio > Monitor, veja o Output da atividade que falhou e confira os papeis listados acima.'
            }
        }

        if ($exportsOk) {
            # Executa os exports agora (o agendamento normal so roda de madrugada) e dispara o historico.
            Write-Host '  Executando os exports e o backfill do historico...' -ForegroundColor Yellow
            $daily = Invoke-HubPipeline -Name 'config_StartExportProcess' -Parameters @{ Schedule = 'Daily' } -TimeoutMinutes 20
            Write-Host "    config_StartExportProcess (Daily): $($daily.Status)" -ForegroundColor DarkGray
            $backfill = Invoke-HubPipeline -Name 'config_RunBackfillJob' -NoWait
            Write-Host "    config_RunBackfillJob disparado (run $($backfill.RunId)); ele roda em segundo plano." -ForegroundColor DarkGray
            Write-Host '  Os primeiros arquivos aparecem no container msexports em minutos e no ingestion logo depois.' -ForegroundColor Green
        }
    }
}
else {
    Write-Host '  Nenhum escopo informado. Crie os exports depois (portal: Cost Management > Exports > All costs (FOCUS) + prices).' -ForegroundColor Yellow
}

# ======================================================================================
Write-Step 'Etapa 4 de 7: extensao multicloud (AWS + OCI)' 'Key Vault para credenciais, pipelines mc_* no Data Factory do hub (AWS via S3) e Function App Python (OCI).'
# ======================================================================================
$awsEnabled = -not $SkipAws
$ociEnabled = -not $SkipOci
if ($awsEnabled -and (-not $AwsBucketName -or -not $AwsPayerAccountId -or -not $AwsAccessKeyId -or -not $AwsSecretAccessKey)) {
    throw 'AWS habilitada: informe -AwsBucketName, -AwsPayerAccountId, -AwsAccessKeyId e -AwsSecretAccessKey (ou use -SkipAws).'
}
$ociPem = ''
if ($ociEnabled) {
    if (-not $OciTenancyOcid -or -not $OciUserOcid -or -not $OciFingerprint -or -not $OciPrivateKeyPath) {
        throw 'OCI habilitada: informe -OciTenancyOcid, -OciUserOcid, -OciFingerprint e -OciPrivateKeyPath (ou use -SkipOci).'
    }
    $ociPem = Get-Content -Raw -Path $OciPrivateKeyPath
}

$bicep = Join-Path $root 'multicloud-extension.bicep'
$ext = @{
    hubName                   = $HubName
    location                  = $Location
    hubStorageAccountName     = $hubStorage.StorageAccountName
    hubDataFactoryName        = $hubAdf.DataFactoryName
    tags                      = $Tags
    awsEnabled                = $awsEnabled
    awsBucketName             = [string]$AwsBucketName
    awsS3Prefix               = $AwsS3Prefix
    awsExportName             = $AwsExportName
    awsPayerAccountId         = [string]$AwsPayerAccountId
    awsRegion                 = $AwsRegion
    awsAccessKeyId            = [string]$AwsAccessKeyId
    awsSecretAccessKey        = $(if ($AwsSecretAccessKey) { ConvertFrom-SecureString $AwsSecretAccessKey -AsPlainText } else { '' })
    awsRecommendationsEnabled = [bool]$AwsRecommendations
    awsRecommendationsExportName = $AwsRecommendationsExportName
    ociEnabled                = $ociEnabled
    ociTenancyOcid            = [string]$OciTenancyOcid
    ociUserOcid               = [string]$OciUserOcid
    ociFingerprint            = [string]$OciFingerprint
    ociRegion                 = $OciRegion
    ociPrivateKeyPem          = $ociPem
    ociRecommendationsEnabled = -not $OciNoRecommendations
}
# Compila o Bicep para ARM JSON antes do deploy: erros de sintaxe aparecem aqui, com linha e coluna,
# em vez de uma mensagem generica de "dynamic parameters" do New-AzResourceGroupDeployment.
$armJson = Join-Path ([IO.Path]::GetTempPath()) "multicloud-extension-$(Get-Date -Format yyyyMMddHHmmss).json"
Write-Host '  Compilando multicloud-extension.bicep...' -ForegroundColor Yellow
$buildOutput = & bicep build $bicep --outfile $armJson 2>&1   # sintaxe do Bicep CLI standalone: arquivo posicional (az bicep usa --file)
$buildOutput | Where-Object { $_ -notmatch 'Warning' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $armJson)) { throw 'Falha ao compilar multicloud-extension.bicep (veja as mensagens acima).' }

Write-Host '  Implantando a extensao multicloud (Key Vault, pipelines mc_*, Function App)...' -ForegroundColor Yellow
$extDeployment = New-AzResourceGroupDeployment -Name "finops-multicloud-$(Get-Date -Format yyyyMMddHHmm)" -ResourceGroupName $ResourceGroup `
    -TemplateFile $armJson -TemplateParameterObject $ext -Mode Incremental
Remove-Item $armJson -Force -ErrorAction SilentlyContinue
if ($extDeployment.ProvisioningState -ne 'Succeeded') { throw "Extensao terminou com estado $($extDeployment.ProvisioningState)." }
$functionAppName = $extDeployment.Outputs.functionAppName.Value
$keyVaultName    = $extDeployment.Outputs.keyVaultName.Value
Write-Host "  Key Vault    : $keyVaultName" -ForegroundColor Green
if ($functionAppName) { Write-Host "  Function App : $functionAppName" -ForegroundColor Green }

# ======================================================================================
Write-Step 'Etapa 5 de 7: configuracao (manifest modelo e triggers)' 'o manifest.json e o gatilho que avisa o hub que uma carga terminou; os triggers ligam o agendamento diario.'
# ======================================================================================
# 5.1 manifest modelo em config/multicloud/manifest.json (conteudo {} : arquivo vazio e ignorado pelo hub)
try {
    $sctx = New-AzStorageContext -StorageAccountName $hubStorage.StorageAccountName -UseConnectedAccount
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value '{}' -NoNewline -Encoding ascii
    Set-AzStorageBlobContent -Context $sctx -Container 'config' -File $tmp -Blob 'multicloud/manifest.json' -Force | Out-Null
    Remove-Item $tmp -Force
    Write-Host '  config/multicloud/manifest.json gravado.' -ForegroundColor Green
}
catch {
    Write-Warning "Nao consegui gravar config/multicloud/manifest.json (precisa de Storage Blob Data Contributor). Faca upload manual de um arquivo com o conteudo {} . Erro: $($_.Exception.Message)"
}

# 5.2 inicia os triggers criados pelo Bicep (nascem parados)
if ($awsEnabled) {
    $triggers = @('mc_aws_DailySchedule')
    if ($AwsRecommendations) { $triggers += 'mc_aws_RecommendationsDailySchedule' }
    foreach ($t in $triggers) {
        Start-AzDataFactoryV2Trigger -ResourceGroupName $ResourceGroup -DataFactoryName $hubAdf.DataFactoryName -Name $t -Force | Out-Null
        Write-Host "  Trigger $t iniciado." -ForegroundColor Green
    }
    # primeira carga imediata (mes atual + anterior)
    $run = Invoke-AzDataFactoryV2Pipeline -ResourceGroupName $ResourceGroup -DataFactoryName $hubAdf.DataFactoryName -PipelineName 'mc_aws_IngestFocus'
    Write-Host "  Primeira execucao da pipeline mc_aws_IngestFocus disparada (run $run)." -ForegroundColor Green
}

# ======================================================================================
Write-Step 'Etapa 6 de 7: codigo do conector OCI' 'publica a Function Python que le os FOCUS reports da OCI e grava parquet tipado no hub.'
# ======================================================================================
if ($ociEnabled -and -not $SkipFunctionPublish) {
    $src = Join-Path (Split-Path $root -Parent) 'functions/oci-connector'
    $zip = Join-Path ([IO.Path]::GetTempPath()) "oci-connector-$(Get-Date -Format yyyyMMddHHmmss).zip"
    Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip -Force
    az account set --subscription $SubscriptionId | Out-Null
    az functionapp deployment source config-zip -g $ResourceGroup -n $functionAppName --src $zip --build-remote true | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Falha no zip deploy. Alternativa: func azure functionapp publish <nome> (Azure Functions Core Tools).' }
    else { Write-Host '  Function publicada. Primeira execucao ocorre no horario agendado (06:30 UTC); para testar agora use a aba Code + Test > Test/Run.' -ForegroundColor Green }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

# ======================================================================================
Write-Step 'Etapa 7 de 7: resumo e passos manuais' 'o que so pode ser feito na interface do Fabric, AWS e OCI.'
# ======================================================================================
Write-Host ''
Write-Host "  Hub          : $HubName  (modo $Mode)"
Write-Host "  Storage      : $($hubStorage.StorageAccountName)  |  DFS: $($hubStorage.PrimaryEndpoints.Dfs)"
Write-Host "  Data Factory : $($hubAdf.DataFactoryName)"
Write-Host "  Identidade   : $($hubAdf.Identity.PrincipalId)"

# --------------------------------------------------------------------------------------
# Verificacao: exports criados e arquivos ja gravados. Evita a duvida "deu certo ou nao?".
# --------------------------------------------------------------------------------------
Write-Host ''
Write-Host '  VERIFICACAO' -ForegroundColor Cyan
foreach ($scope in $ScopesToMonitor) {
    try {
        $exports = @(Get-FinOpsCostExport -Scope $scope -ErrorAction Stop)
        if ($exports.Count -gt 0) {
            Write-Host "    Exports em $scope :" -ForegroundColor Green
            $exports | ForEach-Object { Write-Host "      - $($_.Name)  [$($_.Dataset) $($_.DatasetVersion), $($_.ScheduleFrequency)]" -ForegroundColor DarkGray }
            Write-Host "      No portal: Cost Management > Exports, com o SELETOR DE ESCOPO na assinatura (nao no management group)." -ForegroundColor DarkGray
        }
        else { Write-Warning "Nenhum export encontrado em $scope. Rode a pipeline config_ConfigureExports ou use ManualExports." }
    }
    catch { Write-Warning "Nao consegui listar os exports de $scope : $($_.Exception.Message)" }
}
# O papel de DADOS no storage nao e herdado de Owner nem de Contributor. Concede a quem esta rodando o script,
# porque e o mesmo papel exigido pelo Power BI para ler os arquivos.
try {
    $acct = (Get-AzContext).Account
    $meId = if ($acct.Type -eq 'User') { (Get-AzADUser -UserPrincipalName $acct.Id -ErrorAction Stop).Id }
            else { (Get-AzADServicePrincipal -ApplicationId $acct.Id -ErrorAction Stop).Id }
    $temDados = Get-AzRoleAssignment -ObjectId $meId -Scope $hubStorage.Id -ErrorAction SilentlyContinue |
                    Where-Object { $_.RoleDefinitionName -in @('Storage Blob Data Reader', 'Storage Blob Data Contributor', 'Storage Blob Data Owner') }
    if (-not $temDados) {
        New-AzRoleAssignment -ObjectId $meId -RoleDefinitionName 'Storage Blob Data Contributor' -Scope $hubStorage.Id -ErrorAction Stop | Out-Null
        Write-Host "    Concedido a voce: Storage Blob Data Contributor em $($hubStorage.StorageAccountName) (mesmo papel que o Power BI exige)." -ForegroundColor Green
        Start-Sleep -Seconds 20
    }
}
catch {
    Write-Warning "Nao consegui conceder a voce acesso de dados no storage: $($_.Exception.Message)"
    Write-Warning "Conceda a si mesmo 'Storage Blob Data Reader' em $($hubStorage.StorageAccountName) antes de abrir o Power BI."
}

try {
    $sctxCheck = New-AzStorageContext -StorageAccountName $hubStorage.StorageAccountName -UseConnectedAccount
    foreach ($c in @('msexports', 'ingestion')) {
        $blobs = @(Get-AzStorageBlob -Container $c -Context $sctxCheck -MaxCount 200 -ErrorAction Stop)
        if ($blobs.Count -gt 0) { Write-Host "    Container $c : $($blobs.Count) arquivo(s). Exemplo: $($blobs[0].Name)" -ForegroundColor Green }
        else { Write-Host "    Container $c : vazio por enquanto (os exports levam de 15 a 60 minutos para a primeira carga)." -ForegroundColor DarkGray }
    }
}
catch {
    Write-Warning "Nao consegui ler os containers do storage. Conceda a si mesmo 'Storage Blob Data Reader' em $($hubStorage.StorageAccountName) (esse papel nao e herdado de Owner)."
}
if ($Mode -eq 'Fabric') {
    Write-Host ''
    Write-Host '  FABRIC (fazer uma vez):' -ForegroundColor Yellow
    Write-Host "    1. No Eventhouse, banco Ingestion, rode:  .add database Ingestion admins ('aadapp=$($hubAdf.Identity.PrincipalId)')"
    Write-Host "    2. No banco Hub, rode:                    .add database Hub admins ('aadapp=$($hubAdf.Identity.PrincipalId)')"
    Write-Host '    3. Rode kql/01-multicloud-functions.kql no banco Hub (funcoes CostsMulticloud, CostsAllocated, CostAnomalies, RecommendationsAll).'
    Write-Host '    4. Importe dashboards/finops-multicloud-realtime-dashboard.json (Real-Time Dashboard > Manage > Replace with file) e aponte a fonte para o banco Hub.'
}
else {
    # ----------------------------------------------------------------------------------
    # Valores prontos para colar no Power BI. Este bloco existe porque os tres erros mais
    # comuns do nivel 0 sao: URL sem o container ingestion, Number of Months vazio ou menor
    # que o historico disponivel, e tipo de credencial errado nas fontes publicas.
    # ----------------------------------------------------------------------------------
    $pbiUrl = "https://$($hubStorage.StorageAccountName).dfs.core.windows.net/ingestion"
    try {
        $outDep = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroup -ErrorAction Stop |
                    Where-Object { $_.Outputs -and $_.Outputs.Keys -contains 'storageUrlForPowerBI' } |
                    Sort-Object Timestamp -Descending | Select-Object -First 1
        if ($outDep) { $pbiUrl = $outDep.Outputs['storageUrlForPowerBI'].Value }
    } catch { }

    # Number of Months conta MESES FECHADOS. Deixar vazio faz o filtro de data virar null e o
    # relatorio carrega ZERO linhas sem dar erro. Por isso calculamos um numero concreto.
    $mesesSugeridos = $BackfillMonths
    try {
        $pastas = @(Get-AzStorageBlob -Container ingestion -Context $sctxCheck -Blob 'Costs/*' -ErrorAction Stop |
                        Where-Object { $_.Name -like '*.parquet' } |
                        ForEach-Object { ($_.Name -split '/')[1..2] -join '-' } | Sort-Object -Unique)
        if ($pastas.Count -gt 0) { $mesesSugeridos = [Math]::Max($pastas.Count, $BackfillMonths) }
    } catch { }
    if ($mesesSugeridos -lt 1) { $mesesSugeridos = 6 }

    Write-Host ''
    Write-Host ('-' * 100) -ForegroundColor Yellow
    Write-Host '  POWER BI: copie os valores abaixo' -ForegroundColor Yellow
    Write-Host ('-' * 100) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  1. Baixe PowerBI-storage.zip em https://github.com/microsoft/finops-toolkit/releases/latest'
    Write-Host '     (PowerBI-kql.zip e para o nivel 1; PowerBI-demo.zip tem dados de exemplo)'
    Write-Host ''
    Write-Host '  2. Abra CostSummary.pbit e preencha:'
    Write-Host ''
    Write-Host '     Storage URL      : ' -NoNewline; Write-Host $pbiUrl -ForegroundColor Green
    Write-Host '     Number of Months : ' -NoNewline; Write-Host $mesesSugeridos -ForegroundColor Green
    Write-Host '     RangeStart/End   : ' -NoNewline; Write-Host '(deixe vazios)' -ForegroundColor Green
    Write-Host ''
    Write-Host '     ATENCAO: a URL precisa terminar em /ingestion. Sem o container o relatorio abre VAZIO, sem erro.'
    Write-Host '     ATENCAO: nao deixe Number of Months vazio. Vazio zera o filtro de data e o relatorio abre VAZIO, sem erro.'
    Write-Host ''
    Write-Host '  3. Credenciais (a caixa Access Web content aparece varias vezes; leia a URL do topo):'
    Write-Host ''
    Write-Host '     https://github.com/...                    -> Anonymous'
    Write-Host '     https://ccmstorageprod.blob.core.../*.csv -> Anonymous'
    Write-Host "     https://$($hubStorage.StorageAccountName).dfs.core.windows.net" -NoNewline
    Write-Host '   -> Organizational account (aplique no nivel da RAIZ, sem /ingestion)'
    Write-Host '     https://management.azure.com/...          -> Organizational account'
    Write-Host ''
    Write-Host '  4. Tema: View > Themes > Browse for themes > dashboards/powerbi/FinOps-Multicloud-Theme.json'
    Write-Host ''
    Write-Host '  5. Valide pelas abas DQ e Summary. As abas Purchases, Prices, Inventory e Regions ficam vazias'
    Write-Host '     sem reservas, price sheet e Azure Resource Graph. Isso e esperado.'
    Write-Host ''
    Write-Host ('-' * 100) -ForegroundColor Yellow
}
if ($awsEnabled) {
    Write-Host ''
    Write-Host '  AWS: confirme que o Data Export FOCUS ja entregou arquivos em s3://' -NoNewline -ForegroundColor Yellow
    Write-Host "$AwsBucketName/$AwsS3Prefix/$AwsExportName/data/BILLING_PERIOD=yyyy-MM/ (aws/focus-export-cloudformation.yaml)."
}
if ($ociEnabled) {
    Write-Host ''
    Write-Host '  OCI: confirme a policy "endorse group <grupo> to read objects in tenancy usage-report" e a API key do usuario (oci/README-oci.md).' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  Concluido. Acompanhe a ingestao no relatorio Data ingestion (Power BI) ou na tabela Costs (x_SourceProvider, x_IngestionTime).' -ForegroundColor Green
