// Servidor MCP (Streamable HTTP, respostas JSON, sem sessão) para o claude.ai controlar o RenanCash.
// Escrita sempre pelo espelho (mesmo LWW e aviso em tempo real do app), como o aparelho "claude".
// Anotações: o Renan conta um gasto ao Claude antes de o banco lançar; quando a transação chega, o Claude mostra as candidatas
// e, com a confirmação, grava título, categoria e nota na transação `mb:<id>` como uma edição feita no app.
import { TABELAS_ESPELHO } from "@meu-banco/core";
import { gravar as gravarEspelho, editadaNoApp, ErroGravacao, linhasDe } from "./espelho.js";
import { agoraS, diaSP as DIA, hojeSP } from "./app.js";

const APARELHO = "claude";
const VERSOES = ["2025-06-18", "2025-03-26", "2024-11-05"];
const MAX_LINHAS_SQL = 200;
const TABELAS_SECRETAS = /\b(app_tokens|mcp_oauth|mcp_clientes|push_inscricoes)\b/i;
const SQL_PROIBIDO = /\b(insert|update|delete|drop|alter|create|attach|detach|pragma|vacuum|reindex|analyze|replace\s+into)\b/i;
const DIAS_ANTES = 3; // o banco pode datar a compra um pouco antes do que foi dito
const DIAS_DEPOIS = 7;
const TOLERANCIA = 0.02; // 2% (compra no exterior, gorjeta); a exata vem primeiro

const dataDe = (s) => (s == null ? null : DIA.format(new Date(Number(s) * 1000)));
const epochDe = (data) => Math.floor(Date.parse(data + "T00:00:00-03:00") / 1000); // meia-noite em Brasília, como o app grava
const somarDias = (data, n) => new Date(Date.parse(data + "T12:00:00Z") + n * 86400000).toISOString().slice(0, 10);
const DATA = /^\d{4}-\d{2}-\d{2}$/;
const chave = (s) => String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();
const reais = (v) => Math.round(Number(v) * 100) / 100;
const limite = (v, padrao, max) => Math.min(Math.max(Number(v) || padrao, 1), max);

class ErroFerramenta extends ErroGravacao {}
const gravar = (c, linhas) => gravarEspelho(c, linhas, APARELHO);
const falhar = (msg) => { throw new ErroFerramenta(msg); };

// ---------- Leitura do espelho ----------

async function linhaDe(db, tabela, pk) {
  const r = await db.prepare("SELECT dados, deleted_at FROM espelho WHERE tabela = ?1 AND pk = ?2").bind(tabela, pk).first();
  return r && { dados: r.dados == null ? null : JSON.parse(r.dados), deleted_at: r.deleted_at };
}

async function catalogo(db) {
  const [categorias, carteiras] = await Promise.all([linhasDe(db, "categories"), linhasDe(db, "wallets")]);
  return { categorias, carteiras, cat: new Map(categorias.map((c) => [c.pk, c])), cart: new Map(carteiras.map((w) => [w.pk, w])) };
}
const nomeCat = (cat, pk) => (pk ? cat.cat.get(pk)?.name ?? pk : null);
const viva = (l, msg) => (l && !l.deleted_at ? l : falhar(msg));

// Categoria por nome ou pk. Subcategoria sem categoria leva a categoria-mãe junto.
function resolverCategoria(cat, categoria, subcategoria) {
  const achar = (texto, filtro) => {
    const t = chave(texto);
    return cat.categorias.find((c) => !c.archived && filtro(c) && (c.pk === texto || chave(c.name) === t));
  };
  let principal = null;
  let sub;
  if (categoria) {
    principal = achar(categoria, (c) => !c.main_category_pk) || achar(categoria, () => true);
    if (!principal) falhar(`Categoria "${categoria}" não existe. Categorias: ${cat.categorias.filter((c) => !c.main_category_pk && !c.archived).map((c) => c.name).join(", ")}`);
    if (principal.main_category_pk) { sub = principal; principal = cat.cat.get(principal.main_category_pk); }
  }
  if (subcategoria) {
    sub = achar(subcategoria, (c) => c.main_category_pk && (!principal || c.main_category_pk === principal.pk));
    if (!sub) falhar(`Subcategoria "${subcategoria}" não existe${principal ? ` em ${principal.name}` : ""}. Opções: ${cat.categorias.filter((c) => c.main_category_pk && (!principal || c.main_category_pk === principal.pk)).map((c) => c.name).join(", ") || "nenhuma"}`);
    principal ??= cat.cat.get(sub.main_category_pk);
  }
  return { categoria: principal?.pk ?? null, subcategoria: sub ? sub.pk : principal ? null : undefined };
}

function resolverCarteira(cat, nome) {
  const t = chave(nome);
  const w = cat.carteiras.find((c) => c.pk === nome || chave(c.name) === t) || cat.carteiras.find((c) => chave(c.name).includes(t));
  return w || falhar(`Carteira "${nome}" não existe. Carteiras: ${cat.carteiras.map((c) => c.name).join(", ")}`);
}

function transacaoLegivel(pk, d, cat, banco) {
  return {
    pk, data: dataDe(d.date_created), titulo: d.name, valor: d.amount, receita: !!d.income,
    categoria: nomeCat(cat, d.category_fk), subcategoria: nomeCat(cat, d.sub_category_fk),
    carteira: cat.cart.get(d.wallet_fk)?.name ?? d.wallet_fk, nota: d.note || null, pago: d.paid == null ? null : !!d.paid,
    editada_no_app: editadaNoApp(d),
    ...(banco?.description ? { texto_do_banco: banco.description, estabelecimento: banco.merchant || banco.contraparte || null, conta_banco: banco.conta } : {}),
  };
}

// ---------- Anotações ----------

const sinalGasto = "CASE WHEN a.type = 'CREDIT' THEN t.amount > 0 ELSE t.amount < 0 END";

async function candidatas(db, an) {
  const tol = Math.max(0.01, an.valor * TOLERANCIA);
  const { results } = await db.prepare(
    `SELECT t.id, t.date, t.description, t.merchant, t.contraparte, t.amount, t.status, a.name AS conta, e.dados AS app
     FROM transactions t JOIN accounts a ON a.id = t.account_id
     LEFT JOIN espelho e ON e.tabela = 'transactions' AND e.pk = 'mb:' || t.id AND e.deleted_at IS NULL
     WHERE abs(abs(t.amount) - ?1) <= ?2 AND t.date BETWEEN ?3 AND ?4 AND t.scheduled = 0 AND (${sinalGasto}) = ?5
       AND t.id NOT IN (SELECT transacao_id FROM anotacoes WHERE transacao_id IS NOT NULL AND status IN ('vinculada', 'aplicada') AND id != ?6)
     ORDER BY abs(abs(t.amount) - ?1) > 0.005, abs(julianday(t.date) - julianday(?7)), t.date LIMIT 6`
  ).bind(an.valor, tol, somarDias(an.data, -DIAS_ANTES), somarDias(an.data, DIAS_DEPOIS), an.receita ? 0 : 1, an.id, an.data).all();
  return results.map((t) => {
    const app = t.app ? JSON.parse(t.app) : null;
    return {
      transacao_id: t.id, data: t.date, valor: Math.abs(t.amount), valor_exato: Math.abs(Math.abs(t.amount) - an.valor) < 0.005,
      texto_do_banco: t.description, estabelecimento: t.merchant || t.contraparte || null, conta: t.conta, pendente_no_banco: t.status === "PENDING",
      no_app: app ? { titulo: app.name, ja_editada: editadaNoApp(app) } : null,
    };
  });
}

const anotacaoLegivel = (a, cat) => ({
  id: a.id, status: a.status, valor: a.valor, data: a.data, receita: !!a.receita, descricao: a.descricao, titulo: a.titulo,
  categoria: nomeCat(cat, a.categoria), subcategoria: nomeCat(cat, a.subcategoria),
  nota: a.nota, conta: a.conta, transacao_id: a.transacao_id, criada: a.criada,
});

const lerAnotacao = (db, id) => db.prepare("SELECT * FROM anotacoes WHERE id = ?1").bind(id).first();

function patchDaAnotacao(a) {
  const d = { name: a.titulo || a.descricao, date_time_modified: agoraS() };
  if (a.categoria) { d.category_fk = a.categoria; d.sub_category_fk = a.subcategoria ?? null; }
  if (a.nota) d.note = a.nota;
  return d;
}

// Vinculada cuja transação já está no app vira edição da linha `mb:<id>`. Roda quando o app grava `mb:` no espelho,
// ao confirmar e ao listar anotações (rede de segurança se o gancho do espelho falhar).
export async function aplicarVinculadas(env, ctx) {
  const db = env.DB;
  const { results } = await db.prepare(
    "SELECT a.* FROM anotacoes a JOIN espelho e ON e.tabela = 'transactions' AND e.pk = 'mb:' || a.transacao_id AND e.deleted_at IS NULL WHERE a.status = 'vinculada'"
  ).all();
  if (!results.length) return 0;
  await gravar({ env, ctx }, results.map((a) => ({ tabela: "transactions", pk: "mb:" + a.transacao_id, dados: patchDaAnotacao(a) })));
  const ts = new Date().toISOString();
  await db.batch(results.map((a) => db.prepare("UPDATE anotacoes SET status = 'aplicada', atualizada = ?1 WHERE id = ?2 AND status = 'vinculada'").bind(ts, a.id)));
  return results.length;
}

// Alerta (push) quando uma anotação pendente ganha transação compatível: o Renan confirma com o Claude.
export async function alertasAnotacoes(db) {
  const { results } = await db.prepare("SELECT * FROM anotacoes WHERE status = 'pendente' AND data >= ?1").bind(somarDias(hojeSP(), -30)).all();
  const alertas = [];
  for (const a of results) {
    const c = await candidatas(db, a);
    if (c.length) alertas.push({ chave: `anotacao:${a.id}`, titulo: "Gasto anotado chegou do banco", corpo: `${a.descricao} (R$ ${a.valor.toFixed(2).replace(".", ",")}): confirme com o Claude.` });
  }
  return alertas;
}

// ---------- Ferramentas ----------

const s = (type, description, extra = {}) => ({ type, description, ...extra });
const obj = (properties, required = []) => ({ type: "object", properties, required, additionalProperties: false });
const LEITURA = { readOnlyHint: true, destructiveHint: false, openWorldHint: false };
const ESCRITA = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };
const APAGA = { readOnlyHint: false, destructiveHint: true, openWorldHint: false };

const FERRAMENTAS = [
  {
    name: "anotar_gasto",
    title: "Anotar gasto",
    description: "Guarda um gasto (ou recebimento) que o Renan contou antes de o banco lançar. Quando a transação chegar (até ~24 h depois), ela aparece como candidata em listar_anotacoes e só é aplicada com confirmar_anotacao. Já devolve candidatas se o banco já lançou. Data padrão: hoje (America/Sao_Paulo).",
    inputSchema: obj({
      valor: s("number", "Valor em reais, positivo (ex.: 42.9)"),
      descricao: s("string", "O que foi, nas palavras do Renan (ex.: 'almoço com o time no Outback')"),
      data: s("string", "AAAA-MM-DD do gasto; padrão hoje"),
      titulo: s("string", "Título que a transação deve ter no app; padrão = descricao"),
      categoria: s("string", "Nome da categoria do app (use listar_categorias)"),
      subcategoria: s("string", "Nome da subcategoria"),
      nota: s("string", "Nota que vai na transação"),
      conta: s("string", "Cartão ou conta usada, se o Renan disse (só ajuda a escolher a candidata)"),
      receita: s("boolean", "true se for dinheiro recebido (padrão false = gasto)"),
    }, ["valor", "descricao"]),
    annotations: ESCRITA,
  },
  {
    name: "listar_anotacoes",
    title: "Listar anotações",
    description: "Lista anotações. As pendentes vêm com as transações do banco compatíveis (valor e data). Mostre as candidatas ao Renan e confirme antes de chamar confirmar_anotacao.",
    inputSchema: obj({ status: s("string", "pendente (padrão), vinculada, aplicada, descartada ou todas", { enum: ["pendente", "vinculada", "aplicada", "descartada", "todas"] }), limite: s("integer", "Máximo (padrão 30)") }),
    annotations: LEITURA,
  },
  {
    name: "confirmar_anotacao",
    title: "Confirmar anotação",
    description: "Liga a anotação a uma transação do banco (transacao_id de listar_anotacoes) e grava título, categoria e nota nela. Se o app ainda não importou a transação, fica 'vinculada' e é aplicada sozinha quando chegar. Só chame depois de o Renan confirmar.",
    inputSchema: obj({ anotacao_id: s("string", "Id da anotação"), transacao_id: s("string", "Id da transação do banco") }, ["anotacao_id", "transacao_id"]),
    annotations: ESCRITA,
  },
  {
    name: "editar_anotacao",
    title: "Editar ou descartar anotação",
    description: "Corrige campos de uma anotação pendente/vinculada, volta uma vinculada para pendente (desvincular) ou descarta.",
    inputSchema: obj({
      id: s("string", "Id da anotação"), valor: s("number", "Valor"), data: s("string", "AAAA-MM-DD"), descricao: s("string", "Descrição"),
      titulo: s("string", "Título"), categoria: s("string", "Categoria ('' remove)"), subcategoria: s("string", "Subcategoria"), nota: s("string", "Nota"),
      conta: s("string", "Conta"), receita: s("boolean", "Recebimento"), desvincular: s("boolean", "Volta para pendente"), descartar: s("boolean", "Descarta a anotação"),
    }, ["id"]),
    annotations: ESCRITA,
  },
  {
    name: "resumo",
    title: "Resumo do ciclo",
    description: "Resumo do ciclo atual (salário a salário): quanto já foi gasto, quanto sobra, limite diário e itens na fila Para revisar.",
    inputSchema: obj({}),
    annotations: LEITURA,
  },
  {
    name: "listar_contas",
    title: "Contas e saldos",
    description: "Contas e cartões do banco (saldo, limite, vencimento) e as carteiras do app.",
    inputSchema: obj({}),
    annotations: LEITURA,
  },
  {
    name: "listar_categorias",
    title: "Categorias",
    description: "Categorias do app com as subcategorias.",
    inputSchema: obj({}),
    annotations: LEITURA,
  },
  {
    name: "buscar_transacoes",
    title: "Buscar transações",
    description: "Transações do app (como aparecem nele), mais recentes primeiro. Valor negativo = saída. pk 'mb:<id>' = veio do banco.",
    inputSchema: obj({
      de: s("string", "AAAA-MM-DD inicial (padrão: 30 dias atrás)"), ate: s("string", "AAAA-MM-DD final (padrão: hoje)"),
      texto: s("string", "Busca no título, nota e texto do banco"), categoria: s("string", "Nome da categoria ou subcategoria"),
      carteira: s("string", "Nome da carteira"), valor_min: s("number", "Valor absoluto mínimo"), valor_max: s("number", "Valor absoluto máximo"),
      limite: s("integer", "Máximo (padrão 50, até 300)"),
    }),
    annotations: LEITURA,
  },
  {
    name: "editar_transacao",
    title: "Editar transação",
    description: "Muda título, categoria, subcategoria, nota, valor, data, carteira ou pago de uma transação do app (pk de buscar_transacoes). Aparece em todos os aparelhos na hora.",
    inputSchema: obj({
      pk: s("string", "pk da transação"), titulo: s("string", "Título"), categoria: s("string", "Categoria"), subcategoria: s("string", "Subcategoria ('' remove)"),
      nota: s("string", "Nota"), valor: s("number", "Valor com sinal (negativo = gasto)"), data: s("string", "AAAA-MM-DD"), carteira: s("string", "Carteira"), pago: s("boolean", "Pago"),
    }, ["pk"]),
    annotations: ESCRITA,
  },
  {
    name: "criar_transacao",
    title: "Criar lançamento manual",
    description: "Cria um lançamento manual no app (dinheiro em espécie, gasto fora dos bancos conectados). Gasto do banco não precisa: use anotar_gasto.",
    inputSchema: obj({
      titulo: s("string", "Título"), valor: s("number", "Valor positivo"), receita: s("boolean", "true = entrada (padrão gasto)"), data: s("string", "AAAA-MM-DD (padrão hoje)"),
      categoria: s("string", "Categoria"), subcategoria: s("string", "Subcategoria"), carteira: s("string", "Carteira"), nota: s("string", "Nota"), pago: s("boolean", "Pago (padrão true)"),
    }, ["titulo", "valor", "categoria", "carteira"]),
    annotations: ESCRITA,
  },
  {
    name: "apagar_transacao",
    title: "Apagar transação",
    description: "Apaga uma transação do app em todos os aparelhos (a do banco não volta). Confirme com o Renan antes.",
    inputSchema: obj({ pk: s("string", "pk da transação") }, ["pk"]),
    annotations: APAGA,
  },
  {
    name: "ler_linhas",
    title: "Ler tabela do app",
    description: `Linhas cruas do banco do app (JSON com os nomes de coluna do Drift). Tabelas: ${TABELAS_ESPELHO.join(", ")}. Use para orçamentos (budgets, category_budget_limits), metas (objectives), configurações (_config) e para ver o formato antes de escrever_linha.`,
    inputSchema: obj({ tabela: s("string", "Tabela", { enum: [...TABELAS_ESPELHO] }), pk: s("string", "pk de uma linha"), texto: s("string", "Filtro por texto no JSON"), limite: s("integer", "Máximo (padrão 50, até 500)"), incluir_apagadas: s("boolean", "Inclui apagadas") }, ["tabela"]),
    annotations: LEITURA,
  },
  {
    name: "escrever_linha",
    title: "Escrever linha do app",
    description: "Altera campos de uma linha de qualquer tabela do app (merge: só os campos enviados mudam) ou cria uma linha nova com nova=true (mande todas as colunas, copiando o formato de uma linha existente). Datas são epoch em segundos.",
    inputSchema: obj({ tabela: s("string", "Tabela", { enum: [...TABELAS_ESPELHO] }), pk: s("string", "pk"), campos: s("object", "Colunas e valores"), nova: s("boolean", "Cria a linha se não existir") }, ["tabela", "pk", "campos"]),
    annotations: ESCRITA,
  },
  {
    name: "apagar_linha",
    title: "Apagar linha do app",
    description: "Apaga uma linha de qualquer tabela do app em todos os aparelhos. Confirme com o Renan antes.",
    inputSchema: obj({ tabela: s("string", "Tabela", { enum: [...TABELAS_ESPELHO] }), pk: s("string", "pk") }, ["tabela", "pk"]),
    annotations: APAGA,
  },
  {
    name: "consultar_sql",
    title: "Consulta SQL (leitura)",
    description: "SELECT no D1 (SQLite), só leitura, até 200 linhas. Tabelas úteis: transactions (do banco: id, account_id, date, description, amount, status, merchant, contraparte; em cartão gasto é positivo, em conta é negativo), accounts, espelho (tabela, pk, dados JSON, deleted_at: dados do app), anotacoes, snapshots, sync_log, notificacoes.",
    inputSchema: obj({ sql: s("string", "Comando SELECT ou WITH") }, ["sql"]),
    annotations: LEITURA,
  },
  {
    name: "atualizar_banco",
    title: "Atualizar do banco",
    description: "Pede ao Pluggy os dados mais novos dos bancos e sincroniza (no máximo a cada 5 min).",
    inputSchema: obj({}),
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
  },
];

const texto = (v) => (typeof v === "string" && v.trim() ? v.trim() : null);
function exigirData(d, padrao) {
  const v = d ?? padrao;
  if (!DATA.test(v || "") || new Date(v + "T12:00:00Z").toISOString().slice(0, 10) !== v) falhar("Data inválida (use AAAA-MM-DD): " + d);
  return v;
}
function exigirValor(v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) falhar("Valor deve ser um número positivo");
  return reais(n);
}

const EXECUTAR = {
  async anotar_gasto(a, c) {
    const db = c.env.DB;
    const cat = await catalogo(db);
    const r = resolverCategoria(cat, texto(a.categoria), texto(a.subcategoria));
    const ts = new Date().toISOString();
    const an = {
      id: crypto.randomUUID(), valor: exigirValor(a.valor), data: exigirData(a.data, hojeSP()), receita: a.receita ? 1 : 0,
      descricao: texto(a.descricao) || falhar("descricao obrigatória"), titulo: texto(a.titulo), categoria: r.categoria, subcategoria: r.subcategoria ?? null,
      nota: texto(a.nota), conta: texto(a.conta),
    };
    await db.prepare("INSERT INTO anotacoes (id, valor, data, receita, descricao, titulo, categoria, subcategoria, nota, conta, status, criada, atualizada) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'pendente', ?11, ?11)")
      .bind(an.id, an.valor, an.data, an.receita, an.descricao, an.titulo, an.categoria, an.subcategoria, an.nota, an.conta, ts).run();
    return { anotacao: anotacaoLegivel({ ...an, status: "pendente", criada: ts }, cat), candidatas_agora: await candidatas(db, an) };
  },

  async listar_anotacoes(a, c) {
    const db = c.env.DB;
    const status = a.status || "pendente";
    const lim = limite(a.limite, 30, 200);
    // Falha ao aplicar não pode esconder a lista: as vinculadas ficam para a próxima tentativa.
    await aplicarVinculadas(c.env, c.ctx).catch((e) => console.error("Anotações vinculadas", e?.stack || e));
    const [{ results }, cat] = await Promise.all([
      db.prepare(`SELECT * FROM anotacoes ${status === "todas" ? "" : "WHERE status = ?2"} ORDER BY data DESC, criada DESC LIMIT ?1`).bind(...(status === "todas" ? [lim] : [lim, status])).all(),
      catalogo(db),
    ]);
    return { anotacoes: await Promise.all(results.map(async (x) => ({ ...anotacaoLegivel(x, cat), ...(x.status === "pendente" ? { candidatas: await candidatas(db, x) } : {}) }))) };
  },

  async confirmar_anotacao(a, c) {
    const db = c.env.DB;
    const an = (await lerAnotacao(db, a.anotacao_id)) || falhar("Anotação não encontrada");
    if (!["pendente", "vinculada"].includes(an.status)) falhar(`Anotação está ${an.status}`);
    const tx = (await db.prepare("SELECT id FROM transactions WHERE id = ?1").bind(a.transacao_id).first()) || falhar("Transação do banco não encontrada");
    const outra = await db.prepare("SELECT id FROM anotacoes WHERE transacao_id = ?1 AND status IN ('vinculada', 'aplicada') AND id != ?2").bind(tx.id, an.id).first();
    if (outra) falhar(`Essa transação já está ligada à anotação ${outra.id}`);
    await db.prepare("UPDATE anotacoes SET status = 'vinculada', transacao_id = ?1, atualizada = ?2 WHERE id = ?3").bind(tx.id, new Date().toISOString(), an.id).run();
    const aplicadas = await aplicarVinculadas(c.env, c.ctx);
    const fim = await lerAnotacao(db, an.id);
    return { status: fim.status, mensagem: fim.status === "aplicada" ? "Aplicada: a transação já aparece com o novo título e categoria." : "Vinculada: será aplicada assim que o app importar a transação.", aplicadas };
  },

  async editar_anotacao(a, c) {
    const db = c.env.DB;
    const an = (await lerAnotacao(db, a.id)) || falhar("Anotação não encontrada");
    if (an.status === "aplicada") falhar("Anotação já aplicada: edite a transação com editar_transacao");
    const ts = new Date().toISOString();
    if (a.descartar) {
      await db.prepare("UPDATE anotacoes SET status = 'descartada', atualizada = ?1 WHERE id = ?2").bind(ts, an.id).run();
      return { status: "descartada" };
    }
    const novo = { ...an };
    let cat;
    if (a.valor != null) novo.valor = exigirValor(a.valor);
    if (a.data != null) novo.data = exigirData(a.data);
    for (const k of ["descricao", "titulo", "nota", "conta"]) if (a[k] != null) novo[k] = texto(a[k]);
    if (!novo.descricao) falhar("descricao não pode ficar vazia");
    if (a.receita != null) novo.receita = a.receita ? 1 : 0;
    if (a.categoria === "") { novo.categoria = null; novo.subcategoria = null; }
    else if (a.categoria != null || a.subcategoria != null) {
      const r = resolverCategoria(cat ??= await catalogo(db), texto(a.categoria) ?? (a.subcategoria ? null : an.categoria), texto(a.subcategoria));
      novo.categoria = r.categoria;
      novo.subcategoria = r.subcategoria ?? null;
    }
    if (a.desvincular) { novo.status = "pendente"; novo.transacao_id = null; }
    await db.prepare("UPDATE anotacoes SET valor = ?1, data = ?2, receita = ?3, descricao = ?4, titulo = ?5, categoria = ?6, subcategoria = ?7, nota = ?8, conta = ?9, status = ?10, transacao_id = ?11, atualizada = ?12 WHERE id = ?13")
      .bind(novo.valor, novo.data, novo.receita, novo.descricao, novo.titulo, novo.categoria, novo.subcategoria, novo.nota, novo.conta, novo.status, novo.transacao_id, ts, an.id).run();
    return { anotacao: anotacaoLegivel(novo, cat ?? (await catalogo(db))), ...(novo.status === "pendente" ? { candidatas: await candidatas(db, novo) } : {}) };
  },

  async resumo(_a, c) {
    const b = await c.deps.baseCiclo();
    return { hoje: b.hoje, ciclo: { ...b.resumo, salario: b.config.salario ?? null }, para_revisar: b.revisar?.length ?? 0 };
  },

  async listar_contas(_a, c) {
    const db = c.env.DB;
    const { results } = await db.prepare("SELECT id, type, subtype, name, bank, balance, credit_limit, available_limit, due_date, closing_date FROM accounts ORDER BY type, name").all();
    const carteiras = (await linhasDe(db, "wallets")).filter((w) => !w.archived).map((w) => ({ pk: w.pk, nome: w.name }));
    return { contas_do_banco: results, carteiras_do_app: carteiras };
  },

  async listar_categorias(_a, c) {
    const cat = await catalogo(c.env.DB);
    const ativas = cat.categorias.filter((x) => !x.archived);
    return {
      categorias: ativas.filter((x) => !x.main_category_pk).sort((x, y) => (x.order ?? 0) - (y.order ?? 0)).map((x) => ({
        pk: x.pk, nome: x.name, receita: !!x.income, subcategorias: ativas.filter((y) => y.main_category_pk === x.pk).map((y) => ({ pk: y.pk, nome: y.name })),
      })),
    };
  },

  async buscar_transacoes(a, c) {
    const db = c.env.DB;
    const cat = await catalogo(db);
    const ate = exigirData(a.ate, hojeSP());
    const de = exigirData(a.de, somarDias(ate, -30));
    const lim = limite(a.limite, 50, 300);
    let catPk = null;
    if (texto(a.categoria)) {
      const r = resolverCategoria(cat, a.categoria);
      catPk = r.subcategoria ?? r.categoria;
    }
    const carteira = texto(a.carteira) ? resolverCarteira(cat, a.carteira).pk : null;
    const busca = texto(a.texto) ? `%${a.texto.trim()}%` : null;
    const { results } = await db.prepare(
      `SELECT e.pk, e.dados, t.description, t.merchant, t.contraparte, ac.name AS conta
       FROM espelho e LEFT JOIN transactions t ON e.pk = 'mb:' || t.id LEFT JOIN accounts ac ON ac.id = t.account_id
       WHERE e.tabela = 'transactions' AND e.deleted_at IS NULL
         AND json_extract(e.dados, '$.date_created') >= ?1 AND json_extract(e.dados, '$.date_created') < ?2
         AND (?3 IS NULL OR json_extract(e.dados, '$.name') LIKE ?3 OR json_extract(e.dados, '$.note') LIKE ?3 OR t.description LIKE ?3 OR t.merchant LIKE ?3 OR t.contraparte LIKE ?3)
         AND (?4 IS NULL OR json_extract(e.dados, '$.category_fk') = ?4 OR json_extract(e.dados, '$.sub_category_fk') = ?4)
         AND (?5 IS NULL OR json_extract(e.dados, '$.wallet_fk') = ?5)
         AND (?6 IS NULL OR abs(json_extract(e.dados, '$.amount')) >= ?6) AND (?7 IS NULL OR abs(json_extract(e.dados, '$.amount')) <= ?7)
       ORDER BY json_extract(e.dados, '$.date_created') DESC, e.pk LIMIT ?8`
    ).bind(epochDe(de), epochDe(somarDias(ate, 1)), busca, catPk, carteira, a.valor_min ?? null, a.valor_max ?? null, lim).all();
    return { de, ate, transacoes: results.map((r) => transacaoLegivel(r.pk, JSON.parse(r.dados), cat, r)) };
  },

  async editar_transacao(a, c) {
    const db = c.env.DB;
    const [atual, cat] = await Promise.all([linhaDe(db, "transactions", a.pk).then((l) => viva(l, "Transação não encontrada")), catalogo(db)]);
    const d = { date_time_modified: agoraS() };
    if (a.titulo != null) d.name = texto(a.titulo) || falhar("titulo vazio");
    if (a.nota != null) d.note = a.nota;
    if (a.valor != null) { const v = Number(a.valor); if (!Number.isFinite(v)) falhar("valor inválido"); d.amount = reais(v); }
    if (a.data != null) { d.date_created = epochDe(exigirData(a.data)); d.original_date_due = d.date_created; }
    if (a.carteira != null) d.wallet_fk = resolverCarteira(cat, a.carteira).pk;
    if (a.pago != null) d.paid = a.pago ? 1 : 0;
    if (a.categoria != null || a.subcategoria != null) {
      if (a.subcategoria === "" && a.categoria == null) d.sub_category_fk = null;
      else {
        const r = resolverCategoria(cat, texto(a.categoria) ?? (texto(a.subcategoria) ? null : atual.dados.category_fk), texto(a.subcategoria));
        if (r.categoria) d.category_fk = r.categoria;
        d.sub_category_fk = r.subcategoria ?? null;
      }
    }
    await gravar(c, [{ tabela: "transactions", pk: a.pk, dados: d }]);
    return { transacao: transacaoLegivel(a.pk, { ...atual.dados, ...d }, cat) };
  },

  async criar_transacao(a, c) {
    const db = c.env.DB;
    const cat = await catalogo(db);
    const r = resolverCategoria(cat, texto(a.categoria), texto(a.subcategoria));
    if (!r.categoria) falhar("categoria obrigatória");
    const pk = crypto.randomUUID();
    const quando = epochDe(exigirData(a.data, hojeSP()));
    const valor = exigirValor(a.valor);
    const dados = {
      transaction_pk: pk, paired_transaction_fk: null, name: texto(a.titulo) || falhar("titulo obrigatório"), amount: a.receita ? valor : -valor,
      note: a.nota ?? "", category_fk: r.categoria, sub_category_fk: r.subcategoria ?? null, wallet_fk: resolverCarteira(cat, a.carteira).pk,
      date_created: quando, date_time_modified: agoraS(), original_date_due: quando, income: a.receita ? 1 : 0, period_length: null, reoccurrence: null,
      end_date: null, upcoming_transaction_notification: 1, type: null, paid: a.pago === false ? 0 : 1, created_another_future_transaction: 0, skip_paid: 0,
      objective_fk: null, objective_loan_fk: null, budget_fks_exclude: null,
    };
    await gravar(c, [{ tabela: "transactions", pk, dados }]);
    return { transacao: transacaoLegivel(pk, dados, cat) };
  },

  async apagar_transacao(a, c) {
    const atual = viva(await linhaDe(c.env.DB, "transactions", a.pk), "Transação não encontrada");
    await gravar(c, [{ tabela: "transactions", pk: a.pk, dados: null, deleted_at: new Date().toISOString() }]);
    return { apagada: a.pk, era: transacaoLegivel(a.pk, atual.dados, await catalogo(c.env.DB)) };
  },

  async ler_linhas(a, c) {
    if (!TABELAS_ESPELHO.includes(a.tabela)) falhar("Tabela desconhecida");
    const lim = limite(a.limite, 50, 500);
    const { results } = await c.env.DB.prepare(
      `SELECT pk, dados, updated_at, deleted_at, aparelho FROM espelho WHERE tabela = ?1 AND (?2 IS NULL OR pk = ?2) AND (?3 IS NULL OR dados LIKE ?3) ${a.incluir_apagadas ? "" : "AND deleted_at IS NULL"} ORDER BY server_at DESC LIMIT ?4`
    ).bind(a.tabela, a.pk ?? null, texto(a.texto) ? `%${a.texto.trim()}%` : null, lim).all();
    return { linhas: results.map((r) => ({ ...r, dados: r.dados == null ? null : JSON.parse(r.dados) })) };
  },

  async escrever_linha(a, c) {
    if (!TABELAS_ESPELHO.includes(a.tabela)) falhar("Tabela desconhecida");
    if (!a.campos || typeof a.campos !== "object" || Array.isArray(a.campos)) falhar("campos deve ser um objeto");
    const atual = await linhaDe(c.env.DB, a.tabela, a.pk);
    const existe = atual && !atual.deleted_at;
    if (!existe && !a.nova) falhar("Linha não existe: mande nova=true com todas as colunas para criar");
    const dados = { ...a.campos };
    if (a.tabela !== "_config" && existe && "date_time_modified" in atual.dados && !("date_time_modified" in dados)) dados.date_time_modified = agoraS();
    await gravar(c, [{ tabela: a.tabela, pk: a.pk, dados }]);
    return { linha: { tabela: a.tabela, pk: a.pk, dados: existe ? { ...atual.dados, ...dados } : dados } };
  },

  async apagar_linha(a, c) {
    if (!TABELAS_ESPELHO.includes(a.tabela)) falhar("Tabela desconhecida");
    const atual = viva(await linhaDe(c.env.DB, a.tabela, a.pk), "Linha não encontrada");
    await gravar(c, [{ tabela: a.tabela, pk: a.pk, dados: null, deleted_at: new Date().toISOString() }]);
    return { apagada: { tabela: a.tabela, pk: a.pk }, era: atual.dados };
  },

  async consultar_sql(a, c) {
    const sql = String(a.sql ?? "").trim().replace(/;\s*$/, "");
    if (!/^(select|with)\b/i.test(sql)) falhar("Só SELECT ou WITH");
    if (sql.includes(";")) falhar("Um comando só");
    if (SQL_PROIBIDO.test(sql)) falhar("Só leitura: o comando tem palavra de escrita");
    if (TABELAS_SECRETAS.test(sql)) falhar("Tabela de credenciais fora do alcance");
    const { results } = await c.env.DB.prepare(`SELECT * FROM (${sql}\n) LIMIT ${MAX_LINHAS_SQL + 1}`).all();
    return { linhas: results.slice(0, MAX_LINHAS_SQL), cortado: results.length > MAX_LINHAS_SQL };
  },

  async atualizar_banco(_a, c) {
    return c.deps.atualizar();
  },
};

// ---------- JSON-RPC ----------

const INSTRUCOES = `RenanCash: finanças pessoais do Renan (BRL, fuso America/Sao_Paulo).
Quando o Renan contar um gasto ("gastei 45 no almoço"), chame anotar_gasto com valor, descrição e, se der para inferir, título curto e categoria do app (veja listar_categorias). O banco lança a transação até ~24 h depois.
Quando ele perguntar o que chegou, chame listar_anotacoes: mostre cada anotação com as candidatas e só chame confirmar_anotacao depois do ok dele. Nunca confirme sozinho.
Antes de apagar qualquer coisa, confirme com ele.`;

const resultado = (id, result) => ({ jsonrpc: "2.0", id, result });
const erroRpc = (id, code, message) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });

async function chamar(msg, c) {
  const { id, method, params } = msg;
  if (method === "initialize") {
    const pedida = params?.protocolVersion;
    return resultado(id, {
      protocolVersion: VERSOES.includes(pedida) ? pedida : VERSOES[0],
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "renancash", title: "RenanCash", version: "1.0.0" },
      instructions: INSTRUCOES,
    });
  }
  if (method === "ping") return resultado(id, {});
  if (method === "tools/list") return resultado(id, { tools: FERRAMENTAS });
  if (method === "tools/call") {
    const f = EXECUTAR[params?.name];
    if (!f) return erroRpc(id, -32602, "Ferramenta desconhecida: " + params?.name);
    try {
      const r = await f(params.arguments ?? {}, c);
      return resultado(id, { content: [{ type: "text", text: JSON.stringify(r) }], structuredContent: r });
    } catch (e) {
      if (!(e instanceof ErroGravacao)) console.error("MCP", params?.name, e?.stack || e);
      return resultado(id, { content: [{ type: "text", text: "Erro: " + (e?.message || e) }], isError: true });
    }
  }
  return erroRpc(id, -32601, "Método não suportado: " + method);
}

// deps: { baseCiclo(), atualizar() } vindos do index.js (evita import circular).
export async function tratarMcp(request, env, ctx, deps) {
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } });
  let corpo;
  try { corpo = await request.json(); } catch { return Response.json(erroRpc(null, -32700, "JSON inválido"), { status: 400 }); }
  const c = { env, ctx, deps };
  const lote = Array.isArray(corpo) ? corpo : [corpo];
  const respostas = [];
  for (const msg of lote) {
    if (msg?.jsonrpc !== "2.0" || typeof msg.method !== "string") { if (msg?.id != null) respostas.push(erroRpc(msg.id, -32600, "Pedido inválido")); continue; }
    if (msg.id == null) continue; // notificação (notifications/initialized etc.)
    respostas.push(await chamar(msg, c));
  }
  if (!respostas.length) return new Response(null, { status: 202 });
  return Response.json(Array.isArray(corpo) ? respostas : respostas[0]);
}
