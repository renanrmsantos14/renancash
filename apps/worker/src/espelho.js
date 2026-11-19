// Espelho completo do app: a linha inteira de cada tabela em JSON, com LWW por linha (plano: docs/espelho-completo-plano.md).
// Desligado por padrão: tudo aqui só roda com a variável ESPELHO = "1".
import { validarLinhasEspelho } from "@meu-banco/core";

export const espelhoLigado = (env) => ["1", "true"].includes(String(env.ESPELHO));

export const MAX_PAGINA = 2000;
const MAX_BYTES_COMANDO = 1_000_000; // o D1 aceita ~2 MB por valor ligado; 500 linhas de 16 KB passariam disso
const CURSOR = /^([^|]+)\|([^|]+)\|([\s\S]+)$/; // server_at|tabela|pk (a pk pode ter "|"; a tabela e a data, não)

const LINHAS = "SELECT json_extract(value, '$.tabela'), json_extract(value, '$.pk'), json_extract(value, '$.dados'), json_extract(value, '$.updated_at'), json_extract(value, '$.deleted_at'), ?2, ?3 FROM json_each(?1)";
const COLUNAS = "INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) ";

// Colunas novas de um aparelho com schema mais novo sobrevivem a um envio de schema antigo: o envio vencedor
// sobrepõe as chaves que traz (inclusive null explícito) e mantém as demais. json_patch não serve: apaga a chave com null.
const MESCLAR =
  "json((SELECT '{' || group_concat(json_quote(key) || ':' || CASE type WHEN 'object' THEN value WHEN 'array' THEN value WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' WHEN 'null' THEN 'null' ELSE json_quote(value) END) || '}' " +
  "FROM (SELECT key, type, value FROM json_each(espelho.dados) WHERE key NOT IN (SELECT key FROM json_each(excluded.dados)) UNION ALL SELECT key, type, value FROM json_each(excluded.dados))))";

// LWW no SQL; `WHERE true` desfaz a ambiguidade do parser entre ON CONFLICT e a junção do SELECT (como em sync.js).
// RETURNING só devolve o que foi gravado: o resto perdeu para uma versão mais nova (ou igual).
const SQL_ENVIAR =
  `INSERT ${COLUNAS}${LINHAS} WHERE true ` +
  `ON CONFLICT(tabela, pk) DO UPDATE SET dados = CASE WHEN excluded.dados IS NULL THEN NULL WHEN espelho.dados IS NULL THEN excluded.dados ELSE ${MESCLAR} END, ` +
  "updated_at = excluded.updated_at, deleted_at = excluded.deleted_at, server_at = excluded.server_at, aparelho = excluded.aparelho " +
  "WHERE excluded.updated_at > espelho.updated_at OR (excluded.updated_at = espelho.updated_at AND excluded.aparelho > COALESCE(espelho.aparelho, '')) " +
  "RETURNING tabela, pk";
const SQL_SEMEAR = `INSERT OR REPLACE ${COLUNAS}${LINHAS}`;

const chaveLinha = (l) => JSON.stringify([l.tabela, l.pk]);

function emLotes(linhas) {
  const lotes = [];
  let atual = [];
  let bytes = 0;
  for (const l of linhas) {
    const b = JSON.stringify(l).length;
    if (atual.length && bytes + b > MAX_BYTES_COMANDO) { lotes.push(atual); atual = []; bytes = 0; }
    atual.push(l);
    bytes += b;
  }
  if (atual.length) lotes.push(atual);
  return lotes;
}

const metaDo = async (db) => Object.fromEntries((await db.prepare("SELECT chave, valor FROM espelho_meta").all()).results.map((m) => [m.chave, m.valor]));
const defMeta = (db, chave, valor) => db.prepare("INSERT INTO espelho_meta (chave, valor) VALUES (?1, ?2) ON CONFLICT(chave) DO UPDATE SET valor = excluded.valor").bind(chave, valor);

export const hubDo = (env) => env.ESPELHO_HUB.get(env.ESPELHO_HUB.idFromName("principal"));

export const avisar = (env, aviso) => hubDo(env).fetch("https://hub/avisar", { method: "POST", body: JSON.stringify(aviso) });

const semeado = async (db) => (await metaDo(db)).semeado === "1";

const cursorAtual = (db) =>
  db.prepare("SELECT server_at || '|' || tabela || '|' || pk AS c FROM espelho ORDER BY server_at DESC, tabela DESC, pk DESC LIMIT 1").first("c");

const textoAparelho = (v) => (typeof v === "string" && v.length > 0 && v.length <= 80 ? v : null);

export async function enviarEspelho(db, corpo, agoraIso) {
  const aparelho = textoAparelho(corpo?.aparelho);
  if (!aparelho) return { status: 400, corpo: { erro: "aparelho inválido" } };
  const lote = validarLinhasEspelho(corpo.linhas, agoraIso);
  if ("erro" in lote) return { status: 400, corpo: { erro: lote.erro } };
  if (!(await semeado(db))) return { status: 409, corpo: { erro: "nao_semeado" } };
  const gravadas = new Set();
  if (lote.linhas.length) {
    const resultados = await db.batch(emLotes(lote.linhas).map((l) => db.prepare(SQL_ENVIAR).bind(JSON.stringify(l), agoraIso, aparelho)));
    for (const r of resultados) for (const x of r.results) gravadas.add(chaveLinha(x));
  }
  const perdeu = lote.linhas.filter((l) => !gravadas.has(chaveLinha(l))).map((l) => ({ tabela: l.tabela, pk: l.pk, motivo: "mais_antiga" }));
  return { status: 200, corpo: { aceitos: gravadas.size, rejeitados: [...lote.rejeitados, ...perdeu], cursor: await cursorAtual(db) }, aceitos: gravadas.size, aparelho };
}

export async function puxarEspelho(db, desde, limite) {
  const n = limite == null ? MAX_PAGINA : Number(limite);
  if (!Number.isInteger(n) || n < 1 || n > MAX_PAGINA) return { status: 400, corpo: { erro: `limite deve ser de 1 a ${MAX_PAGINA}` } };
  const c = desde ? CURSOR.exec(desde) : null;
  if (desde && !c) return { status: 400, corpo: { erro: "desde inválido (use server_at|tabela|pk)" } };
  if (!(await semeado(db))) return { status: 200, corpo: { linhas: [], cursor: desde || null, mais: false, semeado: false } };
  const { results } = await db
    .prepare("SELECT tabela, pk, dados, updated_at, deleted_at, server_at, aparelho FROM espelho WHERE ?1 IS NULL OR (server_at, tabela, pk) > (?1, ?2, ?3) ORDER BY server_at, tabela, pk LIMIT ?4")
    .bind(c?.[1] ?? null, c?.[2] ?? null, c?.[3] ?? null, n + 1)
    .all();
  const mais = results.length > n;
  const linhas = results.slice(0, n).map((r) => ({ ...r, dados: r.dados == null ? null : JSON.parse(r.dados) }));
  const ultima = linhas.at(-1);
  return { status: 200, corpo: { linhas, cursor: ultima ? `${ultima.server_at}|${ultima.tabela}|${ultima.pk}` : desde || null, mais, semeado: true } };
}

// Semeio em lotes, só pelo celular. O lote 0 limpa o espelho e abre o semeio ("semeando"); o `fim` grava "semeado".
// Falhou no meio: recomeçar pelo lote 0 (o semeado só existe depois do fim).
export async function semear(db, corpo, agoraIso) {
  const aparelho = textoAparelho(corpo?.aparelho);
  if (!aparelho || !Number.isInteger(corpo.lote) || corpo.lote < 0) return { status: 400, corpo: { erro: "aparelho e lote inválidos" } };
  const lote = validarLinhasEspelho(corpo.linhas, agoraIso);
  if ("erro" in lote) return { status: 400, corpo: { erro: lote.erro } };
  const meta = await metaDo(db);
  const primeiro = corpo.lote === 0;
  if (primeiro && meta.semeado === "1" && corpo.substituir !== true) return { status: 409, corpo: { erro: "ja_semeado" } };
  if (!primeiro && meta.semeando !== aparelho) return { status: 409, corpo: { erro: "semeio_nao_iniciado" } };
  const comandos = [];
  if (primeiro) comandos.push(db.prepare("DELETE FROM espelho"), db.prepare("DELETE FROM espelho_meta WHERE chave = 'semeado'"), defMeta(db, "semeando", aparelho));
  for (const l of emLotes(lote.linhas)) comandos.push(db.prepare(SQL_SEMEAR).bind(JSON.stringify(l), agoraIso, aparelho));
  const fim = corpo.fim === true;
  if (fim) comandos.push(defMeta(db, "semeado", "1"), defMeta(db, "semeado_por", aparelho), defMeta(db, "semeado_em", agoraIso), db.prepare("DELETE FROM espelho_meta WHERE chave = 'semeando'"));
  await db.batch(comandos);
  return { status: 200, corpo: { aceitos: lote.linhas.length, rejeitados: lote.rejeitados, lote: corpo.lote, fim, cursor: await cursorAtual(db) }, fim, aparelho };
}

// ---------- Leitura pelo servidor (ciclo, alertas, revisões: usada na F4) ----------

const ID = (pk) => "cashew:" + pk; // mesmo prefixo do app (idDoPk): é o formato dos ids na tabela `registros`
const comoLista = (texto) => { try { const l = JSON.parse(texto); return Array.isArray(l) ? l.map(String) : []; } catch { return []; } };
const dia = (v) => {
  if (v == null) return null;
  const ms = typeof v === "number" ? (v < 1e11 ? v * 1000 : v) : Date.parse(v); // o Drift grava DateTime em segundos
  return Number.isNaN(ms) ? null : new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" }).format(new Date(ms));
};

export function configDe(linhas) {
  const c = Object.fromEntries(linhas.map((l) => [l.chave, l.valor]));
  return { limite: c.limite ? Number(c.limite) : null, salario: c.salario || null, salarioValor: Number(c.salario_valor) || null };
}

// Projeta o espelho no formato que `baseCiclo` lê hoje da tabela `registros` ({tabela, id, dados}) e na tabela `config`.
// Só leitura. Ajustes vêm das linhas `mb:` de transactions: a categoria atual vira `categoria_id` (o espelho não guarda a "aplicada
// pelo banco", então a categoria do próprio mapeador também vira ajuste: o efeito no ciclo é o mesmo); excluída vira {gasto: 0}.
export async function registrosDoEspelho(db) {
  const { results } = await db
    .prepare(
      "SELECT tabela, pk, dados, deleted_at FROM espelho WHERE tabela IN ('categories', 'associated_titles', 'budgets', 'objectives', 'mb_orcamento_tx', 'mb_meta_aplicacao', 'mb_revisoes', '_config') " +
        "OR (tabela = 'transactions' AND (pk LIKE 'mb:%' OR (deleted_at IS NULL AND json_extract(dados, '$.type') = 1)))"
    )
    .all();
  const vivas = results.filter((r) => r.deleted_at == null && r.dados != null).map((r) => ({ ...r, d: JSON.parse(r.dados) }));
  const daTabela = (t) => vivas.filter((r) => r.tabela === t);
  const registros = [];
  const novo = (tabela, id, dados) => registros.push({ tabela, id, dados, deleted_at: null });

  const categorias = new Map();
  for (const { pk, d } of daTabela("categories")) {
    categorias.set(pk, d.name);
    novo("categorias", ID(pk), { nome: d.name, tipo: d.income ? "receita" : "despesa", cor: d.colour ?? null, icone: d.icon_name ?? null, pai_id: d.main_category_pk ? ID(d.main_category_pk) : null, ordem: d.order });
  }
  for (const { pk, d } of daTabela("associated_titles")) {
    if (!d.title?.trim() || d.title.includes("*")) continue; // não projetável como padrão (mesma regra do app)
    novo("regras", ID(pk), { padrao: d.is_exact_match ? d.title : `*${d.title}*`, categoria_id: ID(d.category_fk) });
  }
  for (const { pk, d } of daTabela("budgets")) {
    novo("orcamentos", ID(pk), {
      nome: d.name, valor: d.amount, categoria_ids: comoLista(d.category_fks).map(ID).sort(), periodo: "ciclo",
      ...(d.archived ? { arquivado: 1 } : {}), ...(d.is_absolute_spending_limit ? { limite_absoluto: 1 } : {}),
    });
  }
  const aplicacoes = Map.groupBy(daTabela("mb_meta_aplicacao"), (r) => r.d.meta_pk);
  for (const { pk, d } of daTabela("objectives")) {
    if (d.type !== 0) continue; // empréstimos (type 1) não entram no ciclo
    novo("metas", ID(pk), { nome: d.name, valor_alvo: d.amount, prazo: dia(d.end_date), aplicacao_ids: (aplicacoes.get(pk) ?? []).map((a) => a.d.aplicacao_pk).sort() });
  }
  for (const { pk, d } of daTabela("transactions")) {
    if (d.type === 1 && !pk.startsWith("mb:")) novo("assinaturas", ID(pk), { nome: d.name?.trim() || "Sem nome", valor: Math.abs(d.amount), dia: Number(dia(d.date_created)?.slice(8)), categoria_id: ID(d.category_fk) });
  }
  for (const { pk, d } of daTabela("mb_revisoes")) novo("revisoes", pk, d);

  const escolhas = Map.groupBy(daTabela("mb_orcamento_tx"), (r) => r.d.tx_pk);
  for (const r of results.filter((x) => x.tabela === "transactions" && x.pk.startsWith("mb:"))) {
    const id = r.pk.slice(3);
    if (r.deleted_at != null) { novo("ajustes", id, { gasto: 0 }); continue; }
    const d = JSON.parse(r.dados);
    const ids = (escolhas.get(r.pk) ?? []).map((e) => e.d.orcamento_pk).filter(Boolean).map(ID).sort();
    const ajuste = {
      ...(categorias.has(d.category_fk) ? { categoria_id: ID(d.category_fk), category: categorias.get(d.category_fk) } : {}),
      ...(escolhas.has(r.pk) ? { orcamento_ids: ids } : {}),
    };
    if (Object.keys(ajuste).length) novo("ajustes", id, ajuste);
  }

  // `_config` vence; a tabela `config` (ciclo gravado pelo painel antigo) cobre o que o app ainda não sincronizou.
  const antiga = (await db.prepare("SELECT chave, valor FROM config").all()).results;
  const config = configDe([...antiga, ...daTabela("_config").map((r) => ({ chave: r.pk, valor: r.d.v == null ? null : String(r.d.v) }))]);
  return { registros, config };
}
