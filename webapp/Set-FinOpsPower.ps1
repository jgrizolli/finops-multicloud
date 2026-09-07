<#
.SYNOPSIS
    Desliga, liga ou mostra o estado do ambiente FinOps Multicloud, para pagar so quando estiver usando.

.DESCRIPTION
    Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer. Baseado no Microsoft FinOps toolkit.

    O que custa dinheiro parado, e o que este script faz com cada item:

      Componente                          Custo parado (aprox.)      Stop -Level Light        Stop -Level Deep
      ----------------------------------  -------------------------  -----------------------  -----------------------------
      Container App (1 replica sempre)    US$ 15 a 20 / mes          para (0 replicas, US$ 0) apaga app e ambiente
      Container Registry Basic            US$ 5 / mes (fixo)         mantem                   apaga (imagem e reconstruida)
      Storage de estado (Table)           centavos                   mantem                   mantem (seus cadastros ficam)
      Log Analytics + App Insights        primeiros 5 GB gratis      mantem                   mantem
      Communication Services (e-mail)     US$ 0 parado               mantem                   mantem
      App Service B1 (se for esse modelo) US$ 13 / mes MESMO PARADO  para o site e AVISA       apaga plano e site
      FinOps hub: storage + Data Factory  US$ 2 a 4 / mes            mantem (opcao -PauseHub) mantem (opcao -PauseHub)

    Light (padrao): volta em segundos (Start). Sobra ~US$ 5/mes do registry.
    Deep: volta com o instalador (10 a 15 min). Sobra so o hub.
    -PauseHub: pausa os gatilhos do Data Factory do hub. Economiza ~US$ 2/mes, mas o dado PARA de ser ingerido;
               ao religar, o mes corrente se recompoe no proximo export diario e meses anteriores exigem backfill.
               Recomendado NAO pausar o hub: o custo e pequeno e o historico continua sendo coletado.

.EXAMPLE
    ./Set-FinOpsPower.ps1 -Action Status -ResourceGroup rg-finops-hub
    ./Set-FinOpsPower.ps1 -Action Stop   -ResourceGroup rg-finops-hub
    ./Set-FinOpsPower.ps1 -Action Start  -ResourceGroup rg-finops-hub
    ./Set-FinOpsPower.ps1 -Action Stop   -ResourceGroup rg-finops-hub -Level Deep
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateSet('Status', 'Stop', 'Start')] [string] $Action,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    # Resource group do hub, se for diferente do da interface.
    [string] $HubResourceGroup,
    [ValidateSet('AppService', 'ContainerApps', 'ContainerApp', 'ACA')]
    [string] $HostingModel = 'ContainerApps',
    [string] $AppName = 'finops-web',
    [string] $SubscriptionId,
    [ValidateSet('Light', 'Deep')] [string] $Level = 'Light',
    # Tambem pausa (Stop) ou retoma (Start) os gatilhos do Data Factory do hub.
    [switch] $PauseHub
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($HostingModel -ne 'AppService') { $HostingModel = 'ContainerApps' }
$env:PYTHONIOENCODING = 'utf-8'; $env:PYTHONUTF8 = '1'
$baseAzure = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
$env:AZURE_EXTENSION_DIR = Join-Path $baseAzure 'cliextensions-finops'
if (-not $HubResourceGroup) { $HubResourceGroup = $ResourceGroup }

function Passo([string] $t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok([string] $t) { Write-Host "  OK   $t" -ForegroundColor Green }
function Info([string] $t) { Write-Host "       $t" -ForegroundColor DarkGray }
function Aviso([string] $t) { Write-Host "  !    $t" -ForegroundColor Yellow }

foreach ($m in @('Az.Accounts', 'Az.Resources', 'Az.DataFactory')) {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Modulo $m nao encontrado. Rode: Install-Module $m -Scope CurrentUser" }
    Import-Module $m -ErrorAction Stop -WarningAction SilentlyContinue
}
if ($SubscriptionId) { Set-AzContext -Subscription $SubscriptionId | Out-Null; az account set --subscription $SubscriptionId --only-show-errors 2>$null | Out-Null }
$ctx = Get-AzContext
if (-not $ctx) { throw 'Nao esta logado no Azure. Rode: Connect-AzAccount' }
Info "Assinatura: $($ctx.Subscription.Name)"
if ($HostingModel -eq 'ContainerApps') { az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null }

# ---------------------------------------------------------------- inventario
Passo 'Inventario'
$app = $null; $registry = $null; $ambiente = $null; $plano = $null
if ($HostingModel -eq 'ContainerApps') {
    $app = az containerapp list -g $ResourceGroup --query "[?starts_with(name,'$AppName')] | [0]" -o json --only-show-errors 2>$null | ConvertFrom-Json
    $registry = az acr list -g $ResourceGroup --query "[?starts_with(name,'finopsacr')] | [0]" -o json --only-show-errors 2>$null | ConvertFrom-Json
    $ambiente = az containerapp env list -g $ResourceGroup --query "[?contains(name,'$AppName')] | [0]" -o json --only-show-errors 2>$null | ConvertFrom-Json
    if ($app) {
        $replicas = (az containerapp revision list -g $ResourceGroup -n $app.name --query "[?properties.active].properties.replicas" -o tsv --only-show-errors 2>$null | Measure-Object -Sum).Sum
        Info "Container App : $($app.name)  estado=$($app.properties.runningStatus)  replicas ativas=$replicas  imagem=$($app.properties.template.containers[0].image)"
    }
    else { Info "Container App : (nao existe em $ResourceGroup)" }
    Info ("Registry      : " + $(if ($registry) { "$($registry.name) (Basic, ~US$ 5/mes fixo)" } else { '(nao existe)' }))
    Info ("Ambiente ACA  : " + $(if ($ambiente) { $ambiente.name } else { '(nao existe)' }))
}
else {
    $site = Get-AzWebApp -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$AppName*" } | Select-Object -First 1
    if ($site) {
        $plano = Get-AzAppServicePlan -ResourceGroupName $ResourceGroup | Where-Object { $_.Id -eq $site.ServerFarmId } | Select-Object -First 1
        Info "App Service   : $($site.Name)  estado=$($site.State)  plano=$($plano.Name) ($($plano.Sku.Name))"
        Aviso 'App Service: o PLANO cobra mesmo com o site parado. Para custo zero, use -Level Deep (apaga plano e site) ou troque para F1.'
    }
    else { Info "App Service   : (nao existe em $ResourceGroup)" }
}
$adf = Get-AzDataFactoryV2 -ResourceGroupName $HubResourceGroup -ErrorAction SilentlyContinue | Where-Object { $_.DataFactoryName -like '*finops*' -or $_.DataFactoryName -like '*hub*' } | Select-Object -First 1
if ($adf) {
    $triggers = Get-AzDataFactoryV2Trigger -ResourceGroupName $HubResourceGroup -DataFactoryName $adf.DataFactoryName -ErrorAction SilentlyContinue
    $ativos = @($triggers | Where-Object { $_.RuntimeState -eq 'Started' }).Count
    Info "Hub (ADF)     : $($adf.DataFactoryName)  gatilhos ativos=$ativos de $(@($triggers).Count)"
}
else { Info "Hub (ADF)     : (nao encontrado em $HubResourceGroup)" }

if ($Action -eq 'Status') {
    Passo 'Custo estimado parado, por mes'
    $ligado = if ($HostingModel -eq 'ContainerApps') { ($app -and $app.properties.runningStatus -eq 'Running') } else { ($site -and $site.State -eq 'Running') }
    Info ("Interface web : " + $(if ($ligado) { 'LIGADA  (Container App ~US$ 15 a 20; App Service B1 ~US$ 13)' } else { 'PARADA  (US$ 0 de computacao)' }))
    Info ("Registry      : " + $(if ($registry) { '~US$ 5 (fixo enquanto existir)' } else { 'US$ 0' }))
    Info 'Estado, logs, e-mail: centavos (Log Analytics e App Insights: 5 GB/mes gratis)'
    Info ("Hub           : ~US$ 2 a 4 (Data Factory + storage)" + $(if ($adf -and $ativos -eq 0) { '  [gatilhos PAUSADOS: nao esta ingerindo]' } else { '' }))
    Write-Host ''
    Write-Host "  Desligar: ./Set-FinOpsPower.ps1 -Action Stop -ResourceGroup $ResourceGroup      (Light; -Level Deep para apagar registry e app)" -ForegroundColor DarkGray
    Write-Host "  Ligar   : ./Set-FinOpsPower.ps1 -Action Start -ResourceGroup $ResourceGroup" -ForegroundColor DarkGray
    return
}

# ---------------------------------------------------------------- STOP
if ($Action -eq 'Stop') {
    Passo "Desligando (nivel $Level)"
    if ($HostingModel -eq 'ContainerApps') {
        if ($app) {
            if ($Level -eq 'Light') {
                if ($PSCmdlet.ShouldProcess($app.name, 'parar o Container App')) {
                    az containerapp stop -g $ResourceGroup -n $app.name --only-show-errors -o none
                    if ($LASTEXITCODE -ne 0) { throw 'Falha ao parar o Container App.' }
                    Ok "Container App $($app.name) parado (0 replicas, computacao US$ 0). Volta em segundos com -Action Start."
                }
            }
            else {
                if ($PSCmdlet.ShouldProcess($app.name, 'APAGAR o Container App, o ambiente e o registry')) {
                    az containerapp delete -g $ResourceGroup -n $app.name --yes --only-show-errors -o none
                    Ok "Container App $($app.name) apagado."
                    if ($ambiente) { az containerapp env delete -g $ResourceGroup -n $ambiente.name --yes --only-show-errors -o none 2>$null; Ok "Ambiente $($ambiente.name) apagado." }
                    if ($registry) { az acr delete -g $ResourceGroup -n $registry.name --yes --only-show-errors -o none; Ok "Registry $($registry.name) apagado (US$ 5/mes a menos)." }
                    Aviso 'Mantidos: storage de estado (seus centros de custo, regras e alertas), Log Analytics, App Insights, Communication Services, app registration.'
                    Aviso 'Para voltar: ./Deploy-FinOpsWebApp.ps1 <mesmos parametros de antes> -HostingModel ContainerApps   (10 a 15 min)'
                }
            }
        }
        else { Aviso 'Nenhum Container App para parar.' }
    }
    else {
        if ($site) {
            if ($Level -eq 'Light') {
                if ($PSCmdlet.ShouldProcess($site.Name, 'parar o App Service')) {
                    Stop-AzWebApp -ResourceGroupName $ResourceGroup -Name $site.Name | Out-Null
                    Ok "App Service $($site.Name) parado."
                    Aviso "O plano $($plano.Name) ($($plano.Sku.Name)) CONTINUA cobrando (~US$ 13/mes no B1). Para zerar: -Level Deep, ou Set-AzAppServicePlan -Tier Free."
                }
            }
            else {
                if ($PSCmdlet.ShouldProcess($site.Name, 'APAGAR o App Service e o plano')) {
                    Remove-AzWebApp -ResourceGroupName $ResourceGroup -Name $site.Name -Force | Out-Null
                    if ($plano) { Remove-AzAppServicePlan -ResourceGroupName $ResourceGroup -Name $plano.Name -Force | Out-Null }
                    Ok 'App Service e plano apagados. Para voltar: ./Deploy-FinOpsWebApp.ps1 <mesmos parametros de antes>.'
                }
            }
        }
        else { Aviso 'Nenhum App Service para parar.' }
    }
    if ($PauseHub -and $adf) {
        foreach ($t in @($triggers | Where-Object { $_.RuntimeState -eq 'Started' })) {
            if ($PSCmdlet.ShouldProcess($t.Name, 'pausar gatilho do hub')) {
                Stop-AzDataFactoryV2Trigger -ResourceGroupName $HubResourceGroup -DataFactoryName $adf.DataFactoryName -Name $t.Name -Force | Out-Null
                Ok "Gatilho $($t.Name) pausado."
            }
        }
        Aviso 'Hub pausado: os exports do Cost Management continuam (sao gratuitos), mas nada e ingerido ate -Action Start -PauseHub.'
        Aviso 'Ao religar, o mes corrente se recompoe no proximo export diario; meses que passaram inteiros pausados exigem: Start-FinOpsCostExport -Backfill <n>.'
    }
    elseif (-not $PauseHub) {
        Info 'Hub mantido ligado (~US$ 2 a 4/mes): o historico continua sendo coletado todos os dias. Use -PauseHub para pausar tambem.'
    }
    Write-Host ''
    Write-Host "  Conferir: ./Set-FinOpsPower.ps1 -Action Status -ResourceGroup $ResourceGroup" -ForegroundColor DarkGray
    return
}

# ---------------------------------------------------------------- START
if ($Action -eq 'Start') {
    Passo 'Ligando'
    if ($HostingModel -eq 'ContainerApps') {
        if (-not $app) {
            Aviso 'O Container App nao existe (foi apagado com -Level Deep, ou nunca foi criado).'
            Aviso "Rode o instalador: ./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup $ResourceGroup -HostingModel ContainerApps -EnableAuth [-EnableEmail -AlertEmailTo ...] -Location <regiao>"
        }
        elseif ($PSCmdlet.ShouldProcess($app.name, 'iniciar o Container App')) {
            az containerapp start -g $ResourceGroup -n $app.name --only-show-errors -o none
            if ($LASTEXITCODE -ne 0) { throw 'Falha ao iniciar o Container App.' }
            $fqdn = $app.properties.configuration.ingress.fqdn
            Ok "Container App $($app.name) iniciando. URL: https://$fqdn"
            Info 'A primeira resposta leva de 20 a 60 s (o container sobe e le o dado do hub).'
        }
    }
    else {
        if (-not $site) { Aviso 'O App Service nao existe. Rode o instalador: ./Deploy-FinOpsWebApp.ps1 ...' }
        elseif ($PSCmdlet.ShouldProcess($site.Name, 'iniciar o App Service')) {
            Start-AzWebApp -ResourceGroupName $ResourceGroup -Name $site.Name | Out-Null
            Ok "App Service $($site.Name) iniciado. URL: https://$($site.DefaultHostName)"
        }
    }
    if ($PauseHub -and $adf) {
        foreach ($t in @($triggers | Where-Object { $_.RuntimeState -ne 'Started' })) {
            if ($PSCmdlet.ShouldProcess($t.Name, 'retomar gatilho do hub')) {
                Start-AzDataFactoryV2Trigger -ResourceGroupName $HubResourceGroup -DataFactoryName $adf.DataFactoryName -Name $t.Name -Force | Out-Null
                Ok "Gatilho $($t.Name) retomado."
            }
        }
        Aviso 'Se o hub ficou pausado por mais de um mes, complete o historico: Start-FinOpsCostExport -Name <export> -Backfill <meses> (docs/03-operacao-do-hub.md, secao 6.8).'
    }
    Write-Host ''
    Write-Host "  Conferir: ./Set-FinOpsPower.ps1 -Action Status -ResourceGroup $ResourceGroup   |   se a URL nao abrir: ./Diagnose-FinOpsWebApp.ps1 -ResourceGroup $ResourceGroup" -ForegroundColor DarkGray
}
