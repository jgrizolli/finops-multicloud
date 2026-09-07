<#
.SYNOPSIS
    Diagnostica por que a interface web do FinOps Multicloud nao abre (Container Apps ou App Service).

.DESCRIPTION
    Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer. Baseado no Microsoft FinOps toolkit.

    Faz, em ordem, as verificacoes que separam as causas mais comuns de "a URL nao abre":
      1. DNS e TCP 443 a partir da sua maquina (rede local, proxy, VPN)
      2. Estado do Container App: revisao mais nova, revisao pronta, replicas, porta de ingress, imagem
      3. Health check sem login (/api/health) e raiz (/) com o codigo HTTP real
      4. Configuracao de autenticacao (Easy Auth) e caminhos excluidos
      5. Ultimas linhas dos logs de sistema e do console (erro de imagem, de pull, de inicializacao)
    Nao altera nada. Ao final, imprime o veredito e o comando de correcao quando ha um conhecido.

.EXAMPLE
    ./Diagnose-FinOpsWebApp.ps1 -ResourceGroup rg-finops-hub -HostingModel ContainerApps
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [ValidateSet('AppService', 'ContainerApps', 'ContainerApp', 'ACA')]
    [string] $HostingModel = 'ContainerApps',
    [string] $AppName = 'finops-web',
    [string] $SubscriptionId
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
if ($HostingModel -ne 'AppService') { $HostingModel = 'ContainerApps' }
$env:PYTHONIOENCODING = 'utf-8'; $env:PYTHONUTF8 = '1'
$baseAzure = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
$env:AZURE_EXTENSION_DIR = Join-Path $baseAzure 'cliextensions-finops'   # mesma pasta isolada do instalador

function Titulo([string] $t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok([string] $t) { Write-Host "  OK   $t" -ForegroundColor Green }
function Ruim([string] $t) { Write-Host "  X    $t" -ForegroundColor Red }
function Info([string] $t) { Write-Host "       $t" -ForegroundColor DarkGray }

$veredito = @()
if ($SubscriptionId) { az account set --subscription $SubscriptionId --only-show-errors 2>$null | Out-Null }

# ---------------------------------------------------------------- descobrir a app
Titulo 'Aplicacao'
if ($HostingModel -eq 'ContainerApps') {
    az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null
    $app = az containerapp list -g $ResourceGroup --query "[?starts_with(name,'$AppName')] | [0]" -o json --only-show-errors 2>$null | ConvertFrom-Json
    if (-not $app) { Ruim "Nenhum Container App com prefixo '$AppName' em $ResourceGroup."; return }
    $nomeApp = $app.name
    $fqdn = $app.properties.configuration.ingress.fqdn
    $porta = $app.properties.configuration.ingress.targetPort
    $externo = $app.properties.configuration.ingress.external
    $imagem = $app.properties.template.containers[0].image
    $revNova = $app.properties.latestRevisionName
    $revPronta = $app.properties.latestReadyRevisionName
    $estado = $app.properties.runningStatus
    $provisionamento = $app.properties.provisioningState
    Ok "$nomeApp  (provisionamento: $provisionamento, execucao: $estado)"
    Info "URL     : https://$fqdn"
    Info "Imagem  : $imagem"
    Info "Ingress : externo=$externo, porta de destino=$porta"
    Info "Revisao : mais nova=$revNova | pronta=$revPronta"

    if ($imagem -like 'mcr.microsoft.com/k8se/quickstart*') {
        Ruim 'A app ainda roda a IMAGEM DE ESPERA. A etapa 5 do instalador nao trocou a imagem.'
        $veredito += 'Rode de novo: ./Deploy-FinOpsWebApp.ps1 ... -HostingModel ContainerApps -CodeOnly'
    }
    if ($porta -ne 8000 -and $imagem -notlike 'mcr.microsoft.com/k8se/quickstart*') {
        Ruim "Porta de ingress e $porta, mas a interface escuta na 8000: o ingress nao alcanca o container."
        $veredito += "az containerapp ingress update -g $ResourceGroup -n $nomeApp --target-port 8000"
    }
    if (-not $externo) {
        Ruim 'Ingress nao e externo: a URL so responde de dentro do ambiente.'
        $veredito += "az containerapp ingress enable -g $ResourceGroup -n $nomeApp --type external --target-port 8000 --transport auto"
    }
    if ($revNova -ne $revPronta) {
        Ruim "A revisao mais nova ($revNova) NAO esta pronta. A pronta e $revPronta (pode ser a imagem antiga)."
    }

    Titulo 'Revisoes e replicas'
    $revs = az containerapp revision list -g $ResourceGroup -n $nomeApp -o json --only-show-errors 2>$null | ConvertFrom-Json
    foreach ($r in $revs) {
        $p = $r.properties
        $linha = "$($r.name): ativa=$($p.active) trafego=$($p.trafficWeight)% saude=$($p.healthState) provisionamento=$($p.provisioningState) execucao=$($p.runningState) replicas=$($p.replicas)"
        if ($p.active -and $p.healthState -eq 'Healthy' -and $p.replicas -ge 1) { Ok $linha } else { Info $linha }
        if ($p.active -and $p.replicas -eq 0) {
            Ruim "  revisao ativa com ZERO replicas (escala a zero ou falha ao subir)."
        }
        if ($p.provisioningState -eq 'Failed' -or $p.runningState -in @('Failed', 'Degraded')) {
            Ruim "  revisao com falha. Ver logs de sistema abaixo (pull da imagem? porta? crash na inicializacao?)."
        }
    }

    Titulo 'Autenticacao (Easy Auth)'
    $auth = az containerapp auth show -g $ResourceGroup -n $nomeApp -o json --only-show-errors 2>$null | ConvertFrom-Json
    if ($auth) {
        $hab = $auth.platform.enabled
        $acao = $auth.globalValidation.unauthenticatedClientAction
        $excl = $auth.globalValidation.excludedPaths -join ', '
        $cid = $auth.identityProviders.azureActiveDirectory.registration.clientId
        $iss = $auth.identityProviders.azureActiveDirectory.registration.openIdIssuer
        Info "habilitada=$hab acao=$acao excluidos=[$excl]"
        Info "clientId=$cid issuer=$iss"
        if ($hab -and -not $cid) { Ruim 'Autenticacao ligada SEM provedor configurado: toda requisicao vai falhar.'; $veredito += "Desligue temporariamente: az containerapp auth update -g $ResourceGroup -n $nomeApp --enabled false" }
        if ($hab -and $excl -notmatch '/api/health') { Ruim '/api/health nao esta fora do login: o health check e a validacao exigem conta.' }
    }
    else { Info 'Sem configuracao de autenticacao (URL publica).' }
}
else {
    $site = Get-AzWebApp -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like "$AppName*" } | Select-Object -First 1
    if (-not $site) { Ruim "Nenhum App Service com prefixo '$AppName' em $ResourceGroup."; return }
    $nomeApp = $site.Name; $fqdn = $site.DefaultHostName
    Ok "$nomeApp (estado: $($site.State))"
    Info "URL: https://$fqdn"
    if ($site.State -ne 'Running') { Ruim 'A app nao esta em execucao.'; $veredito += "Start-AzWebApp -ResourceGroupName $ResourceGroup -Name $nomeApp" }
}

# ---------------------------------------------------------------- rede a partir da maquina
Titulo 'Rede a partir desta maquina'
try {
    $ips = [System.Net.Dns]::GetHostAddresses($fqdn) | ForEach-Object { $_.IPAddressToString }
    Ok "DNS resolve: $($ips -join ', ')"
}
catch { Ruim "DNS NAO resolve $fqdn nesta maquina (VPN, proxy ou DNS corporativo?). O Azure pode estar OK."; $veredito += 'Teste em outra rede (celular) ou fora da VPN. Se so falha aqui, e rede local.' }
try {
    $tcp = Test-NetConnection -ComputerName $fqdn -Port 443 -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) { Ok 'TCP 443 alcancavel' } else { Ruim 'TCP 443 bloqueado a partir desta maquina (firewall ou proxy).' }
}
catch { Info 'Test-NetConnection indisponivel; pulando o teste de porta.' }

# ---------------------------------------------------------------- HTTP real
Titulo 'Respostas HTTP (sem seguir redirecionamentos)'
foreach ($caminho in @('/api/health', '/')) {
    $u = "https://$fqdn$caminho"
    try {
        $resp = Invoke-WebRequest -Uri $u -MaximumRedirection 0 -TimeoutSec 30 -SkipHttpErrorCheck -ErrorAction Stop
        $code = [int] $resp.StatusCode
        $loc = $resp.Headers['Location']
        $corpo = if ($resp.Content) { ("$($resp.Content)".Substring(0, [Math]::Min(160, "$($resp.Content)".Length)) -replace '\s+', ' ') } else { '' }
        switch ($code) {
            200 { Ok "$caminho -> 200  $corpo" }
            { $_ -in 301, 302, 303, 307, 308 } {
                if ("$loc" -match 'login\.microsoftonline\.com') { Ok "$caminho -> $code redireciona para o login do Entra ID (esperado com -EnableAuth)" }
                else { Info "$caminho -> $code para $loc" }
            }
            401 { Ruim "$caminho -> 401: exige login e nao redireciona (acao configurada como Return401?)" }
            403 { Ruim "$caminho -> 403: bloqueado (restricao de acesso ou politica)" }
            404 { Ruim "$caminho -> 404: o ingress chegou ao container mas a rota nao existe (imagem de espera? porta errada?)" }
            { $_ -in 502, 503, 504 } { Ruim "$caminho -> ${code}: o ingress nao consegue falar com o container (sem replica pronta, porta errada, app caiu na inicializacao)" }
            default { Info "$caminho -> $code  $corpo" }
        }
    }
    catch {
        $sc = 0
        try { $sc = [int] $_.Exception.Response.StatusCode } catch { $sc = 0 }
        if ($sc -gt 0) { Info "$caminho -> HTTP $sc (reportado como excecao): $($_.Exception.Message)" }
        else {
            Ruim "$caminho -> sem resposta: $($_.Exception.Message)"
            $veredito += 'Sem resposta HTTP: se o DNS resolve e o TCP alcanca, a app pode estar sem replica ou o ingress fora. Veja os logs abaixo.'
        }
    }
}

# ---------------------------------------------------------------- logs
if ($HostingModel -eq 'ContainerApps') {
    Titulo 'Ultimas linhas do log de SISTEMA (pull da imagem, replicas, probes)'
    $sys = az containerapp logs show -g $ResourceGroup -n $nomeApp --type system --tail 30 --only-show-errors 2>&1
    @($sys) | ForEach-Object {
        $l = "$_"
        if ($l -match '(?i)error|fail|unauthorized|denied|imagepull|crash|back-off|unhealthy') { Write-Host "  $l" -ForegroundColor Red } else { Info $l }
    }
    $sysTexto = (@($sys) -join "`n")
    if ($sysTexto -match '(?i)unauthorized|401|pull access denied|ImagePullBackOff|failed to pull') {
        Ruim 'Falha ao BAIXAR a imagem do registry: a identidade da app ainda nao tem AcrPull efetivo, ou o registry nao esta vinculado.'
        $veredito += "az containerapp registry set -g $ResourceGroup -n $nomeApp --server $(($imagem -split '/')[0]) --identity system"
        $veredito += 'Se o papel AcrPull foi concedido ha poucos minutos, aguarde 5 a 10 min e reative a revisao: az containerapp revision restart -g ' + $ResourceGroup + ' -n ' + $nomeApp + ' --revision ' + $revNova
    }
    Titulo 'Ultimas linhas do log do CONSOLE (a aplicacao em si)'
    $con = az containerapp logs show -g $ResourceGroup -n $nomeApp --type console --tail 40 --only-show-errors 2>&1
    @($con) | ForEach-Object {
        $l = "$_"
        if ($l -match '(?i)error|traceback|exception|failed') { Write-Host "  $l" -ForegroundColor Red } else { Info $l }
    }
    $conTexto = (@($con) -join "`n")
    if ($conTexto -match 'Uvicorn running on') { Ok 'A aplicacao iniciou (uvicorn em execucao).' }
    if ($conTexto -match '(?i)ModuleNotFoundError|ImportError') { Ruim 'Falta dependencia na imagem: confira api/requirements.txt e reconstrua com -CodeOnly.' }
    if ($conTexto -match '(?i)Address already in use|port') { Info 'Mensagem sobre porta no console: confira se o container escuta em 0.0.0.0:8000.' }
}

# ---------------------------------------------------------------- veredito
Titulo 'Veredito'
if ($veredito.Count -eq 0) {
    Write-Host '  Nenhuma causa conhecida encontrada automaticamente. Leia as linhas marcadas com X acima.' -ForegroundColor Yellow
    Write-Host '  Se tudo esta OK aqui e o navegador nao abre, tente uma janela anonima (cache de redirecionamento de login) ou outra rede.' -ForegroundColor Yellow
}
else {
    Write-Host '  Acoes sugeridas, em ordem:' -ForegroundColor Yellow
    $veredito | Select-Object -Unique | ForEach-Object { Write-Host "    $_" -ForegroundColor Cyan }
}
Write-Host ''
