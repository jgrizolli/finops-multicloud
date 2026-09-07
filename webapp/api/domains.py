"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Dominios tematicos: inteligencia artificial e bancos de dados.

Os dois seguem o mesmo desenho: uma funcao classifica as linhas do FOCUS que pertencem ao
dominio (por nome de servico, categoria, tipo de recurso e descricao, nas quatro nuvens),
e uma funcao monta a visao completa do dominio reaproveitando as agregacoes gerais.
"""

from __future__ import annotations

import re

import pandas as pd

import analytics

# --------------------------------------------------------------------------- IA
PADROES_IA = re.compile(
    r"(openai|cognitive|ai foundry|foundry|azure ai|machine learning|ai search|bot service|"
    r"document intelligence|form recognizer|speech|language understanding|translator|content safety|"
    r"ai agent|copilot|bedrock|sagemaker|comprehend|rekognition|textract|kendra|amazon q\b|amazon lex|"
    r"polly|transcribe|vertex|gemini|dialogflow|natural language|vision ai|automl|document ai|"
    r"generative ai|data science|ai language|ai vision|ai speech|anthropic|mistral|llama|phi-|dall-e|whisper)",
    re.I,
)
TIPOS_IA = re.compile(r"(cognitiveservices|machinelearningservices|search/searchservices|botservice|aiservices)", re.I)

PADROES_MODELO = [
    (re.compile(r"gpt-?4o-?mini", re.I), "GPT-4o mini"), (re.compile(r"gpt-?4\.1-?mini", re.I), "GPT-4.1 mini"),
    (re.compile(r"gpt-?4\.1-?nano", re.I), "GPT-4.1 nano"), (re.compile(r"gpt-?4\.1", re.I), "GPT-4.1"),
    (re.compile(r"gpt-?4o", re.I), "GPT-4o"), (re.compile(r"gpt-?4", re.I), "GPT-4"),
    (re.compile(r"gpt-?3\.?5|gpt-?35", re.I), "GPT-3.5"), (re.compile(r"\bo3-?mini", re.I), "o3-mini"),
    (re.compile(r"\bo1-?mini", re.I), "o1-mini"), (re.compile(r"\bo[134]\b", re.I), "o-series"),
    (re.compile(r"text-?embedding|embedding", re.I), "Embeddings"), (re.compile(r"dall-?e", re.I), "DALL-E"),
    (re.compile(r"whisper", re.I), "Whisper"), (re.compile(r"claude", re.I), "Claude"),
    (re.compile(r"llama", re.I), "Llama"), (re.compile(r"mistral", re.I), "Mistral"), (re.compile(r"phi-?\d", re.I), "Phi"),
    (re.compile(r"gemini", re.I), "Gemini"), (re.compile(r"titan", re.I), "Titan"), (re.compile(r"cohere", re.I), "Cohere"),
    (re.compile(r"deepseek", re.I), "DeepSeek"), (re.compile(r"sora", re.I), "Sora"),
]

PADRAO_AGENTE = re.compile(r"(agent|agentic|copilot studio|assistants?)", re.I)
PADRAO_TOKEN = re.compile(r"token", re.I)
PADRAO_ENTRADA = re.compile(r"(input|prompt)", re.I)
PADRAO_SAIDA = re.compile(r"(output|completion|generated)", re.I)
PADRAO_CACHE = re.compile(r"cached", re.I)


def _texto_ia(df) -> pd.Series:
    return (df["ServiceName"] + " | " + df["ServiceCategory"] + " | " + df["ResourceType"] + " | "
            + df["SkuMeter"] + " | " + df["SkuDescription"] + " | " + df["ChargeDescription"] + " | " + df["ServiceSubcategory"])


def mascara_ia(df) -> pd.Series:
    if df.empty:
        return pd.Series(dtype=bool)
    cat = df["ServiceCategory"].str.contains(r"AI|Machine Learning", case=False, regex=True, na=False)
    txt = _texto_ia(df)
    return cat | txt.str.contains(PADROES_IA, na=False) | df["ResourceType"].str.contains(TIPOS_IA, na=False)


def _modelo(texto: str) -> str:
    for padrao, nome in PADROES_MODELO:
        if padrao.search(texto):
            return nome
    return "Outros / não identificado"


def _multiplicador_unidade(unidade: str) -> float:
    u = (unidade or "").lower()
    if "1m" in u or "million" in u or "1,000,000" in u:
        return 1_000_000.0
    if "1k" in u or "1000" in u or "thousand" in u:
        return 1_000.0
    if "100" in u:
        return 100.0
    return 1.0


def analisar_ia(df_total, meses_disponiveis: list[str]) -> dict:
    if df_total.empty:
        return {"resumo": {}, "vazio": True}
    m = mascara_ia(df_total)
    ia = df_total[m].copy()
    total_geral = float(df_total["EffectiveCost"].sum())
    if ia.empty:
        return {"resumo": {"total": 0.0, "participacao": 0.0, "moeda": analytics.moeda_de(df_total)}, "vazio": True,
                "mensagem": "Nenhum serviço de IA identificado no período. Foundry, Azure OpenAI, Bedrock, Vertex AI e "
                            "Generative AI da OCI aparecem aqui automaticamente quando houver consumo."}

    texto = _texto_ia(ia)
    ia["Modelo"] = texto.map(_modelo)
    ia["Agente"] = texto.str.contains(PADRAO_AGENTE, na=False)

    # tokens: linhas cuja unidade de consumo ou preco fala em token
    unidade = ia["ConsumedUnit"].where(ia["ConsumedUnit"].str.strip() != "", ia["PricingUnit"])
    eh_token = unidade.str.contains(PADRAO_TOKEN, na=False) | ia["SkuMeter"].str.contains(PADRAO_TOKEN, na=False)
    quantidade = ia["ConsumedQuantity"].where(ia["ConsumedQuantity"] > 0, ia["PricingQuantity"])
    mult = unidade.map(_multiplicador_unidade)
    ia["Tokens"] = (quantidade * mult).where(eh_token, 0.0)
    ia["TipoToken"] = "Outros"
    ia.loc[eh_token & texto.str.contains(PADRAO_ENTRADA, na=False), "TipoToken"] = "Entrada"
    ia.loc[eh_token & texto.str.contains(PADRAO_SAIDA, na=False), "TipoToken"] = "Saída"
    ia.loc[eh_token & texto.str.contains(PADRAO_CACHE, na=False), "TipoToken"] = "Cache"

    total_ia = float(ia["EffectiveCost"].sum())
    tokens = float(ia["Tokens"].sum())
    custo_tokens = float(ia.loc[eh_token, "EffectiveCost"].sum())
    comp = analytics.comparar_meses(ia)

    # tokens por mes e por tipo
    tok_mes = ia[eh_token].groupby("Mes")["Tokens"].sum().sort_index()
    tok_tipo = ia[eh_token].groupby("TipoToken")["Tokens"].sum().sort_values(ascending=False)

    # participacao da IA no total, mes a mes
    ia_mes = ia.groupby("Mes")["EffectiveCost"].sum()
    tot_mes = df_total.groupby("Mes")["EffectiveCost"].sum()
    participacao = [{"mes": m_, "ia": float(ia_mes.get(m_, 0.0)), "total": float(tot_mes.get(m_, 0.0)),
                     "participacao": (float(ia_mes.get(m_, 0.0)) / float(tot_mes.get(m_, 1.0))) if tot_mes.get(m_, 0) else 0.0}
                    for m_ in sorted(tot_mes.index)]

    agentes = ia[ia["Agente"]]
    resumo = {
        "total": total_ia, "participacao": (total_ia / total_geral) if total_geral else 0.0,
        "variacaoMensal": comp["variacao"], "comparacaoParcial": comp["parcial"], "diasComparados": comp["diasComparados"],
        "rotuloMesAnterior": comp["rotuloAnterior"], "mesAnterior": comp["anterior"], "mesAtual": comp["atual"],
        "tokens": tokens, "custoTokens": custo_tokens,
        "custoPorMilhaoTokens": (custo_tokens / tokens * 1_000_000) if tokens > 0 else 0.0,
        "recursos": int(ia.loc[ia["ResourceName"].str.strip() != "", "ResourceName"].nunique()),
        "servicos": int(ia["ServiceName"].nunique()), "modelos": int(ia["Modelo"].nunique()),
        "custoAgentes": float(agentes["EffectiveCost"].sum()), "recursosAgentes": int(agentes["ResourceName"].nunique()),
        "moeda": analytics.moeda_de(ia),
    }
    return {
        "vazio": False, "resumo": resumo,
        "mensal": analytics.serie_mensal(ia), "diario": analytics.serie_diaria(ia), "participacaoMensal": participacao,
        "porServico": analytics.agrupar(ia, "ServiceName", 12), "porModelo": analytics.agrupar(ia, "Modelo", 12),
        "porNuvem": analytics.agrupar(ia, "Nuvem", 6), "porRecurso": analytics.top_recursos(ia, 25),
        "porAssinatura": analytics.agrupar(ia, "SubAccountName", 10),
        "evolucaoModelo": analytics.evolucao_por(ia, "Modelo", 6),
        "tokensMensal": [{"mes": k, "tokens": float(v)} for k, v in tok_mes.items()],
        "tokensPorTipo": [{"tipo": k, "tokens": float(v)} for k, v in tok_tipo.items()],
        "agentes": analytics.top_recursos(agentes, 15) if not agentes.empty else [],
    }


# --------------------------------------------------------------------------- bancos de dados
ENGINES = [
    # Servicos gerenciados primeiro: "Amazon RDS ... PostgreSQL" e RDS, nao PostgreSQL generico.
    (re.compile(r"aurora", re.I), "Amazon Aurora", "Relacional"),
    (re.compile(r"amazon rds|\brds\b|relational database service", re.I), "Amazon RDS", "Relacional"),
    (re.compile(r"dynamodb", re.I), "Amazon DynamoDB", "NoSQL"),
    (re.compile(r"redshift", re.I), "Amazon Redshift", "Analítico"),
    (re.compile(r"neptune", re.I), "Amazon Neptune", "NoSQL"),
    (re.compile(r"elasticache|memorydb", re.I), "Amazon ElastiCache", "Cache"),
    (re.compile(r"keyspaces|timestream|qldb", re.I), "Amazon NoSQL (outros)", "NoSQL"),
    (re.compile(r"alloydb", re.I), "AlloyDB", "Relacional"),
    (re.compile(r"cloud sql", re.I), "Cloud SQL", "Relacional"),
    (re.compile(r"spanner", re.I), "Cloud Spanner", "Relacional"),
    (re.compile(r"firestore|datastore|bigtable", re.I), "Google NoSQL", "NoSQL"),
    (re.compile(r"bigquery", re.I), "BigQuery", "Analítico"),
    (re.compile(r"memorystore", re.I), "Memorystore", "Cache"),
    (re.compile(r"autonomous", re.I), "Oracle Autonomous Database", "Relacional"),
    (re.compile(r"exadata|database cloud service|oracle database", re.I), "Oracle Database", "Relacional"),
    (re.compile(r"heatwave", re.I), "MySQL HeatWave", "Relacional"),
    (re.compile(r"nosql database", re.I), "Oracle NoSQL", "NoSQL"),
    # Azure e motores genericos
    (re.compile(r"sql managed instance|managedinstances", re.I), "Azure SQL Managed Instance", "Relacional"),
    (re.compile(r"azure sql|sql database|sql/servers", re.I), "Azure SQL Database", "Relacional"),
    (re.compile(r"postgresql|postgres|dbforpostgresql", re.I), "PostgreSQL", "Relacional"),
    (re.compile(r"mysql|dbformysql", re.I), "MySQL", "Relacional"),
    (re.compile(r"mariadb", re.I), "MariaDB", "Relacional"),
    (re.compile(r"cosmos|documentdb", re.I), "Azure Cosmos DB", "NoSQL"),
    (re.compile(r"redis|cache for redis", re.I), "Cache (Redis)", "Cache"),
    (re.compile(r"synapse.*(sql|dedicated)|dedicated sql pool", re.I), "Synapse SQL", "Analítico"),
    (re.compile(r"data explorer|kusto|eventhouse", re.I), "Data Explorer / Eventhouse", "Analítico"),
    (re.compile(r"mongodb|atlas", re.I), "MongoDB", "NoSQL"),
]
CATEGORIA_BD = re.compile(r"database", re.I)


def _texto_bd(df) -> pd.Series:
    return df["ServiceName"] + " | " + df["ResourceType"] + " | " + df["SkuMeter"] + " | " + df["ServiceSubcategory"]


def classificar_engine(texto: str) -> tuple[str, str]:
    for padrao, nome, tipo in ENGINES:
        if padrao.search(texto):
            return nome, tipo
    return "Outros bancos", "Outros"


def analisar_bancos(df_total, meses_disponiveis: list[str]) -> dict:
    if df_total.empty:
        return {"resumo": {}, "vazio": True}
    txt = _texto_bd(df_total)
    m = df_total["ServiceCategory"].str.contains(CATEGORIA_BD, na=False)
    for padrao, _, _ in ENGINES:
        m = m | txt.str.contains(padrao, na=False)
    bd = df_total[m].copy()
    total_geral = float(df_total["EffectiveCost"].sum())
    if bd.empty:
        return {"resumo": {"total": 0.0, "participacao": 0.0, "moeda": analytics.moeda_de(df_total)}, "vazio": True,
                "mensagem": "Nenhum serviço de banco de dados identificado no período."}

    engines = _texto_bd(bd).map(classificar_engine)
    bd["Engine"] = [e[0] for e in engines]
    bd["TipoBD"] = [e[1] for e in engines]

    total_bd = float(bd["EffectiveCost"].sum())
    comp = analytics.comparar_meses(bd)
    comprometido = float(bd.loc[bd["CommitmentDiscountId"].str.strip() != "", "EffectiveCost"].sum())
    nao_prod = float(bd.loc[bd["Ambiente"] == "Não produção", "EffectiveCost"].sum())

    resumo = {
        "total": total_bd, "participacao": (total_bd / total_geral) if total_geral else 0.0,
        "variacaoMensal": comp["variacao"], "comparacaoParcial": comp["parcial"], "diasComparados": comp["diasComparados"],
        "rotuloMesAnterior": comp["rotuloAnterior"], "mesAnterior": comp["anterior"], "mesAtual": comp["atual"],
        "instancias": int(bd.loc[bd["ResourceName"].str.strip() != "", "ResourceName"].nunique()),
        "engines": int(bd["Engine"].nunique()), "coberturaCompromisso": (comprometido / total_bd) if total_bd else 0.0,
        "custoNaoProducao": nao_prod, "percentualNaoProducao": (nao_prod / total_bd) if total_bd else 0.0,
        "moeda": analytics.moeda_de(bd),
    }
    return {
        "vazio": False, "resumo": resumo,
        "mensal": analytics.serie_mensal(bd), "diario": analytics.serie_diaria(bd),
        "porEngine": analytics.agrupar(bd, "Engine", 15), "porTipo": analytics.agrupar(bd, "TipoBD", 6),
        "porNuvem": analytics.agrupar(bd, "Nuvem", 6), "porAmbiente": analytics.agrupar(bd, "Ambiente", 4),
        "porInstancia": analytics.top_recursos(bd, 30), "evolucaoEngine": analytics.evolucao_por(bd, "Engine", 6),
        "porAssinatura": analytics.agrupar(bd, "SubAccountName", 10),
    }


def dataframe_bancos(df_total) -> pd.DataFrame:
    """Recorte do dado so com bancos, para otimizacao e previsao do dominio."""
    if df_total.empty:
        return df_total
    txt = _texto_bd(df_total)
    m = df_total["ServiceCategory"].str.contains(CATEGORIA_BD, na=False)
    for padrao, _, _ in ENGINES:
        m = m | txt.str.contains(padrao, na=False)
    return df_total[m]


def dataframe_ia(df_total) -> pd.DataFrame:
    if df_total.empty:
        return df_total
    return df_total[mascara_ia(df_total)]
