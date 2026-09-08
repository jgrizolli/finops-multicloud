# Publicar este projeto no GitHub

Guia direto, do zero ao repositorio publicado, com o projeto seguro fora do OneDrive. Leva de 5 a 10 minutos.

---

## 1. Antes de comecar

| Item | Como conferir |
|---|---|
| Git instalado | `git --help` responde |
| Conta no GitHub | github.com, logado |
| GitHub CLI (opcional, deixa tudo mais rapido) | `gh --help` responde. Instale com `winget install GitHub.cli` |
| Nenhum segredo na pasta | Confira que nao existe `deploy/parameters.json`, `local.settings.json` nem arquivo `.pem` dentro da pasta. Se existir, mova para fora antes do primeiro commit |

O `.gitignore` deste repositorio ja bloqueia esses arquivos, mas a conferencia manual custa 30 segundos e evita um
vazamento que nao se desfaz.

---

## 2. Decida a visibilidade

| Opcao | Quando escolher |
|---|---|
| **Private** | Recomendado para comecar. Voce mantem o historico salvo e decide depois se abre |
| **Public** | Quando quiser usar o projeto como portfolio ou material de comunidade. O conteudo ja esta limpo de dados de cliente e a licenca MIT permite reuso |

Voce pode trocar de private para public a qualquer momento em Settings > General > Danger Zone.

---

## 3. Caminho rapido, com GitHub CLI

Na pasta do repositorio (a que tem o `README.md` e o `LICENSE`), no PowerShell:

```powershell
cd <caminho-da-pasta-do-repositorio>

git init -b main
git add .
git commit -m "feat: primeira versao do FinOps Multicloud sobre FinOps hubs"

gh auth login
gh repo create finops-multicloud --private --source=. --remote=origin --push
```

Pronto. O repositorio existe, o codigo esta la e o `origin` ja aponta para ele.

Para publicar como publico, troque `--private` por `--public`.

---

## 4. Caminho manual, sem CLI

1. No GitHub, clique em **New repository**.
2. Nome: `finops-multicloud`. Visibilidade: private ou public.
3. **Nao marque** "Add a README", "Add .gitignore" nem "Choose a license". Este repositorio ja tem os tres, e marcar
   as caixas cria um conflito no primeiro push.
4. Copie a URL que o GitHub mostrar e rode, na pasta do repositorio:

```powershell
cd <caminho-da-pasta-do-repositorio>

git init -b main
git add .
git commit -m "feat: primeira versao do FinOps Multicloud sobre FinOps hubs"
git remote add origin https://github.com/<seu-usuario>/finops-multicloud.git
git push -u origin main
```

Se o Git pedir usuario e senha, use o **Git Credential Manager** (ja vem com o Git para Windows) ou um
**personal access token** no lugar da senha (Settings > Developer settings > Personal access tokens).

---

## 5. Depois do primeiro push, faca estas seis coisas

1. **Crie a primeira release.** É o que garante um ponto no tempo que voce consegue baixar inteiro depois:

   ```powershell
   git tag -a v1.0.0 -m "FinOps Multicloud 1.0.0"
   git push origin v1.0.0
   gh release create v1.0.0 --title "FinOps Multicloud 1.0.0" --notes-file CHANGELOG.md
   ```

2. **Proteja a branch main.** Settings > Branches > Add rule para `main`, marcando "Require a pull request before
   merging". Assim voce nao apaga o proprio trabalho com um push errado.

3. **Ligue o GitHub Pages.** Settings > Pages > Source: escolha **GitHub Actions**. O workflow
   `.github/workflows/pages.yml` publica `webapp/FinOps-Preview.html` como a pagina inicial, e o endereco fica
   `https://<seu-usuario>.github.io/finops-multicloud/`. É esse link que o botao no topo do README abre.

4. **Ligue a varredura de segredos.** Settings > Code security and analysis > Secret scanning e Push protection.
   Em repositorio publico é gratuito. Isso bloqueia um commit que leve chave por engano.

5. **Troque `SEU-USUARIO` pelo seu usuario** no `.github/ISSUE_TEMPLATE/config.yml`:

   ```powershell
   (Get-Content .github/ISSUE_TEMPLATE/config.yml -Raw) -replace 'SEU-USUARIO', '<seu-usuario>' | Set-Content .github/ISSUE_TEMPLATE/config.yml -NoNewline
   git add .github/ISSUE_TEMPLATE/config.yml
   git commit -m "docs: aponta os links dos templates para o repositorio"
   git push
   ```

6. **Preencha About.** No topo direito do repositorio, adicione a descricao e os topicos:
   `finops`, `azure`, `aws`, `oci`, `focus`, `powerbi`, `bicep`, `powershell`, `fastapi`, `cost-management`.

---

## 6. Rotina de atualizacao

```powershell
git add .
git commit -m "docs: atualiza o diario de bordo"
git push
```

Mudou algo relevante? Registre no `CHANGELOG.md` e crie uma nova tag (`v1.1.0`, `v1.2.0`). Cada tag é uma copia
completa e baixavel do projeto naquele dia.

---

## 7. O que ficou de fora do repositorio, de proposito

| Arquivo | Motivo |
|---|---|
| `deploy/parameters.json` (preenchido) | Tem o identificador real da sua assinatura e as credenciais de AWS e OCI |
| `webapp/api/local.settings.json` | Configuracao local com valores de ambiente |
| `settings-atual.json` | Estado da instalacao especifica, nao serve para outra pessoa |
| Arquivos `.pem`, `.env`, `.pfx` | Chaves |
| Os 14 documentos Word do `Copilot-Notebook/` | Sao gerados a partir do markdown de `docs/`. O guia
  `docs/COMO-CRIAR-O-NOTEBOOK.md` explica como recriar o notebook quando precisar |

Os tres entregaveis principais em Word e PowerPoint estao em `docs/entregaveis/`, porque nao existem em markdown e
seriam perdidos se ficassem so no OneDrive.

---

## 8. Se algo der errado

| Sintoma | Solucao |
|---|---|
| `remote origin already exists` | `git remote set-url origin <url>` |
| `failed to push some refs` | O repositorio remoto foi criado com README. Rode `git pull --rebase origin main` e empurre de novo |
| `file is too large` | Nenhum arquivo aqui passa de 6 MB, entao o limite de 100 MB do GitHub nao é alcancado. Se aparecer, foi um arquivo adicionado por engano. Remova com `git rm --cached <arquivo>` |
| Push bloqueado por secret scanning | Otimo sinal. Remova o segredo do arquivo, refaca o commit e so entao empurre |
