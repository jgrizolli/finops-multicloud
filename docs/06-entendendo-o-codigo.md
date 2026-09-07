# Entendendo o código: guia de estudo para aprender e explicar a solução

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md).

A [referência técnica](05-referencia-tecnica-interface.md) descreve **o que** cada módulo faz. Esta página é para
**aprender**: em que ordem ler, o que observar em cada arquivo, por que foi feito assim e não de outro jeito, e
como contar essa história para uma plateia técnica ou executiva. Termina com um roteiro de apresentação em três
tamanhos, as perguntas que costumam aparecer e exercícios para fixar mexendo no código.

**Nesta página**

* [Parte 1. O mapa mental: cinco camadas](#parte-1-o-mapa-mental-cinco-camadas)
* [Parte 2. O hub e o kit de instalação (PowerShell e Bicep)](#parte-2-o-hub-e-o-kit-de-instalação-powershell-e-bicep)
* [Parte 3. A interface web, arquivo por arquivo](#parte-3-a-interface-web-arquivo-por-arquivo)
* [Parte 4. Os scripts de operação](#parte-4-os-scripts-de-operação)
* [Parte 5. As decisões de projeto e o porquê de cada uma](#parte-5-as-decisões-de-projeto-e-o-porquê-de-cada-uma)
* [Parte 6. Roteiros para explicar em 2, 10 e 30 minutos](#parte-6-roteiros-para-explicar-em-2-10-e-30-minutos)
* [Parte 7. Perguntas que vão te fazer](#parte-7-perguntas-que-vão-te-fazer)
* [Parte 8. Exercícios para aprender mexendo](#parte-8-exercícios-para-aprender-mexendo)

---

## Parte 1. O mapa mental: cinco camadas

Antes de abrir qualquer arquivo, fixe este desenho. Tudo no kit cabe em uma das cinco camadas, e cada camada só
fala com a vizinha:

```
1. FONTES        Cost Management (Azure), Data Exports (AWS), Billing Export (Google), Cost Reports (OCI)
                 Cada nuvem exporta o SEU custo no formato aberto FOCUS. Ninguem calcula custo aqui.
                        |
2. HUB           FinOps hubs (Microsoft FinOps toolkit): storage + Data Factory (+ Eventhouse no nivel 1)
                 Recebe os exports (msexports), converte em parquet (ingestion), organiza por mes e escopo.
                 Nosso kit INSTALA e OPERA o hub; nao reescreve nada dele. deploy/*.ps1, deploy/*.bicep
                        |
3. DADO          Parquet FOCUS em ingestion/Costs/<ano>/<mes>/<escopo>/  (ou funcao Costs() no Kusto)
                 E o contrato entre o hub e quem consome. Uma tabela, colunas padronizadas.
                        |
4. CONSUMO       Opcao A: relatorios Power BI do toolkit (.pbit apontando para o storage)
                 Opcao B: interface web propria (webapp/): API Python le o parquet, o navegador desenha
                        |
5. OPERACAO      Scripts que instalam, diagnosticam, ligam, desligam e protegem: webapp/*.ps1, deploy/*.ps1
```

Duas ideias sustentam o desenho, e valem para explicar qualquer parte:

* **O FOCUS é o contrato.** Todo o resto (hub, Power BI, interface) só funciona porque as quatro nuvens falam o
  mesmo esquema de colunas. É por isso que dá para acrescentar uma nuvem sem mexer na interface.
* **Cada camada é substituível.** O storage pode virar Eventhouse (nível 1); o Power BI pode virar a interface web;
  o App Service pode virar Container Apps. Nada acima ou abaixo precisa mudar. Quando alguém perguntar "e se
  precisarmos de X?", a resposta quase sempre é "troca a camada, o contrato fica".

**Ordem de leitura sugerida** (cerca de 4 horas para a primeira passagem):

| # | Leia | Tempo | O que fixar |
|---|---|---|---|
| 1 | [10 Glossário e FOCUS](10-glossario-e-focus.md) | 20 min | As quatro colunas de dinheiro e as três consultas que respondem quase tudo |
| 2 | [01 Arquitetura e escolhas](01-arquitetura-e-escolhas.md) | 15 min | Nível 0 e 1; opção A, B ou ambas |
| 3 | `deploy/Deploy-FinOpsMulticloud.ps1` (cabeçalho e as 7 etapas) | 40 min | O que o instalador faz **além** do `Deploy-FinOpsHub` oficial |
| 4 | `webapp/api/data_source.py`, função `normalizar()` | 30 min | Como o dado de qualquer nuvem e versão vira uma só tabela |
| 5 | `webapp/api/analytics.py`, função `comparar_meses()` | 15 min | O erro clássico de dashboard de custo e como evitamos |
| 6 | `webapp/api/main.py` (só a estrutura: rotas, `_dados`, `configurar_fonte_padrao`) | 30 min | O contrato da API e a ordem de inicialização |
| 7 | `webapp/static/js/app.js` (primeiras 130 linhas + `buscar` + `desenhar`) | 30 min | Estado, filtros, um só ponto de acesso à API, gráficos |
| 8 | `webapp/infra/webapp.bicep` | 30 min | Cada recurso e cada papel de acesso, e por que não há segredo |
| 9 | [09 Diário de bordo](09-diario-de-bordo.md) | 60 min | Os 29 erros reais: é a parte que mais ensina |

---

## Parte 2. O hub e o kit de instalação (PowerShell e Bicep)

### 2.1 O que é nosso e o que é do toolkit

O **FinOps hub** é da Microsoft (toolkit de código aberto). Ele já sabe receber exports, converter, organizar e,
no nível 1, ingerir no Kusto. O nosso kit faz três coisas em volta dele:

1. **Instala do jeito certo**, com todas as armadilhas resolvidas (`deploy/Deploy-FinOpsMulticloud.ps1`).
2. **Estende para outras nuvens** (`deploy/multicloud-extension.bicep`, `adf/`, `functions/oci-connector/`, `aws/`, `oci/`).
3. **Opera** (retenção, versão FOCUS, backfill: `Set-FinOpsRetention.ps1`, `Repair-FocusVersion.ps1`).

Regra para explicar: *"Nós não reescrevemos o hub. Nós o instalamos com os erros já resolvidos e o estendemos
onde ele não chega."* Isso importa para governança: o cliente continua com um componente suportado pela Microsoft.

### 2.2 `deploy/Deploy-FinOpsMulticloud.ps1` (723 linhas)

Leia o cabeçalho (`.SYNOPSIS`, `.DESCRIPTION`): as 7 etapas estão listadas. Depois procure por `Write-Step 'Etapa` e
leia etapa por etapa. O padrão de todas elas é o mesmo, e é o padrão de todo script do kit:

```
Write-Step 'Etapa N de 7: nome'  'para que serve, em uma frase'
  verificar o que ja existe  ->  criar so o que falta  ->  confirmar  ->  imprimir o que foi feito
```

| Etapa | Função-chave | O que observar |
|---|---|---|
| 1 Pré-requisitos | `Ensure-BicepCli` (linhas ~196 a 229) | Resolve o erro nº 1 do diário (Bicep fora do PATH). Procura em `~/.azure/bin`, baixa se preciso, adiciona ao PATH da sessão. Você vai ver essa mesma função no instalador da interface: é o **primeiro reuso** do kit |
| 2 Hub | chamada ao `Deploy-FinOpsHub` do módulo `FinOpsToolkit` | Parâmetros `-Mode Storage/Fabric/DataExplorer`. A tag `SecurityControl=Ignore` no resource group (erro nº 2: política que desliga chave compartilhada) |
| 3 Escopos | `New-FinOpsCostExport`, `Start-FinOpsCostExport`, `Invoke-HubPipeline` | Por que exports **manuais** em 1.0r2 no modo Storage (erro nº 12: relatórios Power BI leem 1.0). `-BackfillMonths` traz o histórico |
| 4 Extensão multicloud | `New-AzResourceGroupDeployment` com `multicloud-extension.bicep` | Key Vault para credenciais da AWS e OCI, pipelines `mc_aws_*` no Data Factory do hub, Function App do conector OCI. `-SkipAws`, `-SkipOci` quando não há a nuvem |
| 5 Configuração | upload de `config/multicloud/manifest.json`, `Start-AzDataFactoryV2Trigger` | O `manifest.json` é o **gatilho** do hub: quando ele aparece em uma pasta, o hub ingere aquela pasta. Entender isso explica toda a integração multicloud |
| 6 Conector OCI | zip deploy da Function | Só porque a Oracle não entrega parquet nem permite cópia direta pelo Data Factory |
| 7 Resumo | impressão | O que só pode ser feito na interface (Fabric, dashboards) |

**Por que PowerShell e não Bash ou Python?** Porque o toolkit oficial é um módulo PowerShell (`FinOpsToolkit`). Usar
o módulo garante que o hub seja instalado e atualizado do jeito suportado. Bicep entra onde é infraestrutura
declarativa. Python entra só no conector OCI e na interface web, onde o ecossistema de dados é imbatível.

### 2.3 `deploy/multicloud-extension.bicep`

Leia os `param` (linhas 20 a 94) e depois os `resource`. Três blocos:

* **Key Vault** (`kv`) e os segredos condicionais (`if (awsEnabled)`, `if (ociEnabled)`): a única credencial da
  solução inteira que é um segredo de verdade (a chave de acesso da AWS e a chave privada da OCI) fica aqui, e o
  Data Factory a lê por identidade gerenciada. Nada em texto plano.
* **Data Factory** (`existing`): o Bicep **não cria** um Data Factory; ele acrescenta linked services, datasets e
  pipelines `mc_aws_*` no Data Factory que o hub já criou. Compare com os JSON de `adf/`: são a mesma coisa, no
  formato que o portal aceita colar.
* **Function App** do conector OCI, com identidade gerenciada e papel de escrita no storage do hub.

### 2.4 `adf/*.json` e o `manifest.json`

Abra `adf/pipeline-mc_aws_IngestFocusMonth.json`. A pipeline copia o parquet do S3 para
`ingestion/Costs/aws/<ano>/<mes>/` e, **por último**, grava o `manifest.json`. A ordem importa: o hub reage ao
manifest, então ele só pode aparecer quando os arquivos já estiverem lá. Esse é o mecanismo que faz qualquer nuvem
entrar no hub: **coloque parquet FOCUS na pasta certa e termine com um manifest**. O conector OCI (`function_app.py`,
função `_replace_folder`) faz exatamente o mesmo em Python.

### 2.5 `functions/oci-connector/function_app.py`

Uma Function com timer (`oci_focus_ingest`, 06:30 UTC). Leia `ingest_focus_costs()`: lista os Cost Reports FOCUS
da tenancy (`_months`), baixa o CSV comprimido, converte para parquet com tipos (`_to_typed_parquet`), substitui a
pasta do mês (`_replace_folder`) e grava o manifest. Cerca de 200 linhas, e é o único Python do lado do hub.

### 2.6 `aws/focus-export-cloudformation.yaml`

Um único template cria na conta pagadora: o bucket com política que permite ao serviço de exports gravar
(`ExportBucketPolicy`), o export FOCUS 1.0 diário com sobrescrita (`FocusExport`, tipo `AWS::BCMDataExports::Export`),
opcionalmente o export de recomendações (`RecommendationsExport`), e um usuário IAM só de leitura (`ReaderUser`,
`ReaderPolicy`) cuja chave vai para o Key Vault. Repare em `overwrite` no export: sem ele, o mesmo mês entra duas vezes.

### 2.7 `deploy/Set-FinOpsRetention.ps1` e `deploy/Repair-FocusVersion.ps1`

* `Set-FinOpsRetention.ps1`: lê e altera o bloco `retention` do `config/settings.json` do hub (`Get-Valor`,
  `Set-Valor`). A lição embutida: `ingestion.months` **não apaga** blobs; quem apaga é a regra de ciclo de vida da
  storage (`-ApplyStorageLifecycle`). Detalhe na [operação do hub](03-operacao-do-hub.md#63-o-aviso-importante-sobre-ingestionmonths).
* `Repair-FocusVersion.ps1`: existe por causa do erro nº 12 do diário. Leia o `.DESCRIPTION`: é a explicação mais
  clara do kit sobre versões do FOCUS (1.0, 1.0r2, 1.2-preview) e onde a conversão acontece (só no Kusto).

---

## Parte 3. A interface web, arquivo por arquivo

### 3.1 O fluxo de uma requisição (decore este)

```
navegador                 static/js/app.js         api/main.py            api/data_source.py       api/analytics.py
---------                 ----------------         -----------            ------------------       ----------------
clica em "Por nuvem"  ->  buscar('/api/nuvens') -> nuvens_endpoint()  ->  _fonte.carregar()    ->  aplicar_filtros()
                          com meses=6&nuvens=..    _dados(...)            (cache 30 min ou      ->  agrupar(), serie_mensal()
                                                                          le parquet+normalizar)     evolucao_por()
desenha com ECharts   <-  JSON                 <-  return {...}       <-  DataFrame            <-  listas de dicts
```

Se você consegue narrar esse fluxo sem olhar, você entende a interface. Tudo o mais é variação dele.

### 3.2 `api/data_source.py`: a camada de dados

Leia nesta ordem:

1. **`EQUIVALENCIAS`** (perto do topo): o dicionário que faz FOCUS 1.0, 1.0r2 e 1.2 virarem uma só coisa
   (`x_SkuMeterName` e `SkuMeterName` viram `SkuMeter`, etc.). É pequeno e é o coração da compatibilidade.
2. **`normalizar(df)`**: leia com o diagrama da [referência técnica, 11.6](05-referencia-tecnica-interface.md#116-o-que-o-focus-e-o-hub-fazem-com-o-dado-antes-de-chegar-aqui)
   ao lado. Observe a ordem: renomear colunas, converter números, derivar `Data` e `Mes`, decidir a **Nuvem**
   (`x_SourceProvider` se existir, senão `ProviderName`, mapeado por `NUVENS_CANONICAS`), preencher padrões,
   `ListCost` com fallback, tags (parse **uma vez por string distinta**, que é o truque de desempenho), ambiente.
3. **`FonteBase`**: `carregar()` com cache por tempo (`CACHE_TTL_SEGUNDOS`), uma trava (`threading.Lock`) para
   dez usuários simultâneos não dispararem dez leituras, e `ouvintes_pos_carga` (a lista de funções chamadas após
   cada carga; `main._pos_carga` reavalia alertas). A subclasse só implementa `_ler()`.
4. **`FonteStorage._ler()`**: lista `ingestion/Costs/` recursivamente com o SDK de Data Lake, filtra `*.parquet`,
   lê com pyarrow **só as colunas de `COLUNAS_DESEJADAS`**, concatena. `FonteEstatica`: recebe um DataFrame pronto
   (testes e prévia). **`criar_fonte()`**: escolhe pela variável `DATA_BACKEND`.

O que explicar: *"a interface não sabe de onde o dado veio; ela recebe um DataFrame normalizado. Trocar storage por
Fabric é trocar a classe que implementa `_ler()`."* Veja `kusto_source.py`: `FonteKusto._ler()` executa a consulta
montada por `montar_consulta()` (com `set notruncation`, porque o Kusto corta em 500 mil linhas em silêncio) e
devolve o DataFrame. Mesmo contrato.

### 3.3 `api/analytics.py`: as agregações e a comparação honesta

Funções curtas: `aplicar_filtros`, `resumo`, `serie_diaria`, `serie_mensal`, `agrupar`, `evolucao_por`,
`top_recursos`, `filtros_disponiveis`, `qualidade`. Todas recebem DataFrame e devolvem listas de dicionários prontas
para JSON.

A que merece estudo é **`comparar_meses()`**. Leia o docstring: *"o mês corrente está aberto: no dia 3 ele tem 3 dias
de custo e o anterior tem 30"*. A função descobre até que dia o mês corrente tem dado (`dias_atual`) e compara com
**os mesmos dias** do mês anterior (`Data.dt.day <= dias_atual`). Devolve `parcial=True` e `diasComparados` para o
front rotular ("MTD vs mesmos 4 dias"). Esse bug foi encontrado por teste antes de ir para produção (item 16 do
diário) e é o exemplo perfeito para explicar por que dashboards de custo mentem.

### 3.4 Os módulos de negócio (um parágrafo cada)

| Módulo | Ideia central | Função para ler primeiro |
|---|---|---|
| `governance.py` | Transforma o dicionário de tags em uma tabela **longa** (uma linha por recurso e tag) e responde: cobertura, conformidade das obrigatórias, custo por valor de tag, sem etiqueta, orçamento por tag | `tabela_longa()`, depois `analisar()` |
| `domains.py` | Detecta serviços de **IA** (modelos, tokens, agentes) e **bancos de dados** (27 engines) por padrões em nome, SKU e meter; calcula tokens a partir das unidades de consumo | `PADROES_IA`, `ENGINES`, `classificar_engine()` (a ordem dos padrões importa: item do diário sobre RDS classificado como PostgreSQL) |
| `chargeback.py` | Centros de custo com **regras** (tag, assinatura, grupo, prefixo); `alocar()` atribui cada linha ao primeiro centro cuja regra casa; o compartilhado é rateado proporcionalmente; `importar()` lê CSV ou JSON de um CMDB | `alocar()`, `analisar()` |
| `optimization.py` | Seis famílias de regras sobre **o que dá para inferir do custo** (compromissos ociosos, estabilidade sem reserva, fim de semana, 18 trocas de tecnologia em `REGRAS_TROCA`, sobras, dev caro). Percentuais são referências declaradas, com confiança | `REGRAS_TROCA`, `analisar()` |
| `forecast.py` | Regressão linear sobre a série diária **sem sazonalidade semanal** (estimada e devolvida), picos aparados a 3 desvios, faixa de 80% que alarga com o horizonte. Leia o docstring: *"não é uma rede neural; é uma regressão que o usuário consegue explicar para o CFO"* | `prever()`, `dias_ate()` |
| `alerts.py` | Sete tipos de regra em `TIPOS`, um avaliador por tipo (`_av_orcamento`, `_av_pico`...), `avaliar()` deduplica por `regraId|chave`, abre, auto-resolve e envia e-mail; `mudar_estado()` reconhece, resolve, descarta | `avaliar()` |
| `notifications.py` | ACS (identidade gerenciada) ou SMTP; modelo HTML do e-mail | `enviar()` |
| `state_store.py` | Uma interface (`StateStore`) e duas implementações: JSON local e Table Storage (uma tabela por coleção, sem chave compartilhada) | `AzureTableStore.salvar()` |
| `insights.py` | Achados automáticos com severidade e ação: variação, serviços que cresceram, concentração, anomalias, compromissos, economia, tags, não produção, multicloud | `gerar()` |
| `export_report.py` | PDF (reportlab + matplotlib **orientado a objeto**, sem `pyplot`, por thread safety) e Excel (openpyxl, até 19 abas); `narrativa()` escreve a leitura executiva | `gerar_pdf()` |
| `sobre.py` | Identidade da solução: autor, base, versão. Usada em `/api/sobre`, rodapé, diálogo Sobre, PDF, Excel, e-mail | constantes |

### 3.5 `api/main.py`: a API

Estrutura, de cima para baixo: imports; `app = FastAPI(...)`; `store = criar_store()`; `configurar_fonte()` (injeta
a fonte e registra `_pos_carga` como ouvinte); `configurar_fonte_padrao()`; `_carga()` e `_dados()` (todo endpoint
de leitura passa por aqui: pega a carga em cache e aplica os filtros comuns); os `*_endpoint`; `_crud()` (gera GET,
POST, DELETE para `centros-custo`, `orcamentos`, `regras-alerta` a partir de uma só função); alertas; exportação;
`_agendador()` (thread que reavalia alertas às `ALERT_HOUR`); e, **no fim**, `configurar_fonte_padrao()` e
`iniciar_agendador()`.

Por que no fim? Porque o corpo do módulo executa de cima para baixo na importação, e essas chamadas usam funções
definidas ao longo do arquivo. Chamá-las no meio deu `NameError` e derrubou o container (item 28 do diário). O
teste `test_import.py` existe para isso nunca mais passar.

### 3.6 O front: `static/`

* `index.html`: esqueleto. Cabeçalho com os filtros (período, nuvem, assinatura, categoria), menu lateral com as 14
  páginas em 4 grupos, `<main id="conteudo">`, diálogo Sobre, rodapé com créditos. Sem framework, sem build.
* `js/app.js` (o núcleo, ~400 linhas): `Estado` (filtros, moeda, tema), `CORES_NUVEM` (Azure azul, AWS laranja,
  Google verde, OCI vermelho: **fixas**, para o olho aprender), `buscar()` (o **único** lugar que chama a API, com
  filtros e tratamento de erro), `enviar()` (POST/PATCH/DELETE), formatadores (`moeda`, `pct`, `numCurto`),
  gráficos sobre o ECharts (`grafLinha`, `grafBarraH`, `grafRosca`, `grafEmpilhado`, `grafMedidor`, todos passando
  por `desenhar()`, que cuida de criar, redimensionar e destruir instâncias), componentes de HTML (`cardKpi`,
  `tabela`, `abas`, `abrirModal`), `baixarExport()` (fetch, blob, link temporário: item 15 do diário) e o roteador
  por `hash`.
* `js/pages.js` e `js/pages2.js`: uma função por página, registrada em `Paginas`. Cada uma faz `buscar()`, monta o
  HTML com os componentes e chama os gráficos. Leia `visaoGeral` (a mais simples) e `alertas` (a mais rica: estado,
  ações, formulário).
* `css/styles.css`: variáveis em `:root` e `[data-tema="escuro"]`; tudo o mais usa as variáveis. Para mudar a cor
  de marca de um cliente, muda-se uma linha.

### 3.7 `infra/webapp.bicep`

Leia como uma lista de compras, e para cada item pergunte "quem precisa disso e com que permissão":

| Recurso | Para quê | Permissão dada à identidade da app |
|---|---|---|
| Log Analytics + Application Insights | Logs e telemetria | (a app escreve pela connection string) |
| Storage de estado (`finopsweb<hash>`, `allowSharedKeyAccess: false`) | Centros, regras, alertas | `Storage Table Data Contributor` |
| Communication Services + domínio gerenciado (se `enableEmail`) | E-mail de alerta sem DNS | `Contributor` restrito ao recurso |
| App Service (plano + site) **ou** Container Apps (ambiente + app) + Container Registry | Hospedar | `AcrPull` no registry (Container Apps) |
| Módulo `storage-role.bicep` | Ler o parquet do hub, mesmo em outro resource group | `Storage Blob Data Reader` na storage do hub |

Observe três detalhes que viraram itens do diário: os nomes dos role assignments derivam do **nome da app**, não do
`principalId` (item 23, `BCP120`); recursos condicionais usam `!` (`site!.identity.principalId`); a URL do storage
usa `environment().suffixes.storage` para funcionar em nuvens soberanas.

### 3.8 `Deploy-FinOpsWebApp.ps1`

Mesmo padrão do instalador do hub (7 etapas, `Write-Etapa`, verificar, criar, confirmar). O que ele tem de especial
é tudo que foi aprendido em campo, e cada bloco tem um comentário dizendo qual item do diário o motivou:

* Etapa 1: `Ensure-BicepCli`, `Ensure-ResourceProviders`, pasta de extensões **isolada** da Azure CLI
  (`AZURE_EXTENSION_DIR`), UTF-8, confirmação de login da CLI.
* Etapa 3: compila o Bicep antes (`bicep build`), **valida** com `Test-AzResourceGroupDeployment` (mostra a árvore
  de erros que o deploy esconde), `Test-Alternativas` (quando é cota, testa SKUs, regiões e Container Apps sozinho).
* Etapa 5: `test_import.py` antes de publicar; zip com `/`; Container Apps: `az acr build --no-wait` com o id lido
  do aviso e acompanhamento por status.
* Etapa 6: chama `Set-FinOpsWebAuth.ps1`.
* Etapa 7: valida `/api/health` (e `/api/status` quando não há login).

---

## Parte 4. Os scripts de operação

| Script | Uma frase | Detalhe |
|---|---|---|
| `Set-FinOpsWebAuth.ps1` | Liga ou desliga o login gravando a configuração completa na API do Azure e conferindo | [Ligar, desligar e custos](12-ligar-desligar-custos.md#login-com-entra-id-set-finopswebauthps1) |
| `Set-FinOpsPower.ps1` | `Stop`, `Start`, `Status`; Light para, Deep apaga; `-PauseHub` pausa os gatilhos | [Ligar, desligar e custos](12-ligar-desligar-custos.md) |
| `Diagnose-FinOpsWebApp.ps1` | Quando a URL não abre: rede, revisões, réplicas, porta, imagem, auth, HTTP, logs, veredito | [Interface web, 10.14](04-interface-web.md#1014-operação) |
| `Set-FinOpsRetention.ps1` | Quanto tempo de custo guardar e enxergar | [Operação do hub, 6.4](03-operacao-do-hub.md#64-mudando-a-retenção-o-script) |
| `Repair-FocusVersion.ps1` | Alinha a versão FOCUS dos exports com os relatórios Power BI | [Instalação do hub](02-instalacao-do-hub.md) |
| `api/test_local.py` | A lógica está certa? (60+ checagens sobre dado sintético) | roda em segundos, sem Azure |
| `api/test_import.py` | O servidor inicia? (importa `main.py` como o uvicorn faz) | roda em qualquer máquina com pandas e numpy |
| `build_preview.py` | Gera a prévia em arquivo único com as mesmas funções da produção | `FinOps-Preview.html` |

---

## Parte 5. As decisões de projeto e o porquê de cada uma

Quando alguém perguntar "por que assim?", estas são as respostas curtas. Cada uma tem uma alternativa que foi
considerada e descartada.

| Decisão | Por quê | Alternativa descartada |
|---|---|---|
| Construir **sobre** o FinOps hub, não do zero | Componente suportado pela Microsoft, código aberto, já converte para FOCUS e ingere no Fabric | Pipeline própria de custo: reinventar o que o toolkit já faz, sem suporte |
| **FOCUS** como esquema único | Padrão aberto da FinOps Foundation; as quatro nuvens exportam nele | Esquema próprio: cada nuvem exigiria um conversor |
| Duas camadas de consumo (Power BI **e** interface) | Perfis diferentes: analista quer Power BI; gestor quer abrir uma URL; ambos leem o mesmo dado | Só Power BI (licença por usuário, sem alertas nem chargeback) ou só interface (perde o ecossistema BI) |
| Interface lê o **parquet**, não a API do Cost Management | Mais rápido, sem cota, sem dependência; o hub já normalizou | API direta: cota, latência, uma nuvem só |
| Fonte de dados **plugável** (`FonteBase`) | Migrar para Fabric quando o volume crescer, sem mexer no front | Acoplar ao storage: reescrever quando escalar |
| Python + FastAPI + pandas | Ecossistema de dados maduro; documentação da API grátis | .NET (menos bibliotecas de dados), Node (pandas não tem equivalente) |
| Front **sem framework**, ECharts por CDN | Zero build; um cliente edita com bloco de notas; gráficos interativos prontos | React/Angular: etapa de build, dependências, curva de aprendizado para quem replica |
| **App Service** como padrão, Container Apps como alternativa | Menos peças (zip, sem registry, Easy Auth nativo); Container Apps tem cota própria quando o App Service não tem | AKS: caro e desnecessário para um serviço só |
| **Nenhum segredo** em lugar nenhum | Identidade gerenciada + RBAC em tudo (storage, tabelas, ACS, registry, Kusto); login sem client secret (ID token) | Connection strings e chaves em app settings: rotação, vazamento, auditoria |
| Comparação **MTD vs mesmos N dias** | Comparar mês parcial com mês cheio mente | Comparação bruta: variação de -90% no dia 3 |
| Previsão por **regressão explicável** | O usuário precisa defender o número para o CFO | Modelo de série temporal complexo: caixa-preta, mais dependências |
| Alertas com **dedupe e auto-resolução** | Sem enxurrada de e-mails; a condição que sumiu fecha o alerta sozinha | Alerta a cada avaliação: ruído, ninguém lê |
| Exportação **no servidor** (reportlab, openpyxl) | Sem navegador headless, sem Office; funciona na prévia offline | Impressão do navegador: sem tabelas completas nem Excel |
| Instaladores **idempotentes** com validação antes de criar | Rodar de novo corrige; erro aparece antes de gastar tempo | Scripts "fire and forget": meio deploy feito, meio quebrado |
| Testar **o caminho que a produção usa** (`test_import.py`) | Uma classe inteira de erro (módulo não carrega) só aparecia no container | Só testes de lógica |

---

## Parte 6. Roteiros para explicar em 2, 10 e 30 minutos

### 2 minutos (elevador, executivo)

> "Toda nuvem exporta o custo em um formato padrão chamado FOCUS. Nós usamos o FinOps hub, que é código aberto da
> Microsoft, para juntar Azure, AWS, Google e Oracle em uma tabela só. Em cima dela, o cliente escolhe: os relatórios
> Power BI prontos, ou uma interface web que mostra consumo, governança por tag, chargeback por área, onde economizar,
> previsão a 30, 60 e 90 dias, e alertas por e-mail. Custa uns 30 dólares por mês ligado, 3 desligado, e instala com
> dois comandos. Não tem senha em lugar nenhum: é tudo identidade gerenciada."

### 10 minutos (gerente técnico)

1. O problema: custo espalhado em quatro consoles, quatro formatos, quatro fatos. (1 min)
2. FOCUS como contrato e o hub como motor: o que o toolkit já resolve. Mostre o desenho das cinco camadas. (2 min)
3. As duas camadas de consumo e quando usar cada uma. Mostre a prévia `FinOps-Preview.html`: Visão geral, Por nuvem,
   Chargeback, Alertas. (3 min)
4. Como instala: os dois comandos; o que o instalador valida antes de criar; ligar e desligar. (2 min)
5. Segurança e custo: identidade gerenciada em tudo, login Entra ID, tabela de custos. (1 min)
6. O que vem de graça com o kit: 29 erros reais documentados com a solução automatizada. (1 min)

### 30 minutos (time técnico, com código aberto na tela)

1. Cinco camadas (5 min): o desenho e as duas ideias (FOCUS é o contrato; cada camada é substituível).
2. Hub (7 min): `Deploy-FinOpsMulticloud.ps1` etapa 3 (exports e versão FOCUS), o `manifest.json` como gatilho,
   `multicloud-extension.bicep` (Key Vault, pipelines no Data Factory existente).
3. Interface, o fluxo de uma requisição (8 min): `app.js buscar()` → `main.py _dados()` → `data_source.normalizar()`
   → `analytics.comparar_meses()`. Mostre o parquet sendo lido só nas colunas necessárias e o cache.
4. Infra e segurança (5 min): `webapp.bicep`, tabela recurso × permissão; `Set-FinOpsWebAuth.ps1` gravando na API.
5. Como testamos e o que aprendemos (5 min): `test_local.py`, `test_import.py`, `build_preview.py`; três itens do
   diário à escolha (23 BCP120, 24 cota, 28 NameError). Termine com "o kit registra o que deu errado, e por quê".

---

## Parte 7. Perguntas que vão te fazer

| Pergunta | Resposta curta | Onde está o detalhe |
|---|---|---|
| "Isso substitui o Cost Management / o Power BI?" | Não. Usa o Cost Management como fonte e o Power BI como uma das camadas de consumo. A interface web é a outra | [Arquitetura, seção 3](01-arquitetura-e-escolhas.md#3-escolha-a-camada-de-consumo) |
| "Como entra o Google Cloud?" | Mesmo princípio da AWS: export FOCUS para um bucket, conector copia para `ingestion/Costs/gcp/` e grava o manifest. A interface já reconhece `Google Cloud` e o pinta de verde | [Multicloud](07-multicloud-aws-oci.md) |
| "O dado é em tempo real?" | Não: diário. O Cost Management exporta uma vez por dia; a interface guarda em cache 30 minutos. Custo em nuvem é um dado diário por natureza | [Operação do hub, seção 7](03-operacao-do-hub.md#7-a-rotina-depois-de-instalado-o-que-roda-sozinho-e-o-que-é-manual) |
| "Quanto aguenta?" | Parquet em storage até alguns milhões de linhas por mês; acima disso, Fabric (nível 1) com três variáveis de ambiente | [Referência técnica, 11.12](05-referencia-tecnica-interface.md#1112-desempenho-e-dimensionamento) |
| "Onde ficam as senhas?" | Não há. Identidade gerenciada para storage, tabelas, e-mail, registry e Kusto; login sem client secret. A única credencial de verdade (AWS/OCI) fica no Key Vault | [Referência técnica, 11.10](05-referencia-tecnica-interface.md#1110-segurança-e-identidades) |
| "Por que Python e não .NET?" | pandas e pyarrow para ler parquet e agregar; FastAPI documenta a API sozinho. O conector OCI usa o SDK oficial da Oracle, que é Python | Parte 5 |
| "A previsão é confiável?" | É uma regressão com sazonalidade semanal e faixa de 80%, declarada como tal. Serve para se programar, não para fechar orçamento. Confiabilidade baixa quando a série é curta ou irregular, e a interface diz isso | [Interface web, 10.10](04-interface-web.md#1010-previsão-como-funciona) |
| "Como cobro as áreas?" | Centros de custo com regras (tag, assinatura, grupo, prefixo), importáveis de um CMDB por CSV ou JSON; o compartilhado é rateado proporcionalmente | [Interface web, 10.9](04-interface-web.md#109-chargeback-como-funciona) |
| "Quanto custa parado?" | Cerca de US$ 8 (Light) ou US$ 3 (Deep, só o hub) por mês | [Ligar, desligar e custos](12-ligar-desligar-custos.md) |
| "E se a assinatura não tiver cota de App Service?" | Container Apps, que tem cota própria; o instalador testa as alternativas sozinho e imprime o comando | [Diário, item 24](09-diario-de-bordo.md) |
| "Dá para restringir quem entra?" | Sim: Entra ID > Enterprise applications > `<app>-auth` > Assignment required = Yes, e a lista de usuários ou grupos | [Ligar, desligar e custos](12-ligar-desligar-custos.md#login-com-entra-id-set-finopswebauthps1) |
| "Por que o mês atual parece menor?" | Porque está incompleto. A interface compara MTD com os mesmos dias do mês anterior e rotula | Parte 3.3 |

---

## Parte 8. Exercícios para aprender mexendo

Cada exercício leva de 15 a 60 minutos e termina com um teste que prova que funcionou. Faça na ordem.

1. **Rode os testes e a prévia.** `python api/test_local.py`, `python api/test_import.py`, `python build_preview.py`.
   Abra `FinOps-Preview.html`. Objetivo: ver o ciclo completo sem Azure.
2. **Mude uma cor de nuvem.** Em `app.js` (`CORES_NUVEM`) e `export_report.py`, troque o verde do Google. Regere a
   prévia e exporte um PDF. Objetivo: entender que front e PDF compartilham a tabela.
3. **Acrescente uma coluna à API.** Em `analytics.resumo()`, devolva também `mediaDiaria`. Mostre em `visaoGeral`
   (`pages.js`) como um `cardKpi`. Rode `test_import.py`. Objetivo: o contrato da API cresce por acréscimo.
4. **Crie uma regra de otimização.** Em `optimization.REGRAS_TROCA`, adicione um padrão (por exemplo, `Standard_D2_v3`
   → `Standard_D2as_v5`, 15 a 25%). Veja aparecer em Otimização. Objetivo: as regras são dados, não código.
5. **Crie um tipo de alerta.** Em `alerts.py`, um avaliador `_av_regiao_nova` (região que não aparecia nos últimos 30
   dias) e registre em `TIPOS` e `AVALIADORES`. Teste com `POST /api/alertas/avaliar`. Objetivo: o padrão avaliador
   por tipo.
6. **Simule o Fabric.** Leia `kusto_source.montar_consulta()` e escreva a KQL que ela gera para 6 meses. Rode no
   Eventhouse, se tiver. Objetivo: ver que a fonte só muda o `_ler()`.
7. **Quebre e conserte.** Mova `configurar_fonte_padrao()` para o meio de `main.py` e rode `test_import.py`. Veja o
   `NameError` com a linha. Desfaça. Objetivo: sentir o valor de testar o caminho da produção.
8. **Leia um erro do diário e reproduza mentalmente.** Escolha o item 24 (cota). Sem olhar a solução, escreva qual
   comando você usaria para descobrir a causa. Compare. Objetivo: método de diagnóstico.
9. **Instale em outra assinatura.** Do zero, com o README. Anote cada dúvida que o guia não respondeu e melhore o
   guia. Objetivo: o kit é replicável quando outra pessoa consegue.
10. **Apresente em 10 minutos** para alguém do time usando o roteiro da Parte 6. Objetivo: se você consegue explicar,
    você entendeu.
