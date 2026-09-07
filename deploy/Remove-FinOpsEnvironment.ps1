<#
.SYNOPSIS
    Apaga o ambiente FinOps Multicloud (interface web, hub, ou tudo) deixando-o pronto para ser reinstalado do zero.

.DESCRIPTION
    Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer. Baseado no Microsoft FinOps toolkit.

    Tres acoes diferentes, e este script faz a terceira:
      DESLIGAR   (webapp/Set-FinOpsPower.ps1 -Action Stop)   para de pagar computacao, volta em segundos.
      APAGAR     (este script)                               remove os recursos; nao paga nada; reinstala em 25 a 40 min.
      REINSTALAR (deploy/Deploy-FinOpsMulticloud.ps1 e webapp/Deploy-FinOpsWebApp.ps1)

    O que "apagar" precisa cuidar, alem de deletar recursos, para a REINSTALACAO nao falhar:
      1. Exports do Cost Management vivem na ASSINATURA, nao no resource group. Sem remove-los, continuam tentando
         gravar em um storage que nao existe mais (e o instalador tenta criar outro com o mesmo nome).
      2. Key Vault apagado fica 90 dias em "soft delete" e BLOQUEIA a recriacao com o mesmo nome. Como os nomes do
         kit derivam do resource group, o proximo deploy usaria o mesmo nome. Este script faz o purge.
      3. Log Analytics apagado fica 14 dias em soft delete; e removido com -ForceDelete.
      4. O app registration do login (<app>-auth) fica no Entra ID. E reaproveitado pelo proximo deploy; use
         -RemoveAppRegistration para apagar tambem.
      5. Atribuicoes de papel de identidades apagadas ficam orfas (ObjectType = Unknown) fora do resource group;
         o script remove as que estao no escopo da assinatura e pertenciam ao hub.

    Escopos:
      -Scope Web   apaga so a interface web (Container App ou App Service, registry, storage de estado, e-mail,
                   logs) e mantem o hub e o dado.
      -Scope Hub   apaga o hub (Remove-FinOpsHub) e os exports; mantem a interface (que ficara sem dado).
      -Scope All   apaga o resource group inteiro e tudo o que esta ligado a ele. E o caminho para "recomecar do zero".

    Sempre pede confirmacao (digite o nome do resource group), a menos que -Force. -WhatIf mostra sem apagar.

.EXAMPLE
    ./Remove-FinOpsEnvironment.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Scope All
    # depois:
    ./Deploy-FinOpsMulticloud.ps1 -ParametersFile ./parameters.json
    ../webapp/Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -EnableAuth -HostingModel ContainerApps -Location eastus2

.EXAMPLE
    # So a interface web, mantendo o hub e o historico de custo
    ./Remove-FinOpsEnvironment.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Scope Web
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [ValidateSet('Web', 'Hub', 'All')] [string] $Scope,
    # Resource group do hub, se a interface estiver em outro.
    [string] $HubResourceGroup,
    [string] $HubName = 'finops-hub',
    [string] $AppName = 'finops-web',
    # Manter o storage do hub (o historico de custo em parquet). Vale para -Scope Hub e All.
    [switch] $KeepHubStorage,
    # Apagar tambem o app registration do login no Entra ID.
    [switch] $RemoveAppRegistration,
    # Nao pedir a confirmacao digitada.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:PYTHONIOENCODING = 'utf-8'; $env:PYTHONUTF8 = '1'
$baseAzure = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
$env:AZURE_EXTENSION_DIR = Join-Path $baseAzure 'cliextensions-finops'
if (-not $HubResourceGroup) { $HubResourceGroup = $ResourceGroup }

function Passo([string] $t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok([string] $t) { Write-Host "  OK   $t" -ForegroundColor Green }
function Info([string] $t) { Write-Host "       $t" -ForegroundColor DarkGray }
function Aviso([string] $t) { Write-Host "  !    $t" -ForegroundColor Yellow }

foreach ($m in @('Az.Accounts', 'Az.Resources', 'Az.Storage', 'Az.KeyVault', 'Az.OperationalInsights')) {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Modulo $m nao encontrado. Rode: Install-Module $m -Scope CurrentUser" }
    Import-Module $m -ErrorAction Stop -WarningAction SilentlyContinue
}
$temToolkit = [bool](Get-Module -ListAvailable -Name FinOpsToolkit)
if ($temToolkit) { Import-Module FinOpsToolkit -ErrorAction SilentlyContinue -WarningAction SilentlyContinue }

if (-not (Get-AzContext)) { Connect-AzAccount -Subscription $SubscriptionId | Out-Null }
Set-AzContext -Subscription $SubscriptionId | Out-Null
$ctx = Get-AzContext
az account set --subscription $SubscriptionId --only-show-errors 2>$null | Out-Null
Info "Assinatura: $($ctx.Subscription.Name) ($SubscriptionId)"

$rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) { Aviso "O resource group $ResourceGroup nao existe. Nada a apagar aqui."; }

# ---------------------------------------------------------------- inventario
Passo "Inventario do que sera apagado (escopo: $Scope)"
$recursos = if ($rg) { @(Get-AzResource -ResourceGroupName $ResourceGroup) } else { @() }
$hubStorage = $null
foreach ($sa in @(Get-AzStorageAccount -ResourceGroupName $HubResourceGroup -ErrorAction SilentlyContinue)) {
    try {
        $c = New-AzStorageContext -StorageAccountName $sa.StorageAccountName -UseConnectedAccount
        $nomes = (Get-AzStorageContainer -Context $c -ErrorAction Stop).Name
        if ($nomes -contains 'ingestion' -and $nomes -contains 'msexports') { $hubStorage = $sa.StorageAccountName; break }
    }
    catch { continue }
}
$ehWeb = { param($r) ($r.Name -like "$AppName*") -or ($r.Name -like 'finopsweb*') -or ($r.Name -like 'finopsacr*') }
$recWeb = @($recursos | Where-Object { & $ehWeb $_ })
$recHub = @($recursos | Where-Object { -not (& $ehWeb $_) })

switch ($Scope) {
    'Web' { $alvo = $recWeb }
    'Hub' { $alvo = $recHub }
    'All' { $alvo = $recursos }
}
if ($alvo.Count -eq 0 -and $rg) { Aviso 'Nenhum recurso encontrado para este escopo.' }
$alvo | Sort-Object ResourceType, Name | ForEach-Object { Info ("{0,-55} {1}" -f $_.ResourceType, $_.Name) }

$exports = @()
if ($Scope -in 'Hub', 'All') {
    $escopoSub = "/subscriptions/$SubscriptionId"
    if ($temToolkit) {
        try {
            $todos = @(Get-FinOpsCostExport -Scope $escopoSub -ErrorAction Stop)
            $exports = @($todos | Where-Object { ($_.Name -like 'ftk-*') -or ($hubStorage -and "$($_.StorageAccountId)" -like "*/$hubStorage") })
        }
        catch { Aviso "Nao consegui listar os exports do Cost Management: $($_.Exception.Message)" }
    }
    else {
        Aviso 'Modulo FinOpsToolkit nao instalado: os exports do Cost Management nao serao removidos automaticamente (Install-Module FinOpsToolkit).'
    }
    if ($exports.Count -gt 0) {
        Info ''
        Info 'Exports do Cost Management (escopo da assinatura) que apontam para o hub:'
        $exports | ForEach-Object { Info ("  export  {0}" -f $_.Name) }
    }
}
$appRegs = @()
if ($Scope -in 'Web', 'All') {
    $appRegs = @(az ad app list --display-name "$AppName" --query "[?ends_with(displayName, '-auth')].{appId:appId, nome:displayName}" -o json --only-show-errors 2>$null | ConvertFrom-Json)
    if ($appRegs.Count -gt 0) {
        Info ''
        Info ("App registration do login: " + (($appRegs | ForEach-Object { $_.nome }) -join ', ') + $(if ($RemoveAppRegistration) { '  [sera apagado]' } else { '  [mantido; use -RemoveAppRegistration para apagar]' }))
    }
}
if ($KeepHubStorage -and $hubStorage) { Aviso "O storage do hub ($hubStorage) sera MANTIDO (-KeepHubStorage): o historico de custo fica guardado." }

# ---------------------------------------------------------------- confirmacao
if (-not $Force -and -not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Isto apaga os recursos acima. Para confirmar, digite o nome do resource group ($ResourceGroup):" -ForegroundColor Yellow
    $digitado = Read-Host '  >'
    if ($digitado -ne $ResourceGroup) { throw 'Confirmacao nao bateu. Nada foi apagado.' }
}

# ---------------------------------------------------------------- 1. exports (antes do storage sumir)
if ($exports.Count -gt 0) {
    Passo 'Removendo os exports do Cost Management'
    foreach ($e in $exports) {
        if ($PSCmdlet.ShouldProcess($e.Name, 'remover export do Cost Management')) {
            try { Remove-FinOpsCostExport -Name $e.Name -Scope "/subscriptions/$SubscriptionId" -ErrorAction Stop | Out-Null; Ok "export $($e.Name) removido" }
            catch { Aviso "export $($e.Name): $($_.Exception.Message)" }
        }
    }
}

# ---------------------------------------------------------------- 2. recursos
if ($Scope -eq 'All' -and $rg) {
    Passo "Apagando o resource group $ResourceGroup inteiro"
    if ($KeepHubStorage -and $hubStorage) {
        # Apagar tudo menos o storage: remove recurso a recurso, storage por ultimo e preservado.
        foreach ($r in ($alvo | Where-Object { $_.Name -ne $hubStorage } | Sort-Object { $_.ResourceType -like 'Microsoft.Web/serverfarms' -or $_.ResourceType -like 'Microsoft.App/managedEnvironments' })) {
            if ($PSCmdlet.ShouldProcess($r.Name, "apagar $($r.ResourceType)")) {
                try { Remove-AzResource -ResourceId $r.ResourceId -Force -ErrorAction Stop | Out-Null; Ok "$($r.Name) apagado" }
                catch { Aviso "$($r.Name): $($_.Exception.Message)" }
            }
        }
        Ok "Storage $hubStorage mantido com o historico."
    }
    elseif ($PSCmdlet.ShouldProcess($ResourceGroup, 'apagar o resource group e tudo dentro')) {
        Remove-AzResourceGroup -Name $ResourceGroup -Force | Out-Null
        Ok "Resource group $ResourceGroup apagado."
    }
}
elseif ($Scope -eq 'Hub' -and $rg) {
    Passo "Apagando o hub $HubName"
    $feito = $false
    if ($temToolkit) {
        if ($PSCmdlet.ShouldProcess($HubName, 'Remove-FinOpsHub')) {
            try {
                if ($KeepHubStorage) { Remove-FinOpsHub -Name $HubName -ResourceGroup $HubResourceGroup -KeepStorageAccount -ErrorAction Stop | Out-Null }
                else { Remove-FinOpsHub -Name $HubName -ResourceGroup $HubResourceGroup -ErrorAction Stop | Out-Null }
                $feito = $true; Ok 'Remove-FinOpsHub concluido.'
            }
            catch { Aviso "Remove-FinOpsHub falhou ($($_.Exception.Message)); apagando recurso a recurso." }
        }
    }
    if (-not $feito) {
        foreach ($r in ($recHub | Where-Object { -not ($KeepHubStorage -and $_.Name -eq $hubStorage) })) {
            if ($PSCmdlet.ShouldProcess($r.Name, "apagar $($r.ResourceType)")) {
                try { Remove-AzResource -ResourceId $r.ResourceId -Force -ErrorAction Stop | Out-Null; Ok "$($r.Name) apagado" }
                catch { Aviso "$($r.Name): $($_.Exception.Message)" }
            }
        }
    }
}
elseif ($Scope -eq 'Web' -and $rg) {
    Passo 'Apagando a interface web'
    # Ordem: apps antes de planos e ambientes; storage e registry por ultimo.
    $ordem = @('Microsoft.Web/sites', 'Microsoft.App/containerApps', 'Microsoft.Web/serverfarms', 'Microsoft.App/managedEnvironments',
               'Microsoft.Communication/communicationServices', 'Microsoft.Communication/emailServices', 'Microsoft.Insights/components',
               'Microsoft.OperationalInsights/workspaces', 'Microsoft.ContainerRegistry/registries', 'Microsoft.Storage/storageAccounts')
    $ordenados = $recWeb | Sort-Object { $i = $ordem.IndexOf($_.ResourceType); if ($i -lt 0) { 99 } else { $i } }
    foreach ($r in $ordenados) {
        if ($PSCmdlet.ShouldProcess($r.Name, "apagar $($r.ResourceType)")) {
            try {
                if ($r.ResourceType -eq 'Microsoft.OperationalInsights/workspaces') {
                    Remove-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup -Name $r.Name -ForceDelete -Force -ErrorAction Stop | Out-Null
                }
                else { Remove-AzResource -ResourceId $r.ResourceId -Force -ErrorAction Stop | Out-Null }
                Ok "$($r.Name) apagado"
            }
            catch { Aviso "$($r.Name): $($_.Exception.Message)" }
        }
    }
}

# ---------------------------------------------------------------- 3. soft delete: Key Vault e Log Analytics
if ($Scope -in 'Hub', 'All') {
    Passo 'Limpando o que fica em soft delete (bloquearia a reinstalacao com os mesmos nomes)'
    $kvs = @(Get-AzKeyVault -InRemovedState -ErrorAction SilentlyContinue | Where-Object { $_.VaultName -like 'finops*' -or $_.VaultName -like "*$HubName*" })
    foreach ($kv in $kvs) {
        if ($PSCmdlet.ShouldProcess($kv.VaultName, 'purge do Key Vault em soft delete')) {
            try { Remove-AzKeyVault -VaultName $kv.VaultName -Location $kv.Location -InRemovedState -Force -ErrorAction Stop | Out-Null; Ok "Key Vault $($kv.VaultName) purgado" }
            catch { Aviso "Key Vault $($kv.VaultName): $($_.Exception.Message) (pode precisar do papel Key Vault Contributor ou de 'purge protection' desligado)" }
        }
    }
    if ($kvs.Count -eq 0) { Info 'Nenhum Key Vault em soft delete.' }
}
if ($Scope -in 'Web', 'All') {
    $las = @(Get-AzOperationalInsightsDeletedWorkspace -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$AppName*" -or $_.Name -like "*$HubName*" })
    foreach ($la in $las) {
        Info "Log Analytics em soft delete: $($la.Name) (recuperado automaticamente se o proximo deploy usar o mesmo nome; expira em 14 dias)"
    }
}

# ---------------------------------------------------------------- 4. app registration
if ($RemoveAppRegistration -and $appRegs.Count -gt 0) {
    Passo 'Apagando o app registration do login'
    foreach ($a in $appRegs) {
        if ($PSCmdlet.ShouldProcess($a.nome, 'apagar app registration')) {
            az ad app delete --id $a.appId --only-show-errors 2>$null
            Ok "$($a.nome) apagado"
        }
    }
}

# ---------------------------------------------------------------- 5. atribuicoes orfas na assinatura
if ($Scope -in 'Hub', 'All') {
    Passo 'Atribuicoes de papel orfas no escopo da assinatura'
    $orfas = @(Get-AzRoleAssignment -Scope "/subscriptions/$SubscriptionId" -ErrorAction SilentlyContinue |
               Where-Object { $_.ObjectType -eq 'Unknown' -and $_.Scope -eq "/subscriptions/$SubscriptionId" })
    if ($orfas.Count -eq 0) { Info 'Nenhuma.' }
    else {
        Aviso "$($orfas.Count) atribuicao(oes) orfa(s) (identidade apagada) no escopo da assinatura. Nao removo automaticamente porque podem ser de outros sistemas."
        Aviso 'Se quiser limpar as que eram do hub, rode e revise antes:'
        Aviso "  Get-AzRoleAssignment -Scope /subscriptions/$SubscriptionId | Where-Object ObjectType -eq 'Unknown' | Format-Table RoleDefinitionName, ObjectId"
    }
}

# ---------------------------------------------------------------- resumo
Write-Host ''
Write-Host ('=' * 100) -ForegroundColor Green
Write-Host "  APAGADO (escopo $Scope)" -ForegroundColor Green
Write-Host ('=' * 100) -ForegroundColor Green
Write-Host ''
Write-Host '  Para reinstalar, na ordem:' -ForegroundColor Yellow
if ($Scope -in 'Hub', 'All') {
    Write-Host "    1. .\Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json        (hub; 15 a 25 min; os exports sao recriados e o backfill trazido)" -ForegroundColor Cyan
    Write-Host "    2. .\Repair-FocusVersion.ps1 ...   somente se for usar os relatorios Power BI no modo Storage (o instalador ja faz isso por padrao)" -ForegroundColor DarkGray
}
if ($Scope -in 'Web', 'All') {
    Write-Host "    3. ..\webapp\Deploy-FinOpsWebApp.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -EnableAuth -EnableEmail -AlertEmailTo <email> -HostingModel ContainerApps -Location <regiao>   (10 a 15 min)" -ForegroundColor Cyan
    Write-Host "    4. ..\webapp\Set-FinOpsWebAuth.ps1 -ResourceGroup $ResourceGroup -HostingModel ContainerApps   (so se a etapa 6 do instalador avisar que o login nao ficou ativo)" -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  O dado do Azure leva de 30 min a 24 h para aparecer depois da reinstalacao do hub (export + ingestao). Confira em <url>/api/status.' -ForegroundColor DarkGray
Write-Host ''
