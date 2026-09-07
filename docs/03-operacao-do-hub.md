# Operação do hub: retenção, rotina diária, reexecutar e remover

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [6. Retenção e histórico: quanto tempo de custo você guarda e enxerga](#6-retenção-e-histórico-quanto-tempo-de-custo-você-guarda-e-enxerga)
* [7. A rotina depois de instalado: o que roda sozinho e o que é manual](#7-a-rotina-depois-de-instalado-o-que-roda-sozinho-e-o-que-é-manual)
* [8. Reexecutar, atualizar e remover](#8-reexecutar-atualizar-e-remover)

---

## 6. Retenção e histórico: quanto tempo de custo você guarda e enxerga

Esta é a seção que mais gera dúvida depois da primeira carga, e por um bom motivo: existem **quatro controles
diferentes**, em três lugares diferentes, e cada um faz uma coisa. Se qualquer um estiver curto, você perde
histórico sem receber aviso nenhum.

### 6.1 O mapa completo

| # | Controle | Onde fica | O que faz |
|---|---|---|---|
| 1 | **Backfill** | Parâmetro do export | Quantos meses o Cost Management busca **para trás**, uma vez |
| 2 | **Retenção do hub** | `config/settings.json` | Quanto tempo o hub **guarda** cada camada de dado |
| 3 | **Ciclo de vida do storage** | Regra da storage account | O que **realmente apaga** o parquet antigo |
| 4 | **Number of Months** | Parâmetro do `.pbit` | Quantos meses **fechados** o relatório carrega |

Os quatro são independentes. O 1 traz o dado, o 2 declara a intenção, o 3 executa a exclusão e o 4 decide o que
aparece na tela.

### 6.2 O bloco `retention` do hub, campo por campo

O hub guarda a configuração em `config/settings.json`:

```json
{
  "$schema": "https://aka.ms/finops/hubs/settings-schema",
  "type": "HubInstance",
  "version": "14.0",
  "scopes": [],
  "retention": {
    "msexports": { "days":   0  },
    "ingestion": { "months": 13 },
    "raw":       { "days":   0  },
    "final":     { "months": 13 }
  }
}
```

| Campo | O que controla | Pode mudar depois do deploy? |
|---|---|---|
| `msexports.days` | Dias que o **arquivo bruto** do Cost Management fica no container `msexports`. `0` significa apagar assim que converter | **Sim.** Lido em tempo de execução, vale na próxima ingestão |
| `ingestion.months` | Meses de **parquet processado** no container `ingestion` | **Sim**, mas leia o aviso em 5.3 |
| `raw.days` | Retenção das tabelas `*_raw` no Data Explorer ou Eventhouse (nível 1) | **Não.** É aplicado como policy nas tabelas durante o deploy. Exige redeploy |
| `final.months` | Retenção das tabelas `*_final_v*` no Data Explorer ou Eventhouse (nível 1) | **Sim.** Lido em tempo de execução |

Esses valores e o comportamento de cada um foram confirmados por um colaborador do projeto na discussão #1947 do
repositório do toolkit, já que o bloco `retention` ainda não está na documentação oficial.

**Detalhe útil:** os relatórios Power BI **leem** o `settings.json`, mas só para mostrar os metadados do hub
(versão, quantidade de escopos, valores de retenção) no relatório **Data ingestion**. A retenção **não altera** o
que o Power BI consulta nem filtra. Se um relatório vier vazio, o problema não está aqui.

### 6.3 O aviso importante sobre `ingestion.months`

Hoje, `ingestion.months` **controla até onde o processo de backfill vai, mas não apaga blob antigo do storage**.
A limpeza automática do container `ingestion` ainda não foi implementada pelo toolkit.

Consequências práticas:

* **Aumentar** o valor é seguro e imediato. O dado novo passa a ser considerado.
* **Diminuir** o valor não libera espaço nenhum sozinho. O parquet antigo continua lá, e continua sendo lido pelo
  Power BI, o que pode fazer o relatório mostrar meses que você achou que tinha removido.
* Para **apagar de verdade**, use uma regra de **ciclo de vida** na storage account (item 5.5).

Isso também significa que **você não perde dado** se a retenção ficar menor que o backfill. O instalador ainda
ajusta a retenção para cima automaticamente, mas por coerência de configuração, não por risco de perda.

### 6.4 Mudando a retenção: o script

O kit traz o **`deploy/Set-FinOpsRetention.ps1`**, que lê e altera o bloco `retention` sem você precisar baixar,
editar e subir o JSON na mão.

**Ver a configuração atual** (não altera nada):

```powershell
./Set-FinOpsRetention.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub -Show
```

Saída típica:

```
  Versao do hub : 14.0

  Configuracao (config/settings.json > retention):

    CHAVE              VALOR    O QUE CONTROLA
    msexports.days     0        arquivo bruto do Cost Management (0 = apaga ao converter)
    ingestion.months   13       parquet processado no container ingestion
    raw.days           0        tabelas *_raw do Data Explorer / Eventhouse
    final.months       13       tabelas *_final_v* do Data Explorer / Eventhouse

  Meses de dado no storage hoje: 4  (2026-06 ate 2026-09)
  Use esse numero (ou maior) no parametro Number of Months dos relatorios Power BI.

  Regra de ciclo de vida 'finops-hub-ingestion-retention': nao existe.
  Sem ela, o parquet antigo NUNCA e apagado do storage.
```

**Guardar 24 meses:**

```powershell
./Set-FinOpsRetention.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub `
  -IngestionMonths 24 -FinalMonths 24
```

**Guardar o arquivo bruto por 7 dias** (útil quando você precisa abrir o CSV original para conferir um número):

```powershell
./Set-FinOpsRetention.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub -MsExportsDays 7
```

Lembre de voltar para `0` depois, senão você paga storage por arquivo que já foi convertido.

**Simular, sem gravar:**

```powershell
./Set-FinOpsRetention.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub -IngestionMonths 24 -WhatIf
```

### 6.5 Apagar de verdade: regra de ciclo de vida

Como o hub não apaga o parquet antigo, quem faz isso é a própria storage account. O script cria a regra para você:

```powershell
./Set-FinOpsRetention.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub `
  -IngestionMonths 24 -ApplyStorageLifecycle
```

O que ele cria: uma regra chamada `finops-hub-ingestion-retention`, com filtro no prefixo `ingestion/Costs`, que
apaga blob mais antigo que `meses x 31 + 15` dias. A margem de 15 dias existe para nunca apagar um mês que ainda
está sendo reexportado por ajuste de fatura.

Para remover a regra:

```powershell
./Set-FinOpsRetention.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub -RemoveStorageLifecycle
```

Três coisas a saber sobre ciclo de vida no Azure Storage:

1. O Azure avalia as regras **uma vez por dia**. A primeira execução pode levar até 48 horas.
2. Você precisa do papel **Storage Account Contributor** para criar ou alterar a regra.
3. A regra age no **blob**, não no `settings.json`. Mantenha os dois coerentes, ou você terá uma configuração que
   diz 24 meses e um storage que guarda 13.

**Fazendo pelo portal**, se preferir: storage do hub > **Data management > Lifecycle management** > **Add a rule**
> escopo *Limit blobs with filters* > prefixo `ingestion/Costs` > ação *Delete the blob* após N dias.

### 6.6 Alterando a retenção pelo instalador

Em uma instalação nova, ou em um redeploy, os valores vêm por parâmetro:

```powershell
./Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json `
  -BackfillMonths 24 `
  -IngestionRetentionInMonths 25
```

Ou no `parameters.json`:

```json
{
  "BackfillMonths": 24,
  "IngestionRetentionInMonths": 25
}
```

Use o instalador (e não o `Set-FinOpsRetention.ps1`) quando precisar mudar o **`raw.days`**, porque esse valor só
é aplicado nas tabelas do Data Explorer durante o deploy.

### 6.7 Escolhendo os valores: uma tabela de decisão

| Seu cenário | `msexports.days` | `ingestion.months` | `final.months` | Ciclo de vida |
|---|---|---|---|---|
| Piloto ou POC | 0 | 13 | 13 | não precisa |
| Produção, análise anual | 0 | 13 | 13 | 13 meses |
| Produção, comparação ano a ano | 0 | **25** | **25** | 25 meses |
| Auditoria ou exigência regulatória | 0 | **37** | **37** | 37 meses |
| Depurando uma carga | **7** | atual | atual | atual |

Por que 13, 25 e 37 em vez de 12, 24 e 36: você sempre quer **um mês a mais** que o período de comparação, porque
o mês corrente está aberto e não conta como fechado.

Sobre custo de storage: dado FOCUS comprime muito bem em parquet. Uma assinatura de porte médio gera algo entre
300 KB e 500 KB por mês. Mesmo 37 meses de várias assinaturas dificilmente passa de alguns GB, o que em storage
frio custa centavos. **Não economize retenção para economizar storage**, o custo do dado é irrelevante perto do
custo que ele te ajuda a enxergar.

### 6.8 Trazendo o histórico que ainda não chegou

Ampliar a retenção **não busca** meses passados, apenas permite guardá-los. Para buscar, use o backfill.

O `-Backfill` do `New-FinOpsCostExport` **só roda uma vez, na criação do export**. Depois disso, quem faz é o
`Start-FinOpsCostExport`:

```powershell
$scope = '/subscriptions/<sub-id>'

# 1) descubra o nome exato do export de custo
$nome = (Get-FinOpsCostExport -Scope $scope | Where-Object Dataset -eq 'FocusCost' | Select-Object -First 1).Name

# 2) puxe o historico
Start-FinOpsCostExport -Name $nome -Scope $scope -Backfill 24
```

Cada mês é uma execução de export. Vinte e quatro meses levam de 1 a 3 horas para aterrissar. Acompanhe com:

```powershell
$ctx = New-AzStorageContext -StorageAccountName <storage-do-hub> -UseConnectedAccount
Get-AzStorageBlob -Container ingestion -Context $ctx -Blob "Costs/*" |
  Where-Object { $_.Name -like "*.parquet" } |
  ForEach-Object { ($_.Name -split '/')[1..2] -join '-' } |
  Sort-Object -Unique
```

**A ordem correta é sempre esta:** ampliar a retenção, depois rodar o backfill, depois ajustar o relatório.

### 6.9 Fazendo o relatório enxergar os meses novos

O último controle é o do Power BI. Conte quantos meses existem (comando acima) e use esse número, ou maior, em
**Transform data > Manage Parameters > `Number of Months` > Close & Apply**.

**Nunca deixe esse parâmetro vazio.** Ele conta meses **fechados**, e em branco o filtro de data vira `null`, o
que devolve zero linhas sem erro nenhum. Isso está detalhado no [item 14 do diário de bordo (seção 16)](09-diario-de-bordo.md#14-relatório-carrega-sem-erro-e-mostra-zero-linhas-causa-b-number-of-months-vazio).

### 6.10 Até onde dá para ir

* **Cost Management**: mantém o dado por vários anos, então ele não é o limite prático.
* **Power BI storage reports**: a documentação do toolkit recomenda até cerca de **US$ 2 milhões por mês** de
  gasto monitorado, e sugere os **KQL reports** acima de **US$ 1 milhão por mês ou mais de 13 meses de dado**.
  Passando disso, o refresh começa a estourar tempo e o caminho é o **nível 1** (Eventhouse ou Data Explorer),
  que suporta refresh incremental.
* **Regra prática**: se você quer mais de 13 meses **e** tem gasto relevante, planeje o nível 1 desde já. A
  migração aproveita todo o dado que já está no `ingestion`.

---

## 7. A rotina depois de instalado: o que roda sozinho e o que é manual

Esta seção responde à pergunta "posso deixar rodando e só abrir os relatórios?". A resposta curta é **sim**.

### O ciclo diário, sem ninguém tocar em nada

| Quando | O que acontece | Quem faz |
|---|---|---|
| ~06:00 UTC | O Cost Management executa o export do mês corrente e grava um CSV em `msexports` | Cost Management |
| segundos depois | O trigger `msexports_ManifestAdded` detecta o `manifest.json` novo | Event Grid |
| ~1 a 3 min | A pipeline `msexports_ExecuteETL` chama `msexports_ETL_ingestion`, que converte para parquet e grava em `ingestion/Costs/aaaa/mm/{escopo}` | Data Factory |
| logo em seguida | O arquivo de origem é apagado do `msexports` (`retention.msexports.days = 0`) | Data Factory |
| todo dia 5 (aprox.) | O export mensal reexporta o **mês fechado**, para pegar ajustes de fatura | Cost Management |
| conforme a retenção | O hub apaga do `ingestion` o que passou de `retention.ingestion.months` | Data Factory |

Repare em duas consequências práticas:

1. **O `msexports` vive vazio, e isso é o certo.** Só sobram os `manifest.json`. Já perdi tempo achando que era
   falta de dado. O arquivo de origem é apagado depois de convertido, de propósito, para não pagar storage duas vezes.
2. **Cada carga substitui a pasta inteira do mês.** Por isso não existe duplicidade quando o mesmo mês é
   reexportado.

### O que você precisa fazer, e com que frequência

| Frequência | O que fazer |
|---|---|
| **Uma vez** | Instalar, criar os exports, configurar o `.pbit` (URL e Number of Months), publicar no Power BI Service |
| **Quando quiser ver o dado novo** | Power BI Desktop: botão **Refresh**. Power BI Service: configure o **Scheduled refresh** uma vez ao dia e nem isso é preciso |
| **Quando o histórico crescer além do parâmetro** | Aumentar o `Number of Months` no relatório |
| **Ao trocar credencial da AWS ou OCI** | Nova versão do segredo no Key Vault |
| **Ao atualizar o toolkit** | `Update-Module FinOpsToolkit` e reexecutar o instalador |

### Como saber, em 30 segundos, se está tudo bem

```powershell
$ctx = New-AzStorageContext -StorageAccountName <storage-do-hub> -UseConnectedAccount

# 1) o dado esta chegando? (a data do arquivo do mes corrente deve ser de hoje ou ontem)
Get-AzStorageBlob -Container ingestion -Context $ctx -Blob "Costs/*" |
  Where-Object { $_.Name -like "*.parquet" } |
  Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}, LastModified |
  Sort-Object LastModified -Descending | Format-Table -AutoSize

# 2) os triggers estao ligados? (todos precisam estar Started)
Get-AzDataFactoryV2Trigger -ResourceGroupName <rg> -DataFactoryName <adf-do-hub> |
  Select-Object Name, RuntimeState

# 3) alguma pipeline falhou nas ultimas 24h?
Get-AzDataFactoryV2PipelineRun -ResourceGroupName <rg> -DataFactoryName <adf-do-hub> `
  -LastUpdatedAfter (Get-Date).AddDays(-1) -LastUpdatedBefore (Get-Date).AddMinutes(10) |
  Where-Object Status -ne 'Succeeded' |
  Select-Object PipelineName, Status, RunStart, Message
```

Se os três passarem, não há nada a fazer. O relatório vai se encher sozinho.

---

## 8. Reexecutar, atualizar e remover

```powershell
# Atualizar o hub para a release mais recente do toolkit (mantém dados e configurações)
.\Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json

# Reaplicar só a extensão (pipelines, Function, Key Vault), sem tocar no hub
.\Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json -SkipHub

# Trocar o secret da AWS ou a chave da OCI: crie uma nova versão do segredo no Key Vault
# ou rode o comando acima (-SkipHub) com o novo valor no parameters.json

# Reprocessar um mês específico da AWS
Invoke-AzDataFactoryV2Pipeline -ResourceGroupName rg-finops-hub -DataFactoryName finops-hub-engine-abc123 `
    -PipelineName mc_aws_IngestFocusMonth -Parameter @{ billingPeriod = '2026-07' }

# Histórico da OCI: App setting OCI_MONTHS_BACK = 12, executar a Function uma vez, voltar para 1
```

**Remover:** use `deploy/Remove-FinOpsEnvironment.ps1` (`-Scope Hub` para só o hub, `-Scope All` para tudo). Apagar o
resource group à mão deixa para trás os exports do Cost Management (que ficam no escopo da assinatura e continuam
tentando gravar em um storage que não existe) e o Key Vault em soft delete (que bloqueia a reinstalação com o mesmo
nome). O script cuida dos dois. O ciclo completo de apagar e reinstalar está em
[Desligar, apagar e reinstalar](12-ligar-desligar-custos.md#apagar-remove-finopsenvironmentps1).
