"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Este modulo concentra a identidade da solucao para que ela apareca de forma consistente
na interface, na API, nos relatorios exportados e nos e-mails de alerta.
"""

from __future__ import annotations

NOME = "FinOps Multicloud"
VERSAO = "2.0.0"
AUTOR = "Wanderlei Grizolli Junior"
CARGO = "Sr. Solution Engineer"
LINKEDIN = "https://www.linkedin.com/in/wanderlei-g-junior"
BASE = "Microsoft FinOps toolkit"
BASE_URL = "https://github.com/microsoft/finops-toolkit"
PADRAO_DADOS = "FOCUS (FinOps Open Cost and Usage Specification)"

CREDITO_CURTO = f"Construído por {AUTOR}, {CARGO}. Baseado no {BASE}."

CREDITO_LONGO = (
    f"{NOME} foi construído por {AUTOR}, {CARGO}, sobre o {BASE}, a solução de código aberto "
    f"da Microsoft para engenharia de custos em nuvem. O motor de dados é o FinOps hub do toolkit, "
    f"e todo o consumo é lido no padrão {PADRAO_DADOS}, o que permite comparar Azure, AWS, "
    f"Google Cloud e Oracle Cloud na mesma tabela."
)


def como_dict() -> dict:
    return {
        "nome": NOME,
        "versao": VERSAO,
        "autor": AUTOR,
        "cargo": CARGO,
        "linkedin": LINKEDIN,
        "baseadoEm": BASE,
        "baseadoEmUrl": BASE_URL,
        "padraoDados": PADRAO_DADOS,
        "creditoCurto": CREDITO_CURTO,
        "creditoLongo": CREDITO_LONGO,
    }
