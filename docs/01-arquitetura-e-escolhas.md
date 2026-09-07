# Arquitetura e escolhas: nível de instalação e camada de consumo

> Parte da documentação do **FinOps Multicloud**. Construído por **Wanderlei Grizolli Junior, Sr. Solution Engineer**, sobre o **Microsoft FinOps toolkit**. Volte ao [índice geral](../README.md). Os números de seção são os do guia original e servem como identificadores estáveis nas referências cruzadas.

**Nesta página**

* [2. Escolha o nível antes de instalar](#2-escolha-o-nível-antes-de-instalar)
* [3. Escolha a camada de consumo](#3-escolha-a-camada-de-consumo)

---

## 2. Escolha o nível antes de instalar

Os três níveis usam o mesmo storage, as mesmas pastas e os mesmos conectores. Subir de nível é reexecutar o instalador
com um parâmetro a mais; nada é recarregado.

| Nível | O que é instalado | Custo aproximado da própria solução (documentação do toolkit) | Para quem |
|---|---|---|---|
| **0 Mínimo** | Hub storage-only + conectores AWS/OCI + Power BI storage reports | ~US$ 5 por US$ 1 milhão monitorado por mês | Piloto, validação, até ~US$ 100 mil/mês |
| **1 Recomendado** | Hub + Fabric F2 (Eventhouse) + KQL reports + Real-Time Dashboard + Activator | ~US$ 300/mês (F2) + US$ 10 por US$ 1 milhão | Produção |
| **2 Escala** | F4/F8 ou Data Explorer dedicado, private endpoints, remote hubs, Purview, Data Agent | Conforme a capacidade | Grandes estates, vários tenants |

> Regra prática: comece no **nível 0 só com Azure** (`-Mode Storage -SkipAws -SkipOci`), veja o primeiro relatório,
> depois acrescente Fabric, AWS e OCI, um de cada vez. Cada acréscimo é uma nova execução do mesmo script.

---

---

## 3. Escolha a camada de consumo

Os níveis da seção anterior definem **onde o dado fica**. Esta seção define **como você olha para ele**. As duas
escolhas são independentes: qualquer camada de consumo funciona sobre qualquer nível.

Existem duas opções, e você pode usar **as duas ao mesmo tempo** sobre o mesmo hub.

### 3.1 Opção A: relatórios Power BI do FinOps toolkit

Seis relatórios prontos, publicados e mantidos pela Microsoft, que já entendem o formato FOCUS.

**O que você ganha**

* Nada para construir. Baixa, cola a URL e o número de meses, e está pronto.
* Mantidos pela Microsoft, com correções e melhorias a cada release do toolkit.
* Cobertura ampla: custo, otimização de taxa, chargeback, otimização de workload, governança e qualidade de dados.
* Publicando no Power BI Service, ganha URL, acesso pelo celular, aba no Teams e atualização agendada.

**O que você aceita em troca**

* A aparência é a do Power BI. Personalização existe, mas dentro do que a ferramenta permite.
* Cada pessoa que **visualiza** precisa de licença Pro, a menos que o workspace esteja em capacidade F64 ou maior.
* Você depende do ritmo de release da Microsoft para mudanças de fundo.

**O que instalar:** nada além do hub. Os relatórios são arquivos que você baixa. O instalador do kit já imprime,
ao final, a URL e o número de meses prontos para colar.

### 3.2 Opção B: interface web própria

Uma aplicação web construída sob medida, hospedada em Azure Container Apps, que lê o mesmo dado do hub.

**O que você ganha**

* Identidade visual própria, do logotipo à paleta. Fica com a cara da sua empresa ou do seu cliente.
* Acesso por navegador, com login Entra ID, **sem exigir licença Power BI de ninguém**.
* Funcionalidades que um relatório não faz: **cadastro de centros de custo e chargeback**, **alertas com estado e
  e-mail**, **previsão de 30/60/90 dias**, **otimização com troca de tecnologia**, páginas dedicadas a **IA** e a
  **bancos de dados**, e exportação em **PDF e Excel**.
* Cores fixas por nuvem (Azure azul, AWS laranja, Google verde, OCI vermelho) em todos os gráficos.

**O que você aceita em troca**

* É software: precisa ser mantido, atualizado e ter alguém responsável.
* O custo da infraestrutura é seu (Container Apps, registry, observabilidade).
* O tempo até a primeira tela é maior que o de abrir um `.pbit`.

**O que instalar:** um segundo script de implantação, que cria a infraestrutura da aplicação (Container Apps
Environment, Container App, Container Registry, identidade gerenciada, autenticação Entra ID e Log Analytics) e
publica o código. Esse script é **independente** do instalador do hub e só roda se você escolher esta opção.

### 3.3 Comparativo direto

| Critério | Opção A: Power BI do toolkit | Opção B: interface web própria |
|---|---|---|
| Tempo até a primeira tela | Minutos | Dias |
| Esforço de manutenção | Muito baixo | Contínuo |
| Personalização visual | Limitada ao Power BI | Total |
| Licença para quem visualiza | Pro, ou capacidade F64+ | Nenhuma licença Power BI |
| Custo de infraestrutura própria | Zero | Container Apps e apoio |
| Funcionalidade além de relatório | Não | Sim (ações, formulários, integrações) |
| Quem mantém o conteúdo | Microsoft | Você |
| Serve para entregar a cliente | Sim, imediatamente | Sim, com diferenciação |

### 3.4 Qual escolher

**Escolha a opção A se** você quer valor rápido, não tem equipe para manter software, o público já usa Power BI,
ou está validando a solução antes de investir.

**Escolha a opção B se** você precisa de identidade visual própria, tem público amplo sem licença Power BI, quer
funcionalidades que um relatório não faz, ou está construindo um produto ou oferta para clientes.

**Escolha as duas se** você quer o melhor dos dois mundos, que é o caminho mais comum na prática: Power BI para a
análise profunda de quem trabalha com FinOps todos os dias, e a interface web para a visão executiva e para quem
só precisa consultar de vez em quando. Como as duas leem o mesmo hub, os números são sempre os mesmos.

**A recomendação deste kit:** comece pela opção A, mesmo que o seu destino seja a B. Os relatórios do toolkit
mostram como o modelo FOCUS se comporta com o seu dado real, e essa compreensão é exatamente o que você precisa
para especificar bem a interface própria. Trocar depois não custa nada, porque o hub não muda.

### 3.5 O que instalar em cada caso

| Sua escolha | Scripts a executar |
|---|---|
| **Só Power BI** | `Deploy-FinOpsMulticloud.ps1` |
| **Só interface web** | `Deploy-FinOpsMulticloud.ps1` e depois `Deploy-FinOpsWebApp.ps1` |
| **As duas** | Os mesmos dois. A ordem é a mesma |

O `Deploy-FinOpsMulticloud.ps1` é sempre obrigatório: é ele que cria o hub, de onde vem o dado. A camada de
consumo é o que muda.
