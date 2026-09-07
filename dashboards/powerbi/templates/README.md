# Relatorios Power BI do modo Storage

Os seis modelos `.pbit` do FinOps toolkit ajustados para o hub deste kit, no modo **Storage** (leem o parquet da
camada `ingestion` direto na conta de armazenamento, sem Fabric).

| Arquivo | Para que serve |
|---|---|
| `CostSummary.storage.pbit` | Visao executiva do custo: total, tendencia, por servico, por assinatura e por tag |
| `DataIngestion.storage.pbit` | Saude da ingestao: o que chegou, de qual nuvem, em que dia. É o primeiro a abrir quando o numero parecer errado |
| `Governance.storage.pbit` | Governanca: recursos sem tag, politica, aderencia |
| `Invoicing.storage.pbit` | Conciliacao com a fatura: cobrado, creditos, impostos |
| `RateOptimization.storage.pbit` | Otimizacao de preco: reservas, savings plans, cobertura e economia possivel |
| `WorkloadOptimization.storage.pbit` | Otimizacao de uso: recurso ocioso, subutilizado e mal dimensionado |

## Como usar

1. Abra o arquivo com o Power BI Desktop.
2. Quando ele pedir os parametros, informe a URL do Data Lake do hub, no formato
   `https://<conta-de-armazenamento>.dfs.core.windows.net/ingestion`, e o numero de meses de historico.
3. Entre com a sua conta do Entra ID (Organizational account). O acesso é por RBAC, sem chave de conta.

Se o relatorio reclamar de uma coluna que nao existe (por exemplo `SkuMeterName`), a versao FOCUS do export esta
diferente da esperada. Rode `deploy/Repair-FocusVersion.ps1` e atualize o relatorio.

O passo a passo completo esta em [docs/02-instalacao-do-hub.md](../../../docs/02-instalacao-do-hub.md), no Passo 7, e a
retencao (quanto historico o relatorio enxerga) em
[docs/03-operacao-do-hub.md](../../../docs/03-operacao-do-hub.md).

Para o tema visual, use `../FinOps-Multicloud-Theme.json` (View > Themes > Browse for themes).
