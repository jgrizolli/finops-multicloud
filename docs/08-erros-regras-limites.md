# Erros comuns, regras de ouro da ingestão e limites conhecidos

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [13. Erros comuns e como resolver](#13-erros-comuns-e-como-resolver)
* [14. Regras de ouro da ingestão (documentação oficial do hub)](#14-regras-de-ouro-da-ingestão-documentação-oficial-do-hub)
* [15. Limites conhecidos](#15-limites-conhecidos)

---

## 13. Erros comuns e como resolver

| Mensagem ou sintoma | Causa | Solução |
|---|---|---|
| `Cannot find Bicep. Please add Bicep to your PATH or visit https://aka.ms/bicep-install` (erro dentro de `Deploy-FinOpsHub.ps1`, linha `throw $_.Exception.Message`) | O Bicep CLI não está no PATH. `az bicep install` não basta (instala em `~/.azure/bin`, fora do PATH) | Instale o Bicep (Windows: `winget install -e --id Microsoft.Bicep`; macOS: `brew install bicep`), **reabra o PowerShell** e rode o script de novo. Ou apenas rode de novo a versão atual do script, que adiciona a cópia da Azure CLI ao PATH da sessão sozinha |
| `O modulo FinOpsToolkit x.y e antigo` | Versão do módulo anterior à 12.0 | `Update-Module FinOpsToolkit -Force` e reabra o PowerShell |
| `Key based authentication is not permitted on this storage account` / `KeyBasedAuthenticationNotPermitted` / `DeploymentScriptOperationFailed` (na etapa 2, dentro do Deploy-FinOpsHub) | Política da assinatura desligou o acesso por chave nas storage accounts do hub; os deployment scripts do template precisam dele | Adicione `"ResourceGroupTags": { "SecurityControl": "Ignore" }` ao `parameters.json` (ou `-ResourceGroupTags @{ SecurityControl = 'Ignore' }`) e rode o script de novo. Ele aplica a tag no resource group, reabilita a chave nas storage accounts já criadas e repete o deploy. Em tenants de clientes, alternativa: isenção da política para o resource group |
| `DeploymentScriptACIProvisioningTimeout` | Falha transitória ao criar o container do deployment script, ou a mesma política acima | Rode de novo; se persistir, aplique a tag `SecurityControl = Ignore` como na linha anterior |
| `Falha ao compilar multicloud-extension.bicep` | Erro de sintaxe ou Bicep muito antigo | Leia a linha e coluna indicadas; atualize o Bicep (`winget upgrade Microsoft.Bicep` ou `az bicep upgrade`) |
| `Cannot find path '.\\oci-finops-reader.pem'` na etapa 4 | `SkipOci` está `false` mas o `.pem` do exemplo não existe | Se a OCI ainda não estiver pronta, use `"SkipOci": true` (e `"SkipAws": true` para a AWS); acrescente depois com `-SkipHub` |
| `The subscription '00000000-0000-0000-0000-000000000000' could not be found` ou `SubscriptionId ... ainda e o valor de exemplo` | O arquivo de parâmetros ainda tem o ID de exemplo (normalmente porque o `parameters.example.json` foi editado e depois substituído por uma atualização do kit) | Copie o exemplo para `parameters.json`, preencha com o ID real (`Get-AzSubscription`) e rode com `-ParametersFile .\parameters.json` |
| `does not have access to subscription ID` | Logado em outro tenant ou conta sem acesso | `Connect-AzAccount -Tenant <tenant-id>` com a conta certa, depois `Get-AzSubscription` para confirmar |
| `No exports to display` em Cost Management > Exports | O seletor de escopo está em um management group, e os exports foram criados na assinatura | **Change scope** e selecionar a assinatura monitorada, ou listar com `Get-FinOpsCostExport -Scope /subscriptions/<id>` |
| Atividade `Save Scopes` como *Failed*, mas a pipeline *Succeeded* | Comportamento normal do template oficial: primeira tentativa de leitura dos escopos, com fallback em `Save Scopes as Array` | Nenhuma ação. Vale o status da pipeline, não o da atividade |
| `RBACAccessDenied` (401) na atividade `... focus export` | Identidade do Data Factory sem **Cost Management Contributor** na assinatura (o papel *Cost Management Reader* não serve) | Rode o instalador de novo com `-SkipHub`: a etapa 3 concede o papel. Ou conceda à mão conforme a [seção 4.2](02-instalacao-do-hub.md#42-permissões-quem-precisa-de-quê-e-por-quê) |
| `... 'Microsoft.Authorization/roleAssignments/write' action on specified storage account` | Identidade do Data Factory sem **User Access Administrator** na storage do hub | Idem acima: o instalador concede na etapa 3 |
| `Informe -SubscriptionId e -ResourceGroup` | Faltou parâmetro ou o `parameters.json` não foi lido | Confira o caminho do arquivo e os nomes das chaves |
| `Modo Fabric exige -FabricQueryUri` | `Mode` = Fabric sem o URI | Faça o Passo 3 e copie o Query URI |
| `Nao encontrei a storage account ou o Data Factory do hub` | `HubName` diferente do usado no deploy do hub | Use o mesmo `HubName` (os recursos se chamam `<hub>store...` e `<hub>-engine-...`) |
| `AWS habilitada: informe -AwsBucketName ...` | Parâmetros da AWS incompletos | Preencha bucket, conta pagadora, access key e secret, ou use `-SkipAws` |
| Deploy-FinOpsHub falha com `Authorization failed` | Falta Role Based Access Control Administrator | Peça o papel no resource group ou use um Owner |
| Etapa 5 avisa que não gravou `config/multicloud/manifest.json` | Sem Storage Blob Data Contributor no storage | Peça o papel ou envie o arquivo `adf/manifest.json` pelo Storage browser |
| Exports do Azure não aparecem | Identidade do Data Factory sem papel no escopo | Enterprise Reader (EA) ou Cost Management Contributor (assinatura) para a identidade impressa na etapa 2 |
| `RBACAccessDenied` (401) na pipeline `config_ConfigureExports`, atividade `... focuscost export` | A identidade do Data Factory não tem **Cost Management Contributor** na assinatura. Atenção: **Cost Management Reader não serve**, ele lê mas não cria exports | `New-AzRoleAssignment -ObjectId <id-da-identidade> -RoleDefinitionName 'Cost Management Contributor' -Scope /subscriptions/<sub-id>` e aguarde de 5 a 30 minutos |
| `The user does not have authorization to perform 'Microsoft.Authorization/roleAssignments/write' action on specified storage account` | Ao criar um export gerenciado, o Cost Management atribui um papel a si mesmo na storage de destino, e quem chama a API precisa poder gravar role assignments nessa storage | `New-AzRoleAssignment -ObjectId <id-da-identidade> -RoleDefinitionName 'User Access Administrator' -Scope <resource id da storage do hub>`. O script já tenta conceder isso na etapa 3 |
| `mc_aws_IngestFocus` termina sem copiar nada | Ainda não há arquivos no S3 para o mês | Aguarde a primeira entrega do Data Export (até 24 h) e confira o caminho `focus/finops-focus-1-0/data/BILLING_PERIOD=yyyy-MM/` |
| Linked service `mc_AwsS3` com erro de autenticação | Access key inválida ou Data Factory sem Key Vault Secrets User | Recrie o access key e confira o RBAC do Key Vault |
| Function OCI com 401 ou 404 | Policy `endorse` ausente, fingerprint ou região errados | Revise `oci/README-oci.md` e as App settings |
| Pasta com parquet e nada no Eventhouse | `manifest.json` ausente ou com zero bytes | O manifest deve conter pelo menos `{}` |
| `BadRequest_NoRecordsOrWrongFormat` no Data Explorer | Shard parquet vazio | Sem perda de dados; o hub tenta três vezes |
| Rate optimization vazio para AWS e OCI | Esperado: price sheet e reservas são exports só do Azure | Use `RecommendationsAll()` |
| No Power BI: `We were unable to connect because this credential type isn't supported for this resource`, com uma URL do **github.com** ou do **ccmstorageprod.blob.core.windows.net** no alto da caixa | Essas duas fontes são arquivos públicos do toolkit e não aceitam login. Foi escolhido *Organizational account* | Escolha **Anonymous** e Connect. Só a URL `.dfs.core.windows.net`, o Eventhouse e o Resource Graph usam *Organizational account*. Ver "Credenciais: cada fonte pede um tipo diferente" no Passo 7 |
| No Power BI: `Access to the resource is forbidden` ou 403 na URL `.dfs.core.windows.net` | A sua conta não tem **Storage Blob Data Reader** na storage do hub. Ser Owner **não basta**, papéis de plano de dados não são herdados | `New-AzRoleAssignment -ObjectId (Get-AzADUser -SignedIn).Id -RoleDefinitionName 'Storage Blob Data Reader' -Scope <resource id da storage do hub>`. Alternativa sem RBAC: gerar um SAS token (Read + List, Container + Object) e colar em Transform data > Data Source settings > Edit permissions > Shared access signature |
| No Power BI storage report: `3 queries are blocked by the following error: Costs. The column 'SkuMeterName' of the table wasn't found` | Os exports estão em **FOCUS 1.2-preview** (padrão dos managed exports do hub) e os relatórios storage leem **FOCUS 1.0**. No modo Storage não há conversão de esquema. `x_SkuMeterName` virou `SkuMeter` no FOCUS 1.2 | Rode `deploy/Repair-FocusVersion.ps1 -SubscriptionId <sub> -ResourceGroup <rg>`. Ele desliga os managed exports, apaga os exports 1.2-preview, limpa `ingestion/Costs` e recria tudo em `1.0r2` com backfill. Depois reabra o `.pbit` original |
| No Power BI: **todas** as páginas em branco e uma tarja `There are pending changes in your queries that haven't been applied` no alto | O Power Query foi fechado pelo X ou por `Close` em vez de `Close & Apply`. O modelo nunca carregou | Clique em **Apply changes** na tarja e aguarde. Depois **Refresh now** nas outras duas tarjas, se ainda existirem. Sempre saia do Power Query por **Close & Apply** |
| No Power BI: relatório abre vazio, sem erro | Ainda não há mês fechado, ou o *Number of Months* corta o período disponível | *Number of Months* conta **meses fechados**. Se só existir o mês corrente (recém-implantado, backfill ainda rodando), **deixe o parâmetro vazio**, que carrega tudo o que houver no storage. Para trazer o histórico: `Invoke-AzDataFactoryV2Pipeline -ResourceGroupName <rg> -DataFactoryName <adf-do-hub> -PipelineName config_RunBackfillJob` |
| Reduzi `ingestion.months` e o parquet antigo continua no storage | Comportamento atual do toolkit: `ingestion.months` controla até onde o backfill vai, mas **não apaga blob**. A limpeza automática ainda não foi implementada | Crie a regra de ciclo de vida: `./Set-FinOpsRetention.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -IngestionMonths <n> -ApplyStorageLifecycle`. Ver [seção 6.5](03-operacao-do-hub.md#65-apagar-de-verdade-regra-de-ciclo-de-vida) |
| Mudei `raw.days` no `settings.json` e nada aconteceu | `raw.days` é aplicado como policy nas tabelas do Data Explorer **durante o deploy**. Não é lido em tempo de execução | Reimplante o hub com o valor novo, ou altere a policy da tabela direto no Data Explorer |
| `RateOptimization` abre sem nenhuma recomendação | Falta o export **ReservationRecommendations**, que só pode ser criado em escopo de **billing account (EA)** ou **billing profile (MCA)**. Em escopo de assinatura ele não existe | Rode o instalador com `-ScopesToMonitor '/providers/Microsoft.Billing/billingAccounts/<id>'`. Ver a seção "Habilitando os relatórios que faltam" |
| `WorkloadOptimization` ou `PolicyAndGovernance` com as páginas de inventário vazias | Esses relatórios consultam o **Azure Resource Graph**, não o storage. A conta que abre precisa de **Reader** nas assinaturas | Conceda Reader e atualize. As páginas de custo continuam funcionando mesmo sem o Resource Graph |
| No Power BI: página `Purchases`, `Prices`, `Inventory` ou `Regions` em branco, mas `Summary` com dados | Comportamento esperado. `Purchases` exige reservas, savings plans ou marketplace; `Prices` exige o export de price sheet; `Inventory` e `Regions` dependem do Azure Resource Graph | Nenhuma ação. Valide o relatório pelas páginas `DQ`, `Summary`, `Services` e `Resource groups` |
| No Power BI storage report: `DataSource.Error` ou tabela vazia mesmo com parquet no storage | Foi usado o endpoint **blob** (`.blob.core.windows.net`) em vez do **DFS** | Troque o parâmetro para a URL terminada em `.dfs.core.windows.net`. Os storage reports só funcionam com o endpoint DFS |

---

## 14. Regras de ouro da ingestão (documentação oficial do hub)

1. Parquet, menor que 2 GB por arquivo, um mês por pasta: `ingestion/Costs/yyyy/mm/{escopo}`.
2. Nome `{ingestionId}__{arquivo}.parquet`; todos os arquivos de uma carga com o mesmo `ingestionId`.
3. Cada carga substitui a pasta inteira (apagar os parquet antigos antes de gravar).
4. `manifest.json` por último, com conteúdo (pelo menos `{}`); arquivo vazio é ignorado.
5. Nunca gravar no container `msexports` (exclusivo do Cost Management).

---

## 15. Limites conhecidos

* Dados não-Azure são previstos no design do hub, mas a documentação diz que não foram testados explicitamente na release atual: valide a primeira carga contra a fatura.
* Price sheet, reservation details, recommendations e transactions são exports do Cost Management: o Rate optimization nativo é só Azure. AWS e OCI usam Cost Optimization Hub e Cloud Advisor via `RecommendationsAll()`.
* Versões FOCUS aceitas pelo hub: 1.0, 1.0r2 e 1.2-preview. AWS: usar a tabela FOCUS 1.0. OCI: 1.0 com nomes de 1.0-preview (o hub converte).
* O export de recomendações da AWS não suporta overwrite; a pipeline copia apenas o que chegou nas últimas 26 horas.

Autor: Wanderlei Grizolli Junior. Licença: MIT (mesma do FinOps toolkit).
