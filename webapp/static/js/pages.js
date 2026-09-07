/* ===========================================================================
   FinOps Multicloud
   Construído por Wanderlei Grizolli Junior, Sr. Solution Engineer.
   Baseado no Microsoft FinOps toolkit (https://github.com/microsoft/finops-toolkit).

   Páginas da aplicação. Cada função monta o HTML da página e desenha os gráficos.
   ======================================================================== */

const P = window.Paginas;
const el = () => document.getElementById('pagina');

/* ------------------------------------------------------------- visão geral */
P['visao-geral'] = async function () {
  const d = await buscar('visao-geral');
  const r = d.resumo; Estado.moeda = r.moeda; atualizarBadge(d.alertas);
  el().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Custo total no período', moedaCheia(r.custoEfetivo), `${num(r.linhas)} lançamentos, ${r.servicos} serviços, ${r.nuvens} nuvem(ns)`, true)}
      ${cardKpi('Mês corrente', moedaCheia(r.mesAtual), notaComparacao(r))}
      ${cardKpi('Projeção do mês', moedaCheia(r.projecaoMes), 'Estimativa pela média diária observada')}
      ${cardKpi('Economia sobre a tabela', moedaCheia(r.economia), `${pct(r.percentualEconomia)} de desconto sobre o preço cheio`)}
    </div>
    <div class="grade g2">
      ${cardGrafico('Evolução mensal', 'Custo efetivo e custo faturado por mês', 'g-mensal')}
      ${cardGrafico('Distribuição por categoria', 'Onde o gasto se concentra', 'g-categoria')}
    </div>
    <div class="grade g2">
      ${cardGrafico('Custo diário', 'Série diária do custo efetivo', 'g-diario')}
      ${cardGrafico('Maiores serviços', 'Os 12 serviços com maior custo no período', 'g-servico', 'gr alto')}
    </div>
    <div class="grade g2">
      ${cardGrafico('Por nuvem', 'Comparativo entre provedores, cores fixas por nuvem', 'g-nuvem', 'gr baixo')}
      ${cardGrafico('Por ambiente', 'Produção contra não produção', 'g-ambiente', 'gr baixo')}
    </div>`;
  const m = d.mensal;
  grafLinha('g-mensal', m.map(x => mesLegivel(x.mes)), [{ name: 'Efetivo', data: m.map(x => x.efetivo) }, { name: 'Faturado', data: m.map(x => x.faturado), cor: '#00B7C3' }], { area: true });
  grafRosca('g-categoria', d.porCategoria);
  grafLinha('g-diario', d.diario.map(x => x.data.slice(5)), [{ name: 'Efetivo', data: d.diario.map(x => x.efetivo) }], { area: true });
  grafBarraH('g-servico', d.porServico);
  grafBarraH('g-nuvem', d.porNuvem, { corPor: corNuvem });
  grafRosca('g-ambiente', d.porAmbiente, { corPor: (n) => ({ 'Produção': '#0078D4', 'Não produção': '#FFB900', 'Desconhecido': '#6B7C99' })[n] });
  document.getElementById('rodape-info').textContent = `Atualizado em ${d.atualizadoEm ? new Date(d.atualizadoEm).toLocaleString('pt-BR') : 'agora'}`;
};

/* -------------------------------------------------------------- tecnologia */
P['tecnologia'] = async function () {
  const d = await buscar('tecnologia'); Estado.moeda = d.resumo.moeda;
  const total = d.resumo.custoEfetivo;
  el().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Serviços em uso', d.resumo.servicos, 'Serviços distintos com custo no período', true)}
      ${cardKpi('Custo total', moedaCheia(d.resumo.custoEfetivo), 'Custo efetivo, amortizado')}
      ${cardKpi('Maior serviço', d.porServico.length ? escapar(d.porServico[0].nome) : '--', d.porServico.length ? `${moedaCheia(d.porServico[0].efetivo)}, ${pct(total ? d.porServico[0].efetivo / total : 0)} do total` : '', false, true)}
      ${cardKpi('Regiões', d.porRegiao.length, 'Regiões com recursos gerando custo')}
    </div>
    <div class="grade">${cardGrafico('Evolução dos maiores serviços', 'Os 6 principais, mês a mês', 'g-evol', 'gr alto')}</div>
    <div class="grade g2">
      ${cardGrafico('Custo por serviço', 'Os 20 serviços com maior custo', 'g-serv', 'gr alto')}
      ${cardGrafico('Custo por categoria', 'Agrupamento por família de serviço', 'g-cat')}
    </div>
    <div class="grade g2">
      ${cardGrafico('Custo por tipo de recurso', 'Onde o consumo se materializa', 'g-tipo', 'gr alto')}
      ${cardGrafico('Custo por região', 'Distribuição geográfica', 'g-reg')}
    </div>
    <div class="card"><div class="card-titulo">Detalhe por serviço</div><div class="card-subtitulo">Custo efetivo e participação no total</div>
      ${tabela([{ t: 'Serviço' }, { t: 'Custo', num: true }, { t: 'Participação', num: true }, { t: 'Lançamentos', num: true }],
        d.porServico.map(s => `<tr><td class="forte">${escapar(s.nome)}</td><td class="num">${moedaCheia(s.efetivo)}</td><td class="num">${pct(total ? s.efetivo / total : 0)}</td><td class="num">${num(s.linhas)}</td></tr>`))}
    </div>`;
  grafEmpilhado('g-evol', d.evolucaoServico); grafBarraH('g-serv', d.porServico); grafRosca('g-cat', d.porCategoria);
  grafBarraH('g-tipo', d.porTipoRecurso); grafRosca('g-reg', d.porRegiao);
};

/* ------------------------------------------------------------------ nuvens */
P['nuvens'] = async function () {
  const d = await buscar('nuvens'); Estado.moeda = d.resumo.moeda;
  const total = d.resumo.custoEfetivo;
  const cards = d.porNuvem.map(n => `<div class="card" style="border-top:3px solid ${corNuvem(n.nome)}"><div class="kpi-rotulo">${etiquetaNuvem(n.nome)}</div>
    <div class="kpi-valor">${moedaCheia(n.efetivo)}</div><div class="kpi-nota">${pct(total ? n.efetivo / total : 0)} do total, ${num(n.linhas)} lançamentos</div></div>`).join('');
  const nuvensCat = Object.keys(d.categoriaPorNuvem || {});
  el().innerHTML = `
    ${d.porNuvem.length <= 1 ? `<div class="alerta aviso">Só há dados de uma nuvem no momento. Os conectores de AWS, Google Cloud e Oracle Cloud ficam prontos no kit e passam a aparecer aqui automaticamente quando configurados (guia: docs/07-multicloud-aws-oci.md).</div>` : ''}
    <div class="grade kpi">${cards}</div>
    <div class="grade g2">
      ${cardGrafico('Evolução por nuvem', 'Custo mensal de cada provedor', 'g-evol-nuvem', 'gr alto')}
      ${cardGrafico('Participação atual', 'Divisão do gasto entre as nuvens', 'g-pizza-nuvem', 'gr alto')}
    </div>
    ${nuvensCat.length ? `<div class="grade g${Math.min(nuvensCat.length, 4)}">${nuvensCat.map((n, i) => cardGrafico(`Categorias em ${n}`, 'O que cada nuvem hospeda', `g-cat-${i}`, 'gr baixo')).join('')}</div>` : ''}
    <div class="grade g2">
      ${cardGrafico('Por assinatura ou conta', 'As 15 maiores', 'g-assinatura', 'gr alto')}
      ${cardGrafico('Por conta de faturamento', 'Onde a fatura é emitida', 'g-fatura')}
    </div>
    <div class="card"><div class="card-titulo">Detalhe por assinatura ou conta</div><div class="card-subtitulo">No Azure é a assinatura, na AWS a conta, no Google o projeto, na OCI o compartimento</div>
      ${tabela([{ t: 'Assinatura ou conta' }, { t: 'Custo', num: true }, { t: 'Participação', num: true }],
        d.porAssinatura.map(a => `<tr><td class="forte celula-larga">${escapar(a.nome)}</td><td class="num">${moedaCheia(a.efetivo)}</td><td class="num">${pct(total ? a.efetivo / total : 0)}</td></tr>`))}
    </div>`;
  grafEmpilhado('g-evol-nuvem', d.evolucaoNuvem, { corPor: corNuvem }); grafRosca('g-pizza-nuvem', d.porNuvem, { corPor: corNuvem });
  nuvensCat.forEach((n, i) => grafBarraH(`g-cat-${i}`, d.categoriaPorNuvem[n], { corPor: () => corNuvem(n) }));
  grafBarraH('g-assinatura', d.porAssinatura); grafRosca('g-fatura', d.porContaFatura);
};

/* ---------------------------------------------------------------- recursos */
P['recursos'] = async function () {
  const d = await buscar('recursos', { limite: 60 }); Estado.moeda = d.resumo.moeda;
  el().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Recursos com custo', num(d.resumo.recursos), 'Recursos distintos no período', true)}
      ${cardKpi('Custo total', moedaCheia(d.resumo.custoEfetivo), 'Custo efetivo, amortizado')}
      ${cardKpi('Grupos de recurso', d.porGrupo.length, 'Resource groups com consumo')}
      ${cardKpi('Maior recurso', d.topRecursos.length ? moedaCheia(d.topRecursos[0].efetivo) : '--', d.topRecursos.length ? escapar(d.topRecursos[0].recurso) : '')}
    </div>
    <div class="grade g2">
      ${cardGrafico('Custo por grupo de recurso', 'Os 15 maiores', 'g-grupo', 'gr alto')}
      ${cardGrafico('Por tipo de cobrança', 'Uso, compra, imposto e ajuste', 'g-cobranca')}
    </div>
    <div class="card"><div class="card-titulo">Recursos que mais consomem</div><div class="card-subtitulo">Ordenados por custo efetivo no período</div>
      ${tabela([{ t: 'Recurso' }, { t: 'Serviço' }, { t: 'Grupo' }, { t: 'Nuvem' }, { t: 'Ambiente' }, { t: 'Custo', num: true }, { t: 'Economia', num: true }],
        d.topRecursos.map(x => `<tr><td class="forte celula-larga" title="${escapar(x.recurso)}">${escapar(x.recurso)}</td><td>${escapar(x.servico)}</td><td>${escapar(x.grupo)}</td>
          <td>${etiquetaNuvem(x.nuvem)}</td><td><span class="etiqueta">${escapar(x.ambiente)}</span></td><td class="num">${moedaCheia(x.efetivo)}</td><td class="num">${x.economia > 0 ? moedaCheia(x.economia) : '--'}</td></tr>`))}
    </div>`;
  grafBarraH('g-grupo', d.porGrupo); grafRosca('g-cobranca', d.porTipoCobranca);
};

/* ----------------------------------------------------- blocos reutilizáveis */
function blocoPrevisao(p, prefixo) {
  if (!p || !p.previsao || !p.previsao.length) return `<div class="card"><div class="card-titulo">Previsão</div><div class="vazio">Histórico insuficiente para prever (mínimo de 14 dias).</div></div>`;
  return `<div class="grade g4">
      ${cardKpi('Próximos 30 dias', moedaCheia(p.acumulado['30']), `média diária de ${moeda(p.mediaDiaria)}`, true)}
      ${cardKpi('Próximos 60 dias', moedaCheia(p.acumulado['60']), '')}
      ${cardKpi('Próximos 90 dias', moedaCheia(p.acumulado['90']), '')}
      ${cardKpi('Tendência mensal', delta(p.tendenciaMensal), `confiabilidade ${p.confiabilidade}, ${p.diasUsados} dias analisados`)}
    </div>
    <div class="card"><div class="card-titulo">Realizado e previsão</div><div class="card-subtitulo">${escapar(p.metodo)}, faixa de 80% de confiança</div><div id="${prefixo}-prev" class="gr alto"></div></div>`;
}
function desenharPrevisao(p, prefixo) {
  if (!p || !p.previsao || !p.previsao.length) return;
  const h = p.historico.slice(-90), f = p.previsao;
  const cats = [...h.map(x => x.data.slice(5)), ...f.map(x => x.data.slice(5))];
  const nulos = (n) => new Array(n).fill(null);
  grafLinha(`${prefixo}-prev`, cats, [
    { name: 'Realizado', data: [...h.map(x => x.valor), ...nulos(f.length)], area: true },
    { name: 'Previsão', data: [...nulos(h.length - 1), h.length ? h[h.length - 1].valor : null, ...f.map(x => x.valor)], cor: '#8B5CF6', tracejado: true },
    { name: '_min', data: [...nulos(h.length), ...f.map(x => x.min)], cor: '#8B5CF6', oculta: true, stack: 'faixa' },
    { name: '_faixa', data: [...nulos(h.length), ...f.map(x => x.max - x.min)], cor: '#8B5CF6', oculta: true, stack: 'faixa', area: true, areaOpacidade: .16, corArea: '#8B5CF6' }
  ]);
}
function blocoRecomendacoes(ot, titulo = 'Onde economizar', limite = 10) {
  if (!ot || !ot.recomendacoes || !ot.recomendacoes.length) return `<div class="card"><div class="card-titulo">${escapar(titulo)}</div><div class="vazio">Nenhuma oportunidade identificada com os filtros atuais.</div></div>`;
  return `<div class="card"><div class="card-titulo">${escapar(titulo)}: ${moedaCheia(ot.resumo.economiaEstimada)} por período</div>
    <div class="card-subtitulo">${ot.recomendacoes.length} recomendações, faixa de ${moeda(ot.resumo.economiaMin)} a ${moeda(ot.resumo.economiaMax)}. Estimativas de mercado, para priorizar</div>
    ${tabela([{ t: 'Categoria' }, { t: 'Em uso' }, { t: 'Sugestão' }, { t: 'Custo atual', num: true }, { t: 'Economia estimada', num: true }, { t: 'Confiança' }],
      ot.recomendacoes.slice(0, limite).map(x => `<tr><td><span class="etiqueta">${escapar(x.categoria)}</span></td><td class="celula-larga" title="${escapar(x.acao)}">${escapar(x.atual)}${x.recurso ? `<br><span class="texto-2" style="font-size:11px">${escapar(x.recurso)}</span>` : ''}</td>
        <td class="celula-larga">${escapar(x.sugerido)}</td><td class="num">${moedaCheia(x.custoAtual)}</td><td class="num forte" style="color:var(--verde)">${moedaCheia(x.economiaEstimada)}</td><td><span class="etiqueta">${escapar(x.confianca)}</span></td></tr>`))}
  </div>`;
}
function blocoAchados(achados, titulo = 'Achados') {
  const IC = { critico: '!', atencao: '▲', informativo: 'i', positivo: '✓' };
  if (!achados || !achados.length) return '';
  return `<div class="card"><div class="card-titulo">${escapar(titulo)}</div><div class="grade" style="gap:9px;margin-top:8px">${achados.map(a => `
    <div class="achado ${a.severidade}"><div class="achado-icone">${IC[a.severidade] || 'i'}</div><div class="achado-corpo">
      <div class="achado-titulo">${escapar(a.titulo)} <span class="etiqueta">${escapar(a.categoria)}</span></div><div class="achado-detalhe">${escapar(a.detalhe)}</div>
      ${a.acao ? `<div class="achado-acao"><strong>O que fazer:</strong> ${escapar(a.acao)}</div>` : ''}</div>${a.valor ? `<div class="achado-valor">${moedaCheia(a.valor)}</div>` : ''}</div>`).join('')}</div></div>`;
}

/* ---------------------------------------------------------------------- IA */
P['ia'] = async function () {
  const d = await buscar('ia');
  if (d.vazio) { el().innerHTML = `<div class="alerta aviso">${escapar(d.mensagem || 'Sem serviços de IA no período.')}</div>`; return; }
  const r = d.resumo; Estado.moeda = r.moeda;
  el().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Custo de IA no período', moedaCheia(r.total), `${pct(r.participacao)} do gasto total, ${r.servicos} serviços, ${r.modelos} modelos`, true)}
      ${cardKpi('Mês corrente', moedaCheia(r.mesAtual), notaComparacao(r))}
      ${cardKpi('Tokens processados', numCurto(r.tokens), r.tokens ? `${moedaCheia(r.custoPorMilhaoTokens)} por milhão de tokens (média ponderada)` : 'Nenhum medidor por token encontrado')}
      ${cardKpi('Agentes', moedaCheia(r.custoAgentes), `${r.recursosAgentes} recurso(s) de agente ou assistente`)}
    </div>
    <div class="grade g2">
      ${cardGrafico('Participação da IA no gasto total', 'Mês a mês, quanto a IA representa', 'g-ia-part')}
      ${cardGrafico('Evolução por modelo', 'Os 6 modelos que mais custam', 'g-ia-modelo', 'gr')}
    </div>
    <div class="grade g3">
      ${cardGrafico('Por serviço', 'OpenAI, Foundry, Bedrock, Vertex, Generative AI', 'g-ia-serv')}
      ${cardGrafico('Por modelo', 'Onde os tokens estão indo', 'g-ia-mod')}
      ${cardGrafico('Por nuvem', 'Cores fixas por provedor', 'g-ia-nuvem')}
    </div>
    <div class="grade g2">
      ${cardGrafico('Tokens por mês', 'Volume estimado a partir dos medidores por token', 'g-ia-tok')}
      ${cardGrafico('Tokens por tipo', 'Entrada, saída e cache', 'g-ia-tipo')}
    </div>
    ${blocoPrevisao(d.previsao, 'ia')}
    ${blocoRecomendacoes(d.otimizacao, 'Onde economizar em IA')}
    <div class="card"><div class="card-titulo">Recursos de IA</div><div class="card-subtitulo">Os 25 que mais consomem</div>
      ${tabela([{ t: 'Recurso' }, { t: 'Serviço' }, { t: 'Grupo' }, { t: 'Nuvem' }, { t: 'Custo', num: true }],
        d.porRecurso.map(x => `<tr><td class="forte celula-larga">${escapar(x.recurso)}</td><td>${escapar(x.servico)}</td><td>${escapar(x.grupo)}</td><td>${etiquetaNuvem(x.nuvem)}</td><td class="num">${moedaCheia(x.efetivo)}</td></tr>`))}
    </div>
    ${blocoAchados(d.achados, 'Achados sobre IA')}`;
  const pm = d.participacaoMensal;
  grafLinha('g-ia-part', pm.map(x => mesLegivel(x.mes)), [{ name: 'IA', data: pm.map(x => x.ia), area: true }, { name: 'Total', data: pm.map(x => x.total), cor: '#6B7C99', tracejado: true }]);
  grafEmpilhado('g-ia-modelo', d.evolucaoModelo); grafBarraH('g-ia-serv', d.porServico); grafRosca('g-ia-mod', d.porModelo); grafRosca('g-ia-nuvem', d.porNuvem, { corPor: corNuvem });
  grafLinha('g-ia-tok', d.tokensMensal.map(x => mesLegivel(x.mes)), [{ name: 'Tokens', data: d.tokensMensal.map(x => x.tokens), area: true }], { fmt: numCurto });
  grafRosca('g-ia-tipo', d.tokensPorTipo.map(x => ({ nome: x.tipo, efetivo: x.tokens })), { fmt: numCurto });
  desenharPrevisao(d.previsao, 'ia');
};

/* ------------------------------------------------------------------ bancos */
P['bancos'] = async function () {
  const d = await buscar('bancos');
  if (d.vazio) { el().innerHTML = `<div class="alerta aviso">${escapar(d.mensagem || 'Sem bancos de dados no período.')}</div>`; return; }
  const r = d.resumo; Estado.moeda = r.moeda;
  const corTipo = (n) => ({ 'Relacional': '#0078D4', 'NoSQL': '#8B5CF6', 'Cache': '#00B7C3', 'Analítico': '#FFB900', 'Outros': '#6B7C99' })[n];
  el().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Custo de bancos no período', moedaCheia(r.total), `${pct(r.participacao)} do gasto total, ${r.instancias} instâncias, ${r.engines} engines`, true)}
      ${cardKpi('Mês corrente', moedaCheia(r.mesAtual), notaComparacao(r))}
      ${cardKpi('Cobertura por compromisso', pct(r.coberturaCompromisso), 'Parcela do gasto em reserva ou savings plan')}
      ${cardKpi('Em não produção', moedaCheia(r.custoNaoProducao), `${pct(r.percentualNaoProducao)} do gasto com bancos`)}
    </div>
    <div class="grade g2">
      ${cardGrafico('Evolução por engine', 'Os 6 motores que mais custam', 'g-bd-evol', 'gr alto')}
      ${cardGrafico('Por tipo', 'Relacional, NoSQL, cache e analítico', 'g-bd-tipo', 'gr alto')}
    </div>
    <div class="grade g3">
      ${cardGrafico('Por engine', 'Todos os motores identificados', 'g-bd-eng', 'gr alto')}
      ${cardGrafico('Por nuvem', 'Cores fixas por provedor', 'g-bd-nuvem')}
      ${cardGrafico('Por ambiente', 'Produção contra não produção', 'g-bd-amb')}
    </div>
    ${blocoPrevisao(d.previsao, 'bd')}
    <div class="card"><div class="card-titulo">Previsão por engine</div><div class="card-subtitulo">Próximos 30, 60 e 90 dias para cada motor</div>
      ${tabela([{ t: 'Engine' }, { t: 'Últimos 30', num: true }, { t: 'Próximos 30', num: true }, { t: 'Próximos 60', num: true }, { t: 'Próximos 90', num: true }, { t: 'Tendência' }, { t: 'Confiabilidade' }],
        (d.previsaoEngine || []).map(w => `<tr><td class="forte">${escapar(w.nome)}</td><td class="num">${moedaCheia(w.ultimos30)}</td><td class="num">${moedaCheia(w.proximos30)}</td><td class="num">${moedaCheia(w.proximos60)}</td><td class="num">${moedaCheia(w.proximos90)}</td><td>${delta(w.tendenciaMensal)}</td><td><span class="etiqueta">${escapar(w.confiabilidade)}</span></td></tr>`))}
    </div>
    ${blocoRecomendacoes(d.otimizacao, 'Onde economizar em bancos de dados', 15)}
    <div class="card"><div class="card-titulo">Instâncias que mais consomem</div><div class="card-subtitulo">As 30 maiores</div>
      ${tabela([{ t: 'Instância' }, { t: 'Serviço' }, { t: 'Grupo' }, { t: 'Nuvem' }, { t: 'Ambiente' }, { t: 'Custo', num: true }],
        d.porInstancia.map(x => `<tr><td class="forte celula-larga">${escapar(x.recurso)}</td><td>${escapar(x.servico)}</td><td>${escapar(x.grupo)}</td><td>${etiquetaNuvem(x.nuvem)}</td><td><span class="etiqueta">${escapar(x.ambiente)}</span></td><td class="num">${moedaCheia(x.efetivo)}</td></tr>`))}
    </div>
    ${(d.alertas || []).length ? `<div class="card"><div class="card-titulo">Alertas relacionados a bancos</div>${d.alertas.map(a => `<div class="achado ${a.severidade}" style="margin-top:8px"><div class="achado-corpo"><div class="achado-titulo">${escapar(a.titulo)} <span class="estado ${a.estado}">${escapar(a.estado)}</span></div><div class="achado-detalhe">${escapar(a.detalhe)}</div></div></div>`).join('')}</div>` : ''}
    ${blocoAchados(d.achados, 'Achados sobre bancos de dados')}`;
  grafEmpilhado('g-bd-evol', d.evolucaoEngine); grafRosca('g-bd-tipo', d.porTipo, { corPor: corTipo }); grafBarraH('g-bd-eng', d.porEngine);
  grafRosca('g-bd-nuvem', d.porNuvem, { corPor: corNuvem }); grafRosca('g-bd-amb', d.porAmbiente, { corPor: (n) => ({ 'Produção': '#0078D4', 'Não produção': '#FFB900', 'Desconhecido': '#6B7C99' })[n] });
  desenharPrevisao(d.previsao, 'bd');
};

/* -------------------------------------------------------------- otimização */
P['otimizacao'] = async function () {
  const d = await buscar('otimizacao'); Estado.moeda = d.resumo.moeda || Estado.moeda;
  const r = d.resumo;
  const cob = d.coberturaCompromisso || { coberto: 0, sobDemanda: 0 };
  const totalCob = cob.coberto + cob.sobDemanda;
  el().innerHTML = `
    <div class="grade kpi">
      ${cardKpi('Economia estimada', moedaCheia(r.economiaEstimada || 0), `${pct(r.percentual || 0)} do gasto do período, faixa de ${moeda(r.economiaMin || 0)} a ${moeda(r.economiaMax || 0)}`, true)}
      ${cardKpi('Recomendações', r.recomendacoes || 0, `${(d.porCategoria || []).length} categorias`)}
      ${cardKpi('Alta confiança', moedaCheia(r.altaConfianca || 0), 'Economia das recomendações com alta confiança')}
      ${cardKpi('Cobertura por compromisso', pct(totalCob ? cob.coberto / totalCob : 0), `${moeda(cob.sobDemanda)} ainda em preço sob demanda`)}
    </div>
    <div class="grade g3">
      ${cardGrafico('Economia por categoria', 'Onde está o maior potencial', 'g-ot-cat')}
      ${cardGrafico('Economia por confiança', 'Quanto é seguro contar', 'g-ot-conf', 'gr')}
      ${cardGrafico('Produção e não produção', 'Distribuição do gasto por ambiente', 'g-ot-amb')}
    </div>
    ${blocoRecomendacoes(d, 'Todas as recomendações', 60)}
    <div class="card"><div class="card-titulo">Tabela de equivalências entre nuvens</div><div class="card-subtitulo">O mesmo serviço em cada provedor, e a dica de economia que vale para todos</div>
      ${tabela([{ t: 'Categoria' }, { t: 'Azure' }, { t: 'AWS' }, { t: 'Google Cloud' }, { t: 'Oracle Cloud' }, { t: 'Dica' }],
        (d.equivalencias || []).map(e => `<tr><td class="forte">${escapar(e.categoria)}</td><td style="color:${corNuvem('Microsoft Azure')}">${escapar(e.azure)}</td><td style="color:${corNuvem('Amazon Web Services')}">${escapar(e.aws)}</td><td style="color:${corNuvem('Google Cloud')}">${escapar(e.google)}</td><td style="color:${corNuvem('Oracle Cloud')}">${escapar(e.oci)}</td><td class="texto-2" style="font-size:12px">${escapar(e.dica)}</td></tr>`))}
    </div>
    <div class="card"><div class="card-titulo">Como estas recomendações são geradas</div><div class="achado-detalhe">O FOCUS mostra o que foi cobrado, não a utilização. Por isso as regras aqui olham para compromissos sem uso, gasto estável sem reserva, ambientes não produtivos ligados no fim de semana, SKUs e gerações com equivalente mais barato, e grupos onde só sobrou storage ou IP. Recomendações por utilização (CPU, memória, IOPS) vêm do Azure Advisor, que o FinOps hub também ingere quando a opção de recomendações está ligada.</div></div>`;
  grafRosca('g-ot-cat', d.porCategoria || []); grafRosca('g-ot-conf', d.porConfianca || [], { corPor: (n) => ({ 'alta': '#2FBF71', 'média': '#FFB900', 'baixa': '#6B7C99' })[n] });
  grafRosca('g-ot-amb', d.porAmbiente || [], { corPor: (n) => ({ 'Produção': '#0078D4', 'Não produção': '#FFB900', 'Desconhecido': '#6B7C99' })[n] });
};

/* ---------------------------------------------------------------- previsão */
P['previsao'] = async function () {
  const dim = Estado.previsaoDim || 'servico';
  const d = await buscar('previsao', { dimensao: dim }); Estado.moeda = d.moeda;
  const p = d.previsao;
  const orc = d.orcamentoMensal;
  el().innerHTML = `
    ${blocoPrevisao(p, 'pv')}
    <div class="grade g3">
      ${cardKpi('Fechamento do mês', moedaCheia(p.fimDoMes || 0), `realizado ${moeda(p.realizadoMes || 0)} até hoje`)}
      ${cardKpi('Próximo mês', moedaCheia(p.proximoMes || 0), 'Projeção do mês seguinte inteiro')}
      ${orc ? cardKpi('Orçamento mensal', moedaCheia(orc), d.diasAteOrcamento ? `<span class="delta-sobe">estoura em ${d.diasAteOrcamento} dia(s)</span> no ritmo atual` : `<span class="delta-desce">dentro do orçamento</span> na projeção atual`)
            : cardKpi('Orçamento mensal', '--', 'Cadastre um orçamento total na página de Governança para comparar')}
    </div>
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap">
        <div><div class="card-titulo">Previsão por workload</div><div class="card-subtitulo">Os 10 maiores da dimensão escolhida, com projeção e tendência</div></div>
        <select id="prev-dim" class="campo">${[['servico', 'Por serviço'], ['grupo', 'Por grupo de recurso'], ['assinatura', 'Por assinatura'], ['nuvem', 'Por nuvem'], ['categoria', 'Por categoria']].map(([v, t]) => `<option value="${v}" ${v === dim ? 'selected' : ''}>${t}</option>`).join('')}</select>
      </div>
      ${tabela([{ t: 'Workload' }, { t: 'Últimos 30', num: true }, { t: 'Próximos 30', num: true }, { t: 'Próximos 60', num: true }, { t: 'Próximos 90', num: true }, { t: 'Tendência mensal' }, { t: 'Confiabilidade' }],
        d.workloads.map(w => `<tr><td class="forte">${dim === 'nuvem' ? etiquetaNuvem(w.nome) : escapar(w.nome)}</td><td class="num">${moedaCheia(w.ultimos30)}</td><td class="num">${moedaCheia(w.proximos30)}</td><td class="num">${moedaCheia(w.proximos60)}</td><td class="num">${moedaCheia(w.proximos90)}</td><td>${delta(w.tendenciaMensal)}</td><td><span class="etiqueta">${escapar(w.confiabilidade)}</span></td></tr>`))}
    </div>
    <div class="card"><div class="card-titulo">Como a previsão é feita</div><div class="achado-detalhe">Regressão linear sobre os últimos ${p.diasUsados || 90} dias, com sazonalidade semanal (fim de semana costuma custar menos) e picos aparados a três desvios, para que um incidente isolado não vire tendência. A faixa é de 80% de confiança e alarga com o horizonte. Confiabilidade alta significa série estável com mais de 60 dias; baixa significa série curta ou muito irregular, e o número deve ser lido como ordem de grandeza.</div></div>`;
  desenharPrevisao(p, 'pv');
  document.getElementById('prev-dim').addEventListener('change', e => { Estado.previsaoDim = e.target.value; render(); });
};
