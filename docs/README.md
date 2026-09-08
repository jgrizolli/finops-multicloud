# Documentacao

Treze documentos, na ordem em que fazem sentido ler. Os numeros de secao dentro de cada arquivo sao estaveis e
servem como referencia cruzada entre eles.

| # | Documento | O que responde |
|---|---|---|
| 01 | [Arquitetura e escolhas](01-arquitetura-e-escolhas.md) | Como a solucao funciona, qual nivel instalar (0, 1 ou 2) e qual camada de consumo escolher |
| 02 | [Instalacao do hub](02-instalacao-do-hub.md) | Passo 1 ao 8 da instalacao, por script ou pelo portal, com os valores que voce precisa ter em maos |
| 03 | [Operacao do hub](03-operacao-do-hub.md) | O dia a dia: ingestao, retencao, historico e o que olhar quando o dado nao aparece |
| 04 | [Interface web](04-interface-web.md) | As 14 paginas do portal proprio, instalacao, login e uso |
| 05 | [Referencia tecnica da interface](05-referencia-tecnica-interface.md) | Como a interface é construida por dentro, arquivo a arquivo |
| 06 | [Entendendo o codigo](06-entendendo-o-codigo.md) | O que cada script e cada modulo faz, para voce explicar a outra pessoa |
| 07 | [Multicloud AWS e OCI](07-multicloud-aws-oci.md) | Como as outras nuvens entram no mesmo hub em FOCUS |
| 08 | [Erros, regras e limites](08-erros-regras-limites.md) | Sintoma, causa e solucao dos erros conhecidos. Comece por aqui quando algo quebrar |
| 09 | [Diario de bordo](09-diario-de-bordo.md) | Os erros reais de uma implantacao e o raciocinio por tras de cada decisao |
| 10 | [Glossario e FOCUS](10-glossario-e-focus.md) | Os termos e as colunas do padrao FOCUS, em portugues claro |
| 11 | [Comandos](11-comandos.md) | Todos os comandos do kit, prontos para copiar |
| 12 | [Ligar, desligar e custos](12-ligar-desligar-custos.md) | Desligar, apagar e reinstalar: as tres acoes lado a lado |
| 13 | [Licoes aprendidas](13-licoes-aprendidas.md) | O que levar para o proximo projeto |

## Material de apoio

| Pasta | Conteudo |
|---|---|
| [`anexos/`](anexos/) | Runbook inicial, instalacao pelo portal multicloud e a visao inicial dos scripts |
| [`entregaveis/`](entregaveis/) | Documentacao completa em Word, guia de instalacao pelo portal em Word e o HLD v3 em PowerPoint |
| [`images/`](images/) | Imagens da documentacao: a visao executiva no Power BI e, em `images/interface/`, as telas da interface web exibidas no README |
| [capturar-telas.ps1](capturar-telas.ps1) | Gera as telas da interface a partir da previa, usando o Microsoft Edge em modo headless. Rode quando o visual mudar |
| [COMO-CRIAR-O-NOTEBOOK.md](COMO-CRIAR-O-NOTEBOOK.md) | Passo a passo para montar um notebook do Microsoft 365 Copilot com esta documentacao como fonte |
