# Interface web: referência técnica (como é construída)

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [11. Como a interface web é construída (referência técnica)](#11-como-a-interface-web-é-construída-referência-técnica)

---

## 11. Como a interface web é construída (referência técnica)

A [seção 10](04-interface-web.md#10-interface-web-própria-opção-b) ensina a **usar** a interface. Esta seção explica **como ela funciona por dentro**: as linguagens, o que
cada arquivo faz, como o dado FOCUS entra, o que acontece com ele até virar um gráfico, o contrato entre o servidor
e o navegador, como a segurança está montada e como trocar a fonte de dados do storage para o Fabric sem mexer em
uma linha do front. É o texto para quem vai **manter, estender ou auditar** a solução.

> **Créditos.** Construída por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**.
> Todo arquivo de código começa com esse cabeçalho; `api/sobre.py` centraliza a identidade da solução e a expõe em
> `GET /api/sobre`, no rodapé, no diálogo "Sobre", nos PDFs, nos Excel e nos e-mails.

### 11.1 Em uma frase

**O FinOps hub produz o dado em FOCUS; a interface lê esse dado, transforma em respostas JSON, e o navegador desenha.**
Ela não calcula custo: quem calcula é o Cost Management (Azure), o Data Export (AWS), o Billing Export (Google) ou o
Cost Report (Oracle). Ela não converte formato: quem converte para FOCUS é o hub. O que ela faz é **analisar, cruzar,
prever, alertar e apresentar**.

### 11.2 As camadas e as linguagens

```
Navegador                         Servidor (App Service Linux, Python 3.11)               Dado e estado
--------------------------        -----------------------------------------------        ------------------------------
index.html  (HTML5)               main.py        FastAPI: rotas /api/*                   FOCUS parquet no storage do hub
styles.css  (CSS, temas)          data_source.py camada de dados + normalizacao          ou funcoes Costs() no Kusto
app.js      (JavaScript puro)     kusto_source.py fonte Fabric / Data Explorer            (Eventhouse do Fabric ou ADX)
pages.js, pages2.js (14 paginas)  analytics, governance, domains, chargeback,
ECharts 5   (graficos, CDN)       optimization, forecast, insights                        Table Storage (estado)
                                  alerts.py, notifications.py, state_store.py            ACS (e-mail, opcional)
                                  export_report.py  PDF e Excel
        JSON pela rede  <------>                                       identidade gerenciada, sem segredo
```

| Camada | Linguagem e bibliotecas | Por que essa escolha |
|---|---|---|
| **API** | Python 3.11, **FastAPI** (rotas e validação), **uvicorn** (servidor ASGI) | O ecossistema de dados do Python (pandas, pyarrow) é o mais maduro para ler parquet e agregar; FastAPI gera a documentação em `/api/docs` sozinho |
| **Dados** | **pandas** e **numpy** (agregações), **pyarrow** (leitura de parquet), **azure-identity**, **azure-storage-file-datalake**, **azure-kusto-data** | pyarrow lê só as colunas necessárias; o SDK de Data Lake lista pastas com hierarquia; o cliente Kusto usa a mesma credencial |
| **Estado** | **azure-data-tables** (Table Storage) ou JSON local | Centros de custo, orçamentos e regras são poucos registros; Table Storage custa centavos e dispensa banco |
| **E-mail** | **azure-communication-email** ou SMTP padrão | ACS entrega com domínio gerenciado sem configurar DNS; SMTP fica como alternativa para quem já tem relay |
| **Exportação** | **reportlab** (PDF), **matplotlib** (gráficos em PNG para o PDF), **openpyxl** (Excel) | Geração no servidor, sem navegador headless, sem Office |
| **Front** | HTML5, CSS com variáveis (tema claro e escuro), **JavaScript sem framework**, **ECharts 5** | Zero etapa de build: abre e roda. Um cliente consegue alterar uma página com um editor de texto. ECharts entrega gráficos interativos com legendas, tooltips e exportação de imagem |
| **Infra** | **Bicep** (`infra/webapp.bicep`, `infra/storage-role.bicep`), **PowerShell 7** (`Deploy-FinOpsWebApp.ps1`), **Azure CLI** (autenticação Easy Auth e publicação zip) | Idempotente: rodar de novo corrige em vez de duplicar |
| **Container** (opcional) | `Dockerfile` com base `mcr.microsoft.com/devcontainers/python:3.11` e uvicorn; imagem construída na nuvem (ACR Tasks) | Só para o caminho Container Apps. Base do MCR, e não do Docker Hub, porque o build na nuvem sai de IPs compartilhados e o Docker Hub limita pulls anônimos |

Versões exatas em `api/requirements.txt`. Todas fixadas (`==`), exceto o cliente Kusto (faixa `>=4.5.1,<5`), para que
duas instalações em datas diferentes produzam o mesmo resultado.

### 11.3 Anatomia de uma requisição

O que acontece quando alguém abre a página **Por nuvem** com o filtro em 6 meses:

1. `app.js` lê a rota `#/nuvens`, monta a query string com os filtros ativos (`meses=6&nuvens=...`) e chama
   `fetch('/api/nuvens?meses=6')`.
2. `main.py` recebe em `nuvens_endpoint()`. Chama `_dados()`, que pede a **carga** à fonte (`_fonte.carregar()`).
3. A fonte devolve o dataframe **do cache** se ele tem menos de 30 minutos; senão relê a origem (parquet ou Kusto),
   passa por `normalizar()` e guarda.
4. `analytics.aplicar_filtros()` recorta o dataframe pelo período e pelos filtros.
5. `analytics.agrupar()`, `serie_mensal()`, `evolucao_por()` produzem listas de dicionários.
6. FastAPI serializa em JSON e responde.
7. `pages.js` recebe o JSON, preenche os KPIs e chama `graficoBarras()`, `graficoRosca()` e companhia, que usam
   `CORES_NUVEM` para pintar cada nuvem com a cor fixa.

Duas regras seguem disso e valem para todo o sistema:

* **O front nunca vê parquet, storage, Kusto ou credencial.** Só vê `/api/*` com JSON. É por isso que a origem do
  dado pode mudar sem tocar em HTML ou JavaScript.
* **Toda análise roda sobre o dataframe normalizado.** Nenhum módulo de negócio lê arquivo: recebe um dataframe e
  devolve dicionários. Isso é o que torna a bateria `test_local.py` possível sem Azure.

### 11.4 Os módulos, um a um

**Servidor (`api/`)**

| Arquivo | Responsabilidade | Funções principais | Quem chama |
|---|---|---|---|
| `main.py` | Rotas HTTP, filtros comuns, agendador de alertas, montagem do relatório, arquivos estáticos | `_dados()`, `_pos_carga()`, `_montar_relatorio()`, `_agendador()`, todos os `*_endpoint` | uvicorn |
| `sobre.py` | Identidade da solução: autor, base, versão, licença de uso | `como_dict()`, constantes `AUTOR`, `BASE`, `VERSAO` | `main`, `export_report`, `notifications` |
| `data_source.py` | Camada de dados: fontes, cache, trava, ouvintes, **normalização FOCUS** | `FonteBase.carregar()`, `FonteStorage._ler()`, `FonteEstatica`, `criar_fonte()`, `normalizar()`, `parse_tags()`, `classificar_ambiente()` | `main` (via `criar_fonte`) |
| `kusto_source.py` | Fonte para Fabric Eventhouse ou Azure Data Explorer | `FonteKusto._ler()`, `montar_consulta()` | `criar_fonte()` quando `DATA_BACKEND=kusto` |
| `analytics.py` | Agregações básicas e a comparação honesta entre meses | `aplicar_filtros()`, `resumo()`, `comparar_meses()`, `serie_diaria()`, `serie_mensal()`, `agrupar()`, `evolucao_por()`, `top_recursos()`, `filtros_disponiveis()`, `qualidade()` | quase todos |
| `governance.py` | Tags: cobertura, conformidade das obrigatórias, custo por valor, sem etiqueta, orçamento por tag | `tabela_longa()`, `chave_padrao()`, `analisar()` | `main`, `alerts`, `export_report` |
| `domains.py` | Detecção de IA (modelos, tokens, agentes) e de bancos de dados (engines) por padrões de nome e SKU | `mascara_ia()`, `analisar_ia()`, `classificar_engine()`, `analisar_bancos()` | `main`, `export_report` |
| `chargeback.py` | Centros de custo, regras de alocação, rateio do compartilhado, importação CSV/JSON | `alocar()`, `centros_automaticos()`, `analisar()`, `importar()` | `main`, `alerts` |
| `optimization.py` | Regras de economia: compromissos, fim de semana, troca de tecnologia, sobras, dev caro | `analisar()`, `REGRAS_TROCA`, `EQUIVALENCIAS` | `main`, `insights`, `export_report` |
| `forecast.py` | Previsão 30/60/90 com sazonalidade semanal e faixa de confiança | `prever()`, `prever_workloads()`, `dias_ate()` | `main`, `alerts`, `export_report` |
| `insights.py` | Achados automáticos com severidade e ação sugerida | `gerar()` | `main`, `export_report` |
| `alerts.py` | Sete tipos de regra, avaliação, deduplicação, estados, auto-resolução | `regras_padrao()`, `avaliar()`, `mudar_estado()`, `resumo()`, `TIPOS`, `ESCOPOS` | `main` (rota, pós-carga e agendador) |
| `notifications.py` | E-mail de alerta via ACS ou SMTP, com modelo HTML | `configurado()`, `enviar()`, `notificar_alerta()` | `alerts` |
| `state_store.py` | Persistência das coleções: JSON local ou Table Storage | `StateStore`, `LocalJsonStore`, `AzureTableStore`, `criar_store()` | `main`, `alerts`, `chargeback` |
| `export_report.py` | PDF (capa, narrativa, gráficos, tabelas) e Excel (até 19 abas) | `gerar_pdf()`, `gerar_excel()`, `narrativa()` | `main` |
| `demo_data.py` | Conjunto sintético, determinístico, com as quatro nuvens | `gerar()` | `test_local`, `build_preview` |
| `test_local.py` | Bateria de testes de lógica, sem Azure | executável | você |
| `test_import.py` | Importa `main.py` como o uvicorn faz (com substitutos do FastAPI se preciso) e confere fonte, ouvinte e rotas | executável | você e o instalador (etapa 5) |

**Front (`static/`)**

| Arquivo | Responsabilidade |
|---|---|
| `index.html` | Esqueleto: cabeçalho com filtros, menu lateral com as 14 páginas em 4 grupos, área de conteúdo, diálogo "Sobre", rodapé com créditos |
| `css/styles.css` | Variáveis de tema (`:root` e `[data-tema="escuro"]`), grade dos cartões, tabelas, botões, estados de alerta, folha de impressão |
| `js/app.js` | Núcleo: objeto `Estado` (filtros, moeda, tema), roteador por `hash`, `buscar()` (fetch com tratamento de erro), `CORES_NUVEM`, funções de gráfico sobre o ECharts, formatação de moeda, `baixarExport()`, status da fonte, tema |
| `js/pages.js` | Páginas do grupo Análise e Domínios: visão geral, tecnologia, nuvens, recursos, IA, bancos |
| `js/pages2.js` | Páginas de Gestão e Operação: governança, chargeback, otimização, previsão, alertas, insights, qualidade, relatório |

**Infra e operação**

| Arquivo | Responsabilidade |
|---|---|
| `infra/webapp.bicep` | App Service (ou Container Apps), storage de estado, App Insights, Log Analytics, ACS opcional, papéis, **app settings** (inclusive `DATA_BACKEND` e `KUSTO_*`) |
| `infra/storage-role.bicep` | Concede `Storage Blob Data Reader` na storage do hub, mesmo em outro resource group |
| `Deploy-FinOpsWebApp.ps1` | Instalador em 7 etapas, com `-RunLocal`, `-CodeOnly`, `-InfraOnly`, `-WhatIf` |
| `Set-FinOpsWebAuth.ps1` | Login Entra ID: app registration, configuração completa via API (`authConfigs/current` ou `authsettingsV2`), leitura de confirmação, teste da URL; `-Disable` abre a URL |
| `Set-FinOpsPower.ps1` | `Stop` (Light para; Deep apaga app, ambiente e registry), `Start`, `Status` com estimativa de custo; `-PauseHub` pausa os gatilhos do Data Factory |
| `Diagnose-FinOpsWebApp.ps1` | Diagnóstico somente leitura de "a URL não abre": DNS e TCP da máquina, revisões e réplicas, porta, imagem, Easy Auth, códigos HTTP reais, logs de sistema e console, veredito com comando |
| `build_preview.py` | Gera `FinOps-Preview.html`: roda a API de verdade sobre dados sintéticos e embute as respostas |
| `Dockerfile` | Imagem para o caminho Container Apps |

### 11.5 Como a interface captura os dados do FOCUS

**Nível 0 (storage), o padrão.** A classe `FonteStorage`:

1. Monta a URL do Data Lake a partir de `HUB_STORAGE_ACCOUNT` (ou `HUB_STORAGE_URL`). Aceita a URL com ou sem
   `/ingestion` no fim, porque é comum copiar o valor usado no Power BI.
2. Autentica com `DefaultAzureCredential`: no App Service vira a **identidade gerenciada**; na sua máquina, o
   `az login`. Não existe chave, connection string ou segredo em variável de ambiente.
3. Lista `ingestion/Costs/` **recursivamente** e fica só com `*.parquet`. A estrutura é
   `Costs/<ano>/<mês>/<escopo>/<arquivo>.parquet`, um ou mais arquivos por mês por escopo.
4. Baixa cada arquivo para a memória e lê com **pyarrow**, selecionando apenas as colunas de `COLUNAS_DESEJADAS`
   (cerca de 45 das mais de 60 do FOCUS). Isso reduz memória e tempo de forma expressiva.
5. Concatena tudo em um dataframe e entrega para `normalizar()`.

**Nível 1 (Fabric ou Data Explorer).** A classe `FonteKusto` executa, no banco `Hub`, a consulta montada por
`montar_consulta()`:

```kusto
set notruncation;
Costs()
| where ChargePeriodStart >= startofmonth(now(), -12)
| project-keep BilledCost, EffectiveCost, ListCost, ContractedCost, ..., Tags, x_SourceProvider, x_SourceName, x_IngestionTime
```

`set notruncation` importa: sem ele o Kusto corta a resposta em 500 mil linhas em silêncio. A janela vem de
`KUSTO_MONTHS` (13 por padrão) e a função de `KUSTO_FUNCTION`: `Costs()` segue sempre a versão mais nova do FOCUS que
o hub conhece; `Costs_v1_2()` fixa a versão e é a escolha conservadora.

**Cache, trava e ouvintes** (em `FonteBase`, herdados pelas duas fontes):

* O resultado fica em memória por `CACHE_TTL_SECONDS` (1800). O dado muda uma vez por dia; reler a cada clique seria
  desperdício.
* Uma trava garante que, se dez pessoas abrirem ao mesmo tempo com o cache vencido, **uma** leitura acontece e as
  outras esperam por ela.
* Depois de cada carga nova, os **ouvintes** são chamados. Hoje há um: `_pos_carga` em `main.py`, que reavalia as
  regras de alerta. É assim que um alerta abre no mesmo instante em que o dado do dia chega.

**O que a interface NÃO faz:** não chama a API do Cost Management, não lê o container `msexports`, não lê os CSV
brutos. Ela só consome o resultado do hub. Se o hub não ingeriu, a interface mostra o aviso e aponta para a [seção 7](03-operacao-do-hub.md#7-a-rotina-depois-de-instalado-o-que-roda-sozinho-e-o-que-é-manual).

### 11.6 O que o FOCUS e o hub fazem com o dado antes de chegar aqui

Para ler os gráficos com segurança, ajuda saber o caminho completo do número.

**1. A nuvem exporta.** No Azure, o Cost Management gera um export no formato **FOCUS** (`FocusCost`) para o
container `msexports` do hub. Na AWS, o Data Export FOCUS 1.0 vai para um bucket S3; no Google, o Billing Export para
BigQuery e dali para GCS; na Oracle, o Cost Report FOCUS para um bucket OCI. O hub ingere Azure nativamente; as
outras nuvens chegam pelos conectores descritos na [seção 12](07-multicloud-aws-oci.md#12-o-que-preparar-na-aws-e-na-oci) e nas pastas `aws/` e `oci/` (o Google Cloud segue o
mesmo princípio: export FOCUS para um bucket e um conector para o hub).

**2. O hub converte e organiza.** A pipeline `msexports_ExecuteETL` do Data Factory é disparada pelo `manifest.json`
de cada export, chama `msexports_ETL_ingestion`, converte CSV em **parquet**, e grava em
`ingestion/Costs/<ano>/<mês>/<escopo>/`. Cada nova entrega do mesmo mês **substitui** a anterior (por isso o
`overwrite` nos exports é obrigatório: sem ele, o mês dobra). No nível 1, uma segunda etapa ingere o parquet no
Kusto, onde as funções `Costs_v1_0()`, `Costs_v1_2()` e `Costs()` entregam **todas as versões convertidas para a
mais nova** e acrescentam colunas do hub (`x_SourceProvider`, `x_SourceName`, `x_IngestionTime`, entre outras).

**3. O que é o FOCUS.** É o esquema aberto da FinOps Foundation para dado de custo: mesmos nomes de coluna, mesmas
regras de preenchimento, em qualquer provedor. Quatro colunas de dinheiro que você precisa distinguir:

| Coluna | O que é | Quando usar |
|---|---|---|
| `BilledCost` | O que veio na fatura, com descontos negociados e **com** a compra de reservas no dia da compra | Bater com a fatura |
| `EffectiveCost` | O custo **amortizado**: a reserva é distribuída pelos dias em que foi usada | **Análise, showback, chargeback** (é o padrão da interface) |
| `ListCost` | Preço de tabela, sem nenhum desconto | Medir economia total |
| `ContractedCost` | Preço com o desconto do contrato, antes de reservas | Medir economia só dos compromissos |

**4. Versões.** O Cost Management exporta FOCUS **1.0**, **1.0r2** e **1.2-preview**. Os relatórios Power BI do
toolkit para storage leem 1.0 ([seção 16, erro 12](09-diario-de-bordo.md#12-the-column-skumetername-of-the-table-wasnt-found)). A interface web **aceita qualquer uma**, porque normaliza nomes
que mudaram: `x_SkuMeterName` e `SkuMeterName` viram `SkuMeter`; `x_ResourceGroupName` vira `ResourceGroupName`;
`x_SkuDescription`, `x_SkuMeterCategory` e `x_SkuMeterSubcategory` perdem o prefixo. Onde as duas formas existem, a
mais nova prevalece e a antiga preenche vazios.

**5. A normalização da interface (`normalizar()`).** É a etapa que faz o dado de qualquer nuvem, qualquer versão e
qualquer fonte ficar com a **mesma cara**:

| Passo | O que faz | Por que |
|---|---|---|
| Equivalências | Renomeia colunas de versões diferentes (item 4) | Um só nome no resto do código |
| Números | Converte as colunas de custo e quantidade para numérico; vazio vira 0 | Somar sem erro |
| Datas | `ChargePeriodStart` vira `Data` (dia) e `Mes` (`AAAA-MM`) | Séries diárias e mensais |
| **Nuvem** | Usa `x_SourceProvider` (existe no nível 1); se vazio, `ProviderName` (existe em todo FOCUS); mapeia `Microsoft`, `AWS`, `Google`, `Oracle` e variações para os quatro nomes canônicos | A cor fixa de cada nuvem depende deste nome |
| Padrões | Preenche vazios com valores neutros (`Não informado`, `Global`, `Outros`, `USD`) | Gráfico não quebra por dado faltante |
| `ListCost` | Se zero, copia `ContractedCost`; se ainda zero, `EffectiveCost` | O Cost Management nem sempre envia preço de lista; sem isso a economia sairia falsa |
| **Tags** | Aceita texto JSON (parquet) **ou** dicionário (Kusto); serializa em `TagsStr`; faz o parse **uma vez por string distinta**; marca `SemTag` | Governança e chargeback sem custo de reprocessar milhões de linhas |
| **Ambiente** | Classifica em Produção, Não produção ou Desconhecido pela tag `Environment` (e variações) ou por padrões no nome (`dev`, `hml`, `qa`, `prd`...) | Alimenta otimização (fim de semana, dev caro) e gráficos por ambiente |

O resultado é o **contrato de dados interno**: qualquer fonte nova (um CSV de on-premises, uma API de um provedor
menor) só precisa entregar um dataframe com as colunas FOCUS e passar por `normalizar()`. Todo o resto funciona.

**6. Comparação honesta entre meses.** Um detalhe que muda a leitura dos números: o mês corrente está **incompleto**.
Comparar setembro até o dia 4 com agosto inteiro daria uma queda de 90% que não existe. `comparar_meses()` compara
o **acumulado do mês até hoje** com os **mesmos N dias** do mês anterior, e é isso que aparece no KPI de variação, nos
insights e no alerta de crescimento.

### 11.7 O contrato da API

Todas as rotas de leitura aceitam os mesmos filtros: `meses` (inteiro, padrão 6), `nuvens`, `servicos`,
`assinaturas`, `grupos`, `categorias`, `ambientes` (listas, separadas por vírgula). A documentação interativa fica
em `/api/docs`.

| Rota | Método | Devolve |
|---|---|---|
| `/api/health` | GET | `status`, `configurado`, `versao`. **Sem login e sem dado**: é o health check |
| `/api/sobre` | GET | Autor, base, versão |
| `/api/status` | GET | `backend` (`storage` ou `kusto`), `fonte`, linhas, arquivos, meses, hora da carga, erro, estado, e-mail, resumo de alertas |
| `/api/refresh` | POST | Força releitura da fonte |
| `/api/filtros` | GET | Valores disponíveis para os filtros |
| `/api/visao-geral`, `/api/tecnologia`, `/api/nuvens`, `/api/recursos` | GET | Dados das páginas de Análise |
| `/api/ia`, `/api/bancos` | GET | Domínios: detecção, participação, tokens ou engines, previsão e otimização do domínio |
| `/api/governanca` | GET | Cobertura, conformidade, custo por tag (`?tag=`), sem etiqueta, orçamento por tag |
| `/api/chargeback` | GET | Alocação por centro, rateio, valor a cobrar, não alocado |
| `/api/otimizacao`, `/api/previsao` (`?dimensao=&horizonte=&janela=`), `/api/insights` | GET | Recomendações, previsão 30/60/90 e por workload, achados |
| `/api/centros-custo`, `/api/orcamentos`, `/api/regras-alerta` | GET, POST, DELETE `/{id}` | Cadastros (CRUD) |
| `/api/centros-custo/importar` | POST | Importa CSV ou JSON (`?formato=csv&substituir=true`) |
| `/api/configuracoes/tags-obrigatorias` | GET, POST | Lista de tags obrigatórias |
| `/api/alertas` | GET | Ocorrências (`?estado=`), resumo, tipos, escopos |
| `/api/alertas/{id}` | PATCH, DELETE | Muda estado (`reconhecido`, `resolvido`, `descartado`) com comentário; exclui |
| `/api/alertas/avaliar` | POST | Reavalia todas as regras agora (`?enviar_email=false` para não enviar) |
| `/api/alertas/testar-email` | POST | Envia um e-mail de teste |
| `/api/relatorio` | GET | Tudo que vai no PDF, em JSON (a página Relatório usa) |
| `/api/export/pdf`, `/api/export/excel` | GET | Arquivo binário com `Content-Disposition` |

**Estabilidade do contrato.** Campos podem ser **acrescentados** livremente; **renomear ou remover** exige mudar o
front e regerar a prévia. É este contrato que fica igual quando a fonte muda de storage para Fabric.

### 11.8 Como a exportação funciona

O botão **Exportar** (e os da página Relatório) chama `baixarExport()` em `app.js`, que faz `fetch` na rota de
exportação, recebe o binário como `blob`, cria um link temporário e dispara o download. Fazer por `fetch`, e não por
um link direto, permite mostrar o indicador de progresso, tratar erro (dado ainda não carregado, sessão expirada) e
funcionar também na prévia em arquivo único.

No servidor, `_montar_relatorio()` reúne resumo, séries, agrupamentos, governança, chargeback, previsão, otimização,
domínios, insights e alertas abertos, e entrega a `export_report.gerar_pdf()` ou `gerar_excel()`. Os gráficos do PDF
são desenhados com a API orientada a objeto do matplotlib (`Figure`, sem `pyplot`), porque o `pyplot` guarda estado
global e não é seguro quando duas exportações rodam ao mesmo tempo; uma trava completa a proteção. O App Service
precisa de `MPLCONFIGDIR=/tmp/matplotlib` (o Bicep já define) para o matplotlib ter onde gravar o cache de fontes.

### 11.9 Estado e persistência

| Coleção | Conteúdo | Quem grava |
|---|---|---|
| `centros_custo` | Nome, responsável, e-mail, regras (tag, assinatura, grupo, prefixo), orçamento | Página Chargeback, importação |
| `orcamentos` | Orçamentos por escopo (total, nuvem, assinatura, tag) | Páginas Governança e Previsão |
| `regras_alerta` | Regras: tipo, escopo, limite, severidade, destinatários | Página Alertas (cinco padrão semeadas uma vez) |
| `alertas` | Ocorrências com estado, comentário, histórico | `alerts.avaliar()` e a página Alertas |
| `configuracoes` | Tags obrigatórias, marcadores internos | Governança e o próprio sistema |

Em produção, `STATE_STORAGE_ACCOUNT` aponta para a storage `finopsweb<hash>` e o `AzureTableStore` usa uma tabela
por coleção, com a identidade gerenciada (`Storage Table Data Contributor`) e **chave compartilhada desligada**. Sem
essa variável (modo local), `LocalJsonStore` grava um JSON por coleção em `STATE_DIR` (o instalador aponta para
`webapp/state/`).

### 11.10 Segurança e identidades

| Acesso | Como | Papel ou permissão |
|---|---|---|
| Ler o dado no storage do hub | Identidade gerenciada do App Service | `Storage Blob Data Reader` na storage do hub |
| Ler o dado no Kusto (nível 1) | Mesma identidade | Viewer do banco `Hub`: `.add database Hub viewers ('aadapp=<principalId>;<tenantId>')` |
| Gravar estado | Mesma identidade | `Storage Table Data Contributor` na storage de estado |
| Enviar e-mail | Mesma identidade | `Contributor` restrito ao recurso do Communication Services |
| Usuário entrar na interface | **Easy Auth** com Entra ID (`-EnableAuth`) | Qualquer conta do tenant; restrinja no app registration se precisar |
| Health check da plataforma | `/api/health` fica **fora** do login (`--excluded-paths`) | Nenhuma |

Não há segredo em variável de ambiente, arquivo ou código. O `az webapp auth` exige a extensão `authV2` da Azure CLI,
que o instalador adiciona sozinho.

### 11.11 Trocar a fonte para o Fabric (nível 1) sem mexer no front

**Quando faz sentido.** O parquet em storage atende bem até alguns milhões de linhas por mês. Acima disso, ou quando
já existe um Eventhouse do Fabric ou um Data Explorer no hub, o Kusto agrega em segundos o que o pandas levaria
minutos para carregar, e a memória do App Service deixa de ser o limite.

**O que muda:** três variáveis de ambiente e uma permissão. **O que não muda:** o front, o contrato da API, as
análises, os alertas, a exportação.

```powershell
# 1. Publicar (ou republicar) apontando para o Eventhouse
./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -EnableAuth `
    -DataBackend Kusto -KustoQueryUri https://<eventhouse>.z0.kusto.fabric.microsoft.com -KustoDatabase Hub

# 2. Dar permissao a identidade da aplicacao (o script imprime o comando com os valores certos).
#    Rode na janela de consulta do Eventhouse ou do Data Explorer, no banco Hub:
.add database Hub viewers ('aadapp=<principalId-da-aplicacao>;<tenantId>')

# 3. Conferir
curl https://<url>/api/status      # "backend": "kusto", "fonte": "KQL Costs() no banco Hub em https://..."
```

| Variável | Valor | Observação |
|---|---|---|
| `DATA_BACKEND` | `kusto` | `storage` volta ao parquet |
| `KUSTO_QUERY_URI` | Query URI do Eventhouse (System overview) ou do cluster ADX | Sem barra no fim |
| `KUSTO_DATABASE` | `Hub` | Nome padrão do hub |
| `KUSTO_FUNCTION` | `Costs()` ou `Costs_v1_2()` | Fixar a versão é mais previsível |
| `KUSTO_MONTHS` | `13` | Janela lida para a memória |

Para testar na sua máquina antes de publicar: `./Deploy-FinOpsWebApp.ps1 -RunLocal -DataBackend Kusto -KustoQueryUri https://...`
(usa o seu login; você precisa ser viewer do banco).

**Escala além disso.** Hoje a consulta traz linhas e o pandas agrega. O próximo degrau, quando a memória apertar, é
mover as agregações para KQL (`summarize` no servidor) dentro de `kusto_source.py`, devolvendo só os resultados. O
contrato da API não muda e o front continua igual.

### 11.12 Desempenho e dimensionamento

| Volume mensal (linhas FOCUS) | Memória aproximada | Plano recomendado | Fonte |
|---|---|---|---|
| até 300 mil | menos de 1 GB | B1 (1,75 GB) | storage |
| 300 mil a 1 milhão | 1 a 3 GB | B2 ou P0v3 | storage |
| 1 a 5 milhões | 3 a 10 GB | P1v3 ou P2v3 | storage, ou Kusto |
| acima de 5 milhões | | qualquer | **Kusto**, com agregação no servidor |

A leitura só das colunas necessárias e o parse de tags por string distinta são o que mantêm esses números baixos.
`Always On` fica ligado para o agendador de alertas e para a primeira requisição não pagar a carga.

### 11.13 Como a prévia e os testes são gerados

* **`test_local.py`** cria um conjunto sintético com `demo_data.gerar()`, passa por `normalizar()` e exercita cada
  módulo com asserções de negócio (soma bate, comparação honesta, alocação sem duplicar, previsão dentro da faixa,
  KQL montado, tags em dict). Roda em segundos, sem Azure: `python api/test_local.py`.
* **`build_preview.py`** injeta uma `FonteEstatica` em `main.py`, chama **as mesmas funções das rotas** para todas
  as combinações de página, período e nuvem, gera PDF e Excel reais para 6 e 12 meses, e grava tudo dentro de um
  único HTML com um interceptador de `fetch`. Por isso a prévia mostra exatamente o que a aplicação publicada mostra
  com aquele dado, sem servidor. Se você alterar uma rota em `main.py`, ajuste a classe `ClienteDireto` no mesmo
  arquivo e regere: `python build_preview.py`.

### 11.14 Convenções para quem vai mexer no código

* Nomes, comentários e mensagens em **português**; nomes de colunas FOCUS em inglês, como no padrão.
* Todo arquivo começa com o cabeçalho de créditos. Mantenha ao criar um módulo novo.
* Nenhum módulo de negócio lê arquivo ou rede: recebe dataframe, devolve dicionários. Facilita testar.
* Novas colunas na API: acrescente, não renomeie. Regere a prévia depois.
* Cores: `CORES_NUVEM` em `app.js` e em `export_report.py` são a mesma tabela; mude nos dois.
* Um único processo no App Service (uvicorn sem `--workers`): o agendador de alertas não pode duplicar. Concorrência
  vem do pool de threads do FastAPI para rotas síncronas.
* Sem travessões no texto gerado (PDF, e-mail, interface): vírgula, dois-pontos ou parênteses.
