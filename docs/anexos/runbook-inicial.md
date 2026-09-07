# Operacao (runbook)

> **Anexo da fase de projeto.** Este documento foi escrito no desenho inicial da solução (HLD) e é mantido como referência. O guia atualizado e validado em campo está nos demais arquivos de `docs/` (índice no [README](../../README.md)). Onde houver divergência, vale o guia.


## Rotina diaria (automatica)
| Hora (UTC) | O que roda | Onde ver |
|---|---|---|
| ~00:00 a 05:00 | Cost Management gera os exports FOCUS do Azure (config_DailySchedule do hub) | Cost Management > Exports; Data Factory > Monitor (msexports_*) |
| ate 24 h apos | AWS Data Exports entrega o parquet no S3 | S3 > bucket > prefixo/export/data |
| 06:30 | Function OCI: le FOCUS reports, grava parquet + manifest | Function App > Monitor / Log stream |
| 07:00 | Pipeline `mc_aws_IngestFocus` (mes atual + anterior) | Data Factory > Monitor |
| 08:00 | Pipeline `mc_aws_IngestRecommendations` (se habilitada) | Data Factory > Monitor |
| a cada manifest | Hub: `ingestion_ExecuteETL` > Eventhouse (`Costs_raw` > `Costs_final_v1_2`) | Relatorio Data ingestion; `IngestionHealth()` |

## Checagens semanais (10 minutos)
1. `IngestionHealth()`: tres linhas com Status OK; `DaysBehind` <= 2.
2. Real-Time Dashboard > Qualidade dos dados: custo "Nao alocado" caindo mes a mes.
3. `CostAnomalies(30d)`: tratar as anomalias abertas com o dono do centro de custo.
4. Custo do proprio hub (tag `cm-resource-parent`): Fabric F2 + storage + Data Factory + Function.

## Backfill (historico)
* Azure: `Start-FinOpsCostExport -Name <export> -Scope <scope> -Backfill 12` (precos primeiro, custos depois) ou pipeline `config_RunBackfillJob`.
* AWS: `Invoke-AzDataFactoryV2Pipeline -PipelineName mc_aws_IngestFocusMonth -Parameter @{ billingPeriod = '2026-05' }` para cada mes existente no S3
  (o Data Export so gera meses a partir da criacao; para meses antigos crie um export "one time" ou use o CUR legado).
* OCI: App setting `OCI_MONTHS_BACK` = 12 e execute a Function uma vez; volte para 1 depois. A Oracle retem 12 meses.

## Problemas comuns
| Sintoma | Causa provavel | Acao |
|---|---|---|
| Pasta com parquet mas nada no Eventhouse | manifest.json ausente ou vazio (0 bytes) | Regravar manifest com `{}`; ver trigger `ingestion_ManifestAdded` |
| `BadRequest_NoRecordsOrWrongFormat` no Data Explorer | shard parquet vazio | Ignorar (o hub tenta 3 vezes) ou filtrar arquivos de 0 linhas |
| Custo duplicado em um mes | duas cargas com ingestionId diferentes na mesma pasta sem apagar a anterior | Apagar a pasta e recarregar (pipeline/Function ja fazem isso) |
| Rate optimization vazio para AWS/OCI | esperado: price sheet e reservas sao exports do Cost Management (so Azure) | Usar `RecommendationsAll()` (Cost Optimization Hub / Cloud Advisor) |
| Linked service `mc_AwsS3` falha | access key invalida ou sem Key Vault Secrets User | Testar conexao no ADF Studio; conferir RBAC do vault |
| Function OCI 401/404 | policy `endorse ... usage-report` ausente ou fingerprint errado | Conferir `oci/README-oci.md` |
| Power BI lento | > US$ 1 milhao/mes em storage reports | Migrar para nivel 1 (Fabric) e KQL reports |

## Escalar
| Nivel | Quando | O que mudar |
|---|---|---|
| 0 > 1 | Power BI demora ou > US$ 100 mil/mes monitorados; precisa de anomalias/KQL | Criar Eventhouse, rodar setup KQL, redeploy do hub com `-FabricQueryUri` |
| 1 > 2 | Consultas lentas em F2, muitos usuarios simultaneos, 13+ meses de historico | F4/F8 (ou ADX dedicado); Eventhouse minimum consumption; private endpoints |
| qualquer | Novas nuvens (GCP, Alibaba) ou SaaS | Mesmo padrao: FOCUS em parquet em `ingestion/Costs/yyyy/mm/<cloud>/<escopo>` + manifest |

## Custo da propria solucao (estimativa da documentacao do toolkit)
* Nivel 0: cerca de US$ 5 por US$ 1 milhao monitorado por mes (storage + Data Factory).
* Nivel 1: F2 cerca de US$ 300/mes (ou cluster Data Explorer de um no cerca de US$ 120/mes) + US$ 10 por US$ 1 milhao monitorado.
* Conectores: Data Factory (poucas dezenas de execucoes/dia, centavos), Function Flex Consumption (execucoes diarias, centavos), Key Vault (centavos).
