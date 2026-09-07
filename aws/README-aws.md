# AWS: como ligar o billing da AWS ao FinOps hub

## O que acontece
1. O **AWS Data Exports** gera diariamente a tabela **FOCUS 1.0 with AWS columns** em parquet no seu bucket S3
   (`s3://<bucket>/<prefixo>/<export>/data/BILLING_PERIOD=yyyy-MM/<export>-00001.snappy.parquet`).
   A AWS atualiza o mes corrente ate o fechamento e pode corrigir o mes anterior por ate duas semanas.
2. A pipeline `mc_aws_IngestFocus` do Data Factory do hub roda todo dia (07:00 UTC), lista os parquet do
   mes atual e do anterior, apaga a carga anterior em `ingestion/Costs/yyyy/mm/aws/<payer>`, copia os arquivos
   como `<ingestionId>__<arquivo>.parquet` e grava o `manifest.json`.
3. O hub detecta o manifest e ingere na tabela `Costs` (Fabric ou Data Explorer) ou deixa em storage
   (Power BI storage reports). `ProviderName` chega como **AWS**.

## Passo a passo (console) e o porque de cada passo
| # | Onde | O que fazer | Para que serve |
|---|------|-------------|----------------|
| 1 | Conta pagadora (payer), regiao us-east-1 | CloudFormation > Create stack > `focus-export-cloudformation.yaml` | Cria bucket com a bucket policy exigida pelo Data Exports, o export FOCUS 1.0, o export de recomendacoes (opcional) e o usuario IAM de leitura |
| 2 | IAM > Users > `finops-hub-s3-reader` > Security credentials | Create access key (Application running outside AWS) | Credencial que o Data Factory usa. Guardada no Key Vault do hub, nunca em texto plano |
| 3 | Billing and Cost Management > Data Exports | Conferir que o export `finops-focus-1-0` esta **Healthy** e que ha arquivos no bucket (a primeira entrega leva ate 24 h) | Sem arquivo no S3 a pipeline termina sem copiar nada |
| 4 | Azure: `Deploy-FinOpsMulticloud.ps1` ou Bicep | Informar `awsBucketName`, `awsS3Prefix`, `awsExportName`, `awsPayerAccountId`, `awsRegion`, access key e secret | Cria linked service `mc_AwsS3`, datasets e pipelines `mc_aws_*` no Data Factory do hub |
| 5 | Data Factory Studio > Monitor | Ver a execucao de `mc_aws_IngestFocus` (disparada pelo script) | Confirma copia; erros de credencial aparecem aqui |
| 6 | Fabric/ADX | `Costs \| where ProviderName == "AWS" \| summarize sum(EffectiveCost) by startofmonth(ChargePeriodStart)` | Confirma ingestao ponta a ponta |

## Alternativa sem CloudFormation (AWS CLI)
```bash
aws bcm-data-exports create-export --region us-east-1 --export file://focus-export.json
```
Com `focus-export.json` contendo o mesmo bloco `Export` do template (Name, DataQuery, DestinationConfigurations, RefreshCadence).

## Cost Optimization Hub (como reduzir)
* Ative o Cost Optimization Hub (Billing and Cost Management > Cost Optimization Hub > Enable, incluindo contas membro).
* O export `finops-coh-recommendations` entrega a tabela `COST_OPTIMIZATION_RECOMMENDATIONS` (rightsizing EC2, Graviton, ociosos, RDS, Savings Plans e RIs).
  Esse export nao suporta overwrite: cada entrega cria uma pasta nova; a pipeline `mc_aws_IngestRecommendations` copia apenas o que chegou nas ultimas 26 h.
* Se os nomes das colunas do seu export diferirem dos usados no mapeamento (ver `Manifest.json` na pasta `metadata/`), ajuste o `translator.mappings` da pipeline.

## Observacoes
* Versao FOCUS: use **1.0** (tabela `FOCUS_1_0_AWS`). O hub aceita 1.0, 1.0r2 e 1.2-preview; a versao 1.2 GA da AWS ainda deve ser validada com o transform do hub.
* Um export por conta pagadora. Para varias organizacoes, crie um export por payer e uma pasta `aws/<payer>` para cada.
* Shards vazios: quando o export encolhe, a AWS sobrescreve chunks extras com arquivos vazios; o hub os rejeita com `BadRequest_NoRecordsOrWrongFormat` e tenta de novo tres vezes (atraso de minutos, sem perda de dados).
