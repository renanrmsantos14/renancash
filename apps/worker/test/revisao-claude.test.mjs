// Revisão diária do Claude (fase 3): fila_revisao, aplicar_ia (classificar, anotação, devolução) com Desfazer, kill switch e enviar_resumo.
import { test, mock, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente } from "./ambiente.mjs";
import { tratarMcp } from "../src/mcp.js";
import { aplicarClaude } from "../src/revisaoClaude.js";
import { listarAplicadas, desfazerIa, naoAvisadasIa, aplicarPendentesIa } from "../src/iaAuto.js";

const relogio = (iso) => { mock.timers.reset(); mock.timers.enable({ apis: ["Date"], now: Date.parse(iso) }); };
afterEach(() => mock.timers.reset());
const HOJE = "2026-11-26";
const ANTES = (d) => new Date(Date.parse(HOJE + "T12:00:00Z") - d * 86400000).toISOString().slice(0, 10);
const T0 = "2026-01-01T00:00:00.000Z";

// Ambiente cujo DB roda `antes` logo antes da n-ésima execução (first/all/run) de um SQL que contém `trecho`: simula a corrida entre a checagem e a gravação.
function corrida(env, trecho, antes, n = 1) {
  let vistas = 0;
  const prepare = (sql) => {
    const st = env.DB.prepare(sql);
    if (!sql.includes(trecho)) return st;
    const envolver = (s) => new Proxy(s, { get: (o, k) => {
      if (k === "bind") return (...a) => envolver(o.bind(...a));
      if (!["first", "all", "run"].includes(k)) return o[k];
      return async (...a) => { if (++vistas === n) await antes(); return o[k](...a); };
    } });
    return envolver(st);
  };
  return { ...env, DB: new Proxy(env.DB, { get: (o, k) => (k === "prepare" ? prepare : typeof o[k] === "function" ? o[k].bind(o) : o[k]) }) };
}

async function preparar() {
  relogio("2026-11-26T15:00:00.000Z"); // 12h BRT
  const hub = { idFromName: (n) => n, get: () => ({ fetch: async () => new Response(null, { status: 204 }) }) };
  const amb = criarAmbiente({ ESPELHO: "1", ESPELHO_HUB: hub });
  const db = amb.env.DB;
  const linha = (tabela, pk, dados) => db.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) VALUES (?1, ?2, ?3, ?4, NULL, ?4, 'cel')").bind(tabela, pk, JSON.stringify(dados), T0).run();
  await db.prepare("INSERT INTO espelho_meta (chave, valor) VALUES ('semeado', '1')").run();
  await linha("categories", "c-alim", { category_pk: "c-alim", name: "Alimentação", income: 0, main_category_pk: null, archived: 0 });
  await linha("categories", "c-rest", { category_pk: "c-rest", name: "Restaurante", income: 0, main_category_pk: "c-alim", archived: 0 });
  await linha("categories", "c-sal", { category_pk: "c-sal", name: "Salário", income: 1, main_category_pk: null, archived: 0 });
  await db.prepare("INSERT INTO accounts (id, item_id, type, name, balance, updated_at) VALUES ('acc-cc', 'it', 'CREDIT', 'Cartão', 0, ?1), ('acc-b', 'it', 'BANK', 'Inter', 100, ?1)").bind(T0).run();
  const tx = (id, conta, valor, data, desc, extra = {}) => db.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, updated_at, contraparte) VALUES (?1, ?2, ?3, ?4, ?5, 'DEBIT', ?6, ?7, ?8)")
    .bind(id, conta, data, desc, valor, extra.status ?? "POSTED", T0, extra.contraparte ?? null).run();
  const mb = (id, nome, extra = {}) => linha("transactions", "mb:" + id, { transaction_pk: "mb:" + id, name: nome, amount: -1, note: "", category_fk: null, sub_category_fk: null, date_time_modified: 0, ...extra });
  const decisao = (id, origem, status, sugestao = null, confianca = null) => db.prepare("INSERT INTO ia_aplicacoes (tx_id, origem, sugestao, confianca, status, criado_em, atualizado_em) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)")
    .bind(id, origem, sugestao && JSON.stringify(sugestao), confianca, status, T0).run();
  const envios = [];
  let revisar = [];
  const deps = { baseCiclo: async () => ({ hoje: HOJE, revisar }), atualizar: async () => ({}), enviarPendentes: async () => (envios.push(Date.now()), 1) };
  const ferramenta = async (name, args = {}) => {
    const req = new Request("https://x.test/mcp", { method: "POST", body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }) });
    const r = await (await tratarMcp(req, amb.env, amb.ctx, deps)).json();
    if (r.result.isError) throw new Error(r.result.content[0].text);
    return r.result.structuredContent;
  };
  const app = async (id) => JSON.parse(await db.prepare("SELECT dados FROM espelho WHERE tabela = 'transactions' AND pk = ?1").bind("mb:" + id).first("dados"));
  const status = (id) => db.prepare("SELECT status FROM ia_aplicacoes WHERE tx_id = ?1").bind(id).first("status");
  return { ...amb, db, linha, tx, mb, decisao, ferramenta, app, status, envios, setRevisar: (r) => { revisar = r; } };
}

test("fila_revisao: só o que o app ainda mostra para classificar, com o palpite do Llama; Pix recebido vai com as compras candidatas", async () => {
  const { tx, mb, decisao, ferramenta, setRevisar } = await preparar();
  await tx("g1", "acc-b", -50, HOJE, "MERCADO X"); await mb("g1", "MERCADO X");
  await decisao("g1", "llama", "sombra", { name: "Mercado", category_fk: "c-alim", sub_category_fk: null }, 0.6);
  await tx("g2", "acc-b", -20, HOJE, "PADARIA"); await mb("g2", "Padaria", { date_time_modified: 1764000000 }); // editada no app
  await tx("g3", "acc-b", -30, HOJE, "UBER"); await decisao("g3", "memoria", "aplicada");
  await tx("g4", "acc-cc", 15, ANTES(1), "NETFLIX"); // app ainda não importou
  await tx("g5", "acc-b", -9, ANTES(15), "VELHA"); // fora da janela de 10 dias
  await tx("r1", "acc-b", 120, HOJE, "PIX RECEBIDO JOAO SILVA");
  await tx("c1", "acc-b", -120, ANTES(10), "PIX ENVIADO LOJA ABC");
  await tx("c2", "acc-b", -120, ANTES(40), "PIX ENVIADO LOJA ABC"); // fora dos 30 dias
  await tx("c3", "acc-b", -100, ANTES(5), "PIX ENVIADO JOAO SILVA"); // outro valor
  setRevisar([{ id: "tx:r1", tipo: "pix_recebido", tx_id: "r1", data: HOJE, descricao: "PIX RECEBIDO JOAO SILVA", valor: 120 }, { id: "tx:x", tipo: "pix_enviado", tx_id: "x", data: HOJE, descricao: "PIX ENVIADO ANA", valor: 10 }]);

  const f = await ferramenta("fila_revisao");
  assert.equal(f.aplicar_ia_ligado, true);
  assert.deepEqual(f.para_classificar.map((t) => t.tx_id).sort(), ["c1", "c3", "g1", "g4"]);
  const g1 = f.para_classificar.find((t) => t.tx_id === "g1");
  assert.deepEqual(g1.palpite_llama, { categoria: "Alimentação", subcategoria: null, titulo: "Mercado", confianca: 0.6 });
  assert.equal(f.para_classificar.find((t) => t.tx_id === "g4").valor, -15, "cartão: gasto negativo");
  assert.equal(f.para_classificar.find((t) => t.tx_id === "g4").no_app, null);
  assert.deepEqual(f.para_revisar[0].compras_candidatas.map((c) => [c.compra_id, c.mesmo_favorecido]), [["c1", false]]);
  assert.deepEqual(f.outros_para_revisar.map((i) => i.tipo), ["pix_enviado"]);
});

test("aplicar_ia classificar: grava como IA (Feito pela IA, Desfazer), não ensina a memória e recusa item a item", async () => {
  const { tx, mb, decisao, ferramenta, app, status, env, ctx, db } = await preparar();
  await tx("g1", "acc-b", -50, HOJE, "PIX ENVIADO RESTAURANTE BOM"); await mb("g1", "PIX ENVIADO RESTAURANTE BOM");
  await decisao("g1", "llama", "sombra", { category_fk: "c-alim" }, 0.5);
  await tx("g2", "acc-b", -20, HOJE, "PADARIA"); await mb("g2", "Padaria", { date_time_modified: 1764000000 });
  await tx("g3", "acc-b", -30, HOJE, "UBER"); await mb("g3", "UBER"); await decisao("g3", "memoria", "aplicada");
  await tx("g4", "acc-b", -40, HOJE, "LOJA"); await mb("g4", "LOJA");
  await tx("g5", "acc-cc", 70, HOJE, "IFOOD"); // linha mb: ainda não chegou
  await tx("r1", "acc-b", 120, HOJE, "PIX RECEBIDO JOAO");

  const r = await ferramenta("aplicar_ia", { itens: [
    { tipo: "classificar", tx_id: "g1", subcategoria: "Restaurante", titulo: "Restaurante Bom", motivo: "nome do estabelecimento" },
    { tipo: "classificar", tx_id: "g2", categoria: "Alimentação", motivo: "x" },
    { tipo: "classificar", tx_id: "g3", categoria: "Alimentação", motivo: "x" },
    { tipo: "classificar", tx_id: "g4", categoria: "Inexistente", motivo: "x" },
    { tipo: "classificar", tx_id: "g4", categoria: "Salário", motivo: "x" },
    { tipo: "classificar", tx_id: "g4", categoria: "Alimentação", motivo: "" },
    { tipo: "classificar", tx_id: "r1", categoria: "Alimentação", motivo: "x" },
    { tipo: "classificar", tx_id: "g5", categoria: "Alimentação", motivo: "app de comida" },
  ] });
  assert.deepEqual(r.resultados.map((x) => x.ok), [true, false, false, false, false, false, false, true]);
  assert.match(r.resultados[1].erro, /editada no app/);
  assert.match(r.resultados[2].erro, /já decidiu/);
  assert.match(r.resultados[3].erro, /não existe/);
  assert.match(r.resultados[4].erro, /receita/);
  assert.match(r.resultados[5].erro, /motivo/);
  assert.match(r.resultados[6].erro, /Para revisar/);
  assert.equal(r.resultados[0].status, "aplicada");
  assert.match(r.resultados[7].status, /aguardando/);

  const d = await app("g1");
  assert.deepEqual([d.name, d.category_fk, d.sub_category_fk], ["Restaurante Bom", "c-alim", "c-rest"]);
  assert.ok(d.date_time_modified > 978307200);
  assert.equal((await app("g2")).name, "Padaria", "editada no app não muda");
  assert.equal(await db.prepare("SELECT count(*) n FROM ia_memoria").first("n"), 0, "não vira memória");
  assert.deepEqual(await naoAvisadasIa(db), [], "o resumo é o aviso: sem push em lote");
  const [item] = (await listarAplicadas(db)).itens.filter((i) => i.tx_id === "g1");
  assert.equal(item.origem, "claude");
  assert.equal(item.antes.name, "PIX ENVIADO RESTAURANTE BOM");

  await mb("g5", "IFOOD"); // o app importou: aplica
  await aplicarPendentesIa(env, ctx);
  assert.equal(await status("g5"), "aplicada");

  assert.equal((await desfazerIa(env, ctx, { tx_id: "g1" })).status, 200);
  const volta = await app("g1");
  assert.deepEqual([volta.name, volta.category_fk, volta.date_time_modified], ["PIX ENVIADO RESTAURANTE BOM", null, 0]);
  const de = await ferramenta("aplicar_ia", { itens: [{ tipo: "classificar", tx_id: "g1", categoria: "Alimentação", motivo: "x" }] });
  assert.match(de.resultados[0].erro, /desfeita/, "desfeita não volta");
});

test("aplicar_ia anotação: escolhe entre 2 candidatas, grava título/nota e o Desfazer devolve a anotação a pendente", async () => {
  const { tx, mb, ferramenta, app, env, ctx, db } = await preparar();
  const a = await ferramenta("anotar_gasto", { valor: 45, descricao: "almoço com a Ana", titulo: "Almoço", categoria: "Alimentação", nota: "aniversário" });
  await tx("z1", "acc-b", -45, HOJE, "OUTBACK"); await mb("z1", "OUTBACK");
  await tx("z2", "acc-b", -45, HOJE, "MADERO"); await mb("z2", "MADERO");
  await tx("z3", "acc-b", -60, HOJE, "OUTRO"); await mb("z3", "OUTRO");
  const [an] = (await ferramenta("fila_revisao")).anotacoes_pendentes;
  assert.equal(an.candidatas.length, 2);

  const r = await ferramenta("aplicar_ia", { itens: [
    { tipo: "anotacao", anotacao_id: a.anotacao.id, tx_id: "z3", motivo: "x" },
    { tipo: "anotacao", anotacao_id: a.anotacao.id, tx_id: "z2", motivo: "a Ana citou o Madero" },
    { tipo: "anotacao", anotacao_id: a.anotacao.id, tx_id: "z1", motivo: "x" },
  ] });
  assert.match(r.resultados[0].erro, /não é candidata/);
  assert.equal(r.resultados[1].status, "aplicada");
  assert.match(r.resultados[2].erro, /aplicada|automatica/);
  const d = await app("z2");
  assert.deepEqual([d.name, d.category_fk, d.note], ["Almoço", "c-alim", "aniversário"]);
  assert.equal(await db.prepare("SELECT status FROM anotacoes WHERE id = ?1").bind(a.anotacao.id).first("status"), "aplicada");

  assert.equal((await desfazerIa(env, ctx, { tx_id: "z2" })).status, 200);
  const an2 = await db.prepare("SELECT status, transacao_id FROM anotacoes WHERE id = ?1").bind(a.anotacao.id).first();
  assert.deepEqual([an2.status, an2.transacao_id], ["pendente", null]);
  assert.equal((await app("z2")).name, "MADERO");
});

test("aplicar_ia devolução: compra de outro favorecido com valor exato; recusa valor diferente, fora da janela e repetida; Desfazer grava tombstone", async () => {
  const { tx, ferramenta, env, ctx, db } = await preparar();
  await tx("r1", "acc-b", 120, HOJE, "PIX RECEBIDO MARIA SOUZA");
  await tx("c1", "acc-b", -120, ANTES(10), "PIX ENVIADO LOJA ABC");
  await tx("c2", "acc-b", -100, ANTES(5), "PIX ENVIADO LOJA ABC");
  await tx("c3", "acc-b", -120, ANTES(31), "PIX ENVIADO LOJA ABC");
  await tx("g1", "acc-b", -10, HOJE, "PADARIA");
  const r = await ferramenta("aplicar_ia", { itens: [
    { tipo: "devolucao", tx_id: "r1", reembolso_de: "c2", motivo: "x" },
    { tipo: "devolucao", tx_id: "r1", reembolso_de: "c3", motivo: "x" },
    { tipo: "devolucao", tx_id: "g1", reembolso_de: "c1", motivo: "x" },
    { tipo: "devolucao", tx_id: "r1", reembolso_de: "c1", motivo: "a Maria pagou a compra da loja" },
    { tipo: "devolucao", tx_id: "r1", reembolso_de: "c1", motivo: "x" },
  ] });
  assert.match(r.resultados[0].erro, /valor/);
  assert.match(r.resultados[1].erro, /30 dias/);
  assert.match(r.resultados[2].erro, /Pix recebido/);
  assert.equal(r.resultados[3].status, "aplicada");
  assert.match(r.resultados[4].erro, /já decidiu/);
  const linha = await db.prepare("SELECT dados FROM espelho WHERE tabela = 'mb_revisoes' AND pk = 'tx:r1' AND deleted_at IS NULL").first("dados");
  const dec = JSON.parse(JSON.parse(linha).dados);
  assert.deepEqual([dec.resposta, dec.reembolso_de, dec.ia], ["reembolso", "c1", "claude"]);
  const [item] = (await listarAplicadas(db)).itens;
  assert.deepEqual([item.origem, item.tipo, item.depois.name], ["claude", "devolucao", "Devolução: PIX ENVIADO LOJA ABC"]);

  assert.equal((await desfazerIa(env, ctx, { tx_id: "r1" })).status, 200);
  assert.notEqual(await db.prepare("SELECT deleted_at FROM espelho WHERE tabela = 'mb_revisoes' AND pk = 'tx:r1'").first("deleted_at"), null);
});

test("ia_claude = 0 desliga só aplicar_ia; enviar_resumo sai 1 vez por dia, respeita o silêncio e o tamanho", async () => {
  const { tx, mb, ferramenta, db, envios } = await preparar();
  await db.prepare("INSERT INTO config (chave, valor) VALUES ('ia_claude', '0')").run();
  await tx("g1", "acc-b", -50, HOJE, "MERCADO"); await mb("g1", "MERCADO");
  assert.equal((await ferramenta("fila_revisao")).aplicar_ia_ligado, false);
  await assert.rejects(ferramenta("aplicar_ia", { itens: [{ tipo: "classificar", tx_id: "g1", categoria: "Alimentação", motivo: "x" }] }), /ia_claude/);
  assert.equal(await db.prepare("SELECT count(*) n FROM ia_aplicacoes").first("n"), 0);

  relogio("2026-11-27T00:00:00.000Z"); // 21h BRT de 26/11
  await assert.rejects(ferramenta("enviar_resumo", { titulo: "Revisão", texto: "x".repeat(501) }), /máximo 500/);
  const r = await ferramenta("enviar_resumo", { titulo: "Revisão do dia", texto: "Classifiquei 3 gastos. Ficou 1 Pix para você." });
  assert.equal(r.enviado, true);
  assert.equal(envios.length, 1);
  assert.deepEqual(await ferramenta("enviar_resumo", { titulo: "De novo", texto: "x" }), { enviado: false, motivo: "Já enviado hoje" });
  assert.equal(envios.length, 1);
  const n = await db.prepare("SELECT chave, titulo FROM notificacoes").all();
  assert.deepEqual(n.results, [{ chave: "ia:claude:2026-11-26", titulo: "Revisão do dia" }]);

  relogio("2026-11-28T02:00:00.000Z"); // 23h BRT de 27/11
  const s = await ferramenta("enviar_resumo", { titulo: "Revisão", texto: "Nada hoje." });
  assert.equal(s.enviado, true);
  assert.match(s.push, /7h/);
  assert.equal(envios.length, 1, "em silêncio não dispara");
});

test("ia_claude = 0 com decisão pendente do Claude esperando a linha do app: a sincronização não aplica", async () => {
  const { tx, mb, ferramenta, app, status, env, ctx, db } = await preparar();
  await tx("g5", "acc-cc", 70, HOJE, "IFOOD");
  const r = await ferramenta("aplicar_ia", { itens: [{ tipo: "classificar", tx_id: "g5", categoria: "Alimentação", motivo: "app de comida" }] });
  assert.match(r.resultados[0].status, /aguardando/);
  await db.prepare("INSERT INTO config (chave, valor) VALUES ('ia_claude', '0')").run();
  await mb("g5", "IFOOD");
  await aplicarPendentesIa(env, ctx);
  assert.equal(await status("g5"), "pendente");
  assert.equal((await app("g5")).category_fk, null);
  await db.prepare("UPDATE config SET valor = '1' WHERE chave = 'ia_claude'").run();
  await aplicarPendentesIa(env, ctx);
  assert.equal(await status("g5"), "aplicada");
  assert.equal((await app("g5")).category_fk, "c-alim");
});

test("aplicar_ia devolução: reserva em conflito (outra origem decidiu no meio) é recusada e não grava mb_revisoes", async () => {
  const { tx, env, ctx, db, decisao } = await preparar();
  await tx("r1", "acc-b", 120, HOJE, "PIX RECEBIDO MARIA SOUZA");
  await tx("c1", "acc-b", -120, ANTES(10), "PIX ENVIADO LOJA ABC");
  await decisao("r1", "llama", "sombra", { category_fk: "c-alim" }, 0.5);
  // 2ª conferência "já respondido" é a última antes da reserva: a regra decide o Pix ali.
  const amb = corrida(env, "tabela = 'mb_revisoes' AND pk = ?1", () => db.prepare("UPDATE ia_aplicacoes SET origem = 'regra', status = 'aplicada' WHERE tx_id = 'r1'").run(), 2);
  const r = await aplicarClaude(amb, ctx, [{ tipo: "devolucao", tx_id: "r1", reembolso_de: "c1", motivo: "x" }]);
  assert.equal(r.resultados[0].ok, false);
  assert.match(r.resultados[0].erro, /acabou de decidir/);
  assert.equal(await db.prepare("SELECT count(*) n FROM espelho WHERE tabela = 'mb_revisoes'").first("n"), 0);
  assert.equal(await db.prepare("SELECT origem FROM ia_aplicacoes WHERE tx_id = 'r1'").first("origem"), "regra");
});

test("transação com anotação vinculada: recusada em classificar e fora de para_classificar", async () => {
  const { tx, mb, ferramenta, status, db } = await preparar();
  const a = await ferramenta("anotar_gasto", { valor: 50, descricao: "mercado", titulo: "Mercado", categoria: "Alimentação" });
  await tx("g1", "acc-b", -50, HOJE, "MERCADO X"); await mb("g1", "MERCADO X");
  await tx("g2", "acc-b", -30, HOJE, "UBER"); await mb("g2", "UBER");
  await db.prepare("UPDATE anotacoes SET status = 'vinculada', transacao_id = 'g1' WHERE id = ?1").bind(a.anotacao.id).run();
  assert.deepEqual((await ferramenta("fila_revisao")).para_classificar.map((t) => t.tx_id), ["g2"]);
  const r = await ferramenta("aplicar_ia", { itens: [{ tipo: "classificar", tx_id: "g1", categoria: "Alimentação", motivo: "x" }] });
  assert.equal(r.resultados[0].ok, false);
  assert.match(r.resultados[0].erro, /anotação/);
  assert.equal(await status("g1"), null);
});

test("aplicar_ia: item descartado porque a linha foi editada no app no meio vem como recusa e não conta em aplicadas", async () => {
  const { tx, mb, env, ctx, db, app, status } = await preparar();
  await tx("g1", "acc-b", -50, HOJE, "MERCADO X"); await mb("g1", "MERCADO X");
  await tx("g2", "acc-b", -20, HOJE, "PADARIA"); await mb("g2", "PADARIA");
  // o Renan edita a g1 no app entre a gravação da decisão e a aplicação
  const amb = corrida(env, "INSERT INTO ia_aplicacoes", async () => {
    const d = { ...JSON.parse(await db.prepare("SELECT dados FROM espelho WHERE pk = 'mb:g1'").first("dados")), name: "Meu mercado", date_time_modified: 1764000000 };
    await db.prepare("UPDATE espelho SET dados = ?1 WHERE pk = 'mb:g1'").bind(JSON.stringify(d)).run();
  });
  const r = await aplicarClaude(amb, ctx, [
    { tipo: "classificar", tx_id: "g1", category_fk: "c-alim", motivo: "x" },
    { tipo: "classificar", tx_id: "g2", category_fk: "c-alim", motivo: "x" },
  ]);
  assert.deepEqual(r.resultados.map((x) => x.ok), [false, true]);
  assert.match(r.resultados[0].erro, /Editada no app/);
  assert.deepEqual([r.aplicadas, r.recusadas], [1, 1]);
  assert.equal(await status("g1"), "descartada");
  assert.equal((await app("g1")).name, "Meu mercado");
});
