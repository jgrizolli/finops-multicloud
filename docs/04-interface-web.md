# Interface web: uso, instalação, opções e operação

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [10. Interface web própria (opção B)](#10-interface-web-própria-opção-b)

---

## 10. Interface web própria (opção B)

Esta seção só interessa se você escolheu a **opção B** ou **as duas** na [seção 3](01-arquitetura-e-escolhas.md#3-escolha-a-camada-de-consumo). Se vai usar apenas os
relatórios Power BI, pode pular para a seção seguinte.

A interface web é uma aplicação que lê o **mesmo dado do hub** que o Power BI lê, e o apresenta em um site com
identidade visual própria, acessível por navegador, **sem exigir licença Power BI de ninguém**. Além de mostrar,
ela **faz**: cadastra centros de custo, calcula chargeback, avalia alertas, envia e-mail e exporta relatórios.

> **Créditos.** A interface foi construída por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o
> **Microsoft FinOps toolkit**. A atribuição aparece no cabeçalho de todo arquivo de código, no rodapé da
> interface, no diálogo "Sobre", nos relatórios exportados e nos e-mails de alerta.

### 10.1 As catorze páginas

| Grupo | Página | O que faz |
|---|---|---|
| **Análise** | Visão geral | Custo total, mês corrente, projeção, economia, evolução mensal e diária, categoria, nuvem, ambiente |
| | Por tecnologia | Serviço, categoria, tipo de recurso, região, evolução dos seis maiores |
| | Por nuvem | Azure, AWS, Google Cloud e Oracle Cloud lado a lado, categorias por nuvem, assinaturas, contas de faturamento |
| | Recursos | Os recursos que mais consomem, com grupo, região, ambiente e economia |
| **Domínios** | Inteligência artificial | Foundry, Azure OpenAI, Bedrock, Vertex AI, Generative AI: custo, participação, **tokens**, **modelos**, **agentes**, previsão e otimização do domínio |
| | Bancos de dados | Relacionais, NoSQL, cache e analíticos nas quatro nuvens: engines, ambiente, cobertura de reserva, previsão por engine, otimização e alertas do domínio |
| **Gestão** | Governança | Cobertura de tags, **conformidade das tags obrigatórias**, custo por valor de tag, **recursos sem etiqueta**, **orçamento por tag** |
| | Showback e chargeback | Custo direto por área, **rateio do compartilhado**, valor a cobrar, **cadastro de centros de custo** com regras, **importação de CMDB** |
| | Otimização | Compromissos ociosos e oportunidades, ambientes ligados 24x7, **troca de tecnologia** (18 regras), possíveis sobras, tabela de equivalências entre nuvens |
| | Previsão | 30, 60 e 90 dias com faixa de confiança, fechamento do mês, próximo mês, dias até estourar o orçamento, **por workload** |
| **Operação** | Alertas | Regras configuráveis, ocorrências com estado (**aberto, reconhecido, resolvido, descartado**), envio de **e-mail**, avaliação manual e agendada |
| | Insights | Análise automática: tendências, anomalias, concentração, compromissos, economia, governança |
| | Qualidade do dado | Meses carregados, atraso, cobertura de nome e tag, volume por nuvem |
| | Relatório e exportação | Leitura executiva em texto, gráficos, **PDF** e **Excel** |

Todas respeitam os quatro filtros do topo: **período**, **nuvem**, **categoria** e **assinatura**. O botão
**Exportar** no topo gera PDF ou Excel do que está filtrado.

### 10.2 Cores fixas por nuvem

Cada nuvem tem uma cor que **nunca muda**, em qualquer gráfico, etiqueta ou legenda. Bate o olho e sabe de quem é.

| Nuvem | Cor |
|---|---|
| Microsoft Azure | Azul `#0078D4` |
| Amazon Web Services | Laranja `#FF9900` |
| Google Cloud | Verde `#34A853` |
| Oracle Cloud | Vermelho `#C74634` |

Para mudar, edite `CORES_NUVEM` em `static/js/app.js` e `CORES_NUVEM` em `api/export_report.py` (o PDF usa a
mesma tabela).

### 10.3 Arquitetura

```
Fonte de dados (uma das duas)     Aplicacao (App Service)                          Navegador
------------------------------    ------------------------------------------      ----------------------------
Nivel 0: storage do hub           API Python (FastAPI)                       -->  Interface (HTML + ECharts)
  ingestion/Costs/*.parquet  -->  le a fonte, normaliza, agrega, analisa,         14 paginas, 4 filtros,
Nivel 1: Fabric ou Data Explorer  preve e serve JSON; gera PDF e Excel            tema claro e escuro
  banco Hub, funcao Costs()  -->        |            |
       ^                                |            +----> Azure Communication Services (e-mail, opcional)
       | identidade gerenciada          |
       | (Blob Data Reader ou viewer)   v
                                  Storage de ESTADO (Table Storage)
                                  centros de custo, orcamentos, regras, alertas
                                  identidade gerenciada, Storage Table Data Contributor
```

Decisões de projeto, e o porquê:

**A aplicação lê o resultado do hub, não uma API do Azure.** O hub já converteu e normalizou. Ler o parquet (ou o
banco Kusto) é mais rápido, não consome cota do Cost Management e não depende de mais nenhum serviço.

**A fonte é plugável.** Por padrão lê o parquet do storage (nível 0). Com três variáveis de ambiente passa a consultar
o Eventhouse do Fabric ou o Data Explorer (nível 1), **sem mudar nada no front**. A [seção 11.11](05-referencia-tecnica-interface.md#1111-trocar-a-fonte-para-o-fabric-nível-1-sem-mexer-no-front) mostra como.

**Não há segredo em lugar nenhum.** Acesso ao dado, ao estado e ao e-mail é por **identidade gerenciada**. A storage
de estado nasce com chave compartilhada **desligada**.

**O estado fica separado do dado.** A storage do hub é dado; centros de custo, orçamentos e alertas são configuração
da interface. Misturar os dois atrapalha upgrade do hub e backup.

**O dado fica em cache por 30 minutos.** Os arquivos mudam uma vez por dia. O botão de atualizar força a releitura.

**Os alertas rodam dentro da aplicação.** Um agendador interno reavalia as regras uma vez por dia no horário
configurado, e também a cada recarga do dado. Não precisa de Function, Logic App nem cron externo. Por isso o
App Service roda com **um único worker** e `Always On`.

### 10.4 App Service ou Container Apps

As duas opções funcionam com o mesmo código. O script implanta **App Service por padrão**.

| Critério | App Service | Container Apps |
|---|---|---|
| Como o código chega lá | **Zip**, direto do script | Imagem de container, **construída na nuvem** pelo script (`az acr build`) |
| Precisa de Docker na sua máquina | **Não** | **Não** (o build roda no ACR Tasks) |
| Precisa de Container Registry | **Não** | Sim, o script cria (Basic, cerca de US$ 5/mês) |
| Autenticação Entra ID | **Nativa**, o script configura | Mesmo motor (Easy Auth), o script configura |
| Agendador de alertas interno | **Funciona** (Always On) | Funciona com 1 réplica mínima (padrão do script); com `-ScaleToZero`, use um timer externo chamando `POST /api/alertas/avaliar` |
| Escala a zero | Não | Sim (`-ScaleToZero`) |
| **Cota** | Cota de App Service da assinatura (por família de SKU e total) | **Cota própria**, independente da do App Service |
| Custo aproximado | **B1: cerca de US$ 13/mês** | Consumo: 1 réplica de 0,5 vCPU e 1 GiB sempre ligada, cerca de US$ 15 a 20/mês, mais o registry |
| Passos para o cliente replicar | **Um comando** | **Um comando** (`-HostingModel ContainerApps`) |

**Escolha App Service se** o objetivo é o menor número de peças móveis. É o caso da maioria.
**Escolha Container Apps se** a assinatura **não tem cota de App Service** (erro `InternalSubscriptionIsOverQuotaForSku`
com `Total VMs: 0`, [seção 16, erro 24](09-diario-de-bordo.md#24-preflight-validation-errors-see-inner-errors-for-details-o-azure-recusou-o-plano-e-não-disse-por-quê)), se já tem esteira de containers, ou se precisa de escala agressiva.

**Como o caminho Container Apps funciona no script:** a etapa 3 cria o ambiente, o registry e o Container App com uma
imagem pública de espera (a imagem da interface ainda não existe). A etapa 5 envia `api/`, `static/` e o `Dockerfile`
para o ACR Tasks, que constrói a imagem **na nuvem** e a guarda no registry; em seguida o script aponta o Container
App para o registry (pull por identidade gerenciada, papel `AcrPull`, sem senha), troca a imagem e ajusta a porta.
Reexecuções preservam a imagem publicada, e `-CodeOnly` só reconstrói e troca a imagem.

**Sobre o `Dockerfile` na pasta:** existe **apenas** para o caminho do Container Apps. No App Service é ignorado.
Pode apagar sem quebrar nada se ficar só no App Service.

**Por que não AKS.** Nada aqui exige orquestração de vários serviços, malha de rede ou escala por nó. AKS custaria
mais, exigiria mais operação e não entregaria nenhuma funcionalidade a mais. Se um dia a solução virar um produto
com dezenas de microsserviços, aí sim.

### 10.5 Ver a interface antes de instalar qualquer coisa

| Forma | O que você precisa | O que vê | Tempo |
|---|---|---|---|
| **Prévia em arquivo único** | Só um navegador | As 14 páginas com dados de demonstração | segundos |
| **Modo local** | Python 3.11 e `az login` | A interface com **os seus dados reais** | 2 minutos |
| **Publicada** | Assinatura do Azure | No ar, com URL | 5 a 10 minutos |

**Prévia:** abra **`FinOps-Preview.html`** com duplo clique. Cadastros e ações de alerta funcionam em memória (somem
ao fechar). **Exportar PDF e Excel funciona**: são arquivos reais, gerados pelo mesmo código do servidor, embutidos
para 6 e 12 meses (outros períodos caem no de 6). A prévia é gerada rodando as mesmas funções que rodam em produção
sobre um conjunto sintético: **não é uma maquete**. Para regerar depois de personalizar: `python build_preview.py`.

**Modo local, com os seus dados:**

```powershell
cd webapp
./Deploy-FinOpsWebApp.ps1 -RunLocal -HubStorageAccount <storage-do-hub>
```

Sobe em `http://localhost:8000` com o seu login do Azure CLI. O estado fica em uma pasta `state/` local.

### 10.6 Instalação

**Pré-requisito:** o FinOps hub implantado e com dado no container `ingestion` ([seção 5](02-instalacao-do-hub.md#5-deploy-por-script-caminho-recomendado)).

```powershell
cd .\finops-multicloud-kit\webapp

# instalacao recomendada: com login do tenant e alertas por e-mail
./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-finops-hub `
  -EnableAuth -EnableEmail -AlertEmailTo finops@empresa.com
```

O script imprime a URL ao terminar. A primeira execução leva de 5 a 10 minutos.

| Opção | Efeito | Sem ela |
|---|---|---|
| `-EnableAuth` | Cria app registration e liga o Easy Auth. Só conta do tenant entra | A URL fica **pública** |
| `-EnableEmail` | Cria Azure Communication Services com domínio gerenciado | Alertas só no painel |
| `-AlertEmailTo` | Destinatários padrão dos alertas | Só regras com destinatário próprio enviam |
| `-EmailDataLocation` | Onde o ACS guarda dados (`United States`, `Europe`, `Brazil`) | `United States` |
| `-AlertHour` / `-UtcOffsetHours` | Hora local da reavaliação diária | 09:00, fuso -3 |
| `-DataBackend Kusto -KustoQueryUri <uri>` | Lê do Eventhouse do Fabric ou do Data Explorer em vez do parquet ([seção 11.11](05-referencia-tecnica-interface.md#1111-trocar-a-fonte-para-o-fabric-nível-1-sem-mexer-no-front)) | Lê o parquet do storage |
| `-KustoDatabase` / `-KustoFunction` / `-KustoMonths` | Banco, função KQL e janela da consulta | `Hub`, `Costs()`, 13 |
| `-AppServiceSku` | Plano do App Service (`F1` gratuito para testar, `B1`, `S1`, `P0v3`...) | `B1` |
| `-Location` | Região da interface. Pode ser **diferente** da do hub: a aplicação lê o storage pela rede e o custo de saída é desprezível. Útil quando a região do hub não tem cota ou capacidade | A região do resource group |
| `-ResourceGroup <novo> -HubResourceGroup <rg-do-hub> -Location <região>` | Interface em resource group **próprio** (o script cria). Útil quando o resource group do hub já tem plano App Service de outro tipo, ou quando a governança separa dado de aplicação | Mesmo resource group do hub |
| `-HostingModel ContainerApps` | Container Apps em vez de App Service; sem Docker local, o script constrói a imagem na nuvem | App Service |
| `-ScaleToZero` | Container Apps com zero réplicas quando ocioso (o agendador interno de alertas para junto) | 1 réplica mínima |

**Se a validação falhar**, o script mostra a árvore completa de erros do Azure (a causa real fica na mensagem mais
interna) e imprime uma dica com o comando corrigido para os casos conhecidos: falta de cota na região, SKU
indisponível, mistura de sistemas operacionais no resource group, política da assinatura, atribuição de papel órfã.

### 10.7 O que o script faz, etapa por etapa

| Etapa | O que acontece | Por que importa |
|---|---|---|
| 1 | Verifica módulos, Azure CLI e login; **sonda a saúde da CLI** (uma extensão quebrada derruba todo comando `az`; se for o caso, usa uma pasta de extensões isolada) e confirma que a CLI está **logada na assinatura**; garante o **Bicep CLI no PATH** e **registra os resource providers** (`Microsoft.Web`, `Storage`, `Insights`, `OperationalInsights`, e `Communication`, `App`, `ContainerRegistry` quando usados) | Falhar aqui é melhor que falhar no meio. Assinatura nova sem provider registrado dá `MissingSubscriptionRegistration` |
| 2 | Descobre a storage do hub e conta os meses de dado | Avisa se a interface vai abrir vazia |
| 3 | **Compila o Bicep** (erros aparecem com linha e coluna), **valida com o Azure** sem criar nada (`Test-AzResourceGroupDeployment`, que mostra a causa real que o deploy esconde) e implanta: App Service (ou ACA), **storage de estado**, Application Insights, Log Analytics e, se pedido, **Communication Services**; grava os app settings, inclusive a fonte de dados | Tudo declarativo, idempotente. Falhas conhecidas (cota, SKU, mistura de SO, política, `RoleAssignmentUpdateNotPermitted`, provider) vêm com a solução impressa |
| 4 | Concede `Storage Blob Data Reader` na storage do hub; com Kusto, imprime o comando `.add database ... viewers` para você rodar | **Sem isso, 403.** Não é herdado de Owner |
| 5 | Empacota (zip com separadores Linux, sem arquivos de teste, prévia ou estado local) e publica com `--clean` | Zip com API, front e `requirements.txt` na raiz, que é onde o build do App Service procura |
| 6 | Entra ID, se pedido: chama `Set-FinOpsWebAuth.ps1`, que cria o app registration, grava a configuração inteira na API do Azure, lê de volta e confere; se não confirmar, desliga em vez de bloquear a URL. `/api/health` fica **fora do login** | O health check da plataforma e a etapa 7 precisam alcançar `/api/health` sem conta. O mesmo script liga ou desliga o login depois, sem repetir o deploy |
| 7 | Testa `/api/health`; sem login habilitado, testa também `/api/status` e mostra linhas, meses e fonte | Confirma que subiu e enxerga o dado. Com login, `/api/status` só no navegador |

O Bicep também concede `Storage Table Data Contributor` na storage de estado e `Contributor` **restrito ao recurso**
do ACS, ambos para a identidade da aplicação.

### 10.8 Alertas: como funcionam

**Regras** observam o dado. **Alertas** são ocorrências que as regras abrem. A interface começa com cinco regras
padrão (pico diário, crescimento acima de 25%, mais de 30% sem tag, compromisso sem uso, serviço novo) que você
ajusta ou apaga.

| Tipo de regra | O que observa | Limiar |
|---|---|---|
| Orçamento | Realizado **ou projetado** do mês acima do valor | valor |
| Pico diário | Custo de um dia acima de N desvios da média | desvios (padrão 3) |
| Crescimento mensal | Mês até a data contra o **mesmo intervalo** do mês anterior | percentual |
| Previsão | Projeção de 30 dias acima do valor | valor |
| Sem etiqueta | Percentual do gasto sem tag | percentual |
| Compromisso ocioso | Reserva ou savings plan `Unused` | valor |
| Novo serviço | Serviço que não existia nos 30 dias anteriores | valor |

Cada regra tem **escopo** (total, nuvem, assinatura, grupo, serviço, categoria ou centro de custo), **severidade** e
**destinatários** próprios. Sem destinatário, usa o `-AlertEmailTo` da instalação.

**Ciclo de vida de um alerta:** `aberto` → `reconhecido` (alguém está tratando) → `resolvido` (com comentário do que
foi feito) ou `descartado` (falso positivo). O botão **Eliminar** apaga de vez. Alertas de condição (sem tag,
orçamento, compromisso) **fecham sozinhos** quando a condição deixa de valer.

**Deduplicação:** a mesma ocorrência não abre duas vezes. A avaliação atualiza o valor do alerta existente. O e-mail
sai uma vez, na abertura.

**Quando roda:** a cada recarga do dado (a cada 30 minutos de uso, ou no botão de atualizar), uma vez por dia no
horário configurado, e quando você clica em **Avaliar agora**. Para integrar com um agendador externo:
`POST /api/alertas/avaliar`.

**E-mail:** com `-EnableEmail`, o remetente é `DoNotReply@<dominio>.azurecomm.net`, criado automaticamente. Para
usar um relay corporativo, defina `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD` e `EMAIL_SENDER` nas
configurações da aplicação. O botão **testar** na página de alertas envia um e-mail de verificação.

### 10.9 Chargeback: como funciona

Um **centro de custo** é a área que será cobrada. Cada um tem responsável, e-mail, orçamento mensal e **regras de
alocação**:

| Tipo de regra | Bate quando |
|---|---|
| `tag` | A linha tem a tag `chave` com o `valor` (`*` aceita qualquer valor) |
| `assinatura` | A assinatura, conta ou projeto é o `valor` (sufixo `*` faz prefixo) |
| `grupo` | O resource group é o `valor` |
| `nuvem` | A nuvem é o `valor` |
| `servico` | O serviço é o `valor` |
| `conta` | A conta de faturamento é o `valor` |

Cada linha de custo vai para o **primeiro centro cuja regra bater**, na ordem do cadastro. O que não bater em
ninguém vira **Não alocado**.

**Showback** mostra o custo direto de cada área, sem redistribuir. É para conscientizar.
**Chargeback** mostra o valor a cobrar: custo direto **mais** a fatia do não alocado, distribuída na proporção do
custo direto. A opção "distribuir" pode ser desligada para manter o compartilhado com TI.

**Sem cadastro**, a página faz showback automático pela tag de centro de custo mais comum (`CostCenter`, `centro`,
`cost-center`). Útil no primeiro dia.

**Integração com CMDB:** a importação aceita JSON ou CSV em `POST /api/centros-custo/importar`. Um job agendado
(Logic App, Function, pipeline) que consulta o CMDB e envia o resultado para esse endpoint mantém o cadastro
sincronizado. Com `?substituir=true` o cadastro é recriado do zero. CSV: `nome,responsavel,email,orcamentoMensal,tipo,chave,valor`,
uma linha por regra.

### 10.10 Previsão: como funciona

Regressão linear sobre os últimos 90 dias, com três cuidados que fazem diferença:

1. O **dia corrente é descartado**, porque sempre está incompleto.
2. **Picos acima de três desvios são aparados** antes do ajuste, para que um incidente de dois dias não vire tendência.
3. A **sazonalidade semanal** é estimada e devolvida na projeção, porque fim de semana costuma custar menos.

A faixa é de 80% de confiança e alarga com o horizonte. A **confiabilidade** (alta, média, baixa) vem da variância
residual e do tamanho da série. Baixa significa "leia como ordem de grandeza".

Além do total, a página projeta **por workload** (serviço, grupo, assinatura, nuvem ou categoria), mostra o
**fechamento do mês** e o **próximo mês**, e, se houver orçamento total cadastrado, **em quantos dias estoura**.

### 10.11 Otimização: de onde vêm as recomendações

O FOCUS mostra o que foi cobrado, não a utilização. Por isso as regras aqui são sobre **o que dá para inferir do
custo**:

| Categoria | O que detecta | Economia estimada |
|---|---|---|
| Compromissos | Reserva ou savings plan `Unused`; gasto estável (variação < 35%) sem reserva | 90% a 100%; 25% a 45% |
| Agendamento | Não produção custando no fim de semana o mesmo que no dia útil | 45% a 65% |
| Troca de tecnologia | 18 padrões: VM v2/v3 → v5, Intel → AMD/Arm, Premium SSD em dev, Hot → Cool, GRS em dev, SQL provisionado → serverless, Business Critical em dev, Cosmos provisionado, App Service Pv2 → Pv3, Log Analytics por GB, GPT-4 → 4o/mini, gp2 → gp3, m5/c5 → Graviton, io1 → io2, N1 → E2/N2D, entre outros | 10% a 85%, por regra |
| Possível sobra | Grupo há 30 dias só com storage, disco ou IP, sem nenhum compute | 70% a 100% |
| Ambientes | Não produção acima de 30% do total | 20% a 40% |

Os percentuais são **referências de mercado**, declarados em cada regra. Servem para priorizar, não para fechar
orçamento. Cada recomendação traz **confiança** (alta, média, baixa). Recomendações por **utilização** (CPU, memória,
IOPS) vêm do Azure Advisor, que o hub ingere com a opção de recomendações ligada, e são a próxima evolução da página.

### 10.12 Exportação

| Formato | Conteúdo | Uso |
|---|---|---|
| **PDF** | Capa com KPIs, leitura executiva em texto, gráficos (mensal, categoria, serviços, nuvem, previsão), tabelas de recursos, recomendações, achados e alertas abertos. Paisagem, 5 a 7 páginas | Apresentar |
| **Excel** | Até 19 abas: resumo, mensal, diário, serviço, categoria, nuvem, região, assinatura, recursos, chargeback, tags, sem tag, otimização, previsão, previsão por workload, IA, bancos, insights, alertas | Trabalhar o número |

Os dois respeitam os filtros ativos e são gerados no servidor. O botão **Exportar** fica no topo de toda página; a
página **Relatório** mostra a prévia do que vai no PDF e tem os mesmos botões. O navegador também imprime qualquer
página em PDF pelo botão **Imprimir**, com folha de estilo própria para impressão.

Ao clicar, o botão mostra o indicador de progresso, baixa o arquivo e avisa o nome gerado. Se algo falhar (dado ainda
carregando, sessão expirada), a mensagem aparece na tela em vez de uma página em branco. Um Excel completo em um
conjunto grande leva de 10 a 30 segundos; o PDF, alguns segundos.

### 10.13 Opções do instalador

```powershell
# ver na sua maquina antes de publicar
./Deploy-FinOpsWebApp.ps1 -RunLocal -HubStorageAccount <storage-do-hub>

# instalacao recomendada
./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -EnableAuth -EnableEmail -AlertEmailTo finops@empresa.com

# Container Apps
./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -HostingModel ContainerApps

# lendo do Fabric (Eventhouse) em vez do storage; a interface nao muda
./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -EnableAuth `
    -DataBackend Kusto -KustoQueryUri https://<eventhouse>.z0.kusto.fabric.microsoft.com

# republicar so o codigo (o comando do dia a dia)
./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -CodeOnly

# plano maior
./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -AppServiceSku P0v3

# hub em outro resource group
./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -HubResourceGroup rg-hub-central

# simular
./Deploy-FinOpsWebApp.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -WhatIf
```

### 10.14 Operação

| Tarefa | Como |
|---|---|
| Republicar código | `-CodeOnly` |
| Ver logs | `az webapp log tail -g <rg> -n <app>` |
| Diagnóstico | `<url>/api/status` (dado, estado, e-mail, alertas), `<url>/api/docs` (API) |
| Forçar releitura | Botão `↻` ou `POST /api/refresh` |
| Reavaliar alertas | Botão **Avaliar agora** ou `POST /api/alertas/avaliar` |
| Testar e-mail | Botão **testar** na página de alertas ou `POST /api/alertas/testar-email` |
| Regerar a prévia | `python build_preview.py` |
| Testar sem Azure | `python api/test_local.py` (lógica) e `python api/test_import.py` (o servidor inicia? roda em qualquer máquina com pandas e numpy; bibliotecas ausentes viram curingas) |
| **A URL não abre** | `./Diagnose-FinOpsWebApp.ps1 -ResourceGroup <rg> -HostingModel ContainerApps` (ou `AppService`): DNS, porta, revisões, réplicas, imagem, autenticação, códigos HTTP e logs, com veredito. Não altera nada |
| **Ligar ou desligar o login** | `./Set-FinOpsWebAuth.ps1 -ResourceGroup <rg> -HostingModel ContainerApps` (`-Disable` para abrir). Detalhes em [Ligar, desligar e custos](12-ligar-desligar-custos.md#login-com-entra-id-set-finopswebauthps1) |
| **Desligar para não pagar / ligar de novo** | `./Set-FinOpsPower.ps1 -Action Stop` / `-Action Start` / `-Action Status` (`-Level Deep` apaga app e registry). Detalhes em [Desligar, apagar e reinstalar](12-ligar-desligar-custos.md) |
| **Apagar a interface (ou tudo) e reinstalar** | `../deploy/Remove-FinOpsEnvironment.ps1 -Scope Web` (só a interface) ou `-Scope All`; depois o instalador de novo. Ciclo completo em [Desligar, apagar e reinstalar](12-ligar-desligar-custos.md#reinstalar-do-zero-o-ciclo-completo-de-teste) |
| Trocar a fonte para o Fabric | Rode o instalador com `-DataBackend Kusto -KustoQueryUri ...` e conceda viewer no banco `Hub` ([seção 11.11](05-referencia-tecnica-interface.md#1111-trocar-a-fonte-para-o-fabric-nível-1-sem-mexer-no-front)) |
| Voltar para o storage | Rode o instalador sem `-DataBackend` (ou com `-DataBackend Storage`) |
| Ver qual fonte está ativa | `<url>/api/status`, campo `backend`; ou passe o mouse no indicador de linhas no cabeçalho |

### 10.15 Custo da solução

| Item | Valor aproximado |
|---|---|
| App Service B1 | cerca de US$ 13/mês |
| Storage de estado (Table) | centavos |
| Log Analytics e App Insights | primeiros 5 GB/mês gratuitos |
| Communication Services e-mail | cerca de US$ 0,25 por mil e-mails; alertas raramente passam de dezenas por mês |
| Leitura do storage do hub | centavos |

Sem licença por usuário. Parado, o ambiente cai para cerca de US$ 8/mês (Light) ou US$ 3/mês (Deep): veja
[Ligar, desligar e custos](12-ligar-desligar-custos.md).

### 10.16 Erros comuns da interface web

| Sintoma | Causa | Solução |
|---|---|---|
| Páginas vazias e `/api/status` com erro de acesso | Identidade sem `Storage Blob Data Reader`, ou RBAC não propagou | Aguarde 5 a 15 min; se persistir, rode o instalador de novo |
| Cadastro de centro ou regra dá erro 500 | Identidade sem `Storage Table Data Contributor` na storage de estado | Rode o instalador de novo (o Bicep concede); ou conceda à mão na storage `finopsweb...` |
| Alertas não chegam por e-mail, painel mostra "só painel" | `-EnableEmail` não foi usado, ou identidade sem permissão no ACS | Rode com `-EnableEmail -AlertEmailTo ...`; confira o papel Contributor no recurso do ACS |
| `Nenhum arquivo parquet encontrado` | O hub ainda não ingeriu | [Seção 7](03-operacao-do-hub.md#7-a-rotina-depois-de-instalado-o-que-roda-sozinho-e-o-que-é-manual). Backfill com `Start-FinOpsCostExport -Backfill 12` |
| Página de IA ou bancos diz "nenhum serviço identificado" | Não há consumo desses domínios no período | Normal. Aparece sozinho quando houver |
| Chargeback mostra "showback automático" | Nenhum centro cadastrado | Cadastre ou importe |
| Previsão com confiabilidade baixa | Série curta ou muito irregular | Aumente o período; leia como ordem de grandeza |
| Gráficos não aparecem | Biblioteca de gráficos vem de CDN e a rede bloqueia | Baixe `echarts.min.js` para `static/js/` e troque a referência no `index.html` |
| Exportação demora | Excel completo roda todas as análises | Normal em conjuntos grandes; 10 a 30 segundos |
| "Não consegui gerar a exportação" na tela | O dado ainda não carregou, ou a sessão de login expirou | Aguarde o indicador de linhas ficar verde e tente de novo; se for login, recarregue a página |
| A URL abre para qualquer pessoa | Sem `-EnableAuth` | Rode de novo com `-EnableAuth` |
| Revisão `Unhealthy`/`ActivationFailed`, réplicas em `ContainerBackOff`, log do console com `Traceback` | O processo morre na inicialização (erro de importação, dependência faltando, porta errada) | Leia o traceback no log do console (`az containerapp logs show --type console`). O kit agora roda `api/test_import.py` antes de publicar; rode você também: `python api/test_import.py` ([seção 16, erro 28](09-diario-de-bordo.md#28-containerbackoff-e-401-na-url-um-nameerror-na-importação-do-mainpy)) |
| Autenticação ligada com `clientId` vazio (diagnóstico mostra `clientId=`) | O comando do provedor falhou e a autenticação foi ligada sem provedor | `az containerapp auth update -g <rg> -n <app> --enabled false` para destravar; depois rode o instalador de novo com `-EnableAuth -CodeOnly` ([seção 16, erro 29](09-diario-de-bordo.md#29-easy-auth-do-container-apps-com-clientid-vazio)) |
| A URL não abre depois do "PRONTO" | Várias causas possíveis: revisão sem réplica pronta (imagem ainda baixando ou pull negado), porta de ingress diferente de 8000, autenticação ligada sem provedor, DNS ou proxy da sua rede, cache de login no navegador | Rode `./Diagnose-FinOpsWebApp.ps1 -ResourceGroup <rg> -HostingModel ContainerApps`. Ele imprime o veredito e o comando de correção. Teste também em janela anônima e fora da VPN |
| `Cannot find Bicep` ao rodar o instalador | Bicep fora do PATH | O instalador resolve sozinho (`Ensure-BicepCli`). Se ainda falhar, `winget install -e --id Microsoft.Bicep` e reabra o PowerShell |
| `MissingSubscriptionRegistration` no Bicep | Resource provider não registrado na assinatura | O instalador registra e aguarda. Manual: `Register-AzResourceProvider -ProviderNamespace Microsoft.Web` (e `Microsoft.Communication` para e-mail) |
| `Cannot retrieve the dynamic parameters for the cmdlet` com linhas `Error BCP...` | O Bicep não compilou; a mensagem do PowerShell esconde o erro real | Leia as linhas `Error BCP`. O instalador atual compila antes e mostra o erro com linha e coluna. Se o kit for antigo, baixe a versão atual ([seção 16, erro 23](09-diario-de-bordo.md#23-bcp120-no-role-assignment-o-bicep-da-interface-não-compilava)) |
| `RoleAssignmentUpdateNotPermitted` na etapa 3 | A app foi apagada e recriada com o mesmo nome; sobrou atribuição de papel apontando para a identidade antiga | `Get-AzRoleAssignment -ResourceGroupName <rg> \| Where-Object ObjectType -eq 'Unknown' \| Remove-AzRoleAssignment` e rode de novo (o instalador imprime o comando) |
| `InternalSubscriptionIsOverQuotaForSku`, `Current Limit (B1 VMs): 0` | Assinatura interna sem cota para a **família** do SKU, em todas as regiões | Troque a família: `-AppServiceSku P0v3` (ou `S1`, ou `F1` para testar). Trocar região não resolve. O script testa as alternativas e imprime o comando pronto |
| `UnicodeEncodeError: 'charmap' codec can't encode` em um comando `az` que mostra log (build, logs) | Console do Windows em `cp1252`; a operação no Azure continuou, só a exibição quebrou | O instalador força UTF-8 e acompanha o build por status. Manual: `$env:PYTHONIOENCODING='utf-8'` antes do `az` ([seção 16, erro 26](09-diario-de-bordo.md#26-unicodeencodeerror-charmap-codec-cant-encode-o-build-rodou-na-nuvem-o-que-quebrou-foi-a-tela)) |
| `PermissionError: [WinError 5] Access is denied: '...\.azure\cliextensions\<extensão>\...'` em qualquer comando `az` | Uma extensão da Azure CLI está com instalação quebrada (`dist-info` sem `METADATA`) ou pasta inacessível; a CLI lê todas ao reconstruir a tabela de comandos, de forma intermitente | O instalador **sempre** usa uma pasta de extensões isolada, então não é afetado, e imprime o comando de limpeza. Limpeza definitiva: `Remove-Item "$HOME\.azure\cliextensions\<extensão>" -Recurse -Force` (como administrador se der acesso negado) ([seção 16, erros 25 e 25b](09-diario-de-bordo.md#25-az-acr-build-morre-com-permissionerror-cliextensionsaksarc-a-azure-cli-da-máquina-estava-quebrada)) |
| `SubscriptionIsOverQuotaForSku`, `QuotaExceeded`, "quota of 0 instances" (sem `Internal`) | Sem cota para o plano **nesta região** (regiões com capacidade restrita, como Brazil South) | `-Location eastus2` (a interface pode ficar em outra região), ou `-AppServiceSku P0v3` |
| `InvalidTemplateDeployment ... 'Microsoft.Web/serverFarms' reported preflight validation errors ... See inner errors for details` | O Azure recusou o plano do App Service e o PowerShell escondeu o motivo | O instalador atual valida antes e mostra a árvore de erros com a causa. Manual: `Test-AzResourceGroupDeployment` com os mesmos parâmetros ([seção 16, erro 24](09-diario-de-bordo.md#24-preflight-validation-errors-see-inner-errors-for-details-o-azure-recusou-o-plano-e-não-disse-por-quê)) |
| Resource group já tem plano Windows (ou de outra família) e o Linux é recusado | O Azure não mistura sistemas operacionais de planos no mesmo resource group e região | `-ResourceGroup rg-finops-web -HubResourceGroup rg-finops-hub -Location <região>`: o script cria o resource group novo |
| Rodou a versão nova do kit e o comportamento é o antigo | O OneDrive ainda não terminou de sincronizar todos os arquivos (eles chegam em ordem aleatória) | Aguarde o ícone do OneDrive ficar verde; confira com `Select-String -Path .\Deploy-FinOpsWebApp.ps1 -Pattern 'Validacao OK' -Quiet` (deve devolver `True`) |
| `'microsoft' is not in the 'az webapp auth' command group` | Azure CLI sem a extensão `authV2` | O instalador adiciona. Manual: `az extension add -n authV2 --upgrade` |
| Publicação do zip termina com erro ou tempo esgotado | Build das dependências no plano B1 demorou mais que o limite | Rode de novo com `-CodeOnly`; o segundo build aproveita o cache. Logs: `az webapp log deployment show -g <rg> -n <app>` |
| `/api/status` responde 302 ou pede login no script | Normal com `-EnableAuth`: só `/api/health` fica fora do login | Abra a URL no navegador |
| Com Kusto, erro `Forbidden` ou 403 em `/api/status` | Identidade sem viewer no banco `Hub` | `.add database Hub viewers ('aadapp=<principalId>;<tenantId>')` (o instalador imprime com os valores certos) |
| Com Kusto, `Costs()` não encontrada | Função inexistente no banco, ou banco errado | Confira `-KustoDatabase` e `-KustoFunction`; no Fabric, o banco do hub chama-se `Hub` |
| Aviso de matplotlib sobre pasta de cache no log | `MPLCONFIGDIR` não definido | O Bicep define `/tmp/matplotlib`; se você criou a app por fora, adicione o app setting |

### 10.17 Estrutura dos arquivos

```
webapp/
├── Deploy-FinOpsWebApp.ps1     instalador, 7 etapas, idempotente
├── Set-FinOpsWebAuth.ps1       liga ou desliga o login Entra ID, gravando e conferindo a configuracao na API
├── Set-FinOpsPower.ps1         Stop / Start / Status: desliga para nao pagar, liga em segundos
├── Diagnose-FinOpsWebApp.ps1   diagnostico de "a URL nao abre": rede, revisoes, porta, auth, HTTP, logs
├── build_preview.py            gera a previa em arquivo unico
├── FinOps-Preview.html         a previa gerada
├── Dockerfile                  SO para Container Apps
├── api/
│   ├── main.py                 rotas, agendador, exportacao
│   ├── sobre.py                identidade da solucao (autor, base)
│   ├── data_source.py          fontes (storage, estatica), fabrica criar_fonte, normalizacao FOCUS 1.0/1.2, tags, ambiente, cache
│   ├── kusto_source.py         fonte Fabric Eventhouse / Data Explorer (nivel 1), consulta KQL
│   ├── analytics.py            agregacoes e comparacao honesta entre meses
│   ├── governance.py           tags, conformidade, orcamento por tag
│   ├── domains.py              deteccao de IA (modelos, tokens, agentes) e bancos (engines)
│   ├── chargeback.py           centros de custo, alocacao, rateio, importacao
│   ├── optimization.py         regras de economia e tabela de equivalencias
│   ├── forecast.py             previsao 30/60/90 com sazonalidade
│   ├── alerts.py               regras, avaliacao, estados, deduplicacao
│   ├── notifications.py        e-mail via ACS ou SMTP
│   ├── state_store.py          persistencia local (JSON) ou Table Storage
│   ├── insights.py             analise automatica
│   ├── export_report.py        PDF (reportlab + matplotlib) e Excel (openpyxl)
│   ├── demo_data.py            dados sinteticos para teste e previa
│   ├── test_local.py           bateria de testes de logica, sem Azure
│   ├── test_import.py          o servidor inicia? importa main.py como o uvicorn; roda antes de publicar
│   └── requirements.txt
├── static/
│   ├── index.html
│   ├── css/styles.css
│   └── js/app.js, pages.js, pages2.js
└── infra/
    ├── webapp.bicep            App Service ou ACA, storage de estado, ACS, papeis, observabilidade
    └── storage-role.bicep      papel de leitura na storage do hub
```

### 10.18 Personalizando para um cliente

| O que mudar | Onde |
|---|---|
| Cores do tema | `static/css/styles.css`, bloco `:root` |
| Cores das nuvens | `CORES_NUVEM` em `static/js/app.js` e `api/export_report.py` |
| Nome e logotipo | `static/index.html`, div `marca` |
| Regras de otimização | `REGRAS_TROCA` em `api/optimization.py` |
| Tags obrigatórias padrão | `TAGS_OBRIGATORIAS_PADRAO` em `api/governance.py` (ou pela interface) |
| Regras de alerta padrão | `regras_padrao()` em `api/alerts.py` (ou pela interface) |
| Detecção de serviços de IA e bancos | `PADROES_IA` e `ENGINES` em `api/domains.py` |

Depois, `python api/test_local.py` para validar, `python build_preview.py` para regerar a prévia e `-CodeOnly` para
republicar. A [seção 11](05-referencia-tecnica-interface.md#11-como-a-interface-web-é-construída-referência-técnica) descreve cada módulo e o fluxo do dado para quem for além dessas trocas.
