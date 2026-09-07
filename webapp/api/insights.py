"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Analise automatica sobre o dado FOCUS.

Nao ha modelo de linguagem nem chamada externa. Sao regras estatisticas deterministicas
sobre o seu proprio dado: o resultado e explicavel, roda offline, nao custa token e nao
envia dado nenhum para fora da assinatura.
"""

from __future__ import annotations

import pandas as pd

import analytics


def _fmt(v: float, moeda: str = "USD") -> str:
    return f"{ {'USD': 'US$', 'BRL': 'R$', 'EUR': 'EUR'}.get(moeda, moeda) } {v:,.2f}"


def _achado(severidade, titulo, detalhe, valor=None, acao=None, categoria="Custo"):
    return {"severidade": severidade, "titulo": titulo, "detalhe": detalhe, "valor": valor, "acao": acao, "categoria": categoria}


def _variacao_mensal(df, moeda):
    c = analytics.comparar_meses(df)
    if c["anterior"] <= 0:
        return []
    v = c["variacao"]
    janela = f" Comparação dos primeiros {c['diasComparados']} dias de cada mês, porque o mês corrente ainda está aberto." if c["parcial"] else ""
    if abs(v) < 0.10:
        return [_achado("positivo", "Custo estável entre os dois últimos meses",
                        f"Variação de {v:+.1%}, de {_fmt(c['anterior'], moeda)} para {_fmt(c['atual'], moeda)}.{janela}", categoria="Tendência")]
    sev = "critico" if v > 0.30 else "atencao" if v > 0 else "positivo"
    return [_achado(sev, f"O custo {'aumentou' if v > 0 else 'caiu'} {abs(v):.1%} em relação ao mês anterior",
                    f"De {_fmt(c['anterior'], moeda)} para {_fmt(c['atual'], moeda)}, diferença de {_fmt(abs(c['atual'] - c['anterior']), moeda)}.{janela}",
                    valor=abs(c["atual"] - c["anterior"]),
                    acao="Compare os serviços entre os dois meses para achar a origem." if v > 0 else "Confirme que a queda é intencional e não perda de dado.",
                    categoria="Tendência")]


def _servicos_que_cresceram(df, moeda):
    meses = sorted(m for m in df["Mes"].unique() if m)
    if len(meses) < 2:
        return []
    atual, anterior = meses[-1], meses[-2]
    rec = df[df["Mes"].isin([anterior, atual])]
    if atual == analytics.hoje().to_period("M").strftime("%Y-%m"):
        do_atual = rec[rec["Mes"] == atual]
        if not do_atual.empty:
            dias = int(do_atual["Data"].dt.day.max())
            rec = rec[(rec["Mes"] == atual) | (rec["Data"].dt.day <= dias)]
    t = rec.pivot_table(index="ServiceName", columns="Mes", values="EffectiveCost", aggfunc="sum", fill_value=0)
    if anterior not in t.columns or atual not in t.columns:
        return []
    t["delta"] = t[atual] - t[anterior]
    total_ant = t[anterior].sum()
    if total_ant <= 0:
        return []
    saida = []
    for servico, r in t.sort_values("delta", ascending=False).head(5).iterrows():
        base, agora, delta = float(r[anterior]), float(r[atual]), float(r["delta"])
        if delta <= 0 or base <= 0:
            continue
        pct, peso = delta / base, delta / total_ant
        if pct < 0.20 or peso < 0.02:  # os dois filtros evitam alarme por servico que dobrou de centavos
            continue
        saida.append(_achado("critico" if pct > 1.0 else "atencao", f"{servico} cresceu {pct:.0%}",
                             f"De {_fmt(base, moeda)} para {_fmt(agora, moeda)} no mesmo intervalo de dias, diferença de {_fmt(delta, moeda)}.",
                             valor=delta, acao=f"Verifique o que mudou em {servico}: novos recursos, SKU ou aumento de uso.", categoria="Tendência"))
    return saida


def _concentracao(df, moeda):
    total = float(df["EffectiveCost"].sum())
    if total <= 0:
        return []
    ps = df.groupby("ServiceName")["EffectiveCost"].sum().sort_values(ascending=False)
    lider, v = ps.index[0], float(ps.iloc[0])
    saida = [_achado("informativo", f"{lider} concentra {v / total:.0%} do gasto",
                     f"{_fmt(v, moeda)} de {_fmt(total, moeda)}. Os três maiores serviços somam {float(ps.head(3).sum()) / total:.0%}.",
                     valor=v, acao=f"Otimizar {lider} tem o maior efeito no resultado.", categoria="Distribuição")]
    cauda = ps[ps / total < 0.01]
    if len(cauda) >= 10:
        saida.append(_achado("informativo", f"{len(cauda)} serviços representam menos de 1% cada",
                             f"Juntos somam {_fmt(float(cauda.sum()), moeda)}. O conjunto costuma esconder recurso esquecido.",
                             valor=float(cauda.sum()), acao="Reveja a cauda longa em busca de recurso órfão.", categoria="Distribuição"))
    return saida


def _anomalias(df, moeda):
    s = df.groupby(df["Data"].dt.date)["EffectiveCost"].sum().sort_index()
    if len(s) < 15:
        return []
    s = s.iloc[:-1]
    media, desvio = s.mean(), s.std()
    if not desvio or desvio <= 0:
        return []
    return [_achado("atencao", f"Pico de custo em {dia}", f"{_fmt(float(v), moeda)} contra média de {_fmt(float(media), moeda)}, {v / media:.1f} vezes o normal.",
                    valor=float(v - media), acao="Cheque o que foi criado ou escalado nesse dia.", categoria="Anomalia")
            for dia, v in s[s > media + 3 * desvio].tail(3).items()]


def _compromissos(df, moeda):
    saida = []
    ocioso = df[df["CommitmentDiscountStatus"].str.lower() == "unused"]
    v = float(ocioso["EffectiveCost"].sum())
    if v > 0:
        saida.append(_achado("critico", "Compromisso comprado e não consumido", f"{_fmt(v, moeda)} em reservas ou savings plans sem uso. Dinheiro já pago sem contrapartida.",
                             valor=v, acao="Reavalie escopo e família, ou troque o compromisso.", categoria="Compromissos"))
    total = float(df["EffectiveCost"].sum())
    if total > 0:
        coberto = float(df.loc[df["CommitmentDiscountId"].str.strip() != "", "EffectiveCost"].sum())
        cob = coberto / total
        if cob < 0.20:
            saida.append(_achado("atencao", f"Apenas {cob:.0%} do gasto está coberto por compromisso",
                                 f"{_fmt(total - coberto, moeda)} em preço sob demanda. Reservas reduzem de 20% a 60% em cargas estáveis.",
                                 valor=(total - coberto) * 0.30, acao="Simule reservas para as cargas constantes dos últimos 30 dias.", categoria="Compromissos"))
        elif cob > 0.70:
            saida.append(_achado("positivo", f"{cob:.0%} do gasto está coberto por compromisso", f"{_fmt(coberto, moeda)} passam por reserva ou savings plan.", categoria="Compromissos"))
    return saida


def _economia(df, moeda):
    lista, efetivo = float(df["ListCost"].sum()), float(df["EffectiveCost"].sum())
    if lista <= 0 or lista - efetivo <= 0:
        return []
    return [_achado("positivo", f"Você economizou {(lista - efetivo) / lista:.1%} sobre o preço de tabela",
                    f"{_fmt(lista - efetivo, moeda)} de desconto sobre {_fmt(lista, moeda)}.", valor=lista - efetivo, categoria="Economia")]


def _sem_tag(df, moeda):
    total = float(df["EffectiveCost"].sum())
    v = float(df.loc[df["SemTag"], "EffectiveCost"].sum())
    if total <= 0 or v / total < 0.20:
        return []
    return [_achado("atencao", f"{v / total:.0%} do gasto não tem etiqueta", f"{_fmt(v, moeda)} sem nenhuma tag. Sem etiqueta não existe chargeback confiável.",
                    valor=v, acao="Defina tags obrigatórias e aplique com política.", categoria="Governança")]


def _nao_producao(df, moeda):
    total = float(df["EffectiveCost"].sum())
    v = float(df.loc[df["Ambiente"] == "Não produção", "EffectiveCost"].sum())
    if total <= 0 or v / total < 0.30:
        return []
    return [_achado("atencao", f"{v / total:.0%} do gasto é de ambientes não produtivos",
                    f"{_fmt(v, moeda)} em dev, teste e homologação. Referência de mercado: entre 15% e 25%.",
                    valor=v * 0.3, acao="Auto-shutdown, SKUs menores e limpeza de ambientes antigos.", categoria="Ambientes")]


def _multicloud(df, moeda):
    pn = df.groupby("Nuvem")["EffectiveCost"].sum().sort_values(ascending=False)
    if len(pn) < 2:
        return []
    total = float(pn.sum())
    return [_achado("informativo", f"Gasto distribuído em {len(pn)} nuvens",
                    f"{', '.join(f'{n} {float(v) / total:.0%}' for n, v in pn.items())}. Total de {_fmt(total, moeda)}.", categoria="Multicloud")]


ORDEM = {"critico": 0, "atencao": 1, "informativo": 2, "positivo": 3}


def gerar(df, moeda: str = "USD") -> list[dict]:
    if df.empty:
        return [_achado("informativo", "Sem dados para analisar", "Nenhuma linha de custo no período. Ajuste os filtros ou confira a ingestão.", categoria="Dados")]
    achados = []
    for a in (_variacao_mensal, _servicos_que_cresceram, _anomalias, _compromissos, _concentracao, _economia, _sem_tag, _nao_producao, _multicloud):
        try:
            achados.extend(a(df, moeda))
        except Exception:  # noqa: BLE001
            continue
    achados.sort(key=lambda a: (ORDEM.get(a["severidade"], 9), -(a.get("valor") or 0)))
    return achados
