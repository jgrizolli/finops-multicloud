# Power BI: relatorios do toolkit + pagina Multicloud

Os relatorios oficiais do FinOps toolkit (Cost summary, Rate optimization, Invoicing and chargeback,
Workload optimization, Policy and governance, Data ingestion) ja funcionam com os dados das tres nuvens,
porque tudo entra na mesma tabela `Costs` em FOCUS. O que muda e a **cor**: os dados de AWS e OCI
aparecem com `ProviderName` = AWS e Oracle e podem ser filtrados em qualquer pagina.

## Passo a passo
1. Baixe os **KQL reports** (hub com Fabric ou Data Explorer) ou os **Storage reports** (nivel 0, so storage):
   https://learn.microsoft.com/cloud-computing/finops/toolkit/power-bi/reports
2. Abra `CostSummary.pbit` (ou o `.pbix` demo) e informe os parametros: **Cluster URI** = Query URI do Eventhouse
   (ou Storage URL = endpoint DFS do storage do hub, para o nivel 0).
3. Aplique o tema: **View > Themes > Browse for themes > `FinOps-Multicloud-Theme.json`**
   (azul Microsoft 0078D4 como cor principal, laranja AWS FF9900 e vermelho Oracle C74634 para as series por nuvem).
4. Adicione uma pagina **Multicloud** com os visuais abaixo. Se o relatorio for KQL, crie uma consulta nova
   (Transform data > New source > Azure Data Explorer) apontando para a funcao `CostsAllocated()` do banco Hub.

## Pagina Multicloud (layout sugerido, 16:9)
| Posicao | Visual | Campos / medida | Objetivo |
|---|---|---|---|
| Faixa superior (4 cartoes) | Card | `SUM(EffectiveCost)`, variacao MoM (medida), economia identificada (`SUM(MonthlySavings)` de RecommendationsAll), `% alocado` | Ler o essencial em 5 segundos |
| Esquerda, meio | Donut | Legenda `Provider`, valor `EffectiveCost` | Peso de cada nuvem |
| Centro, meio | Colunas empilhadas | Eixo `ChargeDay`, legenda `Provider`, valor `EffectiveCost` | Tendencia diaria e picos |
| Direita, meio | Matriz | Linhas `CostCenter`/`BusinessUnit`, colunas `Provider`, valor `EffectiveCost` | Showback por dono |
| Faixa inferior | Barras horizontais (Top N 10) | `ServiceName` por `EffectiveCost`, com `Provider` na legenda | De onde vem o consumo |
| Faixa inferior, direita | Tabela | `RecommendationsAll()`: Provider, Category, Recurso, Economia/mes | Como reduzir |

### Medidas DAX uteis (relatorios KQL usam a tabela Costs)
```
Custo efetivo = SUM ( Costs[EffectiveCost] )
Custo mes anterior = CALCULATE ( [Custo efetivo], DATEADD ( 'Date'[Date], -1, MONTH ) )
Variacao MoM % = DIVIDE ( [Custo efetivo] - [Custo mes anterior], [Custo mes anterior] )
Custo alocado % = DIVIDE ( CALCULATE ( [Custo efetivo], Costs[IsAllocated] = TRUE () ), [Custo efetivo] )
```
Interacao: use `Provider` como filtro de pagina sincronizado em todas as paginas do relatorio.

## Boas praticas de apresentacao
* Uma mensagem por pagina; titulo em frase (ex.: "AWS cresceu 18% em agosto puxada por EC2").
* Cores fixas por nuvem em todas as paginas (Azure azul, AWS laranja, OCI vermelho).
* Numeros grandes com unidade e moeda; datas em pt-BR; sem gradientes e sem 3D.
* Publique no workspace Fabric e agende a atualizacao apos as cargas (08:30 UTC).
