// Espelho completo do app: a linha inteira de cada tabela em JSON, com LWW por linha (plano: docs/espelho-completo-plano.md).
// Desligado por padrão: tudo aqui só roda com a variável ESPELHO = "1".
import { validarLinhasEspelho } from "@meu-banco/core";

export const espelhoLigado = (env) => ["1", "true"].includes(String(env.ESPELHO));

export const MAX_PAGINA = 2000;
const MAX_BYTES_COMANDO = 1_000_000; // o D1 aceita ~2 MB por valor ligado; 500 linhas de 16 KB passariam disso
const CURSOR = /^([^|]+)\|([^|]+)\|([\s\S]+)$/; // server_at|tabela|pk (a pk pode ter "|"; a tabela e a data, não)

const LINHAS = "SELECT json_extract(value, '$.tabela'), json_extract(value, '$.pk'), json_extract(value, '$.dados'), json_extract(value, '$.updated_at'), json_extract(value, '$.deleted_at'), ?2, ?3 FROM json_each(?1)";
const COLUNAS = "INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) ";

// Mesmo `dados` que o cliente mandou, como texto: json_extract de um objeto reserializa e arredonda números reais.
// LWW no SQL (guarda contra corrida entre a leitura e a gravação); `WHERE true` desfaz a ambiguidade do parser entre
// ON CONFLICT e a junção do SELECT (como em sync.js). RETURNING só devolve o que foi gravado.
const SQL_ENVIAR =
  `INSERT ${COLUNAS}${LINHAS} WHERE true ` +
  "ON CONFLICT(tabela, pk) DO UPDATE SET dados = excluded.dados, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at, server_at = excluded.server_at, aparelho = excluded.aparelho " +
  "WHERE excluded.updated_at > espelho.updated_at OR (excluded.updated_at = espelho.updated_at AND excluded.aparelho > COALESCE(espelho.aparelho, '')) " +
  "RETURNING tabela, pk";
const SQL_SEMEAR = `INSERT OR REPLACE ${COLUNAS}${LINHAS}`;
const SQL_ATUAIS =
  "SELECT e.tabela, e.pk, e.dados, e.updated_at, e.deleted_at, e.aparelho FROM espelho e JOIN json_each(?1) j ON e.tabela = json_extract(j.value, '$.tabela') AND e.pk = json_extract(j.value, '$.pk')";

const chaveLinha = (l) => JSON.stringify([l.tabela, l.pk]);
const agoraBd = () => new Date().toISOString();
const comDadosTexto = (l) => ({ ...l, dados: l.dados == null ? null : JSON.stringify(l.dados) });
const baixa = (v) => ({ dados: v.dados == null ? null : JSON.parse(v.dados), updated_at: v.updated_at, deleted_at: v.deleted_at, aparelho: v.aparelho ?? "" });
const maisNova = (l, atual, aparelho) => l.updated_at > atual.updated_at || (l.updated_at === atual.updated_at && aparelho > atual.aparelho);

async function atuais(db, linhas) {
  const { results } = await db.prepare(SQL_ATUAIS).bind(JSON.stringify(linhas.map((l) => ({ tabela: l.tabela, pk: l.pk })))).all();
  return new Map(results.map((r) => [chaveLinha(r), baixa(r)]));
}

function emLotes(linhas) {
  const lotes = [];
  let atual = [];
  let bytes = 0;
  for (const l of linhas) {
    const b = new TextEncoder().encode(JSON.stringify(l)).length; // o limite do D1 é em bytes, não em caracteres
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
// ESPELHO ligado E semeado: antes do semeio (ou durante um `substituir`) o espelho está vazio ou incompleto e o Worker segue em `registros`.
export const espelhoPronto = async (env) => espelhoLigado(env) && (await semeado(env.DB));

// Junção das transações com os ajustes. Com o espelho pronto junta direto em `espelho` (por pk e pela categoria), sem passar pela view
// v_ajustes_espelho: o SQLite do CI materializa a view e vira laço aninhado O(tx x espelho). `ajuste` = colunas ajuste_categoria,
// ajuste_gasto e o `updated_at` do ajuste (maior entre transação e categoria: renomear a categoria muda a linha do pull incremental).
export const deTx = (pronto) =>
  pronto
    ? "FROM transactions t LEFT JOIN espelho a ON a.tabela = 'transactions' AND a.pk = 'mb:' || t.id LEFT JOIN espelho c ON c.tabela = 'categories' AND c.pk = json_extract(a.dados, '$.category_fk')"
    : "FROM transactions t LEFT JOIN v_ajustes a ON a.transaction_id = t.id";
export const ajuste = (pronto) =>
  pronto
    ? { categoria: "CASE WHEN a.deleted_at IS NULL AND c.deleted_at IS NULL THEN json_extract(c.dados, '$.name') END", gasto: "CASE WHEN a.deleted_at IS NOT NULL THEN 0 END", atualizado: "CASE WHEN c.server_at > a.server_at THEN c.server_at ELSE a.server_at END" }
    : { categoria: "a.category", gasto: "a.gasto", atualizado: "a.updated_at" };

const cursorAtual = (db) =>
  db.prepare("SELECT server_at || '|' || tabela || '|' || pk AS c FROM espelho ORDER BY server_at DESC, tabela DESC, pk DESC LIMIT 1").first("c");

// `aparelho` vem da autenticação (id do token; sessão do painel = "web"), nunca do corpo: o desempate do LWW não pode ser forjado.
// Gravação: o merge de colunas é feito aqui (leitura + gravação, não atômicas) para preservar o texto JSON de cada valor; a corrida
// só pode perder uma coluna que dois aparelhos com schemas diferentes mandem ao mesmo tempo (o LWW em si é garantido pelo SQL).
export async function enviarEspelho(db, corpo, agoraIso, aparelho) {
  const lote = validarLinhasEspelho(corpo?.linhas, agoraIso);
  if ("erro" in lote) return { status: 400, corpo: { erro: lote.erro } };
  if (!(await semeado(db))) return { status: 409, corpo: { erro: "nao_semeado" } };
  const mapa = lote.linhas.length ? await atuais(db, lote.linhas) : new Map();
  const escrever = new Map();
  const perdeu = [];
  let repetidas = 0; // reenvio idêntico (mesmo updated_at e aparelho) é aceito sem regravar: o cliente pode repetir sem medo
  for (const l of lote.linhas) {
    const k = chaveLinha(l);
    const atual = mapa.get(k);
    if (atual && atual.updated_at === l.updated_at && atual.aparelho === aparelho) { repetidas++; continue; }
    if (atual && !maisNova(l, atual, aparelho)) { perdeu.push(l); continue; }
    const dados = l.dados && atual?.dados ? { ...atual.dados, ...l.dados } : l.dados;
    const nova = { dados, updated_at: l.updated_at, deleted_at: l.deleted_at, aparelho };
    mapa.set(k, nova);
    escrever.set(k, { tabela: l.tabela, pk: l.pk, ...nova });
  }
  const gravadas = new Set();
  if (escrever.size) {
    // server_at tirado aqui, colado no batch: ordena a página do cursor; um relógio tirado antes da leitura deixaria a linha atrás de um cursor já entregue.
    const serverAt = agoraBd();
    const resultados = await db.batch(emLotes([...escrever.values()].map(comDadosTexto)).map((l) => db.prepare(SQL_ENVIAR).bind(JSON.stringify(l), serverAt, aparelho)));
    for (const r of resultados) for (const x of r.results) gravadas.add(chaveLinha(x));
  }
  for (const [k, l] of escrever) if (!gravadas.has(k)) perdeu.push(l); // perdeu a corrida para uma gravação mais nova
  const vencedoras = perdeu.length ? await atuais(db, perdeu) : new Map();
  const rejeitados = [...lote.rejeitados, ...perdeu.map((l) => ({ tabela: l.tabela, pk: l.pk, motivo: "mais_antiga", atual: vencedoras.get(chaveLinha(l)) }))];
  return {
    status: 200,
    corpo: { aceitos: repetidas + gravadas.size, rejeitados, aparelho },
    gravadas: gravadas.size,
    aparelho,
    cursor: gravadas.size ? await cursorAtual(db) : null,
  };
}

export async function puxarEspelho(db, desde, limite, aparelho) {
  const n = limite == null ? MAX_PAGINA : Number(limite);
  if (!Number.isInteger(n) || n < 1 || n > MAX_PAGINA) return { status: 400, corpo: { erro: `limite deve ser de 1 a ${MAX_PAGINA}` } };
  const c = desde ? CURSOR.exec(desde) : null;
  if (desde && !c) return { status: 400, corpo: { erro: "desde inválido (use server_at|tabela|pk)" } };
  if (!(await semeado(db))) return { status: 200, corpo: { linhas: [], cursor: desde || null, mais: false, semeado: false, aparelho } };
  const { results } = await db
    .prepare("SELECT tabela, pk, dados, updated_at, deleted_at, server_at, aparelho FROM espelho WHERE ?1 IS NULL OR (server_at, tabela, pk) > (?1, ?2, ?3) ORDER BY server_at, tabela, pk LIMIT ?4")
    .bind(c?.[1] ?? null, c?.[2] ?? null, c?.[3] ?? null, n + 1)
    .all();
  const mais = results.length > n;
  const linhas = results.slice(0, n).map((r) => ({ ...r, dados: r.dados == null ? null : JSON.parse(r.dados) }));
  const ultima = linhas.at(-1);
  return { status: 200, corpo: { linhas, cursor: ultima ? `${ultima.server_at}|${ultima.tabela}|${ultima.pk}` : desde || null, mais, semeado: true, aparelho } };
}

// Semeio em lotes, só pelo celular (aparelho = id do token). O lote 0 abre o semeio ("semeando") sem apagar nada; o `fim` grava
// "semeado" e marca como apagadas (tombstone, com server_at novo) as linhas vivas que o novo semeio não trouxe, para os outros
// aparelhos saberem. Falhou no meio: recomeçar pelo lote 0 (o semeado só existe depois do fim).
export async function semear(db, corpo, agoraIso, aparelho) {
  if (!Number.isInteger(corpo?.lote) || corpo.lote < 0) return { status: 400, corpo: { erro: "lote inválido" } };
  const lote = validarLinhasEspelho(corpo.linhas, agoraIso);
  if ("erro" in lote) return { status: 400, corpo: { erro: lote.erro } };
  const meta = await metaDo(db);
  const primeiro = corpo.lote === 0;
  if (primeiro && meta.semeado === "1" && corpo.substituir !== true) return { status: 409, corpo: { erro: "ja_semeado" } };
  if (!primeiro && meta.semeando !== aparelho) return { status: 409, corpo: { erro: "semeio_nao_iniciado" } };
  const serverAt = agoraBd(); // colado no batch (ver enviarEspelho)
  const comandos = [];
  if (primeiro) comandos.push(db.prepare("DELETE FROM espelho_meta WHERE chave = 'semeado'"), defMeta(db, "semeando", aparelho), defMeta(db, "semeando_desde", serverAt));
  for (const l of emLotes(lote.linhas.map(comDadosTexto))) comandos.push(db.prepare(SQL_SEMEAR).bind(JSON.stringify(l), serverAt, aparelho));
  const fim = corpo.fim === true;
  if (fim) {
    const desde = primeiro ? serverAt : meta.semeando_desde;
    comandos.push(
      db.prepare("UPDATE espelho SET dados = NULL, deleted_at = ?1, updated_at = ?1, server_at = ?1, aparelho = ?2 WHERE deleted_at IS NULL AND server_at < ?3").bind(serverAt, aparelho, desde),
      defMeta(db, "semeado", "1"), defMeta(db, "semeado_por", aparelho), defMeta(db, "semeado_em", serverAt),
      db.prepare("DELETE FROM espelho_meta WHERE chave IN ('semeando', 'semeando_desde')"),
    );
  }
  await db.batch(comandos);
  return { status: 200, corpo: { aceitos: lote.linhas.length, rejeitados: lote.rejeitados, lote: corpo.lote, fim, cursor: await cursorAtual(db), aparelho }, fim, aparelho };
}

// ---------- Leitura pelo servidor (ciclo, alertas, revisões: usada na F4) ----------

const ID = (pk) => "cashew:" + pk; // mesmo prefixo do app (idDoPk): é o formato dos ids na tabela `registros`
const comoLista = (texto) => { try { const l = JSON.parse(texto); return Array.isArray(l) ? l.map(String) : []; } catch { return []; } };
const msDe = (v) => {
  if (v == null) return null;
  const ms = typeof v === "number" ? (v < 1e11 ? v * 1000 : v) : Date.parse(v); // o Drift grava DateTime em segundos
  return Number.isNaN(ms) ? null : ms;
};
const dia = (v) => { const ms = msDe(v); return ms == null ? null : new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" }).format(new Date(ms)); };

export function configDe(linhas) {
  const c = Object.fromEntries(linhas.map((l) => [l.chave, l.valor]));
  return { limite: c.limite ? Number(c.limite) : null, salario: c.salario || null, salarioValor: Number(c.salario_valor) || null };
}

// Projeta o espelho no formato que `baseCiclo` lê hoje da tabela `registros` ({tabela, id, dados}) e na tabela `config`.
// Só leitura. Ajustes vêm das linhas `mb:` de transactions: a categoria atual vira `categoria_id` (o espelho não guarda a "aplicada
// pelo banco", então a categoria do próprio mapeador também vira ajuste: o efeito no ciclo é o mesmo); excluída vira {gasto: 0}.
// Nome e nota só entram se a linha foi editada (date_time_modified depois de 2000, como `mbEditadoEm` do app); sem edição o texto
// é o do banco. As categorias não têm `pluggy` (o Cashew não tem a coluna e o vínculo foi aposentado na F5): a do Pluggy resolve pelo nome traduzido.
const editada = (v) => { const ms = msDe(v); return ms != null && new Date(ms).getUTCFullYear() >= 2001; };
export async function registrosDoEspelho(db) {
  // Duas leituras independentes num batch só. `_config` vem com as exclusões: o tombstone tem de apagar o valor antigo da tabela `config`.
  const [{ results }, { results: antiga }] = await db.batch([
    db.prepare(
      "SELECT tabela, pk, dados, deleted_at FROM espelho WHERE tabela IN ('categories', 'associated_titles', 'budgets', 'objectives', 'mb_orcamento_tx', 'mb_meta_aplicacao', 'mb_revisoes', '_config') " +
        "OR (tabela = 'transactions' AND (pk LIKE 'mb:%' OR (deleted_at IS NULL AND json_extract(dados, '$.type') = 1)))"
    ),
    db.prepare("SELECT chave, valor FROM config"),
  ]);
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
    if (d.type !== 0) { novo("dividas", ID(pk), { tipo: "emprestimo", nome: d.name, sentido: d.income ? "me_devem" : "devo", valor_total: d.amount }); continue; } // dívida não entra no ciclo
    novo("metas", ID(pk), { nome: d.name, valor_alvo: d.amount, prazo: dia(d.end_date), aplicacao_ids: (aplicacoes.get(pk) ?? []).map((a) => a.d.aplicacao_pk).sort() });
  }
  for (const { pk, d } of daTabela("transactions")) {
    if (d.type === 1 && !pk.startsWith("mb:")) novo("assinaturas", ID(pk), { nome: d.name?.trim() || "Sem nome", valor: Math.abs(d.amount), dia: Number(dia(d.date_created)?.slice(8)), categoria_id: ID(d.category_fk) });
  }
  // A linha do app é {pk, dados} com a decisão em texto JSON; a malformada fica de fora, como em lerRevisoes.
  for (const { pk, d } of daTabela("mb_revisoes")) {
    try { const dec = JSON.parse(d.dados); if (dec && typeof dec === "object") novo("revisoes", pk, dec); } catch {}
  }

  const escolhas = Map.groupBy(daTabela("mb_orcamento_tx"), (r) => r.d.tx_pk);
  const texto = (v) => (typeof v === "string" && v.trim() ? v.trim().slice(0, 200) : null);
  for (const r of results.filter((x) => x.tabela === "transactions" && x.pk.startsWith("mb:"))) {
    const id = r.pk.slice(3);
    if (id.startsWith("inv:")) continue; // investimento do banco: não é transação do ciclo
    if (r.deleted_at != null) { novo("ajustes", id, { gasto: 0 }); continue; }
    const d = JSON.parse(r.dados);
    const edicao = editada(d.date_time_modified);
    const ids = (escolhas.get(r.pk) ?? []).map((e) => e.d.orcamento_pk).filter(Boolean).map(ID).sort();
    const ajuste = {
      ...(categorias.has(d.category_fk) ? { categoria_id: ID(d.category_fk), category: categorias.get(d.category_fk) } : {}),
      ...(escolhas.has(r.pk) ? { orcamento_ids: ids } : {}),
      ...(d.objective_loan_fk ? { divida_id: ID(d.objective_loan_fk) } : {}),
      ...(edicao && texto(d.name) ? { nome: texto(d.name) } : {}),
      ...(edicao && texto(d.note) && d.note !== "Pendente" ? { nota: texto(d.note) } : {}),
    };
    if (Object.keys(ajuste).length) novo("ajustes", id, ajuste);
  }

  // `_config` vence; a tabela `config` (ciclo gravado pelo painel antigo) cobre o que o app ainda não sincronizou.
  const config = configDe([...antiga, ...results.filter((r) => r.tabela === "_config").map((r) => {
    const v = r.deleted_at == null && r.dados != null ? JSON.parse(r.dados).v : null; // tombstone = null, que sobrescreve o valor antigo
    return { chave: r.pk, valor: v == null ? null : String(v) };
  })]);
  return { registros, config };
}
