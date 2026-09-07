# Base de conhecimento FinOps Multicloud para o Copilot Notebook

> Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**. Baseado no **Microsoft FinOps toolkit**.

Esta pasta é a **base de conhecimento** do projeto no formato que o Copilot Notebook (Microsoft 365 Copilot) consome
melhor: um documento Word por tema, gerados a partir da documentação do kit (`finops-multicloud-kit/docs/`). Com eles
como fontes, o Copilot responde perguntas, gera checklists, compara decisões e ajuda a começar o próximo projeto
com tudo o que este ensinou.

## Os 14 documentos (fontes do notebook)

| Arquivo | Conteúdo | Use para perguntar sobre |
|---|---|---|
| `FinOps-Multicloud-00-README.docx` | Visão geral, início rápido, **os scripts e a ordem de execução**, mapa da documentação | "Como instalo do zero?", "qual script faz o quê?" |
| `FinOps-Multicloud-01-arquitetura-e-escolhas.docx` | Níveis 0 e 1; Power BI, interface web ou ambos | "Quando usar Fabric?", "Power BI ou interface?" |
| `FinOps-Multicloud-02-instalacao-do-hub.docx` | Pré-requisitos, os 8 passos, relatórios Power BI, portal | "Como configuro o .pbit?", "por que o relatório ficou em branco?" |
| `FinOps-Multicloud-03-operacao-do-hub.docx` | Retenção, rotina diária, reexecutar, atualizar, remover | "Como guardar 24 meses?", "o que roda sozinho?" |
| `FinOps-Multicloud-04-interface-web.docx` | As 14 páginas, instalação, opções, alertas, chargeback, previsão, exportação, erros | "Como funciona o chargeback?", "como ligo o e-mail de alerta?" |
| `FinOps-Multicloud-05-referencia-tecnica-interface.docx` | Stack, módulos, captura do FOCUS, normalização, contrato da API, segurança, Fabric | "Como a interface lê o parquet?", "como migro para o Fabric?" |
| `FinOps-Multicloud-06-entendendo-o-codigo.docx` | Guia de estudo: camadas, cada arquivo, decisões, roteiros de apresentação, FAQ, exercícios | "Me explique o código em 10 minutos", "por que Python?" |
| `FinOps-Multicloud-07-multicloud-aws-oci.docx` | AWS e OCI | "O que preparar na conta AWS?" |
| `FinOps-Multicloud-08-erros-regras-limites.docx` | Tabela de erros, regras de ouro, limites | "Deu erro X, o que faço?" |
| `FinOps-Multicloud-09-diario-de-bordo.docx` | Os 29 erros reais com sintoma, causa, raciocínio e correção; bases de conhecimento de cotas, CLI e PowerShell | "Já vimos esse erro antes?", "qual foi a causa do BCP120?" |
| `FinOps-Multicloud-10-glossario-e-focus.docx` | Termos e colunas FOCUS | "Qual a diferença entre BilledCost e EffectiveCost?" |
| `FinOps-Multicloud-11-comandos.docx` | Todos os comandos | "Qual o comando para backfill?" |
| `FinOps-Multicloud-12-desligar-apagar-reinstalar.docx` | As três ações, custos parado, ciclo completo de reinstalação, login | "Como desligo para não pagar?", "como apago tudo e reinstalo?" |
| `FinOps-Multicloud-13-licoes-aprendidas.docx` | Lições por tema, checklist do próximo projeto, frases | "O que levo para o próximo projeto?", "monte um checklist de instalador" |

A fonte de verdade é o Markdown do kit; os Word são gerados a partir dele. Ao evoluir o kit, atualize os `.md` e
regenere os Word (qualquer conversor Markdown para Word serve; o usado aqui foi um script Python com `python-docx`).

## Como criar o notebook (uma vez)

1. Abra o **Microsoft 365 Copilot** (app ou `m365.cloud.microsoft`) e, no menu lateral, **Notebooks**. Clique em
   **Novo notebook**.
2. Dê o nome **FinOps Multicloud: base de conhecimento** e, na descrição, cole o texto da seção "Descrição sugerida"
   abaixo (ela orienta o Copilot sobre o que o notebook é e como responder).
3. Em **Adicionar fontes**, escolha os 14 arquivos `.docx` desta pasta (eles estão no seu OneDrive, na pasta do
   projeto). O Copilot Notebook aceita até 20 fontes, então cabem os 14 e sobram 6 para você acrescentar, por exemplo,
   o `HLD v3 FinOps Multicloud Azure AWS OCI.pptx`, a `Documentacao FinOps Multicloud Azure AWS OCI.docx` e o `Guia
   passo a passo pelo portal FinOps Multicloud.docx`, que também estão na pasta do projeto.
4. Faça a primeira pergunta da lista abaixo para testar.

Quando a documentação do kit mudar, substitua o `.docx` correspondente nesta pasta; o notebook lê a versão atual do
arquivo no OneDrive.

## Descrição sugerida para o notebook

> Base de conhecimento do projeto FinOps Multicloud, construído por Wanderlei Grizolli Junior (Sr. Solution
> Engineer) sobre o Microsoft FinOps toolkit: um kit replicável que instala o FinOps hub, coleta custo de Azure, AWS,
> Google Cloud e OCI em FOCUS e oferece relatórios Power BI e uma interface web própria (FastAPI + ECharts) com
> governança, chargeback, otimização, previsão e alertas. As fontes cobrem arquitetura, instalação, operação, código,
> os 29 erros reais da implantação com causa e correção, e as lições aprendidas. Responda sempre citando o documento
> de origem; quando a pergunta for sobre um erro, procure primeiro no diário de bordo; quando for sobre começar um
> projeto novo, use as lições aprendidas e o checklist.

## Perguntas para fazer ao notebook

Sobre o projeto:

* "Explique a arquitetura em cinco camadas e diga qual é o contrato entre elas."
* "Qual a ordem dos scripts para instalar do zero, e o que cada um faz?"
* "Como desligo o ambiente para não pagar, e como apago tudo para reinstalar? Qual a diferença?"
* "Quanto custa o ambiente ligado, parado e apagado?"
* "Como a interface web lê o dado FOCUS e o que a função normalizar faz?"
* "Por que a comparação entre meses usa MTD contra os mesmos dias do mês anterior?"
* "Como migro a interface do storage para o Fabric sem mexer no front?"

Sobre erros:

* "Deu InternalSubscriptionIsOverQuotaForSku com Total VMs 0. O que fazer?"
* "A URL do Container App não abre. Qual a sequência de diagnóstico?"
* "Quais erros já vimos com a Azure CLI e como o kit se protege de cada um?"
* "Liste os erros do diário que envolvem Bicep, com a correção de cada um."

Para o próximo projeto:

* "Monte um checklist de instalador PowerShell replicável com base nas lições aprendidas."
* "Quais lições sobre testes devo aplicar em um projeto Python novo?"
* "Escreva a seção diário de bordo de um README novo seguindo o formato deste projeto."
* "Compare as decisões de projeto (App Service ou Container Apps, Python ou .NET) e diga quando eu escolheria diferente."

Para apresentar:

* "Prepare um roteiro de 10 minutos para explicar a solução a um gerente técnico."
* "Liste as 12 perguntas mais prováveis de uma plateia técnica e as respostas curtas."

## Como manter viva a base

A cada projeto novo que use este kit (ou parte dele), acrescente ao diário de bordo (`docs/09`) os erros novos e às
lições aprendidas (`docs/13`) o que ficou de regra, regenere os dois Word e substitua nesta pasta. O notebook passa a
saber. Em um ano, isso vale mais que o código.
