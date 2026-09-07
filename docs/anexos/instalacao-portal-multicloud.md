# Instalacao pelo portal (passo a passo com o porque de cada etapa)

> **Anexo da fase de projeto.** Este documento foi escrito no desenho inicial da solução (HLD) e é mantido como referência. O guia atualizado e validado em campo está nos demais arquivos de `docs/` (índice no [README](../../README.md)). Onde houver divergência, vale o guia.


Tempo estimado: 2 a 3 horas na primeira vez. Ordem recomendada: Azure > Fabric > AWS > OCI > dashboards.
Comece pelo **nivel 0** (so Azure, so storage) se quiser validar com custo quase zero; os demais niveis
sao acrescentados sem refazer nada.

## Fase A: FinOps hub (Azure)

| # | Onde | O que fazer | Para que serve |
|---|------|-------------|----------------|
| A1 | Portal Azure > Subscriptions > sua assinatura > Settings > Resource providers | Registrar `Microsoft.EventGrid` e `Microsoft.CostManagementExports` | Event Grid avisa o Data Factory quando um arquivo chega; sem ele a ingestao nunca dispara. CostManagementExports permite criar exports |
| A2 | (Somente nivel 1, Fabric) Fabric > workspace > New item > Eventhouse `FinOpsHub` | Criar banco `Ingestion`; abrir `Ingestion_queryset`, colar `finops-hub-fabric-setup-Ingestion.kql` (release do toolkit), substituir `$$rawRetentionInDays$$` por `0`, executar. Repetir para o banco `Hub` com `finops-hub-fabric-setup-Hub.kql`. Copiar o **Query URI** em System overview | Cria as tabelas `*_raw`, `*_final_v1_2`, funcoes `Costs()`, `Prices()`, `Recommendations()` e as politicas de update que normalizam para FOCUS 1.2 |
| A3 | Botao **Deploy to Azure** (documentacao FinOps hubs > Create a new hub) | Assinatura, resource group novo (`rg-finops-hub`), regiao (mesma da capacidade Fabric), hub name `finops-hub`. Data Explorer cluster name vazio; **Fabric eventhouse Query URI** = valor do passo A2 (nivel 1) ou vazio (nivel 0). Next: manter storage `Premium_LRS`. Next: raw retention 0, normalized retention 13 meses. Next: sem infrastructure encryption, rede **Public**. Marcar **Enable managed exports** e informar os escopos (billing account EA `/providers/Microsoft.Billing/billingAccounts/<enrollment>` ou assinaturas). Opcional: **Enable recommendations**. Review + Create | Cria storage (containers msexports, ingestion, config), Data Factory com as pipelines oficiais, identidades e a ligacao com o Eventhouse. Managed exports fazem o hub criar e rodar os exports do Cost Management sozinho |
| A4 | (Somente Fabric) Eventhouse > banco Ingestion > queryset | `.add database Ingestion admins ('aadapp=<objectId do Data Factory>')` e `.add database Hub admins ('aadapp=<objectId>')`. O object ID esta em Data Factory > Settings > Managed identities | Autoriza o Data Factory a ingerir no Eventhouse |
| A5 | Cost Management + Billing > billing account > Access control (EA) ou assinatura > Access control | Dar **Enterprise Reader** (EA) ou **Cost Management Contributor** (assinatura) a identidade do Data Factory | Sem isso os managed exports falham ao criar os exports |
| A6 | Storage do hub > Storage browser > config > `settings.json` | Conferir `scopes`; se necessario adicionar `{ "scope": "/subscriptions/<id>" }`. Salvar | O trigger `config_SettingsUpdated` cria os exports para cada escopo |
| A7 | Data Factory Studio > Author > Pipelines > `config_RunBackfillJob` > Debug | Executar uma vez | Carrega os meses anteriores (retention). Primeiro precos, depois custos, para os savings sairem certos |
| A8 | Cost Management > Exports | Conferir que existem exports `ftk-*` com status **Succeeded** e arquivos em `msexports` | Prova de que o dado do Azure esta chegando |

Sem managed exports (contas MCA): Cost Management > Exports > Create > template **All costs (FOCUS) + prices** >
storage do hub, container `msexports`, diretorio unico por escopo (ex.: `billingProfiles/<id>`), Parquet + Snappy, daily
(mes corrente) e monthly (mes anterior). Overwrite off.

## Fase B: Fabric (nivel 1)

| # | Onde | O que fazer | Para que serve |
|---|------|-------------|----------------|
| B1 | Fabric > Admin portal > Capacity settings | Capacidade **F2** (pay-as-you-go) atribuida ao workspace | Menor custo possivel com Eventhouse; aumente para F4/F8 quando as consultas ficarem lentas |
| B2 | Eventhouse > banco Hub > queryset | Executar `kql/01-multicloud-functions.kql` | Cria `CostCenterMap`, `CostsMulticloud()`, `CostsAllocated()`, `CostAnomalies()`, `RecommendationsAll()`, `CommitmentCoverage()`, `IngestionHealth()` |
| B3 | Banco Hub | Carregar `CostCenterMap` (`.set-or-append` com o mapa conta > centro de custo) | Showback por BU mesmo onde as tags sao ruins |
| B4 | Workspace > New item > Real-Time Dashboard `FinOps Multicloud` > Manage > **Replace with file** | Selecionar `dashboards/finops-multicloud-realtime-dashboard.json`; em Manage > Data sources, editar a fonte `Hub` e apontar para o seu Eventhouse/banco Hub | Tres paginas prontas: Visao executiva, Onde economizar, Qualidade dos dados |
| B5 | Workspace > New item > Real-Time Dashboard (toolkit) | Importar `finops-hub-dashboard.json` da release do toolkit | Dashboard oficial de ingestao e custos Azure |
| B6 | Power BI Desktop | Abrir os **KQL reports** do toolkit com o Query URI; aplicar `dashboards/powerbi/FinOps-Multicloud-Theme.json`; publicar no workspace | Relatorios completos (Cost summary, Rate optimization, etc.) com as tres nuvens |
| B7 | Workspace > New item > Activator | Regra sobre `CostAnomalies(7d)` (linhas novas) > acao Teams/e-mail | Alerta de anomalia para o dono do custo |

## Fase C: AWS (console, sem CloudFormation)

| # | Onde | O que fazer | Para que serve |
|---|------|-------------|----------------|
| C1 | S3 > Create bucket (conta pagadora) | Nome unico, Block all public access, SSE-S3 | Destino dos exports |
| C2 | Bucket > Permissions > Bucket policy | Colar a policy de `aws/README-aws.md` (principal `bcm-data-exports.amazonaws.com`, `s3:PutObject`, condicoes `aws:SourceArn` e `aws:SourceAccount`) | Exigida pela AWS para gravar no bucket |
| C3 | Billing and Cost Management > Data Exports > Create | Standard data export; nome `finops-focus-1-0`; tabela **FOCUS 1.0 with AWS columns**; todas as colunas; Daily; **Overwrite**; **Parquet**; bucket + prefixo `focus` | FOCUS diario em `focus/finops-focus-1-0/data/BILLING_PERIOD=yyyy-MM/` |
| C4 | Cost Optimization Hub > Enable; Data Exports > Create | Tabela **Cost optimization recommendations**, Include all; Daily; **Create new**; Parquet; nome `finops-coh-recommendations` | Recomendacoes para a fila unica |
| C5 | IAM > Policies / Users | Policy `finops-hub-s3-readonly` (ListBucket, GetBucketLocation, GetObject no bucket); usuario `finops-hub-s3-reader` sem console; Security credentials > Create access key | Credencial de leitura do Data Factory |
| C6 | Data Exports / S3 | Status Healthy; arquivos no bucket (ate 24 h) | Sem arquivo nao ha o que copiar |

## Fase D: AWS no Azure (Key Vault + Data Factory Studio, colando JSON)

| # | Onde | O que fazer | Para que serve |
|---|------|-------------|----------------|
| D1 | Portal > Key vaults > Create | RG do hub, RBAC, soft delete | Cofre das credenciais |
| D2 | Key Vault > Secrets | `aws-access-key-id`, `aws-secret-access-key` | Segredos referenciados pelo nome |
| D3 | Key Vault > IAM | **Key Vault Secrets User** para a identidade gerenciada do Data Factory do hub | Data Factory le os segredos |
| D4 | Storage do hub > Storage browser > config | Criar pasta `multicloud` e enviar `adf/manifest.json` (conteudo `{}`) | Manifest modelo copiado ao fim de cada carga |
| D5 | Data Factory Studio > Manage > Linked services > New | `mc_KeyVault` (Azure Key Vault), `mc_HubDataLake` (ADLS Gen2, System Assigned Managed Identity, URL dfs do storage do hub), `mc_AwsS3` (Amazon S3, Access key via Key Vault, Service URL `https://s3.<regiao>.amazonaws.com`). Test connection | Conexoes; referencia em `adf/linkedservice-*.json` |
| D6 | Author > + > Dataset > Binary | Abrir o editor de codigo `{}` e colar `adf/dataset-mc_HubLake_Binary.json`; repetir para `adf/dataset-mc_AwsS3_Binary.json` (trocar `<<NOME-DO-BUCKET>>`); opcional Parquet: `dataset-mc_AwsS3_Parquet.json`, `dataset-mc_HubLake_Parquet.json` | Datasets parametrizados |
| D7 | Author > + > Pipeline | Editor `{}`: colar `adf/pipeline-mc_aws_IngestFocusMonth.json` (trocar `<<CONTA-PAGADORA>>`), depois `adf/pipeline-mc_aws_IngestFocus.json`; opcional `adf/pipeline-mc_aws_IngestRecommendations.json`. **Publish all** | Pipelines de ingestao |
| D8 | Pipeline `mc_aws_IngestFocusMonth` > Debug | `billingPeriod` = mes corrente (`yyyy-MM`); conferir `ingestion/Costs/yyyy/mm/aws/<conta>` | Primeira carga |
| D9 | `mc_aws_IngestFocus` > Add trigger > New | Schedule, diario 07:00 UTC, `monthsBack` = 1, Start on creation; Publish all | Agendamento |

## Fase E (antes chamada D): OCI

Console OCI: `oci/README-oci.md` (grupo, policy `endorse ... usage-report`, usuario, API key).
Azure (portal): Key Vault > secret `oci-private-key-pem` (PEM em uma linha com `\n`); Function App **Flex Consumption**, Python 3.11,
identidade do sistema; IAM: Storage Blob Data Contributor no storage do hub e Key Vault Secrets User no vault; Environment variables
conforme `functions/oci-connector/local.settings.example.json`; publicar o codigo por **VS Code (Deploy to Function App)** ou
**Deployment Center (GitHub)**; testar em Code + Test > Test/Run.

O passo a passo completo, com quatro colunas (passo, onde, o que fazer, para que serve), esta no documento Word
**Guia passo a passo pelo portal FinOps Multicloud.docx**.

## Fase F: validacao ponta a ponta

```kusto
IngestionHealth()                      // Azure, AWS e OCI com Status OK
CostsMulticloud() | summarize sum(EffectiveCost) by Provider, ChargeMonth | order by ChargeMonth desc
RecommendationsAll() | summarize count(), sum(MonthlySavings) by Provider
```
Se AWS ou OCI nao aparecerem: Data Factory > Monitor (pipelines `mc_aws_*`), Function App > Log stream, e o relatorio
**Data ingestion** do Power BI (mostra cada manifest processado).
