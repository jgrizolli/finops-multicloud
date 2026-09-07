<#
.SYNOPSIS
    Implanta a interface web do FinOps Multicloud (opcao B; ver docs/01-arquitetura-e-escolhas.md).

.DESCRIPTION
    Cria a infraestrutura e publica a aplicacao que le o dado do FinOps hub e mostra
    consumo total, consumo por tecnologia, consumo por nuvem, recursos, insights e
    qualidade do dado.

    O que este script faz, na ordem:

      Etapa 1  pre-requisitos e login
      Etapa 2  descobre o storage do hub (de onde vem o dado)
      Etapa 3  implanta a infraestrutura (App Service ou Container Apps) via Bicep
      Etapa 4  concede a identidade da aplicacao o papel de leitura no storage do hub
      Etapa 5  empacota e publica o codigo
      Etapa 6  (opcional) liga a autenticacao Entra ID
      Etapa 7  valida e mostra a URL

    NAO ha segredo em lugar nenhum: a aplicacao acessa o storage por identidade gerenciada.

    Requer o FinOps hub ja implantado. Rode antes o Deploy-FinOpsMulticloud.ps1.

.EXAMPLE
    # Instalacao tipica: App Service, descobrindo o storage do hub sozinho
    ./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub

.EXAMPLE
    # Com autenticacao Entra ID: so quem esta no seu tenant consegue abrir
    ./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub -EnableAuth

.EXAMPLE
    # Em Container Apps, que escala a zero quando ninguem acessa
    ./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub -HostingModel ContainerApps

.EXAMPLE
    # Com alertas por e-mail (cria Azure Communication Services, sem segredo)
    ./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub -EnableAuth -EnableEmail -AlertEmailTo finops@empresa.com

.EXAMPLE
    # Lendo do Fabric (nivel 1) em vez do storage. A interface nao muda nada.
    ./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub -EnableAuth `
        -DataBackend Kusto -KustoQueryUri https://<eventhouse>.z0.kusto.fabric.microsoft.com

.EXAMPLE
    # Republicar so o codigo, sem mexer na infraestrutura (o caso do dia a dia)
    ./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub -CodeOnly

.EXAMPLE
    # Rodar na sua maquina antes de publicar
    ./Deploy-FinOpsWebApp.ps1 -RunLocal -HubStorageAccount finopshubabc123

.NOTES
    Requer PowerShell 7+, modulos Az (Accounts, Resources, Websites) e Azure CLI.
    Para ContainerApps NAO precisa de Docker: a imagem e construida na nuvem (az acr build).
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SubscriptionId,
    [string] $ResourceGroup,
    [string] $Location,

    [string] $AppName = 'finops-web',

    [ValidateSet('AppService', 'ContainerApps')]
    [string] $HostingModel = 'AppService',

    [ValidateSet('F1', 'B1', 'B2', 'B3', 'S1', 'S2', 'P0v3', 'P1v3', 'P2v3', 'P0v4', 'P1v4')]
    [string] $AppServiceSku = 'B1',

    # Nome da storage do hub. Vazio = descoberto pelos containers msexports + ingestion.
    [string] $HubStorageAccount,

    # Resource group do hub, se for diferente do -ResourceGroup.
    [string] $HubResourceGroup,

    # Liga a autenticacao Entra ID (Easy Auth). Sem isso a URL fica publica.
    [switch] $EnableAuth,

    # Minutos que o dado fica em cache na memoria da aplicacao.
    [int] $CacheMinutes = 30,

    # E-mails que recebem os alertas (separados por virgula). Vale quando a regra nao define destinatarios.
    [string] $AlertEmailTo,

    # Cria o Azure Communication Services com dominio gerenciado para enviar e-mail de alerta.
    # Sem isto, os alertas aparecem so no painel da interface.
    [switch] $EnableEmail,

    # Localizacao dos dados do Communication Services: United States, Europe, Brazil, Australia...
    [string] $EmailDataLocation = 'United States',

    # Hora local em que os alertas sao reavaliados todo dia.
    [ValidateRange(0, 23)] [int] $AlertHour = 9,

    # Fuso em horas relativo ao UTC. Brasil = -3.
    [int] $UtcOffsetHours = -3,

    # De onde a aplicacao le o dado. Storage = parquet do hub (nivel 0). Kusto = Eventhouse do
    # Fabric ou Data Explorer (nivel 1). Trocar aqui NAO muda nada na interface.
    [ValidateSet('Storage', 'Kusto')]
    [string] $DataBackend = 'Storage',

    # Query URI do Eventhouse (System overview > Query URI) ou do cluster Data Explorer. So com -DataBackend Kusto.
    [string] $KustoQueryUri,
    [string] $KustoDatabase = 'Hub',
    [string] $KustoFunction = 'Costs()',
    [int]    $KustoMonths = 13,

    # Republica so o codigo, sem tocar na infraestrutura.
    [switch] $CodeOnly,

    # Cria a infraestrutura mas nao publica o codigo.
    [switch] $InfraOnly,

    # Escala a zero no Container Apps (sem custo quando ninguem acessa).
    [switch] $ScaleToZero,

    # Roda na sua maquina em http://localhost:8000, sem publicar nada.
    [switch] $RunLocal,

    [hashtable] $Tags = @{ solution = 'finops-multicloud' }
)

$ErrorActionPreference = 'Stop'

# A Azure CLI (e o uvicorn do modo local) sao programas Python. No Windows eles escrevem no console em cp1252
# e quebram com "UnicodeEncodeError: 'charmap' codec can't encode" quando um log traz caracteres fora dessa
# tabela (barras de progresso do pip, por exemplo). UTF-8 no processo resolve para toda a sessao.
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Etapa([string]$titulo, [string]$paraQue) {
    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
    Write-Host "  $titulo" -ForegroundColor Cyan
    if ($paraQue) { Write-Host "  Para que serve: $paraQue" -ForegroundColor DarkGray }
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
}

function Ensure-BicepCli {
    # New-AzResourceGroupDeployment compila .bicep chamando "bicep" no PATH. O "az bicep install"
    # coloca o binario em ~/.azure/bin, que NAO esta no PATH. Esta funcao resolve os dois casos.
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
        throw 'Bicep CLI nao encontrado. Instale com "winget install -e --id Microsoft.Bicep" (Windows) ou "brew install bicep" (macOS), reabra o PowerShell e rode de novo.'
    }
    Write-Host "  Bicep CLI: $(& bicep --version)  (adicionado ao PATH desta sessao)" -ForegroundColor Green
}

function Ensure-ResourceProviders([string[]] $namespaces) {
    # Um deploy em assinatura nova falha com "MissingSubscriptionRegistration" se o provider nao
    # estiver registrado. Registrar e idempotente e leva de segundos a poucos minutos.
    foreach ($ns in $namespaces) {
        $rp = Get-AzResourceProvider -ProviderNamespace $ns -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($rp -and $rp.RegistrationState -eq 'Registered') { continue }
        Write-Host "  Registrando o provider $ns..." -ForegroundColor Yellow
        Register-AzResourceProvider -ProviderNamespace $ns -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($ns in $namespaces) {
        $tentativas = 0
        while ($tentativas -lt 20) {
            $rp = Get-AzResourceProvider -ProviderNamespace $ns -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $rp -or $rp.RegistrationState -eq 'Registered') { break }
            Start-Sleep -Seconds 10; $tentativas++
        }
    }
    Write-Host "  Providers prontos: $($namespaces -join ', ')" -ForegroundColor Green
}

function Show-ErrosDeploy($erros, [int] $nivel = 1) {
    # Imprime a arvore de erros do ARM (Code + Message, com os Details aninhados). E nos Details que
    # mora a causa real: o primeiro nivel costuma ser so "InvalidTemplateDeployment".
    foreach ($e in @($erros)) {
        if (-not $e) { continue }
        $pad = '  ' * $nivel
        $codigo = if ($e.Code) { "[$($e.Code)] " } else { '' }
        Write-Host "$pad$codigo$($e.Message)" -ForegroundColor Red
        if ($e.Details) { Show-ErrosDeploy $e.Details ($nivel + 1) }
    }
}

function Get-TextoErros($erros) {
    $partes = foreach ($e in @($erros)) {
        if (-not $e) { continue }
        "$($e.Code) $($e.Message)"
        if ($e.Details) { Get-TextoErros $e.Details }
    }
    return ($partes -join ' ')
}

function Write-DicaDeploy([string] $texto) {
    # Traduz os codigos mais comuns do ARM em uma acao concreta. Tudo aqui foi visto em implantacoes reais.
    $outraRegiao = if ($Location -eq 'brazilsouth') { 'eastus2' } else { 'brazilsouth' }
    Write-Host ''
    if ($texto -match 'RoleAssignmentUpdateNotPermitted') {
        Write-Host '  DICA: a app foi recriada e sobrou uma atribuicao de papel apontando para a identidade anterior.' -ForegroundColor Yellow
        Write-Host '  Remova as atribuicoes orfas (ObjectType = Unknown) e rode de novo:' -ForegroundColor Yellow
        Write-Host "    Get-AzRoleAssignment -ResourceGroupName $ResourceGroup | Where-Object ObjectType -eq 'Unknown' | Remove-AzRoleAssignment" -ForegroundColor Cyan
    }
    elseif ($texto -match 'MissingSubscriptionRegistration') {
        Write-Host '  DICA: um resource provider ainda nao terminou de registrar. Aguarde um minuto e rode de novo.' -ForegroundColor Yellow
    }
    elseif ($texto -match 'InternalSubscriptionIsOverQuotaForSku') {
        Write-Host "  DICA: assinatura INTERNA sem cota para a familia do SKU $AppServiceSku. Nesse tipo de assinatura a cota do SKU" -ForegroundColor Yellow
        Write-Host '  costuma ser zero em TODAS as regioes, entao trocar de regiao nao resolve: troque a FAMILIA (cada uma tem cota' -ForegroundColor Yellow
        Write-Host '  propria) ou peca aumento em https://aka.ms/antquotahelp. O script testa as alternativas logo abaixo.' -ForegroundColor Yellow
        Write-Host "    .\Deploy-FinOpsWebApp.ps1 <mesmos parametros> -AppServiceSku P0v3     (PremiumV3, cota separada, ~US$ 60/mes)" -ForegroundColor Cyan
        Write-Host "    .\Deploy-FinOpsWebApp.ps1 <mesmos parametros> -AppServiceSku S1       (Standard, ~US$ 70/mes)" -ForegroundColor Cyan
        Write-Host "    .\Deploy-FinOpsWebApp.ps1 <mesmos parametros> -AppServiceSku F1       (gratuito, so para testar; sem Always On)" -ForegroundColor Cyan
    }
    elseif ($texto -match '(?i)quota|SubscriptionIsOverQuotaForSku|Current Limit') {
        Write-Host "  DICA: a assinatura nao tem cota para o plano $AppServiceSku na regiao $Location (comum em assinaturas de teste" -ForegroundColor Yellow
        Write-Host '  e em regioes com capacidade restrita, como Brazil South). A interface pode ficar em OUTRA regiao: ela le o' -ForegroundColor Yellow
        Write-Host '  storage do hub pela rede e o custo de saida e desprezivel. O script testa as alternativas logo abaixo.' -ForegroundColor Yellow
        Write-Host "    .\Deploy-FinOpsWebApp.ps1 <mesmos parametros> -Location $outraRegiao" -ForegroundColor Cyan
        Write-Host "    .\Deploy-FinOpsWebApp.ps1 <mesmos parametros> -AppServiceSku P0v3     (outra familia de SKU, cota separada)" -ForegroundColor Cyan
    }
    elseif ($texto -match '(?i)SkuNotAvailable|not available in (this )?(region|location)|NotAvailableForSubscription|Requested features?( is| are)? not (available|supported)') {
        Write-Host "  DICA: o SKU $AppServiceSku nao esta disponivel para esta assinatura em $Location. Tente outra regiao ou outro SKU:" -ForegroundColor Yellow
        Write-Host "    .\Deploy-FinOpsWebApp.ps1 <mesmos parametros> -Location $outraRegiao" -ForegroundColor Cyan
        Write-Host "    .\Deploy-FinOpsWebApp.ps1 <mesmos parametros> -AppServiceSku P0v3" -ForegroundColor Cyan
    }
    elseif ($texto -match '(?i)linux|windows|webspace|mixed|cannot be mixed|already contains|not allowed in this resource group') {
        Write-Host '  DICA: o resource group ja tem um plano App Service de outro sistema operacional ou familia na mesma regiao,' -ForegroundColor Yellow
        Write-Host '  e o Azure nao mistura os dois. Coloque a interface em um resource group proprio (o script cria):' -ForegroundColor Yellow
        Write-Host "    .\Deploy-FinOpsWebApp.ps1 <mesmos parametros> -ResourceGroup rg-finops-web -HubResourceGroup $ResourceGroup -Location $Location" -ForegroundColor Cyan
    }
    elseif ($texto -match 'RequestDisallowedByPolicy') {
        Write-Host '  DICA: uma politica da assinatura bloqueou a criacao. O nome da politica esta na mensagem acima.' -ForegroundColor Yellow
        Write-Host '  Em assinaturas internas com politica de seguranca, a saida costuma ser marcar o resource group com a tag' -ForegroundColor Yellow
        Write-Host "  SecurityControl = Ignore (o mesmo que o hub exigiu) ou pedir excecao ao time de governanca." -ForegroundColor Yellow
    }
    else {
        Write-Host '  DICA: leia a mensagem mais interna acima (a de maior recuo): e ela que diz a causa.' -ForegroundColor Yellow
        Write-Host "  Para reproduzir so a validacao, sem criar nada: Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroup -TemplateFile infra\webapp.bicep -TemplateParameterObject <parametros>" -ForegroundColor DarkGray
    }
}

function Test-Alternativas([string] $templateJson, [hashtable] $parametros, [string] $texto) {
    # Quando a causa e cota ou SKU, valida combinacoes alternativas com o MESMO preflight (nada e criado)
    # e imprime as que passam, com o comando pronto. Poupa o ciclo "tenta, falha, tenta de novo".
    if ($texto -notmatch '(?i)quota|SkuNotAvailable|not available in|NotAvailableForSubscription|Requested feature') { return }
    $candidatos = @()
    $cotaTotalZerada = $texto -match 'Total VMs\):\s*0'
    if ($cotaTotalZerada) {
        # "Total VMs: 0" e a cota GERAL de instancias de App Service da assinatura. Nenhum SKU pago passa;
        # nao vale gastar tempo testando familias e regioes. Sobram o Free (contagem propria) e o Container Apps.
        Write-Host ''
        Write-Host '  A cota TOTAL de instancias de App Service esta zerada nesta assinatura (Total VMs: 0).' -ForegroundColor Yellow
        Write-Host '  Isso vale para todas as familias pagas e todas as regioes. Restam duas saidas imediatas: o plano Free (F1),' -ForegroundColor Yellow
        Write-Host '  que tem contagem propria, e o Container Apps, que tem cota separada. A saida definitiva e pedir cota.' -ForegroundColor Yellow
        $candidatos += @{ sku = 'F1'; loc = $Location; modelo = 'AppService' }
    }
    else {
        foreach ($sku in @('P0v3', 'S1', 'F1')) { if ($sku -ne $AppServiceSku) { $candidatos += @{ sku = $sku; loc = $Location; modelo = 'AppService' } } }
        foreach ($loc in @('eastus2', 'eastus', 'westeurope')) { if ($loc -ne $Location) { $candidatos += @{ sku = $AppServiceSku; loc = $loc; modelo = 'AppService' } } }
    }
    $candidatos += @{ sku = $AppServiceSku; loc = $Location; modelo = 'ContainerApps' }
    # A validacao do Container Apps exige os providers registrados; registrar e gratuito e idempotente.
    Ensure-ResourceProviders @('Microsoft.App', 'Microsoft.ContainerRegistry')

    Write-Host ''
    Write-Host "  Testando alternativas com o Azure (validacao apenas, nada e criado; ~10 s cada)..." -ForegroundColor Yellow
    $aprovados = @()
    foreach ($c in $candidatos) {
        $p = $parametros.Clone(); $p.appServiceSku = $c.sku; $p.location = $c.loc; $p.hostingModel = $c.modelo
        $rotulo = if ($c.modelo -eq 'ContainerApps') { "Container Apps em $($c.loc)" } else { "App Service $($c.sku) em $($c.loc)" }
        $r = @(Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroup -TemplateFile $templateJson `
                -TemplateParameterObject $p -Mode Incremental -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
        if ($r.Count -eq 0) {
            Write-Host "    OK        $rotulo" -ForegroundColor Green
            $aprovados += $c
        }
        else {
            $motivo = (Get-TextoErros $r)
            $resumo = if ($motivo -match 'InternalSubscriptionIsOverQuotaForSku|OverQuota|quota') { 'sem cota' }
                      elseif ($motivo -match 'SkuNotAvailable|not available') { 'SKU indisponivel' }
                      else { ($motivo -split '\. ')[0] }
            Write-Host "    recusado  ${rotulo}: $resumo" -ForegroundColor DarkGray
        }
    }
    if ($aprovados.Count -gt 0) {
        $melhor = $aprovados[0]
        Write-Host ''
        Write-Host '  Comando pronto com a primeira alternativa aprovada (troque o SKU ou a regiao se preferir outra da lista):' -ForegroundColor Yellow
        $extras = @()
        if ($EnableAuth) { $extras += '-EnableAuth' }
        if ($EnableEmail) { $extras += '-EnableEmail' }
        if ($AlertEmailTo) { $extras += "-AlertEmailTo $AlertEmailTo" }
        if ($HubResourceGroup) { $extras += "-HubResourceGroup $HubResourceGroup" }
        if ($DataBackend -eq 'Kusto') { $extras += "-DataBackend Kusto -KustoQueryUri $KustoQueryUri -KustoDatabase $KustoDatabase" }
        $modeloArg = if ($melhor.modelo -eq 'ContainerApps') { '-HostingModel ContainerApps' } else { "-AppServiceSku $($melhor.sku)" }
        Write-Host "    .\Deploy-FinOpsWebApp.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup $($extras -join ' ') $modeloArg -Location $($melhor.loc)" -ForegroundColor Cyan
        if ($melhor.sku -eq 'F1' -and $melhor.modelo -eq 'AppService') {
            Write-Host '    (F1 e gratuito e serve para testar: 60 min de CPU por dia, sem Always On. Para uso continuo, peca cota ou use Container Apps.)' -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host ''
        Write-Host '  Nenhuma alternativa passou nesta assinatura. Peca cota (leva de minutos a horas para valores pequenos).' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  PEDIR COTA (para ficar no plano recomendado, B1): portal do Azure > Quotas > App Service > filtre a regiao' -ForegroundColor Yellow
    Write-Host "  > linha 'Basic (B1) VMs' e tambem 'Total VMs' > icone de editar > novo limite 1 ou 2 > Submit." -ForegroundColor Yellow
    Write-Host '  https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/overview   (assinatura interna: https://aka.ms/antquotahelp)' -ForegroundColor Cyan
}

# ======================================================================================
# Modo local: sobe a aplicacao na sua maquina, sem Azure nenhum alem do login
# ======================================================================================
if ($RunLocal) {
    Write-Etapa 'Modo local' 'roda a aplicacao na sua maquina para voce ver antes de publicar.'

    if ($DataBackend -eq 'Storage' -and -not $HubStorageAccount) {
        throw 'No modo local, informe -HubStorageAccount com o nome da storage do hub (ou -DataBackend Kusto -KustoQueryUri ...).'
    }
    if ($DataBackend -eq 'Kusto' -and -not $KustoQueryUri) {
        throw 'Com -DataBackend Kusto, informe -KustoQueryUri.'
    }

    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $python) { throw 'Python 3.11 ou superior nao encontrado no PATH.' }

    Write-Host '  Instalando dependencias...' -ForegroundColor Yellow
    & $python.Source -m pip install --quiet --disable-pip-version-check -r (Join-Path $raiz 'api/requirements.txt')

    $env:DATA_BACKEND = $DataBackend.ToLower()
    $env:HUB_STORAGE_ACCOUNT = [string]$HubStorageAccount
    $env:KUSTO_QUERY_URI = [string]$KustoQueryUri
    $env:KUSTO_DATABASE = $KustoDatabase
    $env:KUSTO_FUNCTION = $KustoFunction
    $env:KUSTO_MONTHS = [string]$KustoMonths
    $env:CACHE_TTL_SECONDS = [string]($CacheMinutes * 60)
    $env:STATE_DIR = Join-Path $raiz 'state'
    $env:ALERT_EMAIL_TO = [string]$AlertEmailTo

    Write-Host ''
    Write-Host "  Fonte de dados: $DataBackend. A aplicacao usa o SEU login do Azure CLI para ler." -ForegroundColor Yellow
    Write-Host '  Se der 403: az login, e confirme Storage Blob Data Reader na storage (ou viewer no banco Hub, no Kusto).' -ForegroundColor DarkGray
    Write-Host "  Estado local (centros, regras, alertas): $env:STATE_DIR" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Abra: http://localhost:8000' -ForegroundColor Green
    Write-Host '  Para parar: Ctrl+C' -ForegroundColor DarkGray
    Write-Host ''

    Push-Location (Join-Path $raiz 'api')
    try { & $python.Source -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload }
    finally { Pop-Location }
    return
}

# ======================================================================================
Write-Etapa 'Etapa 1 de 7: pre-requisitos e login' 'garante as ferramentas e a assinatura correta.'
# ======================================================================================
if (-not $SubscriptionId -or -not $ResourceGroup) {
    throw 'Informe -SubscriptionId e -ResourceGroup. Use os mesmos valores do FinOps hub.'
}

foreach ($m in @('Az.Accounts', 'Az.Resources', 'Az.Storage', 'Az.Websites')) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw "Modulo $m nao encontrado. Rode: Install-Module $m -Scope CurrentUser"
    }
    Import-Module $m -ErrorAction Stop
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI nao encontrada. Instale em https://aka.ms/installazurecli e reabra o PowerShell.'
}

if ($DataBackend -eq 'Kusto' -and -not $KustoQueryUri) { throw 'Com -DataBackend Kusto, informe -KustoQueryUri (Eventhouse > System overview > Query URI).' }

if (-not (Get-AzContext)) { Connect-AzAccount -Subscription $SubscriptionId | Out-Null }
Set-AzContext -Subscription $SubscriptionId | Out-Null
$ctx = Get-AzContext
Write-Host "  Assinatura: $($ctx.Subscription.Name) ($SubscriptionId)" -ForegroundColor Green

# Extensoes da Azure CLI em pasta ISOLADA, sempre. Motivo: ao reconstruir a tabela de comandos, a CLI le os
# metadados de TODAS as extensoes instaladas, e UMA extensao quebrada na pasta do usuario derruba qualquer comando
# ("PermissionError: [WinError 5] Access is denied: ...\.azure\cliextensions\<nome>\..."). Visto em campo com a
# extensao aksarc (dist-info sem o arquivo METADATA). Sondar com "az extension list" NAO detecta o problema, porque
# esse comando engole o erro; e o defeito so aparece quando a CLI resolve reconstruir a tabela (por exemplo, depois
# de instalar ou atualizar uma extensao), o que o torna intermitente. Isolar e deterministico e nao toca na
# instalacao do usuario: as extensoes que o script usa (authV2, containerapp) sao instaladas aqui na primeira
# execucao e reaproveitadas nas seguintes.
$baseAzure = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
$extIsolada = Join-Path $baseAzure 'cliextensions-finops'
New-Item -ItemType Directory -Path $extIsolada -Force | Out-Null
$env:AZURE_EXTENSION_DIR = $extIsolada
Write-Host "  Azure CLI: extensoes desta sessao em $extIsolada (a sua pasta original nao e alterada)." -ForegroundColor DarkGray

# Diagnostico informativo da pasta original: avisa (sem bloquear) se houver extensao com instalacao quebrada.
$extOriginal = Join-Path $baseAzure 'cliextensions'
if (Test-Path $extOriginal) {
    $quebradas = @()
    foreach ($dir in @(Get-ChildItem $extOriginal -Directory -ErrorAction SilentlyContinue)) {
        try {
            foreach ($info in @(Get-ChildItem $dir.FullName -Directory -Filter '*.dist-info' -ErrorAction Stop)) {
                if (-not (Test-Path (Join-Path $info.FullName 'METADATA'))) { $quebradas += $dir.Name }
            }
        }
        catch { $quebradas += $dir.Name }
    }
    $quebradas = @($quebradas | Select-Object -Unique)
    if ($quebradas.Count -gt 0) {
        Write-Host "  Aviso: extensao(oes) da Azure CLI com instalacao quebrada na sua pasta original: $($quebradas -join ', ')." -ForegroundColor Yellow
        Write-Host '  Nao afeta este script (pasta isolada), mas derruba outros comandos az na sua maquina. Para limpar:' -ForegroundColor Yellow
        foreach ($q in $quebradas) { Write-Host "    Remove-Item '$extOriginal\$q' -Recurse -Force    # como administrador, se der acesso negado" -ForegroundColor Cyan }
    }
}

$sondaAz = & az version --only-show-errors -o none 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ("A Azure CLI nao esta funcionando nesta maquina: $($sondaAz | Out-String). " +
           "Reinstale com: winget install --id Microsoft.AzureCLI   (ou winget upgrade --id Microsoft.AzureCLI) e reabra o PowerShell.")
}

az account set --subscription $SubscriptionId --only-show-errors 2>$null | Out-Null
$subAz = az account show --query id -o tsv --only-show-errors 2>$null
if ($subAz -ne $SubscriptionId) {
    Write-Host '  A Azure CLI nao esta logada nesta assinatura. Abrindo o login da CLI (o navegador vai abrir)...' -ForegroundColor Yellow
    az login --tenant $ctx.Tenant.Id --only-show-errors -o none
    az account set --subscription $SubscriptionId --only-show-errors 2>$null | Out-Null
    $subAz = az account show --query id -o tsv --only-show-errors 2>$null
    if ($subAz -ne $SubscriptionId) { throw "A Azure CLI nao conseguiu selecionar a assinatura $SubscriptionId. Rode: az login; az account set --subscription $SubscriptionId" }
}
Write-Host '  Azure CLI: OK, logada na assinatura.' -ForegroundColor Green
if (-not $CodeOnly) {
    Ensure-BicepCli
    $providers = @('Microsoft.Web', 'Microsoft.Storage', 'Microsoft.Insights', 'Microsoft.OperationalInsights')
    if ($HostingModel -eq 'ContainerApps') { $providers += @('Microsoft.App', 'Microsoft.ContainerRegistry') }
    if ($EnableEmail) { $providers += 'Microsoft.Communication' }
    Ensure-ResourceProviders $providers
}

$rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) {
    if ($HubResourceGroup -and $Location) {
        # Interface em resource group proprio (util quando o RG do hub ja tem planos App Service de outro tipo,
        # ou quando a governanca separa "dado" de "aplicacao").
        Write-Host "  Resource group $ResourceGroup nao existe. Criando em $Location (o hub continua em $HubResourceGroup)..." -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($ResourceGroup, 'criar o resource group')) {
            $rg = New-AzResourceGroup -Name $ResourceGroup -Location $Location -Tag $Tags
        }
    }
    else {
        throw ("Resource group $ResourceGroup nao existe. Use o resource group do hub, ou informe " +
               "-HubResourceGroup <rg-do-hub> e -Location <regiao> para a interface ficar em um resource group novo.")
    }
}
if (-not $Location) { $Location = $rg.Location }
Write-Host "  Resource group: $ResourceGroup ($Location)" -ForegroundColor Green

# ======================================================================================
Write-Etapa 'Etapa 2 de 7: storage do hub' 'e de la que a interface le o dado de custo em FOCUS.'
# ======================================================================================
$rgHub = if ($HubResourceGroup) { $HubResourceGroup } else { $ResourceGroup }

if (-not $HubStorageAccount) {
    # A storage do hub e a unica com os containers msexports E ingestion.
    foreach ($sa in (Get-AzStorageAccount -ResourceGroupName $rgHub)) {
        try {
            $c = New-AzStorageContext -StorageAccountName $sa.StorageAccountName -UseConnectedAccount
            $nomes = (Get-AzStorageContainer -Context $c -ErrorAction Stop).Name
            if ($nomes -contains 'ingestion' -and $nomes -contains 'msexports') {
                $HubStorageAccount = $sa.StorageAccountName
                break
            }
        } catch { continue }
    }
}
if (-not $HubStorageAccount) {
    throw "Nao encontrei a storage do FinOps hub em $rgHub. Informe -HubStorageAccount, ou confira se voce tem " +
          "o papel Storage Blob Data Reader nela (esse papel nao e herdado de Owner)."
}
Write-Host "  Storage do hub: $HubStorageAccount (resource group $rgHub)" -ForegroundColor Green

# Aviso util: sem parquet, a interface sobe mas abre vazia.
try {
    $ctxSt = New-AzStorageContext -StorageAccountName $HubStorageAccount -UseConnectedAccount
    $parquet = @(Get-AzStorageBlob -Container ingestion -Context $ctxSt -Blob 'Costs/*' -ErrorAction Stop |
                    Where-Object { $_.Name -like '*.parquet' })
    if ($parquet.Count -gt 0) {
        $meses = @($parquet | ForEach-Object { ($_.Name -split '/')[1..2] -join '-' } | Sort-Object -Unique)
        Write-Host "  Dado disponivel: $($parquet.Count) arquivo(s), $($meses.Count) mes(es) ($($meses[0]) a $($meses[-1]))" -ForegroundColor Green
    }
    else {
        Write-Warning 'Nenhum parquet em ingestion/Costs. A interface vai subir, mas sem dado para mostrar.'
        Write-Warning 'Rode o backfill: Start-FinOpsCostExport -Name <export> -Scope /subscriptions/<sub> -Backfill 12'
    }
}
catch {
    Write-Warning "Nao consegui listar o storage: $($_.Exception.Message)"
}

# ======================================================================================
Write-Etapa 'Etapa 3 de 7: infraestrutura' 'cria a aplicacao, a identidade gerenciada e a observabilidade.'
# ======================================================================================
$appUrl = $null
$nomeApp = $null
$principalId = $null

if ($CodeOnly) {
    Write-Host '  Pulado por -CodeOnly. Descobrindo a aplicacao existente...' -ForegroundColor Yellow
    if ($HostingModel -eq 'ContainerApps') {
        # Sem exigir o modulo Az.ContainerRegistry: a Azure CLI ja esta garantida na etapa 1.
        $registryName = az acr list --resource-group $ResourceGroup --query "[?starts_with(name, 'finopsacr')].name | [0]" -o tsv 2>$null
    }
    if ($HostingModel -eq 'AppService') {
        $sites = @(Get-AzWebApp -ResourceGroupName $ResourceGroup | Where-Object { $_.Name -like "$AppName*" })
        if (-not $sites) { throw "Nenhum App Service com prefixo '$AppName' em $ResourceGroup. Rode sem -CodeOnly primeiro." }
        $nomeApp = $sites[0].Name
        $appUrl = "https://$($sites[0].DefaultHostName)"
        Write-Host "  Aplicacao: $nomeApp" -ForegroundColor Green
    }
    else {
        az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null
        $nomeApp = (az containerapp list -g $ResourceGroup --query "[?starts_with(name,'$AppName')].name | [0]" -o tsv --only-show-errors)
        if (-not $nomeApp) { throw "Nenhum Container App com prefixo '$AppName' em $ResourceGroup. Rode sem -CodeOnly primeiro." }
        $appUrl = 'https://' + (az containerapp show -g $ResourceGroup -n $nomeApp --query 'properties.configuration.ingress.fqdn' -o tsv --only-show-errors)
        $principalId = az containerapp show -g $ResourceGroup -n $nomeApp --query 'identity.principalId' -o tsv --only-show-errors
        Write-Host "  Aplicacao: $nomeApp" -ForegroundColor Green
        Write-Host "  Registry : $registryName" -ForegroundColor Green
    }
}
else {
    $bicep = Join-Path $raiz 'infra/webapp.bicep'
    if (-not (Test-Path $bicep)) { throw "Nao encontrei $bicep." }

    $minReplicas = 1
    if ($ScaleToZero) { $minReplicas = 0 }

    $parametros = @{
        appName               = $AppName
        location              = $Location
        hostingModel          = $HostingModel
        hubStorageAccountName = $HubStorageAccount
        hubResourceGroup      = $rgHub
        appServiceSku         = $AppServiceSku
        cacheTtlSeconds       = $CacheMinutes * 60
        minReplicas           = $minReplicas
        alertEmailTo          = [string]$AlertEmailTo
        enableEmail           = [bool]$EnableEmail
        emailDataLocation     = $EmailDataLocation
        alertHour             = $AlertHour
        utcOffsetHours        = $UtcOffsetHours
        dataBackend           = $DataBackend.ToLower()
        kustoQueryUri         = [string]$KustoQueryUri
        kustoDatabase         = $KustoDatabase
        kustoFunction         = $KustoFunction
        kustoMonths           = $KustoMonths
        tags                  = $Tags
    }
    if ($HostingModel -eq 'ContainerApps') {
        # Reexecucao: preserva a imagem ja publicada, em vez de voltar para a imagem de espera.
        az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null
        $imagemAtual = az containerapp list --resource-group $ResourceGroup --query "[?starts_with(name, '$AppName')].properties.template.containers[0].image | [0]" -o tsv 2>$null
        if ($imagemAtual -and $imagemAtual -like '*.azurecr.io/finops-web:*') {
            $parametros.containerImage = $imagemAtual
            $parametros.containerRegistryServer = ($imagemAtual -split '/')[0]
            Write-Host "  Imagem atual preservada: $imagemAtual" -ForegroundColor DarkGray
        }
    }
    $descBackend = if ($DataBackend -eq 'Kusto') { "Kusto ($KustoQueryUri, banco $KustoDatabase)" } else { 'Storage (parquet do hub)' }
    Write-Host "  Fonte de dados: $descBackend" -ForegroundColor DarkGray
    if ($EnableEmail) {
        Write-Host '  E-mail: Azure Communication Services com dominio gerenciado (sem segredo).' -ForegroundColor DarkGray
        if (-not $AlertEmailTo) { Write-Warning 'EnableEmail sem -AlertEmailTo: os alertas so serao enviados para regras que tenham destinatarios proprios.' }
    }

    Write-Host "  Modelo: $HostingModel" -ForegroundColor Yellow
    if ($HostingModel -eq 'AppService') {
        Write-Host "  SKU do plano: $AppServiceSku" -ForegroundColor DarkGray
    }
    Write-Host '  Implantando (leva de 2 a 5 minutos)...' -ForegroundColor Yellow

    # Compilar ANTES de implantar: um erro de Bicep aparece aqui com linha e coluna, em vez de escondido
    # atras de "Cannot retrieve the dynamic parameters for the cmdlet" do New-AzResourceGroupDeployment.
    $templateJson = Join-Path ([IO.Path]::GetTempPath()) "finops-webapp-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    $saidaBicep = & bicep build $bicep --outfile $templateJson 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $templateJson)) {
        $saidaBicep | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw 'O template Bicep nao compilou. Corrija os erros acima (ou baixe a versao mais recente do kit) e rode de novo.'
    }
    $avisos = @($saidaBicep | Where-Object { "$_" -match 'Warning' })
    if ($avisos) { $avisos | ForEach-Object { Write-Host "  aviso: $_" -ForegroundColor DarkGray } }
    else { Write-Host '  Template compilado sem avisos.' -ForegroundColor Green }

    # Validacao previa (preflight) separada do deploy: quando o Azure recusa o template, o
    # New-AzResourceGroupDeployment so mostra "See inner errors for details" e esconde a causa.
    # O Test-AzResourceGroupDeployment devolve a arvore completa de erros, sem criar nada.
    Write-Host '  Validando o template com o Azure (nada e criado nesta etapa)...' -ForegroundColor DarkGray
    # -WarningAction: o Azure avisa que o modulo do papel no storage (parametro vindo de reference()) fica fora da
    # validacao previa (NestedDeploymentShortCircuited). E esperado; a etapa 4 confere esse papel de qualquer forma.
    $validacao = @(Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroup -TemplateFile $templateJson `
                    -TemplateParameterObject $parametros -Mode Incremental -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
    if ($validacao.Count -gt 0) {
        Write-Host '  O Azure recusou o template antes de criar qualquer recurso:' -ForegroundColor Red
        Show-ErrosDeploy $validacao
        $textoErros = Get-TextoErros $validacao
        Write-DicaDeploy $textoErros
        Test-Alternativas -templateJson $templateJson -parametros $parametros -texto $textoErros
        Remove-Item $templateJson -Force -ErrorAction SilentlyContinue
        throw 'Validacao do template falhou. As mensagens acima dizem a causa e a saida.'
    }
    Write-Host '  Validacao OK.' -ForegroundColor Green

    if ($PSCmdlet.ShouldProcess($ResourceGroup, 'implantar a infraestrutura da interface web')) {
        try {
            $dep = New-AzResourceGroupDeployment `
                -ResourceGroupName $ResourceGroup `
                -Name "finops-web-$(Get-Date -Format 'yyyyMMddHHmmss')" `
                -TemplateFile $templateJson `
                -TemplateParameterObject $parametros `
                -Mode Incremental `
                -ErrorAction Stop
        }
        catch {
            # Junta a mensagem principal com as internas (quando o SDK as expoe) e traduz em uma acao.
            $textos = @($_.Exception.Message)
            $inner = $_.Exception.InnerException
            while ($inner) { $textos += $inner.Message; $inner = $inner.InnerException }
            if ($_.ErrorDetails) { $textos += $_.ErrorDetails.Message }
            $textos | Select-Object -Skip 1 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            Write-DicaDeploy ($textos -join ' ')
            throw
        }
        finally {
            Remove-Item $templateJson -Force -ErrorAction SilentlyContinue
        }

        $appUrl = $dep.Outputs.appUrl.Value
        $nomeApp = $dep.Outputs.appName.Value
        $principalId = $dep.Outputs.principalId.Value

        Write-Host "  Aplicacao      : $nomeApp" -ForegroundColor Green
        Write-Host "  URL            : $appUrl" -ForegroundColor Green
        Write-Host "  Identidade     : $principalId" -ForegroundColor Green
        Write-Host "  Estado (tabelas): $($dep.Outputs.stateStorageAccount.Value)" -ForegroundColor Green
        $registryName = $dep.Outputs.registryName.Value
        if ($registryName) { Write-Host "  Registry       : $registryName" -ForegroundColor Green }
        if ($dep.Outputs.emailEnabled.Value) {
            Write-Host "  Remetente      : $($dep.Outputs.emailSender.Value)" -ForegroundColor Green
        }
    }
}

# ======================================================================================
Write-Etapa 'Etapa 4 de 7: permissao no storage' 'sem o papel de DADOS a aplicacao recebe 403 ao ler o parquet.'
# ======================================================================================
if ($principalId) {
    $escopoStorage = (Get-AzStorageAccount -ResourceGroupName $rgHub -Name $HubStorageAccount).Id
    $ja = Get-AzRoleAssignment -ObjectId $principalId -Scope $escopoStorage -ErrorAction SilentlyContinue |
            Where-Object { $_.RoleDefinitionName -in @('Storage Blob Data Reader', 'Storage Blob Data Contributor', 'Storage Blob Data Owner') }

    if ($ja) {
        Write-Host "  OK: a identidade ja tem '$($ja[0].RoleDefinitionName)' na storage." -ForegroundColor Green
    }
    else {
        # O Bicep ja tenta conceder. Isto aqui e a rede de seguranca para quando quem roda
        # o script nao tem permissao de escrever role assignment no escopo do hub.
        try {
            New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName 'Storage Blob Data Reader' -Scope $escopoStorage -ErrorAction Stop | Out-Null
            Write-Host '  Concedido: Storage Blob Data Reader.' -ForegroundColor Green
        }
        catch {
            Write-Warning "Nao consegui conceder o papel: $($_.Exception.Message)"
            Write-Warning 'Peca a alguem com User Access Administrator para rodar:'
            Write-Warning "  New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName 'Storage Blob Data Reader' -Scope $escopoStorage"
        }
    }
    Write-Host '  Observacao: o RBAC leva de 5 a 15 minutos para propagar. A primeira carga pode falhar antes disso.' -ForegroundColor DarkGray
    if ($DataBackend -eq 'Kusto') {
        Write-Host ''
        Write-Host '  KUSTO: a identidade precisa ser viewer do banco. Rode no Eventhouse (ou Data Explorer), banco ' -NoNewline -ForegroundColor Yellow
        Write-Host "$KustoDatabase" -ForegroundColor Yellow
        Write-Host "    .add database $KustoDatabase viewers ('aadapp=$principalId;$($ctx.Tenant.Id)')" -ForegroundColor Cyan
    }
}
else {
    Write-Host '  Pulado (a infraestrutura nao foi criada nesta execucao).' -ForegroundColor DarkGray
}

# ======================================================================================
Write-Etapa 'Etapa 5 de 7: publicar o codigo' 'envia a API e a interface para a aplicacao.'
# ======================================================================================
if (-not $InfraOnly) {
    # Porta de embarque: antes de publicar, importa o main.py como o uvicorn faz. Um erro de importacao (funcao
    # usada antes de ser definida, dependencia faltando) derruba o container na inicializacao e so aparece como
    # ContainerBackOff minutos depois. Aqui aparece em segundos, com a linha exata. Se nao houver Python na
    # maquina, o teste e pulado com aviso (a publicacao continua).
    $pyTeste = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $pyTeste) { $pyTeste = Get-Command python -ErrorAction SilentlyContinue }
    if ($pyTeste) {
        Write-Host '  Teste de importacao do codigo (simula a inicializacao do servidor)...' -ForegroundColor DarkGray
        $saidaTeste = & $pyTeste.Source (Join-Path $raiz 'api/test_import.py') 2>&1
        $codigoTeste = $LASTEXITCODE
        if ($codigoTeste -eq 1) {
            # 1 = erro no CODIGO do kit (o container nao iniciaria). Bibliotecas ausentes na maquina NAO caem aqui:
            # o teste as substitui por curingas, ou devolve 2 (pulado) quando falta pandas/numpy.
            @($saidaTeste) | Where-Object { "$_" -match 'FALHOU|X |->|Error|Traceback' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            throw 'O codigo nao passa no teste de importacao; publicar agora criaria um container que nao inicia. Corrija e rode de novo.'
        }
        elseif ($codigoTeste -eq 2) {
            @($saidaTeste) | Where-Object { "$_" -match 'PULADO|Nao e erro' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        }
        elseif ($codigoTeste -ne 0) {
            Write-Host "  Teste de importacao nao pode rodar nesta maquina (codigo $codigoTeste); seguindo. O container fara o teste real." -ForegroundColor Yellow
        }
        else {
            Write-Host '  Codigo importa sem erro (rotas registradas, fonte configurada).' -ForegroundColor Green
        }
    }
    else {
        Write-Host '  Python nao encontrado nesta maquina: pulando o teste de importacao (o container fara o teste real).' -ForegroundColor Yellow
    }
}

if ($InfraOnly) {
    Write-Host '  Pulado por -InfraOnly.' -ForegroundColor Yellow
}
elseif ($HostingModel -eq 'AppService') {
    $zip = Join-Path ([IO.Path]::GetTempPath()) "finops-web-$(Get-Date -Format 'yyyyMMddHHmmss').zip"
    $stage = Join-Path ([IO.Path]::GetTempPath()) "finops-web-stage-$([guid]::NewGuid().ToString('N').Substring(0,8))"

    try {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-Item (Join-Path $raiz 'api') -Destination (Join-Path $stage 'api') -Recurse -Force
        Copy-Item (Join-Path $raiz 'static') -Destination (Join-Path $stage 'static') -Recurse -Force

        # O Oryx (build do App Service) procura o requirements.txt na RAIZ do pacote.
        Copy-Item (Join-Path $raiz 'api/requirements.txt') -Destination (Join-Path $stage 'requirements.txt') -Force

        # Artefatos de desenvolvimento nao vao para producao.
        Get-ChildItem $stage -Recurse -Include '__pycache__', '*.pyc', 'test_local.py', 'test_import.py', 'demo_data.py' -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($extra in @('state', 'FinOps-Preview.html')) {
            $p = Join-Path $stage $extra
            if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        }

        # ZipFile do .NET em vez de Compress-Archive: garante separador "/" dentro do pacote, que e o
        # que o App Service Linux espera. Compress-Archive ja gerou pacotes com "\" em algumas versoes.
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        if (Test-Path $zip) { Remove-Item $zip -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        $tamanho = [math]::Round((Get-Item $zip).Length / 1KB, 1)
        Write-Host "  Pacote: $tamanho KB" -ForegroundColor DarkGray
        Write-Host '  Publicando e instalando dependencias (leva de 3 a 6 minutos na primeira vez)...' -ForegroundColor Yellow

        if ($PSCmdlet.ShouldProcess($nomeApp, 'publicar o codigo')) {
            az webapp deploy --resource-group $ResourceGroup --name $nomeApp --src-path $zip --type zip --clean true --restart true --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw ("Falha na publicacao (codigo $LASTEXITCODE). O build das dependencias pode ter excedido o tempo; " +
                       "rode de novo com -CodeOnly. Logs: az webapp log deployment show -g $ResourceGroup -n $nomeApp")
            }
            Write-Host '  Codigo publicado.' -ForegroundColor Green
        }
    }
    finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
else {
    # Container Apps: a imagem e construida NA NUVEM pelo ACR Tasks (az acr build). O contexto enviado e
    # uma pasta de estagio so com o necessario, e o Docker nao e exigido na maquina.
    if (-not $registryName) { throw 'Nao encontrei o registry da interface (finopsacr...). Rode sem -CodeOnly para criar a infraestrutura.' }
    $stage = Join-Path ([IO.Path]::GetTempPath()) "finops-web-img-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-Item (Join-Path $raiz 'api') -Destination (Join-Path $stage 'api') -Recurse -Force
        Copy-Item (Join-Path $raiz 'static') -Destination (Join-Path $stage 'static') -Recurse -Force
        Copy-Item (Join-Path $raiz 'Dockerfile') -Destination (Join-Path $stage 'Dockerfile') -Force
        Get-ChildItem $stage -Recurse -Include '__pycache__', '*.pyc', 'test_local.py', 'test_import.py', 'demo_data.py' -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        $tag = Get-Date -Format 'yyyyMMddHHmmss'
        $imagem = "finops-web:$tag"
        $servidor = "$registryName.azurecr.io"
        Write-Host "  Construindo a imagem $imagem na nuvem (ACR Tasks; leva de 3 a 6 minutos, sem Docker local)..." -ForegroundColor Yellow

        if ($PSCmdlet.ShouldProcess($nomeApp, 'construir e publicar a imagem')) {
            # --file e relativo a RAIZ do contexto enviado; um caminho absoluto da sua maquina nao existe no servidor.
            # --no-logs: o build roda na nuvem de qualquer forma; sem o streaming do log para o console, a
            # exibicao nao pode derrubar o comando (foi o que aconteceu com o 'charmap' no Windows). O script
            # acompanha o status da execucao e, se falhar, baixa o log completo.
            # Com --no-wait a CLI DESCARTA o objeto de retorno (comportamento do framework para comandos com
            # supports_no_wait): nada sai no stdout, e "--query runId" devolve vazio. O id da execucao so aparece
            # no aviso "Queued a build with ID: <id>", em stderr, que "--only-show-errors" esconderia. Por isso este
            # comando roda SEM --only-show-errors e o id e lido do aviso; se faltar, vem da lista de execucoes.
            $saidaBuild = & az acr build --registry $registryName --image $imagem --file Dockerfile --platform linux `
                            --no-logs --no-wait -o none $stage 2>&1
            $codigoBuild = $LASTEXITCODE
            $linhasBuild = @($saidaBuild) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
            $linhasBuild | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            $textoBuild = $linhasBuild -join "`n"
            $runId = if ($textoBuild -match 'Queued a build with ID:\s*([A-Za-z0-9]+)') { $Matches[1] } else { '' }
            if (-not $runId -and $codigoBuild -eq 0) {
                Start-Sleep -Seconds 3
                $runId = az acr task list-runs --registry $registryName --top 1 --query '[0].runId' -o tsv --only-show-errors 2>$null
            }
            if ($codigoBuild -ne 0 -or -not $runId) {
                throw ("Nao consegui enfileirar o build no registry $registryName (codigo $codigoBuild). " +
                       "Confira o login da CLI (az account show) e a permissao no registry (AcrPush ou Contributor).")
            }
            Write-Host "  Build enfileirado (execucao $runId). Aguardando..." -ForegroundColor DarkGray
            $statusRun = ''
            for ($i = 1; $i -le 60; $i++) {
                Start-Sleep -Seconds 15
                $statusRun = az acr task show-run --registry $registryName --run-id $runId --query status -o tsv --only-show-errors 2>$null
                if ($statusRun -in @('Succeeded', 'Failed', 'Canceled', 'Error', 'Timeout')) { break }
                if ($i % 4 -eq 0) { Write-Host "    ainda construindo ($statusRun, $($i * 15) s)..." -ForegroundColor DarkGray }
            }
            if ($statusRun -ne 'Succeeded') {
                Write-Host "  O build terminou com status '$statusRun'. Ultimas linhas do log:" -ForegroundColor Red
                $logBuild = az acr task logs --registry $registryName --run-id $runId --only-show-errors 2>&1
                @($logBuild) | Select-Object -Last 40 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                throw ("Falha ao construir a imagem no registry $registryName (status $statusRun). " +
                       "Log completo: az acr task logs -r $registryName --run-id $runId")
            }
            Write-Host '  Imagem construida.' -ForegroundColor Green

            az extension add --name containerapp --upgrade --only-show-errors 2>$null | Out-Null
            # Primeira passada: a app subiu com a imagem de espera e sem registry configurado. Aponta o
            # registry com a identidade do sistema (AcrPull ja concedido pelo Bicep) e troca a imagem.
            az containerapp registry set --resource-group $ResourceGroup --name $nomeApp --server $servidor --identity system --only-show-errors 2>$null | Out-Null
            az containerapp update --resource-group $ResourceGroup --name $nomeApp --image "$servidor/$imagem" --only-show-errors | Out-Null
            $codigoUpdate = $LASTEXITCODE
            # A imagem de espera escutava na porta 80; a interface escuta na 8000.
            az containerapp ingress update --resource-group $ResourceGroup --name $nomeApp --target-port 8000 --only-show-errors 2>$null | Out-Null
            if ($codigoUpdate -eq 0) {
                # A revisao nova precisa baixar a imagem do registry com a identidade (AcrPull). Se o papel foi
                # concedido ha poucos minutos, o primeiro pull pode falhar por propagacao do RBAC.
                $revisaoNova = az containerapp show -g $ResourceGroup -n $nomeApp --query properties.latestRevisionName -o tsv --only-show-errors 2>$null
                $pronta = ''
                for ($i = 1; $i -le 16; $i++) {
                    $pronta = az containerapp show -g $ResourceGroup -n $nomeApp --query properties.latestReadyRevisionName -o tsv --only-show-errors 2>$null
                    if ($pronta -eq $revisaoNova) { break }
                    Start-Sleep -Seconds 15
                }
                if ($pronta -ne $revisaoNova) {
                    Write-Warning "A revisao nova ($revisaoNova) ainda nao ficou pronta. Se for permissao de pull (AcrPull recem-concedido),"
                    Write-Warning "aguarde 5 minutos e rode de novo com: -CodeOnly -HostingModel ContainerApps. Logs: az containerapp logs show -g $ResourceGroup -n $nomeApp --type system"
                }
                else { Write-Host "  Revisao $revisaoNova pronta." -ForegroundColor Green }
            }
            if ($codigoUpdate -ne 0) {
                throw ("Falha ao trocar a imagem do Container App (codigo $LASTEXITCODE). Se for permissao de pull, aguarde o RBAC (AcrPull) " +
                       "propagar por alguns minutos e rode de novo com -CodeOnly. Logs: az containerapp logs show -g $ResourceGroup -n $nomeApp --type system")
            }
            Write-Host "  Codigo publicado: $servidor/$imagem" -ForegroundColor Green
        }
    }
    finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ======================================================================================
Write-Etapa 'Etapa 6 de 7: autenticacao' 'restringe o acesso a quem tem conta no seu tenant.'
# ======================================================================================
if (-not $EnableAuth) {
    Write-Host '  Nao habilitada. A URL fica PUBLICA na internet.' -ForegroundColor Yellow
    Write-Host "  Para restringir depois: ./Set-FinOpsWebAuth.ps1 -ResourceGroup $ResourceGroup -HostingModel $HostingModel" -ForegroundColor DarkGray
}
elseif ($appUrl) {
    # Toda a logica de autenticacao vive em Set-FinOpsWebAuth.ps1: grava a configuracao completa direto na API
    # do Azure (sem depender das combinacoes de parametros do "az ... auth update", que mudam entre versoes),
    # le de volta para confirmar e, se nao confirmar, DESLIGA em vez de deixar a URL bloqueada. O mesmo script
    # serve para ligar ou desligar depois, sem rodar o instalador.
    if ($PSCmdlet.ShouldProcess($nomeApp, 'habilitar autenticacao Entra ID')) {
        try {
            & (Join-Path $raiz 'Set-FinOpsWebAuth.ps1') -ResourceGroup $ResourceGroup -HostingModel $HostingModel `
                -AppName $nomeApp -SubscriptionId $SubscriptionId -SkipUrlTest
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Set-FinOpsWebAuth devolveu codigo $LASTEXITCODE" }
        }
        catch {
            Write-Warning "Nao consegui habilitar a autenticacao: $($_.Exception.Message)"
            Write-Warning 'A URL esta PUBLICA. Para tentar de novo, sem repetir o deploy:'
            Write-Warning "  ./Set-FinOpsWebAuth.ps1 -ResourceGroup $ResourceGroup -HostingModel $HostingModel -Verbose"
            Write-Warning 'Ou pelo portal: aplicacao > Authentication > Add identity provider > Microsoft > Create new app registration;'
            Write-Warning '  em "Excluded paths", adicione /api/health.'
        }
    }
}


# ======================================================================================
Write-Etapa 'Etapa 7 de 7: validacao' 'confirma que a aplicacao respondeu e que enxerga o dado.'
# ======================================================================================
if ($appUrl -and -not $InfraOnly) {
    Write-Host '  Aguardando a aplicacao iniciar...' -ForegroundColor Yellow
    $ok = $false
    $tentativas = if ($HostingModel -eq 'ContainerApps') { 20 } else { 12 }   # o Container App ainda baixa a imagem
    for ($i = 1; $i -le $tentativas; $i++) {
        Start-Sleep -Seconds 15
        try {
            $r = Invoke-RestMethod -Uri "$appUrl/api/health" -TimeoutSec 20 -ErrorAction Stop
            if ($r.status -eq 'ok') { $ok = $true; break }
        }
        catch { Write-Host "    tentativa $i de $tentativas..." -ForegroundColor DarkGray }
    }

    if ($ok) {
        Write-Host '  A aplicacao respondeu.' -ForegroundColor Green
        if ($EnableAuth) {
            Write-Host '  Com login habilitado, /api/status exige conta do tenant. Abra a URL no navegador para ver o dado.' -ForegroundColor DarkGray
        }
        else {
            try {
                $st = Invoke-RestMethod -Uri "$appUrl/api/status" -TimeoutSec 180 -ErrorAction Stop
                if ($st.erro) {
                    Write-Warning "A aplicacao subiu, mas nao leu o dado: $($st.erro)"
                    Write-Warning 'Se for permissao, aguarde a propagacao do RBAC (5 a 15 min) e recarregue a pagina.'
                }
                else {
                    Write-Host "  Dado carregado ($($st.backend)): $($st.linhas) linhas, $($st.arquivos) arquivo(s)/consulta(s), $($st.meses.Count) mes(es)." -ForegroundColor Green
                }
            }
            catch {
                Write-Host '  A primeira carga pode demorar. Abra a URL e aguarde alguns segundos.' -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Warning 'A aplicacao ainda nao respondeu. Isso e comum na primeira publicacao.'
        if ($HostingModel -eq 'AppService') { Write-Warning "Acompanhe os logs com: az webapp log tail -g $ResourceGroup -n $nomeApp" }
        else { Write-Warning "Acompanhe os logs com: az containerapp logs show -g $ResourceGroup -n $nomeApp --follow" }
        Write-Warning "Diagnostico completo (nao altera nada): ./Diagnose-FinOpsWebApp.ps1 -ResourceGroup $ResourceGroup -HostingModel $HostingModel"
    }
}

# ======================================================================================
Write-Host ''
Write-Host ('=' * 100) -ForegroundColor Green
Write-Host '  PRONTO' -ForegroundColor Green
Write-Host ('=' * 100) -ForegroundColor Green
Write-Host ''
Write-Host '  Abra:  ' -NoNewline; Write-Host $appUrl -ForegroundColor Cyan
Write-Host "  Se a URL nao abrir: ./Diagnose-FinOpsWebApp.ps1 -ResourceGroup $ResourceGroup -HostingModel $HostingModel" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Paginas disponiveis:'
Write-Host '    Visao geral            custo total, evolucao, categoria, nuvem e ambiente'
Write-Host '    Por tecnologia         servicos, categorias, tipos de recurso e regioes'
Write-Host '    Por nuvem              Azure, AWS, Google Cloud e Oracle Cloud, cores fixas'
Write-Host '    Recursos               os que mais consomem'
Write-Host '    Inteligencia artificial Foundry, OpenAI, Bedrock, Vertex, agentes, tokens e modelos'
Write-Host '    Bancos de dados        engines, tipos, previsao e otimizacao do dominio'
Write-Host '    Governanca             tags, conformidade, sem etiqueta, orcamento por tag'
Write-Host '    Showback e chargeback  centros de custo, rateio, cadastro e importacao de CMDB'
Write-Host '    Otimizacao             compromissos, agendamento, troca de tecnologia, sobras'
Write-Host '    Previsao               30, 60 e 90 dias, por workload'
Write-Host '    Alertas                regras, ocorrencias, reconhecer, resolver, e-mail'
Write-Host '    Insights e Qualidade   analise automatica e saude da ingestao'
Write-Host '    Relatorio              leitura executiva, exportacao PDF e Excel'
Write-Host ''
Write-Host '  Diagnostico:'
Write-Host "    $appUrl/api/status    o que foi lido e quando"
Write-Host "    $appUrl/api/docs      documentacao da API"
Write-Host ''
Write-Host '  Operacao:'
$modeloFinal = if ($HostingModel -eq 'ContainerApps') { ' -HostingModel ContainerApps' } else { '' }
Write-Host "    Republicar so o codigo : ./Deploy-FinOpsWebApp.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup$modeloFinal -CodeOnly"
Write-Host "    Ver os logs            : az webapp log tail -g $ResourceGroup -n $nomeApp"
Write-Host "    Rodar na sua maquina   : ./Deploy-FinOpsWebApp.ps1 -RunLocal -HubStorageAccount $HubStorageAccount"
Write-Host ''
if (-not $EnableAuth) {
    Write-Host '  ATENCAO: a URL esta publica. Para exigir login do seu tenant, rode de novo com -EnableAuth.' -ForegroundColor Yellow
    Write-Host ''
}
if (-not $EnableEmail) {
    Write-Host '  Alertas por e-mail desligados: aparecem so no painel. Para ligar, rode de novo com -EnableEmail -AlertEmailTo voce@empresa.com' -ForegroundColor DarkGray
    Write-Host ''
}
