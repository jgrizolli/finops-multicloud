<#
.SYNOPSIS
    Publica este repositorio no GitHub, do zero, em um comando.

.DESCRIPTION
    Confere que nao ha segredo na pasta, inicializa o git, faz o primeiro commit, cria o repositorio no GitHub
    (usando o GitHub CLI) e empurra o codigo. Se o GitHub CLI nao estiver instalado, deixa tudo pronto localmente
    e mostra os dois comandos que faltam.

.PARAMETER Nome
    Nome do repositorio no GitHub. Padrao: finops-multicloud

.PARAMETER Visibilidade
    Private (padrao) ou Public.

.PARAMETER Tag
    Cria a tag da primeira versao depois do push. Padrao: v1.0.0. Use vazio para nao criar.

.PARAMETER WhatIf
    Mostra o que seria feito, sem fazer.

.EXAMPLE
    ./publicar.ps1

.EXAMPLE
    ./publicar.ps1 -Nome finops-multicloud -Visibilidade Public -Tag v1.0.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Nome = 'finops-multicloud',
    [ValidateSet('Private', 'Public')] [string] $Visibilidade = 'Private',
    [string] $Tag = 'v1.0.0',
    [string] $Mensagem = 'feat: primeira versao do FinOps Multicloud sobre FinOps hubs'
)

$ErrorActionPreference = 'Stop'
$raiz = $PSScriptRoot
Set-Location $raiz

function Info($t) { Write-Host "  $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  $t" -ForegroundColor Green }
function Aviso($t){ Write-Host "  $t" -ForegroundColor Yellow }

Write-Host ''
Write-Host 'Publicar FinOps Multicloud no GitHub' -ForegroundColor White
Write-Host '------------------------------------' -ForegroundColor DarkGray

# 1. Git presente
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git nao encontrado. Instale com: winget install Git.Git'
}
Ok 'git encontrado'

# 2. Conferencia de seguranca
$proibidos = @(
    'deploy/parameters.json'
    'webapp/api/local.settings.json'
    'functions/oci-connector/local.settings.json'
    'settings-atual.json'
)
$achados = @()
foreach ($arquivo in $proibidos) {
    if (Test-Path (Join-Path $raiz $arquivo)) { $achados += $arquivo }
}
$achados += (Get-ChildItem -Path $raiz -Recurse -File -Include '*.pem', '*.pfx', '*.key' -ErrorAction SilentlyContinue |
             ForEach-Object { $_.FullName.Replace($raiz, '').TrimStart('\', '/') })

$textos = Get-ChildItem -Path $raiz -Recurse -File -Include '*.ps1', '*.md', '*.json', '*.py', '*.bicep', '*.kql', '*.yml', '*.yaml' -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -notmatch '\\\.git\\' }
foreach ($t in $textos) {
    $conteudo = Get-Content $t.FullName -Raw -ErrorAction SilentlyContinue
    if ($conteudo -match 'AKIA[0-9A-Z]{16}' -and $conteudo -notmatch 'AKIAIOSFODNN7EXAMPLE') {
        $achados += "$($t.Name): possivel chave de acesso da AWS"
    }
    if ($conteudo -match '-----BEGIN [A-Z ]*PRIVATE KEY-----') {
        $achados += "$($t.Name): chave privada"
    }
}

if ($achados.Count -gt 0) {
    Aviso 'Encontrei arquivos que NAO devem ir para o GitHub:'
    $achados | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    Aviso 'Mova esses arquivos para fora da pasta (ou confirme que estao no .gitignore) e rode de novo.'
    $resposta = Read-Host 'Continuar mesmo assim? (digite SIM para seguir)'
    if ($resposta -ne 'SIM') { return }
} else {
    Ok 'nenhum segredo encontrado na pasta'
}

# 3. Repositorio local
if (-not (Test-Path (Join-Path $raiz '.git'))) {
    if ($PSCmdlet.ShouldProcess($raiz, 'git init')) {
        git init -b main | Out-Null
        Ok 'repositorio local criado (branch main)'
    }
} else {
    Info 'repositorio local ja existe'
}

if ($PSCmdlet.ShouldProcess($raiz, 'git add e commit')) {
    git add .
    $temMudanca = (git status --porcelain)
    if ($temMudanca) {
        git commit -m $Mensagem | Out-Null
        Ok 'commit criado'
    } else {
        Info 'nada novo para commitar'
    }
}

# 4. GitHub
$gh = Get-Command gh -ErrorAction SilentlyContinue
$temOrigin = (git remote 2>$null) -contains 'origin'

if ($temOrigin) {
    Info "remoto origin ja configurado: $(git remote get-url origin)"
    if ($PSCmdlet.ShouldProcess('origin/main', 'git push')) {
        git push -u origin main
        Ok 'codigo enviado'
    }
} elseif ($gh) {
    $flag = if ($Visibilidade -eq 'Public') { '--public' } else { '--private' }
    if ($PSCmdlet.ShouldProcess($Nome, "gh repo create $flag")) {
        gh repo create $Nome $flag --source=. --remote=origin --push
        Ok "repositorio $Nome criado e enviado"
    }
} else {
    Aviso 'GitHub CLI nao encontrado. Instale com: winget install GitHub.cli'
    Aviso 'Ou crie o repositorio pelo site e rode os dois comandos abaixo:'
    Write-Host "    git remote add origin https://github.com/<seu-usuario>/$Nome.git" -ForegroundColor White
    Write-Host '    git push -u origin main' -ForegroundColor White
    return
}

# 5. Tag da primeira versao
if ($Tag -and $PSCmdlet.ShouldProcess($Tag, 'criar tag')) {
    $existe = (git tag --list $Tag)
    if (-not $existe) {
        git tag -a $Tag -m "FinOps Multicloud $Tag"
        git push origin $Tag
        Ok "tag $Tag criada e enviada"
        if ($gh) {
            gh release create $Tag --title "FinOps Multicloud $Tag" --notes-file CHANGELOG.md
            Ok 'release publicada'
        }
    } else {
        Info "tag $Tag ja existe"
    }
}

Write-Host ''
Ok 'Pronto. Proximos passos sugeridos:'
Write-Host '    1. Settings > Branches: proteja a branch main' -ForegroundColor White
Write-Host '    2. Settings > Code security: ligue secret scanning e push protection' -ForegroundColor White
Write-Host '    3. .github/ISSUE_TEMPLATE/config.yml: troque SEU-USUARIO pelo seu usuario' -ForegroundColor White
Write-Host '    4. About (topo direito): descricao e topicos finops, azure, aws, oci, focus' -ForegroundColor White
Write-Host ''
