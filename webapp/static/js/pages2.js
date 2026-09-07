/* ===========================================================================
   FinOps Multicloud
   Construído por Wanderlei Grizolli Junior, Sr. Solution Engineer.
   Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

   Páginas de gestão e operação: governança, chargeback, alertas, insights,
   qualidade do dado e relatório.
   ======================================================================== */

const P2 = window.Paginas;
const el2 = () => document.getElementById('pagina');

/* --------------------------------------------------------------- governança */
P2['governanca'] = async function () {
  const tag = Estado.govTag || '';
  const d = await buscar('governanca', { tag }); Estado.moeda = d.resumo.moeda || Estado.moeda;
  const r = d.resumo;
  const corConf = (v) => v >= .9 ? 'ok' : v >= .6 ? 'aviso' : 'ruim';
  el2().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Gasto com etiqueta', pct(1 - (r.percentualSemTag || 0)), `${moedaCheia(r.comTag || 0)} de ${moedaCheia(r.total || 0)}`, true)}
      ${cardKpi('Gasto sem etiqueta', moedaCheia(r.semTag || 0), `${pct(r.percentualSemTag || 0)} do total, ${num(r.recursosSemTag || 0)} recursos`)}
      ${cardKpi('Conformidade média', pct(r.conformidadeMedia || 0), `nas ${(d.obrigatorias || []).length} tags obrigatórias`)}
      ${cardKpi('Chaves de tag em uso', r.chavesDistintas || 0, 'Chaves distintas encontradas no período')}
    </div>
    <div class="grade g2">
      <div class="card"><div class="card-titulo">Conformidade das tags obrigatórias</div><div class="card-subtitulo">Quanto do gasto carrega cada tag exigida. <a href="#" id="gov-editar-obrig" style="color:var(--azul-claro)">Editar lista</a></div>
        ${d.conformidade.map(c => `<div style="margin:10px 0"><div style="display:flex;justify-content:space-between;font-size:12.5px;margin-bottom:5px"><b>${escapar(c.chave)}</b><span>${pct(c.percentual)} · ${moeda(c.descoberto)} descoberto</span></div>${barra(c.percentual, corConf(c.percentual))}</div>`).join('')}
      </div>
      ${cardGrafico('Cobertura por chave', 'Quanto do gasto total carrega cada chave', 'g-gov-cob', 'gr alto')}
    </div>
    <div class="grade g2">
      <div class="card">
        <div style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap"><div><div class="card-titulo">Custo por valor da tag</div><div class="card-subtitulo">Distribuição do gasto pelos valores de uma chave</div></div>
          <select id="gov-tag" class="campo">${(d.chavesDisponiveis || []).map(k => `<option value="${escapar(k)}" ${k === d.chave ? 'selected' : ''}>${escapar(k)}</option>`).join('')}</select></div>
        <div id="g-gov-val" class="gr alto"></div>
      </div>
      ${cardGrafico('Por ambiente', 'Classificação por tag Environment e por padrão de nome', 'g-gov-amb', 'gr alto')}
    </div>
    <div class="card"><div class="card-titulo">Orçamentos por tag</div><div class="card-subtitulo">Gasto do mês corrente contra o orçamento cadastrado. <a href="#" id="gov-novo-orc" style="color:var(--azul-claro)">Novo orçamento</a></div>
      ${d.orcamentosTag.length ? tabela([{ t: 'Orçamento' }, { t: 'Tag' }, { t: 'Orçamento mensal', num: true }, { t: 'Gasto no mês', num: true }, { t: 'Uso' }, { t: '' }],
        d.orcamentosTag.map(o => `<tr><td class="forte">${escapar(o.nome)}</td><td><span class="etiqueta">${escapar(o.chave)}=${escapar(o.valor)}</span></td><td class="num">${moedaCheia(o.orcamento)}</td><td class="num">${moedaCheia(o.gasto)}</td><td style="min-width:140px">${barra(o.uso)}<span class="ajuda">${pct(o.uso)}</span></td><td class="direita"><button class="btn btn-perigo btn-pequeno" data-del-orc="${o.id}">remover</button></td></tr>`))
        : '<div class="vazio">Nenhum orçamento por tag cadastrado. Cadastre para acompanhar o gasto de cada centro contra o planejado.</div>'}
    </div>
    <div class="card"><div class="card-titulo">Recursos sem etiqueta que mais custam</div><div class="card-subtitulo">Comece por aqui: são os que não têm dono</div>
      ${tabela([{ t: 'Recurso' }, { t: 'Serviço' }, { t: 'Grupo' }, { t: 'Assinatura' }, { t: 'Nuvem' }, { t: 'Custo', num: true }],
        d.semTag.map(x => `<tr><td class="forte celula-larga">${escapar(x.recurso)}</td><td>${escapar(x.servico)}</td><td>${escapar(x.grupo)}</td><td>${escapar(x.assinatura)}</td><td>${etiquetaNuvem(x.nuvem)}</td><td class="num">${moedaCheia(x.efetivo)}</td></tr>`), 'Todos os recursos têm ao menos uma etiqueta.')}
    </div>`;
  grafBarraH('g-gov-cob', d.cobertura.map(c => ({ nome: c.chave, efetivo: c.cobertura })), { fmt: pct });
  grafRosca('g-gov-val', d.porValor.map(v => ({ nome: v.valor, efetivo: v.efetivo })));
  grafRosca('g-gov-amb', d.ambientes, { corPor: (n) => ({ 'Produção': '#0078D4', 'Não produção': '#FFB900', 'Desconhecido': '#6B7C99' })[n] });
  document.getElementById('gov-tag').addEventListener('change', e => { Estado.govTag = e.target.value; render(); });
  document.getElementById('gov-editar-obrig').addEventListener('click', e => { e.preventDefault(); formTagsObrigatorias(d.obrigatorias || []); });
  document.getElementById('gov-novo-orc').addEventListener('click', e => { e.preventDefault(); formOrcamento(d.chavesDisponiveis || []); });
  document.querySelectorAll('[data-del-orc]').forEach(b => b.addEventListener('click', async () => { if (confirm('Remover este orçamento?')) { await enviar(`orcamentos/${b.dataset.delOrc}`, 'DELETE'); toast('Orçamento removido'); render(); } }));
};

function formTagsObrigatorias(atuais) {
  abrirModal('Tags obrigatórias', `<p>Uma chave por linha. São as tags que a governança exige em todo recurso, e a conformidade é medida sobre elas.</p>
    <div class="form"><label class="largo">Chaves<textarea id="f-chaves" rows="5">${escapar(atuais.join('\n'))}</textarea></label></div>
    <div class="form-acoes"><button class="btn" id="f-salvar">Salvar</button></div>`);
  document.getElementById('f-salvar').addEventListener('click', async () => {
    const chaves = document.getElementById('f-chaves').value.split('\n').map(s => s.trim()).filter(Boolean);
    await enviar('configuracoes/tags-obrigatorias', 'POST', { chaves }); fecharModal(); toast('Tags obrigatórias salvas'); render();
  });
}
function formOrcamento(chaves) {
  abrirModal('Novo orçamento', `<div class="form">
      <label>Nome<input id="f-nome" placeholder="Ex.: Plataforma 2026"></label>
      <label>Valor mensal<input id="f-valor" type="number" min="0" step="100" placeholder="45000"></label>
      <label>Escopo<select id="f-escopo"><option value="tag">Tag</option><option value="total">Total</option><option value="nuvem">Nuvem</option><option value="assinatura">Assinatura</option><option value="servico">Serviço</option><option value="grupo">Grupo de recurso</option></select></label>
      <label id="l-chave">Chave da tag<input id="f-chave" list="dl-chaves" placeholder="CostCenter"><datalist id="dl-chaves">${chaves.map(k => `<option value="${escapar(k)}">`).join('')}</datalist></label>
      <label id="l-val">Valor<input id="f-val" placeholder="CC-1001 (ou o nome da nuvem, assinatura, serviço)"></label>
    </div><div class="form-acoes"><button class="btn" id="f-salvar">Salvar</button></div>`);
  const esc = document.getElementById('f-escopo');
  const atualizar = () => { document.getElementById('l-chave').style.display = esc.value === 'tag' ? '' : 'none'; document.getElementById('l-val').style.display = esc.value === 'total' ? 'none' : ''; };
  esc.addEventListener('change', atualizar); atualizar();
  document.getElementById('f-salvar').addEventListener('click', async () => {
    try {
      await enviar('orcamentos', 'POST', { nome: document.getElementById('f-nome').value, valorMensal: parseFloat(document.getElementById('f-valor').value || 0),
        escopoTipo: esc.value, chave: document.getElementById('f-chave').value, valor: document.getElementById('f-val').value });
      fecharModal(); toast('Orçamento salvo'); render();
    } catch (e) { alert(e.message); }
  });
}

/* --------------------------------------------------------------- chargeback */
P2['chargeback'] = async function () {
  const distribuir = Estado.cbDistribuir !== false;
  const d = await buscar('chargeback', { distribuir }); Estado.moeda = d.resumo.moeda || Estado.moeda;
  const r = d.resumo;
  const centros = d.centros.filter(c => c.centro !== 'Não alocado');
  const naoAloc = d.centros.find(c => c.centro === 'Não alocado');
  el2().innerHTML = `
    ${d.automatico ? `<div class="alerta aviso"><b>Showback automático.</b> Nenhum centro de custo cadastrado, então as áreas foram derivadas da tag <b>${escapar(d.chaveAutomatica || '')}</b>. Cadastre os centros para nomear as áreas, atribuir responsáveis, orçamentos e regras por assinatura ou grupo.</div>` : ''}
    <div class="grade kpi">
      ${cardKpi('Custo alocado', pct(r.percentualAlocado || 0), `${moedaCheia(r.alocado || 0)} atribuídos a ${r.centros || 0} centro(s)`, true)}
      ${cardKpi('Não alocado (compartilhado)', moedaCheia(r.naoAlocado || 0), distribuir ? 'Distribuído proporcionalmente no chargeback' : 'Mantido à parte no chargeback')}
      ${cardKpi('Total do período', moedaCheia(r.total || 0), `mês corrente: ${r.mesCorrente || ''}`)}
      ${cardKpi('Centros cadastrados', (d.cadastro || []).length, `<a href="#" id="cb-novo" style="color:var(--azul-claro)">Novo centro</a> · <a href="#" id="cb-importar" style="color:var(--azul-claro)">Importar</a>`)}
    </div>
    <div class="abas" id="cb-abas"></div>
    <div id="cb-conteudo"></div>`;
  const conteudo = document.getElementById('cb-conteudo');
  const desenharAba = (i) => {
    Estado.graficos.forEach(g => { try { g.dispose(); } catch (_) {} }); Estado.graficos = [];
    if (i === 0) {
      conteudo.innerHTML = `<div class="grade g2">${cardGrafico('Evolução por centro de custo', 'Custo direto mês a mês', 'g-cb-evol', 'gr alto')}${cardGrafico('Participação', 'Divisão do custo direto', 'g-cb-part', 'gr alto')}</div>
        <div class="card"><div class="card-titulo">Showback: o que cada área consumiu</div><div class="card-subtitulo">Custo direto, sem redistribuição. É a visão para conscientizar</div>
        ${tabela([{ t: 'Centro de custo' }, { t: 'Responsável' }, { t: 'Custo direto', num: true }, { t: 'Participação', num: true }, { t: 'Gasto no mês', num: true }, { t: 'Orçamento' }, { t: 'Principais serviços' }],
          d.centros.map(c => `<tr><td class="forte">${escapar(c.centro)}</td><td>${escapar(c.responsavel || '')}${c.email ? `<br><span class="ajuda">${escapar(c.email)}</span>` : ''}</td><td class="num">${moedaCheia(c.direto)}</td><td class="num">${pct(c.participacao)}</td><td class="num">${moedaCheia(c.gastoMes)}</td>
            <td style="min-width:130px">${c.orcamentoMensal ? `${barra(c.usoOrcamento)}<span class="ajuda">${pct(c.usoOrcamento)} de ${moeda(c.orcamentoMensal)}</span>` : '<span class="ajuda">sem orçamento</span>'}</td>
            <td class="texto-2" style="font-size:11.5px">${(d.detalhe[c.centro] || []).slice(0, 3).map(s => `${escapar(s.servico)} ${moeda(s.efetivo, 0)}`).join(' · ')}</td></tr>`))}</div>`;
      grafEmpilhado('g-cb-evol', d.mensal); grafRosca('g-cb-part', d.centros.map(c => ({ nome: c.centro, efetivo: c.direto })));
    } else if (i === 1) {
      conteudo.innerHTML = `<div class="card"><div style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap">
          <div><div class="card-titulo">Chargeback: quanto cobrar de cada área</div><div class="card-subtitulo">Custo direto mais a fatia do custo compartilhado</div></div>
          <label style="display:flex;gap:8px;align-items:center;font-size:12.5px"><input type="checkbox" id="cb-dist" ${distribuir ? 'checked' : ''}> Distribuir o não alocado proporcionalmente</label></div>
        ${tabela([{ t: 'Centro de custo' }, { t: 'Responsável' }, { t: 'Custo direto', num: true }, { t: 'Rateio do compartilhado', num: true }, { t: 'Valor a cobrar', num: true }, { t: 'Faturado (referência)', num: true }],
          centros.map(c => `<tr><td class="forte">${escapar(c.centro)}</td><td>${escapar(c.responsavel || '')}</td><td class="num">${moedaCheia(c.direto)}</td><td class="num">${moedaCheia(c.rateio)}</td><td class="num forte">${moedaCheia(c.cobrar)}</td><td class="num texto-2">${moedaCheia(c.faturado)}</td></tr>`)
            .concat(naoAloc && !distribuir ? [`<tr><td class="forte texto-2">Não alocado (fica com TI)</td><td></td><td class="num">${moedaCheia(naoAloc.direto)}</td><td class="num">--</td><td class="num">${moedaCheia(naoAloc.direto)}</td><td class="num texto-2">${moedaCheia(naoAloc.faturado)}</td></tr>`] : []))}
        <div class="ajuda" style="margin-top:10px">O rateio distribui o custo não alocado (${moedaCheia(r.naoAlocado || 0)}) na proporção do custo direto de cada área. Para uma fatura interna por área, use a exportação Excel: a aba Chargeback traz estes valores.</div></div>`;
      document.getElementById('cb-dist').addEventListener('change', e => { Estado.cbDistribuir = e.target.checked; render(); });
    } else {
      conteudo.innerHTML = `<div class="card"><div class="card-titulo">Cadastro de centros de custo</div><div class="card-subtitulo">Cada linha de custo vai para o primeiro centro cuja regra bater, na ordem abaixo. O que não bater em ninguém fica como não alocado</div>
        ${tabela([{ t: 'Centro' }, { t: 'Responsável' }, { t: 'Orçamento mensal', num: true }, { t: 'Regras' }, { t: '' }],
          (d.cadastro || []).map(c => `<tr><td class="forte">${escapar(c.nome)}</td><td>${escapar(c.responsavel || '')}<br><span class="ajuda">${escapar(c.email || '')}</span></td><td class="num">${c.orcamentoMensal ? moedaCheia(c.orcamentoMensal) : '--'}</td>
            <td><div class="chip-lista">${(c.regras || []).map(rg => `<span class="chip">${escapar(rg.tipo)}${rg.chave ? ` ${escapar(rg.chave)}` : ''} = ${escapar(rg.valor || '*')}</span>`).join('')}</div></td>
            <td class="direita nowrap"><button class="btn btn-secundario btn-pequeno" data-edit="${c.id}">editar</button> <button class="btn btn-perigo btn-pequeno" data-del="${c.id}">remover</button></td></tr>`), 'Nenhum centro cadastrado. Use "Novo centro" ou "Importar".')}
        <div class="ajuda" style="margin-top:12px"><b>Integração com CMDB:</b> envie a lista de centros para <code>POST /api/centros-custo/importar</code> em JSON ou CSV (<code>?formato=csv</code>). Um job agendado que consulta o CMDB e chama esse endpoint mantém o cadastro sincronizado. Com <code>&amp;substituir=true</code> o cadastro é recriado do zero.</div></div>`;
      conteudo.querySelectorAll('[data-edit]').forEach(b => b.addEventListener('click', () => formCentro((d.cadastro || []).find(c => c.id === b.dataset.edit))));
      conteudo.querySelectorAll('[data-del]').forEach(b => b.addEventListener('click', async () => { if (confirm('Remover este centro de custo?')) { await enviar(`centros-custo/${b.dataset.del}`, 'DELETE'); toast('Centro removido'); render(); } }));
    }
  };
  abas('cb-abas', ['Showback', 'Chargeback', 'Cadastro'], desenharAba);
  desenharAba(Estado.cbAba || 0);
  document.getElementById('cb-novo').addEventListener('click', e => { e.preventDefault(); formCentro(null); });
  document.getElementById('cb-importar').addEventListener('click', e => { e.preventDefault(); formImportar(); });
};

function formCentro(c) {
  c = c || { nome: '', responsavel: '', email: '', orcamentoMensal: 0, regras: [{ tipo: 'tag', chave: 'CostCenter', valor: '' }] };
  const linhaRegra = (r = {}) => `<div class="regra"><select class="r-tipo">${['tag', 'assinatura', 'grupo', 'nuvem', 'servico', 'conta'].map(t => `<option ${r.tipo === t ? 'selected' : ''}>${t}</option>`).join('')}</select>
    <input class="r-chave" placeholder="chave (só para tag)" value="${escapar(r.chave || '')}"><input class="r-valor" placeholder="valor (* aceita qualquer; sufixo* faz prefixo)" value="${escapar(r.valor || '')}"><button class="btn-x r-del">✕</button></div>`;
  abrirModal(c.id ? 'Editar centro de custo' : 'Novo centro de custo', `<div class="form">
      <label>Nome<input id="f-nome" value="${escapar(c.nome)}"></label><label>Responsável<input id="f-resp" value="${escapar(c.responsavel || '')}"></label>
      <label>E-mail<input id="f-email" type="email" value="${escapar(c.email || '')}"></label><label>Orçamento mensal<input id="f-orc" type="number" min="0" step="100" value="${c.orcamentoMensal || ''}"></label>
      <div class="largo"><div class="kpi-rotulo" style="margin-bottom:8px">Regras de alocação</div><div class="regras" id="f-regras">${(c.regras || []).map(linhaRegra).join('')}</div>
      <button class="btn btn-secundario btn-pequeno" id="f-add" style="margin-top:8px">+ regra</button>
      <div class="ajuda" style="margin-top:8px">tag: chave e valor da etiqueta. assinatura, grupo, nuvem, servico, conta: só o valor. A primeira regra que bater vence.</div></div>
    </div><div class="form-acoes"><button class="btn" id="f-salvar">Salvar</button></div>`);
  const cont = document.getElementById('f-regras');
  const ligarDel = () => cont.querySelectorAll('.r-del').forEach(b => b.onclick = () => b.parentElement.remove());
  ligarDel();
  document.getElementById('f-add').addEventListener('click', () => { cont.insertAdjacentHTML('beforeend', linhaRegra()); ligarDel(); });
  document.getElementById('f-salvar').addEventListener('click', async () => {
    const regras = [...cont.querySelectorAll('.regra')].map(r => ({ tipo: r.querySelector('.r-tipo').value, chave: r.querySelector('.r-chave').value.trim(), valor: r.querySelector('.r-valor').value.trim() })).filter(r => r.valor || r.tipo === 'tag');
    try {
      await enviar('centros-custo', 'POST', { id: c.id, nome: document.getElementById('f-nome').value, responsavel: document.getElementById('f-resp').value, email: document.getElementById('f-email').value,
        orcamentoMensal: parseFloat(document.getElementById('f-orc').value || 0), regras, ativo: true });
      fecharModal(); toast('Centro de custo salvo'); Estado.cbAba = 2; render();
    } catch (e) { alert(e.message); }
  });
}
function formImportar() {
  abrirModal('Importar centros de custo', `<p>Cole um JSON (lista de centros) ou um CSV com as colunas <code>nome,responsavel,email,orcamentoMensal,tipo,chave,valor</code>. No CSV, repita o nome em cada linha de regra.</p>
    <div class="form"><label>Formato<select id="f-fmt"><option value="json">JSON</option><option value="csv">CSV</option></select></label>
      <label style="flex-direction:row;align-items:center;gap:8px"><input type="checkbox" id="f-subst"> Substituir o cadastro atual</label>
      <label class="largo">Conteúdo<textarea id="f-conteudo" rows="10" placeholder='[{"nome":"Plataforma","responsavel":"Ana","email":"ana@x.com","orcamentoMensal":45000,"regras":[{"tipo":"tag","chave":"CostCenter","valor":"CC-1001"}]}]'></textarea></label></div>
    <div class="form-acoes"><button class="btn" id="f-salvar">Importar</button></div>`);
  document.getElementById('f-salvar').addEventListener('click', async () => {
    const fmt = document.getElementById('f-fmt').value, subst = document.getElementById('f-subst').checked;
    const r = await fetch(`/api/centros-custo/importar?formato=${fmt}&substituir=${subst}`, { method: 'POST', body: document.getElementById('f-conteudo').value });
    if (!r.ok) { alert((await r.json()).detail); return; }
    const j = await r.json(); fecharModal(); toast(`${j.importados} centro(s) importado(s)`); Estado.cbAba = 2; render();
  });
}

/* ------------------------------------------------------------------ alertas */
P2['alertas'] = async function () {
  const filtro = Estado.alFiltro || 'ativos';
  const d = await enviar(`alertas${filtro === 'todos' ? '' : filtro === 'ativos' ? '' : `?estado=${filtro}`}`, 'GET');
  atualizarBadge(d.resumo);
  let lista = d.alertas;
  if (filtro === 'ativos') lista = lista.filter(a => a.estado === 'aberto' || a.estado === 'reconhecido');
  const regras = await enviar('regras-alerta', 'GET');
  const em = d.resumo.email || {};
  const IC = { critico: '!', atencao: '▲', informativo: 'i' };
  el2().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Alertas abertos', d.resumo.abertos, `${d.resumo.porSeveridade.critico || 0} críticos, ${d.resumo.porSeveridade.atencao || 0} de atenção`, true)}
      ${cardKpi('Reconhecidos', d.resumo.reconhecidos, 'Alguém já está tratando')}
      ${cardKpi('Regras ativas', regras.filter(r => r.ativo).length, `${regras.length} cadastradas · <a href="#" id="al-nova" style="color:var(--azul-claro)">nova regra</a>`)}
      ${cardKpi('Envio de e-mail', em.ativo ? '<span style="color:var(--verde)">ativo</span>' : '<span style="color:var(--amarelo)">só painel</span>', em.ativo ? `${em.acs ? 'Azure Communication Services' : 'SMTP'} · <a href="#" id="al-teste" style="color:var(--azul-claro)">testar</a>` : 'Configure ACS_ENDPOINT e EMAIL_SENDER para receber por e-mail', false, true)}
    </div>
    <div class="abas" id="al-abas"></div>
    <div id="al-conteudo"></div>`;
  const cont = document.getElementById('al-conteudo');
  const desenharAba = (i) => {
    if (i === 0) {
      cont.innerHTML = `<div style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:12px">
          <select id="al-filtro" class="campo">${[['ativos', 'Abertos e reconhecidos'], ['aberto', 'Só abertos'], ['reconhecido', 'Só reconhecidos'], ['resolvido', 'Resolvidos'], ['descartado', 'Descartados'], ['todos', 'Todos']].map(([v, t]) => `<option value="${v}" ${v === filtro ? 'selected' : ''}>${t}</option>`).join('')}</select>
          <div style="display:flex;gap:8px"><button class="btn btn-secundario btn-pequeno" id="al-avaliar">Avaliar agora</button></div></div>
        <div class="grade" style="gap:10px">${lista.length ? lista.map(a => `
          <div class="achado ${a.severidade} ${a.estado}"><div class="achado-icone">${IC[a.severidade] || 'i'}</div><div class="achado-corpo">
            <div class="achado-titulo">${escapar(a.titulo)} <span class="estado ${a.estado}">${escapar(a.estado)}</span> <span class="etiqueta">${escapar(a.regraNome)}</span> <span class="etiqueta">${escapar(a.escopo)}</span></div>
            <div class="achado-detalhe">${escapar(a.detalhe)}</div>
            ${a.acao ? `<div class="achado-acao"><strong>O que fazer:</strong> ${escapar(a.acao)}</div>` : ''}
            <div class="ajuda" style="margin-top:6px">Aberto em ${dataCurta(a.abertoEm)}${a.notificado ? ' · e-mail enviado' : a.notificacao && a.notificacao !== 'e-mail nao configurado' ? ` · e-mail: ${escapar(a.notificacao)}` : ''}${a.comentario ? ` · <i>${escapar(a.comentario)}</i>` : ''}</div>
            <div class="achado-acoes">
              ${a.estado === 'aberto' ? `<button class="btn btn-secundario btn-pequeno" data-ack="${a.id}">Reconhecer</button>` : ''}
              ${a.estado !== 'resolvido' ? `<button class="btn btn-secundario btn-pequeno" data-res="${a.id}">Resolver</button>` : ''}
              ${a.estado !== 'descartado' ? `<button class="btn btn-secundario btn-pequeno" data-desc="${a.id}">Descartar</button>` : ''}
              <button class="btn btn-perigo btn-pequeno" data-del="${a.id}">Eliminar</button>
            </div></div>${a.valorFormatado ? `<div class="achado-valor">${escapar(a.valorFormatado)}</div>` : ''}</div>`).join('')
          : '<div class="vazio">Nenhum alerta neste filtro. Tudo sob controle.</div>'}</div>`;
      document.getElementById('al-filtro').addEventListener('change', e => { Estado.alFiltro = e.target.value; render(); });
      document.getElementById('al-avaliar').addEventListener('click', async () => { carregando(true); try { const r = await enviar('alertas/avaliar', 'POST'); toast(`${r.novos.length} novo(s), ${r.atualizados} atualizado(s), ${r.resolvidos} resolvido(s)`); } finally { carregando(false); } render(); });
      const acao = (sel, estado) => cont.querySelectorAll(sel).forEach(b => b.addEventListener('click', async () => {
        const id = b.dataset.ack || b.dataset.res || b.dataset.desc;
        const comentario = estado === 'resolvido' ? (prompt('Comentário (opcional): o que foi feito?') || '') : '';
        await enviar(`alertas/${id}`, 'PATCH', { estado, comentario }); toast(`Alerta ${estado}`); render();
      }));
      acao('[data-ack]', 'reconhecido'); acao('[data-res]', 'resolvido'); acao('[data-desc]', 'descartado');
      cont.querySelectorAll('[data-del]').forEach(b => b.addEventListener('click', async () => { if (confirm('Eliminar este alerta definitivamente?')) { await enviar(`alertas/${b.dataset.del}`, 'DELETE'); toast('Alerta eliminado'); render(); } }));
    } else {
      cont.innerHTML = `<div class="card"><div class="card-titulo">Regras</div><div class="card-subtitulo">Avaliadas a cada carga do dado e uma vez por dia no horário configurado. Sem destinatários, usa o e-mail padrão da aplicação</div>
        ${tabela([{ t: 'Regra' }, { t: 'Tipo' }, { t: 'Limiar' }, { t: 'Escopo' }, { t: 'Severidade' }, { t: 'Destinatários' }, { t: 'Ativa' }, { t: '' }],
          regras.map(r => `<tr><td class="forte">${escapar(r.nome)}</td><td><span class="etiqueta">${escapar((d.tipos[r.tipo] || {}).nome || r.tipo)}</span></td><td>${escapar(r.limiar)} ${escapar((d.tipos[r.tipo] || {}).unidade === 'percentual' ? '%' : (d.tipos[r.tipo] || {}).unidade === 'desvios' ? 'σ' : '')}</td>
            <td>${escapar(r.escopoTipo === 'total' || !r.escopoValor ? 'total' : `${r.escopoTipo}: ${r.escopoValor}`)}</td><td><span class="estado ${r.severidade === 'critico' ? 'aberto' : r.severidade === 'atencao' ? 'reconhecido' : ''}">${escapar(r.severidade)}</span></td>
            <td class="texto-2" style="font-size:11.5px">${escapar((r.destinatarios || []).join(', ') || 'padrão')}</td><td>${r.ativo ? '✓' : 'não'}</td>
            <td class="direita nowrap"><button class="btn btn-secundario btn-pequeno" data-edit="${r.id}">editar</button> <button class="btn btn-perigo btn-pequeno" data-del="${r.id}">remover</button></td></tr>`))}
        <div class="ajuda" style="margin-top:12px">${Object.entries(d.tipos).map(([k, v]) => `<b>${escapar(v.nome)}</b>: ${escapar(v.descricao)}.`).join(' ')}</div></div>`;
      cont.querySelectorAll('[data-edit]').forEach(b => b.addEventListener('click', () => formRegra(regras.find(r => r.id === b.dataset.edit), d.tipos)));
      cont.querySelectorAll('[data-del]').forEach(b => b.addEventListener('click', async () => { if (confirm('Remover esta regra?')) { await enviar(`regras-alerta/${b.dataset.del}`, 'DELETE'); toast('Regra removida'); Estado.alAba = 1; render(); } }));
    }
  };
  abas('al-abas', ['Alertas', 'Regras'], (i) => { Estado.alAba = i; desenharAba(i); });
  if (Estado.alAba === 1) { document.querySelectorAll('#al-abas .aba')[1].click(); } else desenharAba(0);
  document.getElementById('al-nova').addEventListener('click', e => { e.preventDefault(); formRegra(null, d.tipos); });
  const t = document.getElementById('al-teste');
  if (t) t.addEventListener('click', async e => { e.preventDefault(); const r = await enviar('alertas/testar-email', 'POST', {}); alert(r.ok ? `E-mail de teste enviado para ${r.destinatarios.join(', ')}` : `Falha: ${r.mensagem}`); });
};

function formRegra(r, tipos) {
  r = r || { nome: '', tipo: 'orcamento', limiar: '', escopoTipo: 'total', escopoValor: '', severidade: 'atencao', destinatarios: [], ativo: true };
  abrirModal(r.id ? 'Editar regra' : 'Nova regra de alerta', `<div class="form">
      <label>Nome<input id="f-nome" value="${escapar(r.nome)}"></label>
      <label>Tipo<select id="f-tipo">${Object.entries(tipos).map(([k, v]) => `<option value="${k}" ${r.tipo === k ? 'selected' : ''}>${escapar(v.nome)}</option>`).join('')}</select></label>
      <label>Limiar <span class="ajuda" id="f-unid"></span><input id="f-limiar" type="number" step="any" value="${escapar(r.limiar)}"></label>
      <label>Severidade<select id="f-sev">${['critico', 'atencao', 'informativo'].map(s => `<option ${r.severidade === s ? 'selected' : ''}>${s}</option>`).join('')}</select></label>
      <label>Escopo<select id="f-esc">${['total', 'nuvem', 'assinatura', 'grupo', 'servico', 'categoria', 'centro'].map(s => `<option ${r.escopoTipo === s ? 'selected' : ''}>${s}</option>`).join('')}</select></label>
      <label>Valor do escopo<input id="f-escv" value="${escapar(r.escopoValor || '')}" placeholder="vazio = tudo"></label>
      <label class="largo">Destinatários (separados por vírgula)<input id="f-dest" value="${escapar((r.destinatarios || []).join(', '))}" placeholder="vazio = e-mail padrão da aplicação"></label>
      <label style="flex-direction:row;align-items:center;gap:8px"><input type="checkbox" id="f-ativo" ${r.ativo ? 'checked' : ''}> Ativa</label>
    </div><div class="form-acoes"><button class="btn" id="f-salvar">Salvar</button></div>`);
  const tipo = document.getElementById('f-tipo');
  const atualizar = () => { const u = (tipos[tipo.value] || {}).unidade; document.getElementById('f-unid').textContent = u === 'percentual' ? '(%)' : u === 'desvios' ? '(desvios padrão)' : '(valor na moeda)'; };
  tipo.addEventListener('change', atualizar); atualizar();
  document.getElementById('f-salvar').addEventListener('click', async () => {
    try {
      await enviar('regras-alerta', 'POST', { id: r.id, nome: document.getElementById('f-nome').value, tipo: tipo.value, limiar: parseFloat(document.getElementById('f-limiar').value || 0),
        severidade: document.getElementById('f-sev').value, escopoTipo: document.getElementById('f-esc').value, escopoValor: document.getElementById('f-escv').value,
        destinatarios: document.getElementById('f-dest').value.split(',').map(s => s.trim()).filter(Boolean), ativo: document.getElementById('f-ativo').checked });
      fecharModal(); toast('Regra salva'); Estado.alAba = 1; render();
    } catch (e) { alert(e.message); }
  });
}

/* ----------------------------------------------------------------- insights */
P2['insights'] = async function () {
  const d = await buscar('insights'); Estado.moeda = d.resumo.moeda;
  const contagem = d.achados.reduce((a, x) => { a[x.severidade] = (a[x.severidade] || 0) + 1; return a; }, {});
  const oportunidade = d.achados.filter(a => (a.severidade === 'critico' || a.severidade === 'atencao') && a.valor).reduce((s, a) => s + a.valor, 0);
  el2().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Achados', d.achados.length, `${contagem.critico || 0} críticos, ${contagem.atencao || 0} de atenção`, true)}
      ${cardKpi('Valor em jogo', moedaCheia(oportunidade), 'Soma do impacto dos pontos de atenção')}
      ${cardKpi('Economia já obtida', moedaCheia(d.resumo.economia), `${pct(d.resumo.percentualEconomia)} sobre o preço de tabela`)}
      ${cardKpi('Variação mensal', delta(d.resumo.variacaoMensal), notaComparacao(d.resumo))}
    </div>
    <div class="card"><div class="card-titulo">Como estes achados são gerados</div><div class="achado-detalhe">Regras estatísticas determinísticas aplicadas ao seu próprio dado FOCUS: comparação mês até a data contra o mesmo intervalo do mês anterior, desvio padrão sobre a série diária, concentração por serviço, cobertura de compromissos e de etiquetas. Nada é enviado para fora da sua assinatura, e cada conclusão traz os números que a sustentam.</div></div>
    ${blocoAchados(d.achados, 'Achados do período')}`;
};

/* ---------------------------------------------------------------- qualidade */
P2['qualidade'] = async function () {
  const d = await buscar('insights'); const q = d.qualidade; Estado.moeda = d.resumo.moeda;
  const atraso = q.atrasoDias;
  const estado = atraso === null ? 'sem dado' : atraso <= 2 ? 'em dia' : atraso <= 5 ? 'com atraso pequeno' : 'com atraso relevante';
  const totalLinhas = d.resumo.linhas || 1;
  el2().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Meses carregados', (q.meses || []).length, (q.meses || []).length ? `de ${mesLegivel(q.meses[0])} a ${mesLegivel(q.meses[q.meses.length - 1])}` : '', true)}
      ${cardKpi('Último dia com dado', escapar(q.ultimoDia || '--'), atraso === null ? '' : `${atraso} dia(s) atrás, ${estado}`)}
      ${cardKpi('Lançamentos', num(d.resumo.linhas), 'Linhas de custo no período filtrado')}
      ${cardKpi('Moedas', (q.moedas || []).join(', ') || '--', (q.moedas || []).length > 1 ? 'Atenção: não some valores de moedas diferentes' : 'Moeda única, valores somáveis')}
    </div>
    ${(q.moedas || []).length > 1 ? `<div class="alerta aviso">Existe mais de uma moeda no conjunto. Os totais somam sem conversão cambial. Filtre por conta de faturamento para analisar uma moeda por vez.</div>` : ''}
    <div class="grade g2">
      <div class="card"><div class="card-titulo">Cobertura de metadados</div><div class="card-subtitulo">O que falta para chargeback confiável</div>
        ${tabela([{ t: 'Indicador' }, { t: 'Lançamentos', num: true }, { t: 'Participação', num: true }], [
          `<tr><td>Sem nome de recurso</td><td class="num">${num(q.semRecurso)}</td><td class="num">${pct(q.semRecurso / totalLinhas)}</td></tr>`,
          `<tr><td>Sem etiqueta (tag)</td><td class="num">${num(q.semTag)}</td><td class="num">${pct(q.semTag / totalLinhas)}</td></tr>`])}</div>
      <div class="card"><div class="card-titulo">Ingestão por nuvem</div><div class="card-subtitulo">Volume e data do último lançamento de cada provedor</div>
        ${tabela([{ t: 'Nuvem' }, { t: 'Lançamentos', num: true }, { t: 'Custo', num: true }, { t: 'Último dia' }],
          (q.porNuvem || []).map(n => `<tr><td>${etiquetaNuvem(n.nuvem)}</td><td class="num">${num(n.linhas)}</td><td class="num">${moedaCheia(n.efetivo)}</td><td>${escapar(n.ultimoDia || '--')}</td></tr>`))}</div>
    </div>
    <div class="card"><div class="card-titulo">Meses disponíveis no hub</div><div class="card-subtitulo">Cada mês é uma pasta em ingestion/Costs. Para trazer mais histórico, use o backfill (seção 6 do guia)</div>
      <div class="chip-lista" style="margin-top:4px">${(q.meses || []).map(m => `<span class="etiqueta">${mesLegivel(m)}</span>`).join('') || '<span class="vazio">Nenhum mês carregado.</span>'}</div></div>`;
};

/* ---------------------------------------------------------------- relatório */
P2['relatorio'] = async function () {
  const d = await buscar('relatorio'); Estado.moeda = d.moeda;
  el2().innerHTML = `
    <div class="card destaque"><div style="display:flex;justify-content:space-between;align-items:flex-start;gap:16px;flex-wrap:wrap">
      <div><div class="card-titulo" style="font-size:17px">Relatório executivo</div><div class="card-subtitulo">${escapar(d.filtrosTexto)}. O PDF traz esta leitura, os gráficos e as tabelas de apoio. O Excel traz todos os dados em abas</div></div>
      <div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn" id="rel-pdf">⤓ Exportar PDF</button><button class="btn btn-secundario" id="rel-xlsx">⤓ Exportar Excel</button><button class="btn btn-secundario" onclick="window.print()">🖶 Imprimir esta página</button></div></div></div>
    <div class="grade kpi">
      ${cardKpi('Custo total no período', moedaCheia(d.resumo.custoEfetivo), `${d.resumo.servicos} serviços, ${num(d.resumo.recursos)} recursos`, true)}
      ${cardKpi('Mês corrente', moedaCheia(d.resumo.mesAtual), notaComparacao(d.resumo))}
      ${cardKpi('Projeção do mês', moedaCheia(d.resumo.projecaoMes), '')}
      ${cardKpi('Economia sobre a tabela', moedaCheia(d.resumo.economia), pct(d.resumo.percentualEconomia))}
    </div>
    <div class="card"><div class="card-titulo">Leitura executiva</div><div class="narrativa" style="margin-top:8px">${(d.narrativa || []).map(t => `<p>${escapar(t)}</p>`).join('')}</div></div>
    <div class="grade g2">${cardGrafico('Evolução mensal', 'Custo efetivo e faturado', 'g-rel-mensal')}${cardGrafico('Por categoria', 'Distribuição do gasto', 'g-rel-cat')}</div>
    <div class="grade g2">${cardGrafico('Maiores serviços', 'Top 12', 'g-rel-serv', 'gr alto')}${cardGrafico('Por nuvem', 'Cores fixas por provedor', 'g-rel-nuvem', 'gr alto')}</div>
    ${blocoPrevisao(d.previsao, 'rel')}
    ${blocoRecomendacoes(d.otimizacao, 'Principais oportunidades', 8)}
    ${blocoAchados(d.achados.slice(0, 6), 'Principais achados')}
    <div class="card"><div class="credito">${escapar((Estado.sobre || {}).creditoLongo || '')}</div></div>`;
  const m = d.mensal;
  grafLinha('g-rel-mensal', m.map(x => mesLegivel(x.mes)), [{ name: 'Efetivo', data: m.map(x => x.efetivo) }, { name: 'Faturado', data: m.map(x => x.faturado), cor: '#00B7C3' }], { area: true });
  grafRosca('g-rel-cat', d.porCategoria); grafBarraH('g-rel-serv', d.porServico); grafBarraH('g-rel-nuvem', d.porNuvem, { corPor: corNuvem });
  desenharPrevisao(d.previsao, 'rel');
  document.getElementById('rel-pdf').addEventListener('click', () => baixarExport('pdf'));
  document.getElementById('rel-xlsx').addEventListener('click', () => baixarExport('excel'));
};
