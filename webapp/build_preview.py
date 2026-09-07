"""
FinOps Multicloud
Construido por Wanderlei Grizolli Junior, Sr. Solution Engineer.
Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

Gera a previa da interface em UM arquivo HTML, que abre com duplo clique.

Como funciona: sobe a aplicacao REAL (FastAPI) em memoria com uma fonte de dados sintetica
e um estado local temporario, chama cada endpoint que a interface usa, e embute as respostas
no HTML. Um interceptador substitui o fetch pelas respostas embutidas. Acoes de escrita
(salvar centro, reconhecer alerta) sao simuladas em memoria no navegador.

Consequencia util: se um endpoint tiver defeito, a previa mostra o mesmo defeito. Ela nao e
uma maquete, e o codigo real com dado de demonstracao.

Uso:  python build_preview.py
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import warnings

warnings.filterwarnings("ignore")

RAIZ = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(RAIZ, "api"))

# estado local temporario e sem agendador, ANTES de importar a app
_tmp = tempfile.mkdtemp(prefix="finops-preview-")
os.environ["STATE_DIR"] = _tmp
os.environ["ALERTS_SCHEDULER"] = "false"
os.environ["ALERTS_ON_LOAD"] = "false"
os.environ["HUB_STORAGE_ACCOUNT"] = "demonstracao"
os.environ["FINOPS_SKIP_DEFAULT_SOURCE"] = "1"   # a previa injeta a FonteEstatica; nao criar a fonte de storage

import demo_data  # noqa: E402
from data_source import FonteEstatica  # noqa: E402

try:
    import main as app_main  # noqa: E402
    from fastapi.testclient import TestClient  # noqa: E402
    MODO = "http"
except ModuleNotFoundError:
    # Sem FastAPI instalado (ex.: maquina de documentacao): chamamos a logica diretamente.
    app_main = None
    TestClient = None
    MODO = "direto"

PERIODOS = [1, 3, 6, 12]  # 24 e "tudo" caem para 12 na previa, via alternativa do interceptador


def preparar_estado(store):
    for c in demo_data.CENTROS_DEMO:
        store.salvar("centros_custo", c)
    for o in demo_data.ORCAMENTOS_DEMO:
        store.salvar("orcamentos", o)
    store.salvar("regras_alerta", {"id": "orc-total", "nome": "Orçamento total mensal", "tipo": "orcamento", "limiar": 120000,
                                   "escopoTipo": "total", "escopoValor": "", "severidade": "critico", "destinatarios": ["finops@empresa.com"], "ativo": True})
    store.salvar("regras_alerta", {"id": "prev-ia", "nome": "IA acima de 15 mil em 30 dias", "tipo": "previsao", "limiar": 15000,
                                   "escopoTipo": "servico", "escopoValor": "Azure OpenAI Service", "severidade": "atencao", "destinatarios": [], "ativo": True})


class ClienteDireto:
    """Chama a mesma logica dos endpoints sem HTTP. Espelha main.py; se main.py mudar, ajuste aqui."""

    def __init__(self, carga, store):
        import alerts, analytics, chargeback, domains, export_report, forecast, governance, insights, notifications, optimization, sobre
        self.m = dict(alerts=alerts, analytics=analytics, chargeback=chargeback, domains=domains, export_report=export_report, forecast=forecast,
                      governance=governance, insights=insights, notifications=notifications, optimization=optimization, sobre=sobre)
        self.carga, self.store = carga, store

    def _df(self, q):
        a = self.m["analytics"]
        meses = int(q.get("meses", 0) or 0)
        return a.aplicar_filtros(self.carga.df, meses=meses or None, nuvens=[q["nuvens"]] if q.get("nuvens") else None)

    def get(self, url):
        from urllib.parse import parse_qs, urlparse
        u = urlparse(url); rota = u.path.replace("/api/", ""); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        m, st, c = self.m, self.store, self.carga
        a, df = m["analytics"], None
        try:
            if rota == "status":
                r = {"storage": "demonstracao", "url": "local", "arquivos": c.arquivos, "linhas": c.linhas, "megabytes": 0.0, "meses": c.meses,
                     "carregadoEm": c.carregado_em.isoformat(), "duracaoSegundos": 0.0, "erro": None, "estado": st.descricao(),
                     "email": m["notifications"].configurado(), "alertas": m["alerts"].resumo(st)}
            elif rota == "filtros": r = a.filtros_disponiveis(c.df)
            elif rota == "sobre": r = m["sobre"].como_dict()
            elif rota == "alertas":
                itens = st.listar("alertas"); r = {"alertas": itens, "resumo": m["alerts"].resumo(st), "tipos": m["alerts"].TIPOS, "escopos": list(m["alerts"].ESCOPOS)}
            elif rota == "regras-alerta": r = st.listar("regras_alerta")
            elif rota == "centros-custo": r = st.listar("centros_custo")
            elif rota == "orcamentos": r = st.listar("orcamentos")
            elif rota == "configuracoes/tags-obrigatorias": r = st.obter("configuracoes", "tags_obrigatorias") or {"id": "tags_obrigatorias", "chaves": m["governance"].TAGS_OBRIGATORIAS_PADRAO}
            else:
                df = self._df(q)
                if rota == "visao-geral":
                    r = {"resumo": a.resumo(df), "mensal": a.serie_mensal(df), "diario": a.serie_diaria(df), "porNuvem": a.agrupar(df, "Nuvem", 10),
                         "porCategoria": a.agrupar(df, "ServiceCategory", 10), "porServico": a.agrupar(df, "ServiceName", 12), "porAmbiente": a.agrupar(df, "Ambiente", 4),
                         "alertas": m["alerts"].resumo(st), "atualizadoEm": c.carregado_em.isoformat()}
                elif rota == "tecnologia":
                    r = {"resumo": a.resumo(df), "porServico": a.agrupar(df, "ServiceName", 20), "porCategoria": a.agrupar(df, "ServiceCategory", 12),
                         "porTipoRecurso": a.agrupar(df, "ResourceType", 15), "evolucaoServico": a.evolucao_por(df, "ServiceName", 6), "porRegiao": a.agrupar(df, "RegionName", 12)}
                elif rota == "nuvens":
                    r = {"resumo": a.resumo(df), "porNuvem": a.agrupar(df, "Nuvem", 10), "evolucaoNuvem": a.evolucao_por(df, "Nuvem", 5),
                         "porAssinatura": a.agrupar(df, "SubAccountName", 15), "porContaFatura": a.agrupar(df, "BillingAccountName", 10),
                         "categoriaPorNuvem": {n: a.agrupar(df[df["Nuvem"] == n], "ServiceCategory", 6) for n in df["Nuvem"].unique()} if not df.empty else {}}
                elif rota == "recursos":
                    r = {"resumo": a.resumo(df), "topRecursos": a.top_recursos(df, 60), "porGrupo": a.agrupar(df, "ResourceGroupName", 15),
                         "porTipoCobranca": a.agrupar(df, "ChargeCategory", 8), "porAmbiente": a.agrupar(df, "Ambiente", 4)}
                elif rota == "insights":
                    rs = a.resumo(df); r = {"resumo": rs, "achados": m["insights"].gerar(df, rs["moeda"]), "qualidade": a.qualidade(df, c.meses)}
                elif rota == "governanca":
                    cfg = st.obter("configuracoes", "tags_obrigatorias") or {}
                    r = m["governance"].analisar(df, c.tags_por_string, q.get("tag"), cfg.get("chaves"), st.listar("orcamentos"))
                elif rota == "ia":
                    r = m["domains"].analisar_ia(df, c.meses)
                    if not r.get("vazio"):
                        ia = m["domains"].dataframe_ia(df); r["previsao"] = m["forecast"].prever(ia); r["otimizacao"] = m["optimization"].analisar(ia, 15); r["achados"] = m["insights"].gerar(ia, r["resumo"]["moeda"])
                elif rota == "bancos":
                    r = m["domains"].analisar_bancos(df, c.meses)
                    if not r.get("vazio"):
                        bd = m["domains"].dataframe_bancos(df); r["previsao"] = m["forecast"].prever(bd)
                        r["previsaoEngine"] = m["forecast"].prever_workloads(bd.assign(Engine=[m["domains"].classificar_engine(t)[0] for t in m["domains"]._texto_bd(bd)]), "Engine", top=8)
                        r["otimizacao"] = m["optimization"].analisar(bd, 20); r["achados"] = m["insights"].gerar(bd, r["resumo"]["moeda"]); r["alertas"] = []
                elif rota == "otimizacao":
                    r = m["optimization"].analisar(df); r["porAmbiente"] = a.agrupar(df, "Ambiente", 4)
                    r["coberturaCompromisso"] = {"coberto": float(df.loc[df["CommitmentDiscountId"].str.strip() != "", "EffectiveCost"].sum()) if not df.empty else 0.0,
                                                 "sobDemanda": float(df.loc[df["CommitmentDiscountId"].str.strip() == "", "EffectiveCost"].sum()) if not df.empty else 0.0}
                elif rota == "previsao":
                    dim = {"servico": "ServiceName", "grupo": "ResourceGroupName", "assinatura": "SubAccountName", "nuvem": "Nuvem", "categoria": "ServiceCategory"}.get(q.get("dimensao", "servico"), "ServiceName")
                    p = m["forecast"].prever(df); orcs = [o for o in st.listar("orcamentos") if o.get("escopoTipo") == "total"]; ot = float(orcs[0].get("valorMensal") or 0) if orcs else 0.0
                    r = {"resumo": a.resumo(df), "previsao": p, "workloads": m["forecast"].prever_workloads(df, dim, top=10), "dimensao": dim, "orcamentoMensal": ot,
                         "diasAteOrcamento": m["forecast"].dias_ate(ot, p["previsao"], p.get("realizadoMes", 0.0)) if ot else None, "moeda": a.moeda_de(df)}
                elif rota == "chargeback":
                    r = m["chargeback"].analisar(df, st.listar("centros_custo"), c.tags_por_string, q.get("distribuir", "true") != "false"); r["cadastro"] = st.listar("centros_custo")
                elif rota == "relatorio":
                    rs = a.resumo(df); mo = rs["moeda"]; ach = m["insights"].gerar(df, mo); prev = m["forecast"].prever(df); ot = m["optimization"].analisar(df, 40)
                    r = {"moeda": mo, "resumo": rs, "mensal": a.serie_mensal(df), "porServico": a.agrupar(df, "ServiceName", 15), "porCategoria": a.agrupar(df, "ServiceCategory", 10),
                         "porNuvem": a.agrupar(df, "Nuvem", 6), "topRecursos": a.top_recursos(df, 15), "achados": ach, "previsao": prev, "otimizacao": ot,
                         "alertas": [x for x in st.listar("alertas") if x.get("estado") in ("aberto", "reconhecido")],
                         "filtrosTexto": f"últimos {q.get('meses')} meses" if q.get("meses") else "todo o período", "narrativa": m["export_report"].narrativa(rs, ach, prev, ot, mo)}
                else:
                    return type("R", (), {"status_code": 404, "text": "rota desconhecida"})()
            return type("R", (), {"status_code": 200, "json": (lambda self_=None, r=r: r)})()
        except Exception as exc:  # noqa: BLE001
            return type("R", (), {"status_code": 500, "text": str(exc)})()


def main() -> int:
    print("Gerando dados de demonstração...")
    df = demo_data.gerar()
    fonte = FonteEstatica(df)
    from state_store import LocalJsonStore
    store = app_main.store if app_main else LocalJsonStore(_tmp)
    if app_main:
        app_main.configurar_fonte(fonte)
    preparar_estado(store)
    carga = fonte.carregar()
    print(f"  {carga.linhas:,} linhas, {len(carga.meses)} meses, {carga.df['Nuvem'].nunique()} nuvens  (modo {MODO})")

    import alerts, chargeback  # noqa: E402
    res = alerts.avaliar(carga.df, store, chargeback.alocar(carga.df, store.listar("centros_custo"), carga.tags_por_string), enviar_email=False)
    if res["novos"]:
        alerts.mudar_estado(store, res["novos"][-1]["id"], "reconhecido", "Time de plataforma está avaliando.")
    print(f"  {len(res['novos'])} alertas de demonstração")

    cliente = TestClient(app_main.app) if app_main else ClienteDireto(carga, store)
    respostas: dict[str, object] = {}

    def podar(obj):
        """Reduz o tamanho da previa sem mudar o que a tela mostra: series diarias ficam com 120 pontos,
        historico da previsao com 90, listas longas com 40 itens."""
        if isinstance(obj, dict):
            for k, v in list(obj.items()):
                if k == "diario" and isinstance(v, list):
                    obj[k] = v[-120:]
                elif k == "historico" and isinstance(v, list):
                    obj[k] = v[-90:]
                elif k in ("topRecursos", "porRecurso", "porInstancia", "semTag", "recomendacoes") and isinstance(v, list):
                    obj[k] = v[:40]
                else:
                    podar(v)
        elif isinstance(obj, list):
            for v in obj:
                podar(v)
        return obj

    def pegar(chave, url):
        r = cliente.get(url)
        respostas[chave] = podar(r.json()) if r.status_code == 200 else {"detail": r.text, "_status": r.status_code}

    print("Chamando os endpoints reais...")
    pegar("GET /api/status", "/api/status")
    pegar("GET /api/filtros", "/api/filtros")
    pegar("GET /api/sobre", "/api/sobre")
    pegar("GET /api/alertas", "/api/alertas")
    pegar("GET /api/regras-alerta", "/api/regras-alerta")
    pegar("GET /api/centros-custo", "/api/centros-custo")
    pegar("GET /api/orcamentos", "/api/orcamentos")
    pegar("GET /api/configuracoes/tags-obrigatorias", "/api/configuracoes/tags-obrigatorias")

    nuvens = [""] + sorted(carga.df["Nuvem"].unique().tolist())
    paginas = ["visao-geral", "tecnologia", "nuvens", "recursos", "insights", "ia", "bancos", "governanca", "otimizacao", "chargeback", "relatorio"]
    for meses in PERIODOS:
        q = f"meses={meses}" if meses else ""
        for nuvem in nuvens:
            qn = (q + ("&" if q else "") + f"nuvens={nuvem}") if nuvem else q
            for p in paginas:
                pegar(f"{p}|{meses}|{nuvem}", f"/api/{p}?{qn}")
            for dim in ("servico", "grupo", "assinatura", "nuvem", "categoria"):
                pegar(f"previsao|{meses}|{nuvem}|{dim}", f"/api/previsao?{qn}{'&' if qn else ''}dimensao={dim}")
            pegar(f"chargeback|{meses}|{nuvem}|nodist", f"/api/chargeback?{qn}{'&' if qn else ''}distribuir=false")
    print(f"  {len(respostas)} respostas pré-calculadas")

    # Exportacoes REAIS (PDF e Excel gerados pelo mesmo codigo do servidor) para os periodos
    # mais usados. Ficam embutidas em base64 e o interceptador as devolve como download.
    import base64
    import export_report
    exportacoes = {}
    for meses in (6, 12):
        rel = cliente.get(f"/api/relatorio?meses={meses}")
        if rel.status_code != 200:
            continue
        d = rel.json()
        d["diario"] = respostas.get(f"visao-geral|{meses}|", {}).get("diario", [])
        d["porRegiao"] = respostas.get(f"tecnologia|{meses}|", {}).get("porRegiao", [])
        d["porAssinatura"] = respostas.get(f"nuvens|{meses}|", {}).get("porAssinatura", [])
        d["chargeback"] = respostas.get(f"chargeback|{meses}|", {})
        d["governanca"] = respostas.get(f"governanca|{meses}|", {})
        d["previsaoWorkloads"] = respostas.get(f"previsao|{meses}||servico", {}).get("workloads", [])
        d["ia"] = respostas.get(f"ia|{meses}|", {})
        d["bancos"] = respostas.get(f"bancos|{meses}|", {})
        exportacoes[str(meses)] = {
            "pdf": base64.b64encode(export_report.gerar_pdf(d)).decode("ascii"),
            "xlsx": base64.b64encode(export_report.gerar_excel(d)).decode("ascii"),
        }
    print(f"  exportações embutidas: {', '.join(f'{k} meses' for k in exportacoes)}")

    html = io.open(os.path.join(RAIZ, "static/index.html"), encoding="utf-8").read()
    css = io.open(os.path.join(RAIZ, "static/css/styles.css"), encoding="utf-8").read()
    js = "\n".join(io.open(os.path.join(RAIZ, f"static/js/{n}.js"), encoding="utf-8").read() for n in ("app", "pages", "pages2"))

    payload = json.dumps(respostas, ensure_ascii=False, separators=(",", ":"), default=str)
    payload_exp = json.dumps(exportacoes, separators=(",", ":"))

    banner = """
<div class="faixa-demo"><strong>Prévia com dados de demonstração.</strong> Os números são gerados artificialmente e não representam gasto real.
Serve para conhecer a interface antes de implantar. Cadastros e ações de alerta funcionam em memória e são perdidos ao fechar.
Exportar PDF e Excel funciona: são arquivos reais gerados pelo mesmo código do servidor, para 6 e 12 meses e todas as nuvens.</div>"""
    css_banner = """
.faixa-demo{background:linear-gradient(135deg,rgba(255,185,0,.16),rgba(247,99,12,.10));border:1px solid rgba(255,185,0,.42);border-radius:var(--raio-p);padding:11px 16px;margin-bottom:16px;font-size:12.5px;color:var(--texto)}
.faixa-demo strong{color:var(--amarelo)}"""

    interceptador = r"""
(function () {
  const D = window.__DADOS_PREVIA__;
  const mem = { alertas: JSON.parse(JSON.stringify(D['GET /api/alertas'])), regras: JSON.parse(JSON.stringify(D['GET /api/regras-alerta'])),
                centros: JSON.parse(JSON.stringify(D['GET /api/centros-custo'])), orcamentos: JSON.parse(JSON.stringify(D['GET /api/orcamentos'])),
                tags: JSON.parse(JSON.stringify(D['GET /api/configuracoes/tags-obrigatorias'])) };
  const ok = (c) => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(c) });
  const erro = (m) => Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({ detail: m }) });
  const id = () => Math.random().toString(16).slice(2, 14);
  const resumoAlertas = () => { const ab = mem.alertas.alertas.filter(a => a.estado === 'aberto'); const ps = {}; ab.forEach(a => ps[a.severidade] = (ps[a.severidade] || 0) + 1);
    return Object.assign({}, mem.alertas.resumo, { abertos: ab.length, reconhecidos: mem.alertas.alertas.filter(a => a.estado === 'reconhecido').length, porSeveridade: ps }); };

  window.fetch = function (url, op) {
    op = op || {}; const u = String(url); const metodo = (op.method || 'GET').toUpperCase();
    const [caminho, qs] = u.split('?'); const q = new URLSearchParams(qs || ''); const corpo = op.body ? JSON.parse(op.body) : {};
    const rota = caminho.replace(/^.*\/api\//, '');

    if (rota === 'health') return ok({ status: 'ok' });
    if (rota === 'sobre') return ok(D['GET /api/sobre']);
    if (rota === 'filtros') return ok(D['GET /api/filtros']);
    if (rota === 'status') return ok(Object.assign({}, D['GET /api/status'], { alertas: resumoAlertas() }));
    if (rota === 'refresh') return ok({ linhas: D['GET /api/status'].linhas, arquivos: 1, erro: null });
    if (rota === 'configuracoes/tags-obrigatorias') { if (metodo === 'POST') { mem.tags = { id: 'tags_obrigatorias', chaves: corpo.chaves }; } return ok(mem.tags); }

    if (rota === 'alertas' && metodo === 'GET') { const est = q.get('estado'); const lista = est ? mem.alertas.alertas.filter(a => a.estado === est) : mem.alertas.alertas;
      return ok(Object.assign({}, mem.alertas, { alertas: lista, resumo: resumoAlertas() })); }
    if (rota.startsWith('alertas/avaliar')) return ok({ novos: [], atualizados: mem.alertas.alertas.length, resolvidos: 0, regras: mem.regras.length });
    if (rota.startsWith('alertas/testar-email')) return ok({ ok: false, mensagem: 'e-mail nao configurado na prévia', destinatarios: [] });
    if (rota.startsWith('alertas/')) { const aid = rota.split('/')[1]; const a = mem.alertas.alertas.find(x => x.id === aid); if (!a) return erro('não encontrado');
      if (metodo === 'DELETE') { mem.alertas.alertas = mem.alertas.alertas.filter(x => x.id !== aid); return ok({ ok: true }); }
      if (metodo === 'PATCH') { a.estado = corpo.estado; if (corpo.comentario) a.comentario = corpo.comentario; return ok(a); } }

    const crud = (nome, colecao) => { if (rota === nome && metodo === 'GET') return ok(mem[colecao]);
      if (rota === nome && metodo === 'POST') { corpo.id = corpo.id || id(); const i = mem[colecao].findIndex(x => x.id === corpo.id); if (i >= 0) mem[colecao][i] = corpo; else mem[colecao].push(corpo); return ok(corpo); }
      if (rota.startsWith(nome + '/') && metodo === 'DELETE') { const rid = rota.split('/')[1]; mem[colecao] = mem[colecao].filter(x => x.id !== rid); return ok({ ok: true }); } return null; };
    if (rota.startsWith('centros-custo/importar')) return ok({ importados: 0, total: mem.centros.length });
    for (const [n, c] of [['centros-custo', 'centros'], ['orcamentos', 'orcamentos'], ['regras-alerta', 'regras']]) { const r = crud(n, c); if (r) return r; }
    if (rota.startsWith('export/')) {
      const E = window.__EXPORTS_PREVIA__ || {};
      const m0 = q.get('meses') || '6';
      const conj = E[m0] || E['6'] || E[Object.keys(E)[0]];
      if (!conj) return erro('Exportação indisponível nesta prévia.');
      const tipo = rota.endsWith('excel') ? 'xlsx' : 'pdf';
      const mime = tipo === 'xlsx' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'application/pdf';
      const bin = atob(conj[tipo]); const bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      const nome = `finops-${tipo === 'xlsx' ? 'dados' : 'relatorio'}-previa-${m0}m.${tipo}`;
      return Promise.resolve({ ok: true, status: 200, blob: () => Promise.resolve(new Blob([bytes], { type: mime })),
        headers: { get: (h) => h.toLowerCase() === 'content-disposition' ? `attachment; filename="${nome}"` : null } });
    }

    let meses = q.get('meses') || '0'; const nuvem = q.get('nuvens') || '';
    if (meses === '24' || meses === '0') meses = '12'; // na previa, 24 meses e "tudo" mostram os 12 disponiveis
    let chave = `${rota}|${meses}|${nuvem}`;
    if (rota === 'previsao') chave += `|${q.get('dimensao') || 'servico'}`;
    if (rota === 'chargeback' && q.get('distribuir') === 'false') chave += '|nodist';
    if (D[chave]) { const r = D[chave]; if (rota === 'chargeback') r.cadastro = mem.centros; if (rota === 'visao-geral') r.alertas = resumoAlertas(); return ok(r); }
    const alt = `${rota}|${meses}|` + (rota === 'previsao' ? `|${q.get('dimensao') || 'servico'}` : '');
    if (D[alt]) return ok(D[alt]);
    return erro('Esta combinação de filtros não está na prévia. Categoria e assinatura funcionam na aplicação publicada.');
  };
})();
"""

    html = html.replace('<link rel="stylesheet" href="/static/css/styles.css">', f"<style>\n{css}\n{css_banner}\n</style>")
    html = html.replace('<div id="alerta" class="alerta oculto"></div>', banner + '\n  <div id="alerta" class="alerta oculto"></div>')
    for fid, rot in (("filtro-categoria", "Categoria (na versão publicada)"), ("filtro-assinatura", "Assinatura (na versão publicada)")):
        html = html.replace(f'<select id="{fid}" class="campo">', f'<select id="{fid}" class="campo" disabled title="Disponível na aplicação publicada">')
    html = html.replace(
        '<script src="/static/js/app.js"></script>\n<script src="/static/js/pages.js"></script>\n<script src="/static/js/pages2.js"></script>',
        f"<script>window.__DADOS_PREVIA__ = {payload};</script>\n<script>window.__EXPORTS_PREVIA__ = {payload_exp};</script>\n<script>{interceptador}</script>\n<script>\n{js}\n</script>")
    html = html.replace("<title>FinOps Multicloud</title>", "<title>FinOps Multicloud, prévia</title>")

    saida = os.path.join(RAIZ, "FinOps-Preview.html")
    io.open(saida, "w", encoding="utf-8").write(html)
    print(f"\nPrévia gerada: {saida}\n  {os.path.getsize(saida) / 1024:,.0f} KB, arquivo único, abre com duplo clique")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
