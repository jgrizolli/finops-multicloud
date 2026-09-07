# OCI: como ligar o billing da Oracle Cloud ao FinOps hub

## O que acontece
1. A Oracle gera **FOCUS cost reports** (CSV.gz) a cada 6 horas, particionados por dia de uso, em um bucket
   **da propria Oracle** (namespace `bling`, bucket = OCID da sua tenancy, pasta `FOCUS Reports/yyyy/mm/dd/`).
   Retencao de 1 ano.
2. A Function App `<hub>-mc-oci-<sufixo>` (Python, Flex Consumption) roda todo dia (06:30 UTC), le os arquivos
   do mes atual e do anterior com a API key de um usuario OCI de leitura, converte cada CSV.gz em **parquet tipado**
   e grava em `ingestion/Costs/yyyy/mm/oci/<tenancy>/<ingestionId>__<arquivo>.parquet` + `manifest.json`.
3. Opcionalmente le o **OCI Cloud Advisor** (servico Optimizer) e grava as recomendacoes em
   `ingestion/Recommendations/yyyy/mm/oci/<tenancy>/` no esquema da tabela `Recommendations` do hub.
4. O hub ingere e `ProviderName` chega como **Oracle**.

## Passo a passo (console OCI) e o porque de cada passo
| # | Onde | O que fazer | Para que serve |
|---|------|-------------|----------------|
| 1 | Identity & Security > Domains > Default > Groups | Criar grupo `finops-readers` | Agrupar a permissao de leitura dos relatorios |
| 2 | Identity & Security > Policies (compartimento raiz) | Criar policy com as duas linhas abaixo | Autoriza leitura do bucket da Oracle onde os relatorios ficam e das recomendacoes do Advisor |
| 3 | Domains > Default > Users | Criar usuario `finops-hub-reader` (sem console), adicionar ao grupo | Identidade tecnica usada pela Function |
| 4 | Usuario > API keys > Add API key | Gerar par de chaves; baixar o `.pem` privado; copiar o **fingerprint** | Autenticacao da API OCI (assinatura de requisicoes) |
| 5 | Azure: `Deploy-FinOpsMulticloud.ps1` | Informar `OciTenancyOcid`, `OciUserOcid`, `OciFingerprint`, `OciRegion`, `OciPrivateKeyPath` | A chave vai para o Key Vault; a Function le via Key Vault reference |
| 6 | Billing & Cost Management > Cost and Usage Reports | Conferir que existem arquivos em **FOCUS Reports** | Sem relatorio (tenancy nao medida) nao ha dado |
| 7 | Azure: Function App > Functions > oci_focus_ingest > Code + Test > Test/Run | Executar uma vez | Primeira carga sem esperar o agendamento |

### Policy (compartimento raiz)
```
define tenancy usage-report as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq
endorse group finops-readers to read objects in tenancy usage-report
allow group finops-readers to read optimizer-api-family in tenancy
```
O OCID acima e o da tenancy da Oracle que hospeda os relatorios (fixo, publicado na documentacao da Oracle).
A terceira linha e opcional (Cloud Advisor).

## Observacoes
* Os relatorios FOCUS da OCI trazem alguns nomes do FOCUS 1.0-preview (`UsageQuantity`, `UsageUnit`); o transform do hub
  converte para `ConsumedQuantity`/`ConsumedUnit`. A Function mantem os nomes originais e apenas tipa as colunas.
* `ChargePeriodStart/End` podem vir como data ISO ou epoch; a Function trata os dois casos.
* Corrections chegam como linhas adicionais (`ChargeCategory` = Adjustment); nao sao removidas.
* Memoria: a Function processa um arquivo por vez (2 GB de instancia). Tenancies muito grandes: aumente `instanceMemoryMB` no Bicep.
* Alternativa: copiar os relatorios para um bucket seu (OCI Function agendada) e usar o conector **Oracle Cloud Storage** do Data Factory (API compativel com S3). Mais pecas, sem codigo Python no Azure.
