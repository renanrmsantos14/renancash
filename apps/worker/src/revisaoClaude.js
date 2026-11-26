// src/revisaoClaude.js — revisão diária do Claude pelo MCP (docs/ia-automatica-plano.md, fase 3): a fila do que falta decidir,
// a aplicação do que o Claude tem certeza (origem `claude` em ia_aplicacoes: aparece em "Feito pela IA" e tem Desfazer) e o resumo
// como push do app. Nunca cria nem apaga transação; linha `mb:` editada no app nunca é tocada. Não importa mcp.js (os nomes de
// categoria chegam já resolvidos em pk).
import { gravar, editadaNoApp, espelhoPronto, linhasDe } from "./espelho.js";
import { agoraTs, hojeSP } from "./app.js";
import { somarDias } from "./ciclo.js";
import { candidatas } from "./anotacoes.js";
import { tipoDeRevisao, nomeDaPessoa, normalizarRevisao } from "./revisao.js";
import { configIa, lerSeguro, resolver, aplicarPendentesIa, contextoDevolucao, emCentavos, JANELA_DEVOLUCAO } from "./iaAuto.js";
import { stmtAlertas, emSilencio } from "./alertas.js";

const APARELHO = "claude";
export const MAX_ITENS = 30;
export const MAX_TITULO_RESUMO = 80;
export const MAX_TEXTO_RESUMO = 500;
const MAX_FILA = 80;
const DECIDIDA = ["pendente", "aplicada", "desfeita", "descartada"];
const DO_REVISAR = ["pix_recebido", "envio_santander"];
const ANOTADA = "('vinculada', 'automatica', 'aplicada')"; // transação já ligada a uma anotação: o título e a categoria vêm dela
const recusa = (erro) => ({ ok: false, erro });

// ---------- Fila ----------

// Gastos e entradas do banco que o app ainda mostra em "Para classificar" (linha `mb:` não editada ou ainda não importada), sem
// decisão da IA além da sombra do Llama. Pix recebido e envio ao Santander são do "Para revisar".
export async function paraClassificar(env, dias) {
  const db = env.DB;
  const [{ results }, categorias] = await Promise.all([
    db.prepare(
      `SELECT t.id, t.date, t.description, t.merchant, t.contraparte, t.amount, t.scheduled, a.type AS tipo_conta, a.name AS conta,
              e.dados AS app, i.sugestao AS palpite, i.confianca
       FROM transactions t JOIN accounts a ON a.id = t.account_id
       LEFT JOIN espelho e ON e.tabela = 'transactions' AND e.pk = 'mb:' || t.id
       LEFT JOIN ia_aplicacoes i ON i.tx_id = t.id
       WHERE t.date >= ?1 AND t.scheduled = 0 AND t.status != 'PENDING' AND e.deleted_at IS NULL
         AND COALESCE(CAST(json_extract(e.dados, '$.date_time_modified') AS REAL), 0) < 978307200
         AND (i.tx_id IS NULL OR i.status = 'sombra')
         AND NOT EXISTS (SELECT 1 FROM anotacoes n WHERE n.transacao_id = t.id AND n.status IN ${ANOTADA})
       ORDER BY t.date DESC, t.id LIMIT ?2`
    ).bind(somarDias(hojeSP(), -dias), MAX_FILA * 2).all(),
    linhasDe(db, "categories"),
  ]);
  const nome = new Map(categorias.map((c) => [c.pk, c.name]));
  return results
    .filter((t) => !(t.tipo_conta !== "CREDIT" && DO_REVISAR.includes(tipoDeRevisao(t)?.tipo)))
    .slice(0, MAX_FILA)
    .map((t) => {
      const app = t.app ? lerSeguro(t.app) : null;
      const p = t.palpite ? lerSeguro(t.palpite) : null;
      return {
        tx_id: t.id, data: t.date, texto_do_banco: t.description, estabelecimento: t.merchant || t.contraparte || null,
        valor: t.tipo_conta === "CREDIT" ? -t.amount : t.amount, conta: t.conta, // negativo = gasto
        no_app: app ? { titulo: app.name ?? null, categoria: nome.get(app.category_fk) ?? null } : null,
        ...(p?.category_fk ? { palpite_llama: { categoria: nome.get(p.category_fk) ?? p.category_fk, subcategoria: nome.get(p.sub_category_fk) ?? null, titulo: p.name ?? null, confianca: t.confianca } } : {}),
      };
    });
}

// Pix recebidos da fila "Para revisar" com as compras que eles podem devolver (valor exato, até 30 dias antes, não usadas).
export async function paraRevisar(env, revisar) {
  const db = env.DB;
  const pix = (revisar ?? []).filter((i) => i.tipo === "pix_recebido");
  if (!pix.length) return [];
  const [{ results: txs }, ctx] = await Promise.all([
    db.prepare("SELECT id, contraparte FROM transactions WHERE id IN (SELECT value FROM json_each(?1))").bind(JSON.stringify(pix.map((i) => i.tx_id))).all(),
    contextoDevolucao(db, somarDias(pix.map((i) => i.data).sort()[0], -JANELA_DEVOLUCAO)),
  ]);
  const parte = new Map(txs.map((t) => [t.id, normalizarRevisao(t.contraparte)]));
  return pix.map((i) => {
    const piso = somarDias(i.data, -JANELA_DEVOLUCAO);
    const pessoa = nomeDaPessoa(i.descricao);
    const compras = ctx.compras
      .filter((c) => !ctx.usadas.has(c.id) && emCentavos(c.amount) === -emCentavos(i.valor) && c.date >= piso && c.date <= i.data)
      .map((c) => ({
        compra_id: c.id, data: c.date, texto_do_banco: c.description, valor: c.amount,
        mesmo_favorecido: !!((pessoa && pessoa === nomeDaPessoa(c.description)) || (parte.get(i.tx_id) && parte.get(i.tx_id) === normalizarRevisao(c.contraparte ?? c.merchant))),
      }));
    return { tx_id: i.tx_id, data: i.data, texto_do_banco: i.descricao, valor: i.valor, compras_candidatas: compras };
  });
}

// ---------- Aplicação ----------

async function classificar(db, it, cats, ts) {
  const t = await db.prepare(
    `SELECT t.id, t.description, t.amount, t.status, t.scheduled, a.type AS tipo_conta, e.dados AS app, e.deleted_at AS apagada, i.status AS ia,
            EXISTS (SELECT 1 FROM anotacoes n WHERE n.transacao_id = t.id AND n.status IN ${ANOTADA}) AS anotada
     FROM transactions t JOIN accounts a ON a.id = t.account_id
     LEFT JOIN espelho e ON e.tabela = 'transactions' AND e.pk = 'mb:' || t.id LEFT JOIN ia_aplicacoes i ON i.tx_id = t.id WHERE t.id = ?1`
  ).bind(it.tx_id).first();
  if (!t) return recusa("Transação do banco não encontrada");
  if (t.status === "PENDING" || t.scheduled) return recusa("Transação ainda pendente ou agendada no banco");
  if (t.apagada != null) return recusa("Transação apagada no app");
  if (t.app && editadaNoApp(lerSeguro(t.app))) return recusa("Já editada no app: a decisão é do Renan");
  if (DECIDIDA.includes(t.ia)) return recusa(`A IA já decidiu esta transação (${t.ia})`);
  if (t.anotada) return recusa("Transação já ligada a uma anotação");
  if (t.tipo_conta !== "CREDIT" && DO_REVISAR.includes(tipoDeRevisao(t)?.tipo)) return recusa("É item do Para revisar, não de classificação");
  if (!it.category_fk) return recusa("categoria obrigatória");
  const r = resolver(cats, it.category_fk, it.sub_category_fk, t.tipo_conta === "CREDIT" ? -t.amount : t.amount);
  if (!r) return recusa("Categoria arquivada ou de receita num gasto");
  const sugestao = { name: it.titulo, ...r, motivo: it.motivo };
  // Só entra sem decisão ou por cima da sombra: memória, regra, anotação ou o Renan (desfeita/descartada) ganham.
  const { results } = await db.prepare(
    `INSERT INTO ia_aplicacoes (tx_id, origem, chave, sugestao, confianca, status, criado_em, atualizado_em, avisada_em) VALUES (?1, 'claude', NULL, ?2, 1, 'pendente', ?3, ?3, ?3)
     ON CONFLICT(tx_id) DO UPDATE SET origem = 'claude', chave = NULL, sugestao = excluded.sugestao, confianca = 1, status = 'pendente',
       anterior = NULL, depois = NULL, acerto = NULL, aplicado_em = NULL, atualizado_em = excluded.atualizado_em, avisada_em = excluded.avisada_em
     WHERE ia_aplicacoes.status = 'sombra' RETURNING tx_id`
  ).bind(t.id, JSON.stringify(sugestao), ts).all();
  return results.length ? { ok: true } : recusa("A IA acabou de decidir esta transação");
}

async function anotacao(db, it, ts) {
  const an = it.anotacao_id && (await db.prepare("SELECT * FROM anotacoes WHERE id = ?1").bind(it.anotacao_id).first());
  if (!an) return recusa("Anotação não encontrada");
  if (an.status !== "pendente") return recusa(`Anotação está ${an.status}`);
  const c = (await candidatas(db, an)).find((x) => x.transacao_id === it.tx_id);
  if (!c) return recusa("A transação não é candidata desta anotação (veja anotacoes_pendentes)");
  if (c.pendente_no_banco) return recusa("Transação ainda pendente no banco");
  if (c.apagada_no_app) return recusa("Transação apagada no app");
  if (c.no_app?.ja_editada) return recusa("Já editada no app: a decisão é do Renan");
  const ia = await db.prepare("SELECT status FROM ia_aplicacoes WHERE tx_id = ?1").bind(it.tx_id).first("status");
  if (["aplicada", "desfeita", "descartada"].includes(ia)) return recusa(`A IA já decidiu esta transação (${ia})`);
  const sugestao = { name: an.titulo || an.descricao, category_fk: an.categoria ?? null, sub_category_fk: an.subcategoria ?? null, note: an.nota ?? null, anotacao_id: an.id, motivo: it.motivo };
  // Mesma transição condicional da ligação automática (anotacoes.js): a decisão só entra com a anotação pendente e vice-versa.
  const [, ligou] = await db.batch([
    db.prepare(
      `INSERT INTO ia_aplicacoes (tx_id, origem, chave, sugestao, confianca, status, criado_em, atualizado_em, avisada_em)
       SELECT ?1, 'claude', ?2, ?3, 1, 'pendente', ?4, ?4, ?4 WHERE EXISTS (SELECT 1 FROM anotacoes WHERE id = ?2 AND status = 'pendente')
       ON CONFLICT(tx_id) DO UPDATE SET origem = excluded.origem, chave = excluded.chave, sugestao = excluded.sugestao, confianca = 1, status = 'pendente',
         anterior = NULL, depois = NULL, acerto = NULL, aplicado_em = NULL, atualizado_em = excluded.atualizado_em, avisada_em = excluded.avisada_em
       WHERE ia_aplicacoes.status IN ('pendente', 'sombra')`
    ).bind(it.tx_id, an.id, JSON.stringify(sugestao), ts),
    db.prepare("UPDATE anotacoes SET status = 'automatica', transacao_id = ?1, atualizada = ?2 WHERE id = ?3 AND status = 'pendente' AND EXISTS (SELECT 1 FROM ia_aplicacoes WHERE tx_id = ?1 AND origem = 'claude' AND chave = ?3 AND status = 'pendente') RETURNING id")
      .bind(it.tx_id, ts, an.id),
  ]);
  return ligou.results.length ? { ok: true } : recusa("A anotação ou a transação mudou agora: chame fila_revisao de novo");
}

async function devolucao(env, ctx, it, ts) {
  const db = env.DB;
  const t = await db.prepare("SELECT t.*, a.type AS tipo_conta, i.status AS ia FROM transactions t JOIN accounts a ON a.id = t.account_id LEFT JOIN ia_aplicacoes i ON i.tx_id = t.id WHERE t.id = ?1").bind(it.tx_id).first();
  if (!t) return recusa("Pix do banco não encontrado");
  if (t.tipo_conta === "CREDIT" || t.status === "PENDING" || t.scheduled || tipoDeRevisao(t)?.tipo !== "pix_recebido") return recusa("Só Pix recebido em conta corrente, já postado");
  if (DECIDIDA.includes(t.ia)) return recusa(`A IA já decidiu este Pix (${t.ia})`);
  const pk = "tx:" + t.id;
  const viva = () => db.prepare("SELECT 1 FROM espelho WHERE tabela = 'mb_revisoes' AND pk = ?1 AND deleted_at IS NULL").bind(pk).first();
  if (await viva()) return recusa("Já respondido no app");
  const { compras, usadas } = await contextoDevolucao(db, somarDias(t.date, -JANELA_DEVOLUCAO));
  const c = compras.find((x) => x.id === it.reembolso_de);
  if (!c || c.date > t.date) return recusa("Compra não encontrada (Pix enviado/compra em conta corrente, até 30 dias antes do Pix)");
  if (emCentavos(c.amount) !== -emCentavos(t.amount)) return recusa("O valor da compra é diferente do Pix: só devolução total");
  if (usadas.has(c.id)) return recusa("Compra já reembolsada ou ligada a empréstimo");
  const decisao = { tipo: "decisao", tx_id: t.id, resposta: "reembolso", reembolso_de: c.id, valor: Math.abs(t.amount), data: t.date, descricao: String(t.description ?? "").slice(0, 200), ia: "claude" };
  if (await viva()) return recusa("Já respondido no app"); // conferida de novo logo antes de gravar
  // Reserva antes de gravar: sem o registro não há "Feito pela IA" nem Desfazer, e a devolução automática (fase 2) e outra
  // devolução para a mesma compra passam a ver esta. Falhou ao gravar: a reserva sai e nada foi aplicado.
  const { results: reservou } = await db.prepare(
    `INSERT INTO ia_aplicacoes (tx_id, origem, sugestao, confianca, status, depois, criado_em, aplicado_em, atualizado_em, avisada_em) VALUES (?1, 'claude', ?2, 1, 'aplicada', ?3, ?4, ?4, ?4, ?4)
     ON CONFLICT(tx_id) DO UPDATE SET origem = 'claude', chave = NULL, sugestao = excluded.sugestao, confianca = 1, status = 'aplicada', anterior = NULL,
       depois = excluded.depois, acerto = NULL, aplicado_em = excluded.aplicado_em, atualizado_em = excluded.atualizado_em, avisada_em = excluded.avisada_em
     WHERE ia_aplicacoes.status = 'sombra' RETURNING tx_id`
  ).bind(t.id, JSON.stringify({ reembolso_de: c.id, compra: c.description, motivo: it.motivo }), JSON.stringify(decisao), ts).all();
  if (!reservou.length) return recusa("A IA acabou de decidir este Pix");
  try {
    await gravar({ env, ctx }, [{ tabela: "mb_revisoes", pk, dados: { pk, dados: JSON.stringify(decisao) } }], APARELHO);
  } catch (e) {
    await db.prepare("DELETE FROM ia_aplicacoes WHERE tx_id = ?1 AND origem = 'claude' AND status = 'aplicada' AND aplicado_em = ?2").bind(t.id, ts).run();
    throw e;
  }
  return { ok: true, status: "aplicada" };
}

// itens: [{tipo, tx_id, category_fk?, sub_category_fk?, titulo?, anotacao_id?, reembolso_de?, motivo, erro?}] (erro = recusado antes,
// ex.: categoria que não existe). Resultado item a item; classificação e anotação entram `pendente` e são aplicadas aqui mesmo.
export async function aplicarClaude(env, ctx, itens) {
  if (!(await espelhoPronto(env))) return { recusado: "O espelho do app não está ligado: nada aplicado." };
  const cfg = await configIa(env);
  if (!cfg.auto || !cfg.claude) return { recusado: `Desligado (${!cfg.auto ? "ia_auto" : "ia_claude"} = "0"): nada aplicado. Mande só o resumo.` };
  const db = env.DB;
  const cats = new Map((await linhasDe(db, "categories")).map((c) => [c.pk, c]));
  const ts = agoraTs();
  const resultados = [];
  for (const it of itens) {
    let r;
    try {
      r = it.erro ? recusa(it.erro)
        : it.tipo === "classificar" ? await classificar(db, it, cats, ts)
        : it.tipo === "anotacao" ? await anotacao(db, it, ts)
        : it.tipo === "devolucao" ? await devolucao(env, ctx, it, ts)
        : recusa("tipo deve ser classificar, anotacao ou devolucao");
    } catch (e) {
      console.error("Revisão do Claude", it.tipo, e?.stack || e);
      r = recusa(String(e?.message || e));
    }
    resultados.push({ tipo: it.tipo, tx_id: it.tx_id, ...r });
  }
  const ligadas = resultados.filter((r) => r.ok && !r.status);
  if (ligadas.length) {
    // As decisões já estão gravadas: falhar aqui não pode virar erro da chamada inteira (ficam pendentes e a próxima sincronização aplica).
    await aplicarPendentesIa(env, ctx, cfg).catch((e) => console.error("Revisão do Claude: aplicação", e?.stack || e));
    const ids = ligadas.map((r) => r.tx_id);
    const { results } = await db.prepare(
      `SELECT i.tx_id, i.status, e.pk IS NOT NULL AS importada FROM ia_aplicacoes i
       LEFT JOIN espelho e ON e.tabela = 'transactions' AND e.pk = 'mb:' || i.tx_id AND e.deleted_at IS NULL AND e.dados IS NOT NULL
       WHERE i.tx_id IN (SELECT value FROM json_each(?1))`
    ).bind(JSON.stringify(ids)).all();
    const st = new Map(results.map((x) => [x.tx_id, x]));
    for (const r of ligadas) {
      const x = st.get(r.tx_id);
      if (x?.status === "pendente") r.status = x.importada ? "pendente: aplica na próxima sincronização" : "aguardando o app importar a transação";
      else if (x?.status === "aplicada") r.status = "aplicada";
      else Object.assign(r, recusa(x?.status === "descartada" ? "Editada no app antes de aplicar: a decisão é do Renan" : "A decisão mudou antes de aplicar"), { status: x?.status ?? null });
    }
  }
  return { resultados, aplicadas: resultados.filter((r) => r.ok).length, recusadas: resultados.filter((r) => !r.ok).length };
}

// ---------- Resumo (push) ----------

// titulo e texto já aparados (string ou null). No máximo 1 por dia (São Paulo): a chave da notificação é o dia. Em silêncio (22h–7h) fica gravado e sai no cron das 7h.
export async function enviarResumo(env, { titulo, texto }, enviarPendentes) {
  if (!titulo || !texto) return { erro: "titulo e texto obrigatórios" };
  if (titulo.length > MAX_TITULO_RESUMO) return { erro: `titulo com ${titulo.length} caracteres (máximo ${MAX_TITULO_RESUMO}): encurte` };
  if (texto.length > MAX_TEXTO_RESUMO) return { erro: `texto com ${texto.length} caracteres (máximo ${MAX_TEXTO_RESUMO}): encurte` };
  const chave = `ia:claude:${hojeSP()}`;
  const r = await stmtAlertas(env.DB, [{ chave, titulo, corpo: texto }])[0].run();
  if (!r.meta?.changes) return { enviado: false, motivo: "Já enviado hoje" };
  if (emSilencio(new Date())) return { enviado: true, push: "Silêncio das 22h às 7h: o push sai às 7h" };
  const n = await enviarPendentes();
  return { enviado: true, push: n ? `Enviado para ${n} aparelho(s)` : "Gravado; nenhum aparelho recebeu o push agora (aparece ao abrir o app)" };
}
