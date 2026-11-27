// Migração dos empréstimos do modelo antigo (objetivo do Cashew `type=1` + lançamentos com `objective_loan_fk`) para o novo
// (decisões `emprestimo`/`devolucao` em `mb_revisoes`, que alimentam a tela Empréstimos). Spec: docs/features/emprestimos-unificados/spec.md.
//  - tx_id SINTÉTICO `mig:<objetivo>:<lançamento>`: com o id real o app trataria a transação como "não gasto" e a apagaria.
//  - As transações e o objetivo antigos NUNCA são tocados. O status "migrado" vem das decisões vivas (a tabela D1 é só histórico).
//  - Tudo em centavos inteiros; datas em America/Sao_Paulo (dia() do espelho).
import { agoraTs, hashToken } from "./app.js";
import { calcularEmprestimos, cmp } from "./emprestimosCalculo.js";
import { decisaoDe, dia, ErroGravacao, espelhoPronto, gravar, linhasDe } from "./espelho.js";

const APARELHO = "migracao"; // id próprio: o aviso "mudou" não pode ser filtrado do app que pediu a migração
const centavos = (v) => (Number.isFinite(Number(v)) ? Math.round(Math.abs(Number(v)) * 100) : 0);
const prefixo = (objetivo) => `mig:${objetivo}:`;
const idReal = (pk) => (pk.startsWith("mb:") ? pk.slice(3) : pk); // transactions.id; a decisão `tx:<id>` usa o id puro
const reais = (c) => c / 100;

// ---------- leitura ----------

/** Objetivos de empréstimo, lançamentos ligados e decisões do espelho (leitura pura). */
export async function lerEstado(db) {
  const objetivos = (await linhasDe(db, "objectives")).filter((o) => o.type === 1);
  const { results } = await db
    .prepare("SELECT pk, dados FROM espelho WHERE tabela = 'transactions' AND deleted_at IS NULL AND dados IS NOT NULL AND json_extract(dados, '$.objective_loan_fk') IS NOT NULL")
    .all();
  const ligadas = results.map((r) => ({ ...JSON.parse(r.dados), pk: r.pk }));
  const decisoes = new Map(); // tx_id -> decisão (a última vence, como no app)
  const perdoes = new Map(); // emprestimo_id -> perdão
  const linhasMig = []; // pks vivos `tx:mig:...`
  for (const r of await linhasDe(db, "mb_revisoes")) {
    const d = decisaoDe(r);
    if (!d) continue;
    if (d.tipo === "decisao" && d.tx_id && d.resposta) {
      decisoes.set(d.tx_id, d);
      if (String(d.tx_id).startsWith("mig:")) linhasMig.push(r.pk);
    } else if (d.tipo === "perdao" && typeof d.emprestimo_id === "string" && Number(d.valor) > 0 && /^\d{4}-\d{2}-\d{2}/.test(String(d.data ?? ""))) {
      perdoes.set(d.emprestimo_id, d);
    }
  }
  return { objetivos, ligadas, decisoes, perdoes, linhasMig };
}

const eventosDe = (estado, { semPrefixo = null, extras = [] } = {}) =>
  [...[...estado.decisoes.values()].filter((d) => !(semPrefixo && String(d.tx_id).startsWith(semPrefixo))), ...extras];
const perdoesDe = (estado, semPrefixo = null) => [...estado.perdoes.values()].filter((p) => !(semPrefixo && p.emprestimo_id.startsWith(semPrefixo)));

// ---------- planejamento de um objetivo ----------

/**
 * Plano de um objetivo antigo. `opcoes`: { pessoa?: string, ajustar?: boolean }.
 * Devolve o item da prévia + as linhas de `mb_revisoes` a gravar. As diferenças têm sinal tal que Σ = saldo antigo − saldo novo.
 */
export function planejarObjetivo(o, estado, opcoes = {}) {
  const nome = String(o.name ?? "").trim();
  const base = { objetivo: o.pk, nome, pessoa: null, status: "nao_mapeavel", motivos: [], avisos: [], lancamentos: 0, originalCentavos: 0, pagoCentavos: 0, saldoAntigoCentavos: 0, saldoNovoCentavos: 0, diferencas: [], linhas: [], grupo: null };
  if (!(o.income === 1 || o.income === true)) return { ...base, motivos: ["Empréstimo que você pegou (devo): fora desta migração"] };
  if (Number(o.amount) !== 0) return { ...base, motivos: ["Empréstimo de valor fixo: fora desta migração"] };
  const mias = estado.ligadas.filter((t) => t.objective_loan_fk === o.pk);
  if (!mias.length) return { ...base, motivos: ["Sem lançamentos ligados"] };

  const avisos = [];
  const naoPagos = mias.filter((t) => !t.paid);
  if (naoPagos.length) avisos.push(`${naoPagos.length} lançamento(s) não pago(s) ficam de fora (já não contavam no saldo antigo)`);
  const pagos = mias.filter((t) => t.paid && centavos(t.amount) > 0).map((t) => ({
    pk: t.pk, valor: centavos(t.amount), tipo: Number(t.amount) < 0 ? "emprestimo" : "devolucao", data: dia(t.date_created),
    divergente: (Number(t.amount) < 0) !== !(t.income === 1 || t.income === true),
  }));
  const assinado = (t) => (t.tipo === "emprestimo" ? t.valor : -t.valor);
  const saldoAntigo = pagos.reduce((s, t) => s + assinado(t), 0);

  // Fora do mapa (cada um vira uma diferença explicada): sem data, ou o id real do lançamento já tem decisão no modelo novo.
  const diferencas = [];
  const mapeados = [];
  for (const t of pagos) {
    const real = estado.decisoes.get(idReal(t.pk));
    const motivo = t.data == null ? "Sem data" : real && (real.resposta === "emprestimo" || real.resposta === "devolucao") ? "Já contado no modelo novo (decisão do próprio lançamento)" : null;
    if (motivo) diferencas.push({ tx: t.pk, data: t.data, tipo: t.tipo, centavos: assinado(t), motivo });
    else mapeados.push(t);
  }
  const emprestimos = mapeados.filter((t) => t.tipo === "emprestimo").sort((a, b) => cmp(a.data + a.pk, b.data + b.pk));
  if (!emprestimos.length) return { ...base, motivos: ["Nenhum empréstimo mapeável (só devoluções, ou todos já contados/sem data)"], lancamentos: mias.length, saldoAntigoCentavos: saldoAntigo, diferencas };

  const inicio = emprestimos[0].data;
  const grupo = `${prefixo(o.pk)}${emprestimos[0].pk}`;
  const pessoa = (typeof opcoes.pessoa === "string" ? opcoes.pessoa.trim().slice(0, 60) : nome) || null;
  const montar = (t, valor, data, id, dataOriginal) => ({
    pk: t.pk, tipo: t.tipo, valor, data, dataOriginal,
    d: {
      tipo: "decisao", tx_id: id, resposta: t.tipo, valor: reais(valor), data,
      descricao: `Migrado do empréstimo antigo${nome ? ` "${nome}"` : ""}`, ...(t.tipo === "emprestimo" && pessoa ? { pessoa } : {}),
      emprestimo_id: grupo, migrado_de: { objetivo: o.pk, lancamento: t.pk }, ...(dataOriginal ? { data_original: dataOriginal } : {}),
    },
  });
  const idDe = (t) => `${prefixo(o.pk)}${t.pk}`;
  let eventos;
  let ajustados = 0;
  if (!opcoes.ajustar) eventos = mapeados.map((t) => montar(t, t.valor, t.data, idDe(t), null));
  else {
    // Com ajuste, pagamento acima do saldo do dia não se perde: o excedente vira crédito e é aplicado, em partes, no dia dos próximos empréstimos
    // (a devolução guarda `data_original`). Empréstimo do dia entra antes do pagamento do mesmo dia, como no cálculo do app.
    eventos = [];
    const ordem = [...mapeados].sort((a, b) => cmp(a.data, b.data) || (a.tipo === b.tipo ? 0 : a.tipo === "emprestimo" ? -1 : 1) || cmp(a.pk, b.pk));
    const fila = [];
    const usouId = new Set();
    const parte = (t, valor, data) => {
      const id = usouId.has(t.pk) ? `${idDe(t)}~${eventos.filter((e) => e.pk === t.pk).length + 1}` : idDe(t);
      usouId.add(t.pk);
      eventos.push(montar(t, valor, data, id, data === t.data ? null : t.data));
    };
    let saldo = 0;
    for (const t of ordem) {
      if (t.tipo === "emprestimo") {
        eventos.push(montar(t, t.valor, t.data, idDe(t), null));
        saldo += t.valor;
        while (fila.length && saldo > 0) {
          const c = fila[0];
          const x = Math.min(c.resta, saldo);
          parte(c.t, x, t.data);
          c.resta -= x;
          saldo -= x;
          if (!c.resta) fila.shift();
        }
      } else {
        const x = Math.min(t.valor, saldo);
        saldo -= x;
        if (x > 0) parte(t, x, t.data);
        if (t.valor > x) { fila.push({ t, resta: t.valor - x }); ajustados++; }
      }
    }
    for (const c of fila) diferencas.push({ tx: c.t.pk, data: c.t.data, tipo: "devolucao", centavos: -c.resta, motivo: "Pago a mais: sobrou crédito depois do último empréstimo" });
  }
  const calc = calcularEmprestimos(eventos.map((e) => e.d));
  const g = [...calc.abertos, ...calc.quitados].find((e) => e.txId === grupo);
  const absorvido = new Map();
  for (const p of g.pagamentos) absorvido.set(p.txId, (absorvido.get(p.txId) ?? 0) + p.centavos);
  for (const e of eventos) {
    if (e.tipo !== "devolucao") continue;
    const perdido = e.valor - (absorvido.get(e.d.tx_id) ?? 0);
    if (perdido > 0) diferencas.push({ tx: e.pk, data: e.dataOriginal ?? e.data, tipo: "devolucao", centavos: -perdido, motivo: e.data < inicio ? "Devolução anterior ao primeiro empréstimo (o app não a abateria)" : "Pago a mais: acima do saldo no dia" });
  }
  const saldoNovo = g.restanteCentavos;
  const fecha = diferencas.reduce((s, d) => s + d.centavos, 0) === saldoAntigo - saldoNovo;

  const motivos = [];
  if (o.archived) motivos.push(saldoAntigo > 0 ? "Arquivado com saldo em aberto: confirme que ainda é devido" : "Arquivado");
  if (pagos.some((t) => t.divergente)) motivos.push("Sinal do valor e tipo (receita/despesa) divergem em algum lançamento: usei o sinal");
  if (!fecha) motivos.push("A reconciliação não fechou: não migre sem conferir");
  if (!pessoa) avisos.push("Sem pessoa: fica em \"Sem pessoa\" na tela");
  if (ajustados) avisos.push(`Datas ajustadas: ${ajustados} pagamento(s) acima do saldo foram aplicados no dia dos próximos empréstimos`);
  const status = !fecha ? "revisar" : motivos.length && (o.archived && saldoAntigo > 0 || pagos.some((t) => t.divergente)) ? "revisar" : "pronto";
  return {
    ...base, pessoa, status, motivos, avisos, lancamentos: mias.length, originalCentavos: g.originalCentavos, pagoCentavos: g.pagoCentavos,
    saldoAntigoCentavos: saldoAntigo, saldoNovoCentavos: saldoNovo, diferencas, grupo, inicio,
    linhas: eventos.map((e) => ({ tabela: "mb_revisoes", pk: `tx:${e.d.tx_id}`, dados: { pk: `tx:${e.d.tx_id}`, dados: JSON.stringify(e.d) } })),
  };
}

// ---------- prévia ----------

const restantes = (calc) => new Map([...calc.abertos, ...calc.quitados].map((e) => [e.txId, e.restanteCentavos]));

async function assinaturaDe(estado, ajustar = []) {
  const alvo = new Set(estado.ligadas.map((t) => idReal(t.pk)));
  const base = {
    o: estado.objetivos.map((o) => [o.pk, o.name, o.amount, o.income, o.archived ? 1 : 0]).sort((a, b) => cmp(a[0], b[0])),
    t: estado.ligadas.map((t) => [t.pk, t.objective_loan_fk, t.amount, t.income, t.paid ? 1 : 0, t.date_created]).sort((a, b) => cmp(a[0], b[0])),
    a: [...new Set(ajustar)].sort(cmp),
    d: [...estado.decisoes.values()].filter((d) => String(d.tx_id).startsWith("mig:") || alvo.has(d.tx_id)).map((d) => [d.tx_id, d.resposta, d.valor, d.data]).sort((a, b) => cmp(a[0], b[0])),
  };
  return hashToken(JSON.stringify(base));
}

/** Prévia (leitura pura). `opcoes`: { pessoas?: {objetivo: nome}, ajustar?: [objetivo] }. */
export async function previa(db, opcoes = {}, estadoPronto = null) {
  const estado = estadoPronto ?? (await lerEstado(db));
  const ajustar = new Set(opcoes.ajustar ?? []);
  const itens = [];
  for (const o of estado.objetivos.sort((a, b) => cmp(a.pk, b.pk))) {
    const base = { pessoa: opcoes.pessoas?.[o.pk] };
    const plano = planejarObjetivo(o, estado, { ...base, ajustar: ajustar.has(o.pk) });
    const vivas = [...estado.decisoes.keys()].filter((id) => id.startsWith(prefixo(o.pk)));
    if (vivas.length) {
      // migrado com ou sem ajuste de datas: vale se as decisões vivas batem com qualquer um dos dois planos
      const bate = (pl) => {
        const previstas = new Map(pl.linhas.map((l) => [JSON.parse(l.dados.dados).tx_id, JSON.parse(l.dados.dados)]));
        return previstas.size === vivas.length && vivas.every((id) => { const a = previstas.get(id), b = estado.decisoes.get(id); return a && a.valor === b.valor && a.data === b.data && a.resposta === b.resposta; });
      };
      const igual = bate(plano) || bate(planejarObjetivo(o, estado, { ...base, ajustar: !ajustar.has(o.pk) }));
      itens.push({ ...plano, status: igual ? "migrado" : "desatualizado", motivos: igual ? [] : ["O empréstimo antigo mudou depois da migração (lançamento novo, editado ou apagado): confira antes de desfazer e migrar de novo"], linhas: [] });
    } else {
      const alt = plano.status !== "nao_mapeavel" ? planejarObjetivo(o, estado, { ...base, ajustar: !ajustar.has(o.pk) }) : null;
      // mostra o que o outro modo (com/sem ajuste de datas) faria, para a pessoa escolher com os números na mão
      const comparar = alt && alt.saldoNovoCentavos !== plano.saldoNovoCentavos ? { ajustar: !ajustar.has(o.pk), saldoNovoCentavos: alt.saldoNovoCentavos, diferencaCentavos: alt.saldoAntigoCentavos - alt.saldoNovoCentavos } : null;
      itens.push(comparar ? { ...plano, alternativa: comparar } : plano);
    }
  }
  const antes = calcularEmprestimos(eventosDe(estado), perdoesDe(estado));
  const aplicaveis = itens.filter((i) => i.status === "pronto" || i.status === "revisar");
  const sim = simular(estado, aplicaveis);
  const sumNovo = aplicaveis.reduce((s, i) => s + i.saldoNovoCentavos, 0);
  return {
    assinatura: await assinaturaDe(estado, opcoes.ajustar ?? []),
    itens: itens.map(({ linhas, ...resto }) => resto),
    totais: {
      antesCentavos: antes.devidoCentavos,
      depoisCentavos: sim.depois.devidoCentavos,
      saldoAntigoCentavos: aplicaveis.reduce((s, i) => s + i.saldoAntigoCentavos, 0),
      saldoNovoCentavos: sumNovo,
      diferencaCentavos: aplicaveis.reduce((s, i) => s + i.saldoAntigoCentavos - i.saldoNovoCentavos, 0),
      ...efeitos(antes, sim.depois, aplicaveis),
    },
    contagem: Object.fromEntries(["pronto", "revisar", "migrado", "desatualizado", "nao_mapeavel"].map((s) => [s, itens.filter((i) => i.status === s).length])),
  };
}

function simular(estado, itens) {
  const extras = itens.flatMap((i) => i.linhas.map((l) => JSON.parse(l.dados.dados)));
  return { depois: calcularEmprestimos(eventosDe(estado, { extras }), perdoesDe(estado)) };
}

// depois − antes = Σ saldo novo (isolado) dos migrados + Σ deltas dos demais (devoluções antigas sem vínculo ou ordem do FIFO). Σ exato.
function efeitos(antes, depois, itens) {
  const antiga = restantes(antes), nova = restantes(depois);
  const esperado = new Map([...antiga, ...itens.map((i) => [i.grupo, i.saldoNovoCentavos])]);
  const efeitosSobreOutros = [];
  for (const [id, restante] of nova) {
    const e = esperado.get(id) ?? 0;
    if (restante !== e) efeitosSobreOutros.push({ emprestimo: id, centavos: restante - e, motivo: "Devolução antiga sem vínculo (abate o mais antigo): a ordem mudou com a migração" });
  }
  return { efeitosSobreOutros };
}

// ---------- aplicar ----------

const erro = (status, corpo) => ({ status, corpo });
const okLista = (v, max) => Array.isArray(v) && v.length >= 1 && v.length <= max && v.every((x) => typeof x === "string" && x.length > 0 && x.length < 100);

export async function aplicar(env, ctx, corpo) {
  if (!(await espelhoPronto(env))) return erro(409, { erro: "O espelho não está ativo ou semeado: nada pode ser gravado" });
  if (!corpo || typeof corpo !== "object" || !okLista(corpo.objetivos, 50) || typeof corpo.assinatura !== "string") return erro(400, { erro: "Informe objetivos[] e assinatura" });
  if (corpo.pessoas != null && (typeof corpo.pessoas !== "object" || Object.values(corpo.pessoas).some((v) => typeof v !== "string"))) return erro(400, { erro: "pessoas inválido" });
  if (corpo.ajustar != null && !(Array.isArray(corpo.ajustar) && !corpo.ajustar.length) && !okLista(corpo.ajustar, 50)) return erro(400, { erro: "ajustar inválido" });
  const opcoes = { pessoas: corpo.pessoas ?? {}, ajustar: corpo.ajustar ?? [] };
  const estado = await lerEstado(env.DB);
  const atual = await previa(env.DB, opcoes, estado);
  if (atual.assinatura !== corpo.assinatura) return erro(409, { erro: "Os dados mudaram desde a prévia: confira a prévia de novo", previa: atual });

  const ajustar = new Set(opcoes.ajustar);
  const escolhidos = [];
  const resultado = [];
  for (const pk of [...new Set(corpo.objetivos)]) {
    const item = atual.itens.find((i) => i.objetivo === pk);
    if (!item) { resultado.push({ objetivo: pk, resultado: "nao_encontrado" }); continue; }
    if (item.status === "migrado") { resultado.push({ objetivo: pk, resultado: "ja_migrado" }); continue; }
    if (item.status !== "pronto" && item.status !== "revisar") { resultado.push({ objetivo: pk, resultado: "recusado", motivos: item.motivos }); continue; }
    const o = estado.objetivos.find((x) => x.pk === pk);
    escolhidos.push(planejarObjetivo(o, estado, { pessoa: opcoes.pessoas[pk], ajustar: ajustar.has(pk) }));
  }
  if (!escolhidos.length) return { status: 200, corpo: { ok: true, aplicados: [], resultado, antesCentavos: atual.totais.antesCentavos, depoisCentavos: atual.totais.antesCentavos } };

  const antes = calcularEmprestimos(eventosDe(estado), perdoesDe(estado));
  const depois = simular(estado, escolhidos).depois;
  const hashOutros = await hashToken(JSON.stringify(eventosCanonicos(estado)));
  try {
    await gravar({ env, ctx }, escolhidos.flatMap((p) => p.linhas), APARELHO);
  } catch (e) {
    if (e instanceof ErroGravacao) return erro(502, { erro: e.message });
    throw e;
  }
  const ts = agoraTs();
  await env.DB.batch(escolhidos.map((p) =>
    env.DB.prepare("INSERT INTO emprestimos_migracao (objetivo, acao, em, pks, saldo_antigo, saldo_novo, antes, depois, hash_outros, pessoa) VALUES (?1, 'aplicar', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)")
      .bind(p.objetivo, ts, JSON.stringify(p.linhas.map((l) => l.pk)), p.saldoAntigoCentavos, p.saldoNovoCentavos, antes.devidoCentavos, depois.devidoCentavos, hashOutros, p.pessoa)));
  return {
    status: 200,
    corpo: {
      ok: true, resultado, antesCentavos: antes.devidoCentavos, depoisCentavos: depois.devidoCentavos,
      aplicados: escolhidos.map((p) => ({ objetivo: p.objetivo, pessoa: p.pessoa, saldoAntigoCentavos: p.saldoAntigoCentavos, saldoNovoCentavos: p.saldoNovoCentavos, decisoes: p.linhas.length })),
      ...efeitos(antes, depois, escolhidos),
    },
  };
}

// Eventos de empréstimo/devolução/perdão que não são de nenhuma migração (`mig:`), em forma canônica, para saber se algo mudou fora dela.
// Ignora TODAS as migrações (não só a do objetivo): migrar ou desfazer outro objetivo depois não pode invalidar a trava do desfazer.
function eventosCanonicos(estado, semPrefixo = "mig:") {
  const ev = eventosDe(estado, { semPrefixo }).filter((d) => d.resposta === "emprestimo" || d.resposta === "devolucao")
    .map((d) => [d.tx_id, d.resposta, d.valor, d.data, d.emprestimo_id ?? null, d.sobra ?? null, d.sobra_para ?? null, d.sobra_id ?? null]);
  const pe = perdoesDe(estado, semPrefixo).map((p) => ["perdao", p.emprestimo_id, p.valor, p.data]);
  return [...ev, ...pe].map((x) => JSON.stringify(x)).sort(cmp).map((x) => JSON.parse(x));
}

// ---------- desfazer ----------

export async function desfazer(env, ctx, corpo) {
  if (!(await espelhoPronto(env))) return erro(409, { erro: "O espelho não está ativo ou semeado: nada pode ser gravado" });
  const objetivo = corpo?.objetivo;
  if (typeof objetivo !== "string" || !objetivo || objetivo.length > 100) return erro(400, { erro: "Informe o objetivo" });
  const estado = await lerEstado(env.DB);
  const pre = prefixo(objetivo);
  const pks = estado.linhasMig.filter((pk) => pk.startsWith(`tx:${pre}`));
  if (!pks.length) return erro(409, { erro: "Este empréstimo não está migrado" });

  const alheias = [...estado.decisoes.values()].filter((d) => !String(d.tx_id).startsWith(pre) && (String(d.emprestimo_id ?? "").startsWith(pre) || String(d.sobra_id ?? "").startsWith(pre)));
  const perdoados = [...estado.perdoes.values()].filter((p) => p.emprestimo_id.startsWith(pre));
  if (alheias.length || perdoados.length) {
    return erro(409, { erro: "Não dá para desfazer: já há pagamento ou perdão registrado em cima deste empréstimo no modelo novo", referencias: alheias.length + perdoados.length });
  }
  const com = calcularEmprestimos(eventosDe(estado), perdoesDe(estado));
  const sem = calcularEmprestimos(eventosDe(estado, { semPrefixo: pre }), perdoesDe(estado, pre));
  const rCom = restantes(com), rSem = restantes(sem);
  const mudam = [...rSem].filter(([id, r]) => (rCom.get(id) ?? 0) !== r).map(([id]) => id);
  if (mudam.length) {
    const ultima = await env.DB.prepare("SELECT hash_outros FROM emprestimos_migracao WHERE objetivo = ?1 AND acao = 'aplicar' ORDER BY id DESC LIMIT 1").bind(objetivo).first("hash_outros");
    const hoje = await hashToken(JSON.stringify(eventosCanonicos(estado)));
    if (ultima !== hoje) return erro(409, { erro: "Não dá para desfazer: houve lançamentos no modelo novo depois da migração e o desfazer mudaria o saldo de outros empréstimos", emprestimos: mudam });
  }
  const ts = agoraTs();
  try {
    await gravar({ env, ctx }, pks.map((pk) => ({ tabela: "mb_revisoes", pk, dados: null, deleted_at: ts })), APARELHO);
  } catch (e) {
    if (e instanceof ErroGravacao) return erro(502, { erro: e.message });
    throw e;
  }
  await env.DB.prepare("INSERT INTO emprestimos_migracao (objetivo, acao, em, pks, antes, depois) VALUES (?1, 'desfazer', ?2, ?3, ?4, ?5)")
    .bind(objetivo, ts, JSON.stringify(pks), com.devidoCentavos, sem.devidoCentavos).run();
  return { status: 200, corpo: { ok: true, removidas: pks.length, antesCentavos: com.devidoCentavos, depoisCentavos: sem.devidoCentavos } };
}
