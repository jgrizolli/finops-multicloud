"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Agregacoes sobre o dataframe FOCUS.

Regra que vale para o arquivo inteiro: a interface mostra EffectiveCost por padrao (custo
amortizado, o numero para analisar consumo) e expoe BilledCost onde a conversa e de fatura.
"""

from __future__ import annotations

from datetime import datetime

import pandas as pd


def hoje() -> pd.Timestamp:
    return pd.Timestamp.now(tz="UTC").tz_localize(None).normalize()


def aplicar_filtros(df, meses=None, nuvens=None, servicos=None, assinaturas=None, grupos=None, categorias=None, ambientes=None):
    if df.empty:
        return df
    saida = df
    if meses and meses > 0 and "Data" in saida.columns:
        limite = hoje().replace(day=1) - pd.DateOffset(months=meses - 1)
        saida = saida[saida["Data"] >= limite]
    for coluna, valores in (("Nuvem", nuvens), ("ServiceName", servicos), ("SubAccountName", assinaturas),
                            ("ResourceGroupName", grupos), ("ServiceCategory", categorias), ("Ambiente", ambientes)):
        if valores and coluna in saida.columns:
            saida = saida[saida[coluna].isin(valores)]
    return saida


def moeda_de(df) -> str:
    if df.empty or "BillingCurrency" not in df.columns:
        return "USD"
    m = df["BillingCurrency"].dropna().unique()
    return str(m[0]) if len(m) else "USD"


def comparar_meses(df) -> dict:
    """
    Compara o mes corrente com o anterior de forma honesta.

    O mes corrente esta aberto: no dia 3 ele tem 3 dias de custo e o anterior tem 30.
    Comparar os valores brutos produz uma "queda" enorme que nao existe. A comparacao
    correta e mes ate a data contra o MESMO intervalo de dias do mes anterior.
    """
    vazio = {"atual": 0.0, "anterior": 0.0, "variacao": 0.0, "atualCheio": 0.0, "anteriorCheio": 0.0,
             "parcial": False, "diasComparados": 0, "rotuloAtual": "", "rotuloAnterior": ""}
    if df.empty or "Mes" not in df.columns:
        return vazio
    por_mes = df.groupby("Mes")["EffectiveCost"].sum().sort_index()
    if len(por_mes) < 2:
        return vazio

    rot_atual, rot_anterior = por_mes.index[-1], por_mes.index[-2]
    cheio_atual, cheio_anterior = float(por_mes.iloc[-1]), float(por_mes.iloc[-2])
    do_atual = df[df["Mes"] == rot_atual]
    dias_atual = int(do_atual["Data"].dt.day.max()) if not do_atual.empty else 0
    aberto = rot_atual == hoje().to_period("M").strftime("%Y-%m")

    if aberto and dias_atual > 0:
        base = float(df[(df["Mes"] == rot_anterior) & (df["Data"].dt.day <= dias_atual)]["EffectiveCost"].sum())
        parcial = True
    else:
        base, parcial, dias_atual = cheio_anterior, False, 0

    return {"atual": cheio_atual, "anterior": base, "variacao": ((cheio_atual - base) / base) if base > 0 else 0.0,
            "atualCheio": cheio_atual, "anteriorCheio": cheio_anterior, "parcial": parcial,
            "diasComparados": dias_atual, "rotuloAtual": str(rot_atual), "rotuloAnterior": str(rot_anterior)}


def resumo(df) -> dict:
    """KPIs do topo da tela."""
    base = {"custoEfetivo": 0.0, "custoFaturado": 0.0, "custoLista": 0.0, "economia": 0.0, "percentualEconomia": 0.0,
            "mesAtual": 0.0, "mesAnterior": 0.0, "mesAnteriorCheio": 0.0, "variacaoMensal": 0.0, "comparacaoParcial": False,
            "diasComparados": 0, "rotuloMesAtual": "", "rotuloMesAnterior": "", "projecaoMes": 0.0,
            "recursos": 0, "servicos": 0, "nuvens": 0, "moeda": "USD", "linhas": 0}
    if df.empty:
        return base

    efetivo, faturado, lista = float(df["EffectiveCost"].sum()), float(df["BilledCost"].sum()), float(df["ListCost"].sum())
    economia = max(lista - efetivo, 0.0)
    por_mes = df.groupby("Mes")["EffectiveCost"].sum().sort_index()
    mes_atual = float(por_mes.iloc[-1]) if len(por_mes) else 0.0
    comp = comparar_meses(df)

    projecao = 0.0
    if len(por_mes):
        rotulo = por_mes.index[-1]
        dias_com_dado = df[df["Mes"] == rotulo]["Data"].dt.date.nunique()
        if dias_com_dado:
            ano, mes = (int(p) for p in rotulo.split("-"))
            proximo = datetime(ano + (mes == 12), (mes % 12) + 1, 1)
            projecao = (mes_atual / dias_com_dado) * (proximo - datetime(ano, mes, 1)).days

    base.update({
        "custoEfetivo": efetivo, "custoFaturado": faturado, "custoLista": lista, "economia": economia,
        "percentualEconomia": (economia / lista) if lista else 0.0,
        "mesAtual": mes_atual, "mesAnterior": comp["anterior"], "mesAnteriorCheio": comp["anteriorCheio"],
        "variacaoMensal": comp["variacao"], "comparacaoParcial": comp["parcial"], "diasComparados": comp["diasComparados"],
        "rotuloMesAtual": comp["rotuloAtual"], "rotuloMesAnterior": comp["rotuloAnterior"], "projecaoMes": projecao,
        "recursos": int(df.loc[df["ResourceName"].str.strip() != "", "ResourceName"].nunique()),
        "servicos": int(df["ServiceName"].nunique()), "nuvens": int(df["Nuvem"].nunique()),
        "moeda": moeda_de(df), "linhas": int(len(df)),
    })
    return base


def serie_diaria(df) -> list[dict]:
    if df.empty:
        return []
    s = df.groupby(df["Data"].dt.date).agg(efetivo=("EffectiveCost", "sum"), faturado=("BilledCost", "sum")).sort_index()
    return [{"data": str(d), "efetivo": float(r.efetivo), "faturado": float(r.faturado)} for d, r in s.iterrows()]


def serie_mensal(df) -> list[dict]:
    if df.empty:
        return []
    s = df.groupby("Mes").agg(efetivo=("EffectiveCost", "sum"), faturado=("BilledCost", "sum"), lista=("ListCost", "sum")).sort_index()
    return [{"mes": m, "efetivo": float(r.efetivo), "faturado": float(r.faturado), "lista": float(r.lista),
             "economia": float(max(r.lista - r.efetivo, 0))} for m, r in s.iterrows()]


def agrupar(df, coluna, limite=15, metrica="EffectiveCost") -> list[dict]:
    """Top N por custo, com o restante somado em 'Outros'."""
    if df.empty or coluna not in df.columns:
        return []
    s = (df.groupby(coluna).agg(efetivo=(metrica, "sum"), faturado=("BilledCost", "sum"), linhas=(metrica, "size"))
         .sort_values("efetivo", ascending=False))
    s = s[s["efetivo"] > 0]
    itens = [{"nome": str(n) if str(n).strip() else "Não informado", "efetivo": float(r.efetivo),
              "faturado": float(r.faturado), "linhas": int(r.linhas)} for n, r in s.head(limite).iterrows()]
    if len(s) > limite:
        resto = s.iloc[limite:]
        itens.append({"nome": f"Outros ({len(resto)})", "efetivo": float(resto["efetivo"].sum()),
                      "faturado": float(resto["faturado"].sum()), "linhas": int(resto["linhas"].sum())})
    return itens


def evolucao_por(df, coluna, limite=6) -> dict:
    """Serie mensal empilhada dos N maiores valores de uma dimensao."""
    if df.empty or coluna not in df.columns:
        return {"meses": [], "series": []}
    maiores = df.groupby(coluna)["EffectiveCost"].sum().sort_values(ascending=False).head(limite).index.tolist()
    tabela = (df[df[coluna].isin(maiores)]
              .pivot_table(index="Mes", columns=coluna, values="EffectiveCost", aggfunc="sum", fill_value=0).sort_index())
    return {"meses": [str(m) for m in tabela.index],
            "series": [{"nome": str(c), "valores": [float(v) for v in tabela[c]]} for c in tabela.columns]}


def top_recursos(df, limite=25) -> list[dict]:
    if df.empty:
        return []
    r = df[df["ResourceName"].str.strip() != ""]
    if r.empty:
        return []
    s = (r.groupby(["ResourceName", "ServiceName", "ResourceGroupName", "RegionName", "Nuvem", "Ambiente"])
         .agg(efetivo=("EffectiveCost", "sum"), lista=("ListCost", "sum")).sort_values("efetivo", ascending=False).head(limite))
    return [{"recurso": i[0], "servico": i[1], "grupo": i[2] or "Não informado", "regiao": i[3], "nuvem": i[4],
             "ambiente": i[5], "efetivo": float(x.efetivo), "economia": float(max(x.lista - x.efetivo, 0))}
            for i, x in s.iterrows()]


def filtros_disponiveis(df) -> dict:
    vazio = {"nuvens": [], "servicos": [], "assinaturas": [], "grupos": [], "categorias": [], "ambientes": [], "meses": []}
    if df.empty:
        return vazio

    def valores(col, limite=200):
        if col not in df.columns:
            return []
        ordem = df.groupby(col)["EffectiveCost"].sum().sort_values(ascending=False)
        return [str(v) for v in ordem.head(limite).index if str(v).strip()]

    return {"nuvens": valores("Nuvem"), "servicos": valores("ServiceName"), "assinaturas": valores("SubAccountName"),
            "grupos": valores("ResourceGroupName"), "categorias": valores("ServiceCategory"),
            "ambientes": valores("Ambiente"), "meses": sorted(m for m in df["Mes"].unique() if m)}


def qualidade(df, meses_disponiveis) -> dict:
    """Sinais de saude do dado, equivalente a pagina DQ dos relatorios do toolkit."""
    if df.empty:
        return {"meses": [], "atrasoDias": None, "ultimoDia": None, "semRecurso": 0, "semTag": 0, "moedas": [], "porNuvem": []}
    ultimo = df["Data"].max()
    atraso = (hoje() - ultimo).days if pd.notna(ultimo) else None
    pn = (df.groupby("Nuvem").agg(linhas=("EffectiveCost", "size"), efetivo=("EffectiveCost", "sum"), ultimo=("Data", "max"))
          .sort_values("efetivo", ascending=False))
    return {
        "meses": meses_disponiveis, "atrasoDias": int(atraso) if atraso is not None else None,
        "ultimoDia": str(ultimo.date()) if pd.notna(ultimo) else None,
        "semRecurso": int((df["ResourceName"].str.strip() == "").sum()), "semTag": int(df["SemTag"].sum()),
        "moedas": [str(m) for m in df["BillingCurrency"].dropna().unique()],
        "porNuvem": [{"nuvem": str(n), "linhas": int(r.linhas), "efetivo": float(r.efetivo),
                      "ultimoDia": str(r.ultimo.date()) if pd.notna(r.ultimo) else None} for n, r in pn.iterrows()],
    }
