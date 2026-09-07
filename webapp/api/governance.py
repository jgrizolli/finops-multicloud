"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Governanca: cobertura de etiquetas, recursos sem etiqueta, custo por etiqueta e orcamento
por etiqueta. E aqui que se mede se a organizacao consegue atribuir custo a alguem.
"""

from __future__ import annotations

import pandas as pd

import analytics

# Chaves de tag que costumam carregar o centro de custo. A primeira encontrada vira padrao.
CHAVES_CENTRO = ("CostCenter", "costcenter", "cost-center", "cost_center", "centro", "CentroDeCusto", "centro_custo", "CC")
CHAVES_AMBIENTE = ("Environment", "environment", "env", "ambiente", "Stage")
CHAVES_DONO = ("Owner", "owner", "dono", "responsavel", "Responsavel", "team", "Team", "time")

TAGS_OBRIGATORIAS_PADRAO = ["CostCenter", "Environment", "Owner"]


def _custo_por_tagstr(df) -> pd.DataFrame:
    """Custo somado por string de tags. Parse uma vez por string, nao por linha."""
    return df.groupby("TagsStr").agg(efetivo=("EffectiveCost", "sum"), linhas=("EffectiveCost", "size"),
                                     recursos=("ResourceName", "nunique"))


def tabela_longa(df, tags_por_string: dict) -> pd.DataFrame:
    """(chave, valor, efetivo, linhas) para cada par de tag presente no dado."""
    if df.empty:
        return pd.DataFrame(columns=["chave", "valor", "efetivo", "linhas"])
    base = _custo_por_tagstr(df)
    linhas = []
    for tags_str, r in base.iterrows():
        for k, v in tags_por_string.get(tags_str, {}).items():
            linhas.append((k, v, float(r.efetivo), int(r.linhas)))
    if not linhas:
        return pd.DataFrame(columns=["chave", "valor", "efetivo", "linhas"])
    t = pd.DataFrame(linhas, columns=["chave", "valor", "efetivo", "linhas"])
    return t.groupby(["chave", "valor"], as_index=False).sum()


def chave_padrao(longa: pd.DataFrame, candidatas=CHAVES_CENTRO) -> str | None:
    if longa.empty:
        return None
    presentes = set(longa["chave"].unique())
    for c in candidatas:
        if c in presentes:
            return c
    # sem candidata conhecida: a chave com maior custo coberto
    return str(longa.groupby("chave")["efetivo"].sum().idxmax())


def analisar(df, tags_por_string: dict, tag_selecionada: str | None = None, obrigatorias: list[str] | None = None,
             orcamentos: list[dict] | None = None) -> dict:
    if df.empty:
        return {"resumo": {}, "cobertura": [], "porValor": [], "semTag": [], "conformidade": [],
                "ambientes": [], "orcamentosTag": [], "chave": None, "chavesDisponiveis": []}

    total = float(df["EffectiveCost"].sum())
    longa = tabela_longa(df, tags_por_string)
    obrigatorias = obrigatorias or TAGS_OBRIGATORIAS_PADRAO

    sem_tag = df[df["SemTag"]]
    custo_sem_tag = float(sem_tag["EffectiveCost"].sum())

    # cobertura por chave: quanto do custo total tem aquela chave
    cobertura = []
    if not longa.empty:
        por_chave = longa.groupby("chave").agg(efetivo=("efetivo", "sum"), valores=("valor", "nunique")).sort_values("efetivo", ascending=False)
        for k, r in por_chave.head(25).iterrows():
            cobertura.append({"chave": str(k), "efetivo": float(r.efetivo), "cobertura": (float(r.efetivo) / total) if total else 0.0,
                              "valoresDistintos": int(r.valores)})

    chave = tag_selecionada if (tag_selecionada and not longa.empty and tag_selecionada in set(longa["chave"])) else chave_padrao(longa)
    por_valor = []
    if chave:
        pv = longa[longa["chave"] == chave].sort_values("efetivo", ascending=False)
        for _, r in pv.head(20).iterrows():
            por_valor.append({"valor": str(r.valor) or "(vazio)", "efetivo": float(r.efetivo),
                              "participacao": (float(r.efetivo) / total) if total else 0.0, "linhas": int(r.linhas)})
        coberto = float(pv["efetivo"].sum())
        if total - coberto > 0.005:
            por_valor.append({"valor": f"(sem a tag {chave})", "efetivo": float(total - coberto),
                              "participacao": ((total - coberto) / total) if total else 0.0, "linhas": 0})

    # conformidade: por tag obrigatoria, quanto do custo esta coberto
    conformidade = []
    for k in obrigatorias:
        cob = float(longa[longa["chave"] == k]["efetivo"].sum()) if not longa.empty else 0.0
        conformidade.append({"chave": k, "coberto": cob, "descoberto": max(total - cob, 0.0),
                             "percentual": (cob / total) if total else 0.0})

    # recursos sem tag, os mais caros
    top_sem_tag = []
    if not sem_tag.empty:
        s = (sem_tag[sem_tag["ResourceName"].str.strip() != ""]
             .groupby(["ResourceName", "ServiceName", "ResourceGroupName", "SubAccountName", "Nuvem"])["EffectiveCost"]
             .sum().sort_values(ascending=False).head(30))
        top_sem_tag = [{"recurso": i[0], "servico": i[1], "grupo": i[2] or "Não informado", "assinatura": i[3],
                        "nuvem": i[4], "efetivo": float(v)} for i, v in s.items()]

    # distribuicao por ambiente (coluna derivada, considera tags e nomes)
    ambientes = analytics.agrupar(df, "Ambiente", limite=5)

    # orcamentos por tag: compara o gasto do mes corrente com o orcamento cadastrado
    orcamentos_tag = []
    mes_corrente = analytics.hoje().to_period("M").strftime("%Y-%m")
    do_mes = df[df["Mes"] == mes_corrente]
    longa_mes = tabela_longa(do_mes, tags_por_string) if not do_mes.empty else longa.iloc[0:0]
    for o in (orcamentos or []):
        if o.get("escopoTipo") != "tag":
            continue
        k, v = o.get("chave", ""), str(o.get("valor", ""))
        gasto = float(longa_mes[(longa_mes["chave"] == k) & (longa_mes["valor"] == v)]["efetivo"].sum()) if not longa_mes.empty else 0.0
        limite = float(o.get("valorMensal") or 0)
        orcamentos_tag.append({"id": o.get("id"), "nome": o.get("nome") or f"{k}={v}", "chave": k, "valor": v,
                               "orcamento": limite, "gasto": gasto, "uso": (gasto / limite) if limite else 0.0,
                               "mes": mes_corrente})

    resumo = {
        "total": total, "comTag": total - custo_sem_tag, "semTag": custo_sem_tag,
        "percentualSemTag": (custo_sem_tag / total) if total else 0.0,
        "recursosSemTag": int(sem_tag.loc[sem_tag["ResourceName"].str.strip() != "", "ResourceName"].nunique()),
        "chavesDistintas": int(longa["chave"].nunique()) if not longa.empty else 0,
        "moeda": analytics.moeda_de(df),
        "conformidadeMedia": (sum(c["percentual"] for c in conformidade) / len(conformidade)) if conformidade else 0.0,
    }
    return {"resumo": resumo, "cobertura": cobertura, "porValor": por_valor, "semTag": top_sem_tag,
            "conformidade": conformidade, "ambientes": ambientes, "orcamentosTag": orcamentos_tag,
            "chave": chave, "chavesDisponiveis": [c["chave"] for c in cobertura], "obrigatorias": obrigatorias}
