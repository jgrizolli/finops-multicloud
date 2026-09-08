# Telas da interface

As capturas da interface web que o README exibe.

| Arquivo | Página |
|---|---|
| `visao-geral.png` | Visão geral: indicadores, evolução mensal, distribuição por categoria, custo diário, maiores serviços |
| `inteligencia-artificial.png` | Inteligência artificial: participação da IA no total, evolução por modelo, quebra por serviço, modelo e nuvem |
| `showback-chargeback.png` | Showback e chargeback: evolução por centro de custo, participação e a tabela do que cada área consumiu |

São capturas do ambiente real, com a barra de status do navegador recortada para não expor o endereço da instalação.

Para gerar outras telas, ou refazer estas quando o visual mudar, use o capturador, que abre a prévia no Microsoft
Edge em modo headless e salva um PNG de cada página:

```powershell
.\docs\capturar-telas.ps1 -Rotas Todas
```
