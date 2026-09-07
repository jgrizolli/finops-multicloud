<#
.SYNOPSIS
    Le e altera a retencao de dados do FinOps hub (arquivo config/settings.json).

.DESCRIPTION
    O hub guarda a configuracao de retencao em config/settings.json, no bloco "retention":

        "retention": {
          "msexports": { "days":   0 },     <- arquivo bruto do Cost Management
          "ingestion": { "months": 13 },    <- parquet processado no container ingestion
          "raw":       { "days":   0 },     <- tabelas *_raw do Data Explorer / Eventhouse
          "final":     { "months": 13 }     <- tabelas *_final_v* do Data Explorer / Eventhouse
        }

    O que cada um controla, e se pode ser alterado depois do deploy (fonte: discussion #1947
    do repositorio finops-toolkit, respondida por um colaborador do projeto):

      msexports.days   SIM, lido em tempo de execucao. Vale na proxima ingestao.
                       0 = apaga o arquivo bruto assim que converte. Suba para 3 ou 7 se
                       voce precisar depurar uma carga com o arquivo original em maos.

      ingestion.months SIM, lido em tempo de execucao. ATENCAO: hoje esse valor controla
                       ate onde o backfill vai, mas NAO apaga blob antigo do storage. A
                       limpeza automatica ainda nao foi implementada pelo toolkit. Para
                       apagar de verdade, use uma regra de ciclo de vida no storage
                       (parametro -ApplyStorageLifecycle deste script).

      raw.days         NAO. E aplicado como policy nas tabelas do Data Explorer durante o
                       deploy. Para mudar, reimplante o hub ou altere a policy na mao.

      final.months     SIM, lido em tempo de execucao. Vale na proxima ingestao.

    Observacao util: os relatorios Power BI LEEM o settings.json, mas so para mostrar os
    metadados do hub (versao, quantidade de escopos, retencao) no relatorio Data ingestion.
    A retencao nao muda o que o Power BI consulta nem filtra.

.EXAMPLE
    # Apenas ver a configuracao atual, sem alterar nada
    ./Set-FinOpsRetention.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Show

.EXAMPLE
    # Guardar 24 meses de parquet e 24 meses nas tabelas finais
    ./Set-FinOpsRetention.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub `
        -IngestionMonths 24 -FinalMonths 24

.EXAMPLE
    # Guardar o arquivo bruto por 7 dias (util para depurar uma carga)
    ./Set-FinOpsRetention.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -MsExportsDays 7

.EXAMPLE
    # Alem de ajustar o settings.json, criar a regra de ciclo de vida que realmente apaga
    # o parquet antigo do container ingestion (o hub sozinho nao apaga)
    ./Set-FinOpsRetention.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub `
        -IngestionMonths 24 -ApplyStorageLifecycle

.EXAMPLE
    # Ver o que seria alterado, sem gravar
    ./Set-FinOpsRetention.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -IngestionMonths 24 -WhatIf

.NOTES
    Requer PowerShell 7+, modulos Az.Accounts, Az.Resources e Az.Storage.
    Voce precisa de Storage Blob Data Contributor no storage do hub para gravar o settings.json.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,

    # Nome do storage do hub. Se omitido, e descoberto pelos containers msexports + ingestion.
    [string] $StorageAccountName,

    # Apenas exibe a configuracao atual e sai.
    [switch] $Show,

    # Dias para manter o arquivo bruto do Cost Management no container msexports.
    # 0 = apaga assim que converte (padrao do hub). 3 a 7 ajuda a depurar cargas.
    [ValidateRange(0, 90)]
    [Nullable[int]] $MsExportsDays,

    # Meses de parquet processado no container ingestion.
    [ValidateRange(1, 60)]
    [Nullable[int]] $IngestionMonths,

    # Dias de retencao das tabelas *_raw do Data Explorer / Eventhouse.
    # ATENCAO: so tem efeito em um redeploy do hub. Aqui apenas registramos o valor.
    [ValidateRange(0, 365)]
    [Nullable[int]] $RawDays,

    # Meses de retencao das tabelas *_final_v* do Data Explorer / Eventhouse.
    [ValidateRange(1, 120)]
    [Nullable[int]] $FinalMonths,

    # Cria (ou atualiza) uma regra de ciclo de vida no storage que apaga de verdade o parquet
    # antigo do container ingestion. Necessario porque o hub ainda nao faz essa limpeza.
    [switch] $ApplyStorageLifecycle,

    # Remove a regra de ciclo de vida criada por este script.
    [switch] $RemoveStorageLifecycle
)

$ErrorActionPreference = 'Stop'
$regraCicloVida = 'finops-hub-ingestion-retention'

function Write-Titulo([string]$texto) {
    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
    Write-Host "  $texto" -ForegroundColor Cyan
    Write-Host ('=' * 100) -ForegroundColor DarkCyan
}

# ======================================================================================
# Contexto e descoberta do storage
# ======================================================================================
foreach ($m in @('Az.Accounts', 'Az.Resources', 'Az.Storage')) {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Modulo $m nao encontrado. Rode: Install-Module $m -Scope CurrentUser" }
    Import-Module $m -ErrorAction Stop
}

if (-not (Get-AzContext)) { Connect-AzAccount -Subscription $SubscriptionId | Out-Null }
Set-AzContext -Subscription $SubscriptionId | Out-Null

$hubStorage = $null
if ($StorageAccountName) {
    $hubStorage = Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccountName
}
else {
    foreach ($sa in (Get-AzStorageAccount -ResourceGroupName $ResourceGroup)) {
        try {
            $c = New-AzStorageContext -StorageAccountName $sa.StorageAccountName -UseConnectedAccount
            $nomes = (Get-AzStorageContainer -Context $c -ErrorAction Stop).Name
            if ($nomes -contains 'ingestion' -and $nomes -contains 'msexports') { $hubStorage = $sa; break }
        } catch { continue }
    }
}
if (-not $hubStorage) {
    throw "Nao encontrei a storage do hub em $ResourceGroup. Informe -StorageAccountName ou confira se voce " +
          "tem o papel Storage Blob Data Reader (ou superior) nela."
}
$ctxStorage = New-AzStorageContext -StorageAccountName $hubStorage.StorageAccountName -UseConnectedAccount

# ======================================================================================
# Ler o settings.json atual
# ======================================================================================
$tmp = Join-Path ([IO.Path]::GetTempPath()) "settings-$([guid]::NewGuid()).json"
try {
    Get-AzStorageBlobContent -Container 'config' -Blob 'settings.json' -Context $ctxStorage -Destination $tmp -Force | Out-Null
}
catch {
    throw "Nao consegui ler config/settings.json em $($hubStorage.StorageAccountName): $($_.Exception.Message)"
}
$settings = Get-Content $tmp -Raw | ConvertFrom-Json

if (-not $settings.PSObject.Properties.Name.Contains('retention')) {
    throw 'O settings.json nao tem o bloco "retention". Verifique a versao do hub (minimo recomendado: 0.7).'
}

function Get-Valor($obj, [string]$secao, [string]$campo) {
    if ($obj.retention.PSObject.Properties.Name -contains $secao -and
        $obj.retention.$secao.PSObject.Properties.Name -contains $campo) {
        return $obj.retention.$secao.$campo
    }
    return $null
}

Write-Titulo "Retencao atual do hub  ($($hubStorage.StorageAccountName))"
Write-Host "  Versao do hub : $($settings.version)"
Write-Host ''
Write-Host '  Configuracao (config/settings.json > retention):' -ForegroundColor Yellow
Write-Host ''
Write-Host ('    {0,-18} {1,-8} {2}' -f 'CHAVE', 'VALOR', 'O QUE CONTROLA') -ForegroundColor DarkGray
Write-Host ('    {0,-18} {1,-8} {2}' -f 'msexports.days',   (Get-Valor $settings 'msexports' 'days'),   'arquivo bruto do Cost Management (0 = apaga ao converter)')
Write-Host ('    {0,-18} {1,-8} {2}' -f 'ingestion.months', (Get-Valor $settings 'ingestion' 'months'), 'parquet processado no container ingestion')
Write-Host ('    {0,-18} {1,-8} {2}' -f 'raw.days',         (Get-Valor $settings 'raw' 'days'),         'tabelas *_raw do Data Explorer / Eventhouse')
Write-Host ('    {0,-18} {1,-8} {2}' -f 'final.months',     (Get-Valor $settings 'final' 'months'),     'tabelas *_final_v* do Data Explorer / Eventhouse')

# Quantos meses de dado existem hoje, para dar contexto ao usuario
try {
    $meses = @(Get-AzStorageBlob -Container ingestion -Context $ctxStorage -Blob 'Costs/*' -ErrorAction Stop |
                Where-Object { $_.Name -like '*.parquet' } |
                ForEach-Object { ($_.Name -split '/')[1..2] -join '-' } | Sort-Object -Unique)
    if ($meses.Count -gt 0) {
        Write-Host ''
        Write-Host "  Meses de dado no storage hoje: $($meses.Count)  ($($meses[0]) ate $($meses[-1]))" -ForegroundColor Green
        Write-Host "  Use esse numero (ou maior) no parametro Number of Months dos relatorios Power BI." -ForegroundColor DarkGray
    }
}
catch { }

# Regra de ciclo de vida existente
try {
    $regras = (Get-AzStorageAccountManagementPolicy -ResourceGroupName $ResourceGroup -StorageAccountName $hubStorage.StorageAccountName -ErrorAction Stop).Rules
    $minha = $regras | Where-Object { $_.Name -eq $regraCicloVida }
    if ($minha) {
        $dias = $minha.Actions.BaseBlob.Delete.DaysAfterModificationGreaterThan
        Write-Host ''
        Write-Host "  Regra de ciclo de vida '$regraCicloVida': ATIVA, apaga blob com mais de $dias dias em ingestion/Costs." -ForegroundColor Green
    }
    else {
        Write-Host ''
        Write-Host "  Regra de ciclo de vida '$regraCicloVida': nao existe." -ForegroundColor DarkGray
        Write-Host '  Sem ela, o parquet antigo NUNCA e apagado do storage (o hub ainda nao implementa essa limpeza).' -ForegroundColor DarkGray
    }
}
catch {
    Write-Host ''
    Write-Host '  Nao consegui ler as regras de ciclo de vida do storage (precisa de Storage Account Contributor).' -ForegroundColor DarkGray
}

if ($Show) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Host ''
    return
}

# ======================================================================================
# Aplicar as alteracoes
# ======================================================================================
$mudou = $false
$avisos = @()

function Set-Valor([string]$secao, [string]$campo, $novo, [string]$rotulo) {
    if ($null -eq $novo) { return $false }
    $atual = Get-Valor $script:settings $secao $campo
    if ($atual -eq $novo) {
        Write-Host "    $rotulo ja esta em $novo. Nada a fazer." -ForegroundColor DarkGray
        return $false
    }
    if (-not ($script:settings.retention.PSObject.Properties.Name -contains $secao)) {
        $script:settings.retention | Add-Member -NotePropertyName $secao -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not ($script:settings.retention.$secao.PSObject.Properties.Name -contains $campo)) {
        $script:settings.retention.$secao | Add-Member -NotePropertyName $campo -NotePropertyValue $novo
    }
    else {
        $script:settings.retention.$secao.$campo = $novo
    }
    Write-Host "    $rotulo : $atual -> $novo" -ForegroundColor Yellow
    return $true
}

if ($null -ne $MsExportsDays -or $null -ne $IngestionMonths -or $null -ne $RawDays -or $null -ne $FinalMonths) {
    Write-Titulo 'Alterando a retencao'

    if (Set-Valor 'msexports' 'days'   $MsExportsDays   'msexports.days')   { $mudou = $true }
    if (Set-Valor 'ingestion' 'months' $IngestionMonths 'ingestion.months') { $mudou = $true }
    if (Set-Valor 'raw'       'days'   $RawDays         'raw.days')         { $mudou = $true }
    if (Set-Valor 'final'     'months' $FinalMonths     'final.months')     { $mudou = $true }

    if ($null -ne $RawDays) {
        $avisos += 'raw.days so tem efeito em um REDEPLOY do hub (a policy fica nas tabelas do Data Explorer). ' +
                   'O valor foi gravado no settings.json, mas rode o instalador de novo para aplicar.'
    }
    if ($null -ne $IngestionMonths -and -not $ApplyStorageLifecycle) {
        $avisos += 'ingestion.months controla ate onde o backfill vai, mas NAO apaga blob antigo do storage. ' +
                   'Se voce quer reduzir a retencao de verdade, rode de novo com -ApplyStorageLifecycle.'
    }

    if ($mudou) {
        if ($PSCmdlet.ShouldProcess('config/settings.json', 'gravar nova retencao')) {
            $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $tmp -Encoding utf8
            Set-AzStorageBlobContent -Container 'config' -Blob 'settings.json' -File $tmp -Context $ctxStorage -Force | Out-Null
            Write-Host ''
            Write-Host '  settings.json atualizado. Vale a partir da proxima ingestao.' -ForegroundColor Green
        }
    }
    else {
        Write-Host ''
        Write-Host '  Nenhuma alteracao necessaria.' -ForegroundColor Green
    }
}

# ======================================================================================
# Regra de ciclo de vida do storage
# ======================================================================================
if ($ApplyStorageLifecycle -or $RemoveStorageLifecycle) {
    Write-Titulo 'Regra de ciclo de vida do storage'

    try {
        $existentes = @()
        try { $existentes = @((Get-AzStorageAccountManagementPolicy -ResourceGroupName $ResourceGroup -StorageAccountName $hubStorage.StorageAccountName -ErrorAction Stop).Rules) } catch { }
        $outras = @($existentes | Where-Object { $_.Name -ne $regraCicloVida })

        if ($RemoveStorageLifecycle) {
            if ($PSCmdlet.ShouldProcess($hubStorage.StorageAccountName, "remover a regra $regraCicloVida")) {
                if ($outras.Count -gt 0) {
                    Set-AzStorageAccountManagementPolicy -ResourceGroupName $ResourceGroup -StorageAccountName $hubStorage.StorageAccountName -Rule $outras | Out-Null
                }
                else {
                    Remove-AzStorageAccountManagementPolicy -ResourceGroupName $ResourceGroup -StorageAccountName $hubStorage.StorageAccountName -Force | Out-Null
                }
                Write-Host "  Regra $regraCicloVida removida. O parquet antigo deixa de ser apagado." -ForegroundColor Green
            }
        }
        else {
            $mesesAlvo = if ($null -ne $IngestionMonths) { $IngestionMonths } else { Get-Valor $settings 'ingestion' 'months' }
            if (-not $mesesAlvo) { throw 'Nao consegui determinar a retencao alvo. Informe -IngestionMonths.' }

            # Convertemos meses em dias com folga (31 dias por mes + 15 dias de margem), para nunca
            # apagar o mes que ainda esta sendo reexportado por ajuste de fatura.
            $dias = [int]($mesesAlvo * 31) + 15

            $acao = Add-AzStorageAccountManagementPolicyAction -BaseBlobAction Delete -DaysAfterModificationGreaterThan $dias
            $filtro = New-AzStorageAccountManagementPolicyFilter -PrefixMatch 'ingestion/Costs' -BlobType blockBlob
            $nova = New-AzStorageAccountManagementPolicyRule -Name $regraCicloVida -Action $acao -Filter $filtro

            if ($PSCmdlet.ShouldProcess($hubStorage.StorageAccountName, "aplicar a regra $regraCicloVida ($dias dias)")) {
                Set-AzStorageAccountManagementPolicy -ResourceGroupName $ResourceGroup -StorageAccountName $hubStorage.StorageAccountName -Rule ($outras + $nova) | Out-Null
                Write-Host "  Regra $regraCicloVida aplicada." -ForegroundColor Green
                Write-Host "    Apaga blob em ingestion/Costs com mais de $dias dias (equivale a $mesesAlvo meses, com margem)." -ForegroundColor DarkGray
                Write-Host '    O Azure avalia as regras uma vez por dia. A primeira execucao pode levar ate 48 horas.' -ForegroundColor DarkGray
            }
        }
    }
    catch {
        Write-Warning "Nao consegui alterar a regra de ciclo de vida: $($_.Exception.Message)"
        Write-Warning 'Voce precisa do papel Storage Account Contributor no storage do hub.'
    }
}

Remove-Item $tmp -Force -ErrorAction SilentlyContinue

if ($avisos.Count -gt 0) {
    Write-Host ''
    Write-Host ('-' * 100) -ForegroundColor Yellow
    Write-Host '  ATENCAO' -ForegroundColor Yellow
    Write-Host ('-' * 100) -ForegroundColor Yellow
    foreach ($a in $avisos) { Write-Host "  * $a" -ForegroundColor Yellow; Write-Host '' }
}

Write-Host ''
Write-Host '  Lembrete: retencao no hub e coisa diferente de periodo no relatorio.' -ForegroundColor Cyan
Write-Host '  Depois de ampliar a retencao e trazer o historico (Start-FinOpsCostExport -Backfill N),' -ForegroundColor DarkGray
Write-Host '  ajuste o parametro Number of Months nos relatorios Power BI para enxergar os meses novos.' -ForegroundColor DarkGray
Write-Host ''
