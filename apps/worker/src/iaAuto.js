// src/iaAuto.js — IA automática, fase 1 (docs/ia-automatica-plano.md): memória por favorecido no servidor, decisão na chegada
// da transação da Pluggy, modo sombra do Llama e a lista "Feito pela IA" com Desfazer.
//
// Só roda com o espelho ligado e semeado. Kill switch: `ia_auto` = "0" (linha `_config` do espelho, tabela `config` ou var IA_AUTO)
// desliga decisão, aplicação e push. `ia_limiar` (mesmas fontes) ausente = o Llama nunca aplica, só registra em sombra.
// A escrita vai pelo mesmo caminho do MCP (`gravar`: LWW com updated_at = max(agora, atual + 1 ms)) como o aparelho "ia".
// Linha `mb:` já editada pelo usuário (date_time_modified >= 2001) nunca é sobrescrita.
import { ordenarRegras, padraoCasa } from "@meu-banco/core";
import { gravar, editadaNoApp, espelhoPronto, linhasDe } from "./espelho.js";
import { sugerir, MAX_LANCAMENTOS } from "./ia.js";
import { agoraS, agoraTs, hojeSP, DIAS_REIMPORTAR } from "./app.js";
import { lerJson as json } from "./sync.js";
import { somarDias } from "./ciclo.js";

const APARELHO = "ia";
const MAX_TX = 200;
const MAX_LOTES_LLAMA = 2; // até 16 lançamentos por sincronização (cada chamada pode levar até 15 s); o resto fica para a próxima
const MIN_CONFIRMACOES = 2;
const DIAS_LISTA = 14;
const MAX_PADROES = 1000;
const MAX_NOME = 60;
const FAIXAS = [[0.7, 0.8], [0.8, 0.9], [0.9, 1]];

// ---------- Chave do favorecido (igual a mbChavePadrao, budget/lib/struct/mbSync/classificar.dart) ----------

const DE = "ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ";
const PARA = "AAAAAEEEEIIIIOOOOOUUUUC";
// mbNormalizarRevisao (revisao.dart): troca só os acentos da tabela; o resto que não é A-Z vira espaço.
export function normalizarRevisao(s) {
  let b = "";
  for (const c of String(s ?? "").toUpperCase().split("")) { const i = DE.indexOf(c); b += i >= 0 ? PARA[i] : c; }
  return b.replace(/[^A-Z ]+/g, " ").replace(/\s+/g, " ").trim();
}
const PREFIXO_BANCO = /^(?:PIX (?:ENVIAD[OA]|ENVIO|RECEBID[OA]|RECEBIMENTO)|(?:TED|DOC|TRANSFERENCIA)(?: (?:ENVIAD[OA]|RECEBID[OA]))?|PAGAMENTO(?: DE)?|PAG|COMPRA(?: NO)?(?: (?:DEBITO|CREDITO))?)\b ?/;
export const chavePadrao = (descricao) => normalizarRevisao(descricao).replace(PREFIXO_BANCO, "").split(" ").filter((p) => p.length > 1).slice(0, 4).join(" ");

// Título escrito pelo usuário (não o texto do banco): é o que a memória repete nas próximas.
function nomeDoUsuario(nome, descricao) {
  const t = typeof nome === "string" ? nome.trim() : "";
  if (!t || t === String(descricao ?? "").trim() || PREFIXO_BANCO.test(normalizarRevisao(t))) return null;
  return t.slice(0, MAX_NOME);
}

// ---------- Configuração ----------

// Kill switch: qualquer fonte com "0" desliga. Limiar: a primeira definida (espelho, config, var), entre 0 e 1.
export async function configIa(env) {
  const db = env.DB;
  const [esp, cfg] = await db.batch([
    db.prepare("SELECT pk, dados FROM espelho WHERE tabela = '_config' AND pk IN ('ia_auto', 'ia_limiar') AND deleted_at IS NULL"),
    db.prepare("SELECT chave, valor FROM config WHERE chave IN ('ia_auto', 'ia_limiar')"),
  ]);
  const fontes = [
    Object.fromEntries(esp.results.map((r) => { try { return [r.pk, JSON.parse(r.dados)?.v]; } catch { return [r.pk, null]; } })),
    Object.fromEntries(cfg.results.map((r) => [r.chave, r.valor])),
    { ia_auto: env.IA_AUTO, ia_limiar: env.IA_LIMIAR },
  ];
  const auto = !fontes.some((f) => f.ia_auto != null && String(f.ia_auto).trim() === "0");
  const bruto = fontes.map((f) => f.ia_limiar).find((v) => v != null && String(v).trim() !== "");
  const l = Number(String(bruto ?? "").replace(",", "."));
  return { auto, limiar: bruto != null && l > 0 && l <= 1 ? l : null };
}

// ---------- Catálogo do app (espelho) ----------

// Categoria (ou subcategoria, que leva a mãe) que ainda existe e serve ao sinal do valor → {category_fk, sub_category_fk} ou null.
function resolver(cats, catPk, subPk, valor) {
  let cat = cats.get(catPk);
  let sub = subPk ? cats.get(subPk) : null;
  if (cat?.main_category_pk) { sub = cat; cat = cats.get(cat.main_category_pk); }
  if (!cat || cat.archived || cat.main_category_pk || (valor < 0 && cat.income)) return null;
  if (sub && (sub.archived || sub.main_category_pk !== cat.pk)) sub = null;
  return { category_fk: cat.pk, sub_category_fk: sub?.pk ?? null };
}

function contextoLlama(cats, memoria, chaves) {
  const todas = [...cats.values()].filter((c) => !c.archived).sort((a, b) => (a.order ?? 0) - (b.order ?? 0) || (a.pk < b.pk ? -1 : 1));
  const categorias = todas.filter((c) => !c.main_category_pk).map((c) => ({
    pk: c.pk, nome: c.name, receita: !!c.income, subs: todas.filter((s) => s.main_category_pk === c.pk).map((s) => ({ pk: s.pk, nome: s.name })),
  }));
  const ordem = [...memoria.values()].filter((m) => m.confirmacoes > 0).sort((a, b) => chaves.has(b.chave) - chaves.has(a.chave));
  const exemplos = ordem.map((m) => ({ descricao: m.chave, categoria: m.category_fk, subcategoria: m.sub_category_fk, titulo: m.nome }));
  return { categorias, vinculos: [], exemplos };
}

// ---------- Decisão na chegada (fim de cada sincronização com a Pluggy) ----------

// Transações da janela sem decisão: regra do usuário ou memória confirmada 2+ vezes → aplicar; senão o Llama, em lote, só registra
// (sombra) — a não ser que `ia_limiar` esteja definido e a confiança passe dele. Falha do Workers AI: nada é gravado (fica na fila).
//
// Parte síncrona (regra/memória) sempre bloqueia. A do Llama bloqueia quando pode aplicar (`ia_limiar`) ou sem `ctx`;
// em sombra só registra, então roda em `ctx.waitUntil` e não atrasa o Atualizar.
export async function decidirIa(env, ctx) {
  if (!(await espelhoPronto(env))) return;
  const cfg = await configIa(env);
  if (!cfg.auto) return;
  const db = env.DB;
  const { results: txs } = await db.prepare(
    `SELECT t.id, t.description, t.amount, t.date, a.type AS tipo_conta, a.name AS conta, e.dados AS app, e.deleted_at AS apagada
     FROM transactions t JOIN accounts a ON a.id = t.account_id
     LEFT JOIN espelho e ON e.tabela = 'transactions' AND e.pk = 'mb:' || t.id
     WHERE t.date >= ?1 AND t.scheduled = 0 AND t.status != 'PENDING' AND NOT EXISTS (SELECT 1 FROM ia_aplicacoes i WHERE i.tx_id = t.id)
       -- PENDING fica de fora: a Pluggy recria o id ao postar e a decisão ficaria órfã
       -- apagada ou já editada no app nunca ganha decisão: fora do LIMIT, senão ocupariam a janela para sempre
       AND e.deleted_at IS NULL AND COALESCE(CAST(json_extract(e.dados, '$.date_time_modified') AS REAL), 0) < 978307200
     ORDER BY t.date DESC, t.id LIMIT ?2`
  ).bind(somarDias(hojeSP(), -DIAS_REIMPORTAR), MAX_TX).all();
  const novas = txs.filter((t) => !t.apagada && !editadaNoApp(json(t.app)));
  if (!novas.length) return;
  const [categorias, titulos, mem] = await Promise.all([
    linhasDe(db, "categories"), linhasDe(db, "associated_titles"), db.prepare("SELECT * FROM ia_memoria").all().then((r) => r.results),
  ]);
  const cats = new Map(categorias.map((c) => [c.pk, c]));
  const memoria = new Map(mem.map((m) => [m.chave, m]));
  // associated_titles → padrão do app ("contém" vira *título*; vazio ou com * não vale), como em contextoLocal.dart.
  const regras = ordenarRegras(titulos.filter((a) => a.title?.trim() && !a.title.includes("*") && a.category_fk)
    .map((a) => ({ id: a.pk, padrao: a.is_exact_match ? a.title : `*${a.title}*`, categoria_id: a.category_fk, prioridade: null })));

  const ts = agoraTs();
  const linhas = [];
  const registrar = (t, origem, chave, sugestao, confianca, status) =>
    linhas.push(db.prepare("INSERT OR IGNORE INTO ia_aplicacoes (tx_id, origem, chave, sugestao, confianca, status, criado_em, atualizado_em) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)")
      .bind(t.id, origem, chave || null, sugestao ? JSON.stringify(sugestao) : null, confianca, status, ts));
  const aplicar = async () => {
    const tarefas = [];
    await aplicarPendentesIa(env, { waitUntil: (p) => tarefas.push(p) }, cfg);
    await Promise.allSettled(tarefas);
  };
  const paraLlama = [];
  for (const t of novas) {
    const valor = t.tipo_conta === "CREDIT" ? -t.amount : t.amount; // negativo = saída (como o app manda ao /api/ia/sugerir)
    const chave = chavePadrao(t.description);
    const regra = regras.find((r) => padraoCasa(r.padrao, t.description ?? ""));
    const deRegra = regra && resolver(cats, regra.categoria_id, null, valor);
    if (deRegra) { registrar(t, "regra", chave, { name: null, ...deRegra }, 1, "pendente"); continue; }
    const m = chave ? memoria.get(chave) : null;
    const daMemoria = m && m.confirmacoes >= MIN_CONFIRMACOES && resolver(cats, m.category_fk, m.sub_category_fk, valor);
    if (daMemoria) { registrar(t, "memoria", chave, { name: m.nome || null, ...daMemoria }, 1, "pendente"); continue; }
    paraLlama.push({ t, chave, valor });
  }

  if (linhas.length) await db.batch(linhas.splice(0)); // esvazia: a parte do Llama reaproveita `registrar`
  await aplicar();
  if (!env.AI || !paraLlama.length) return;
  const llama = async () => {
    const contexto = contextoLlama(cats, memoria, new Set(paraLlama.map((p) => p.chave)));
    const lotes = [];
    for (let i = 0; i < Math.min(paraLlama.length, MAX_LANCAMENTOS * MAX_LOTES_LLAMA); i += MAX_LANCAMENTOS) lotes.push(paraLlama.slice(i, i + MAX_LANCAMENTOS));
    const respostas = await Promise.all(lotes.map((lote) => sugerir(env, { contexto, lancamentos: lote.map(({ t, valor }) => ({ id: t.id, descricao: t.description, valor, data: t.date, conta: t.conta })) })));
    lotes.forEach((lote, i) => {
      const r = respostas[i];
      if (!r.ia) return; // Workers AI fora do ar ou sem cota: nada registrado, tenta na próxima sincronização
      const porId = new Map(r.sugestoes.map((s) => [s.id, s]));
      for (const { t, chave } of lote) {
        const s = porId.get(t.id);
        const sugestao = s ? { name: s.titulo, category_fk: s.categoria, sub_category_fk: s.subcategoria } : null;
        const aplica = s && cfg.limiar != null && s.confianca >= cfg.limiar;
        registrar(t, "llama", chave, sugestao, s?.confianca ?? null, aplica ? "pendente" : "sombra");
      }
    });
    if (linhas.length) await db.batch(linhas);
    if (cfg.limiar != null) await aplicar();
  };
  if (cfg.limiar != null || !ctx) await llama();
  else ctx.waitUntil(llama().catch((e) => console.error("IA: Llama falhou", e?.stack || e)));
}

// ---------- Aplicação (mesmo mecanismo das anotações vinculadas do MCP) ----------

const campos = (d) => ({ name: d?.name ?? null, category_fk: d?.category_fk ?? null, sub_category_fk: d?.sub_category_fk ?? null });

// Decisão `pendente` cuja linha `mb:` já está no espelho vira patch na hora; sem a linha, espera o app enviá-la (gancho do
// POST /api/espelho). Linha editada pelo usuário: a decisão é descartada, nada é gravado.
export async function aplicarPendentesIa(env, ctx, cfg = null) {
  const db = env.DB;
  const { results } = await db.prepare(
    "SELECT i.tx_id, i.sugestao, e.dados FROM ia_aplicacoes i JOIN espelho e ON e.tabela = 'transactions' AND e.pk = 'mb:' || i.tx_id AND e.deleted_at IS NULL AND e.dados IS NOT NULL WHERE i.status = 'pendente'"
  ).all();
  if (!results.length || !(cfg ?? (await configIa(env))).auto) return;
  const ts = agoraTs();
  const dtm = agoraS();
  const descartar = [];
  const aplicar = [];
  for (const r of results) {
    const d = JSON.parse(r.dados);
    if (editadaNoApp(d)) { descartar.push(r.tx_id); continue; }
    const s = JSON.parse(r.sugestao);
    const patch = { category_fk: s.category_fk, sub_category_fk: s.sub_category_fk ?? null, date_time_modified: dtm, ...(s.name ? { name: s.name } : {}) };
    aplicar.push({ tx_id: r.tx_id, patch, anterior: { ...campos(d), date_time_modified: d.date_time_modified ?? null }, depois: { ...campos({ ...d, ...patch }), date_time_modified: dtm } });
  }
  if (descartar.length) await db.batch(descartar.map((id) => db.prepare("UPDATE ia_aplicacoes SET status = 'descartada', atualizado_em = ?1 WHERE tx_id = ?2 AND status = 'pendente'").bind(ts, id)));
  if (!aplicar.length) return;
  // Reserva antes de gravar: uma execução concorrente (cron + POST /api/espelho) que lesse a linha já gravada pela IA a tomaria por
  // edição do usuário e descartaria a decisão. Só grava o que esta execução reservou.
  const reservas = await db.batch(aplicar.map((a) => db.prepare("UPDATE ia_aplicacoes SET status = 'aplicada', anterior = ?1, depois = ?2, aplicado_em = ?3, atualizado_em = ?3 WHERE tx_id = ?4 AND status = 'pendente' RETURNING tx_id")
    .bind(JSON.stringify(a.anterior), JSON.stringify(a.depois), ts, a.tx_id)));
  const minhas = aplicar.filter((_, i) => reservas[i].results.length);
  if (!minhas.length) return;
  try {
    await gravar({ env, ctx }, minhas.map((a) => ({ tabela: "transactions", pk: "mb:" + a.tx_id, dados: a.patch })), APARELHO);
  } catch (e) {
    console.error("IA: aplicação recusada pelo espelho", e?.stack || e); // voltam a pendentes: a próxima linha `mb:` ou sincronização tenta de novo
    await db.batch(minhas.map((a) => db.prepare("UPDATE ia_aplicacoes SET status = 'pendente', anterior = NULL, depois = NULL, aplicado_em = NULL, atualizado_em = ?1 WHERE tx_id = ?2 AND status = 'aplicada' AND aplicado_em = ?3")
      .bind(agoraTs(), a.tx_id, ts)));
  }
}

// ---------- Aprendizado (POST /api/espelho) ----------

const SQL_MB = "SELECT e.pk, e.dados, e.deleted_at, t.description FROM espelho e JOIN json_each(?1) j ON j.value = e.pk LEFT JOIN transactions t ON t.id = substr(e.pk, 4) WHERE e.tabela = 'transactions'";

// Estado das linhas `mb:` antes de o app gravar: o aprendizado compara com o depois.
export async function estadoMb(db, pks) {
  const { results } = await db.prepare(SQL_MB).bind(JSON.stringify(pks)).all();
  const estado = new Map(pks.map((pk) => [pk, null])); // ausente ou apagada = null
  for (const r of results) if (r.deleted_at == null) estado.set(r.pk, json(r.dados));
  return estado;
}

const igual = (a, b) => a?.category_fk === b?.category_fk && (a?.sub_category_fk ?? null) === (b?.sub_category_fk ?? null) && a?.name === b?.name;

// Edição do usuário numa `mb:` (date_time_modified novo e >= 2001, com categoria, subcategoria ou nome mudados, ou a primeira
// edição = confirmação na fila): mesma escolha da memória soma 1; escolha diferente (inclusive corrigir a IA) troca e volta a 1.
// O valor que a própria IA aplicou e volta do app não conta. Sugestão em sombra ganha acerto/erro (pela categoria).
export async function aprenderIa(env, antes) {
  const db = env.DB;
  const pks = [...antes.keys()];
  if (!pks.length) return;
  const [{ results: atuais }, { results: decisoes }] = await db.batch([
    db.prepare(SQL_MB).bind(JSON.stringify(pks)),
    db.prepare("SELECT * FROM ia_aplicacoes WHERE tx_id IN (SELECT substr(value, 4) FROM json_each(?1))").bind(JSON.stringify(pks)),
  ]);
  const porTx = new Map(decisoes.map((d) => [d.tx_id, d]));
  const ts = agoraTs();
  const comandos = [];
  for (const r of atuais) {
    if (r.deleted_at != null || !r.dados) continue;
    const d = JSON.parse(r.dados);
    const a = antes.get(r.pk);
    if (!editadaNoApp(d) || (a && Number(a.date_time_modified) === Number(d.date_time_modified))) continue;
    if (a && editadaNoApp(a) && igual(a, d)) continue; // só nota, pago etc.
    const dec = porTx.get(r.pk.slice(3));
    const depois = json(dec?.depois);
    if (dec?.status === "aplicada" && igual(depois, d)) continue;
    if (dec?.status === "sombra" && dec.acerto == null && dec.sugestao) {
      comandos.push(db.prepare("UPDATE ia_aplicacoes SET acerto = ?1, atualizado_em = ?2 WHERE tx_id = ?3").bind(JSON.parse(dec.sugestao).category_fk === d.category_fk ? 1 : 0, ts, dec.tx_id));
    }
    const chave = chavePadrao(r.description);
    if (!chave || !d.category_fk) continue;
    comandos.push(db.prepare(
      `INSERT INTO ia_memoria (chave, category_fk, sub_category_fk, nome, confirmacoes, atualizado_em) VALUES (?1, ?2, ?3, ?4, 1, ?5)
       ON CONFLICT(chave) DO UPDATE SET
         confirmacoes = CASE WHEN ia_memoria.category_fk = excluded.category_fk AND ia_memoria.sub_category_fk IS excluded.sub_category_fk THEN ia_memoria.confirmacoes + 1 ELSE 1 END,
         nome = CASE WHEN ia_memoria.category_fk = excluded.category_fk AND ia_memoria.sub_category_fk IS excluded.sub_category_fk THEN COALESCE(excluded.nome, ia_memoria.nome) ELSE excluded.nome END,
         category_fk = excluded.category_fk, sub_category_fk = excluded.sub_category_fk, atualizado_em = excluded.atualizado_em`
    ).bind(chave, d.category_fk, d.sub_category_fk ?? null, nomeDoUsuario(d.name, r.description), ts));
  }
  if (comandos.length) await db.batch(comandos);
}

// ---------- Endpoints ----------

const SITUACOES = "('pendente', 'aplicada', 'desfeita')";

// GET /api/ia/aplicadas?desde=<ISO> (últimos 14 dias sem `desde`). `desde` compara com a última mudança de status.
export async function listarAplicadas(db, desde) {
  const piso = desde ?? new Date(Date.now() - DIAS_LISTA * 86400000).toISOString();
  const { results } = await db.prepare(
    `SELECT i.*, t.description FROM ia_aplicacoes i LEFT JOIN transactions t ON t.id = i.tx_id
     WHERE i.status IN ${SITUACOES} AND i.atualizado_em >= ?1 AND (i.status != 'pendente' OR t.id IS NOT NULL)
     ORDER BY COALESCE(i.aplicado_em, i.criado_em) DESC LIMIT 500`
  ).bind(piso).all();
  return {
    itens: results.map((i) => {
      const s = json(i.sugestao);
      const depois = i.depois ? campos(json(i.depois)) : { name: s?.name || i.description || null, category_fk: s?.category_fk ?? null, sub_category_fk: s?.sub_category_fk ?? null };
      return { tx_id: i.tx_id, origem: i.origem, status: i.status, antes: i.anterior ? campos(json(i.anterior)) : null, depois, criado_em: i.criado_em, aplicado_em: i.aplicado_em ?? null };
    }),
  };
}

// POST /api/ia/desfazer {tx_id}: restaura nome, categoria e date_time_modified de antes (a transação volta à fila) e zera a memória
// que aplicou (deixa de aplicar sozinha). Pendente: nada foi gravado, só cancela (e zera a memória do mesmo jeito). Regra do
// usuário fica como está (a decisão desfeita não volta). Linha apagada ou editada pelo usuário depois da IA não é tocada.
export async function desfazerIa(env, ctx, corpo) {
  const txId = typeof corpo?.tx_id === "string" ? corpo.tx_id : null;
  const db = env.DB;
  const dec = txId && (await db.prepare(`SELECT * FROM ia_aplicacoes WHERE tx_id = ?1 AND status IN ${SITUACOES}`).bind(txId).first());
  if (!dec) return { status: 404, corpo: { erro: "Aplicação da IA não encontrada" } };
  if (dec.status === "desfeita") return { status: 409, corpo: { erro: "Já desfeita" } };
  if (dec.status === "aplicada") {
    const atual = await db.prepare("SELECT dados, deleted_at FROM espelho WHERE tabela = 'transactions' AND pk = ?1").bind("mb:" + txId).first();
    if (!atual || atual.deleted_at != null || !atual.dados) return { status: 410, corpo: { erro: "A transação foi apagada: não há o que desfazer." } };
    if (!igual(json(dec.depois), json(atual.dados))) return { status: 412, corpo: { erro: "A transação foi editada depois da IA. Use Corrigir para mudar." } };
    const a = json(dec.anterior);
    try {
      await gravar({ env, ctx }, [{ tabela: "transactions", pk: "mb:" + txId, dados: { ...campos(a), date_time_modified: a.date_time_modified } }], APARELHO);
    } catch (e) {
      return { status: 502, corpo: { erro: String(e?.message || e) } };
    }
  }
  const ts = agoraTs();
  const aplicada = json(dec.depois) ?? json(dec.sugestao);
  // Condicional ao status lido: se a IA aplicou a pendente no meio, o Desfazer não pode marcar desfeita sem restaurar.
  const marcou = await db.prepare("UPDATE ia_aplicacoes SET status = 'desfeita', atualizado_em = ?1 WHERE tx_id = ?2 AND status = ?3 RETURNING tx_id").bind(ts, txId, dec.status).all();
  if (!marcou.results.length) return { status: 412, corpo: { erro: "A IA acabou de mudar esta transação. Atualize a lista e tente de novo." } };
  if (dec.origem !== "regra" && dec.chave && aplicada) {
    await db.prepare("UPDATE ia_memoria SET confirmacoes = 0, atualizado_em = ?1 WHERE chave = ?2 AND category_fk = ?3").bind(ts, dec.chave, aplicada.category_fk).run();
  }
  return { status: 200, corpo: { ok: true } };
}

const textoOuNull = (v, max) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);

// POST /api/ia/memoria {padroes:[{chave, category_fk, sub_category_fk, nome, confirmacoes}]}: importação dos padrões locais do
// aparelho (mbSugestaoLocal). Merge: só troca o que o servidor tem se a importada tiver mais confirmações.
export async function importarMemoria(db, corpo) {
  if (!Array.isArray(corpo?.padroes) || corpo.padroes.length > MAX_PADROES) return { status: 400, corpo: { erro: `padroes deve ser uma lista de até ${MAX_PADROES}` } };
  const ts = agoraTs();
  const validos = corpo.padroes.flatMap((p) => {
    const chave = textoOuNull(p?.chave, 120);
    const cat = textoOuNull(p?.category_fk, 100);
    if (!chave || !cat) return [];
    const n = Number.isInteger(p.confirmacoes) ? Math.min(Math.max(p.confirmacoes, 1), 1000) : 1;
    return [{ chave, category_fk: cat, sub_category_fk: textoOuNull(p.sub_category_fk, 100), nome: textoOuNull(p.nome, MAX_NOME), confirmacoes: n, atualizado_em: ts }];
  });
  if (!validos.length) return { status: 200, corpo: { importados: 0 } };
  const { results } = await db.prepare(
    `INSERT INTO ia_memoria (chave, category_fk, sub_category_fk, nome, confirmacoes, atualizado_em)
     SELECT json_extract(value, '$.chave'), json_extract(value, '$.category_fk'), json_extract(value, '$.sub_category_fk'), json_extract(value, '$.nome'), json_extract(value, '$.confirmacoes'), json_extract(value, '$.atualizado_em')
     FROM json_each(?1) WHERE true
     ON CONFLICT(chave) DO UPDATE SET category_fk = excluded.category_fk, sub_category_fk = excluded.sub_category_fk, nome = excluded.nome, confirmacoes = excluded.confirmacoes, atualizado_em = excluded.atualizado_em
     WHERE excluded.confirmacoes > ia_memoria.confirmacoes RETURNING chave`
  ).bind(JSON.stringify(validos)).all();
  return { status: 200, corpo: { importados: new Set(results.map((r) => r.chave)).size } };
}

// GET /api/ia/relatorio: acerto do modo sombra por faixa de confiança (a última faixa inclui 1). `aguardando` = sugestões que o
// usuário ainda não confirmou nem corrigiu.
export async function relatorioIa(db) {
  const { results } = await db.prepare(
    `SELECT CASE WHEN confianca >= 0.9 AND confianca <= 1 THEN 2 WHEN confianca >= 0.8 THEN 1 WHEN confianca >= 0.7 THEN 0 END AS faixa,
            COUNT(*) AS total, SUM(acerto = 1) AS acertos, SUM(acerto IS NULL) AS aguardando
     FROM ia_aplicacoes WHERE status = 'sombra' AND sugestao IS NOT NULL AND confianca IS NOT NULL GROUP BY faixa`
  ).all();
  const porFaixa = new Map(results.map((r) => [r.faixa, r]));
  const faixas = FAIXAS.map(([de, ate], i) => {
    const r = porFaixa.get(i);
    const total = (r?.total ?? 0) - (r?.aguardando ?? 0);
    const acertos = r?.acertos ?? 0;
    return { de, ate, total, acertos, erros: total - acertos, taxa: total ? Math.round((acertos / total) * 1000) / 1000 : null };
  });
  return { faixas, aguardando: results.reduce((n, r) => n + r.aguardando, 0) };
}

// ---------- Push em lote ----------

// Aplicações ainda não avisadas (a desfeita antes do aviso não conta, mas sai da fila do aviso).
export async function naoAvisadasIa(db) {
  const { results } = await db.prepare("SELECT tx_id, status, aplicado_em FROM ia_aplicacoes WHERE aplicado_em IS NOT NULL AND avisada_em IS NULL").all();
  return results;
}

export const stmtAvisadasIa = (db, ids, ts) => db.prepare("UPDATE ia_aplicacoes SET avisada_em = ?1 WHERE tx_id IN (SELECT value FROM json_each(?2))").bind(ts, JSON.stringify(ids));
