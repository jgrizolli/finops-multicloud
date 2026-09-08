# FinOps Multicloud Kit (Azure + AWS + Google Cloud + OCI) sobre o FinOps toolkit

[![Licença: MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-0078D4.svg)](LICENSE)
[![FOCUS](https://img.shields.io/badge/FOCUS-1.0r2-0078D4.svg)](docs/10-glossario-e-focus.md)
[![Base: FinOps toolkit](https://img.shields.io/badge/base-Microsoft%20FinOps%20toolkit-0078D4.svg)](https://github.com/microsoft/finops-toolkit)
[![PowerShell 7](https://img.shields.io/badge/PowerShell-7-0078D4.svg)](docs/11-comandos.md)
[![Documentação](https://img.shields.io/badge/documenta%C3%A7%C3%A3o-13%20guias-0078D4.svg)](docs/)

> Construído por **Wanderlei Grizolli Junior**, Sr. Solution Engineer. Baseado no
> [Microsoft FinOps toolkit](https://github.com/microsoft/finops-toolkit), a solução de código aberto da Microsoft
> para engenharia de custos em nuvem.

Uma única fonte de verdade de custo em **FOCUS** para Azure, AWS, Google Cloud e Oracle Cloud, construída sobre o
**FinOps hubs** (Microsoft FinOps toolkit), com duas camadas de consumo à sua escolha: os **relatórios Power BI do
toolkit** e uma **interface web própria** (14 páginas: análise, IA, bancos de dados, governança, showback e
chargeback, otimização, previsão, alertas, exportação).

```
Fontes FOCUS                 FinOps hubs (Azure)                          Consumo (escolha uma ou as duas)
--------------------         ----------------------------------------     --------------------------------------
Azure Cost Mgmt export  -->  msexports -> Data Factory -> ingestion  -->  Relatórios Power BI do toolkit
AWS Data Exports (S3)   -->  pipelines mc_aws_* -> ingestion/Costs/aws     Interface web própria (App Service ou
OCI FOCUS reports       -->  Function OCI -> ingestion/Costs/oci             Container Apps), lendo o parquet do
Google Billing Export   -->  (mesmo princípio, export para bucket)          hub ou o Eventhouse do Fabric
                             nível 1: Eventhouse (Fabric) ou Data Explorer
```

Toda a documentação funciona **sem acesso à internet**: comandos, valores e explicações estão nos arquivos deste
pacote. Ela foi escrita durante uma implantação real e registra cada parede encontrada e como foi resolvida.

---

## A interface

Interface própria, em Python, FastAPI e ECharts. Tema escuro por padrão, paleta do azul Microsoft. Lê o parquet em
FOCUS direto do hub, com identidade gerenciada, sem chave nem connection string.

**Visão geral**, o custo consolidado de todas as nuvens em formato FOCUS: os quatro indicadores do topo, a evolução
mensal de custo efetivo contra faturado, a distribuição por categoria, o custo diário e os maiores serviços do
período. Os filtros do topo (período, nuvem, categoria, assinatura) valem para a página inteira, e o botão Exportar
gera PDF e Excel.

![Visão geral da interface FinOps Multicloud](docs/images/interface/visao-geral.png)

**Inteligência artificial**, uma página só para o gasto com IA, que é a pergunta que mais aparece hoje: quanto a IA
representa do total mês a mês, a evolução por modelo, e a quebra por serviço (OpenAI, Foundry, Bedrock, Vertex,
Generative AI), por modelo e por nuvem.

![Página de inteligência artificial](docs/images/interface/inteligencia-artificial.png)

**Showback e chargeback**, o custo virando conversa com as áreas: evolução por centro de custo, participação de cada
um, e a tabela do que cada área consumiu, com responsável, participação, gasto no mês, orçamento e principais
serviços. Showback mostra o custo direto para conscientizar; chargeback redistribui proporcionalmente o que não tem
dono.

![Página de showback e chargeback](docs/images/interface/showback-chargeback.png)

As outras onze páginas estão em [docs/04-interface-web.md](docs/04-interface-web.md), e a construção por dentro em
[docs/05-referencia-tecnica-interface.md](docs/05-referencia-tecnica-interface.md).

### Sobre esta interface: autoria, e por que ela é substituível

Esta interface foi **criada por mim, Wanderlei Grizolli Junior**, com o auxílio do **Microsoft Copilot Cowork**, ao
longo da mesma implantação que gerou a documentação deste repositório. E ela é, de propósito, a parte mais
descartável da solução.

**O que importa é o backend.** O valor está no hub: o dado de custo de Azure, AWS, Google Cloud e Oracle Cloud
normalizado em **FOCUS**, parquet particionado na camada `ingestion`, com retenção controlada e ingestão auditável.
Esse dado não pertence a nenhuma tela. Ele é lido por identidade gerenciada e RBAC, então qualquer coisa que fale
com o Azure Data Lake ou com o Eventhouse consegue consumir o mesmo conjunto: os relatórios Power BI do toolkit, um
Real-Time Dashboard do Fabric, um notebook, um Grafana, ou uma interface que você escreva do zero em React, Angular,
Blazor, Streamlit ou o que preferir.

**Então troque à vontade.** Refaça o visual, remova páginas, mude a paleta, traduza, adapte à identidade da sua
empresa, ou jogue esta interface fora inteira e escreva a sua. A licença é MIT justamente para isso. Nada no hub
depende do que está em `webapp/`, e apagar essa pasta não quebra a ingestão. O contrário também vale: a camada de
leitura é isolada (`api/data_source.py` para o parquet, `api/kusto_source.py` para o Eventhouse), então dá para
apontar a mesma interface para o Fabric sem tocar em uma linha do front.

**Como ela foi construída, em resumo.** Backend em Python com **FastAPI**, servindo uma API por página, e o front em
HTML, CSS e JavaScript sem framework, com **ECharts** para os gráficos. Nenhum pacote de build, nenhum `node_modules`:
o navegador recebe o que está em `static/` e pronto. `pandas` e `pyarrow` fazem a leitura e a agregação do parquet
FOCUS, `azure-identity` e `azure-storage-file-datalake` fazem o acesso sem chave, `azure-data-tables` guarda os
cadastros (centros de custo, orçamentos, alertas), `reportlab` e `openpyxl` geram o PDF e o Excel da exportação, e
`azure-communication-email` manda os alertas. A infraestrutura é **Bicep** (`webapp/infra/`), com hospedagem em App
Service ou Container Apps, e o login é Entra ID. Tudo isso está desenhado arquivo por arquivo em
[docs/06-entendendo-o-codigo.md](docs/06-entendendo-o-codigo.md).

**O papel do Copilot Cowork.** Ele acelerou a parte mecânica: gerar o esqueleto das páginas, propor a normalização
FOCUS, escrever os scripts PowerShell de instalação e remoção, montar a prévia estática, e, principalmente,
transformar cada erro real da implantação em documentação. As decisões de arquitetura, a escolha dos níveis, o que
entra e o que fica de fora, e cada teste em assinatura de verdade foram meus. Vale dizer também o que não é: nada
aqui é gerado sem revisão, e o [diário de bordo](docs/09-diario-de-bordo.md) registra os 29 erros que apareceram no
caminho, justamente porque o primeiro palpite raramente é o que funciona.

> **Quer navegar em vez de olhar?** Baixe [`webapp/FinOps-Preview.html`](webapp/FinOps-Preview.html) e abra com duplo
> clique. São as 14 páginas com dados sintéticos, exportação em PDF e Excel funcionando, sem instalar nada e sem
> precisar de internet. Para deixar essa prévia no ar como demo pública, ligue o GitHub Pages em Settings > Pages,
> escolhendo GitHub Actions em Source: o workflow `.github/workflows/pages.yml` publica sozinho.

### A outra camada de consumo: os relatórios Power BI do toolkit

Quem prefere Power BI usa os seis relatórios do FinOps toolkit sobre o mesmo hub, sem passar pela interface web.

![Visão executiva no Power BI](docs/images/dashboard-preview-visao-executiva.png)

---

## Comece aqui

| Você quer | Caminho |
|---|---|
| **Ver a interface web sem instalar nada** | Abra `webapp/FinOps-Preview.html` com duplo clique (dados sintéticos, exportação PDF e Excel funcionam) |
| **Instalar o hub** (motor de tudo) | [Escolha o nível](docs/01-arquitetura-e-escolhas.md#2-escolha-o-nível-antes-de-instalar) e [a camada de consumo](docs/01-arquitetura-e-escolhas.md#3-escolha-a-camada-de-consumo), depois [instale por script](docs/02-instalacao-do-hub.md#5-deploy-por-script-caminho-recomendado) (Passo 1 ao 8) |
| **Usar os relatórios Power BI** | [Passo 7 da instalação](docs/02-instalacao-do-hub.md#passo-7-dashboards) e [retenção e histórico](docs/03-operacao-do-hub.md#6-retenção-e-histórico-quanto-tempo-de-custo-você-guarda-e-enxerga) |
| **Instalar a interface web** | [Instalação da interface](docs/04-interface-web.md#106-instalação) (um comando) |
| **Desligar, apagar ou reinstalar do zero** | [Desligar, apagar e reinstalar](docs/12-ligar-desligar-custos.md) (as três ações e o ciclo completo) |
| **Algo deu errado** | [Erros comuns](docs/08-erros-regras-limites.md#13-erros-comuns-e-como-resolver) (sintoma, causa, solução); se não estiver lá, o [diário de bordo](docs/09-diario-de-bordo.md#16-diário-de-bordo-os-erros-reais-de-uma-implantação-e-o-raciocínio-por-trás-de-cada-um) |
| **Entender o código para explicar a alguém** | [Entendendo o código](docs/06-entendendo-o-codigo.md) e a [referência técnica](docs/05-referencia-tecnica-interface.md#11-como-a-interface-web-é-construída-referência-técnica) |
| **Levar o aprendizado para o próximo projeto** | [Lições aprendidas](docs/13-licoes-aprendidas.md) |

Instalação mínima, em três comandos (PowerShell 7, na pasta do kit):

```powershell
# 1. hub (Azure, nivel 0: so storage). Leva 15 a 25 min.
.\deploy\Deploy-FinOpsMulticloud.ps1 -ParametersFile .\deploy\parameters.json

# 2. interface web (opcional). Leva 10 a 15 min. Use -HostingModel ContainerApps se a assinatura nao tiver cota de App Service.
.\webapp\Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup rg-finops-hub -EnableAuth -EnableEmail -AlertEmailTo voce@empresa.com

# 3. no fim do dia (desligar). Para apagar tudo e recomecar: .\deploy\Remove-FinOpsEnvironment.ps1 -Scope All
.\webapp\Set-FinOpsPower.ps1 -Action Stop -ResourceGroup rg-finops-hub
```

---

## Os scripts: qual, para que serve, em que ordem

Tudo o que o kit faz é feito por scripts PowerShell, pensados para serem executados por outras pessoas, em outras
assinaturas, sem ajuda. Esta é a ordem de um ciclo completo (instalar, usar, desligar, apagar, reinstalar):

| # | Script | Para que serve | Quando rodar | Tempo |
|---|---|---|---|---|
| 1 | `deploy/Deploy-FinOpsMulticloud.ps1` | **Instala o hub** (motor): storage, Data Factory, exports do Cost Management em FOCUS, retenção, backfill do histórico; opcionalmente Fabric, AWS e OCI | Primeiro, uma vez por ambiente. Rodar de novo atualiza sem duplicar | 15 a 25 min |
| 2 | `deploy/Repair-FocusVersion.ps1` | Alinha a versão FOCUS dos exports (1.0r2) com os relatórios Power BI do modo Storage | Só se os relatórios `.pbit` reclamarem de coluna (`SkuMeterName`); o instalador já cria os exports certos | 5 min |
| 3 | `deploy/Set-FinOpsRetention.ps1` | Lê e altera **quanto tempo de custo** o hub guarda e o relatório enxerga (`-Show` para ver) | Quando quiser mais ou menos histórico | 2 min |
| 4 | `webapp/Deploy-FinOpsWebApp.ps1` | **Instala a interface web** (opção B): infraestrutura, código, login, validação. `-HostingModel ContainerApps` se a assinatura não tiver cota de App Service; `-CodeOnly` para republicar só o código | Depois do hub. `-CodeOnly` a cada mudança no código | 10 a 15 min (3 a 6 com `-CodeOnly`) |
| 5 | `webapp/Set-FinOpsWebAuth.ps1` | **Liga ou desliga o login** Entra ID na interface, gravando e conferindo a configuração na API | Só se a etapa 6 do instalador avisar que o login não ficou ativo; ou para desligar (`-Disable`) | 2 min |
| 6 | `webapp/Diagnose-FinOpsWebApp.ps1` | **Diagnóstico** somente leitura quando a URL não abre: rede, revisões, réplicas, porta, imagem, login, códigos HTTP, logs, veredito | Quando algo não abre | 1 min |
| 7 | `webapp/Set-FinOpsPower.ps1` | **Desligar e ligar** (`-Action Stop`, `Start`, `Status`) para pagar só quando usar. `-Level Deep` apaga app e registry; `-PauseHub` pausa os gatilhos do hub | Fim do dia; volta do estudo | Segundos |
| 8 | `deploy/Remove-FinOpsEnvironment.ps1` | **Apaga** o ambiente (`-Scope Web`, `Hub` ou `All`) limpando exports, Key Vault em soft delete e demais restos, para a reinstalação não falhar. `-WhatIf` mostra sem apagar | Quando quiser recomeçar do zero ou parar de pagar de vez. Depois, volte ao passo 1 | 5 a 10 min |

Ferramentas de desenvolvimento (não são de instalação): `webapp/api/test_local.py` (a lógica está certa?),
`webapp/api/test_import.py` (o servidor inicia?), `webapp/build_preview.py` (gera a prévia `FinOps-Preview.html`).

As três ações que confundem, lado a lado: **desligar** (para de pagar computação, volta em segundos: script 7),
**apagar** (não paga nada, volta com os instaladores: script 8 e depois 1 e 4) e **reinstalar** (scripts 1 e 4, na
ordem). O ciclo completo, comando a comando, está em [Desligar, apagar e reinstalar](docs/12-ligar-desligar-custos.md).

---

## Mapa da documentação

| Documento | O que tem | Leia quando |
|---|---|---|
| [01 Arquitetura e escolhas](docs/01-arquitetura-e-escolhas.md) | Níveis 0 e 1 (storage, Fabric, Data Explorer); opção A (Power BI), B (interface web) ou ambas; o que cada uma exige e custa | Antes de instalar |
| [02 Instalação do hub](docs/02-instalacao-do-hub.md) | Pré-requisitos com verificação, os 8 passos do instalador, relatórios Power BI (`.pbit`, parâmetros, credenciais, `.pbix`, publicação e atualização agendada), armadilhas do portal, instalação pelo portal | Instalando |
| [03 Operação do hub](docs/03-operacao-do-hub.md) | Retenção e histórico (`settings.json`, `Set-FinOpsRetention.ps1`, ciclo de vida, backfill), a rotina diária, reexecutar, atualizar e remover | Depois de instalado |
| [04 Interface web](docs/04-interface-web.md) | As 14 páginas, arquitetura, App Service ou Container Apps, prévia, instalação, opções, o que cada etapa faz, cadastros, alertas, exportação, operação, custo, erros | Usando ou instalando a interface |
| [05 Referência técnica da interface](docs/05-referencia-tecnica-interface.md) | Linguagens e bibliotecas, módulos, como o dado FOCUS é capturado e normalizado, contrato da API, estado, segurança, troca para o Fabric, dimensionamento | Mantendo ou estendendo |
| [06 Entendendo o código](docs/06-entendendo-o-codigo.md) | Guia de estudo: ordem de leitura, cada arquivo explicado com o porquê, roteiros para explicar em 2, 10 e 30 minutos, perguntas frequentes, exercícios | Aprendendo para explicar |
| [07 Multicloud: AWS e OCI](docs/07-multicloud-aws-oci.md) | O que preparar na conta pagadora da AWS e na tenancy da Oracle | Ligando outras nuvens |
| [08 Erros, regras e limites](docs/08-erros-regras-limites.md) | Tabela de erros (sintoma, causa, solução), regras de ouro da ingestão, limites conhecidos | Algo deu errado |
| [09 Diário de bordo](docs/09-diario-de-bordo.md) | Os 29 erros reais da implantação, em ordem, com sintoma, causa, raciocínio e onde a correção está automatizada; bases de conhecimento de cotas, Azure CLI e PowerShell | Aprendendo com o que aconteceu |
| [10 Glossário e FOCUS](docs/10-glossario-e-focus.md) | Termos de FinOps e do toolkit; as colunas FOCUS que importam e as três consultas que respondem quase tudo | Novo em FinOps ou FOCUS |
| [11 Comandos](docs/11-comandos.md) | Todos os comandos do dia a dia em um lugar | Operando |
| [12 Desligar, apagar e reinstalar](docs/12-ligar-desligar-custos.md) | As três ações lado a lado, o que custa parado, `Set-FinOpsPower.ps1`, `Remove-FinOpsEnvironment.ps1`, o ciclo completo de teste do zero, login com `Set-FinOpsWebAuth.ps1` | Economizando ou recomeçando |
| [13 Lições aprendidas](docs/13-licoes-aprendidas.md) | O aprendizado destes dias organizado por tema, com a regra que fica e o trecho reutilizável; checklist para o próximo projeto | Começando outro projeto |
| `docs/anexos/` | Documentos da fase de desenho (portal multicloud, visão inicial dos scripts, runbook inicial), mantidos como referência | Consulta |

Documentos que acompanham o pacote, em [`docs/entregaveis/`](docs/entregaveis/): **Documentacao FinOps Multicloud
Azure AWS OCI.docx** (o que é, como funciona, estudo de caso, custo), **Guia passo a passo pelo portal FinOps
Multicloud.docx** (instalação pela interface, sem scripts) e **HLD v3 FinOps Multicloud Azure AWS OCI.pptx**
(arquitetura para apresentar).

**Base de conhecimento para o Copilot Notebook:** o guia [`docs/COMO-CRIAR-O-NOTEBOOK.md`](docs/COMO-CRIAR-O-NOTEBOOK.md)
traz o passo a passo para montar um notebook do Microsoft 365 Copilot com esta documentação como fonte, e as perguntas
para fazer a ele. Os arquivos Word do notebook são gerados a partir do markdown de `docs/`, por isso não são
versionados aqui.

---

## 1. O que tem neste pacote

| Pasta | Conteúdo | Quando usar |
|---|---|---|
| `deploy/` | `Deploy-FinOpsMulticloud.ps1` (instalador do hub, 7 etapas), `Remove-FinOpsEnvironment.ps1` (apaga web, hub ou tudo, pronto para reinstalar), `Repair-FocusVersion.ps1` (alinha a versão FOCUS dos exports com os relatórios Power BI), `Set-FinOpsRetention.ps1` (lê e altera a retenção), `multicloud-extension.bicep`, `parameters.example.json` | Instalar, apagar e operar o hub |
| `webapp/` | Interface web: `api/` (Python, FastAPI), `static/` (HTML, CSS, JavaScript, ECharts), `infra/` (Bicep), `Deploy-FinOpsWebApp.ps1` (instalador), `Set-FinOpsWebAuth.ps1` (login), `Set-FinOpsPower.ps1` (ligar e desligar), `Diagnose-FinOpsWebApp.ps1` (a URL não abre?), `build_preview.py` e `FinOps-Preview.html` (prévia), `Dockerfile` (só Container Apps) | Opção B |
| `adf/` | JSON dos linked services, datasets, pipelines e triggers do Data Factory para a AWS, mais o `manifest.json` modelo | Instalação pelo portal ou entender a extensão multicloud |
| `aws/` | `focus-export-cloudformation.yaml` e `README-aws.md` | Preparar a conta pagadora da AWS |
| `oci/` | `README-oci.md` | Preparar a tenancy da Oracle |
| `functions/oci-connector/` | Conector OCI em Python (`function_app.py`) | Publicado pelo instalador do hub (etapa 6) |
| `kql/` | Funções multicloud para o banco `Hub` e consultas do dashboard | Nível 1, no Eventhouse |
| `dashboards/` | Real-Time Dashboard (Fabric), tema e guia do Power BI, e os seis relatórios `.pbit` do modo Storage em `powerbi/templates/` | Depois do deploy |
| `docs/` | Toda a documentação, dividida por tema (mapa acima), mais `entregaveis/` (Word e PowerPoint), `anexos/` e `images/` | Sempre |
| `.github/` | Workflow de CI (análise de PowerShell, compilação do Bicep, sintaxe de Python, JSON e YAML, varredura de segredos), publicação da prévia no GitHub Pages, templates de issue e de PR, Dependabot | Contribuindo |

---

## 2. Como este repositório está organizado

```
.
├── deploy/                      instalador do hub, remoção, retenção, correção de FOCUS, Bicep
├── webapp/                      interface web própria
│   ├── api/                     FastAPI (14 páginas de API), testes locais
│   ├── static/                  HTML, CSS, JavaScript, ECharts
│   ├── infra/                   Bicep da interface e do papel de acesso ao storage
│   └── FinOps-Preview.html      prévia offline, abre com duplo clique
├── adf/                         objetos do Data Factory para a AWS (linked services, datasets, pipelines, triggers)
├── aws/                         CloudFormation do Data Export em FOCUS e preparo da conta pagadora
├── oci/                         preparo da tenancy Oracle
├── functions/oci-connector/     conector OCI em Python
├── kql/                         funções e consultas do Eventhouse
├── dashboards/                  Real-Time Dashboard do Fabric, tema e relatórios .pbit
├── docs/                        13 guias, anexos, entregáveis em Word e PowerPoint, imagens da interface
└── .github/                     CI, publicação da demo no GitHub Pages, templates de issue e PR, Dependabot
```

Documentos de repositório: [CONTRIBUTING](CONTRIBUTING.md), [SECURITY](SECURITY.md), [SUPPORT](SUPPORT.md),
[CODE_OF_CONDUCT](CODE_OF_CONDUCT.md), [CHANGELOG](CHANGELOG.md) e
[PUBLICAR-NO-GITHUB](PUBLICAR-NO-GITHUB.md) (como subir e manter este projeto no GitHub).

---

## Convenções

* Comandos em `powershell` são para a sua máquina, com PowerShell 7 e sessão logada no Azure. Comandos em `kusto`
  são para a janela de consulta do Eventhouse ou do Data Explorer. Comandos em `bash` são para a AWS CLI.
* `<assim>` é um valor que você troca. Sem os sinais.
* Termos do produto ficam em inglês quando é assim que aparecem na tela (Cost Management, Data Factory, Eventhouse).
* Os números de seção dentro de `docs/` são os do guia original (por exemplo, "seção 10.6") e servem como
  identificadores estáveis nas referências cruzadas entre os documentos.
* Nenhum segredo (chave, senha, connection string) aparece em arquivo ou variável: tudo é identidade gerenciada e RBAC.

---

## Segurança e dados

Nada neste repositório contém identificador real de assinatura, tenant, OCID, chave de AWS ou dado de cliente. Os
exemplos usam valores fictícios (`1111aaaa-2222-bbbb-3333-cccc4444dddd`, `AKIAIOSFODNN7EXAMPLE`, `voce@empresa.com`).
O `parameters.json` preenchido, o `local.settings.json` e qualquer arquivo `.pem` ficam fora do controle de versão
pelo `.gitignore`. Detalhes em [SECURITY.md](SECURITY.md).

## Contribuindo

Leia o [guia de contribuição](CONTRIBUTING.md). A regra principal: só entra o que foi testado em uma assinatura de
verdade, com o resultado registrado no Pull Request.

## Licença

[MIT](LICENSE). Este projeto se apoia no [Microsoft FinOps toolkit](https://github.com/microsoft/finops-toolkit),
também de código aberto, e não é um produto oficial da Microsoft nem tem suporte oficial.

---

*FinOps Multicloud. Construído por Wanderlei Grizolli Junior, Sr. Solution Engineer, com o auxílio do Microsoft
Copilot Cowork. Baseado no Microsoft FinOps toolkit.*
