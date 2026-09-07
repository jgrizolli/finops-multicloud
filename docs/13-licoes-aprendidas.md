# Lições aprendidas: o caderno para o próximo projeto

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md).

Este caderno reúne o que estes dias de implantação ensinaram, organizado por **tema** e não por ordem cronológica
(a cronologia está no [diário de bordo](09-diario-de-bordo.md)). Cada lição tem o mesmo formato: **o que aconteceu**,
**a causa**, **a regra que fica** e, quando cabe, **o trecho reutilizável**. No fim, um checklist para começar o
próximo projeto já com tudo isso aplicado.

Como usar: leia uma vez inteiro; depois, ao começar um projeto novo, vá direto ao checklist e às seções dos temas
envolvidos. Este arquivo também existe em Word na pasta `Copilot-Notebook/`, junto com os demais documentos, para servir de
fonte a um Copilot Notebook.

**Nesta página**

* [Tema 1. Método de trabalho](#tema-1-método-de-trabalho)
* [Tema 2. Azure: Bicep, ARM, cotas e providers](#tema-2-azure-bicep-arm-cotas-e-providers)
* [Tema 3. Azure CLI e PowerShell](#tema-3-azure-cli-e-powershell)
* [Tema 4. Container Apps, App Service e Easy Auth](#tema-4-container-apps-app-service-e-easy-auth)
* [Tema 5. FinOps hub, FOCUS e Power BI](#tema-5-finops-hub-focus-e-power-bi)
* [Tema 6. Python, dados e testes](#tema-6-python-dados-e-testes)
* [Tema 7. Documentação e replicabilidade](#tema-7-documentação-e-replicabilidade)
* [Checklist para o próximo projeto](#checklist-para-o-próximo-projeto)
* [Frases para lembrar](#frases-para-lembrar)

---

## Tema 1. Método de trabalho

### 1.1 Cada rodada avança um degrau; registre o degrau

**O que aconteceu.** A interface web precisou de sete execuções do instalador até abrir. Cada uma falhou em um ponto
diferente e **mais adiante** que a anterior: Bicep, cota, extensão da CLI, codificação do console, saída descartada,
importação do módulo, autenticação.

**A regra.** Uma sequência de falhas em pontos diferentes é progresso, não fracasso. Anote cada degrau (sintoma, causa,
correção) no momento em que acontece, porque em uma semana você não lembra a ordem nem o raciocínio. O
[diário de bordo](09-diario-de-bordo.md) nasceu assim e virou a parte mais valiosa do kit.

### 1.2 Teste o caminho que a produção usa

**O que aconteceu.** Sessenta testes de lógica passavam, a prévia funcionava, e o container morreu na inicialização com
um `NameError`. Nenhum teste fazia `import main` do jeito que o servidor faz.

**A regra.** Para cada forma como a produção executa o código (importar um módulo, iniciar um processo, receber uma
requisição), precisa existir um teste que faça exatamente aquilo. Testes de lógica não substituem um teste de
inicialização. Trecho reutilizável: `webapp/api/test_import.py` (importa o módulo com substitutos para bibliotecas
ausentes; falha só por erro no código).

### 1.3 Um teste de pré-publicação distingue "erro no código" de "falta biblioteca aqui"

**O que aconteceu.** O teste criado para proteger o deploy bloqueou o deploy, porque a máquina de quem instala não
tem as bibliotecas que só existem dentro do container.

**A regra.** Só erro no **código** bloqueia. Dependência ausente no ambiente local é aviso ou pulo (código de saída
próprio), nunca falha. E valide o teste em quatro cenários antes de entregar: ambiente completo, ambiente mínimo,
ambiente sem o essencial (deve pular), código com o bug conhecido reintroduzido (deve falhar).

### 1.4 Quando o teste não é confiável, elimine a condição em vez de testar

**O que aconteceu.** Uma extensão quebrada da Azure CLI derrubava comandos de forma intermitente. A sonda (`az
extension list`) passava e o erro voltava.

**A regra.** Diante de um defeito intermitente cuja detecção é incerta, remova a condição que o permite (pasta de
extensões isolada, sempre) em vez de tentar detectá-lo. Determinístico vence esperto.

### 1.5 Valide antes de criar, e mostre a causa real

**O que aconteceu.** O deploy falhava com "See inner errors for details" e nenhum detalhe. Três rodadas foram gastas
adivinhando.

**A regra.** Toda operação cara ou lenta ganha uma validação barata antes (`Test-AzResourceGroupDeployment`,
`bicep build`, `test_import.py`), e a mensagem de erro mostrada é a **mais interna** da árvore, com a ação sugerida.
Se dá para testar as alternativas automaticamente (SKUs, regiões, outro serviço), teste e imprima o comando pronto.

### 1.6 Quando a abstração falha, fale com a API

**O que aconteceu.** Os subcomandos `az ... auth` recusaram combinações de parâmetros que mudam entre versões. A
autenticação ficou meio configurada.

**A regra.** CLIs e SDKs são conveniência sobre uma API. Quando a conveniência quebra, monte o objeto inteiro e grave
direto na API (`az rest`), depois **leia de volta** e confira. A API tem um contrato; a CLI tem uma versão por mês.

### 1.7 Sincronização de arquivos não é atômica

**O que aconteceu.** O OneDrive sincronizou o Bicep novo antes do script novo; o usuário rodou a versão antiga do script
com o template novo e o erro não fez sentido.

**A regra.** Antes de executar uma versão nova de qualquer coisa que veio por sincronização, confirme um marcador que
só existe na versão nova (`Select-String -Pattern '<texto novo>' -Quiet` deve devolver `True`). Melhor ainda:
versione os scripts e imprima a versão no início.

### 1.8 O usuário irritado está certo

**O que aconteceu.** "Por que você não corrige logo o que precisa?" depois de o teste de importação bloquear o deploy.

**A regra.** Quando quem usa perde a paciência, a causa costuma ser uma decisão minha que empurrou o custo para ele
(testar na máquina dele o que deveria ser testado na minha). Corrija a causa, valide em cenários que representem a
máquina dele, e diga o que mudou em uma frase antes de pedir para rodar de novo.

---

## Tema 2. Azure: Bicep, ARM, cotas e providers

### 2.1 O nome de um role assignment tem que ser calculável antes do deploy (BCP120)

O `principalId` da identidade gerenciada só existe depois de criar a app; usar no `guid()` do nome quebra a compilação.
**Regra:** derive o GUID de nomes determinísticos (`guid(recurso.id, nomeDaApp, papel)`) e use o `principalId` só na
propriedade. Consequência: recriar a app com o mesmo nome colide com a atribuição antiga
(`RoleAssignmentUpdateNotPermitted`); remova as órfãs (`ObjectType = Unknown`).

### 2.2 Recurso condicional: operador `!` quando o ramo garante que existe

`if (enableEmail)` gera `BCP318` ao acessar propriedades. **Regra:** `recurso!.propriedade` quando o código só acessa
no ramo em que o recurso existe; `recurso.?propriedade` quando pode ser nulo de verdade.

### 2.3 Sem URL fixa de nuvem

`core.windows.net` não funciona em nuvens soberanas e o linter avisa. **Regra:** `environment().suffixes.storage`.

### 2.4 Cota de App Service: por família de SKU **e** total, por assinatura

`InternalSubscriptionIsOverQuotaForSku` com `Current Limit (B1 VMs): 0` é cota da família Basic; com
`Current Limit (Total VMs): 0` é a cota geral, e **nenhum SKU pago passa em nenhuma região**. Assinaturas internas e de
teste nascem assim. **Regra:** leia qual limite está em zero antes de trocar região; se for `Total VMs`, as saídas são
pedir cota (portal > Quotas > App Service), Free (F1) ou Container Apps (cota própria). Não existe cmdlet simples para
consultar essa cota: o preflight é o teste.

### 2.5 Resource providers em assinatura nova

`MissingSubscriptionRegistration` no primeiro deploy. **Regra:** registre os providers que o template usa antes do
deploy (`Register-AzResourceProvider`), de forma idempotente, no início do instalador.

### 2.6 `New-AzResourceGroupDeployment -TemplateFile x.bicep` precisa do `bicep` no PATH

`az bicep install` coloca o binário em `~/.azure/bin`, fora do PATH. **Regra:** função `Ensure-BicepCli` em todo
script que compila Bicep; compile com `bicep build` antes para ver erros com linha e coluna.

### 2.7 Papéis de plano de dados não vêm de Owner

`Storage Blob Data Reader` precisa ser concedido explicitamente, à identidade da app e a você mesmo (para o Power BI e
o Storage browser). Propagação leva de 5 a 15 minutos. **Regra:** conceda no Bicep, confira no instalador, avise sobre
a propagação.

---

## Tema 3. Azure CLI e PowerShell

### 3.1 Uma extensão quebrada derruba a CLI inteira, de forma intermitente

A CLI lê os metadados de **todas** as extensões ao reconstruir a tabela de comandos. Uma pasta `*.dist-info` sem o
arquivo `METADATA` produz `PermissionError: [WinError 5]`. `az extension list` **não** revela (engole o erro).
**Regra:** scripts usam sempre `AZURE_EXTENSION_DIR` próprio; para diagnosticar a pasta do usuário, procure `dist-info`
sem `METADATA`; limpeza com `Remove-Item` como administrador.

### 3.2 Console do Windows em cp1252 quebra comandos que mostram log

`UnicodeEncodeError: 'charmap' codec can't encode` no meio de um build que **continuou na nuvem**. **Regra:**
`$env:PYTHONIOENCODING='utf-8'` e `$env:PYTHONUTF8='1'` no início de todo script que chama `az`; para operações longas,
prefira `--no-wait` e acompanhar por status a depender do streaming de log.

### 3.3 `--no-wait` descarta a resposta

Comandos com `supports_no_wait` não devolvem nada no stdout; o id vem como aviso em stderr, que `--only-show-errors`
esconde. **Regra:** capture `2>&1` sem `--only-show-errors`, leia o id do aviso (`Queued a build with ID: <id>`), ou liste
em seguida (`az acr task list-runs --top 1`).

### 3.4 `az account set` pode falhar em silêncio

**Regra:** confirme com `az account show --query id -o tsv` antes de qualquer comando que crie recurso; abra `az login`
se não bater.

### 3.5 `az acr build --file` é relativo ao contexto

Caminho absoluto da máquina não existe no servidor de build. **Regra:** `--file Dockerfile`, e imagem base do
`mcr.microsoft.com` (o Docker Hub limita pulls anônimos dos IPs compartilhados do ACR Tasks).

### 3.6 Armadilhas de sintaxe do PowerShell que apareceram

| Armadilha | Regra |
|---|---|
| `"$code: texto"` | `"${code}: texto"` (o dois-pontos é sintaxe de escopo de variável) |
| `"$obj.Prop"` | `"$($obj.Prop)"` |
| `$LASTEXITCODE` lido depois de outro comando | guarde logo após: `$codigo = $LASTEXITCODE` |
| `Compress-Archive` no Windows | `[System.IO.Compression.ZipFile]::CreateFromDirectory` (separador `/`) |
| `$ErrorActionPreference = 'Stop'` com avisos do `az` em stderr | capture `2>&1` e trate como texto |
| `. .\script.ps1` (dot-sourcing) para executar | `.\script.ps1`; dot-source só para importar funções |
| Windows PowerShell 5.1 | `#Requires -Version 7.0` no topo, para o erro ser claro |

---

## Tema 4. Container Apps, App Service e Easy Auth

### 4.1 Container Apps tem cota própria e não exige Docker local

`az acr build` constrói a imagem na nuvem (ACR Tasks). **Regra:** o caminho Container Apps pode ser tão "um comando"
quanto o App Service: registry no Bicep, `AcrPull` por identidade, imagem de espera na primeira passada, troca da
imagem e da porta depois do build, reexecuções preservam a imagem.

### 4.2 Dois logs, dois papéis

O log de **sistema** diz **que** a réplica não subiu (pull, probe, `ContainerBackOff`); o log do **console** diz **por
quê** (a saída do processo, com o traceback). **Regra:** em "a URL não abre", leia os dois, nessa ordem. O
`Diagnose-FinOpsWebApp.ps1` automatiza.

### 4.3 401 na frente de um container morto

Com Easy Auth ligado e o container caído, a resposta é 401 (ou redirecionamento). Parece problema de login; é
problema de aplicação. **Regra:** confira `latestReadyRevisionName == latestRevisionName` e réplicas antes de mexer
na autenticação.

### 4.4 Nunca ligue autenticação sem provedor confirmado

`--enabled true` com `clientId` vazio bloqueia tudo. **Regra:** grave a configuração completa de uma vez (API), leia
de volta, confira `clientId`, `issuer` e caminhos excluídos; se não bater, desligue. `/api/health` sempre fora do login
(health check da plataforma e validação do instalador).

### 4.5 `--issuer` e `--tenant-id` não convivem; `--set` aceita um só par

Regras herdadas da extensão `authV2`. **Regra:** evite os subcomandos; use a API (`authConfigs/current`,
`authsettingsV2`).

### 4.6 App Service parado continua cobrando

O **plano** cobra, não o site. **Regra:** para custo zero, apague o plano ou troque para Free; no Container Apps,
`az containerapp stop` zera a computação e o ambiente Consumption não cobra ocioso.

### 4.7 Um processo só, uvicorn direto

`gunicorn` com `UvicornWorker` está descontinuado, e vários workers duplicariam o agendador interno. **Regra:**
`python -m uvicorn main:app --app-dir api`; escala horizontal vem de réplicas, não de workers.

---

## Tema 5. FinOps hub, FOCUS e Power BI

### 5.1 O FOCUS é o contrato; a versão importa

Cost Management exporta 1.0, 1.0r2 e 1.2-preview. Os relatórios Power BI para storage leem 1.0 (`SkuMeterName`);
o 1.2 renomeou para `SkuMeter`. A conversão entre versões só acontece no Kusto (nível 1). **Regra:** no nível 0, exports
em 1.0r2 para o Power BI; na interface web, um dicionário de equivalências aceita qualquer versão.

### 5.2 O manifest é o gatilho

O hub ingere uma pasta quando o `manifest.json` aparece nela. **Regra:** qualquer conector novo (AWS, Google, OCI)
copia o parquet primeiro e grava o manifest por último. É assim que se acrescenta uma nuvem sem tocar no hub.

### 5.3 `overwrite` nos exports é obrigatório

Sem ele o mesmo mês entra duas vezes. Vale para Azure (export diário sobrescreve o mês) e AWS (`OVERWRITE_REPORT`).

### 5.4 `ingestion.months` não apaga nada

É metadado para as consultas; quem apaga blob é a regra de ciclo de vida da storage. **Regra:** retenção tem duas
metades (o que a consulta enxerga e o que o storage guarda); trate as duas.

### 5.5 Power BI no storage: URL, credencial e meses

A URL do parâmetro precisa terminar em `/ingestion`; a credencial (conta organizacional) é no nível da raiz;
`Number of Months` nunca vazio. Um relatório em branco com "pending changes" é só o Close & Apply que faltou. Refresh
agendado no Service quebra com URL de caminho: use a raiz.

### 5.6 Deploy scripts do hub e política de chave compartilhada

Assinaturas com política que desliga chave em storage derrubam os deployment scripts do template. A saída oficial
dos mantenedores: tag `SecurityControl = Ignore` no resource group.

### 5.7 Comparar mês parcial com mês cheio mente

**Regra:** MTD contra os mesmos N dias do mês anterior, e rotule.

---

## Tema 6. Python, dados e testes

### 6.1 O corpo do módulo executa de cima para baixo

Chamar uma função no meio do arquivo que usa outra definida abaixo dá `NameError` na importação. **Regra:** a
inicialização (configurar fonte, iniciar threads) vai no **fim** do módulo, ou dentro de uma função chamada no fim.

### 6.2 pandas 3 e pyarrow

pandas 3 lê `pyarrow.__version__` e importa `pyarrow.compute` ao carregar; um substituto parcial confunde. **Regra:**
para testar sem pyarrow, esconda-o por completo (`sys.meta_path`) em vez de simular.

### 6.3 matplotlib em servidor

`pyplot` tem estado global e não é thread-safe; e precisa de pasta gravável para cache (`MPLCONFIGDIR`). **Regra:**
API orientada a objeto (`Figure()`), trava, `MPLCONFIGDIR=/tmp/matplotlib`.

### 6.4 Tags: parse uma vez por string distinta

Milhões de linhas, poucas dezenas de milhares de combinações de tags. **Regra:** dicionário `TagsStr -> dict`,
reaproveitado por governança e chargeback. Kusto devolve `Tags` como dict, parquet como texto: normalize para texto
antes.

### 6.5 Leia só as colunas necessárias

pyarrow com `columns=` reduz memória e tempo de forma expressiva. **Regra:** liste as colunas desejadas em um lugar
(`COLUNAS_DESEJADAS`) e use nas duas fontes.

### 6.6 Exportação por link direto não trata erro

`<a href download>` não mostra progresso, não trata 401 nem 500, e não funciona em `file://`. **Regra:** `fetch` →
`blob` → link temporário, com indicador e mensagem; a prévia embute os binários reais em base64.

### 6.7 A prévia roda o mesmo código da produção

`build_preview.py` injeta uma fonte estática e chama as mesmas funções das rotas. **Regra:** prévia não é maquete;
se um número aparece na prévia, é o número que a produção daria com aquele dado. Isso encontrou o bug da comparação
mensal antes do deploy.

---

## Tema 7. Documentação e replicabilidade

### 7.1 Documente o caminho real, não o caminho feliz

A documentação oficial descreve o que funciona. O que faltava era o que **não** funciona e por quê. **Regra:** cada erro
real vira um item com sintoma, causa, raciocínio e onde a correção está automatizada. É o que transforma um script em
um asset replicável.

### 7.2 A correção vai para o código, não para o texto

Toda vez que uma correção manual foi necessária, ela virou parâmetro, função ou verificação no instalador. **Regra:** o
usuário nunca deve "lembrar de fazer X à mão"; se precisa lembrar, o script está incompleto.

### 7.3 Um README de 200 KB é uma parede

**Regra:** README como índice e início rápido (10 KB); um documento por tema em `docs/`; números de seção mantidos como
identificadores estáveis; referências cruzadas como links verificados por script (zero quebrados).

### 7.4 Nomeie a fonte de cada afirmação

Percentuais de economia, custos, limites: sempre com a fonte (documentação, mensagem de erro real, medição). O que não
tem fonte é opinião, e o texto diz que é.

### 7.5 Sem travessões, com créditos

Estilo do autor: vírgula, dois-pontos ou parênteses; créditos ("Construído por..., baseado no Microsoft FinOps toolkit")
em todo arquivo, tela, PDF, Excel e e-mail. Verificado por script antes de publicar.

---

## Checklist para o próximo projeto

Antes de escrever a primeira linha:

- [ ] Desenhe as camadas e diga qual é o **contrato** entre elas (aqui, o FOCUS). Cada camada deve ser substituível.
- [ ] Decida o que é **seu** e o que é de um produto suportado. Construa sobre o suportado; estenda onde ele não chega.
- [ ] Liste os segredos que a solução teria. Elimine um a um com identidade gerenciada e RBAC. O que sobrar vai para Key Vault.

Nos scripts de instalação:

- [ ] `#Requires -Version 7.0`; UTF-8 (`PYTHONIOENCODING`, `PYTHONUTF8`, `Console.OutputEncoding`).
- [ ] `Ensure-BicepCli`; `Ensure-ResourceProviders`; `AZURE_EXTENSION_DIR` isolado; `az account show` conferido.
- [ ] Compilar (`bicep build`) e validar (`Test-AzResourceGroupDeployment`) antes de implantar; mostrar a mensagem mais interna; testar alternativas quando for cota ou SKU.
- [ ] Idempotente: rodar de novo corrige. `-WhatIf`. Etapas nomeadas com "para que serve".
- [ ] Teste de importação do código antes de publicar, que bloqueia só por erro no código.
- [ ] Nunca ligar autenticação sem confirmar o provedor; health check fora do login.
- [ ] Mensagem final com: URL, como republicar, como diagnosticar, como desligar.

No código:

- [ ] Inicialização no fim do módulo. Um processo por container. Nada de estado global de biblioteca (pyplot).
- [ ] Fonte de dados atrás de uma interface (`_ler()`); cache com trava; ouvintes para reações pós-carga.
- [ ] Comparações de período honestas (MTD vs mesmos dias). Percentuais com fonte e confiança.
- [ ] Testes: lógica (`test_local`), inicialização (`test_import`), renderização (prévia com as funções reais).

Na documentação:

- [ ] README curto com mapa; um arquivo por tema; links verificados; créditos e estilo conferidos por script.
- [ ] Diário de bordo desde o primeiro erro: sintoma, causa, raciocínio, correção automatizada.
- [ ] Guia de estudo do código com roteiros de apresentação e exercícios.
- [ ] Este caderno, atualizado com o que o projeto novo ensinar.

Na operação:

- [ ] Script de ligar e desligar com a tabela de custo parado. Script de diagnóstico somente leitura.
- [ ] Antes de executar versão nova vinda por sincronização, confirmar um marcador da versão nova.

---

## Frases para lembrar

* **"O FOCUS é o contrato; cada camada é substituível."**
* **"Nós não reescrevemos o hub; instalamos com os erros resolvidos e estendemos onde ele não chega."**
* **"Teste o caminho que a produção usa."**
* **"Só erro no código bloqueia; falta de biblioteca aqui é aviso."**
* **"Quando o teste não é confiável, elimine a condição."**
* **"Quando a CLI abstrai mal, fale com a API, e leia de volta."**
* **"Veja os erros internos: a causa está na mensagem de maior recuo."**
* **"O manifest é o gatilho."**
* **"MTD contra os mesmos dias, ou o dashboard mente."**
* **"A correção vai para o código, não para o texto."**
* **"Cada rodada avança um degrau; registre o degrau."**
