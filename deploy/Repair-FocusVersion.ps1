<#
.SYNOPSIS
    Alinha a versao FOCUS dos Cost Management exports com o que os relatorios Power BI storage esperam.

.DESCRIPTION
    Por que este script existe:

    O template do FinOps hub cria "managed exports" na versao FOCUS 1.2-preview. A conversao de 1.2 para
    o esquema 1.0 (que os relatorios Power BI usam) acontece SOMENTE na ingestao do Azure Data Explorer e
    do Microsoft Fabric. No modo Storage (nivel 0) nao existe essa conversao: o parquet que chega ao
    container ingestion mantem o esquema 1.2-preview.

    Resultado: ao abrir um relatorio do pacote PowerBI-storage.zip, a consulta Costs falha com

        The column 'SkuMeterName' of the table wasn't found.

    porque a coluna x_SkuMeterName do FOCUS 1.0 foi renomeada para SkuMeter no FOCUS 1.2.

    Este script:
      1. Esvazia a lista de escopos em config/settings.json, para o hub parar de recriar managed exports
      2. Remove os Cost Management exports de FocusCost cuja versao e diferente da desejada
      3. Limpa a pasta ingestion/Costs (dado no esquema antigo)
      4. Cria exports novos na versao correta, com backfill, e executa
      5. Mostra o que precisa ser acompanhado

    O padrao e FOCUS 1.0r2, que e a versao estavel e a que os relatorios Power BI storage leem.

    Se voce usa o nivel 1 (Fabric ou Data Explorer), NAO precisa deste script: a conversao para 1.2
    acontece na ingestao e os KQL reports ja leem o esquema certo.

.EXAMPLE
    # Uso tipico: corrigir o ambiente para os relatorios Power BI storage
    ./Repair-FocusVersion.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroup rg-finops-hub

.EXAMPLE
    # Ver o que seria feito, sem alterar nada
    ./Repair-FocusVersion.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -WhatIf

.EXAMPLE
    # Manter os managed exports ligados (nao recomendado no modo Storage)
    ./Repair-FocusVersion.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -KeepManagedExports

.NOTES
    Requer PowerShell 7+, modulos Az (Accounts, Resources, Storage) e o modulo FinOpsToolkit.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,

    # Escopos a monitorar. Vazio = a propria assinatura informada.
    [string[]] $ScopesToMonitor = @(),

    [ValidateSet('1.0', '1.0r2')]
    [string] $FocusVersion = '1.0r2',

    [int] $BackfillMonths = 3,

    # Nao mexe em config/settings.json. O hub vai continuar recriando managed exports 1.2-preview.
    [switch] $KeepManagedExports,

    # Nao apaga ingestion/Costs. Use se quiser manter o dado antigo por algum motivo.
    [switch] $SkipPurge,

    # Apaga ingestion/Costs mesmo quando nao havia export na versao errada.
    # Sem este switch, reexecutar o script em um ambiente ja corrigido NAO apaga o dado bom.
    [switch] $ForcePurge,

    # Alem do export diario (mes corrente), cria o export mensal do mes anterior.
    # Recomendado pelo toolkit: o mes fechado e reexportado uma vez para pegar ajustes de fatura.
    [switch] $SkipMonthlyExport
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$titulo, [string]$paraQueServe) {
    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
    Write-Host "  $titulo" -ForegroundColor Cyan
    if ($paraQueServe) { Write-Host "  Para que serve: $paraQueServe" -ForegroundColor DarkGray }
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
}

# ======================================================================================
Write-Step 'Etapa 1 de 5: contexto e descoberta do hub' 'localiza a storage do hub para ler a configuracao e limpar o dado antigo.'
# ======================================================================================

foreach ($m in @('Az.Accounts', 'Az.Resources', 'Az.Storage', 'FinOpsToolkit')) {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Modulo $m nao encontrado. Rode: Install-Module $m -Scope CurrentUser" }
    Import-Module $m -ErrorAction Stop
}

if (-not (Get-AzContext)) { Connect-AzAccount -Subscription $SubscriptionId | Out-Null }
Set-AzContext -Subscription $SubscriptionId | Out-Null
$ctxAz = Get-AzContext
Write-Host "  Assinatura: $($ctxAz.Subscription.Name) ($($ctxAz.Subscription.Id))"

if ($ScopesToMonitor.Count -eq 0) { $ScopesToMonitor = @("/subscriptions/$SubscriptionId") }
Write-Host "  Escopos    : $($ScopesToMonitor -join ', ')"
Write-Host "  Versao alvo: FOCUS $FocusVersion"

# A storage do hub e a unica do resource group que tem os containers msexports e ingestion.
$hubStorage = $null
foreach ($sa in (Get-AzStorageAccount -ResourceGroupName $ResourceGroup)) {
    try {
        $c = New-AzStorageContext -StorageAccountName $sa.StorageAccountName -UseConnectedAccount
        $nomes = (Get-AzStorageContainer -Context $c -ErrorAction Stop).Name
        if ($nomes -contains 'ingestion' -and $nomes -contains 'msexports') { $hubStorage = $sa; $ctxStorage = $c; break }
    } catch { continue }
}
if (-not $hubStorage) {
    throw "Nao encontrei a storage do hub em $ResourceGroup (preciso de uma com os containers msexports e ingestion). " +
          "Verifique o -ResourceGroup e se voce tem o papel Storage Blob Data Reader ou superior nela."
}
Write-Host "  Storage    : $($hubStorage.StorageAccountName)" -ForegroundColor Green

# ======================================================================================
Write-Step 'Etapa 2 de 5: desligar os managed exports' 'sem isso o hub recria os exports 1.2-preview na proxima execucao e o problema volta.'
# ======================================================================================

if ($KeepManagedExports) {
    Write-Host '  Pulado por -KeepManagedExports. Atencao: o hub pode recriar exports 1.2-preview.' -ForegroundColor Yellow
}
else {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "settings-$([guid]::NewGuid()).json"
    try {
        Get-AzStorageBlobContent -Container 'config' -Blob 'settings.json' -Context $ctxStorage -Destination $tmp -Force | Out-Null
        $settings = Get-Content $tmp -Raw | ConvertFrom-Json

        $chaveEscopos = @('exportScopes', 'scopes') | Where-Object { $settings.PSObject.Properties.Name -contains $_ } | Select-Object -First 1

        if (-not $chaveEscopos) {
            Write-Host '  settings.json nao tem lista de escopos. Nada a desligar.' -ForegroundColor DarkGray
        }
        elseif (@($settings.$chaveEscopos).Count -eq 0) {
            Write-Host "  settings.json ja esta com '$chaveEscopos' vazio. Managed exports desligados." -ForegroundColor Green
        }
        else {
            $antes = @($settings.$chaveEscopos) | ForEach-Object {
                if ($_ -is [string]) { $_ }
                elseif ($_.PSObject.Properties.Name -contains 'scope') { $_.scope }
                else { ($_ | ConvertTo-Json -Compress) }
            }
            Write-Host "  Escopos gerenciados hoje: $($antes -join ', ')" -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess('config/settings.json', "esvaziar $chaveEscopos")) {
                $settings.$chaveEscopos = @()
                $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $tmp -Encoding utf8
                Set-AzStorageBlobContent -Container 'config' -Blob 'settings.json' -File $tmp -Context $ctxStorage -Force | Out-Null
                Write-Host '  settings.json atualizado. O hub para de criar e reconfigurar exports.' -ForegroundColor Green
            }
        }
    }
    catch {
        Write-Host "  Nao consegui ler ou gravar config/settings.json: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '  Siga manualmente: Storage browser > config > settings.json > editar a lista de escopos para [].' -ForegroundColor Yellow
    }
    finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
}

# ======================================================================================
Write-Step 'Etapa 3 de 5: remover os exports na versao errada' 'um export so pode ser criado com uma versao; para trocar e preciso apagar e recriar.'
# ======================================================================================

$removidos = 0
foreach ($scope in $ScopesToMonitor) {
    $exports = @()
    try { $exports = @(Get-FinOpsCostExport -Scope $scope -ErrorAction Stop) } catch {
        Write-Host "  Nao consegui listar exports em $scope : $($_.Exception.Message)" -ForegroundColor Yellow
        continue
    }
    if ($exports.Count -eq 0) { Write-Host "  Nenhum export em $scope." -ForegroundColor DarkGray; continue }

    foreach ($e in $exports) {
        $versao = if ($e.PSObject.Properties.Name -contains 'DatasetVersion') { $e.DatasetVersion } else { '' }
        $tipo   = if ($e.PSObject.Properties.Name -contains 'Dataset') { $e.Dataset } else { '' }
        Write-Host "    - $($e.Name)  [$tipo $versao]" -ForegroundColor DarkGray

        if ($tipo -eq 'FocusCost' -and $versao -ne $FocusVersion) {
            if ($PSCmdlet.ShouldProcess($e.Name, "Remove-FinOpsCostExport (versao $versao)")) {
                try {
                    Remove-FinOpsCostExport -Name $e.Name -Scope $scope -ErrorAction Stop | Out-Null
                    Write-Host "      removido (estava em $versao)" -ForegroundColor Yellow
                    $removidos++
                }
                catch { Write-Host "      falha ao remover: $($_.Exception.Message)" -ForegroundColor Red }
            }
        }
    }
}
Write-Host "  Exports removidos: $removidos" -ForegroundColor Green

# ======================================================================================
Write-Step 'Etapa 4 de 5: limpar o dado no esquema antigo' 'parquet 1.2-preview e 1.0r2 na mesma pasta quebram o relatorio; a carga nova substitui a pasta inteira.'
# ======================================================================================

if ($SkipPurge) {
    Write-Host '  Pulado por -SkipPurge.' -ForegroundColor Yellow
}
elseif ($removidos -eq 0 -and -not $ForcePurge) {
    Write-Host '  Nenhum export estava na versao errada, entao o dado existente ja esta no esquema certo.' -ForegroundColor Green
    Write-Host '  Limpeza pulada para nao apagar dado bom. Use -ForcePurge se quiser limpar mesmo assim.' -ForegroundColor DarkGray
}
else {
    foreach ($container in @('ingestion', 'msexports')) {
        $alvo = if ($container -eq 'ingestion') { 'Costs' } else { $null }
        try {
            if ($alvo) {
                $existe = Get-AzDataLakeGen2Item -FileSystem $container -Path $alvo -Context $ctxStorage -ErrorAction SilentlyContinue
                if ($existe -and $PSCmdlet.ShouldProcess("$container/$alvo", 'remover recursivamente')) {
                    Remove-AzDataLakeGen2Item -FileSystem $container -Path $alvo -Context $ctxStorage -Force | Out-Null
                    Write-Host "  $container/$alvo removido." -ForegroundColor Green
                }
                elseif (-not $existe) { Write-Host "  $container/$alvo nao existe. Nada a limpar." -ForegroundColor DarkGray }
            }
            else {
                $itens = @(Get-AzDataLakeGen2ChildItem -FileSystem $container -Context $ctxStorage -ErrorAction SilentlyContinue)
                foreach ($i in $itens) {
                    if ($PSCmdlet.ShouldProcess("$container/$($i.Path)", 'remover recursivamente')) {
                        Remove-AzDataLakeGen2Item -FileSystem $container -Path $i.Path -Context $ctxStorage -Force | Out-Null
                    }
                }
                if ($itens.Count -gt 0) { Write-Host "  $container limpo ($($itens.Count) itens)." -ForegroundColor Green }
                else { Write-Host "  $container ja esta vazio." -ForegroundColor DarkGray }
            }
        }
        catch { Write-Host "  Nao consegui limpar $container : $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

# ======================================================================================
Write-Step 'Etapa 5 de 5: criar os exports na versao correta e executar' 'e daqui que vem o dado novo, ja no esquema que o Power BI storage entende.'
# ======================================================================================

foreach ($scope in $ScopesToMonitor) {
    $safe      = ($scope.Trim('/') -replace '[^a-zA-Z0-9]', '-').ToLower()
    $sufixo    = $safe.Substring([Math]::Max(0, $safe.Length - 30))
    $isBilling = $scope -like '/providers/Microsoft.Billing/*'
    $datasets  = if ($isBilling) { @('FocusCost', 'PriceSheet', 'ReservationDetails', 'ReservationRecommendations', 'ReservationTransactions') } else { @('FocusCost') }

    foreach ($ds in $datasets) {
        $nome = "ftk-$($ds.ToLower())-$sufixo"
        $exp = @{
            Name             = $nome
            Scope            = $scope
            Dataset          = $ds
            StorageAccountId = $hubStorage.Id
            StorageContainer = 'msexports'
            StoragePath      = $scope.Trim('/')
            DoNotOverwrite   = $true
            Execute          = $true
        }
        if ($ds -eq 'FocusCost') { $exp.DatasetVersion = $FocusVersion; $exp.Backfill = $BackfillMonths }

        $rotulo = if ($ds -eq 'FocusCost') { "$ds $FocusVersion" } else { $ds }
        Write-Host "  Export $nome ($rotulo) em $scope" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($nome, 'New-FinOpsCostExport')) {
            try { New-FinOpsCostExport @exp | Out-Null; Write-Host '    criado e executado.' -ForegroundColor Green }
            catch { Write-Host "    falha: $($_.Exception.Message)" -ForegroundColor Red }
        }
    }
    # Export mensal do mes anterior: o mes fechado e reexportado uma vez para capturar ajustes de fatura.
    if (-not $SkipMonthlyExport) {
        $nomeMensal = "ftk-focuscost-monthly-$sufixo"
        $expM = @{
            Name             = $nomeMensal
            Scope            = $scope
            Dataset          = 'FocusCost'
            DatasetVersion   = $FocusVersion
            StorageAccountId = $hubStorage.Id
            StorageContainer = 'msexports'
            StoragePath      = $scope.Trim('/')
            Monthly          = $true
            DoNotOverwrite   = $true
        }
        Write-Host "  Export $nomeMensal (FocusCost $FocusVersion, mensal do mes anterior) em $scope" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($nomeMensal, 'New-FinOpsCostExport (mensal)')) {
            try { New-FinOpsCostExport @expM | Out-Null; Write-Host '    criado.' -ForegroundColor Green }
            catch { Write-Host "    falha: $($_.Exception.Message)" -ForegroundColor Red }
        }
    }

    if (-not $isBilling) {
        Write-Host '  Escopo de assinatura: apenas FocusCost. Precos e reservas so existem em billing account (EA) ou billing profile (MCA).' -ForegroundColor DarkGray
    }
}

# ======================================================================================
Write-Host ''
Write-Host ('=' * 100) -ForegroundColor Green
Write-Host '  PRONTO. O que acompanhar agora' -ForegroundColor Green
Write-Host ('=' * 100) -ForegroundColor Green
Write-Host ''
Write-Host "  1. Os exports levam de 15 a 60 minutos para entregar o backfill de $BackfillMonths meses."
Write-Host '  2. Acompanhe a chegada do parquet com:'
Write-Host ''
Write-Host "     `$ctx = New-AzStorageContext -StorageAccountName $($hubStorage.StorageAccountName) -UseConnectedAccount" -ForegroundColor DarkGray
Write-Host '     Get-AzStorageBlob -Container ingestion -Context $ctx -Blob "Costs/*" |' -ForegroundColor DarkGray
Write-Host '       Where-Object { $_.Name -like "*.parquet" } |' -ForegroundColor DarkGray
Write-Host '       Select-Object Name, @{n="KB";e={[math]::Round($_.Length/1KB,1)}}, LastModified' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  3. Confirme a versao dos exports:'
Write-Host ''
Write-Host "     Get-FinOpsCostExport -Scope '$($ScopesToMonitor[0])' | Select-Object Name, Dataset, DatasetVersion, ScheduleFrequency" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  4. No Power BI Desktop, abra o CostSummary.pbit de novo (arquivo original, nao o pbix salvo)'
Write-Host '     e refaca a conexao. A consulta Costs deve carregar sem o erro de coluna.'
Write-Host ''
