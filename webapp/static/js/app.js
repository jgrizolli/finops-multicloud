/* ===========================================================================
   FinOps Multicloud
   Construído por Wanderlei Grizolli Junior, Sr. Solution Engineer.
   Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

   Núcleo da aplicação: estado, rede, formatação, gráficos, componentes e roteador.
   As páginas ficam em pages.js e se registram em window.Paginas.
   ======================================================================== */

const Estado = {
  rota: 'visao-geral', meses: 6, nuvem: '', categoria: '', assinatura: '', moeda: 'USD',
  graficos: [], tema: localStorage.getItem('finops-tema') || 'escuro', sobre: null
};

/* Cores FIXAS por nuvem. Valem em todo gráfico, etiqueta e legenda. */
const CORES_NUVEM = {
  'Microsoft Azure': '#0078D4',
  'Amazon Web Services': '#FF9900',
  'Google Cloud': '#34A853',
  'Oracle Cloud': '#C74634'
};
const corNuvem = (n) => CORES_NUVEM[n] || '#8B5CF6';

const PAGINAS_INFO = {
  'visao-geral': ['Visão geral', 'Custo consolidado de todas as nuvens, em formato FOCUS'],
  'tecnologia':  ['Por tecnologia', 'Onde o dinheiro está indo, por serviço, categoria e região'],
  'nuvens':      ['Por nuvem', 'Comparativo entre Azure, AWS, Google Cloud e Oracle Cloud'],
  'recursos':    ['Recursos', 'Os recursos que mais consomem, com detalhe por grupo'],
  'ia':          ['Inteligência artificial', 'Foundry, OpenAI, agentes, tokens e modelos, nas quatro nuvens'],
  'bancos':      ['Bancos de dados', 'Relacionais, NoSQL, cache e analíticos, com otimização e previsão'],
  'governanca':  ['Governança', 'Etiquetas, conformidade, recursos sem dono e orçamento por tag'],
  'chargeback':  ['Showback e chargeback', 'Quem gastou o quê, e quanto cobrar de cada área'],
  'otimizacao':  ['Otimização', 'Onde economizar: compromissos, horários, trocas de tecnologia e sobras'],
  'previsao':    ['Previsão', 'Para onde o custo vai em 30, 60 e 90 dias'],
  'alertas':     ['Alertas', 'O que saiu do controle, quem foi avisado e o que já foi tratado'],
  'insights':    ['Insights', 'Análise automática do seu próprio dado, sem enviar nada para fora'],
  'qualidade':   ['Qualidade do dado', 'Saúde da ingestão: meses, atraso, cobertura de tags'],
  'relatorio':   ['Relatório e exportação', 'Leitura executiva pronta para apresentar, em PDF ou Excel']
};

/* ------------------------------------------------------------- formatação */
const SIMBOLOS = { USD: 'US$', BRL: 'R$', EUR: '€', GBP: '£' };
function moeda(v, casas = 2) {
  if (v === null || v === undefined || isNaN(v)) return '--';
  const s = SIMBOLOS[Estado.moeda] || (Estado.moeda + ' ');
  const a = Math.abs(v);
  if (a >= 1e6) return `${s} ${(v / 1e6).toFixed(2)} mi`;
  if (a >= 1e3) return `${s} ${(v / 1e3).toFixed(1)} mil`;
  return `${s} ${v.toFixed(casas)}`;
}
function moedaCheia(v) {
  if (v === null || v === undefined || isNaN(v)) return '--';
  return `${SIMBOLOS[Estado.moeda] || (Estado.moeda + ' ')} ${v.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
const pct = (v) => (v === null || v === undefined || isNaN(v)) ? '--' : `${(v * 100).toFixed(1)}%`;
const num = (v) => (v === null || v === undefined || isNaN(v)) ? '--' : Number(v).toLocaleString('pt-BR');
function numCurto(v) {
  if (v === null || v === undefined || isNaN(v)) return '--';
  if (v >= 1e9) return `${(v / 1e9).toFixed(2)} bi`;
  if (v >= 1e6) return `${(v / 1e6).toFixed(2)} mi`;
  if (v >= 1e3) return `${(v / 1e3).toFixed(1)} mil`;
  return Number(v).toLocaleString('pt-BR');
}
function mesLegivel(m) {
  if (!m || m.length < 7) return m || '';
  const n = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
  return `${n[parseInt(m.slice(5, 7), 10) - 1]}/${m.slice(2, 4)}`;
}
function dataCurta(iso) {
  if (!iso) return '--';
  const d = new Date(iso);
  return isNaN(d) ? String(iso).slice(0, 10) : d.toLocaleDateString('pt-BR');
}
function escapar(t) {
  const d = document.createElement('div');
  d.textContent = t === null || t === undefined ? '' : String(t);
  return d.innerHTML;
}

/* ------------------------------------------------------------------- rede */
function paramsFiltro(extras = {}) {
  const p = new URLSearchParams();
  if (Estado.meses > 0) p.set('meses', Estado.meses);
  if (Estado.nuvem) p.append('nuvens', Estado.nuvem);
  if (Estado.categoria) p.append('categorias', Estado.categoria);
  if (Estado.assinatura) p.append('assinaturas', Estado.assinatura);
  Object.entries(extras).forEach(([k, v]) => { if (v !== undefined && v !== null && v !== '') p.set(k, v); });
  return p;
}
async function buscar(caminho, extras = {}) {
  const r = await fetch(`/api/${caminho}?${paramsFiltro(extras)}`);
  if (!r.ok) {
    let msg = `Erro ${r.status}`;
    try { msg = (await r.json()).detail || msg; } catch (_) {}
    throw new Error(msg);
  }
  return r.json();
}
async function enviar(caminho, metodo = 'POST', corpo = null) {
  const r = await fetch(`/api/${caminho}`, {
    method: metodo,
    headers: corpo !== null ? { 'Content-Type': 'application/json' } : {},
    body: corpo !== null ? JSON.stringify(corpo) : undefined
  });
  if (!r.ok) {
    let msg = `Erro ${r.status}`;
    try { msg = (await r.json()).detail || msg; } catch (_) {}
    throw new Error(msg);
  }
  return r.json();
}

function carregando(on) { document.getElementById('carregando').classList.toggle('oculto', !on); }
function alertar(msg, tipo = 'erro') {
  const el = document.getElementById('alerta');
  if (!msg) { el.classList.add('oculto'); return; }
  el.className = `alerta ${tipo === 'aviso' ? 'aviso' : ''}`;
  el.innerHTML = msg;
}
function toast(msg) {
  alertar(`<span style="color:var(--verde)">✓</span> ${escapar(msg)}`, 'aviso');
  setTimeout(() => alertar(''), 3500);
}

/* --------------------------------------------------------------- gráficos */
const PALETA = ['#0078D4', '#00B7C3', '#8B5CF6', '#2FBF71', '#FFB900', '#F7630C', '#50B0F0', '#E5484D', '#C239B3', '#498205'];
function baseGrafico() {
  const claro = document.body.classList.contains('claro');
  return { textoCor: claro ? '#52658A' : '#9BAAC4', linhaCor: claro ? '#DCE5F0' : '#24344F',
           fundoTip: claro ? '#FFFFFF' : '#1C2A47', bordaTip: claro ? '#DCE5F0' : '#24344F', tipTexto: claro ? '#10203A' : '#E8EEF7' };
}
function desenhar(id, opcao) {
  const el = document.getElementById(id);
  if (!el || typeof echarts === 'undefined') return null;
  const g = echarts.init(el, null, { renderer: 'canvas' });
  const b = baseGrafico();
  const comum = {
    color: PALETA, textStyle: { fontFamily: '"Segoe UI", sans-serif', color: b.textoCor },
    tooltip: { backgroundColor: b.fundoTip, borderColor: b.bordaTip, textStyle: { color: b.tipTexto, fontSize: 12 },
               extraCssText: 'border-radius:9px;box-shadow:0 4px 18px rgba(0,0,0,.25);' },
    grid: { left: 8, right: 16, top: 26, bottom: 8, containLabel: true }
  };
  g.setOption(Object.assign({}, comum, opcao, { tooltip: Object.assign({}, comum.tooltip, opcao.tooltip || {}) }));
  Estado.graficos.push(g);
  return g;
}
function eixoValor(b, fmt) {
  return { type: 'value', axisLabel: { color: b.textoCor, fontSize: 11, formatter: fmt || ((v) => moeda(v, 0)) },
           splitLine: { lineStyle: { color: b.linhaCor, type: 'dashed' } }, axisLine: { show: false }, axisTick: { show: false } };
}
function eixoCategoria(dados, b, rot = 0) {
  return { type: 'category', data: dados, axisLabel: { color: b.textoCor, fontSize: 11, rotate: rot },
           axisLine: { lineStyle: { color: b.linhaCor } }, axisTick: { show: false } };
}
function gradienteAzul() {
  return new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: 'rgba(0,120,212,.55)' }, { offset: 1, color: 'rgba(0,120,212,0)' }]);
}

/* linha: series = [{name, data, cor?, tracejado?, area?, stack?}] */
function grafLinha(id, categorias, series, op = {}) {
  const b = baseGrafico();
  const visiveis = series.filter(s => !s.oculta);
  desenhar(id, {
    tooltip: { trigger: 'axis', axisPointer: { type: 'line', lineStyle: { color: '#0078D4' } },
      formatter: (ps) => { let h = `<b>${ps[0].axisValueLabel}</b>`; ps.forEach(p => { const s = series.find(x => x.name === p.seriesName); if (p.value !== null && p.value !== undefined && !(s && s.oculta)) h += `<br>${p.marker} ${p.seriesName}: <b>${op.fmt ? op.fmt(p.value) : moedaCheia(p.value)}</b>`; }); return h; } },
    legend: visiveis.length > 1 ? { data: visiveis.map(s => s.name), textStyle: { color: b.textoCor, fontSize: 11 }, top: 0, icon: 'circle', itemWidth: 8, itemHeight: 8 } : { show: false },
    grid: { left: 8, right: 16, top: visiveis.length > 1 ? 34 : 18, bottom: 6, containLabel: true },
    xAxis: eixoCategoria(categorias, b), yAxis: eixoValor(b, op.fmt),
    series: series.map((s, i) => ({
      name: s.name, type: 'line', smooth: true, symbol: 'circle', symbolSize: 4, showSymbol: categorias.length <= 40 && !s.oculta,
      lineStyle: { width: s.oculta ? 0 : (s.largura || 2.4), type: s.tracejado ? 'dashed' : 'solid', color: s.cor, opacity: s.oculta ? 0 : 1 },
      itemStyle: { color: s.cor, opacity: s.oculta ? 0 : 1 }, data: s.data, stack: s.stack, z: s.z || 2,
      areaStyle: s.area ? { opacity: s.areaOpacidade ?? .22, color: s.corArea || s.cor || gradienteAzul() }
        : (op.area && i === 0) ? { opacity: .22, color: gradienteAzul() } : undefined
    }))
  });
}
function grafBarraH(id, itens, op = {}) {
  const b = baseGrafico();
  const ordenado = itens.slice().reverse();
  const campo = op.campo || 'efetivo';
  desenhar(id, {
    tooltip: { trigger: 'item', formatter: (p) => `<b>${p.name}</b><br>${op.fmt ? op.fmt(p.value) : moedaCheia(p.value)}` },
    grid: { left: 8, right: 60, top: 8, bottom: 6, containLabel: true },
    xAxis: Object.assign(eixoValor(b, op.fmt), { splitLine: { lineStyle: { color: b.linhaCor, type: 'dashed' } } }),
    yAxis: { type: 'category', data: ordenado.map(i => i.nome.length > 30 ? i.nome.slice(0, 29) + '…' : i.nome),
             axisLabel: { color: b.textoCor, fontSize: 11.5 }, axisLine: { show: false }, axisTick: { show: false } },
    series: [{ type: 'bar', barMaxWidth: 17,
      data: ordenado.map(i => { const c = op.corPor ? op.corPor(i.nome) : null; return { value: i[campo], itemStyle: { borderRadius: [0, 5, 5, 0],
        color: c || new echarts.graphic.LinearGradient(0, 0, 1, 0, [{ offset: 0, color: '#005A9E' }, { offset: 1, color: '#50B0F0' }]) } }; }),
      label: { show: true, position: 'right', color: b.textoCor, fontSize: 10.5, formatter: (p) => op.fmt ? op.fmt(p.value) : moeda(p.value, 0) } }]
  });
}
function grafRosca(id, itens, op = {}) {
  const b = baseGrafico();
  const campo = op.campo || 'efetivo';
  desenhar(id, {
    tooltip: { trigger: 'item', formatter: (p) => `<b>${p.name}</b><br>${op.fmt ? op.fmt(p.value) : moedaCheia(p.value)} (${p.percent}%)` },
    legend: { type: 'scroll', orient: 'vertical', right: 4, top: 'center', textStyle: { color: b.textoCor, fontSize: 11 }, icon: 'circle', itemWidth: 8, itemHeight: 8 },
    series: [{ type: 'pie', radius: ['52%', '76%'], center: ['34%', '50%'], avoidLabelOverlap: true,
      itemStyle: { borderRadius: 5, borderColor: 'transparent', borderWidth: 2 }, label: { show: false }, emphasis: { scale: true, scaleSize: 6 },
      data: itens.map(i => { const c = op.corPor ? op.corPor(i.nome) : null; return Object.assign({ name: i.nome, value: i[campo] }, c ? { itemStyle: { color: c } } : {}); }) }]
  });
}
function grafEmpilhado(id, dados, op = {}) {
  const b = baseGrafico();
  desenhar(id, {
    tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' },
      formatter: (ps) => { let h = `<b>${ps[0].axisValueLabel}</b>`, t = 0; ps.forEach(p => { t += p.value; h += `<br>${p.marker} ${p.seriesName}: <b>${moedaCheia(p.value)}</b>`; }); return h + `<br><span style="opacity:.7">Total: ${moedaCheia(t)}</span>`; } },
    legend: { textStyle: { color: b.textoCor, fontSize: 11 }, top: 0, icon: 'circle', itemWidth: 8, itemHeight: 8, type: 'scroll' },
    grid: { left: 8, right: 16, top: 34, bottom: 6, containLabel: true },
    xAxis: eixoCategoria(dados.meses.map(mesLegivel), b), yAxis: eixoValor(b),
    series: dados.series.map(s => { const c = op.corPor ? op.corPor(s.nome) : null; return Object.assign({ name: s.nome, type: 'bar', stack: 'total', barMaxWidth: 42, emphasis: { focus: 'series' }, data: s.valores }, c ? { itemStyle: { color: c } } : {}); })
  });
}
function grafMedidor(id, valor, titulo, cor) {
  const b = baseGrafico();
  desenhar(id, {
    series: [{ type: 'gauge', startAngle: 200, endAngle: -20, min: 0, max: 100, radius: '95%', center: ['50%', '62%'],
      progress: { show: true, width: 14, itemStyle: { color: cor || '#0078D4' } }, axisLine: { lineStyle: { width: 14, color: [[1, b.linhaCor]] } },
      axisTick: { show: false }, splitLine: { show: false }, axisLabel: { show: false }, pointer: { show: false },
      title: { show: true, offsetCenter: [0, '30%'], color: b.textoCor, fontSize: 11 },
      detail: { valueAnimation: true, offsetCenter: [0, '-8%'], fontSize: 24, fontWeight: 700, color: cor || '#0078D4', formatter: '{value}%' },
      data: [{ value: Math.round(valor * 100), name: titulo }] }]
  });
}

/* -------------------------------------------------------------- componentes */
function cardKpi(rotulo, valor, nota, destaque = false, pequeno = false) {
  return `<div class="card ${destaque ? 'destaque' : ''}"><div class="kpi-rotulo">${escapar(rotulo)}</div>
    <div class="kpi-valor ${pequeno ? 'pequeno' : ''}">${valor}</div>${nota ? `<div class="kpi-nota">${nota}</div>` : ''}</div>`;
}
function delta(v, invertido = false) {
  if (v === null || v === undefined || isNaN(v)) return '<span class="delta-igual">sem base</span>';
  const sobe = v > 0.005, desce = v < -0.005;
  const c = sobe ? (invertido ? 'delta-desce' : 'delta-sobe') : desce ? (invertido ? 'delta-sobe' : 'delta-desce') : 'delta-igual';
  return `<span class="kpi-delta ${c}">${sobe ? '▲' : desce ? '▼' : '='} ${pct(Math.abs(v))}</span>`;
}
function notaComparacao(r) {
  const base = `${delta(r.variacaoMensal)} contra ${moeda(r.mesAnterior)}`;
  if (r.comparacaoParcial) return `${base}<br><span style="opacity:.75">mesmos ${r.diasComparados} primeiros dias de ${mesLegivel(r.rotuloMesAnterior)}</span>`;
  return `${base} em ${mesLegivel(r.rotuloMesAnterior) || 'mês anterior'}`;
}
function cardGrafico(titulo, sub, id, classe = 'gr') {
  return `<div class="card"><div class="card-titulo">${escapar(titulo)}</div><div class="card-subtitulo">${escapar(sub)}</div><div id="${id}" class="${classe}"></div></div>`;
}
function tabela(cab, linhas, vazio = 'Nada a mostrar com os filtros atuais.') {
  if (!linhas.length) return `<div class="vazio">${escapar(vazio)}</div>`;
  return `<div class="tabela-caixa"><table><thead><tr>${cab.map(c => `<th class="${c.num ? 'num' : ''}">${escapar(c.t)}</th>`).join('')}</tr></thead><tbody>${linhas.join('')}</tbody></table></div>`;
}
function etiquetaNuvem(n) {
  return `<span class="etiqueta"><span class="ponto-nuvem" style="background:${corNuvem(n)}"></span>${escapar(n)}</span>`;
}
function barra(v, classes = '') {
  const p = Math.max(0, Math.round((v || 0) * 100));
  const c = classes || (v > 1 ? 'ruim' : v > .85 ? 'aviso' : 'ok');
  return `<div class="barra ${c}" title="${p}%"><span style="width:${Math.min(p, 100)}%"></span></div>`;
}
function abrirModal(titulo, html) {
  document.getElementById('modal-titulo').textContent = titulo;
  document.getElementById('modal-corpo').innerHTML = html;
  document.getElementById('modal').classList.remove('oculto');
}
function fecharModal() { document.getElementById('modal').classList.add('oculto'); }
function abas(id, itens, aoTrocar) {
  const el = document.getElementById(id);
  el.innerHTML = itens.map((t, i) => `<button class="aba ${i === 0 ? 'ativa' : ''}" data-i="${i}">${escapar(t)}</button>`).join('');
  el.querySelectorAll('.aba').forEach(b => b.addEventListener('click', () => {
    el.querySelectorAll('.aba').forEach(x => x.classList.remove('ativa'));
    b.classList.add('ativa'); aoTrocar(parseInt(b.dataset.i, 10));
  }));
}

/* ------------------------------------------------------------------ roteador */
window.Paginas = window.Paginas || {};
async function render() {
  Estado.graficos.forEach(g => { try { g.dispose(); } catch (_) {} });
  Estado.graficos = [];
  const info = PAGINAS_INFO[Estado.rota] || PAGINAS_INFO['visao-geral'];
  document.getElementById('titulo-pagina').textContent = info[0];
  document.getElementById('subtitulo-pagina').textContent = info[1];
  document.querySelectorAll('.nav-item').forEach(a => a.classList.toggle('ativo', a.dataset.rota === Estado.rota));
  carregando(true); alertar('');
  try {
    await (window.Paginas[Estado.rota] || window.Paginas['visao-geral'])();
  } catch (e) {
    document.getElementById('pagina').innerHTML = '';
    alertar(`<b>Não consegui carregar os dados.</b><br>${escapar(e.message)}<br><br>Verifique o diagnóstico em <code>/api/status</code>.`);
  } finally { carregando(false); }
}
function irPara() {
  const h = (location.hash || '#/visao-geral').replace('#/', '').split('?')[0];
  Estado.rota = window.Paginas[h] ? h : 'visao-geral';
  render();
}

/* -------------------------------------------------------------------- setup */
async function carregarFiltros() {
  try {
    const f = await (await fetch('/api/filtros')).json();
    const preencher = (id, valores, rotulo) => {
      const el = document.getElementById(id);
      el.innerHTML = `<option value="">${rotulo}</option>` + valores.map(v => `<option value="${escapar(v)}">${escapar(v)}</option>`).join('');
    };
    preencher('filtro-nuvem', f.nuvens || [], 'Todas as nuvens');
    preencher('filtro-categoria', f.categorias || [], 'Todas as categorias');
    preencher('filtro-assinatura', f.assinaturas || [], 'Todas as assinaturas');
  } catch (_) {}
}
async function verificarStatus() {
  const caixa = document.getElementById('status-fonte'), texto = document.getElementById('status-texto');
  try {
    const s = await (await fetch('/api/status')).json();
    if (s.erro) { caixa.className = 'status-fonte erro'; texto.textContent = 'sem dados'; alertar(`<b>A ingestão ainda não tem dado.</b><br>${escapar(s.erro)}`, 'aviso'); }
    else {
      caixa.className = 'status-fonte ok';
      const origem = s.backend === 'kusto' ? 'Fabric/Kusto' : s.backend === 'storage' ? 'storage' : (s.backend || 'fonte');
      texto.textContent = `${num(s.linhas)} linhas, ${(s.meses || []).length} meses · ${origem}`;
      caixa.title = `${s.fonte || s.storage}, ${s.arquivos} arquivo(s)/consulta(s), ${s.megabytes} MB`;
    }
    atualizarBadge(s.alertas);
  } catch (_) { caixa.className = 'status-fonte erro'; texto.textContent = 'indisponível'; }
}
function atualizarBadge(resumo) {
  const b = document.getElementById('badge-alertas');
  if (!resumo) return;
  const n = resumo.abertos || 0;
  b.textContent = n; b.classList.toggle('oculto', n === 0);
}
async function carregarSobre() {
  try {
    Estado.sobre = await (await fetch('/api/sobre')).json();
    document.getElementById('rodape-credito').innerHTML = `<span class="credito">${escapar(Estado.sobre.creditoCurto)}</span>`;
  } catch (_) {}
}
function mostrarSobre() {
  const s = Estado.sobre || {};
  abrirModal(`${s.nome || 'FinOps Multicloud'} ${s.versao || ''}`, `
    <p>${escapar(s.creditoLongo || '')}</p>
    <p><b>Autor:</b> ${escapar(s.autor || '')}, ${escapar(s.cargo || '')}${s.linkedin ? ` · <a href="${s.linkedin}" target="_blank" rel="noopener">LinkedIn</a>` : ''}</p>
    <p><b>Baseado em:</b> <a href="${s.baseadoEmUrl || '#'}" target="_blank" rel="noopener">${escapar(s.baseadoEm || '')}</a></p>
    <p><b>Padrão de dados:</b> ${escapar(s.padraoDados || '')}</p>
    <p class="ajuda">Os insights, previsões e recomendações são regras estatísticas determinísticas sobre o seu próprio dado. Nenhuma informação é enviada para fora da sua assinatura.</p>`);
}
function aplicarTema() {
  const claro = Estado.tema === 'claro';
  document.body.classList.toggle('claro', claro);
  document.getElementById('icone-tema').textContent = claro ? '☾' : '☀';
  document.getElementById('texto-tema').textContent = claro ? 'Tema escuro' : 'Tema claro';
}
/* Exportação por fetch, e não por link direto: assim dá para mostrar o spinner, tratar erro
   (dado ainda não carregado, sessão expirada) e funcionar também na prévia em arquivo único. */
async function baixarExport(tipo) {
  const url = `/api/export/${tipo === 'excel' ? 'excel' : 'pdf'}?${paramsFiltro()}`;
  carregando(true);
  try {
    const r = await fetch(url);
    if (!r.ok) {
      let msg = `Erro ${r.status}`;
      try { msg = (await r.json()).detail || msg; } catch (_) {}
      throw new Error(msg);
    }
    const blob = await r.blob();
    let nome = `finops-${tipo === 'excel' ? 'dados' : 'relatorio'}-${new Date().toISOString().slice(0, 10)}.${tipo === 'excel' ? 'xlsx' : 'pdf'}`;
    const cd = r.headers && r.headers.get ? r.headers.get('content-disposition') : null;
    const m = cd && cd.match(/filename="?([^";]+)"?/);
    if (m) nome = m[1];
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob); a.download = nome;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    toast(`${tipo === 'excel' ? 'Excel' : 'PDF'} gerado: ${nome}`);
  } catch (e) {
    alertar(`<b>Não consegui gerar a exportação.</b><br>${escapar(e.message)}`);
  } finally { carregando(false); }
}
function atualizarLinksExport() { /* mantido por compatibilidade; os botões chamam baixarExport */ }
function iniciar() {
  aplicarTema(); atualizarLinksExport();
  const rerender = () => { atualizarLinksExport(); render(); };
  document.getElementById('filtro-meses').addEventListener('change', e => { Estado.meses = parseInt(e.target.value, 10); rerender(); });
  document.getElementById('filtro-nuvem').addEventListener('change', e => { Estado.nuvem = e.target.value; rerender(); });
  document.getElementById('filtro-categoria').addEventListener('change', e => { Estado.categoria = e.target.value; rerender(); });
  document.getElementById('filtro-assinatura').addEventListener('change', e => { Estado.assinatura = e.target.value; rerender(); });
  document.getElementById('btn-atualizar').addEventListener('click', async () => {
    carregando(true);
    try { await fetch('/api/refresh', { method: 'POST' }); } catch (_) {}
    await verificarStatus(); await carregarFiltros(); await render();
  });
  document.getElementById('btn-tema').addEventListener('click', () => {
    Estado.tema = Estado.tema === 'claro' ? 'escuro' : 'claro'; localStorage.setItem('finops-tema', Estado.tema); aplicarTema(); render();
  });
  document.getElementById('btn-sobre').addEventListener('click', mostrarSobre);
  document.getElementById('modal-fechar').addEventListener('click', fecharModal);
  document.getElementById('modal').addEventListener('click', e => { if (e.target.id === 'modal') fecharModal(); });
  document.getElementById('btn-exportar').addEventListener('click', e => { e.stopPropagation(); document.getElementById('menu-export').classList.toggle('oculto'); });
  document.getElementById('exp-pdf').addEventListener('click', e => { e.preventDefault(); baixarExport('pdf'); });
  document.getElementById('exp-xlsx').addEventListener('click', e => { e.preventDefault(); baixarExport('excel'); });
  document.addEventListener('click', () => document.getElementById('menu-export').classList.add('oculto'));
  window.addEventListener('hashchange', irPara);
  window.addEventListener('resize', () => Estado.graficos.forEach(g => { try { g.resize(); } catch (_) {} }));
  verificarStatus(); carregarFiltros(); carregarSobre(); irPara();
}
document.addEventListener('DOMContentLoaded', iniciar);
