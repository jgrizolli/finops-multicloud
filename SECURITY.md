# Politica de seguranca

## Como reportar

Encontrou uma falha de seguranca neste repositorio? **Nao abra uma issue publica.** Use a aba
**Security > Report a vulnerability** (GitHub Private Vulnerability Reporting) ou envie uma mensagem direta ao
mantenedor. A resposta sai em ate 5 dias uteis.

## O que este projeto faz para se proteger

* Nenhum segredo em arquivo ou variavel: acesso a Azure por identidade gerenciada e RBAC, e as credenciais de AWS e
  OCI vao para o Key Vault criado pelo instalador.
* `parameters.json`, `local.settings.json`, `*.pem`, `.env` e afins estao no `.gitignore`.
* A interface web usa Entra ID (`Set-FinOpsWebAuth.ps1`) e os dados de custo sao lidos com identidade gerenciada,
  sem chave de conta de armazenamento.
* Os arquivos de exemplo (`parameters.example.json`) trazem apenas valores fictícios.

## Antes de publicar qualquer alteracao

Confira que o commit nao leva identificador real de assinatura, tenant, OCID, chave AWS (`AKIA...`) nem endereco de
email corporativo de cliente. Todos os exemplos usam valores como `1111aaaa-2222-bbbb-3333-cccc4444dddd`,
`AKIAIOSFODNN7EXAMPLE` e `voce@empresa.com`.

## Escopo

Este projeto se apoia no [Microsoft FinOps toolkit](https://github.com/microsoft/finops-toolkit). Falhas no proprio
toolkit devem ser reportadas no repositorio da Microsoft.
