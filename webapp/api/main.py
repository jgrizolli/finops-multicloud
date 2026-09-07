"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

API da interface web. Le o dado FOCUS ja processado pelo FinOps hub e serve os endpoints que
a interface consome. Nenhum segredo no codigo: o acesso ao storage usa identidade gerenciada.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Annotated

import pandas as pd
from fastapi import Body, FastAPI, HTTPException, Query, Request
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

import alerts
import analytics
import chargeback
import domains
import export_report
import forecast
import governance
import insights
import notifications
import optimization
import sobre
from data_source import FonteBase, criar_fonte
from state_store import criar_store

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("finops.api")

DIR_ESTATICO = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "static")

app = FastAPI(title=f"{sobre.NOME} API", description=sobre.CREDITO_LONGO, version=sobre.VERSAO,
              docs_url="/api/docs", openapi_url="/api/openapi.json")
app.add_middleware(GZipMiddleware, minimum_size=1000)

store = criar_store()
_fonte: FonteBase | None = None
_erro_config: str | None = None


def configurar_fonte(fonte: FonteBase) -> None:
    """Define a fonte de dados. Em producao vem de configurar_fonte_padrao(); nos testes e na previa e injetada."""
    global _fonte, _erro_config
    _fonte, _erro_config = fonte, None
    if _pos_carga not in fonte.ouvintes_pos_carga:
        fonte.ouvintes_pos_carga.append(_pos_carga)
    log.info("Fonte de dados: %s (%s)", fonte.backend, fonte.descricao)


def configurar_fonte_padrao() -> None:
    """Le a configuracao do ambiente (DATA_BACKEND e companhia) e configura a fonte.

    Chamada no FIM deste modulo, e nao aqui: configurar_fonte() usa _pos_carga, definida mais abaixo.
    Chamar antes dava NameError na importacao, o processo morria antes de abrir a porta e o Container Apps
    ficava em ContainerBackOff (visto em campo; teste em test_local.py cobre desde entao).
    """
    global _erro_config
    try:
        configurar_fonte(criar_fonte())
    except (ValueError, ImportError) as exc:
        _erro_config = str(exc)
        log.error("Configuracao ausente: %s", exc)


ListaOpcional = Annotated[list[str] | None, Query()]


# ------------------------------------------------------------------ base
def _carga():
    if _erro_config or _fonte is None:
        raise HTTPException(status_code=503, detail=_erro_config or "Fonte de dados nao configurada.")
    carga = _fonte.carregar()
    if carga.erro and carga.df.empty:
        raise HTTPException(status_code=503, detail=carga.erro)
    return carga


def _dados(meses, nuvens=None, servicos=None, assinaturas=None, grupos=None, categorias=None, ambientes=None):
    carga = _carga()
    return carga, analytics.aplicar_filtros(carga.df, meses=meses, nuvens=nuvens, servicos=servicos, assinaturas=assinaturas,
                                             grupos=grupos, categorias=categorias, ambientes=ambientes)


def _centros_alocados(df, carga):
    centros = store.listar("centros_custo")
    if not centros or df.empty:
        return None
    return chargeback.alocar(df, centros, carga.tags_por_string)


def _pos_carga(carga):
    """Depois de cada carga nova, reavalia os alertas sobre o dado completo."""
    if carga.df.empty or os.getenv("ALERTS_ON_LOAD", "true").lower() == "false":
        return
    try:
        alerts.avaliar(carga.df, store, _centros_alocados(carga.df, carga))
    except Exception:  # noqa: BLE001
        log.exception("Avaliacao de alertas pos-carga falhou")


def _texto_filtros(meses, nuvens, categorias, assinaturas):
    partes = [f"últimos {meses} meses" if meses else "todo o período"]
    if nuvens:
        partes.append("nuvem: " + ", ".join(nuvens))
    if categorias:
        partes.append("categoria: " + ", ".join(categorias))
    if assinaturas:
        partes.append("assinatura: " + ", ".join(assinaturas))
    return " · ".join(partes)


# ------------------------------------------------------------------ infraestrutura
@app.get("/api/health")
def health():
    """Usado pelo health check da plataforma. Nunca depende do dado nem exige login."""
    return {"status": "ok", "configurado": _fonte is not None, "versao": sobre.VERSAO}


@app.get("/api/sobre")
def sobre_endpoint():
    return sobre.como_dict()


@app.get("/api/status")
def status():
    if _erro_config or _fonte is None:
        return JSONResponse(status_code=503, content={"erro": _erro_config})
    c = _fonte.carregar()
    return {"backend": _fonte.backend, "fonte": _fonte.descricao, "storage": _fonte.storage_account, "url": _fonte.storage_url,
            "arquivos": c.arquivos, "linhas": c.linhas, "megabytes": round(c.bytes_lidos / 1024 / 1024, 2), "meses": c.meses,
            "carregadoEm": c.carregado_em.isoformat() if c.carregado_em else None, "duracaoSegundos": c.duracao_segundos,
            "erro": c.erro, "estado": store.descricao(), "email": notifications.configurado(), "alertas": alerts.resumo(store),
            "versao": sobre.VERSAO}


@app.post("/api/refresh")
def refresh():
    if _fonte is None:
        raise HTTPException(status_code=503, detail=_erro_config or "Fonte nao configurada.")
    _fonte.invalidar()
    c = _fonte.carregar(forcar=True)
    return {"linhas": c.linhas, "arquivos": c.arquivos, "erro": c.erro}


@app.get("/api/filtros")
def filtros():
    return analytics.filtros_disponiveis(_carga().df)


# ------------------------------------------------------------------ paginas de analise
@app.get("/api/visao-geral")
def visao_geral(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
                grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None):
    carga, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    return {"resumo": analytics.resumo(df), "mensal": analytics.serie_mensal(df), "diario": analytics.serie_diaria(df),
            "porNuvem": analytics.agrupar(df, "Nuvem", 10), "porCategoria": analytics.agrupar(df, "ServiceCategory", 10),
            "porServico": analytics.agrupar(df, "ServiceName", 12), "porAmbiente": analytics.agrupar(df, "Ambiente", 4),
            "alertas": alerts.resumo(store), "atualizadoEm": carga.carregado_em.isoformat() if carga.carregado_em else None}


@app.get("/api/tecnologia")
def tecnologia(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
               grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None):
    _, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    return {"resumo": analytics.resumo(df), "porServico": analytics.agrupar(df, "ServiceName", 20),
            "porCategoria": analytics.agrupar(df, "ServiceCategory", 12), "porTipoRecurso": analytics.agrupar(df, "ResourceType", 15),
            "evolucaoServico": analytics.evolucao_por(df, "ServiceName", 6), "porRegiao": analytics.agrupar(df, "RegionName", 12)}


@app.get("/api/nuvens")
def nuvens_endpoint(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
                    grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None):
    _, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    return {"resumo": analytics.resumo(df), "porNuvem": analytics.agrupar(df, "Nuvem", 10), "evolucaoNuvem": analytics.evolucao_por(df, "Nuvem", 5),
            "porAssinatura": analytics.agrupar(df, "SubAccountName", 15), "porContaFatura": analytics.agrupar(df, "BillingAccountName", 10),
            "categoriaPorNuvem": {n: analytics.agrupar(df[df["Nuvem"] == n], "ServiceCategory", 6) for n in df["Nuvem"].unique()} if not df.empty else {}}


@app.get("/api/recursos")
def recursos(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
             grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None, limite: int = 50):
    _, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    return {"resumo": analytics.resumo(df), "topRecursos": analytics.top_recursos(df, limite), "porGrupo": analytics.agrupar(df, "ResourceGroupName", 15),
            "porTipoCobranca": analytics.agrupar(df, "ChargeCategory", 8), "porAmbiente": analytics.agrupar(df, "Ambiente", 4)}


@app.get("/api/insights")
def insights_endpoint(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
                      grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None):
    carga, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    r = analytics.resumo(df)
    return {"resumo": r, "achados": insights.gerar(df, r["moeda"]), "qualidade": analytics.qualidade(df, carga.meses)}


@app.get("/api/governanca")
def governanca_endpoint(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
                        grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None, tag: str | None = None):
    carga, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    cfg = store.obter("configuracoes", "tags_obrigatorias") or {}
    return governance.analisar(df, carga.tags_por_string, tag, cfg.get("chaves"), store.listar("orcamentos"))


@app.get("/api/ia")
def ia_endpoint(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
                grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None):
    carga, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    saida = domains.analisar_ia(df, carga.meses)
    if not saida.get("vazio"):
        ia = domains.dataframe_ia(df)
        saida["previsao"] = forecast.prever(ia, horizonte=90)
        saida["otimizacao"] = optimization.analisar(ia, limite=15)
        saida["achados"] = insights.gerar(ia, saida["resumo"]["moeda"])
    return saida


@app.get("/api/bancos")
def bancos_endpoint(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
                    grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None):
    carga, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    saida = domains.analisar_bancos(df, carga.meses)
    if not saida.get("vazio"):
        bd = domains.dataframe_bancos(df)
        saida["previsao"] = forecast.prever(bd, horizonte=90)
        saida["previsaoEngine"] = forecast.prever_workloads(bd.assign(Engine=[domains.classificar_engine(t)[0] for t in domains._texto_bd(bd)]), "Engine", top=8)
        saida["otimizacao"] = optimization.analisar(bd, limite=20)
        saida["achados"] = insights.gerar(bd, saida["resumo"]["moeda"])
        saida["alertas"] = [a for a in store.listar("alertas") if a.get("estado") in ("aberto", "reconhecido") and
                            any(k in (a.get("escopo", "") + a.get("titulo", "")).lower() for k in ("sql", "cosmos", "postgres", "mysql", "redis", "rds", "dynamo", "banco"))]
    return saida


@app.get("/api/otimizacao")
def otimizacao_endpoint(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
                        grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None):
    _, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    saida = optimization.analisar(df)
    saida["porAmbiente"] = analytics.agrupar(df, "Ambiente", 4)
    saida["coberturaCompromisso"] = {
        "coberto": float(df.loc[df["CommitmentDiscountId"].str.strip() != "", "EffectiveCost"].sum()) if not df.empty else 0.0,
        "sobDemanda": float(df.loc[df["CommitmentDiscountId"].str.strip() == "", "EffectiveCost"].sum()) if not df.empty else 0.0}
    return saida


@app.get("/api/previsao")
def previsao_endpoint(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
                      grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None,
                      dimensao: str = "ServiceName", horizonte: int = 90, janela: int = 90):
    _, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    dim = {"servico": "ServiceName", "grupo": "ResourceGroupName", "assinatura": "SubAccountName", "nuvem": "Nuvem",
           "categoria": "ServiceCategory"}.get(dimensao, dimensao)
    p = forecast.prever(df, horizonte=horizonte, janela=janela)
    orcs = [o for o in store.listar("orcamentos") if o.get("escopoTipo") == "total"]
    orcamento_total = float(orcs[0].get("valorMensal") or 0) if orcs else 0.0
    return {"resumo": analytics.resumo(df), "previsao": p, "workloads": forecast.prever_workloads(df, dim, top=10, horizonte=horizonte),
            "dimensao": dim, "orcamentoMensal": orcamento_total,
            "diasAteOrcamento": forecast.dias_ate(orcamento_total, p["previsao"], p.get("realizadoMes", 0.0)) if orcamento_total else None,
            "moeda": analytics.moeda_de(df)}


@app.get("/api/chargeback")
def chargeback_endpoint(meses: int = 6, nuvens: ListaOpcional = None, servicos: ListaOpcional = None, assinaturas: ListaOpcional = None,
                        grupos: ListaOpcional = None, categorias: ListaOpcional = None, ambientes: ListaOpcional = None, distribuir: bool = True):
    carga, df = _dados(meses, nuvens, servicos, assinaturas, grupos, categorias, ambientes)
    saida = chargeback.analisar(df, store.listar("centros_custo"), carga.tags_por_string, distribuir)
    saida["cadastro"] = store.listar("centros_custo")
    return saida


# ------------------------------------------------------------------ cadastros
def _crud(colecao: str, validar=None):
    def listar():
        return store.listar(colecao)

    def salvar(item: dict = Body(...)):
        if validar:
            validar(item)
        return store.salvar(colecao, item)

    def remover(id_: str):
        if not store.remover(colecao, id_):
            raise HTTPException(status_code=404, detail="Não encontrado.")
        return {"ok": True}

    return listar, salvar, remover


def _validar_centro(c):
    if not c.get("nome"):
        raise HTTPException(status_code=400, detail="Informe o nome do centro de custo.")
    for r in c.get("regras", []):
        if r.get("tipo") not in ("tag", "assinatura", "grupo", "nuvem", "servico", "conta"):
            raise HTTPException(status_code=400, detail=f"Tipo de regra inválido: {r.get('tipo')}")


def _validar_orcamento(o):
    if not o.get("nome") or not o.get("valorMensal"):
        raise HTTPException(status_code=400, detail="Informe nome e valor mensal.")
    if o.get("escopoTipo") not in ("total", "tag", "nuvem", "assinatura", "grupo", "servico", "centro"):
        raise HTTPException(status_code=400, detail="Escopo inválido.")


def _validar_regra(r):
    if r.get("tipo") not in alerts.TIPOS:
        raise HTTPException(status_code=400, detail=f"Tipo inválido. Use um de: {', '.join(alerts.TIPOS)}")
    if not r.get("nome"):
        raise HTTPException(status_code=400, detail="Informe o nome da regra.")
    r.setdefault("ativo", True)
    r.setdefault("severidade", "atencao")
    r.setdefault("escopoTipo", "total")


for _colecao, _rota, _val in (("centros_custo", "centros-custo", _validar_centro), ("orcamentos", "orcamentos", _validar_orcamento),
                              ("regras_alerta", "regras-alerta", _validar_regra)):
    _l, _s, _r = _crud(_colecao, _val)
    _l.__name__, _s.__name__, _r.__name__ = f"listar_{_colecao}", f"salvar_{_colecao}", f"remover_{_colecao}"
    app.get(f"/api/{_rota}", name=_l.__name__)(_l)
    app.post(f"/api/{_rota}", name=_s.__name__)(_s)
    app.delete(f"/api/{_rota}/{{id_}}", name=_r.__name__)(_r)


@app.post("/api/centros-custo/importar")
async def importar_centros(request: Request, formato: str = "json", substituir: bool = False):
    """Ponto de integracao com CMDB: envie JSON (lista de centros) ou CSV. Com substituir=true, apaga o cadastro atual antes."""
    corpo = (await request.body()).decode("utf-8", errors="replace")
    try:
        centros = chargeback.importar(corpo, formato)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=f"Não consegui interpretar o conteúdo: {exc}") from exc
    if substituir:
        store.limpar("centros_custo")
    salvos = store.salvar_varios("centros_custo", centros)
    return {"importados": len(salvos), "total": len(store.listar("centros_custo"))}


@app.get("/api/configuracoes/tags-obrigatorias")
def tags_obrigatorias():
    return store.obter("configuracoes", "tags_obrigatorias") or {"id": "tags_obrigatorias", "chaves": governance.TAGS_OBRIGATORIAS_PADRAO}


@app.post("/api/configuracoes/tags-obrigatorias")
def salvar_tags_obrigatorias(cfg: dict = Body(...)):
    chaves = [str(c).strip() for c in cfg.get("chaves", []) if str(c).strip()]
    return store.salvar("configuracoes", {"id": "tags_obrigatorias", "chaves": chaves})


# ------------------------------------------------------------------ alertas
@app.get("/api/alertas")
def listar_alertas(estado: str | None = None):
    itens = store.listar("alertas")
    if estado:
        itens = [a for a in itens if a.get("estado") == estado]
    itens.sort(key=lambda a: ({"critico": 0, "atencao": 1, "informativo": 2}.get(a.get("severidade"), 3), a.get("abertoEm", "")), reverse=False)
    return {"alertas": itens, "resumo": alerts.resumo(store), "tipos": alerts.TIPOS, "escopos": list(alerts.ESCOPOS)}


@app.patch("/api/alertas/{id_}")
def atualizar_alerta(id_: str, corpo: dict = Body(...)):
    try:
        a = alerts.mudar_estado(store, id_, corpo.get("estado", "reconhecido"), corpo.get("comentario", ""))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not a:
        raise HTTPException(status_code=404, detail="Alerta não encontrado.")
    return a


@app.delete("/api/alertas/{id_}")
def excluir_alerta(id_: str):
    if not store.remover("alertas", id_):
        raise HTTPException(status_code=404, detail="Alerta não encontrado.")
    return {"ok": True}


@app.post("/api/alertas/avaliar")
def avaliar_alertas(enviar_email: bool = True):
    carga = _carga()
    return alerts.avaliar(carga.df, store, _centros_alocados(carga.df, carga), enviar_email=enviar_email)


@app.post("/api/alertas/testar-email")
def testar_email(corpo: dict = Body(default={})):
    dest = corpo.get("destinatarios") or notifications.configurado()["destinatariosPadrao"]
    ok, msg = notifications.notificar_alerta({"severidade": "informativo", "titulo": "Teste de notificação",
                                              "detalhe": "Se você recebeu este e-mail, o envio de alertas está funcionando.",
                                              "regraNome": "teste", "escopo": "total"}, dest)
    return {"ok": ok, "mensagem": msg, "destinatarios": dest}


# ------------------------------------------------------------------ exportacao
def _montar_relatorio(meses, nuvens, categorias, assinaturas, completo=True):
    carga, df = _dados(meses, nuvens, None, assinaturas, None, categorias)
    r = analytics.resumo(df)
    m = r["moeda"]
    achados = insights.gerar(df, m)
    prev = forecast.prever(df, horizonte=90)
    ot = optimization.analisar(df, limite=40)
    dados = {
        "moeda": m, "resumo": r, "mensal": analytics.serie_mensal(df), "diario": analytics.serie_diaria(df),
        "porServico": analytics.agrupar(df, "ServiceName", 15), "porCategoria": analytics.agrupar(df, "ServiceCategory", 10),
        "porNuvem": analytics.agrupar(df, "Nuvem", 6), "porRegiao": analytics.agrupar(df, "RegionName", 12),
        "porAssinatura": analytics.agrupar(df, "SubAccountName", 15), "topRecursos": analytics.top_recursos(df, 200 if completo else 15),
        "achados": achados, "previsao": prev, "otimizacao": ot,
        "alertas": [a for a in store.listar("alertas") if a.get("estado") in ("aberto", "reconhecido")],
        "filtrosTexto": _texto_filtros(meses, nuvens, categorias, assinaturas),
    }
    dados["narrativa"] = export_report.narrativa(r, achados, prev, ot, m)
    if completo:
        dados["chargeback"] = chargeback.analisar(df, store.listar("centros_custo"), carga.tags_por_string)
        cfg = store.obter("configuracoes", "tags_obrigatorias") or {}
        dados["governanca"] = governance.analisar(df, carga.tags_por_string, None, cfg.get("chaves"), store.listar("orcamentos"))
        dados["previsaoWorkloads"] = forecast.prever_workloads(df, "ServiceName", top=10)
        dados["ia"] = domains.analisar_ia(df, carga.meses)
        dados["bancos"] = domains.analisar_bancos(df, carga.meses)
    return dados


@app.get("/api/export/pdf")
def export_pdf(meses: int = 6, nuvens: ListaOpcional = None, categorias: ListaOpcional = None, assinaturas: ListaOpcional = None):
    dados = _montar_relatorio(meses, nuvens, categorias, assinaturas, completo=False)
    nome = f"finops-relatorio-{datetime.now().strftime('%Y%m%d-%H%M')}.pdf"
    return Response(export_report.gerar_pdf(dados), media_type="application/pdf", headers={"Content-Disposition": f'attachment; filename="{nome}"'})


@app.get("/api/export/excel")
def export_excel(meses: int = 6, nuvens: ListaOpcional = None, categorias: ListaOpcional = None, assinaturas: ListaOpcional = None):
    dados = _montar_relatorio(meses, nuvens, categorias, assinaturas, completo=True)
    nome = f"finops-dados-{datetime.now().strftime('%Y%m%d-%H%M')}.xlsx"
    return Response(export_report.gerar_excel(dados), media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    headers={"Content-Disposition": f'attachment; filename="{nome}"'})


@app.get("/api/relatorio")
def relatorio_endpoint(meses: int = 6, nuvens: ListaOpcional = None, categorias: ListaOpcional = None, assinaturas: ListaOpcional = None):
    """Previa do relatorio executivo para a tela (mesmo conteudo do PDF)."""
    d = _montar_relatorio(meses, nuvens, categorias, assinaturas, completo=False)
    d.pop("diario", None)
    return d


# ------------------------------------------------------------------ agendador
def _agendador():
    """Reavalia os alertas uma vez por dia, no horario configurado, mesmo sem ninguem acessar."""
    hora = int(os.getenv("ALERT_HOUR", "9"))
    fuso = int(os.getenv("APP_UTC_OFFSET", "-3"))
    time.sleep(90)  # deixa a aplicacao subir antes da primeira carga
    while True:
        try:
            if _fonte is not None:
                _fonte.carregar(forcar=True)  # a carga dispara _pos_carga, que avalia os alertas
        except Exception:  # noqa: BLE001
            log.exception("Agendador: falha na carga")
        agora = datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(hours=fuso)
        proximo = agora.replace(hour=hora, minute=0, second=0, microsecond=0)
        if proximo <= agora:
            proximo += timedelta(days=1)
        time.sleep(max((proximo - agora).total_seconds(), 300))


_agendador_iniciado = False


def iniciar_agendador() -> None:
    """Sobe a thread do agendador uma unica vez, e so quando ha fonte configurada."""
    global _agendador_iniciado
    if _agendador_iniciado or _fonte is None or os.getenv("ALERTS_SCHEDULER", "true").lower() == "false":
        return
    _agendador_iniciado = True
    threading.Thread(target=_agendador, daemon=True, name="finops-agendador").start()


# A fonte padrao e configurada por ultimo, quando todas as funcoes do modulo ja existem.
# A previa e os testes chamam configurar_fonte(...) depois de importar, sobrescrevendo esta.
if os.getenv("FINOPS_SKIP_DEFAULT_SOURCE", "").lower() not in ("1", "true"):
    configurar_fonte_padrao()
    iniciar_agendador()


# ------------------------------------------------------------------ front
if os.path.isdir(DIR_ESTATICO):
    app.mount("/static", StaticFiles(directory=DIR_ESTATICO), name="static")

    @app.get("/")
    def raiz():
        return FileResponse(os.path.join(DIR_ESTATICO, "index.html"))

    @app.get("/{caminho:path}")
    def spa(caminho: str):
        if caminho.startswith("api/"):
            raise HTTPException(status_code=404, detail="Endpoint nao encontrado.")
        return FileResponse(os.path.join(DIR_ESTATICO, "index.html"))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8000")))
