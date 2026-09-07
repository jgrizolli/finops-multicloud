# Como contribuir

Obrigado por querer melhorar o FinOps Multicloud. Este repositorio nasceu de uma implantacao real, entao a regra
principal é simples: **so entra no repositorio o que voce testou em uma assinatura de verdade**.

## Antes de abrir um Pull Request

1. Leia [docs/01-arquitetura-e-escolhas.md](docs/01-arquitetura-e-escolhas.md) para entender os niveis (0, 1 e 2) e a
   escolha da camada de consumo. Mudanca que quebra essa escolha precisa ser discutida em uma issue antes.
2. Rode os scripts que voce alterou em uma assinatura de teste, do inicio ao fim, e registre o resultado na descricao
   do PR (comando usado, tempo, saida relevante).
3. Se a mudanca gerar um erro novo ou resolver um erro antigo, atualize
   [docs/08-erros-regras-limites.md](docs/08-erros-regras-limites.md) e, quando o raciocinio for util para outra
   pessoa, o [diario de bordo](docs/09-diario-de-bordo.md).

## Padroes de codigo

| Area | Regra |
|---|---|
| PowerShell | PowerShell 7, verbos aprovados (`Get`, `Set`, `New`, `Remove`), `[CmdletBinding()]`, `-WhatIf` em tudo que apaga ou altera, mensagens de erro que dizem o que fazer a seguir |
| Python (API) | FastAPI, funcoes pequenas, sem segredo em codigo, identidade gerenciada e RBAC para tudo que fala com Azure |
| Bicep | Nomes de recurso derivados de `uniqueString`, sem valor fixo de assinatura ou tenant, `roleDefinitionId` sempre por GUID de papel interno |
| KQL | Funcoes no banco `Hub`, nomes em ingles, comentario de uma linha explicando a intencao |
| Documentacao | Portugues do Brasil, termos de produto em ingles quando aparecem assim na tela, numeros de secao estaveis (nao renumere) |

## Nunca versione

Chave de acesso, senha, connection string, arquivo `.pem`, `parameters.json` preenchido, `local.settings.json`,
identificador real de assinatura ou tenant. O `.gitignore` ja bloqueia os casos conhecidos, mas confira o `git diff`
antes do commit.

## Mensagens de commit

Use o padrao `tipo: resumo no imperativo`, por exemplo:

```
feat: adiciona pipeline de recomendacoes da AWS
fix: corrige versao FOCUS 1.0r2 nos exports gerenciados
docs: explica a retencao do ingestion em 03-operacao-do-hub
chore: atualiza acoes do workflow de CI
```

## Fluxo

1. Crie um branch a partir de `main`: `git checkout -b feat/nome-curto`
2. Faca commits pequenos e com contexto
3. Abra o PR preenchendo o template
4. O workflow de CI precisa passar (analise de PowerShell, compilacao do Bicep, sintaxe de Python e JSON)
