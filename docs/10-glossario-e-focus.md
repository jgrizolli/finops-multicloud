# Glossário e as colunas FOCUS que você mais vai usar

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [17. Glossário](#17-glossário)
* [19. Apêndice B: as colunas FOCUS que você mais vai usar](#19-apêndice-b-as-colunas-focus-que-você-mais-vai-usar)

---

## 17. Glossário

| Termo | O que é |
|---|---|
| **FOCUS** | FinOps Open Cost and Usage Specification. Esquema aberto e padronizado de custo, mantido pela FinOps Foundation. É o que permite comparar Azure, AWS e OCI na mesma tabela |
| **FinOps hub** | Solução do FinOps toolkit que recebe, normaliza e organiza dados de custo. É o motor deste kit |
| **`msexports`** | Container onde o Cost Management deposita o arquivo bruto. É apagado depois da conversão. **Nunca grave nada aqui** |
| **`ingestion`** | Container com o dado já convertido em parquet, organizado por `Costs/aaaa/mm/{escopo}`. É daqui que o Power BI lê |
| **`config`** | Container com o `settings.json` do hub (versão, escopos, retenção) e os esquemas |
| **Managed export** | Export criado e mantido pelo próprio hub, a partir da lista de escopos no `settings.json`. Usa FOCUS 1.2-preview |
| **Export manual** | Export criado por você via `New-FinOpsCostExport`. Permite escolher a versão FOCUS. É o que o modo Storage usa |
| **Backfill** | Busca de meses passados. Roda **uma vez**, na criação do export, ou sob demanda via `Start-FinOpsCostExport` |
| **ETL** | Extract, Transform, Load. Aqui: converter o CSV do Cost Management em parquet normalizado |
| **Eventhouse** | Banco de dados do Microsoft Fabric Real-Time Intelligence, baseado no motor do Azure Data Explorer. É o nível 1 |
| **KQL** | Kusto Query Language, a linguagem do Eventhouse e do Data Explorer |
| **`.pbit`** | Template do Power BI. Traz visuais e medidas, mas nenhum dado. Ao abrir, pede os parâmetros |
| **`.pbix`** | Arquivo do Power BI com dados embutidos. É o que você salva depois de configurar um `.pbit` |
| **Endpoint DFS** | `https://<conta>.dfs.core.windows.net`. É a interface Data Lake Gen2. **Não confunda com o endpoint blob**, que os storage reports não aceitam |
| **Papel de plano de dados** | Papéis como `Storage Blob Data Reader`, que dão acesso ao **conteúdo** dos arquivos. Não são herdados de Owner nem de Contributor |
| **Scope (escopo)** | O nível do Azure que está sendo exportado: assinatura, resource group, billing account (EA) ou billing profile (MCA) |
| **`x_`** | Prefixo das colunas de **extensão** do FOCUS, específicas de um provedor. Ex.: `x_ResourceGroupName` |

---

## 19. Apêndice B: as colunas FOCUS que você mais vai usar

Referência rápida para montar visuais e escrever KQL. A lista completa está no dicionário de dados do toolkit.

### Dinheiro

| Coluna | O que significa | Quando usar |
|---|---|---|
| `BilledCost` | O que **entrou na fatura** no período | Conciliação com a fatura. É o número que o financeiro cobra de você |
| `EffectiveCost` | Custo **amortizado**, com a parcela de reservas e savings plans distribuída no tempo | Análise de consumo real, showback e chargeback |
| `ContractedCost` | Custo pelo **preço negociado**, sem descontos de compromisso | Base para calcular a economia gerada por reservas |
| `ListCost` | Custo pelo **preço de tabela**, sem nenhum desconto | Base para calcular a economia total |

**Economia total** = `ListCost - EffectiveCost`. **Economia por compromisso** = `ContractedCost - EffectiveCost`.

Use `BilledCost` para falar com finanças e `EffectiveCost` para falar com engenharia. Misturar os dois é a fonte
número um de discussão improdutiva em reunião de custo.

### Tempo

| Coluna | O que é |
|---|---|
| `ChargePeriodStart` / `ChargePeriodEnd` | Início e fim do período da linha. Em export diário, é o dia |
| `BillingPeriodStart` / `BillingPeriodEnd` | Início e fim do ciclo de faturamento (normalmente o mês) |

### Quem gastou

| Coluna | O que é |
|---|---|
| `BillingAccountId` / `BillingAccountName` | A conta de faturamento. Em MCA é o billing profile |
| `SubAccountId` / `SubAccountName` | A assinatura no Azure, a conta na AWS, o compartment na OCI |
| `x_ResourceGroupName` | Resource group. Coluna de extensão, específica do Azure |
| `Tags` | Marcadores. É aqui que mora o centro de custo, se a sua governança estiver em ordem |

### O que foi consumido

| Coluna | O que é |
|---|---|
| `ServiceName` | O serviço: Virtual Machines, Storage Accounts, API Management |
| `ServiceCategory` | A categoria: Compute, Storage, Networking, AI and Machine Learning |
| `ResourceId` / `ResourceName` | O recurso específico |
| `ResourceType` | O tipo do recurso |
| `RegionId` / `RegionName` | A região |
| `SkuId` / `SkuPriceId` | O SKU e o preço aplicado |
| `ConsumedQuantity` / `ConsumedUnit` | Quanto e em que unidade |

### Classificação da linha

| Coluna | Valores | Para que serve |
|---|---|---|
| `ChargeCategory` | `Usage`, `Purchase`, `Tax`, `Credit`, `Adjustment` | Separar consumo de compra. A página **Purchases** dos relatórios filtra por `Purchase` |
| `ChargeClass` | `Correction` ou vazio | Identificar ajustes retroativos |
| `ChargeFrequency` | `Recurring`, `Usage-Based`, `One-Time` | Separar custo fixo de variável |
| `CommitmentDiscountId` / `CommitmentDiscountName` | preenchido quando há reserva ou savings plan | Medir cobertura de compromisso |
| `PricingCategory` | `On-Demand`, `Committed`, `Dynamic` | Ver quanto do gasto está em preço cheio |

### Colunas do próprio toolkit

| Coluna | O que é |
|---|---|
| `x_SourceProvider` | De qual nuvem veio a linha. É o que permite o comparativo multicloud |
| `x_SourceChanges` | Códigos informativos do que o toolkit ajustou na normalização |
| `x_IngestionTime` | Quando a linha entrou no hub. Útil para monitorar atraso de dado |

### Três consultas que respondem quase tudo

```dax
Custo faturado  = SUM(Costs[BilledCost])
Custo efetivo   = SUM(Costs[EffectiveCost])
Economia        = SUM(Costs[ListCost]) - SUM(Costs[EffectiveCost])
```

```kusto
// custo por nuvem e por mes (nivel 1, no banco Hub)
Costs()
| summarize Efetivo = sum(EffectiveCost) by x_SourceProvider, ChargeMonth = startofmonth(ChargePeriodStart)
| order by ChargeMonth desc
```

```kusto
// top 20 recursos do mes
Costs()
| where ChargePeriodStart >= startofmonth(now())
| summarize Custo = sum(EffectiveCost) by ResourceName, ServiceName
| top 20 by Custo desc
```
