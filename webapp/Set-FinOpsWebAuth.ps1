<#
.SYNOPSIS
    Liga (ou desliga) o login com Entra ID na interface web do FinOps Multicloud, de forma verificavel.

.DESCRIPTION
    Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer. Baseado no Microsoft FinOps toolkit.

    Por que este script existe: os comandos "az containerapp auth microsoft update" e "az webapp auth microsoft
    update" tem regras de combinacao de parametros que mudam entre versoes da CLI (por exemplo, --issuer e
    --tenant-id nao podem vir juntos) e, quando falham, e facil acabar com a autenticacao LIGADA e SEM provedor,
    o que bloqueia a URL para todo mundo. Aqui a configuracao inteira (plataforma, regra global, provedor,
    caminhos excluidos) e gravada de uma vez, direto na API do Azure (az rest), e depois LIDA de volta para
    confirmar. Se a confirmacao falhar, o script desliga a autenticacao em vez de deixar a URL inutilizavel.

    O que faz:
      1. Localiza a aplicacao (Container App ou App Service) e a URL publica.
      2. Cria ou reutiliza o app registration "<app>-auth" no Entra ID, com o redirect URI do Easy Auth e
         emissao de ID token (necessaria porque nao usamos client secret).
      3. Garante o service principal do registro no tenant.
      4. Grava a configuracao de autenticacao completa (PUT em authConfigs/current ou authsettingsV2).
      5. Le de volta e confere clientId, issuer, acao e caminhos excluidos.
      6. Testa a URL: /api/health deve responder 200 sem login; / deve redirecionar para login.microsoftonline.com.

    Nao precisa de Docker, nao altera o codigo nem a infraestrutura. Idempotente: rodar de novo so corrige.

.EXAMPLE
    ./Set-FinOpsWebAuth.ps1 -ResourceGroup rg-finops-hub -HostingModel ContainerApps

.EXAMPLE
    # Desligar o login (a URL fica publica)
    ./Set-FinOpsWebAuth.ps1 -ResourceGroup rg-finops-hub -HostingModel ContainerApps -Disable
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [ValidateSet('AppService', 'ContainerApps', 'ContainerApp', 'ACA')]
    [string] $HostingModel = 'ContainerApps',
    # Prefixo (ou nome completo) da aplicacao.
    [string] $AppName = 'finops-web',
    [string] $SubscriptionId,
    # Caminhos que ficam FORA do login. /api/health e obrigatorio: e o health check da plataforma.
    [string[]] $ExcludedPaths = @('/api/health'),
    # Desliga a autenticacao (URL publica).
    [switch] $Disable,
    # Nao testa a URL no fim (util em automacao sem acesso de saida).
    [switch] $SkipUrlTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($HostingModel -ne 'AppService') { $HostingModel = 'ContainerApps' }
$env:PYTHONIOENCODING = 'utf-8'; $env:PYTHONUTF8 = '1'
$baseAzure = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
$env:AZURE_EXTENSION_DIR = Join-Path $baseAzure 'cliextensions-finops'   # mesma pasta isolada do instalador

function Passo([string] $t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok([string] $t) { Write-Host "  OK   $t" -ForegroundColor Green }
function Info([string] $t) { Write-Host "       $t" -ForegroundColor DarkGray }

if ($SubscriptionId) { az account set --subscription $SubscriptionId --only-show-errors 2>$null | Out-Null }
$conta = az account show -o json --only-show-errors 2>$null | ConvertFrom-Json
if (-not $conta) { throw 'Azure CLI nao esta logada. Rode: az login' }
$SubscriptionId = $conta.id
$tenantId = $conta.tenantId
Info "Assinatura $($conta.name) ($SubscriptionId), tenant $tenantId"

# ---------------------------------------------------------------- 1. aplicacao
Passo 'Aplicacao'
if ($HostingModel -eq 'ContainerApps') {
    az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null
    $app = az containerapp list -g $ResourceGroup --query "[?starts_with(name,'$AppName')] | [0]" -o json --only-show-errors 2>$null | ConvertFrom-Json
    if (-not $app) { throw "Nenhum Container App com prefixo '$AppName' em $ResourceGroup." }
    $nomeApp = $app.name
    $fqdn = $app.properties.configuration.ingress.fqdn
    $urlConfig = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$nomeApp/authConfigs/current?api-version=2024-03-01"
}
else {
    $site = az webapp list -g $ResourceGroup --query "[?starts_with(name,'$AppName')] | [0]" -o json --only-show-errors 2>$null | ConvertFrom-Json
    if (-not $site) { throw "Nenhum App Service com prefixo '$AppName' em $ResourceGroup." }
    $nomeApp = $site.name
    $fqdn = $site.defaultHostName
    $urlConfig = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$nomeApp/config/authsettingsV2?api-version=2023-12-01"
}
$appUrl = "https://$fqdn"
Ok "$nomeApp  ($appUrl)"

# ---------------------------------------------------------------- desligar
if ($Disable) {
    Passo 'Desligando a autenticacao'
    $corpo = @{ properties = @{ platform = @{ enabled = $false } } } | ConvertTo-Json -Depth 6
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $corpo -Encoding utf8
    if ($PSCmdlet.ShouldProcess($nomeApp, 'desligar a autenticacao')) {
        az rest --method put --url $urlConfig --body "@$tmp" --only-show-errors -o none
        if ($LASTEXITCODE -ne 0) { throw 'A API recusou a alteracao.' }
        Ok 'Autenticacao desligada. A URL esta PUBLICA.'
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return
}

# ---------------------------------------------------------------- 2. app registration
Passo 'App registration no Entra ID'
$redirect = "$appUrl/.auth/login/aad/callback"
$nomeRegistro = "$nomeApp-auth"
$appId = az ad app list --display-name $nomeRegistro --query '[0].appId' -o tsv --only-show-errors 2>$null
if (-not $appId) {
    Info "Criando '$nomeRegistro'..."
    if ($PSCmdlet.ShouldProcess($nomeRegistro, 'criar o app registration')) {
        $saida = & az ad app create --display-name $nomeRegistro --sign-in-audience AzureADMyOrg `
                    --web-redirect-uris $redirect --enable-id-token-issuance true --query appId -o tsv --only-show-errors 2>&1
        $appId = @($saida) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-f-]{36}$' } | Select-Object -First 1
        if (-not $appId) {
            @($saida) | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            throw ('Nao consegui criar o app registration. Em geral e falta de permissao no Entra ID (papel Application Developer ou ' +
                   'superior). Peca a alguem com permissao para criar um registro com o redirect URI ' + $redirect + ' e ID tokens habilitados, ' +
                   'ou use o portal: Container App > Authentication > Add identity provider > Microsoft > Create new app registration.')
        }
    }
}
else {
    Info "Reutilizando '$nomeRegistro' ($appId); atualizando redirect URI e ID token."
    az ad app update --id $appId --web-redirect-uris $redirect --enable-id-token-issuance true --only-show-errors 2>$null | Out-Null
}
Ok "appId $appId"
Info "Redirect URI: $redirect"

# 3. service principal (sem ele o login falha com "Application ... was not found in the directory")
$sp = az ad sp show --id $appId --query id -o tsv --only-show-errors 2>$null
if (-not $sp) {
    az ad sp create --id $appId --only-show-errors -o none 2>$null
    Ok 'Service principal criado no tenant.'
}
else { Ok 'Service principal ja existe no tenant.' }

# ---------------------------------------------------------------- 4. gravar a configuracao completa
Passo 'Gravando a configuracao de autenticacao (API do Azure)'
$emissor = "https://login.microsoftonline.com/$tenantId/v2.0"
$config = @{
    properties = @{
        platform = @{ enabled = $true }
        globalValidation = @{
            unauthenticatedClientAction = 'RedirectToLoginPage'
            redirectToProvider = 'azureactivedirectory'
            excludedPaths = @($ExcludedPaths)
        }
        identityProviders = @{
            azureActiveDirectory = @{
                enabled = $true
                registration = @{
                    clientId = $appId
                    openIdIssuer = $emissor
                }
                validation = @{
                    allowedAudiences = @("api://$appId")
                }
            }
        }
        login = @{ preserveUrlFragmentsForLogins = $false }
    }
}
if ($HostingModel -eq 'AppService') { $config.properties.platform.runtimeVersion = '~1' }
$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value ($config | ConvertTo-Json -Depth 8) -Encoding utf8
Info "Issuer: $emissor"
Info "Caminhos fora do login: $($ExcludedPaths -join ', ')"

if ($PSCmdlet.ShouldProcess($nomeApp, 'gravar a configuracao de autenticacao')) {
    $resp = & az rest --method put --url $urlConfig --body "@$tmp" --only-show-errors -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        @($resp) | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw 'A API recusou a configuracao. Nada foi ligado.'
    }
}
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 5. ler de volta e conferir
Passo 'Conferindo o que ficou gravado'
$lido = az rest --method get --url $urlConfig -o json --only-show-errors 2>$null | ConvertFrom-Json
$p = $lido.properties
$cid = $p.identityProviders.azureActiveDirectory.registration.clientId
$iss = $p.identityProviders.azureActiveDirectory.registration.openIdIssuer
$hab = $p.platform.enabled
$acao = $p.globalValidation.unauthenticatedClientAction
$excl = @($p.globalValidation.excludedPaths)
Info "habilitada=$hab acao=$acao clientId=$cid"
Info "issuer=$iss excluidos=[$($excl -join ', ')]"
$conferido = ($hab -eq $true) -and ($cid -eq $appId) -and ($iss -eq $emissor) -and ($acao -eq 'RedirectToLoginPage') -and ($excl -contains '/api/health')
if (-not $conferido) {
    Write-Host '  A configuracao lida nao bate com a gravada. Desligando a autenticacao para nao bloquear a URL.' -ForegroundColor Red
    $corpo = @{ properties = @{ platform = @{ enabled = $false } } } | ConvertTo-Json -Depth 6
    $tmp2 = New-TemporaryFile; Set-Content -Path $tmp2 -Value $corpo -Encoding utf8
    az rest --method put --url $urlConfig --body "@$tmp2" --only-show-errors -o none 2>$null
    Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue
    throw 'Autenticacao NAO habilitada (URL publica). Rode com -Verbose e envie a saida para analise.'
}
Ok 'Configuracao confirmada: provedor Entra ID gravado, redirecionamento para login, /api/health fora do login.'

# ---------------------------------------------------------------- 6. testar a URL
if (-not $SkipUrlTest) {
    Passo 'Testando a URL (a plataforma leva de 10 a 60 s para aplicar)'
    $okHealth = $false; $okLogin = $false
    for ($i = 1; $i -le 8; $i++) {
        try {
            $r1 = Invoke-WebRequest -Uri "$appUrl/api/health" -MaximumRedirection 0 -TimeoutSec 20 -SkipHttpErrorCheck
            $r2 = Invoke-WebRequest -Uri "$appUrl/" -MaximumRedirection 0 -TimeoutSec 20 -SkipHttpErrorCheck
            $okHealth = ([int] $r1.StatusCode -eq 200)
            $okLogin = ([int] $r2.StatusCode -in 301, 302, 303, 307) -and ("$($r2.Headers.Location)" -match 'login\.microsoftonline\.com')
            if ($okHealth -and $okLogin) { break }
        }
        catch { }
        Start-Sleep -Seconds 8
    }
    if ($okHealth) { Ok '/api/health responde 200 sem login (health check preservado).' } else { Write-Warning '/api/health nao respondeu 200. Se a app acabou de subir, aguarde e rode Diagnose-FinOpsWebApp.ps1.' }
    if ($okLogin) { Ok '/ redireciona para o login da Microsoft.' } else { Write-Warning '/ ainda nao redireciona para o login. Aguarde um minuto e abra a URL em janela anonima.' }
}

Write-Host ''
Write-Host '  PRONTO. Quem abrir a URL precisa entrar com conta do tenant:' -ForegroundColor Green
Write-Host "  $appUrl" -ForegroundColor Cyan
Write-Host '  Para restringir a um grupo de pessoas: Entra ID > Enterprise applications > ' -NoNewline -ForegroundColor DarkGray
Write-Host "$nomeRegistro" -NoNewline -ForegroundColor DarkGray
Write-Host ' > Properties > "Assignment required" = Yes, e adicione usuarios ou grupos em "Users and groups".' -ForegroundColor DarkGray
Write-Host ''
