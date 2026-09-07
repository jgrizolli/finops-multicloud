# Desligar, apagar e reinstalar: o ciclo de vida do ambiente

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md).

Este ambiente foi montado para **estudo, demonstração e evolução**, não para ficar ligado 24 horas. Existem
**três ações diferentes**, e confundi-las custa dinheiro ou tempo:

| Ação | O que acontece | Quanto paga depois | Quanto demora para voltar | Script |
|---|---|---|---|---|
| **Desligar** | A interface para de rodar; nada é apagado; o hub continua coletando | ~US$ 8/mês (registry + hub) ou ~US$ 3 com `-Level Deep` | Segundos (`Start`) ou 10 a 15 min (Deep, reinstala a interface) | `webapp/Set-FinOpsPower.ps1` |
| **Apagar** | Os recursos são removidos; exports, Key Vault em soft delete e demais restos são limpos para a reinstalação não falhar | US$ 0 (ou só o storage do hub, se você mantiver o histórico) | 25 a 40 min (hub + interface) + até 24 h para o dado voltar | `deploy/Remove-FinOpsEnvironment.ps1` |
| **Reinstalar** | Os mesmos instaladores de sempre, na mesma ordem | | | `deploy/Deploy-FinOpsMulticloud.ps1` e `webapp/Deploy-FinOpsWebApp.ps1` |

Regra prática: **vai voltar em dias, desligue; vai voltar em semanas ou quer testar a instalação do zero, apague.**

**Nesta página**

* [O que custa dinheiro, e o que custa parado](#o-que-custa-dinheiro-e-o-que-custa-parado)
* [Desligar: `Set-FinOpsPower.ps1 -Action Stop`](#desligar-set-finopspowerps1--action-stop)
* [Ligar: `Set-FinOpsPower.ps1 -Action Start`](#ligar-set-finopspowerps1--action-start)
* [Apagar: `Remove-FinOpsEnvironment.ps1`](#apagar-remove-finopsenvironmentps1)
* [Reinstalar do zero: o ciclo completo de teste](#reinstalar-do-zero-o-ciclo-completo-de-teste)
* [Pausar o hub também (opcional, e por que em geral não vale)](#pausar-o-hub-também-opcional-e-por-que-em-geral-não-vale)
* [Login com Entra ID: `Set-FinOpsWebAuth.ps1`](#login-com-entra-id-set-finopswebauthps1)
* [Rotina sugerida para estudo](#rotina-sugerida-para-estudo)
* [Como saber quanto está custando de verdade](#como-saber-quanto-está-custando-de-verdade)

---

## O que custa dinheiro, e o que custa parado

Valores aproximados de lista, em dólar, por mês, para 1 instância. Servem para decidir, não para fechar orçamento.

| Componente | Ligado | Parado (Light) | Parado (Deep) | Observação |
|---|---|---|---|---|
| **Container App** da interface (0,5 vCPU, 1 GiB, 1 réplica sempre ativa) | 15 a 20 | **0** | **0** (apagado) | `az containerapp stop` zera a computação; o ambiente Consumption não cobra ocioso |
| **Container Registry** Basic (guarda a imagem) | 5 | 5 | **0** (apagado) | Custo fixo enquanto existir. A imagem é reconstruída pelo instalador em 3 a 6 minutos |
| **App Service B1** (se você usou esse modelo) | 13 | **13** | **0** (plano apagado) | O plano cobra mesmo com o site parado. Para zerar sem apagar: `Set-AzAppServicePlan -Tier Free` |
| Storage de **estado** (Table: centros de custo, regras, alertas) | centavos | centavos | centavos | Mantido sempre: são os seus cadastros |
| Log Analytics + Application Insights | 0 a 2 | 0 | 0 | Primeiros 5 GB por mês gratuitos |
| Communication Services (e-mail de alerta) | 0 + US$ 0,25 por mil e-mails | 0 | 0 | Só cobra por e-mail enviado |
| **FinOps hub**: storage do dado + Data Factory + Key Vault | 2 a 4 | 2 a 4 | 2 a 4 | Os exports do Cost Management são gratuitos; o Data Factory cobra por execução de pipeline (poucos centavos por dia) |
| Fabric (só nível 1) | capacidade F2 a partir de ~260 | pausar a capacidade zera | idem | Fora do escopo deste ambiente (nível 0) |

Leitura rápida: **ligado, o ambiente todo fica em torno de US$ 25 a 30 por mês**. Parado no modo Light, cerca de
**US$ 8** (registry + hub). Parado no modo Deep, cerca de **US$ 3** (só o hub, que continua coletando o histórico).

## Desligar: `Set-FinOpsPower.ps1 -Action Stop`

```powershell
cd .\finops-multicloud-kit\webapp

# ver o estado e a estimativa de custo antes de mexer
.\Set-FinOpsPower.ps1 -Action Status -ResourceGroup rg-finops-hub

# Light (padrao): para a interface. Volta em segundos. Sobra o registry (~US$ 5/mes) e o hub.
.\Set-FinOpsPower.ps1 -Action Stop -ResourceGroup rg-finops-hub

# Deep: apaga Container App, ambiente e registry. Volta com o instalador (10 a 15 min). Sobra so o hub.
.\Set-FinOpsPower.ps1 -Action Stop -ResourceGroup rg-finops-hub -Level Deep
```

O que cada nível preserva:

| | Light | Deep |
|---|---|---|
| Seus cadastros (centros de custo, orçamentos, regras, alertas) | Sim | Sim (ficam na storage de estado) |
| Imagem construída | Sim | Não (reconstruída no próximo deploy) |
| App registration do login | Sim | Sim (reaproveitado) |
| URL | A mesma | **Muda** (o Container App novo recebe outro sufixo de ambiente); o script atualiza o redirect URI do login |
| Tempo para voltar | 20 a 60 segundos | 10 a 15 minutos |

Com `-WhatIf` o script mostra o que faria sem fazer nada.

## Ligar: `Set-FinOpsPower.ps1 -Action Start`

```powershell
# depois de um Stop Light
.\Set-FinOpsPower.ps1 -Action Start -ResourceGroup rg-finops-hub

# depois de um Stop Deep: e o instalador, com os mesmos parametros de sempre
.\Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -EnableAuth -EnableEmail -AlertEmailTo voce@empresa.com -Location eastus2 -HostingModel ContainerApps
```

A primeira resposta depois de ligar leva de 20 a 60 segundos: o container sobe e lê o dado do hub (a leitura fica em
cache por 30 minutos). Se a URL não abrir em dois minutos: `.\Diagnose-FinOpsWebApp.ps1 -ResourceGroup rg-finops-hub`.

## Apagar: `Remove-FinOpsEnvironment.ps1`

Apagar não é só deletar recursos. Quatro coisas ficam para trás e **fazem a reinstalação falhar** se não forem
tratadas, e o script trata as quatro:

| O que fica | Por que atrapalha | O que o script faz |
|---|---|---|
| **Exports do Cost Management** | Vivem na assinatura, não no resource group. Continuariam tentando gravar em um storage apagado, e o instalador tentaria criar outro com o mesmo nome | `Remove-FinOpsCostExport` para cada export que aponta para o storage do hub (antes de apagar o storage) |
| **Key Vault em soft delete** (90 dias) | Bloqueia a recriação com o mesmo nome, e os nomes do kit derivam do resource group: o próximo deploy usaria o mesmo | Purge (`Remove-AzKeyVault -InRemovedState`) |
| **Log Analytics em soft delete** (14 dias) | Na interface, é removido com `-ForceDelete`; no hub, o mesmo nome é recuperado automaticamente | Remove com força (interface) ou informa (hub) |
| **App registration do login** | Não atrapalha: o próximo deploy o reaproveita e atualiza o redirect URI | Mantém; `-RemoveAppRegistration` apaga |

```powershell
cd .inops-multicloud-kit\deploy

# ver o que seria apagado, sem apagar
.\Remove-FinOpsEnvironment.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Scope All -WhatIf

# apagar TUDO (hub + interface + exports + restos). Pede para digitar o nome do resource group.
.\Remove-FinOpsEnvironment.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Scope All

# apagar tudo, mas GUARDAR o historico de custo (o storage do hub fica; a reinstalacao reaproveita)
.\Remove-FinOpsEnvironment.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Scope All -KeepHubStorage

# so a interface web (o hub e o dado ficam)
.\Remove-FinOpsEnvironment.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Scope Web

# so o hub (a interface fica, mas sem dado ate o hub voltar)
.\Remove-FinOpsEnvironment.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Scope Hub
```

O script imprime o inventário do que vai apagar, pede a confirmação digitada (o nome do resource group; `-Force`
pula), e no fim imprime a ordem de reinstalação. Ele não mexe em atribuições de papel órfãs no escopo da assinatura
(podem ser de outros sistemas): lista e deixa a decisão com você.

## Reinstalar do zero: o ciclo completo de teste

É o roteiro para provar que o kit é replicável: apagar tudo e subir de novo só com os scripts. Tempo total de
trabalho: cerca de 45 minutos; o dado do Azure aparece entre 30 minutos e 24 horas depois (o Cost Management gera
o export, o hub ingere).

```powershell
# 0. (opcional) os cadastros da interface (centros de custo, orcamentos, regras) ficam na storage de estado, que
#    -Scope All apaga. Se quiser guardar, exporte os centros pela interface (Chargeback > exportar CSV) antes. Veja a nota no fim.

# 1. APAGAR
cd .inops-multicloud-kit\deploy
.\Remove-FinOpsEnvironment.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -Scope All

# 2. HUB (15 a 25 min). O parameters.json e a SUA copia do parameters.example.json (nunca edite o exemplo).
.\Deploy-FinOpsMulticloud.ps1 -ParametersFile .\parameters.json
#    Ao final: exports criados em FOCUS 1.0r2, backfill disparado, settings.json com a retencao. Confira:
#    Get-AzStorageBlob -Container ingestion -Context $ctx | Where-Object Name -like '*.parquet'   (pode levar ate 1 h para o primeiro)

# 3. INTERFACE WEB (10 a 15 min). Container Apps se a assinatura nao tiver cota de App Service (a sua nao tem).
cd ..\webapp
.\Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -EnableAuth -EnableEmail -AlertEmailTo voce@empresa.com -Location eastus2 -HostingModel ContainerApps

# 4. LOGIN (so se a etapa 6 do instalador avisar que nao ficou ativo)
.\Set-FinOpsWebAuth.ps1 -ResourceGroup rg-finops-hub -HostingModel ContainerApps

# 5. CONFERIR
.\Diagnose-FinOpsWebApp.ps1 -ResourceGroup rg-finops-hub -HostingModel ContainerApps     # revisao pronta, /api/health 200, / redireciona para o login
#    abra a URL, entre com a conta do tenant, veja "linhas" no indicador do cabecalho (verde = dado carregado)

# 6. POWER BI (opcional): abra os .pbit com a URL do storage + /ingestion, 6 meses (docs/02-instalacao-do-hub.md, Passo 7)

# 7. FIM DO DIA
.\Set-FinOpsPower.ps1 -Action Stop -ResourceGroup rg-finops-hub
```

O que esperar em cada ponto: depois do passo 2, a interface (passo 3) pode abrir **sem dado** por até algumas horas;
o indicador do cabeçalho fica cinza e `/api/status` mostra `linhas: 0` com a mensagem "Nenhum arquivo parquet
encontrado". É normal: o hub ainda está esperando o primeiro export. Quando o parquet chegar, a interface lê sozinha
(cache de 30 minutos) ou pelo botão de recarregar.

**Sobre os cadastros** (centros de custo, orçamentos, regras de alerta): ficam na storage de estado da interface,
que `-Scope All` e `-Scope Web` apagam. Duas saídas: exportar os centros pela interface antes (CSV) e importar depois
(`POST /api/centros-custo/importar`), ou apagar só o que precisa (por exemplo, `-Scope Hub` mantém a interface e os
cadastros). As regras padrão de alerta são semeadas de novo automaticamente.

## Pausar o hub também (opcional, e por que em geral não vale)

O hub custa de US$ 2 a 4 por mês e é ele que **coleta o histórico todos os dias**. Pausar economiza pouco e cria
um buraco no dado:

* Os exports do Cost Management continuam (são gratuitos) e gravam em `msexports`, mas nada é convertido para
  `ingestion` enquanto os gatilhos do Data Factory estão pausados.
* Ao religar, o **mês corrente se recompõe sozinho** no próximo export diário (o export do dia traz o mês inteiro
  até a data). **Meses que passaram inteiros pausados não voltam sozinhos**: é preciso o backfill
  (`Start-FinOpsCostExport -Name <export> -Backfill <meses>`, ver [retenção e histórico](03-operacao-do-hub.md#68-trazendo-o-histórico-que-ainda-não-chegou)).

Se mesmo assim quiser pausar (por exemplo, uma ausência de meses):

```powershell
.\Set-FinOpsPower.ps1 -Action Stop  -ResourceGroup rg-finops-hub -PauseHub    # para a interface E pausa os gatilhos do hub
.\Set-FinOpsPower.ps1 -Action Start -ResourceGroup rg-finops-hub -PauseHub    # liga a interface E retoma os gatilhos
```

## Login com Entra ID: `Set-FinOpsWebAuth.ps1`

A URL da interface nasce **pública** se o login não for habilitado. O instalador faz isso com `-EnableAuth`, mas se a
etapa 6 falhar (foi o que aconteceu na primeira implantação real: a CLI recusou a combinação de parâmetros e a
autenticação ficou desligada, com aviso), o script dedicado resolve sem repetir o deploy:

```powershell
# ligar (ou corrigir) o login. Idempotente.
.\Set-FinOpsWebAuth.ps1 -ResourceGroup rg-finops-hub -HostingModel ContainerApps

# desligar o login (URL publica de novo)
.\Set-FinOpsWebAuth.ps1 -ResourceGroup rg-finops-hub -HostingModel ContainerApps -Disable
```

O que ele faz, e por que é confiável:

1. Cria ou reutiliza o app registration `<app>-auth` no Entra ID, com o redirect URI do Easy Auth
   (`https://<url>/.auth/login/aad/callback`) e emissão de **ID token** (necessária porque não usamos client secret;
   nenhum segredo em lugar nenhum).
2. Garante o service principal no tenant (sem ele o login falha com "Application ... was not found in the directory").
3. Grava a configuração **inteira** de uma vez, direto na API do Azure (`az rest` em `authConfigs/current`, ou
   `authsettingsV2` no App Service): plataforma ligada, redirecionar para o login, provedor Entra ID com `clientId`
   e `issuer`, `/api/health` fora do login. Não depende das combinações de parâmetros do `az ... auth update`, que
   mudam entre versões da CLI e foram a causa da falha.
4. **Lê de volta** e confere. Se não bater, **desliga** a autenticação em vez de deixar a URL bloqueada para todo mundo.
5. Testa: `/api/health` deve responder 200 sem login; `/` deve redirecionar para `login.microsoftonline.com`.

Por padrão, **qualquer conta do tenant** entra. Para restringir a um grupo: Entra ID > Enterprise applications >
`<app>-auth` > Properties > **Assignment required = Yes**, e em Users and groups adicione quem pode. Quem não estiver
na lista recebe uma tela de "acesso negado" do próprio Entra ID.

`/api/health` fica fora do login de propósito: é o caminho que a plataforma usa para saber se a aplicação está viva e
que o instalador usa para validar. Ele não expõe dado (só `status`, `configurado` e `versao`).

## Rotina sugerida para estudo

| Momento | Comando |
|---|---|
| Vou estudar agora | `.\Set-FinOpsPower.ps1 -Action Start -ResourceGroup rg-finops-hub` e abra a URL |
| Mudei o código e quero ver publicado | `.\Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -HostingModel ContainerApps -CodeOnly` (3 a 6 min; roda `test_import.py` antes) |
| Terminei por hoje | `.\Set-FinOpsPower.ps1 -Action Stop -ResourceGroup rg-finops-hub` |
| Vou ficar semanas sem usar | `... -Action Stop -Level Deep` (sobra só o hub, ~US$ 3/mês, coletando histórico) |
| Quero testar a instalação do zero, ou não vou usar por meses | `deploy\Remove-FinOpsEnvironment.ps1 -Scope All` e o ciclo completo acima |
| Voltei depois de semanas | Instalador completo (Deep) ou `-Action Start` (Light); confira o dado com `<url>/api/status` |

## Como saber quanto está custando de verdade

A própria solução mostra: os recursos do resource group `rg-finops-hub` aparecem na interface web (filtre por
assinatura e por grupo de recursos) e nos relatórios Power BI, porque o hub coleta o custo da assinatura inteira,
inclusive o dele mesmo. No portal: Cost Management > Cost analysis > filtro Resource group = `rg-finops-hub`,
agrupado por serviço. É um bom exercício de FinOps: a ferramenta medindo a si mesma.
