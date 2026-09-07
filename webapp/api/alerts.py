"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Alertas: regras que observam o dado e abrem ocorrencias quando algo sai do controle.

Regra (cadastro):
  {id, nome, tipo, limiar, escopoTipo, escopoValor, severidade, destinatarios[], ativo}
  tipos: orcamento | pico_diario | crescimento_mensal | previsao | sem_tag | compromisso_ocioso | novo_servico

Alerta (ocorrencia):
  {id, regraId, regraNome, tipo, severidade, titulo, detalhe, valor, valorFormatado, acao,
   escopo, chave, estado, abertoEm, atualizadoEm, comentario, notificado}
  estados: aberto -> reconhecido -> resolvido (ou descartado)

Deduplicacao: cada alerta tem uma chave. Se ja existe um alerta aberto ou reconhecido com a
mesma chave, a avaliacao atualiza o valor em vez de abrir outro. Assim o painel nao enche de
repeticoes e o e-mail sai uma vez por ocorrencia.

Resolucao automatica: alertas de condicao (sem tag, compromisso ocioso, orcamento) fecham
sozinhos quando a condicao deixa de valer. Alertas de evento (pico) ficam abertos ate alguem
tratar.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

import pandas as pd

import analytics
import forecast
import notifications
from state_store import StateStore, agora_iso

log = logging.getLogger("finops.alerts")

TIPOS = {
    "orcamento": {"nome": "Orçamento", "descricao": "Gasto do mês (realizado ou projetado) acima do orçamento", "unidade": "valor"},
    "pico_diario": {"nome": "Pico diário", "descricao": "Custo de um dia acima de N desvios padrão da média", "unidade": "desvios"},
    "crescimento_mensal": {"nome": "Crescimento mensal", "descricao": "Mês até a data acima de X% em relação ao mesmo período do mês anterior", "unidade": "percentual"},
    "previsao": {"nome": "Previsão", "descricao": "Projeção dos próximos 30 dias acima de um valor", "unidade": "valor"},
    "sem_tag": {"nome": "Sem etiqueta", "descricao": "Percentual do gasto sem tag acima de X%", "unidade": "percentual"},
    "compromisso_ocioso": {"nome": "Compromisso ocioso", "descricao": "Reserva ou savings plan sem uso acima de um valor", "unidade": "valor"},
    "novo_servico": {"nome": "Novo serviço", "descricao": "Serviço que não existia nos 30 dias anteriores e já custa mais que X", "unidade": "valor"},
}

ESCOPOS = {"total": None, "nuvem": "Nuvem", "assinatura": "SubAccountName", "grupo": "ResourceGroupName",
           "servico": "ServiceName", "centro": "Centro", "categoria": "ServiceCategory"}


def regras_padrao() -> list[dict]:
    """Conjunto inicial. Existe para o painel nao nascer vazio; o usuario ajusta ou apaga."""
    return [
        {"id": "padrao-pico", "nome": "Pico de custo diário", "tipo": "pico_diario", "limiar": 3, "escopoTipo": "total",
         "escopoValor": "", "severidade": "atencao", "destinatarios": [], "ativo": True, "padrao": True},
        {"id": "padrao-crescimento", "nome": "Crescimento acima de 25% no mês", "tipo": "crescimento_mensal", "limiar": 25,
         "escopoTipo": "total", "escopoValor": "", "severidade": "atencao", "destinatarios": [], "ativo": True, "padrao": True},
        {"id": "padrao-semtag", "nome": "Mais de 30% do gasto sem etiqueta", "tipo": "sem_tag", "limiar": 30, "escopoTipo": "total",
         "escopoValor": "", "severidade": "informativo", "destinatarios": [], "ativo": True, "padrao": True},
        {"id": "padrao-ocioso", "nome": "Compromisso sem uso", "tipo": "compromisso_ocioso", "limiar": 1, "escopoTipo": "total",
         "escopoValor": "", "severidade": "critico", "destinatarios": [], "ativo": True, "padrao": True},
        {"id": "padrao-novo", "nome": "Serviço novo custando mais de 100", "tipo": "novo_servico", "limiar": 100, "escopoTipo": "total",
         "escopoValor": "", "severidade": "informativo", "destinatarios": [], "ativo": True, "padrao": True},
    ]


def _fmt(v: float, moeda: str) -> str:
    s = {"USD": "US$", "BRL": "R$", "EUR": "EUR"}.get(moeda, moeda)
    return f"{s} {v:,.2f}"


def _recorte(df, regra: dict, centros_alocados: pd.Series | None):
    tipo, valor = regra.get("escopoTipo", "total"), str(regra.get("escopoValor") or "")
    if tipo == "total" or not valor:
        return df
    if tipo == "centro":
        if centros_alocados is None:
            return df.iloc[0:0]
        return df[centros_alocados == valor]
    col = ESCOPOS.get(tipo)
    return df[df[col] == valor] if col in df.columns else df.iloc[0:0]


def _escopo_txt(regra: dict) -> str:
    t, v = regra.get("escopoTipo", "total"), regra.get("escopoValor") or ""
    return "total" if (t == "total" or not v) else f"{t}: {v}"


# ------------------------------------------------------------------ avaliadores
def _av_orcamento(df, regra, moeda, orcamentos):
    limiar = float(regra.get("limiar") or 0)
    mes = analytics.hoje().to_period("M").strftime("%Y-%m")
    realizado = float(df[df["Mes"] == mes]["EffectiveCost"].sum())
    prev = forecast.prever(df, horizonte=45)
    projetado = float(prev.get("fimDoMes") or realizado)
    if limiar <= 0:
        return []
    saida = []
    if realizado > limiar:
        saida.append(dict(chave=f"orc-real-{mes}", titulo="Orçamento do mês estourado",
                          detalhe=f"Realizado {_fmt(realizado, moeda)} contra orçamento de {_fmt(limiar, moeda)} ({realizado / limiar:.0%}).",
                          valor=realizado - limiar, acao="Congele novas alocações e revise os maiores serviços do mês.", severidade="critico", condicao=True))
    elif projetado > limiar:
        dias = forecast.dias_ate(limiar, prev["previsao"], realizado)
        saida.append(dict(chave=f"orc-proj-{mes}", titulo="Projeção do mês passa do orçamento",
                          detalhe=f"Realizado {_fmt(realizado, moeda)}, projeção de fim de mês {_fmt(projetado, moeda)} contra "
                                  f"{_fmt(limiar, moeda)}. No ritmo atual, estoura em {dias} dia(s)." if dias else
                                  f"Realizado {_fmt(realizado, moeda)}, projeção {_fmt(projetado, moeda)} contra {_fmt(limiar, moeda)}.",
                          valor=projetado - limiar, acao="Ainda dá tempo: identifique o que cresceu e aja antes do fechamento.", condicao=True))
    return saida


def _av_pico(df, regra, moeda, _):
    k = float(regra.get("limiar") or 3)
    s = df.groupby(df["Data"].dt.date)["EffectiveCost"].sum().sort_index()
    if len(s) < 14:
        return []
    s = s.iloc[:-1]  # dia corrente incompleto
    media, desvio = s.mean(), s.std()
    if not desvio or desvio <= 0:
        return []
    picos = s[s > media + k * desvio].tail(5)
    return [dict(chave=f"pico-{dia}", titulo=f"Pico de custo em {dia}",
                 detalhe=f"{_fmt(float(v), moeda)} no dia, contra média de {_fmt(float(media), moeda)} ({v / media:.1f} vezes).",
                 valor=float(v - media), acao="Veja o que foi criado, escalado ou executado nesse dia.", condicao=False)
            for dia, v in picos.items()]


def _av_crescimento(df, regra, moeda, _):
    limiar = float(regra.get("limiar") or 25) / 100
    c = analytics.comparar_meses(df)
    if c["anterior"] <= 0 or c["variacao"] < limiar:
        return []
    janela = f" (comparação dos primeiros {c['diasComparados']} dias)" if c["parcial"] else ""
    return [dict(chave=f"cresc-{c['rotuloAtual']}", titulo=f"Custo {c['variacao']:.0%} acima do mês anterior",
                 detalhe=f"De {_fmt(c['anterior'], moeda)} para {_fmt(c['atual'], moeda)}{janela}.",
                 valor=c["atual"] - c["anterior"], acao="Compare os serviços entre os dois meses para achar a origem.", condicao=True)]


def _av_previsao(df, regra, moeda, _):
    limiar = float(regra.get("limiar") or 0)
    if limiar <= 0:
        return []
    p = forecast.prever(df, horizonte=30)
    v30 = p["acumulado"]["30"]
    if v30 <= limiar:
        return []
    return [dict(chave="prev-30", titulo="Previsão de 30 dias acima do limite",
                 detalhe=f"Projeção de {_fmt(v30, moeda)} para os próximos 30 dias, limite de {_fmt(limiar, moeda)}. "
                         f"Tendência de {p['tendenciaMensal']:+.0%} ao mês, confiabilidade {p['confiabilidade']}.",
                 valor=v30 - limiar, acao="Antecipe: reveja a tendência dos maiores serviços na página de previsão.", condicao=True)]


def _av_sem_tag(df, regra, moeda, _):
    limiar = float(regra.get("limiar") or 30) / 100
    total = float(df["EffectiveCost"].sum())
    if total <= 0:
        return []
    sem = float(df.loc[df["SemTag"], "EffectiveCost"].sum())
    pct = sem / total
    if pct < limiar:
        return []
    return [dict(chave="semtag", titulo=f"{pct:.0%} do gasto sem etiqueta",
                 detalhe=f"{_fmt(sem, moeda)} sem nenhuma tag. Sem etiqueta não há chargeback confiável.",
                 valor=sem, acao="Defina tags obrigatórias e aplique com política (Azure Policy, SCP, Org Policy).", condicao=True)]


def _av_ocioso(df, regra, moeda, _):
    limiar = float(regra.get("limiar") or 0)
    ocioso = df[df["CommitmentDiscountStatus"].str.lower() == "unused"]
    v = float(ocioso["EffectiveCost"].sum())
    if v <= max(limiar, 0):
        return []
    nomes = ", ".join(sorted(ocioso["CommitmentDiscountName"].unique())[:3])
    return [dict(chave="ocioso", titulo="Compromisso comprado e não consumido",
                 detalhe=f"{_fmt(v, moeda)} em reservas ou savings plans sem uso no período ({nomes}).",
                 valor=v, acao="Troque escopo ou família, ou avalie devolução parcial.", condicao=True)]


def _av_novo_servico(df, regra, moeda, _):
    limiar = float(regra.get("limiar") or 0)
    hoje = analytics.hoje()
    recentes = df[df["Data"] >= hoje - pd.Timedelta(days=7)]
    antes = df[(df["Data"] < hoje - pd.Timedelta(days=7)) & (df["Data"] >= hoje - pd.Timedelta(days=37))]
    if recentes.empty or antes.empty:
        return []
    novos = set(recentes["ServiceName"].unique()) - set(antes["ServiceName"].unique())
    saida = []
    for s in novos:
        v = float(recentes[recentes["ServiceName"] == s]["EffectiveCost"].sum())
        if v > limiar:
            saida.append(dict(chave=f"novo-{s}", titulo=f"Serviço novo: {s}",
                              detalhe=f"Não aparecia nos 30 dias anteriores e já custou {_fmt(v, moeda)} na última semana.",
                              valor=v, acao="Confirme se foi planejado e se tem dono e etiqueta.", condicao=False))
    return saida


AVALIADORES = {"orcamento": _av_orcamento, "pico_diario": _av_pico, "crescimento_mensal": _av_crescimento,
               "previsao": _av_previsao, "sem_tag": _av_sem_tag, "compromisso_ocioso": _av_ocioso, "novo_servico": _av_novo_servico}


# ------------------------------------------------------------------ motor
def avaliar(df, store: StateStore, centros_alocados: pd.Series | None = None, enviar_email: bool = True) -> dict:
    """Roda todas as regras ativas, abre ou atualiza alertas e notifica os novos."""
    # Semeia as regras padrao que ainda nao existem (o usuario pode desativar ou apagar depois;
    # a marca "padrao" impede que voltem se ele as apagar de proposito).
    existentes_ids = {r["id"] for r in store.listar("regras_alerta")}
    cfg = store.obter("configuracoes", "regras_padrao_semeadas")
    if not cfg:
        for r in regras_padrao():
            if r["id"] not in existentes_ids:
                store.salvar("regras_alerta", r)
        store.salvar("configuracoes", {"id": "regras_padrao_semeadas", "em": agora_iso()})
    regras = [r for r in store.listar("regras_alerta") if r.get("ativo", True)]

    moeda = analytics.moeda_de(df)
    existentes = {a["chave"]: a for a in store.listar("alertas") if a.get("estado") in ("aberto", "reconhecido")}
    vistos, novos, atualizados, resolvidos = set(), [], 0, 0
    cfg_email = notifications.configurado()

    for regra in regras:
        avaliador = AVALIADORES.get(regra.get("tipo"))
        if not avaliador:
            continue
        rec = _recorte(df, regra, centros_alocados)
        if rec.empty:
            continue
        try:
            ocorrencias = avaliador(rec, regra, moeda, None)
        except Exception:  # noqa: BLE001
            log.exception("Regra %s falhou", regra.get("nome"))
            continue
        for oc in ocorrencias:
            chave = f"{regra['id']}|{oc['chave']}"
            vistos.add(chave)
            sev = oc.get("severidade") or regra.get("severidade", "atencao")
            if chave in existentes:
                a = existentes[chave]
                a.update({"detalhe": oc["detalhe"], "valor": oc["valor"], "valorFormatado": _fmt(oc["valor"], moeda), "severidade": sev})
                store.salvar("alertas", a)
                atualizados += 1
                continue
            a = {"regraId": regra["id"], "regraNome": regra.get("nome", ""), "tipo": regra.get("tipo"), "severidade": sev,
                 "titulo": oc["titulo"], "detalhe": oc["detalhe"], "valor": oc["valor"], "valorFormatado": _fmt(oc["valor"], moeda),
                 "acao": oc.get("acao", ""), "escopo": _escopo_txt(regra), "chave": chave, "condicao": oc.get("condicao", False),
                 "estado": "aberto", "abertoEm": agora_iso(), "comentario": "", "notificado": False, "notificacao": ""}
            destinatarios = list(regra.get("destinatarios") or []) or cfg_email["destinatariosPadrao"]
            if enviar_email and destinatarios:
                ok, msg = notifications.notificar_alerta(a, destinatarios)
                a["notificado"], a["notificacao"] = ok, msg
            a = store.salvar("alertas", a)
            novos.append(a)

    # resolucao automatica dos alertas de condicao que deixaram de valer
    for chave, a in existentes.items():
        if a.get("condicao") and chave not in vistos:
            a["estado"] = "resolvido"
            a["comentario"] = (a.get("comentario") or "") + " Resolvido automaticamente: a condição deixou de valer."
            a["resolvidoEm"] = agora_iso()
            store.salvar("alertas", a)
            resolvidos += 1

    store.salvar("configuracoes", {"id": "ultima_avaliacao", "em": agora_iso(), "novos": len(novos), "atualizados": atualizados,
                                   "resolvidos": resolvidos, "regras": len(regras), "emailAtivo": cfg_email["ativo"]})
    log.info("Alertas: %s novos, %s atualizados, %s resolvidos", len(novos), atualizados, resolvidos)
    return {"novos": novos, "atualizados": atualizados, "resolvidos": resolvidos, "regras": len(regras)}


def resumo(store: StateStore) -> dict:
    alertas = store.listar("alertas")
    abertos = [a for a in alertas if a.get("estado") == "aberto"]
    rec = [a for a in alertas if a.get("estado") == "reconhecido"]
    por_sev = {}
    for a in abertos:
        por_sev[a.get("severidade", "atencao")] = por_sev.get(a.get("severidade", "atencao"), 0) + 1
    ultima = store.obter("configuracoes", "ultima_avaliacao") or {}
    return {"abertos": len(abertos), "reconhecidos": len(rec), "total": len(alertas), "porSeveridade": por_sev,
            "ultimaAvaliacao": ultima.get("em"), "email": notifications.configurado()}


def mudar_estado(store: StateStore, id_: str, estado: str, comentario: str = "") -> dict | None:
    a = store.obter("alertas", id_)
    if not a:
        return None
    if estado not in ("aberto", "reconhecido", "resolvido", "descartado"):
        raise ValueError("estado inválido")
    a["estado"] = estado
    if comentario:
        a["comentario"] = comentario
    a[f"{estado}Em"] = agora_iso()
    return store.salvar("alertas", a)
