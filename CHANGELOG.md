# Historico de mudancas

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Versionamento [SemVer](https://semver.org/lang/pt-BR/).

## [1.1.0] 2026-09-07

A interface web deixou de ser um arquivo escondido na pasta `webapp/` e passou a ser a primeira coisa que a pessoa
ve no repositorio.

### Incluido

* **Demo ao vivo no GitHub Pages** (`.github/workflows/pages.yml`): a cada push que altera
  `webapp/FinOps-Preview.html`, a previa é publicada em `https://<usuario>.github.io/finops-multicloud/` e fica
  clicavel a partir do README, com as 14 paginas navegaveis e a exportacao funcionando.
* **Capturador de telas** (`docs/capturar-telas.ps1`): abre a previa no Microsoft Edge em modo headless e salva um
  PNG de cada pagina em `docs/images/interface/`. Sem dependencia alem do navegador que ja vem no Windows.
* **README com a interface em destaque**: tres capturas do ambiente real, em tamanho cheio, cada uma com o texto
  explicando o que a pagina responde: visao geral, inteligencia artificial, e showback e chargeback. Os relatorios
  Power BI passaram a ser apresentados logo abaixo, como a segunda camada de consumo. As imagens tiveram a barra de
  status do navegador recortada, para nao expor o endereco da instalacao.
* `publicar.ps1` captura as telas sozinho quando elas estao faltando, antes do primeiro commit.

## [1.0.0] 2026-09-07

Primeira versao publicada no GitHub, com o conteudo consolidado da implantacao real de setembro de 2026.

### Incluido

* **Hub e multicloud**: `deploy/Deploy-FinOpsMulticloud.ps1` (instalador do hub em 7 etapas),
  `deploy/multicloud-extension.bicep`, `deploy/Remove-FinOpsEnvironment.ps1`, `deploy/Repair-FocusVersion.ps1` e
  `deploy/Set-FinOpsRetention.ps1`.
* **Interface web propria**: `webapp/` com API em FastAPI (`api/`), front em HTML, CSS e JavaScript (`static/`),
  infraestrutura em Bicep (`infra/`), instalador `Deploy-FinOpsWebApp.ps1`, login Entra ID (`Set-FinOpsWebAuth.ps1`),
  ligar e desligar (`Set-FinOpsPower.ps1`), diagnostico (`Diagnose-FinOpsWebApp.ps1`) e previa offline
  (`build_preview.py` e `FinOps-Preview.html`).
* **AWS**: `aws/focus-export-cloudformation.yaml` (Data Exports em FOCUS 1.0) e os objetos de Data Factory em `adf/`
  (linked services, datasets, pipelines `mc_aws_*` e triggers diarios).
* **OCI**: conector em Python (`functions/oci-connector/`) e preparacao da tenancy (`oci/README-oci.md`).
* **Consumo**: consultas e funcoes KQL (`kql/`), Real-Time Dashboard do Fabric
  (`dashboards/finops-multicloud-realtime-dashboard.json`), tema e guia do Power BI (`dashboards/powerbi/`) e os seis
  relatorios `.pbit` do modo Storage (`dashboards/powerbi/templates/`).
* **Documentacao**: 13 documentos em `docs/` (arquitetura, instalacao, operacao, interface, referencia tecnica,
  codigo, multicloud, erros, diario de bordo, glossario FOCUS, comandos, ligar e desligar, licoes aprendidas), tres
  anexos, os entregaveis em Word e PowerPoint em `docs/entregaveis/` e o guia do Copilot Notebook.
* **Estrutura de repositorio**: licenca MIT, guia de contribuicao, politica de seguranca, suporte, codigo de conduta,
  templates de issue e de PR, Dependabot e workflow de CI (analise de PowerShell, compilacao de Bicep, sintaxe de
  Python, JSON e YAML).

### Atualizado

* `deploy/parameters.example.json`: passou a ser a versao mais recente do arquivo, com os campos em branco nomeados
  (`Inserir-Subscription-Id-Aqui`), `Mode` em `Storage`, `SkipAws` e `SkipOci` em `true` e a tag
  `SecurityControl: Ignore` no grupo de recursos.
* `deploy/settings.example.json`: exemplo do `settings.json` real do hub (schema 14.0, retencao de 13 meses em
  `ingestion` e `final`), util como referencia antes de alterar a retencao com `Set-FinOpsRetention.ps1`.

### Corrigido

* `aws/focus-export-cloudformation.yaml`: a descricao do parametro `BucketName` tinha dois pontos seguidos de espaco
  fora de aspas, o que quebra a leitura do template em YAML. O valor passou a ser uma string entre aspas.

### Observacoes

* Nenhum identificador real de assinatura, tenant, OCID ou chave de AWS foi publicado. Todos os exemplos usam valores
  ficticios.
* `deploy/parameters.json` e `webapp/api/local.settings.json` ficam fora do controle de versao por seguranca.
