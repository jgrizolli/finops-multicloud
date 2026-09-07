"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Previsao de custo para 30, 60 e 90 dias.

Metodo, de proposito simples e explicavel:
  1. Pega a serie diaria dos ultimos N dias (padrao 90).
  2. Remove o dia corrente (sempre incompleto) e apara picos acima de 3 desvios, para que um
     incidente isolado nao vire tendencia.
  3. Estima a sazonalidade semanal (fim de semana costuma custar menos).
  4. Ajusta uma reta na serie sem sazonalidade e projeta, devolvendo a sazonalidade.
  5. A faixa de confianca vem do erro residual, e alarga com o horizonte.

Nao e uma rede neural. E uma regressao que o usuario consegue explicar para o CFO.
"""

from __future__ import annotations

from datetime import timedelta

import numpy as np
import pandas as pd

import analytics

Z_80 = 1.2816  # faixa de 80% de confianca


def _serie(df) -> pd.Series:
    if df.empty:
        return pd.Series(dtype=float)
    s = df.groupby(df["Data"].dt.date)["EffectiveCost"].sum().sort_index()
    s.index = pd.to_datetime(s.index)
    # dias sem lancamento contam como zero, senao a reta se inclina para cima artificialmente
    if len(s) > 1:
        s = s.reindex(pd.date_range(s.index.min(), s.index.max(), freq="D"), fill_value=0.0)
    return s


def prever(df, horizonte: int = 90, janela: int = 90) -> dict:
    s = _serie(df)
    vazio = {"historico": [], "previsao": [], "acumulado": {"30": 0.0, "60": 0.0, "90": 0.0}, "mediaDiaria": 0.0,
             "tendenciaMensal": 0.0, "confiabilidade": "insuficiente", "metodo": "regressão linear com sazonalidade semanal",
             "diasUsados": 0, "fimDoMes": 0.0, "proximoMes": 0.0}
    if len(s) < 14:
        vazio["historico"] = [{"data": str(d.date()), "valor": float(v)} for d, v in s.items()]
        return vazio

    # o dia corrente sempre esta incompleto
    if s.index[-1].normalize() >= analytics.hoje():
        s = s.iloc[:-1]
    s = s.tail(janela)
    n = len(s)
    if n < 14:
        return vazio

    y = s.values.astype(float)
    # apara picos: um incidente de tres dias nao pode puxar a reta
    mediana, desvio = np.median(y), np.std(y)
    if desvio > 0:
        y_aparado = np.clip(y, mediana - 3 * desvio, mediana + 3 * desvio)
    else:
        y_aparado = y.copy()

    # sazonalidade semanal, so se houver ao menos quatro semanas
    dias_semana = s.index.dayofweek.values
    fatores = np.ones(7)
    if n >= 28 and y_aparado.mean() > 0:
        for d in range(7):
            sel = y_aparado[dias_semana == d]
            if len(sel):
                fatores[d] = sel.mean() / y_aparado.mean()
        fatores = np.where(fatores <= 0, 1.0, fatores)
    dessaz = y_aparado / fatores[dias_semana]

    x = np.arange(n)
    b, a = np.polyfit(x, dessaz, 1)  # dessaz ~ a + b*x
    ajuste = a + b * x
    residuo = dessaz - ajuste
    sigma = float(np.std(residuo)) if n > 2 else 0.0

    ultimo_dia = s.index[-1]
    previsao = []
    for h in range(1, horizonte + 1):
        dia = ultimo_dia + timedelta(days=h)
        base = a + b * (n - 1 + h)
        valor = max(base * fatores[dia.dayofweek], 0.0)
        largura = Z_80 * sigma * np.sqrt(1 + h / max(n, 1))
        previsao.append({"data": str(dia.date()), "valor": float(valor),
                         "min": float(max(valor - largura, 0.0)), "max": float(valor + largura)})

    def acumular(dias):
        return float(sum(p["valor"] for p in previsao[:dias]))

    media = float(y_aparado.mean())
    tendencia_mensal = (b * 30 / media) if media > 0 else 0.0
    cv = (sigma / media) if media > 0 else 1.0
    confiabilidade = "alta" if (cv < 0.15 and n >= 60) else "média" if (cv < 0.35 and n >= 30) else "baixa"

    # fim do mes corrente e mes seguinte, uteis para orcamento
    hoje = analytics.hoje()
    fim_mes = (hoje.replace(day=1) + pd.DateOffset(months=1)) - timedelta(days=1)
    realizado_mes = float(df[df["Mes"] == hoje.to_period("M").strftime("%Y-%m")]["EffectiveCost"].sum()) if not df.empty else 0.0
    restante_mes = sum(p["valor"] for p in previsao if pd.Timestamp(p["data"]) <= fim_mes and pd.Timestamp(p["data"]) >= hoje)
    ini_prox = fim_mes + timedelta(days=1)
    fim_prox = (ini_prox + pd.DateOffset(months=1)) - timedelta(days=1)
    proximo_mes = sum(p["valor"] for p in previsao if ini_prox <= pd.Timestamp(p["data"]) <= fim_prox)

    return {
        "historico": [{"data": str(d.date()), "valor": float(v)} for d, v in s.items()],
        "previsao": previsao,
        "acumulado": {"30": acumular(30), "60": acumular(60), "90": acumular(90)},
        "mediaDiaria": media, "tendenciaMensal": float(tendencia_mensal), "confiabilidade": confiabilidade,
        "metodo": "regressão linear com sazonalidade semanal", "diasUsados": int(n),
        "fimDoMes": float(realizado_mes + restante_mes), "realizadoMes": realizado_mes, "proximoMes": float(proximo_mes),
        "sigma": sigma,
    }


def prever_workloads(df, dimensao: str = "ServiceName", top: int = 10, horizonte: int = 90) -> list[dict]:
    """Previsao resumida para os N maiores valores de uma dimensao (servico, grupo, assinatura, nuvem)."""
    if df.empty or dimensao not in df.columns:
        return []
    maiores = df.groupby(dimensao)["EffectiveCost"].sum().sort_values(ascending=False).head(top).index
    saida = []
    for nome in maiores:
        rec = df[df[dimensao] == nome]
        p = prever(rec, horizonte=horizonte)
        ult30 = float(rec[rec["Data"] >= analytics.hoje() - timedelta(days=30)]["EffectiveCost"].sum())
        saida.append({"nome": str(nome) or "Não informado", "ultimos30": ult30, "proximos30": p["acumulado"]["30"],
                      "proximos60": p["acumulado"]["60"], "proximos90": p["acumulado"]["90"],
                      "tendenciaMensal": p["tendenciaMensal"], "confiabilidade": p["confiabilidade"]})
    return saida


def dias_ate(valor_alvo: float, previsao: list[dict], realizado: float = 0.0) -> int | None:
    """Em quantos dias o acumulado (realizado + previsto) atinge um valor. None se nao atinge."""
    acumulado = realizado
    for i, p in enumerate(previsao, start=1):
        acumulado += p["valor"]
        if acumulado >= valor_alvo:
            return i
    return None
