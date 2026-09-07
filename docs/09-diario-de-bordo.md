# Diário de bordo: os erros reais de uma implantação e o raciocínio por trás de cada um

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [16. Diário de bordo: os erros reais de uma implantação, e o raciocínio por trás de cada um](#16-diário-de-bordo-os-erros-reais-de-uma-implantação-e-o-raciocínio-por-trás-de-cada-um)

---

## 16. Diário de bordo: os erros reais de uma implantação, e o raciocínio por trás de cada um

Esta seção existe porque a documentação oficial descreve o caminho feliz. O que segue é o caminho real de uma
implantação do zero, em ordem cronológica, com **sintoma, causa, por que acontece e onde a correção já está
automatizada** neste kit. Se você bater em qualquer uma dessas paredes, a resposta está aqui.

### 1. `Cannot find Bicep. Please add Bicep to your PATH`

**Sintoma:** o `Deploy-FinOpsHub` morre logo no começo, mesmo com o Bicep instalado.

**Causa:** `az bicep install` instala o binário em `~/.azure/bin`, que **não entra no PATH**. O `Deploy-FinOpsHub`
procura `bicep` no PATH e não acha.

**Raciocínio:** é fácil concluir que o Bicep não está instalado e reinstalar em loop. O teste que separa os dois
casos é `az bicep version` funcionar e `bicep --version` falhar. Se for isso, é PATH, não instalação.

**Correção no kit:** a função `Ensure-BicepCli` procura a cópia da Azure CLI, e se não achar baixa o binário para
`~/.bicep`, adicionando ao PATH da sessão. Não é preciso fazer nada.

### 2. `KeyBasedAuthenticationNotPermitted` / `DeploymentScriptOperationFailed`

**Sintoma:** o deploy do hub falha na criação dos deployment scripts.

**Causa:** uma política da assinatura desliga o acesso por chave compartilhada nas storage accounts. Os deployment
scripts do template do hub montam um file share **usando chave**, então não conseguem subir.

**Raciocínio:** o erro aponta para a storage, mas o problema é de governança, não de storage. Assinaturas internas
da Microsoft (SFI) e Landing Zones corporativas costumam ter essa política.

**Correção no kit:** parâmetro `-ResourceGroupTags @{ SecurityControl = 'Ignore' }`, que é a saída recomendada
pelos mantenedores do toolkit nas issues #1816 e #2241. O script aplica a tag no resource group e reabilita
`AllowSharedKeyAccess` nas storages já criadas. Em tenant de cliente, a alternativa é uma isenção de política
para o resource group.

### 3. `The subscription '00000000-...' could not be found`

**Sintoma:** o script reclama de uma assinatura de exemplo, mesmo você tendo preenchido o arquivo.

**Causa:** o `parameters.example.json` foi editado no lugar, e uma atualização do kit substituiu o arquivo,
levando junto os valores preenchidos.

**Raciocínio:** arquivos de exemplo são modelos, e modelos são sobrescritos. Sempre copie antes de preencher.

**Correção no kit:** o script agora **valida placeholders** e avisa em amarelo quando você está usando o
`parameters.example.json` diretamente. Copie para `parameters.json`:

```powershell
Copy-Item .\parameters.example.json .\parameters.json
```

### 4. `Nao encontrei a storage account ou o Data Factory do hub`

**Sintoma:** o hub aparece verde no portal, mas o script não encontra os recursos.

**Causa:** a descoberta era por prefixo de nome, e o template gera sufixos aleatórios.

**Correção no kit:** a descoberta passou a usar os **outputs do deployment** (`storageAccountName`,
`dataFactoryName`), com fallback por tag `cm-resource-parent` e só então por prefixo. Se tudo falhar, o script
lista os recursos do resource group para você ver o que existe.

### 5. `Unrecognized parameter "--file"` ao compilar o Bicep

**Sintoma:** `bicep build --file arquivo.bicep` falha, mas o `az bicep build --file` funciona.

**Causa:** são **duas CLIs diferentes com sintaxes diferentes**. O Bicep CLI standalone recebe o arquivo como
argumento posicional; o `--file` é sintaxe do wrapper da Azure CLI.

**Forma correta:**

```powershell
bicep build arquivo.bicep --outfile arquivo.json      # Bicep CLI standalone
az bicep build --file arquivo.bicep --outfile a.json  # via Azure CLI
```

### 6. `RBACAccessDenied` (HTTP 401) na pipeline `config_ConfigureExports`

**Sintoma:** a pipeline do hub tenta criar o export e recebe 401.

**Causa:** a identidade gerenciada do Data Factory tinha **Cost Management Reader**. Esse papel **lê** exports mas
**não cria**. Para criar é preciso **Cost Management Contributor**.

**Raciocínio:** o nome "Reader" engana. Muita gente concede Reader achando que basta para a leitura de custo, mas
o hub precisa **criar e executar** exports.

**Correção no kit:** a etapa 3 concede os papéis automaticamente e imprime o object id da identidade.

### 7. `The user does not have authorization to perform 'Microsoft.Authorization/roleAssignments/write' action on specified storage account`

**Sintoma:** falha ao criar o export gerenciado.

**Causa:** ao criar um export com destino em storage, o **Cost Management atribui um papel a si mesmo** naquela
storage. Quem chama a API precisa poder gravar role assignments ali, ou seja, precisa de
**User Access Administrator** no escopo da storage.

**Raciocínio:** esse é um efeito colateral não óbvio. A permissão que falta não é sobre custo, é sobre RBAC.

**Correção no kit:** concedida automaticamente na etapa 3.

### 8. Atividade `Save Scopes` como *Failed* com a pipeline *Succeeded*

**Sintoma:** o monitor do Data Factory mostra uma atividade vermelha dentro de uma execução verde.

**Causa:** é o **desenho do template oficial**. A atividade `Save Scopes` é a primeira tentativa de leitura da
configuração, e existe um fallback chamado `Save Scopes as Array`. A falha da primeira é o gatilho da segunda.

**Regra:** **vale o status da pipeline, não o da atividade.** Não perca tempo com essa.

### 9. "No exports to display" no Cost Management, com exports existindo

**Sintoma:** o portal mostra a lista vazia.

**Causa:** o **seletor de escopo** está em um management group, e os exports foram criados na assinatura.

**Como confirmar por fora do portal:**

```powershell
Get-FinOpsCostExport -Scope '/subscriptions/<sub-id>' | Select-Object Name, Dataset, DatasetVersion, ScheduleFrequency
```

### 10. `We were unable to connect because this credential type isn't supported for this resource`

**Sintoma:** no Power BI, ao autenticar em uma URL do `github.com`.

**Causa:** foi escolhido **Organizational account** para uma fonte **pública**. Os relatórios do toolkit leem
tabelas abertas hospedadas no GitHub e um CSV público no `ccmstorageprod`. Essas fontes **não têm login**.

**Regra mental:** URL que não é sua, **Anonymous**. URL que é sua, **Organizational account**.

### 11. Relatório totalmente em branco, com tarja `There are pending changes in your queries that haven't been applied`

**Sintoma:** todas as páginas vazias, três tarjas amarelas no topo.

**Causa:** o Power Query foi fechado pelo **X** ou por **Close**, em vez de **Close & Apply**. O modelo nunca
carregou.

**Correção:** clique em **Apply changes** na tarja e aguarde. E sempre saia do Power Query por **Close & Apply**.

### 12. `The column 'SkuMeterName' of the table wasn't found`

**Sintoma:** ao carregar o `CostSummary.pbit`, três consultas são bloqueadas.

**Causa:** incompatibilidade de versão FOCUS. O template do hub cria os exports gerenciados em **1.2-preview**, e a
conversão de 1.2 para o esquema 1.0 acontece **somente na ingestão do Data Explorer e do Fabric**. No modo Storage
não há conversão. Os relatórios `PowerBI-storage.zip` leem o esquema **1.0**, e a coluna `x_SkuMeterName` do 1.0
virou `SkuMeter` no 1.2.

**Fonte:** changelog do toolkit v12, *"Added full support for FOCUS 1.2 in Azure Data Explorer and Microsoft
Fabric... This change does not include Power BI and Data Explorer dashboard updates."*

**Raciocínio:** a tentação é editar o código M e criar a coluna na mão. Isso funciona por dez minutos e quebra na
próxima coluna. O conserto certo é alinhar a **origem**, não o relatório.

**Correção no kit:** o modo `Storage` agora usa exports manuais em **1.0r2** por padrão. Para ambientes já
implantados, use o `Repair-FocusVersion.ps1`.

### 13. Relatório carrega sem erro e mostra zero linhas, causa A: URL sem o container

**Sintoma:** silêncio total. Sem erro, sem tarja, sem dado.

**Causa:** o parâmetro de storage estava na **raiz** da conta, e não em `.../ingestion`.

**Fonte:** código de erro `HubDataNotFound` da documentação, *"If using raw exports, please correct the storage
path to not reference the ingestion container"*, ou seja, para hubs a URL **inclui** o container.

**Valor certo:** o output `storageUrlForPowerBI` do deployment. Termina em `/ingestion`.

**Detalhe que confunde:** o **parâmetro** vai com `/ingestion`, mas o **nível da credencial** deve ser a **raiz**
da conta, porque o relatório também lê o container `config`.

### 14. Relatório carrega sem erro e mostra zero linhas, causa B: `Number of Months` vazio

**Sintoma:** igual ao anterior, silêncio total.

**Causa:** o parâmetro conta **meses fechados**. Quando fica nulo, o código M calcula a data de corte como `null`,
e em Power Query um filtro do tipo `data >= null` **não dá erro, devolve zero linhas**.

**Raciocínio:** a documentação diz que vazio carrega tudo. Na prática, com o parâmetro vazio o relatório abriu
vazio, e com `6` abriu completo. Prefira sempre um número concreto, maior ou igual à quantidade de meses que
existe no storage.

**Correção no kit:** o instalador **conta os meses presentes no `ingestion`** e imprime o número pronto para
colar, no bloco final da execução.

### 15. Exportar PDF e Excel não fazia nada na prévia, e falhava em silêncio na aplicação

**Sintoma:** clicar em **Exportar** não baixava arquivo; na prévia em arquivo único, nada acontecia; na aplicação, um
erro de permissão ou de dado ainda não carregado virava uma aba em branco.

**Causa:** os botões eram links diretos (`<a href="/api/export/pdf" download>`). Um link não tem como mostrar
progresso nem tratar erro, e em um arquivo aberto do disco (`file://`) não existe servidor para responder.

**Raciocínio:** o teste que revela é abrir o console do navegador: o link "funciona" (a navegação acontece), mas o
resultado é o HTML de erro do servidor sendo salvo como `.pdf`. A exportação precisa ser tratada como uma **chamada de
API com resposta binária**, não como um link.

**Correção no kit:** `baixarExport()` em `app.js` faz `fetch`, recebe `blob`, cria o link temporário e dispara o
download, com indicador de progresso e mensagem de erro na tela. A prévia passou a embutir PDF e Excel **reais**,
gerados pelo mesmo código, para 6 e 12 meses. Teste: abra `FinOps-Preview.html`, clique em **Exportar > PDF**.

### 16. Variação de -91% entre o mês corrente e o anterior

**Sintoma:** no dia 4 do mês, o KPI de variação mensal mostrava queda de 90%, e o alerta de crescimento nunca abria.

**Causa:** comparação de um mês **incompleto** (4 dias) com um mês **inteiro** (31 dias).

**Raciocínio:** é o erro mais comum em dashboard de custo, e passa despercebido porque o número "parece" plausível
nos últimos dias do mês. A comparação correta é **acumulado até hoje** contra **os mesmos N dias** do mês anterior.

**Correção no kit:** `analytics.comparar_meses()` faz exatamente isso e alimenta o KPI, os insights e o alerta de
crescimento. A leitura completa do mês anterior continua disponível na série mensal.

### 17. Gráficos do PDF corrompidos quando duas pessoas exportavam ao mesmo tempo

**Sintoma:** em testes de carga, dois PDFs gerados em paralelo saíam com gráficos trocados ou vazios.

**Causa:** o `matplotlib.pyplot` guarda a figura "atual" em estado **global**. Duas threads desenhando ao mesmo tempo
disputam a mesma figura.

**Raciocínio:** o sintoma parece aleatório e só aparece com concorrência, por isso não se vê em teste manual. A
solução é não depender de estado global: criar `Figure()` explicitamente e desenhar nela.

**Correção no kit:** `export_report.py` usa a API orientada a objeto do matplotlib, com uma trava como segunda
garantia. O App Service recebe `MPLCONFIGDIR=/tmp/matplotlib` pelo Bicep, porque o matplotlib precisa de uma pasta
gravável para o cache de fontes e o diretório padrão não é gravável ali.

### 18. `uvicorn.workers.UvicornWorker` marcado como descontinuado

**Sintoma:** aviso no log de inicialização do App Service e risco de o comando de start quebrar em versões futuras.

**Causa:** o worker do gunicorn para uvicorn foi movido para o pacote `uvicorn-worker` e a classe antiga ficou
descontinuada. Além disso, dois workers duplicariam o agendador de alertas, que roda dentro do processo.

**Raciocínio:** para esta aplicação não existe ganho em vários processos: o cache é um só, e a concorrência de
leitura já vem do pool de threads do FastAPI. Um processo `uvicorn` direto é mais simples e elimina o aviso.

**Correção no kit:** `appCommandLine` do Bicep, `Dockerfile` e `-RunLocal` usam
`python -m uvicorn main:app --host 0.0.0.0 --port 8000 --app-dir api`. O gunicorn saiu do `requirements.txt`.

### 19. `New-AzResourceGroupDeployment` não compila o `.bicep` da interface web

**Sintoma:** o instalador da interface falha na etapa 3 com erro de Bicep ausente, na mesma máquina em que o hub
instalou sem problema.

**Causa:** o mesmo caso do erro 1, em outro script. O instalador do hub tinha a função `Ensure-BicepCli`; o da
interface não tinha.

**Raciocínio:** toda vez que um script chama `New-AzResourceGroupDeployment -TemplateFile *.bicep`, precisa garantir o
`bicep` no PATH. É uma regra do kit, não um detalhe de um script.

**Correção no kit:** `Ensure-BicepCli` também em `Deploy-FinOpsWebApp.ps1`, mais o registro dos resource providers
(`Microsoft.Web`, `Storage`, `Insights`, `OperationalInsights`, `Communication`, `App`), porque assinatura recém-criada
falha com `MissingSubscriptionRegistration` no primeiro deploy.

### 20. `az webapp auth update` sem o subcomando, e a validação final falhando com login ligado

**Sintoma:** em Azure CLI mais antiga, o Easy Auth não configurava (`'microsoft' is not in the 'az webapp auth'
command group`). Quando configurava, a etapa 7 do instalador reportava falha em `/api/status` (resposta 302).

**Causa:** os comandos `az webapp auth` da geração V2 vivem na extensão `authV2`. E com login habilitado, **toda**
rota exige conta, inclusive a que o script usa para validar.

**Raciocínio:** o health check tem que ficar fora do login por dois motivos: a plataforma precisa saber se a
aplicação está viva sem se autenticar, e o instalador precisa validar o deploy sem sessão de usuário.

**Correção no kit:** `az extension add -n authV2 --upgrade` antes de configurar; `--excluded-paths '["/api/health"]'`
no Easy Auth; a etapa 7 valida `/api/health` sempre e `/api/status` só quando não há login.

### 21. Zip do App Service com caminhos invertidos

**Sintoma:** publicação bem-sucedida, aplicação sem subir, log com arquivo não encontrado.

**Causa:** em algumas versões do PowerShell no Windows, `Compress-Archive` grava os caminhos internos do zip com
barra invertida. O App Service Linux extrai como arquivos de nome `api\main.py` na raiz, e não como pastas.

**Raciocínio:** o zip abre normal no Windows, o que esconde o problema. Só no Linux o separador importa.

**Correção no kit:** o instalador empacota com `System.IO.Compression.ZipFile`, que sempre usa `/`. Também exclui do
pacote testes, dados sintéticos, a prévia e o estado local, e publica com `--clean true`.

### 22. Preparar a troca para o Fabric antes de precisar dela

**Sintoma:** não é um erro, é uma decisão. O parquet em storage atende até alguns milhões de linhas por mês; acima
disso, a memória do App Service vira o limite.

**Raciocínio:** se a fonte estivesse espalhada pelo código, trocar para o Kusto exigiria reescrever a aplicação. Por
isso a camada de dados é uma classe com um único método a implementar (`_ler`), e todo o resto trabalha sobre o
dataframe normalizado.

**Correção no kit:** `FonteStorage` e `FonteKusto` em `data_source.py` e `kusto_source.py`, escolhidas por
`DATA_BACKEND`. O Kusto devolve `Tags` como dicionário e não como texto; a normalização aceita os dois. A consulta usa
`set notruncation`, porque o corte padrão de 500 mil linhas é silencioso. [Seção 11.11](05-referencia-tecnica-interface.md#1111-trocar-a-fonte-para-o-fabric-nível-1-sem-mexer-no-front).

### 23. `BCP120` no role assignment: o Bicep da interface não compilava

**Sintoma:** primeira execução real do `Deploy-FinOpsWebApp.ps1`. A etapa 3 morre com
`Cannot retrieve the dynamic parameters for the cmdlet` seguido de uma lista de avisos e de dois erros
`BCP120: This expression is being used in an assignment to the "name" property of the
"Microsoft.Authorization/roleAssignments" type, which requires a value that can be calculated at the start of the
deployment`.

**Causa:** o nome de um role assignment é um GUID, e eu o calculava a partir do `principalId` da identidade
gerenciada da aplicação. Esse valor **só existe depois** de a aplicação ser criada, e o ARM exige que o nome de todo
recurso seja conhecido **antes** de o deploy começar.

**Raciocínio:** a mensagem do PowerShell ("dynamic parameters") esconde o problema: é assim que o
`New-AzResourceGroupDeployment` reporta falha de compilação do Bicep. A pista boa está nas linhas `Error BCP120`, que
dizem exatamente qual expressão e por quê. Os `Warning BCP318` da mesma saída são outro assunto: o Bicep avisa que um
recurso condicional (`if (enableEmail)`, `if (ehAppService)`) pode não existir. Como o código só acessa cada recurso no
ramo em que ele existe, a resposta é o operador `!` (`site!.identity.principalId`), que a própria documentação do
BCP318 indica. E o aviso `no-hardcoded-env-urls` pede `environment().suffixes.storage` no lugar de `core.windows.net`,
para o template funcionar também em nuvens soberanas.

**Correção no kit:** o GUID passou a derivar do **nome** da aplicação (`guid(storageEstado.id, nomeSite, papel)`), que
é determinístico; o `principalId` ficou só na propriedade. Os três avisos foram eliminados. E o instalador agora
**compila o Bicep antes de implantar** (`bicep build`), mostrando erros com linha e coluna, e implanta o JSON
compilado. Uma consequência da escolha do nome: se você apagar a aplicação e recriá-la com o mesmo nome, a atribuição
antiga (apontando para a identidade que não existe mais) colide com a nova, e o ARM responde
`RoleAssignmentUpdateNotPermitted`. O instalador detecta essa mensagem e imprime o comando para remover as
atribuições órfãs (`ObjectType = Unknown`).

### 24. `preflight validation errors ... See inner errors for details`: o Azure recusou o plano e não disse por quê

**Sintoma:** segunda execução real. O Bicep compilou limpo (nenhum aviso), e o `New-AzResourceGroupDeployment` parou
com `InvalidTemplateDeployment ... 'Microsoft.Web/serverFarms (2023-12-01)' reported preflight validation errors ...
See inner errors for details`. E nenhum "inner error" na tela.

**Causa:** o ARM valida o template com cada resource provider antes de criar qualquer coisa (preflight). O provider do
App Service recusou o plano. O motivo estava nos detalhes aninhados da resposta, mas com `$ErrorActionPreference =
'Stop'` o PowerShell interrompe no primeiro registro de erro e os detalhes nunca são impressos.

**Raciocínio:** quando um erro diz "veja os erros internos", a pergunta certa é "como enxergo os erros internos".
`Test-AzResourceGroupDeployment` faz a mesma validação, não cria nada, e **devolve os erros como objetos** com a
propriedade `Details` aninhada, em vez de lançar exceção. É a ferramenta certa para esse diagnóstico, e barata o
bastante para rodar sempre. Para um plano de App Service, as causas mais comuns são falta de cota do SKU na região
(assinaturas internas e de teste, e regiões com capacidade restrita como Brazil South), SKU indisponível para a
assinatura, e resource group que já tem plano de outro sistema operacional.

Houve uma lição paralela: a saída mostrava a linha `382 | $dep = New-AzResourceGroupDeployment`, que era a versão
**anterior** do script. O OneDrive tinha sincronizado o Bicep novo, mas o script ainda não. Arquivos chegam em ordem
aleatória; antes de rodar uma versão nova, espere o ícone ficar verde ou confira um texto que só existe na nova.

**O que era, de fato:** com a validação separada, a causa apareceu na terceira camada da árvore:
`InternalSubscriptionIsOverQuotaForSku: Operation cannot be completed without additional quota. Current Limit (B1 VMs): 0,
Amount required: 1`. A assinatura (interna, do tipo MCAP) não tem cota de plano **Basic**. A primeira tentativa de
contorno foi outra região (`-Location eastus2`): **falhou com a mesma mensagem**, o que ensinou o ponto principal
deste item: quando o código começa com `Internal`, a cota é da assinatura para aquela **família** de SKU, em todas as
regiões. A terceira tentativa foi `-AppServiceSku P0v3` em eastus2, e a mensagem mudou de forma decisiva: de
`Current Limit (B1 VMs): 0` para **`Current Limit (Total VMs): 0`**. Ou seja: além da cota por família, existe a
cota **total** de instâncias de App Service, e nesta assinatura ela é zero. Nenhum SKU pago passa, em nenhuma região.
Restam três saídas: pedir cota (portal > Quotas > App Service, autoatendimento, aprovação em minutos a horas para
valores pequenos), o plano Free (F1, contagem própria, só para testar) ou o **Container Apps**, que tem cota
independente. Foi o que levou o kit a automatizar por completo o caminho Container Apps ([seção 10.4](04-interface-web.md#104-app-service-ou-container-apps)).

**Correção no kit:** a etapa 3 passou a validar com `Test-AzResourceGroupDeployment` antes de implantar, imprimindo a
árvore de erros (a causa real fica na mensagem mais interna) e uma **dica com o comando corrigido** para cada caso
conhecido. Quando a causa é cota ou SKU, o script **testa sozinho as alternativas** com a mesma validação e sem criar
nada: se a cota total está zerada, testa só F1 e Container Apps (não adianta testar famílias pagas); senão, testa
P0v3, S1 e F1 na mesma região, o SKU pedido em eastus2, eastus e westeurope, e o Container Apps. Imprime as que passam,
o comando pronto com a primeira aprovada e o caminho do portal para pedir cota. O Bicep passou a declarar o `tier` do SKU explicitamente e a desligar
`healthCheckPath` e `alwaysOn` no Free. Ganhou também `-Location` documentado (a interface pode ficar em outra região
que a do hub) e a criação de resource group próprio com `-ResourceGroup <novo> -HubResourceGroup <rg-do-hub> -Location <região>`.

**Base de conhecimento: cotas do App Service, o que aprendemos**

| Fato | Consequência prática |
|---|---|
| A cota de App Service é por **família de SKU** (Free, Basic, Standard, PremiumV2, PremiumV3, PremiumV4, Isolated), por assinatura e por região | Zerar em uma família não afeta as outras. É por isso que P0v3 passa onde B1 falha |
| Assinaturas internas e de teste (MCAP, sandbox, Visual Studio) costumam nascer com cota **zero** em algumas famílias, em todas as regiões | O código de erro vem com `Internal`. Não adianta trocar de região |
| Assinaturas comerciais (Pay-as-you-go, EA, CSP) costumam ter cota por região, e regiões com capacidade restrita (Brazil South, algumas da Europa) podem estar em zero | O código vem sem `Internal` (`SubscriptionIsOverQuotaForSku`). Trocar de região costuma resolver |
| Não existe cmdlet simples para consultar a cota de App Service antes de implantar; ela não aparece no painel de Quotas do portal | A forma barata e confiável de saber é o próprio preflight (`Test-AzResourceGroupDeployment`), que é o que o script faz |
| Aumento de cota: interno pelo `aka.ms/antquotahelp`; comercial por **ticket de suporte** (Quota, App Service) | Leva de horas a dias. Para uma demo, troque a família e siga |
| Custo aproximado (Linux, 1 instância, mês cheio): F1 grátis, B1 ~US$ 13, S1 ~US$ 70, P0v3 ~US$ 60, P1v3 ~US$ 120 | P0v3 é mais barato que S1 e tem mais memória (4 GB); para a interface é a melhor segunda opção |
| Free (F1): 60 minutos de CPU por dia, sem Always On, sem health check, sem domínio próprio | Serve para testar; o agendador de alertas só roda enquanto a app estiver acordada |
| `Current Limit (Total VMs): 0` é a cota **geral** de instâncias de App Service da assinatura, acima das cotas por família | Nenhum SKU pago passa, em nenhuma região. Sobram o Free (F1, contagem própria), o Container Apps, ou pedir cota |
| Container Apps tem cota **própria**, separada do App Service | É a saída imediata quando nenhuma família passa: `-HostingModel ContainerApps`. O script constrói a imagem na nuvem; não precisa de Docker |

**Base de conhecimento: Azure CLI na máquina de quem instala**

| Fato | Consequência prática |
|---|---|
| A CLI carrega os metadados de **todas** as extensões instaladas ao **reconstruir** a tabela de comandos (após instalar ou atualizar uma extensão, ou quando o comando não está no índice em cache) | Uma extensão quebrada derruba qualquer comando, com `PermissionError ... cliextensions\<nome>`, e de forma **intermitente**: às vezes passa, às vezes não |
| `az extension list` **não** revela a extensão quebrada: ele captura o erro de versão e segue | Não use como teste de saúde. `az version` falha de verdade quando a CLI está inutilizável |
| `AZURE_EXTENSION_DIR` muda a pasta de extensões só para o processo atual | O script **sempre** usa `.azure\cliextensions-finops`: comportamento igual em qualquer máquina, sem tocar na instalação do usuário. As extensões necessárias (`authV2`, `containerapp`) são instaladas ali uma vez |
| Assinatura exata do defeito: pasta `*.dist-info` sem o arquivo `METADATA` dentro | A CLI cai no `pkginfo`, que tenta abrir a pasta como arquivo e recebe `Access is denied`. Apague a pasta da extensão e reinstale-a se precisar dela |
| `az account set` sem checar a saída pode falhar em silêncio | Sempre confirmar com `az account show --query id -o tsv` antes de comandos que criam recursos |
| Comandos `az webapp auth` (V2) e `az containerapp` vivem em extensões (`authV2`, `containerapp`) | O script instala as duas com `az extension add --upgrade`; em CLI antiga sem elas, o erro é `... is not in the '...' command group` |
| `az acr build --file` é **relativo à raiz do contexto** enviado | Caminho absoluto da máquina não existe no servidor de build; use `--file Dockerfile` |

**Base de conhecimento: armadilhas de sintaxe do PowerShell que apareceram neste kit**

| Armadilha | Sintoma | Regra |
|---|---|---|
| `"$code: texto"` dentro de aspas duplas | `ParserError: Variable reference is not valid. ':' was not followed by a valid variable name character` | O dois-pontos faz parte da sintaxe de escopo de variável (`$env:`, `$script:`). Escreva `"${code}: texto"` |
| `"$obj.Propriedade"` em aspas duplas | Imprime o objeto inteiro seguido de `.Propriedade` literal | Use `"$($obj.Propriedade)"` |
| `$LASTEXITCODE` lido depois de um `\| Out-Null` ou de outro comando | Código de saída de outro comando | Guarde em variável logo após o comando: `$codigo = $LASTEXITCODE` |
| `Compress-Archive` no Windows | Zip com `\` nos caminhos internos; o Linux extrai como arquivos de nome `api\main.py` | Use `[System.IO.Compression.ZipFile]::CreateFromDirectory` |
| `$ErrorActionPreference = 'Stop'` com comandos `az` que escrevem avisos em stderr | O aviso vira exceção e interrompe o script | Capture com `2>&1` e trate a saída como texto; ou `--only-show-errors` quando não precisar do aviso |
| Dot-sourcing (`. .\script.ps1`) para executar | Variáveis e funções do script ficam na sessão e podem contaminar a execução seguinte | Execute com `.\script.ps1`; dot-source só quando quiser importar funções |
| A CLI escreve no console em `cp1252` no Windows; logs com caracteres fora da tabela derrubam o comando (`'charmap' codec can't encode`) | `$env:PYTHONIOENCODING='utf-8'` e `$env:PYTHONUTF8='1'` antes de qualquer `az`. Para operações longas, prefira `--no-wait` e acompanhar por status a depender do streaming de log |
| Com `--no-wait`, comandos `az` registrados com `supports_no_wait` **descartam a resposta**: stdout vazio, `--query` vazio. O id da operação sai como aviso em stderr (`Queued a build with ID: <id>`), que `--only-show-errors` esconde | Para automatizar: rode sem `--only-show-errors`, capture `2>&1`, leia o id do aviso; ou liste em seguida (`az acr task list-runs --top 1 --query '[0].runId'`) |
| `az acr task show-run --run-id` dá o status (`Queued`, `Running`, `Succeeded`, `Failed`); `az acr task logs --run-id` dá o log | Padrão robusto para build na nuvem a partir de um script, sem depender do streaming de log |
| `--excluded-paths` do Easy Auth (`az webapp auth update` e `az containerapp auth update`) espera a lista **entre colchetes e sem aspas internas**: `'[/api/health,/outro]'` | A CLI remove os colchetes e separa por vírgula; com aspas internas o caminho gravado fica errado e o health check passa a exigir login |
| ACR Tasks (build na nuvem) sai de IPs compartilhados; o Docker Hub limita pulls anônimos por IP | Imagem base do `mcr.microsoft.com`, nunca do Docker Hub |
| **Autoatendimento de cota** existe no portal: Quotas > App Service (preview), filtre a região, edite a linha do SKU (`Basic (B1) VMs`) e `Total VMs`, peça 1 ou 2 | Pedidos pequenos são aprovados em minutos a poucas horas. É o caminho para ficar no B1, o SKU recomendado do kit |

### 25. `az acr build` morre com `PermissionError ... cliextensions\aksarc`: a Azure CLI da máquina estava quebrada

**Sintoma:** primeira execução com `-HostingModel ContainerApps`. **A etapa 3 passou** (Container App, registry,
storage de estado, e-mail e identidade criados; validação OK) e a etapa 4 confirmou o papel no storage do hub. Na
etapa 5, o `az acr build` falhou antes de enviar qualquer coisa, com um traceback do Python terminando em
`PermissionError: [WinError 5] Access is denied: 'C:\Users\...\.azure\cliextensions\aksarc\aksarc-1.5.74.dist-info'`.

**Causa:** nada a ver com o registry nem com o Azure. A Azure CLI, ao montar a tabela de comandos, **lê os metadados de
todas as extensões instaladas**. Uma delas (`aksarc`, do AKS habilitado pelo Arc) estava com a pasta inacessível
(instalação interrompida, ou feita por outro usuário ou em sessão elevada). Basta uma extensão assim para derrubar
qualquer comando `az` que precise carregar extensões.

**Raciocínio:** a pista é o caminho no erro: `.azure\cliextensions\<nome>`. Se aparecer, o problema é local e vai se
repetir em qualquer comando, não só no build. O teste que isola é `az extension list`: se falhar com a mesma mensagem,
está confirmado. A saída que não mexe em nada do usuário é a variável de ambiente `AZURE_EXTENSION_DIR`, que faz a
CLI usar **outra pasta de extensões** só naquela sessão. A limpeza definitiva é apagar a pasta da extensão quebrada
(`Remove-Item "$HOME\.azure\cliextensions\aksarc" -Recurse -Force`, em PowerShell como administrador se o acesso
for negado) ou `az extension remove -n aksarc`.

**Correção no kit:** a etapa 1 passou a **sondar a CLI** (`az extension list`). Se falhar, identifica a extensão pelo
caminho da mensagem, cria uma pasta isolada (`.azure\cliextensions-finops`), aponta `AZURE_EXTENSION_DIR` para ela e
segue; as extensões que o script precisa (`authV2`, `containerapp`) são instaladas ali. A etapa 1 também passou a
confirmar que a CLI está **logada na assinatura certa** (`az account show`), abrindo `az login` se não estiver: o
`az account set` anterior tinha a saída suprimida, e uma falha ali passaria despercebida. De quebra, o `--file` do
`az acr build` passou a ser relativo ao contexto (`Dockerfile`), porque um caminho absoluto da máquina não existe no
servidor de build, e a etapa 7 espera mais tempo no Container Apps (a imagem ainda está sendo baixada).

### 25b. A extensão quebrada voltou: sondar a CLI não funciona, isolar sempre funciona

**Sintoma:** quarta execução com Container Apps. O erro do item 25 (`PermissionError ... cliextensions\aksarc`)
**voltou** no `az acr build`, embora a sonda da etapa 1 (`az extension list`) tivesse passado sem reclamar.

**Causa:** dois fatos que só ficaram claros lendo o código da CLI. Primeiro, `az extension list` **engole** o erro de
metadados (mostra a versão vazia e segue), então não serve como teste. Segundo, a CLI só lê os metadados de todas as
extensões quando **reconstrói a tabela de comandos**, e isso acontece de forma intermitente: depois de instalar ou
atualizar uma extensão, ou quando o comando não está no índice em cache. Foi por isso que, na execução anterior, o
`az acr build` passou por essa fase (e caiu no `charmap`), e nesta caiu na extensão: entre as duas, o script tinha
atualizado a extensão `containerapp`, o que invalidou o índice.

**Raciocínio:** quando um defeito é intermitente e o teste não é confiável, não se testa: **elimina-se a condição**.
A variável `AZURE_EXTENSION_DIR` faz a CLI usar outra pasta de extensões; se o script **sempre** usar uma pasta
própria, a pasta do usuário deixa de importar, em qualquer máquina, sem depender de detectar nada. O custo é
instalar ali as duas extensões que o script usa (`authV2` e `containerapp`), uma vez; nas execuções seguintes a pasta
é reaproveitada. É também o comportamento mais previsível para um asset que vai rodar em máquinas de clientes.

**Correção no kit:** a etapa 1 sempre aponta `AZURE_EXTENSION_DIR` para `.azure\cliextensions-finops`. Como
diagnóstico informativo, ela varre a pasta original procurando `*.dist-info` sem o arquivo `METADATA` (a assinatura
exata do defeito) ou pastas inacessíveis, e imprime o comando de limpeza para cada extensão quebrada, sem bloquear.
A verificação de saúde passou a ser `az version`, que falha de verdade se a CLI estiver inutilizável.

### 26. `UnicodeEncodeError: 'charmap' codec can't encode`: o build rodou na nuvem, o que quebrou foi a tela

**Sintoma:** segunda execução com Container Apps. A proteção da CLI funcionou (o erro da extensão sumiu), e o
`az acr build` **enfileirou e começou o build no registry**. Segundos depois, traceback do Python terminando em
`encodings\cp1252.py ... UnicodeEncodeError: 'charmap' codec can't encode characters in position 392-431`, e o
script tratou como falha.

**Causa:** a Azure CLI é um programa Python. No Windows, ela escreve no console com a codificação `cp1252`, que não
representa muitos caracteres. O log do build (que a CLI transmite ao vivo para a tela) trouxe caracteres fora dessa
tabela, as barras de progresso do `pip` dentro da imagem, e a **exibição** quebrou. O build em si continuou na nuvem.

**Raciocínio:** a pista está no traceback: `_stream_utils.py` e `colorama/ansitowin32.py` são o caminho do streaming
de log, não do build. Sempre que a última linha é `cp1252.py ... encode`, o problema é o console, não a operação.
Dois remédios, e o kit aplica os dois: (1) forçar UTF-8 no processo Python (`PYTHONIOENCODING=utf-8`,
`PYTHONUTF8=1`) e no console (`[Console]::OutputEncoding`), o que resolve para **todos** os comandos `az` da sessão;
(2) não depender do streaming: enfileirar com `--no-wait --no-logs`, acompanhar o status da execução com
`az acr task show-run` e só baixar o log (`az acr task logs`) se o status final não for `Succeeded`. Assim a exibição
nunca mais derruba o comando.

**Correção no kit:** UTF-8 definido no início do script (vale também para o `-RunLocal`, que roda Python); build
enfileirado e acompanhado por status, com as últimas 40 linhas do log impressas em caso de falha; depois de trocar a
imagem, o script espera a revisão nova ficar pronta (o primeiro pull com `AcrPull` recém-concedido pode falhar por
propagação do RBAC) e orienta a repetir com `-CodeOnly` se não ficar. O script passou a declarar `#Requires -Version 7.0`,
para que em Windows PowerShell 5.1 a mensagem seja clara em vez de um erro obscuro no meio do caminho.

### 27. `--no-wait` sem saída: a CLI enfileirou o build e descartou a resposta

**Sintoma:** quinta execução com Container Apps, já com a extensão quebrada removida. Nenhum traceback, nenhuma
mensagem: só "Nao consegui enfileirar o build no registry". E o build **tinha sido enfileirado**.

**Causa:** no framework da Azure CLI, quando um comando registrado com `supports_no_wait` recebe `--no-wait`, o
resultado do comando é **descartado** antes de chegar à saída: nada no stdout, e `--query runId` devolve vazio. O
identificador da execução só aparece no aviso `Queued a build with ID: <id>`, em stderr, que o `--only-show-errors`
(que eu usava para deixar a saída limpa) escondia. Duas escolhas razoáveis, juntas, produziram silêncio total.

**Raciocínio:** "não houve erro, mas também não houve resultado" é a assinatura de saída descartada, não de falha. A
confirmação foi `az acr task list-runs -r <registry> -o table`, que mostrou os builds das execuções anteriores
enfileirados e concluídos. Regra prática: em comandos `az` com `--no-wait`, o identificador vem do aviso no stderr
ou de um comando de listagem em seguida; nunca do stdout.

**Correção no kit:** o `az acr build` roda sem `--only-show-errors`, as linhas informativas da CLI (empacotando o
contexto, enviando, "Queued a build with ID") são exibidas em cinza, e o id é lido do aviso; se não vier, o script
pega a execução mais recente com `az acr task list-runs --top 1`. O acompanhamento por status continua igual.

### 28. `ContainerBackOff` e 401 na URL: um `NameError` na importação do `main.py`

**Sintoma:** o instalador rodou até o fim, imprimiu "PRONTO" com a URL, e a URL não abria. O `Diagnose-FinOpsWebApp.ps1`
mostrou: revisão nova `Unhealthy`, `ActivationFailed`, 2 réplicas em `ContainerBackOff` ("Persistent Failure to
start container"); `/api/health` e `/` respondendo **401**; e, no log do console, o traceback do uvicorn terminando em
`File "/app/api/main.py", line 63 ... configurar_fonte(criar_fonte()) ... NameError: name '_pos_carga' is not defined`.

**Causa:** um bug meu no código. `main.py` chamava `configurar_fonte(criar_fonte())` **no meio do arquivo**, e essa
função usa `_pos_carga`, definida só mais abaixo. Em Python, o corpo do módulo executa de cima para baixo na
importação; a chamada rodou antes de a função existir. O processo morreu antes de abrir a porta 8000, o Container
Apps tentou de novo dezenas de vezes (`ContainerBackOff`) e nunca teve uma réplica saudável. O **401** era o Easy Auth
respondendo na frente de um container morto: com `unauthenticatedClientAction = RedirectToLoginPage`, a resposta
para chamadas sem navegador é 401 mesmo (só o navegador recebe o redirecionamento), e o diagnóstico ainda mostrou
`clientId=` vazio, um segundo problema a confirmar (item 29).

**Por que os testes não pegaram:** `test_local.py` testa a lógica de negócio e **não importa `main.py`**; e a prévia,
na máquina sem FastAPI, cai no "modo direto", que também não importa. O único lugar onde `import main` acontecia de
verdade era o uvicorn dentro do container. Uma classe inteira de erro (o módulo não carrega) estava fora da rede de
testes.

**Raciocínio:** quando o container "não sobe", os dois logs do Container Apps dividem o trabalho: o log de **sistema**
diz **que** a réplica não subiu (pull, probes, back-off); o log do **console** diz **por quê** (a saída do processo). O
traceback estava lá, com arquivo e linha. E a lição de método: todo teste precisa exercitar o **caminho que a produção
usa**. Se a produção faz `import main`, algum teste precisa fazer `import main`.

**Correção no kit:** (1) `main.py` passou a configurar a fonte padrão **no fim do módulo** (`configurar_fonte_padrao()`),
depois de todas as funções existirem; o agendador de alertas segue o mesmo caminho (`iniciar_agendador()`), porque
dependia da fonte já configurada. (2) Novo `api/test_import.py`: importa `main.py` como o uvicorn faz, com
substitutos mínimos do FastAPI quando ele não está instalado, e confere fonte configurada, ouvinte registrado e 20
rotas essenciais entre as 38 registradas. Rodado contra a versão com o bug, falha com o mesmo `NameError` do
container. (3) O instalador roda esse teste **antes de publicar** (etapa 5) e aborta se falhar: um erro de
importação passa a aparecer em segundos na sua tela, e não minutos depois como `ContainerBackOff`.

**Correção da correção (mesma noite):** a primeira versão do `test_import.py` só substituía o FastAPI, e na máquina
do usuário (que tem Python mas não tem `matplotlib`, `reportlab`, `openpyxl` nem os SDKs do Azure, porque tudo isso só
existe dentro do container) falhou com `ModuleNotFoundError: No module named 'matplotlib'` e **bloqueou o deploy**. Um
teste que protege o deploy não pode depender do ambiente de quem instala. A versão atual substitui **qualquer**
biblioteca de terceiros ausente por um módulo curinga (aceita qualquer atributo, chamada, decorador ou classe base);
só `pandas` e `numpy` precisam ser reais, e sem eles o teste é **pulado** com aviso (código de saída 2), nunca
bloqueia. Validado em quatro cenários: máquina completa, máquina só com pandas e numpy, máquina sem pandas (pula), e
código com o bug reintroduzido (falha apontando `main.py`, linha exata). Regra que fica: **um teste de
pré-publicação distingue "erro no código" de "falta biblioteca aqui"; só o primeiro bloqueia.**

### 29. Easy Auth do Container Apps com `clientId` vazio

**Sintoma:** no mesmo diagnóstico do item 28, a seção de autenticação mostrou `habilitada=True` mas `clientId=` e
`issuer=` vazios.

**Causa provável:** o `az containerapp auth microsoft update` da etapa 6 falhou em silêncio (a saída estava suprimida
com `2>$null`) e o `az containerapp auth update --enabled true` seguinte ligou a autenticação **sem provedor**. Nesse
estado toda requisição é recusada, mesmo com o container saudável.

**Raciocínio:** ligar a autenticação e configurar o provedor são dois comandos; se o segundo passo depende do
primeiro, o script tem que **verificar** o primeiro antes de seguir, e não assumir. A verificação certa é
`az containerapp auth show` e conferir `identityProviders.azureActiveDirectory.registration.clientId`.

**O que era, de fato (confirmado na execução seguinte):** o `az containerapp auth microsoft update` recusa `--issuer`
e `--tenant-id` juntos (regra herdada da extensão `authV2`: "cannot both be configured"), e o caminho alternativo com
`--set` aceita um único `chave=valor`, não três. Os dois comandos falharam, a verificação pegou, a autenticação foi
desligada e a URL ficou pública, com aviso. Melhor que bloqueada, mas ainda não era o resultado.

**Correção no kit (definitiva):** a autenticação saiu do instalador e virou um script próprio, `Set-FinOpsWebAuth.ps1`,
que **não usa** os subcomandos `auth microsoft update` nem `auth update`. Ele monta a configuração inteira (plataforma,
regra global, provedor com `clientId` e `issuer`, audiências, caminhos excluídos) e grava de uma vez com `az rest` no
recurso `authConfigs/current` (Container Apps) ou `config/authsettingsV2` (App Service). Depois **lê de volta** e
confere campo a campo; se não bater, desliga. E testa a URL: `/api/health` em 200, `/` redirecionando para
`login.microsoftonline.com`. O instalador (etapa 6) apenas chama esse script. Regra que fica: **quando a CLI abstrai
mal um recurso, fale com a API do recurso**; a API tem um contrato só, a CLI tem uma versão por mês.

### O padrão que emerge de tudo isso

Três lições que valem para qualquer implantação:

1. **Papéis de plano de dados não são herdados.** `Storage Blob Data Reader` não vem de Owner nem de Contributor.
   Precisa ser concedido explicitamente, e o RBAC do Cost Management leva de 5 a 30 minutos para propagar.
2. **Silêncio é pior que erro.** Os dois maiores atrasos vieram de filtros que devolvem zero linhas sem reclamar.
   Sempre valide a **origem** primeiro (o parquet está lá?) antes de mexer na ferramenta de visualização.
3. **Versão de esquema é contrato.** FOCUS 1.0 e 1.2 não são intercambiáveis, e a conversão só existe em parte do
   produto. Escolha a versão pelo **consumo** que você vai usar, não pela mais nova.
