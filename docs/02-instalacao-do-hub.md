# Instalação do FinOps hub (script ou portal) e relatórios Power BI

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [4. Antes de começar (pré-requisitos)](#4-antes-de-começar-pré-requisitos)
* [5. Deploy por script (caminho recomendado)](#5-deploy-por-script-caminho-recomendado)
* [9. Deploy pelo portal (sem scripts)](#9-deploy-pelo-portal-sem-scripts)

---

## 4. Antes de começar (pré-requisitos)

### 4.1 Ferramentas na sua máquina (Windows, macOS ou Linux)

Abra o **PowerShell 7** (não o Windows PowerShell 5.1) e confira cada item. Os comandos de instalação estão logo abaixo de cada verificação.

```powershell
# 1) Versão do PowerShell: precisa começar com 7
$PSVersionTable.PSVersion
#    Se for 5.x, instale o PowerShell 7: https://aka.ms/powershell  (ou: winget install Microsoft.PowerShell)

# 2) Módulos Az e FinOpsToolkit
Get-Module -ListAvailable Az.Accounts, Az.Resources, Az.Storage, Az.DataFactory, Az.KeyVault, Az.Websites, FinOpsToolkit |
    Select-Object Name, Version
#    Se algum não aparecer:
Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
Install-Module -Name FinOpsToolkit -Scope CurrentUser -Repository PSGallery -Force

# 3) Azure CLI (usada para publicar o código da Function)
az version
#    Se não existir: https://aka.ms/installazurecli  (ou: winget install Microsoft.AzureCLI)

# 4) Bicep CLI NO PATH (obrigatório: o Deploy-FinOpsHub e o New-AzResourceGroupDeployment compilam .bicep)
bicep --version
#    Se der "bicep: command not found" / "não é reconhecido", instale e REABRA o PowerShell:
#      Windows : winget install -e --id Microsoft.Bicep
#      macOS   : brew install bicep
#      Linux   : curl -Lo bicep https://github.com/Azure/bicep/releases/latest/download/bicep-linux-x64 && chmod +x bicep && sudo mv bicep /usr/local/bin/
```

> **Atenção ao Bicep.** O comando `az bicep install` instala uma cópia privada da Azure CLI (em `~/.azure/bin`) que **não fica no PATH**.
> Só com ela, o `Deploy-FinOpsHub` falha com `Cannot find Bicep. Please add Bicep to your PATH`. Use uma das três formas acima
> (a do Windows via `winget` é a mais simples). O instalador deste pacote também tenta resolver sozinho: se `bicep` não estiver no PATH,
> ele procura a cópia da Azure CLI, e se não achar, baixa o executável para `~/.bicep` e o adiciona ao PATH da sessão.

Saída esperada do item 2 (as versões podem ser maiores):

```
Name            Version
----            -------
Az.Accounts     4.x
Az.Resources    7.x
Az.Storage      8.x
Az.DataFactory  1.x
Az.KeyVault     6.x
Az.Websites     3.x
FinOpsToolkit   12.x
```

> O módulo **FinOpsToolkit** precisa ser recente (release 12 ou posterior) para aceitar `-FabricQueryUri`, `-EnableManagedExports`
> e `-ScopesToMonitor`. Para atualizar: `Update-Module FinOpsToolkit -Force`.

### 4.2 Permissões: quem precisa de quê, e por quê

Esta é a parte que mais causa erro na instalação, então vale entender o desenho antes. Existem **dois atores**:

* **Você**, a pessoa que instala. Precisa poder criar recursos e conceder papéis.
* **A identidade gerenciada do Data Factory** do hub (aparece como `finops-hub-engine-xxxxx`). É ela que, depois de instalada,
  trabalha sozinha todos os dias: cria os exports, lê o custo, grava no storage e consulta as recomendações.

O instalador concede automaticamente os papéis da identidade que dependem de RBAC do Azure (etapa 3) e mostra quais já existiam.
Os papéis de billing (EA e MCA) não são RBAC e continuam sendo concedidos no portal de billing.

#### Papéis de quem instala (você)

| Papel | Em qual escopo | Para que serve | O que acontece sem ele |
|---|---|---|---|
| **Contributor** | Resource group do hub | Criar storage, Data Factory, Key Vault e os demais recursos | O deploy do hub falha logo no início |
| **Role Based Access Control Administrator** (ou **Owner**) | Resource group do hub, e a assinatura se for conceder papéis lá | Conceder papéis às identidades gerenciadas, que é o que a etapa 3 faz por você | O instalador avisa que não conseguiu conceder e você precisa pedir a alguém com esse direito |
| **Storage Blob Data Reader** (ou Contributor) | Storage account do hub | Ler os dados no Power BI e no Storage browser | Erro 403 no Power BI. **Esse papel não é herdado de Owner nem de Contributor**, precisa ser concedido explicitamente |

#### Papéis da identidade do Data Factory (concedidos pelo instalador)

| Papel | Em qual escopo | Para que serve | Erro típico se faltar |
|---|---|---|---|
| **Cost Management Contributor** | Assinatura (ou billing account) monitorada | Criar e executar os exports de custo em FOCUS. Cuidado: **Cost Management Reader não serve**, ele apenas lê exports existentes | `RBACAccessDenied` com HTTP 401 na pipeline `config_ConfigureExports` |
| **User Access Administrator** | Storage account do hub | Ao criar um export, o Cost Management precisa atribuir um papel a si mesmo na storage de destino, e quem chama a API precisa poder gravar essa atribuição | `The user does not have authorization to perform 'Microsoft.Authorization/roleAssignments/write' action on specified storage account` |
| **Reader** | Assinatura monitorada | Consultas ao Azure Resource Graph que geram as recomendações (discos órfãos, VMs paradas, IPs soltos, Hybrid Benefit) | As recomendações do Azure ficam vazias. O custo continua funcionando |
| **Storage Blob Data Contributor**, **Storage Account Contributor** | Storage account do hub | Gravar e ler os arquivos durante a ingestão | Concedidos pelo próprio template do hub, normalmente não exigem ação |
| **Enterprise Reader** ou **Department Reader** | Enrollment EA | Criar exports em escopo de billing EA. Não é RBAC do Azure, é concedido no portal de EA | Exports em escopo de billing não são criados |
| **Contributor no billing profile** | Billing profile MCA | Equivalente ao anterior em contratos MCA. Lembre que **MCA não suporta managed exports**: use `"ManualExports": true` | Exports não são criados |

Se preferir conceder à mão, os comandos são estes (troque os identificadores pelos seus, que o instalador imprime na etapa 2):

```powershell
$mi  = '<object id da identidade do Data Factory>'
$sub = '/subscriptions/<id da assinatura>'
$sa  = '<resource id da storage account do hub>'

New-AzRoleAssignment -ObjectId $mi -RoleDefinitionName 'Cost Management Contributor' -Scope $sub
New-AzRoleAssignment -ObjectId $mi -RoleDefinitionName 'Reader'                      -Scope $sub
New-AzRoleAssignment -ObjectId $mi -RoleDefinitionName 'User Access Administrator'   -Scope $sa

# conferir tudo o que a identidade tem hoje
Get-AzRoleAssignment -ObjectId $mi | Select-Object RoleDefinitionName, Scope
```

O RBAC do Cost Management leva de **5 a 30 minutos** para propagar. O instalador já conta com isso: ele tenta criar os exports
algumas vezes, com intervalo, antes de desistir.

#### A tag `SecurityControl = Ignore`

Não é um papel, é uma tag no resource group, e serve para um caso específico: assinaturas com política de segurança que **desliga o
acesso por chave** nas storage accounts (o padrão em assinaturas internas da Microsoft, e possível em qualquer tenant com a política
*Storage accounts should prevent shared key access*). O template oficial do hub usa deployment scripts que montam um file share por
chave, e sem essa exceção o deploy falha com `KeyBasedAuthenticationNotPermitted`. Configure com
`"ResourceGroupTags": { "SecurityControl": "Ignore" }` no `parameters.json`. Em tenants de clientes, o equivalente é criar uma
**isenção da política** para o resource group.

### 4.3 Informações que você vai precisar (anote antes)

| Valor | Onde encontrar | Exemplo |
|---|---|---|
| Subscription ID do Azure | Portal > Subscriptions | `1111aaaa-2222-bbbb-3333-cccc4444dddd` |
| Escopo(s) de custo | EA: Cost Management + Billing > Billing scopes > Properties (número do enrollment). Assinatura: Subscriptions > Overview | `/providers/Microsoft.Billing/billingAccounts/1234567` ou `/subscriptions/<id>` |
| Query URI do Eventhouse (nível 1) | Fabric > Eventhouse > System overview > Query URI | `https://trd-abc123.z0.kusto.fabric.microsoft.com` |
| Bucket, prefixo, nome do export e conta pagadora (AWS) | Console AWS > S3 e Data Exports | `finops-focus-exports-123456789012`, `focus`, `finops-focus-1-0`, `123456789012` |
| Access key e secret do usuário IAM (AWS) | IAM > Users > Security credentials | `AKIA...` / `wJalr...` |
| OCID da tenancy, OCID do usuário, fingerprint, região home, arquivo `.pem` (OCI) | Console OCI > Profile > Tenancy; usuário > API keys | `ocid1.tenancy.oc1..aaaa`, `ocid1.user.oc1..aaaa`, `aa:bb:...`, `sa-saopaulo-1` |

---

## 5. Deploy por script (caminho recomendado)

O instalador `deploy/Deploy-FinOpsMulticloud.ps1` é **idempotente**: pode ser executado quantas vezes for preciso.
Ele tem sete etapas e imprime, em cada uma, o que está fazendo e para que serve.

| Etapa | O que faz |
|---|---|
| 1 | Verifica módulos (FinOpsToolkit 12 ou superior), garante o Bicep CLI no PATH, faz login, seleciona a assinatura, cria o resource group |
| 2 | `Deploy-FinOpsHub` (motor oficial) em modo Storage, Fabric ou DataExplorer |
| 3 | Escopos do Azure: concede os papéis da identidade do Data Factory, cria os exports (repetindo enquanto o RBAC propaga) e dispara a primeira execução mais o backfill |
| 4 | Compila e implanta o Bicep da extensão: Key Vault + segredos, pipelines `mc_aws_*`, Function App OCI, RBAC |
| 5 | Grava `config/multicloud/manifest.json`, inicia os triggers, dispara a primeira carga da AWS |
| 6 | Publica o código do conector OCI |
| 7 | Resumo, verificação (lista os exports criados e conta os arquivos já gravados) e passos manuais restantes |

### Passo 1. Descompacte e abra a pasta `deploy`

```powershell
Expand-Archive -Path .\finops-multicloud-kit.zip -DestinationPath C:\finops -Force
Set-Location C:\finops\finops-multicloud-kit\deploy
Get-ChildItem
```

Você deve ver `Deploy-FinOpsMulticloud.ps1`, `multicloud-extension.bicep` e `parameters.example.json`.

### Passo 2. Entre no Azure e confirme a assinatura

```powershell
Connect-AzAccount
Set-AzContext -Subscription "1111aaaa-2222-bbbb-3333-cccc4444dddd"
Get-AzContext | Select-Object Name, Subscription, Tenant

az login
az account set --subscription "1111aaaa-2222-bbbb-3333-cccc4444dddd"
az account show --query "{nome:name, id:id}" -o table
```

Os dois logins são necessários: o PowerShell (módulos Az) faz o deploy; a Azure CLI publica o código da Function.

### Passo 3. Só para o nível 1: prepare o Fabric antes do script

O script não cria o Eventhouse (isso é feito na interface do Fabric). Faça uma vez:

1. Fabric > workspace (com capacidade F2) > **New item > Eventhouse** > nome `FinOpsHub`.
2. **+ Database** > `Ingestion`. Abra `Ingestion_queryset`, cole o arquivo `finops-hub-fabric-setup-Ingestion.kql`
   (baixe da release mais recente em `github.com/microsoft/finops-toolkit/releases`), substitua `$$rawRetentionInDays$$` por `0`
   (Ctrl+H, depois Ctrl+Alt+Enter) e execute tudo (Ctrl+Home, Shift+Enter).
3. **+ Database** > `Hub`. Repita com `finops-hub-fabric-setup-Hub.kql`.
4. **System overview > Query URI > Copy URI**. Esse é o valor de `FabricQueryUri`.

### Passo 4. Prepare o arquivo de parâmetros

```powershell
Copy-Item .\parameters.example.json .\parameters.json
notepad .\parameters.json      # ou: code .\parameters.json
```

> **Edite sempre a cópia `parameters.json`, nunca o `parameters.example.json`.** O arquivo de exemplo é o modelo do kit e é
> **substituído** a cada atualização do pacote (inclusive pela sincronização do OneDrive); se você preencher o exemplo, os seus
> valores voltam para `00000000-0000-0000-0000-000000000000` na próxima atualização e o deploy falha com
> `The subscription '00000000-...' could not be found`. O `parameters.json` não faz parte do kit e nunca é sobrescrito.
> O script avisa se for executado com o arquivo de exemplo e recusa IDs de exemplo.

Para descobrir o ID da assinatura e conferir o tenant em que você está conectado:

```powershell
Get-AzSubscription | Select-Object Name, Id, TenantId
```

Exemplo preenchido para o **nível 0, só Azure** (o mais simples para começar):

```json
{
  "SubscriptionId": "1111aaaa-2222-bbbb-3333-cccc4444dddd",
  "ResourceGroup": "rg-finops-hub",
  "Location": "brazilsouth",
  "HubName": "finops-hub",

  "Mode": "Storage",

  "ScopesToMonitor": [ "/subscriptions/1111aaaa-2222-bbbb-3333-cccc4444dddd" ],
  "ManualExports": false,
  "BackfillMonths": 3,
  "IngestionRetentionInMonths": 13,
  "EnableRecommendations": true,

  "SkipAws": true,
  "SkipOci": true,

  "Tags": { "solution": "finops-multicloud", "owner": "finops-team", "environment": "prod" },
  "ResourceGroupTags": { "SecurityControl": "Ignore" }
}
```

Exemplo preenchido para o **nível 1 com as três nuvens**:

```json
{
  "SubscriptionId": "1111aaaa-2222-bbbb-3333-cccc4444dddd",
  "ResourceGroup": "rg-finops-hub",
  "Location": "brazilsouth",
  "HubName": "finops-hub",

  "Mode": "Fabric",
  "FabricQueryUri": "https://trd-abc123.z0.kusto.fabric.microsoft.com",
  "FabricCapacityUnits": 2,

  "ScopesToMonitor": [ "/providers/Microsoft.Billing/billingAccounts/1234567" ],
  "ManualExports": false,
  "BackfillMonths": 3,
  "IngestionRetentionInMonths": 13,
  "EnableRecommendations": true,

  "SkipAws": false,
  "AwsBucketName": "finops-focus-exports-123456789012",
  "AwsS3Prefix": "focus",
  "AwsExportName": "finops-focus-1-0",
  "AwsPayerAccountId": "123456789012",
  "AwsRegion": "us-east-1",
  "AwsAccessKeyId": "AKIAIOSFODNN7EXAMPLE",
  "AwsSecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "AwsRecommendations": true,
  "AwsRecommendationsExportName": "finops-coh-recommendations",

  "SkipOci": false,
  "OciTenancyOcid": "ocid1.tenancy.oc1..aaaaaaaaexemplo",
  "OciUserOcid": "ocid1.user.oc1..aaaaaaaaexemplo",
  "OciFingerprint": "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99",
  "OciRegion": "sa-saopaulo-1",
  "OciPrivateKeyPath": "C:\\finops\\segredos\\oci-finops-reader.pem",
  "OciNoRecommendations": false,

  "Tags": { "solution": "finops-multicloud", "owner": "finops-team", "environment": "prod" },
  "ResourceGroupTags": { "SecurityControl": "Ignore" }
}
```

Regras do arquivo:

* As chaves são exatamente os nomes dos parâmetros do script (maiúsculas e minúsculas importam).
* `Mode` aceita `Storage`, `Fabric` ou `DataExplorer`. `Fabric` exige `FabricQueryUri`; `DataExplorer` exige `DataExplorerName`.
* Contas **MCA**: use `"ManualExports": true` (managed exports não são suportados em MCA).
* No Windows, caminhos em JSON usam barra dupla (`C:\\pasta\\arquivo.pem`).
* `ResourceGroupTags` vai só para o resource group. `{ "SecurityControl": "Ignore" }` é necessário em assinaturas internas da Microsoft e em
  tenants cuja política desliga o acesso por chave em storage (ver aviso na [seção 4.2](#42-permissões-quem-precisa-de-quê-e-por-quê)). Em assinaturas sem essa política, deixe `{ }`.
* **Nunca** versione `parameters.json` com segredos. Apague-o ao terminar ou guarde em local seguro.
* Se AWS ou OCI ainda não estiverem preparadas, deixe `"SkipAws": true` e/ou `"SkipOci": true`. Valores de exemplo (`AKIA....`, `./oci-finops-reader.pem`)
  fazem a etapa 4 falhar. Acrescente cada nuvem depois, rodando o script com `-SkipHub`.

### Passo 5. Execute o instalador

Nível 0, só Azure (cerca de 10 a 15 minutos):

```powershell
.\Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json
```

O mesmo, sem arquivo de parâmetros:

```powershell
.\Deploy-FinOpsMulticloud.ps1 `
    -SubscriptionId  "1111aaaa-2222-bbbb-3333-cccc4444dddd" `
    -ResourceGroup   "rg-finops-hub" `
    -Location        "brazilsouth" `
    -HubName         "finops-hub" `
    -Mode            Storage `
    -ScopesToMonitor "/subscriptions/1111aaaa-2222-bbbb-3333-cccc4444dddd" `
    -SkipAws -SkipOci
```

Nível 1 com Fabric e AWS, ainda sem OCI (a secret da AWS é pedida na tela, sem ficar no histórico):

```powershell
.\Deploy-FinOpsMulticloud.ps1 `
    -SubscriptionId    "1111aaaa-2222-bbbb-3333-cccc4444dddd" `
    -ResourceGroup     "rg-finops-hub" `
    -Location          "brazilsouth" `
    -HubName           "finops-hub" `
    -Mode              Fabric `
    -FabricQueryUri    "https://trd-abc123.z0.kusto.fabric.microsoft.com" `
    -ScopesToMonitor   "/providers/Microsoft.Billing/billingAccounts/1234567" `
    -AwsBucketName     "finops-focus-exports-123456789012" `
    -AwsPayerAccountId "123456789012" `
    -AwsRegion         "us-east-1" `
    -AwsAccessKeyId    "AKIAIOSFODNN7EXAMPLE" `
    -AwsSecretAccessKey (Read-Host -AsSecureString "Secret access key da AWS") `
    -AwsRecommendations `
    -SkipOci
```

Acrescentar a OCI depois, sem reinstalar o hub (preencha os campos `Oci*` no `parameters.json` e mude `SkipOci` para `false`):

```powershell
.\Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json -SkipHub
```

Durante a execução você verá blocos como este, um por etapa:

```
====================================================================================================
  Etapa 2 de 7: FinOps hub (motor da solucao)
  Para que serve: cria storage (msexports/ingestion/config), Data Factory com as pipelines oficiais ...
====================================================================================================
  Deploy-FinOpsHub em modo Fabric...
  Storage do hub : finopshubstoreabc123
  Data Factory   : finops-hub-engine-abc123
  Identidade ADF : 3f2a1111-2222-3333-4444-555566667777
```

Ao final, a **Etapa 7** imprime os passos manuais que restam (comandos `.add database` do Fabric, conferências da AWS e da OCI).
Copie essa saída.

### Passo 6. Termine no Fabric (só nível 1)

No Eventhouse, banco `Ingestion`, execute os dois comandos impressos pela etapa 7 (troque pelo Object ID real):

```kusto
.add database Ingestion admins ('aadapp=3f2a1111-2222-3333-4444-555566667777')
.add database Hub admins ('aadapp=3f2a1111-2222-3333-4444-555566667777')
```

No banco `Hub`, cole e execute o arquivo `kql/01-multicloud-functions.kql` inteiro. Depois carregue o mapa de contas
(exemplo; troque pelos seus valores):

```kusto
.set-or-append CostCenterMap <|
    datatable(Provider:string, AccountId:string, AccountName:string, CostCenter:string, BusinessUnit:string, Application:string, Owner:string, Environment:string)[
        "Azure", "1111aaaa-2222-bbbb-3333-cccc4444dddd", "sub-prod-core", "CC-1001", "Digital",    "Portal",    "ana.souza",  "prod",
        "AWS",   "123456789012",                          "prod-data",     "CC-2002", "Dados",      "Lakehouse", "joao.lima",  "prod",
        "OCI",   "ocid1.compartment.oc1..aaaa",          "erp-prod",      "CC-3003", "Financeiro", "ERP",       "carla.reis", "prod"
    ]
```

### Passo 7. Dashboards

**Nível 1 (Fabric Real-Time Dashboard)**

1. Fabric > workspace > **New item > Real-Time Dashboard** > nome `FinOps Multicloud`.
2. **Manage > Replace with file** > `dashboards/finops-multicloud-realtime-dashboard.json`.
3. **Manage > Data sources** > editar a fonte `Hub` > escolher o seu Eventhouse e o banco `Hub` > Connect > Apply.

Se a importação do dashboard recusar a versão do arquivo, crie um dashboard vazio e adicione os blocos com as consultas
de `kql/02-dashboard-queries.kql` (cada consulta indica o visual).

**Nível 0 e nível 1 (relatórios Power BI do toolkit)**

O toolkit publica seis relatórios prontos (Cost summary, Rate optimization, Invoicing and chargeback, Workload
optimization, Policy and governance, Data ingestion) em `github.com/microsoft/finops-toolkit/releases/latest`.
São arquivos `.pbit`, ou seja **modelos**: trazem todos os visuais e medidas, mas nenhum dado. Escolha o pacote
pela origem do dado:

| Pacote | Lê de | Quando usar |
|---|---|---|
| `PowerBI-demo.zip` | Dados de exemplo embutidos | Só para conhecer os relatórios, sem conectar nada |
| `PowerBI-storage.zip` | Storage account do hub (parquet) | **Nível 0** |
| `PowerBI-kql.zip` | Eventhouse ou Data Explorer | **Nível 1** |

Passos:

1. Baixe e extraia o pacote, e abra o `.pbit` desejado no Power BI Desktop.
2. Preencha os parâmetros:
   * **Nível 0**: cole a **Storage URL** (endpoint DFS, terminado em `.dfs.core.windows.net`, nunca o de blob)
     em *Hub storage URL* e em *Export storage URL*. O valor está em resource group > Deployments > deployment do
     hub > Outputs > `storageUrlForPowerBI`.
   * **Nível 1**: cole o **Cluster URI** (o mesmo Query URI do Eventhouse) e escolha *Daily* ou *Monthly*.
   * *Number of Months*: comece com `3`. Deixe `RangeStart` e `RangeEnd` vazios.
3. Aplique o tema `dashboards/powerbi/FinOps-Multicloud-Theme.json` (View > Themes > Browse for themes).

#### Credenciais: cada fonte pede um tipo diferente

Esta é a parte que mais confunde. O Power BI mostra a mesma caixa **Access Web content** várias vezes, uma por
fonte, e o tipo certo **muda conforme a URL que aparece no alto da caixa**. Leia a URL antes de escolher:

| URL na caixa | O que é | Tipo a escolher |
|---|---|---|
| `https://github.com/...` | Tabelas públicas de apoio do toolkit (regiões, serviços, tipos de recurso, unidades de preço) | **Anonymous** |
| `https://ccmstorageprod.blob.core.windows.net/...AutofitComboMeterData.csv` | Tabela pública de flexibilidade de tamanho de reserva | **Anonymous** |
| `https://<storage-do-hub>.dfs.core.windows.net/` | O seu dado de custo | **Organizational account** > Sign in |
| Azure Data Explorer / Eventhouse (nível 1) | O seu dado de custo | **Organizational account** > Sign in |
| Azure Resource Graph | Metadados de recursos | **Organizational account** > Sign in |

As duas primeiras são arquivos públicos e **não têm login**. Escolher *Organizational account* nelas devolve
`We were unable to connect because this credential type isn't supported for this resource`.

Para refazer uma escolha errada: **Transform data > Data source settings > Edit permissions > Clear permissions**.
Para limpar tudo: **File > Options and settings > Data source settings > Global permissions**.

#### A versão FOCUS tem que bater com o relatório (causa nº 1 de relatório quebrado no nível 0)

Este é o ponto mais importante desta seção. O template do FinOps hub cria os *managed exports* na versão
**FOCUS 1.2-preview**. A conversão de 1.2 para o esquema 1.0 acontece **somente na ingestão do Azure Data
Explorer e do Microsoft Fabric** (changelog do toolkit v12: *"Added full support for FOCUS 1.2 in Azure Data
Explorer and Microsoft Fabric... This change does not include Power BI and Data Explorer dashboard updates.
Those are still using the \*\_v1\_0 functions"*).

No **modo Storage (nível 0) não existe essa conversão**: o parquet que chega ao container `ingestion` mantém
o esquema 1.2-preview, e os relatórios do `PowerBI-storage.zip` leem o esquema **FOCUS 1.0**. O resultado é
um erro no carregamento:

```
Load
3 queries are blocked by the following error:
  Costs
     The column 'SkuMeterName' of the table wasn't found.
  Query parameters
```

A explicação está no dicionário de dados do toolkit: a coluna `x_SkuMeterName` do FOCUS 1.0 foi **renomeada
para `SkuMeter` no FOCUS 1.2**. O relatório procura o nome antigo e não encontra.

**Regra prática:**

| Nível | Consumo | Versão FOCUS dos exports |
|---|---|---|
| **0 (Storage)** | Relatórios Power BI storage | **1.0r2** |
| **1 (Fabric / Data Explorer)** | KQL reports e Real-Time Dashboard | **1.2-preview** (o hub converte na ingestão) |

O instalador já cuida disso: no modo `Storage` ele liga `-ManualExports` sozinho e cria os exports em
`1.0r2`. Se o seu ambiente já foi implantado com managed exports em 1.2-preview, corrija com o script
`deploy/Repair-FocusVersion.ps1`:

```powershell
./Repair-FocusVersion.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub
```

Ele faz, nesta ordem: esvazia a lista de escopos em `config/settings.json` (para o hub parar de recriar os
managed exports), remove os exports `FocusCost` na versão errada, limpa `ingestion/Costs` e `msexports`,
e cria exports novos em `1.0r2` com backfill. Use `-WhatIf` para ver o que ele faria sem alterar nada.

Um export **não permite trocar a versão depois de criado**. Por isso o caminho é apagar e recriar.

#### Sempre saia do Power Query por Close & Apply

Se você entrar em **Transform data** (para conferir linhas, ver um erro ou trocar um parâmetro), **saia clicando em
`Close & Apply`**. Fechar pelo X ou por `Close` deixa as alterações pendentes, e o relatório abre **com todas as
páginas em branco**, sem mensagem de erro nenhuma. O sintoma é uma tarja amarela no alto da tela:

```
There are pending changes in your queries that haven't been applied.   [Apply changes]
One or more calculated columns need to be manually refreshed.          [Refresh now]
Some of the tables have incomplete or no data.                         [Refresh now]
```

Correção: clique em **Apply changes** na primeira tarja e aguarde o carregamento terminar. Depois, se as outras
duas continuarem visíveis, clique no **Refresh now** de cada uma. Em último caso, faixa **Home > Refresh**.

#### Os seis relatórios: o que cada um exige

Depois que o primeiro relatório funcionar, os outros abrem **do mesmo jeito**: mesmo `.pbit`, mesma URL, mesmas
credenciais. Não há configuração adicional. O que muda é **de qual export cada um depende**, e é por isso que
alguns vão abrir cheios e outros vão abrir parcialmente vazios no mesmo ambiente.

| Relatório | Para que serve | Exports que exige |
|---|---|---|
| **CostSummary** | Visão geral de custo amortizado, com as quebras mais comuns | FOCUS (+ price sheet, recomendado) |
| **DataIngestion** | Saúde do pipeline: meses, escopos, versões, erros de normalização | FOCUS |
| **InvoicingAndChargeback** | Conciliação de fatura, tendência de custo faturado, chargeback | FOCUS (+ reservation transactions, opcional) |
| **RateOptimization** | Economia atual e potencial com reservas e savings plans | FOCUS + **reservation recommendations** (obrigatório para ver recomendações), reservation details e transactions (recomendados) |
| **WorkloadOptimization** | Oportunidades de eficiência em recurso e uso | FOCUS + **Azure Resource Graph** |
| **PolicyAndGovernance** | Postura de governança: conformidade, segurança, gestão de recursos | FOCUS + **Azure Resource Graph** |

**Comece pelo `DataIngestion`.** Ele é o diagnóstico: mostra quais meses e escopos chegaram, qual versão FOCUS
está em uso e quais correções o toolkit aplicou. Se algo estiver errado no dado, ele te conta antes de você
perder tempo nos outros.

#### O que esperar no seu ambiente

Três avisos honestos, para você não achar que quebrou:

**1. Price sheet, reservas e transações só existem em escopo de faturamento.** Esses exports exigem
**billing account (EA)** ou **billing profile (MCA)**. Em escopo de **assinatura**, eles não podem ser criados.
Consequência: no `RateOptimization`, a parte de recomendações fica vazia, e no `CostSummary` a coluna `ListCost`
pode vir aproximada.

**2. `WorkloadOptimization` e `PolicyAndGovernance` consultam o Azure Resource Graph**, não o seu storage. São
duas fontes distintas no mesmo relatório. Você vai autenticar em `management.azure.com` com
**Organizational account**, e o resultado depende de a sua conta ter leitura nas assinaturas. Se o Resource Graph
não responder, esses relatórios abrem com as páginas de custo preenchidas e as de inventário vazias.

**3. A página `Purchases` fica vazia sem compras.** Ela filtra `ChargeCategory = "Purchase"`, que só existe se
houver reserva, savings plan ou marketplace. Consumo pay-as-you-go é `Usage`. Vazia ali é o resultado correto.

#### Habilitando os relatórios que faltam

Para ativar o `RateOptimization` por completo, você precisa dos exports de reserva, e eles só existem em escopo de
faturamento. Descubra os seus escopos disponíveis:

```powershell
# billing accounts aos quais voce tem acesso
Get-AzBillingAccount | Select-Object Name, DisplayName, AccountType
```

Com um escopo de faturamento em mãos, o instalador cria os cinco datasets de uma vez:

```powershell
./Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json -SkipHub `
  -ScopesToMonitor '/providers/Microsoft.Billing/billingAccounts/<id-do-enrollment>'
```

Ele detecta que o escopo é de faturamento e cria `FocusCost`, `PriceSheet`, `ReservationDetails`,
`ReservationRecommendations` e `ReservationTransactions`.

Para `WorkloadOptimization` e `PolicyAndGovernance`, não há export a criar. Basta que a conta que abre o relatório
tenha **Reader** nas assinaturas que você quer inventariar.

#### Um atalho quando abrir vários relatórios

As credenciais do Power BI são **globais**, não ficam dentro do arquivo. Depois de autenticar no primeiro
relatório, os outros **não vão pedir login de novo**, desde que você tenha aplicado a credencial do storage no
nível da **raiz** da conta (`https://<storage>.dfs.core.windows.net`) e não no nível do container.

Ou seja: acerte o primeiro com calma, e os cinco seguintes são só abrir, colar a URL e o número de meses.

#### Como validar que carregou

Julgue o relatório pelas páginas certas:

| Página | O que esperar |
|---|---|
| `DQ` | Diagnóstico de qualidade dos dados. É a primeira que você deve abrir |
| `Summary` | Custo total e tendência. Se tiver número aqui, está funcionando |
| `Services`, `Resource groups`, `Resources` | Devem listar o que existe na assinatura |
| `Purchases` | **Vazia por design** se você não tem reservas, savings plans nem compras de marketplace |
| `Prices` | Vazia sem o export de price sheet (EA ou MCA) |
| `Inventory`, `Regions` | Dependem do Azure Resource Graph |

Contagem exata de linhas: **Transform data > consulta `Costs` >** barra cinza no rodapé da janela **> Close & Apply**.

#### `.pbit` e `.pbix`: por que reabrir pede tudo de novo

Esta é a dúvida que aparece assim que o primeiro relatório funciona. A resposta está na diferença entre os dois
formatos:

| Formato | O que guarda | Ao abrir |
|---|---|---|
| **`.pbit`** (template) | Visuais, medidas e a **definição** dos parâmetros. **Nenhum dado e nenhum valor preenchido** | **Sempre pergunta os parâmetros de novo.** É o comportamento correto dele |
| **`.pbix`** (relatório) | Tudo do template **mais os valores dos parâmetros e os dados carregados** | Abre pronto, com o dado da última atualização |

Ou seja: o `.pbit` é o molde, e você usa **uma vez por relatório**. O `.pbix` é a peça pronta, e é o que você
guarda e reabre.

**Salve como `.pbix` assim que o relatório carregar:**

**File > Save as** > escolha a pasta > nome, por exemplo `FinOps-CostSummary.pbix`.

A partir daí, é só dar duplo clique no `.pbix`. Ele abre com o dado da última vez que você atualizou, sem
perguntar nada. Para trazer o dado novo, botão **Refresh** na faixa Home.

Uma observação sobre as credenciais: elas **não ficam dentro do arquivo**, ficam salvas globalmente na sua
instalação do Power BI Desktop (**File > Options and settings > Data source settings > Global permissions**). Por
isso o segundo, o terceiro e o quarto relatório não pedem login de novo. E por isso também, ao levar o `.pbix`
para outra máquina, ele pede autenticação uma vez.

Sugestão de organização, já pensando em entregar isso a um cliente:

```
FinOps-Reports/
├── originais/                       <- os .pbit baixados, nunca alterados
│   ├── CostSummary.pbit
│   ├── DataIngestion.pbit
│   └── ...
└── configurados/                    <- os .pbix que voce usa no dia a dia
    ├── FinOps-CostSummary.pbix
    ├── FinOps-DataIngestion.pbix
    └── ...
```

Guarde os `.pbit` originais. Quando o toolkit lançar uma versão nova dos relatórios, você repete o processo a
partir do template novo, em vez de tentar migrar o `.pbix` antigo.

#### Deixar atualizando sozinho: publicar no Power BI Service

O `.pbix` no Desktop só atualiza quando você clica em **Refresh**. Para o dado se atualizar sozinho, sem a sua
máquina ligada, publique no serviço.

**1. Publicar**

No Desktop, faixa **Home > Publish** > escolha um workspace > **Select**. Ao terminar, ele oferece o link
**Open ... in Power BI**. O relatório passa a existir em `app.powerbi.com`, abre em navegador e celular, e pode
ser fixado como aba no Teams.

**2. Informar a credencial no serviço**

A credencial do Desktop **não vai junto**. No workspace:

**Semantic model** (o item com o mesmo nome do relatório) > **Settings** > **Data source credentials** >
**Edit credentials** > **OAuth2** > **Sign in**.

Faça isso para cada fonte que aparecer. As fontes públicas (GitHub, `ccmstorageprod`) ficam em **Anonymous**,
igual ao Desktop.

**3. Agendar a atualização**

Ainda em **Settings** do semantic model > **Refresh** > ligue **Configure a refresh schedule**:

| Campo | Sugestão |
|---|---|
| Frequência | **Daily** |
| Horário | **09:00** e, se quiser folga, **15:00** no seu fuso |
| Time zone | o seu |
| Notificação de falha | ligue, com o seu email |

Por que 09:00: o Cost Management executa o export por volta das 06:00 UTC, e a ingestão leva alguns minutos.
Atualizar de manhã, no seu fuso, garante que o dado do dia já chegou.

Uma vez ao dia basta. O dado de custo é diário, atualizar de hora em hora só consome capacidade sem trazer
informação nova.

**4. Conferir**

Ainda em **Settings > Refresh history**, você vê cada execução, com status e duração. Se falhar, o erro aparece
ali, e o email chega se você ligou a notificação.

#### ATENÇÃO: o detalhe que impede a atualização agendada

Existe um comportamento do conector que derruba a atualização agendada, e não é nada óbvio.

Quando o Power BI recebe uma URL **com caminho** (por exemplo `https://<conta>.dfs.core.windows.net/ingestion`),
ele **não a reconhece como Azure Data Lake Storage Gen2**. Passa a tratar como fonte genérica de arquivo ou web, e
**nesse modo o Power BI Service não permite atualização agendada**, mesmo com a autenticação funcionando. O
sintoma é a mensagem *"You cannot schedule refresh for this dataset"*.

O que resolve: estabelecer a conexão **no nível da conta de storage** e navegar pelos containers dentro do Power
Query.

Para os **relatórios do toolkit isso já está resolvido**: o código M deles usa o conector correto internamente, e
o parâmetro com `/ingestion` é tratado dentro da consulta. Publicar um relatório do toolkit e agendar a
atualização funciona normalmente.

O cuidado vale para **relatórios que você construir do zero**. Nesse caso, use sempre:

```
AzureStorage.DataLake("https://<conta>.dfs.core.windows.net")
```

e navegue até o container dentro da consulta, em vez de colar a URL com o caminho completo. É a diferença entre um
relatório que atualiza sozinho e um que só funciona no Desktop.

#### Licenciamento: quem consegue ver

| Cenário | O que é preciso |
|---|---|
| Você mesmo, no Desktop | Nada, é gratuito |
| Você publica e só você vê | Licença **Pro** |
| Você compartilha com o time | **Pro para cada pessoa** que visualiza |
| Workspace em capacidade **F64 ou maior** | Quem visualiza pode ter licença **gratuita** |
| Trial do Fabric (60 dias) | Capacidade equivalente a F64, dispensa Pro no período |

O trial do Fabric resolve dois problemas de uma vez: dispensa a Pro dos visualizadores e habilita o nível 1 com
Eventhouse. Para ativar: `app.fabric.microsoft.com` > ícone de conta > **Start trial**.

#### Resumo: os três modos de consumir pelo Power BI

| Modo | Atualiza sozinho? | Quem acessa | Quando usar |
|---|---|---|---|
| **`.pbix` no Desktop** | Não, só no botão Refresh | Só você, na sua máquina | Análise pessoal, desenvolvimento |
| **Publicado no Service** | **Sim**, no horário agendado | Quem você compartilhar | Uso recorrente, time, gestão |
| **Real-Time Dashboard (nível 1)** | **Sim**, consulta ao vivo | Quem tiver acesso ao workspace | Quando já estiver no Fabric |

### Passo 8. Valide

No banco `Hub`:

```kusto
IngestionHealth()
// esperado: uma linha por nuvem (Azure, AWS, OCI) com Status = OK e DaysBehind <= 2

CostsMulticloud()
| summarize Efetivo = sum(EffectiveCost), Faturado = sum(BilledCost) by Provider, ChargeMonth
| order by ChargeMonth desc
// compare o mês fechado com a fatura de cada nuvem (Faturado, sem impostos)

RecommendationsAll()
| summarize Recomendacoes = count(), EconomiaMensal = sum(MonthlySavings) by Provider
```

Primeira carga demora: Azure até 1 hora após o deploy (exports + ingestão); AWS depende da primeira entrega do Data Export
(até 24 horas após criá-lo); OCI roda na hora agendada (06:30 UTC) ou quando você executa a Function manualmente
(Function App > Functions > `oci_focus_ingest` > Code + Test > Test/Run).

---

### Onde ver os exports no portal (armadilha comum)

Em **Cost Management > Exports**, o que aparece depende do **seletor de escopo** no topo da página. Os exports do hub são criados
no escopo que você listou em `ScopesToMonitor`, normalmente **a assinatura**. Se o seletor estiver em *Root management group* ou em
outro management group, a tela mostra **No exports to display** mesmo com tudo funcionando.

Clique em **Change scope** e selecione a assinatura monitorada. Pelo PowerShell, a lista independe do seletor:

```powershell
Get-FinOpsCostExport -Scope "/subscriptions/<id da assinatura>" |
    Select-Object Name, Dataset, DatasetVersion, ScheduleFrequency
```

### Atividades que falham e não são problema

Na pipeline `config_ConfigureExports` do hub, a atividade **`Save Scopes`** aparece como *Failed* mesmo quando tudo dá certo.
Ela é a primeira tentativa de ler os escopos em um formato, e o fluxo segue por `Save Scopes as Array`, que é o caminho normal.
O sinal que vale é o **status da pipeline** no topo: se estiver *Succeeded*, está tudo certo. Essa atividade pertence ao template
oficial do FinOps hub, não a este kit.

---

## 9. Deploy pelo portal (sem scripts)

Todo o processo pela interface está no documento **Guia passo a passo pelo portal FinOps Multicloud.docx** (7 partes) e,
resumido, em `docs/anexos/instalacao-portal-multicloud.md`. Os JSON da pasta `adf/` são colados no editor de código do Data Factory Studio
(botão com o símbolo de chaves) para criar datasets e pipelines sem digitar propriedade por propriedade.
