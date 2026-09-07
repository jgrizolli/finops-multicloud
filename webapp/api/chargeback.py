"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Showback e chargeback: quem gastou o que.

Centro de custo (a "area" que sera cobrada) e um cadastro com regras de alocacao:
  {id, nome, responsavel, email, orcamentoMensal, regras: [{tipo, chave, valor}]}
  tipo: tag | assinatura | grupo | nuvem | servico
Cada linha de custo e atribuida ao PRIMEIRO centro cuja regra bate, na ordem do cadastro.
O que nao bate em ninguem vira "Não alocado".

Showback   mostra o custo direto de cada area, sem redistribuir nada.
Chargeback mostra o valor a cobrar: custo direto mais a fatia do custo compartilhado
           (o nao alocado), distribuida proporcionalmente ao custo direto de cada area.

Cadastro: manual pela interface, ou em lote via importacao (JSON ou CSV). A importacao e o
ponto de integracao com CMDB: um job que consulta o CMDB e envia o resultado para
POST /api/centros-custo/importar mantem o cadastro sincronizado.
"""

from __future__ import annotations

import csv
import io
import json

import pandas as pd

import analytics
import governance

NAO_ALOCADO = "Não alocado"


def _mascara_regra(df, regra: dict, tags_por_string: dict) -> pd.Series:
    tipo = (regra.get("tipo") or "").lower()
    valor = str(regra.get("valor") or "").strip()
    chave = str(regra.get("chave") or "").strip()
    if not valor and tipo != "tag":
        return pd.Series(False, index=df.index)

    if tipo == "tag":
        # bate quando a tag existe com o valor dado; valor "*" aceita qualquer valor
        alvo = {s for s, t in tags_por_string.items() if chave in t and (valor in ("*", "") or str(t[chave]).lower() == valor.lower())}
        return df["TagsStr"].isin(alvo)
    coluna = {"assinatura": "SubAccountName", "grupo": "ResourceGroupName", "nuvem": "Nuvem", "servico": "ServiceName",
              "conta": "BillingAccountName"}.get(tipo)
    if not coluna:
        return pd.Series(False, index=df.index)
    if valor.endswith("*"):
        return df[coluna].str.lower().str.startswith(valor[:-1].lower())
    return df[coluna].str.lower() == valor.lower()


def alocar(df, centros: list[dict], tags_por_string: dict) -> pd.Series:
    """Devolve uma Series com o nome do centro de cada linha."""
    resultado = pd.Series(NAO_ALOCADO, index=df.index, dtype=object)
    livre = pd.Series(True, index=df.index)
    for c in centros:
        if not c.get("ativo", True):
            continue
        m = pd.Series(False, index=df.index)
        for regra in c.get("regras", []):
            m = m | _mascara_regra(df, regra, tags_por_string)
        pega = m & livre
        resultado[pega] = c.get("nome", c.get("id"))
        livre = livre & ~pega
    return resultado


def centros_automaticos(df, tags_por_string: dict) -> list[dict]:
    """Sem cadastro, propoe centros a partir da tag de centro de custo mais comum."""
    longa = governance.tabela_longa(df, tags_por_string)
    chave = governance.chave_padrao(longa)
    if not chave:
        return []
    valores = longa[longa["chave"] == chave].sort_values("efetivo", ascending=False).head(30)
    return [{"id": f"auto-{i}", "nome": str(r.valor) or "(vazio)", "responsavel": "", "email": "", "orcamentoMensal": 0,
             "automatico": True, "regras": [{"tipo": "tag", "chave": chave, "valor": str(r.valor)}]}
            for i, (_, r) in enumerate(valores.iterrows())]


def analisar(df, centros: list[dict], tags_por_string: dict, distribuir_compartilhado: bool = True) -> dict:
    if df.empty:
        return {"resumo": {}, "centros": [], "mensal": {"meses": [], "series": []}, "automatico": False}

    automatico = False
    if not centros:
        centros = centros_automaticos(df, tags_por_string)
        automatico = True

    df = df.copy()
    df["Centro"] = alocar(df, centros, tags_por_string)
    total = float(df["EffectiveCost"].sum())
    direto = df.groupby("Centro")["EffectiveCost"].sum()
    compartilhado = float(direto.get(NAO_ALOCADO, 0.0))
    base_alocada = float(direto.drop(NAO_ALOCADO, errors="ignore").sum())

    mes_corrente = analytics.hoje().to_period("M").strftime("%Y-%m")
    do_mes = df[df["Mes"] == mes_corrente].groupby("Centro")["EffectiveCost"].sum()
    faturado = df.groupby("Centro")["BilledCost"].sum()
    por_centro_info = {c.get("nome", c.get("id")): c for c in centros}

    linhas = []
    for nome, valor in direto.sort_values(ascending=False).items():
        valor = float(valor)
        info = por_centro_info.get(nome, {})
        if nome == NAO_ALOCADO:
            rateio = 0.0
        else:
            rateio = (compartilhado * valor / base_alocada) if (distribuir_compartilhado and base_alocada > 0) else 0.0
        orcamento = float(info.get("orcamentoMensal") or 0)
        gasto_mes = float(do_mes.get(nome, 0.0))
        linhas.append({
            "centro": nome, "responsavel": info.get("responsavel", ""), "email": info.get("email", ""),
            "direto": valor, "rateio": rateio, "cobrar": valor + rateio, "faturado": float(faturado.get(nome, 0.0)),
            "participacao": (valor / total) if total else 0.0,
            "orcamentoMensal": orcamento, "gastoMes": gasto_mes, "usoOrcamento": (gasto_mes / orcamento) if orcamento else None,
            "regras": info.get("regras", []), "id": info.get("id"),
        })

    # detalhe por servico dentro de cada centro (top 5), util para a fatura interna
    detalhe = {}
    for nome, g in df.groupby("Centro"):
        s = g.groupby("ServiceName")["EffectiveCost"].sum().sort_values(ascending=False).head(6)
        detalhe[nome] = [{"servico": k, "efetivo": float(v)} for k, v in s.items()]

    resumo = {
        "total": total, "alocado": base_alocada, "naoAlocado": compartilhado,
        "percentualAlocado": (base_alocada / total) if total else 0.0, "centros": int(len(direto.drop(NAO_ALOCADO, errors="ignore"))),
        "moeda": analytics.moeda_de(df), "distribuirCompartilhado": distribuir_compartilhado, "mesCorrente": mes_corrente,
    }
    return {"resumo": resumo, "centros": linhas, "detalhe": detalhe,
            "mensal": analytics.evolucao_por(df, "Centro", limite=8), "automatico": automatico,
            "chaveAutomatica": centros[0]["regras"][0]["chave"] if (automatico and centros) else None}


def importar(conteudo: str, formato: str = "json") -> list[dict]:
    """Converte JSON ou CSV em lista de centros. Formato CSV: nome,responsavel,email,orcamentoMensal,tipo,chave,valor."""
    if formato == "csv":
        leitor = csv.DictReader(io.StringIO(conteudo))
        centros: dict[str, dict] = {}
        for linha in leitor:
            nome = (linha.get("nome") or "").strip()
            if not nome:
                continue
            c = centros.setdefault(nome, {"nome": nome, "responsavel": linha.get("responsavel", ""), "email": linha.get("email", ""),
                                          "orcamentoMensal": float(linha.get("orcamentoMensal") or 0), "regras": []})
            if linha.get("tipo"):
                c["regras"].append({"tipo": linha["tipo"].strip().lower(), "chave": (linha.get("chave") or "").strip(), "valor": (linha.get("valor") or "").strip()})
        return list(centros.values())
    dados = json.loads(conteudo)
    if isinstance(dados, dict) and "centros" in dados:
        dados = dados["centros"]
    if not isinstance(dados, list):
        raise ValueError("Esperava uma lista de centros de custo.")
    saida = []
    for d in dados:
        if not isinstance(d, dict) or not d.get("nome"):
            continue
        saida.append({"id": d.get("id"), "nome": d["nome"], "responsavel": d.get("responsavel", ""), "email": d.get("email", ""),
                      "orcamentoMensal": float(d.get("orcamentoMensal") or 0), "ativo": d.get("ativo", True),
                      "regras": [r for r in d.get("regras", []) if isinstance(r, dict) and r.get("tipo")]})
    return saida
