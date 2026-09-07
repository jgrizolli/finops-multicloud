# Instalacao automatizada (PowerShell + Bicep)

> **Anexo da fase de projeto.** Este documento foi escrito no desenho inicial da solução (HLD) e é mantido como referência. O guia atualizado e validado em campo está nos demais arquivos de `docs/` (índice no [README](../../README.md)). Onde houver divergência, vale o guia.


## Por que PowerShell + Bicep (e Python so onde e inevitavel)
* **PowerShell**: o toolkit oficial e distribuido como modulo `FinOpsToolkit` (Deploy-FinOpsHub, New-FinOpsCostExport,
  Start-FinOpsCostExport). Reaproveitar o modulo garante que o hub seja instalado e atualizado do jeito suportado.
* **Bicep**: tudo que e infraestrutura (Key Vault, objetos do Data Factory, Function App, RBAC) fica declarativo,
  idempotente e revisavel em pull request. Rodar de novo nao duplica nada.
* **Python**: apenas o conector OCI, porque a Oracle nao entrega parquet nem permite copia direta pelo Data Factory
  a partir do bucket dela; o codigo tem 200 linhas e usa o SDK oficial da Oracle.

## Pre-requisitos na maquina de quem instala
* PowerShell 7+, `Install-Module Az`, `Install-Module FinOpsToolkit`
* Azure CLI (`az`), usada para publicar o codigo da Function
* **Bicep CLI no PATH** (`bicep --version` deve responder). Windows: `winget install -e --id Microsoft.Bicep`; macOS: `brew install bicep`;
  Linux: binario de github.com/Azure/bicep/releases em `/usr/local/bin`. Atencao: `az bicep install` sozinho NAO coloca o Bicep no PATH e o
  `Deploy-FinOpsHub` falha com `Cannot find Bicep. Please add Bicep to your PATH`. O script tenta resolver sozinho (usa a copia da Azure CLI
  ou baixa o executavel para `~/.bicep`), mas instalar antes e reabrir o terminal e o caminho mais previsivel.
* Permissoes: Contributor + Role Based Access Control Administrator no resource group; Enterprise Reader ou
  Cost Management Contributor nos escopos; Storage Blob Data Contributor no storage do hub (para gravar o manifest modelo)
* Fabric (nivel 1): Eventhouse criado e scripts `finops-hub-fabric-setup-*.kql` executados (fase A2 do guia do portal)

## Assinaturas com politica de shared key (ex.: internas da Microsoft)
O template oficial do hub usa deployment scripts que montam um file share por chave de storage. Politicas que desligam a chave
(SFI, "Storage accounts should prevent shared key access") fazem o deploy falhar com `KeyBasedAuthenticationNotPermitted`.
Solucao dos mantenedores (issues #1816 e #2241 do toolkit): tag `SecurityControl = Ignore` no resource group antes do deploy.
Neste kit: `"ResourceGroupTags": { "SecurityControl": "Ignore" }` no parameters.json. O script aplica a tag, reabilita a chave
nas storage accounts de uma tentativa anterior e repete o deploy.

## Passo a passo
1. Copie `deploy/parameters.example.json` para `deploy/parameters.json` e preencha. Nao versione o arquivo com segredos.
2. Execute:
   ```powershell
   cd deploy
   ./Deploy-FinOpsMulticloud.ps1 -ParametersFile ./parameters.json
   ```
3. Leia o resumo final (etapa 7). Ele lista os comandos `.add database ... admins` do Fabric e os checks de AWS/OCI.
4. Rode `kql/01-multicloud-functions.kql` no banco Hub e importe o dashboard (`dashboards/`).

## O que cada etapa do script faz
| Etapa | Acao | Por que |
|---|---|---|
| 1 | Instala/importa modulos, valida a versao do FinOpsToolkit (>= 12), garante o Bicep CLI no PATH, login, cria o resource group | Ambiente previsivel; o erro mais comum (Bicep fora do PATH) e tratado aqui |
| 2 | `Deploy-FinOpsHub` com `-FabricQueryUri` (Fabric), `-DataExplorerName` (ADX) ou nenhum (storage) e `-EnableManagedExports -ScopesToMonitor` | Motor oficial; a mesma linha atualiza o hub quando sai release nova |
| 3 | Managed exports (padrao) ou `New-FinOpsCostExport` por escopo com `-Backfill` (contas MCA ou sem permissao de RBAC) | Sem export nao ha dado; o backfill traz o historico |
| 4 | Compila `multicloud-extension.bicep` para JSON (`bicep build`) e implanta: Key Vault + segredos, pipelines `mc_aws_*`, Function App OCI, RBAC | Conectores AWS/OCI sem tocar no template do hub; erros de sintaxe aparecem com linha e coluna |
| 5 | Grava `config/multicloud/manifest.json` (`{}`), inicia os triggers e dispara a primeira carga da AWS | O hub so ingere quando ve um manifest.json com conteudo |
| 6 | Zip deploy da Function (`az functionapp deployment source config-zip --build-remote true`) | Publica o conector OCI |
| 7 | Resumo | Passos que so existem na interface (Fabric, AWS, OCI) |

## Exemplos
```powershell
# Nivel 0: custo minimo, so Azure, so storage (Power BI storage reports)
./Deploy-FinOpsMulticloud.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Location brazilsouth `
  -Mode Storage -ScopesToMonitor '/subscriptions/<sub>' -SkipAws -SkipOci

# Nivel 1: Fabric F2 + AWS (sem OCI ainda)
./Deploy-FinOpsMulticloud.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Location brazilsouth `
  -Mode Fabric -FabricQueryUri https://xxxx.kusto.fabric.microsoft.com `
  -ScopesToMonitor '/providers/Microsoft.Billing/billingAccounts/1234567' `
  -AwsBucketName finops-focus-exports-123456789012 -AwsPayerAccountId 123456789012 `
  -AwsAccessKeyId AKIA... -AwsSecretAccessKey (Read-Host -AsSecureString 'AWS secret') -SkipOci

# Somente atualizar a extensao (hub ja existe)
./Deploy-FinOpsMulticloud.ps1 -ParametersFile ./parameters.json -SkipHub
```

## Atualizacoes
* **Hub**: repita a etapa 2 (ou `Deploy-FinOpsHub` direto). O toolkit publica release mensal; leia o changelog antes.
* **Extensao**: `-SkipHub` reaplica o Bicep. Objetos `mc_*` sao substituidos, nunca duplicados.
* **Function**: `-SkipHub` ou `func azure functionapp publish`.
* **Rotacao de segredos**: atualize o segredo no Key Vault (aws-secret-access-key, oci-private-key-pem); Data Factory e Function
  leem na proxima execucao (a Function pode exigir restart para renovar a Key Vault reference).
