<#
.SYNOPSIS
    Captura as telas da interface web a partir da previa, para ilustrar o README.

.DESCRIPTION
    Abre webapp/FinOps-Preview.html no Microsoft Edge em modo headless, navega pelas 14 rotas da interface e
    salva um PNG de cada uma em docs/images/interface/. Nao precisa de nada instalado alem do Edge, que ja vem
    com o Windows. Leva cerca de um minuto.

    As tres imagens que o README exibe (visao-geral, inteligencia-artificial e showback-chargeback) sao capturas do
    ambiente real e ja estao no repositorio. Use este script para gerar as demais paginas, ou para refazer todas
    quando o visual da interface mudar.

.PARAMETER Rotas
    Quais telas capturar. Padrao: as cinco que o README mostra. Use 'Todas' para as 14.

.PARAMETER Largura
    Largura da janela em pixels. Padrao 1600, que rende bem no README do GitHub.

.PARAMETER Altura
    Altura da janela em pixels. Padrao 1000.

.NOTES
    As capturas saem no tema escuro, que é o padrao da interface. O tema claro é uma escolha guardada no navegador
    (botao no topo da tela), entao nao da para forcar por linha de comando.

.EXAMPLE
    ./docs/capturar-telas.ps1

.EXAMPLE
    ./docs/capturar-telas.ps1 -Rotas Todas

.EXAMPLE
    ./docs/capturar-telas.ps1 -Rotas visao-geral, otimizacao -EsperaSegundos 8
#>
[CmdletBinding()]
param(
    [string[]] $Rotas = @('visao-geral', 'ia', 'chargeback', 'otimizacao', 'previsao'),
    [int] $Largura = 1600,
    [int] $Altura = 1000,
    [int] $EsperaSegundos = 4
)

$ErrorActionPreference = 'Stop'

$todas = @(
    'visao-geral', 'tecnologia', 'nuvens', 'recursos',
    'ia', 'bancos',
    'governanca', 'chargeback', 'otimizacao', 'previsao',
    'alertas', 'insights', 'qualidade', 'relatorio'
)

if ($Rotas.Count -eq 1 -and $Rotas[0] -eq 'Todas') { $Rotas = $todas }

$raiz = Split-Path -Parent $PSScriptRoot
$previa = Join-Path $raiz 'webapp\FinOps-Preview.html'
$destino = Join-Path $raiz 'docs\images\interface'

if (-not (Test-Path $previa)) { throw "Nao encontrei $previa. Rode o script de dentro do repositorio." }
if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Path $destino -Force | Out-Null }

$edge = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $edge) {
    $chrome = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $chrome) { throw 'Nao encontrei o Microsoft Edge nem o Chrome. Um dos dois é necessario.' }
    $edge = $chrome
}

Write-Host ''
Write-Host "Navegador: $edge" -ForegroundColor DarkGray
Write-Host "Destino:   $destino" -ForegroundColor DarkGray
Write-Host "Capturando $($Rotas.Count) tela(s) em ${Largura}x${Altura}" -ForegroundColor Cyan
Write-Host ''

$perfil = Join-Path $env:TEMP "finops-capturas-$(Get-Random)"
$urlBase = ([Uri](Resolve-Path $previa).Path).AbsoluteUri

foreach ($rota in $Rotas) {
    $arquivo = Join-Path $destino "$rota.png"
    $url = "$urlBase#/$rota"

    $argumentos = @(
        '--headless=new'
        '--disable-gpu'
        '--hide-scrollbars'
        '--force-device-scale-factor=1'
        "--window-size=$Largura,$Altura"
        "--virtual-time-budget=$($EsperaSegundos * 1000)"
        "--user-data-dir=$perfil"
        '--allow-file-access-from-files'
        "--screenshot=$arquivo"
        $url
    )

    & $edge @argumentos 2>$null | Out-Null

    if (Test-Path $arquivo) {
        $kb = [math]::Round((Get-Item $arquivo).Length / 1KB)
        Write-Host ("  {0,-14} {1} KB" -f $rota, $kb) -ForegroundColor Green
    } else {
        Write-Host ("  {0,-14} falhou" -f $rota) -ForegroundColor Yellow
    }
}

Remove-Item $perfil -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Pronto. As imagens estao em docs/images/interface/.' -ForegroundColor Green
Write-Host 'Se alguma tela saiu vazia, aumente a espera: -EsperaSegundos 8' -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Para enviar ao GitHub:' -ForegroundColor Cyan
Write-Host '  git add docs/images/interface' -ForegroundColor White
Write-Host '  git commit -m "docs: atualiza as telas da interface no README"' -ForegroundColor White
Write-Host '  git push' -ForegroundColor White
Write-Host ''
