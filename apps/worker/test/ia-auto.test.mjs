// test/ia-auto.test.mjs — IA automática, fase 1 (docs/ia-automatica-plano.md, "Critérios de aceite"): memória por favorecido,
// decisão no fim da sincronização, modo sombra do Llama, "Feito pela IA" com Desfazer e o push em lote.
// Relógio fixo: terça 10/11/2026 12h BRT (fora do silêncio); cada passo do "app" anda 1 s para o LWW não empatar.
import { test, mock, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, simularPluggy, restaurarFetch, hubMudo, MODOS, nomeDoModo, entrarComSenha, ORIGEM } from "./ambiente.mjs";
import { registrarItem } from "../src/pluggy.js";
import { chavePadrao } from "../src/iaAuto.js";
import { alertaIa } from "../src/alertas.js";

const ID = "33333333-3333-4333-8333-333333333333";
const T0 = Date.parse("2026-11-10T15:00:00.000Z");
const HOJE = "2026-11-10";
const relogio = (iso) => { mock.timers.reset(); mock.timers.enable({ apis: ["Date"], now: Date.parse(iso) }); };
const andar = (ms = 1000) => relogio(new Date(Date.now() + ms).toISOString());
afterEach(() => { restaurarFetch(); mock.timers.reset(); });

// Llama falso: devolve, para cada lançamento, a categoria C2 (Lazer) com a confiança pedida; `null` = Workers AI fora do ar.
const llama = (confianca = 0.95) => {
  const chamadas = [];
  return { chamadas, run: async (_m, o) => {
    chamadas.push(o);
    if (confianca === null) throw new Error("5007: No such model");
    return { response: { sugestoes: Array.from({ length: 8 }, (_, i) => ({ n: i + 1, categoria: "C2", subcategoria: "", titulo: "Show", vinculo: "", confianca, pergunta: "" })) } };
  } };
};

async function preparar({ espelho = true, ai = llama(), extra = {} } = {}) {
  relogio(new Date(T0).toISOString());
  const amb = criarAmbiente({ PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo", ...(espelho ? { ESPELHO: "1", ESPELHO_HUB: hubMudo() } : {}), ...(ai ? { AI: ai } : {}), ...extra });
  const db = amb.env.DB;
  await registrarItem(db, ID, "2026-11-01T00:00:00.000Z");
  const auth = { authorization: "Bearer " + (await criarAparelho(amb.env)), "content-type": "application/json" };
  const pluggy = simularPluggy((u) => {
    if (u.pathname.startsWith("/items/")) return { id: ID, status: "UPDATED", connector: { name: "Inter" } };
    if (u.pathname === "/accounts") return { results: [{ id: "cc", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta Inter", balance: 500 }] };
    if (u.host === "push.test") return new Response(null, { status: 201 });
    return { results: [] };
  });
  const ts = new Date().toISOString();
  const linha = (tabela, pk, dados) => db.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) VALUES (?1, ?2, ?3, ?4, NULL, ?4, 'cel')").bind(tabela, pk, JSON.stringify(dados), ts);
  if (espelho) await db.batch([
    db.prepare("INSERT INTO espelho_meta (chave, valor) VALUES ('semeado', '1')"),
    linha("categories", "c-alim", { name: "Alimentação", income: 0, main_category_pk: null, archived: 0, order: 1 }),
    linha("categories", "c-rest", { name: "Restaurante", income: 0, main_category_pk: "c-alim", archived: 0, order: 2 }),
    linha("categories", "c-lazer", { name: "Lazer", income: 0, main_category_pk: null, archived: 0, order: 3 }),
    linha("categories", "c-sal", { name: "Salário", income: 1, main_category_pk: null, archived: 0, order: 4 }),
  ]);
  const gasto = (id, desc, valor = 40) =>
    db.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES (?1, 'cc', ?2, ?3, ?4, 'DEBIT', 'POSTED', 0, ?5)").bind(id, HOJE, desc, -valor, new Date().toISOString()).run();
  const sincronizar = async () => {
    await db.prepare("DELETE FROM sync_log").run();
    await amb.worker.scheduled({ scheduledTime: Date.now() }, amb.env, amb.ctx);
    await amb.esperar();
  };
  const post = async (caminho, corpo) => { andar(); const r = await amb.pedir(caminho, { method: "POST", headers: auth, body: JSON.stringify(corpo) }); await amb.esperar(); return r; };
  const get = async (caminho) => (await amb.pedir(caminho, { headers: auth })).json();
  // O app importa a transação (sem edição) ou o usuário a classifica (date_time_modified = agora, em segundos).
  const app = (id, desc, { cat = "c-sem", sub = null, nome = desc, editada = false } = {}) => post("/api/espelho", { linhas: [{
    tabela: "transactions", pk: "mb:" + id, updated_at: new Date(Date.now() + 1000).toISOString(), deleted_at: null,
    dados: { name: nome, amount: -40, category_fk: cat, sub_category_fk: sub, date_time_modified: editada ? Math.floor((Date.now() + 1000) / 1000) : null, note: "" } }] });
  const tx = async (id) => JSON.parse((await db.prepare("SELECT dados FROM espelho WHERE tabela = 'transactions' AND pk = ?1").bind("mb:" + id).first("dados")) ?? "null");
  const decisao = (id) => db.prepare("SELECT * FROM ia_aplicacoes WHERE tx_id = ?1").bind(id).first();
  const memoria = (chave) => db.prepare("SELECT * FROM ia_memoria WHERE chave = ?1").bind(chave).first();
  // Usuário confirma o favorecido duas vezes no app (duas transações diferentes).
  const confirmar2x = async (desc, cat = "c-alim", sub = "c-rest", nome = "Almoço") => {
    for (const id of ["h1", "h2"]) { await gasto(id + desc.length, desc); await app(id + desc.length, desc); await app(id + desc.length, desc, { cat, sub, nome, editada: true }); }
  };
  return { ...amb, db, auth, pluggy, gasto, sincronizar, post, get, app, tx, decisao, memoria, confirmar2x, ai };
}

test("chave do favorecido igual a mbChavePadrao do app", () => {
  assert.equal(chavePadrao("PIX ENVIADO - Fabiana Silva 123"), "FABIANA SILVA");
  assert.equal(chavePadrao("Pix enviado Fabiana Silva"), "FABIANA SILVA");
  assert.equal(chavePadrao("Compra no débito IFOOD *IFD Agência São Paulo"), "IFOOD IFD AGENCIA SAO");
  assert.equal(chavePadrao("UBER *TRIP"), "UBER TRIP");
  assert.equal(chavePadrao("123 - *"), "");
});

test("favorecido confirmado 2x: a próxima transação é aplicada direto e aparece em Feito pela IA", async () => {
  const t = await preparar();
  await t.confirmar2x("IFOOD *SUSHI");
  assert.equal((await t.memoria("IFOOD SUSHI")).confirmacoes, 2);
  await t.gasto("n1", "IFOOD *SUSHI");
  await t.sincronizar();
  assert.equal((await t.decisao("n1")).status, "pendente", "espera o app mandar a linha mb:");
  await t.app("n1", "IFOOD *SUSHI");
  const d = await t.tx("n1");
  assert.deepEqual([d.category_fk, d.sub_category_fk, d.name], ["c-alim", "c-rest", "Almoço"]);
  assert.ok(d.date_time_modified >= 978307200, "o app mostra como classificada");
  assert.equal((await t.memoria("IFOOD SUSHI")).confirmacoes, 2, "a aplicação da IA não conta como confirmação");
  const { itens } = await t.get("/api/ia/aplicadas");
  assert.deepEqual(itens.map(({ tx_id, origem, status, antes, depois }) => ({ tx_id, origem, status, antes, depois })), [{
    tx_id: "n1", origem: "memoria", status: "aplicada",
    antes: { name: "IFOOD *SUSHI", category_fk: "c-sem", sub_category_fk: null },
    depois: { name: "Almoço", category_fk: "c-alim", sub_category_fk: "c-rest" },
  }]);
  assert.ok(itens[0].criado_em && itens[0].aplicado_em);
  // Linha mb: que já estava no espelho: aplicada na própria sincronização.
  await t.gasto("n2", "IFOOD *SUSHI");
  await t.app("n2", "IFOOD *SUSHI");
  await t.sincronizar();
  assert.equal((await t.decisao("n2")).status, "aplicada");
  assert.equal((await t.tx("n2")).category_fk, "c-alim");
  assert.equal((await t.get("/api/ia/aplicadas?desde=2030-01-01T00:00:00.000Z")).itens.length, 0);
});

test("regra do usuário (associated_titles) aplica sem mudar o título", async () => {
  const t = await preparar();
  await t.db.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, server_at, aparelho) VALUES ('associated_titles', 'a1', ?1, 'x', 'x', 'cel')")
    .bind(JSON.stringify({ title: "NETFLIX", is_exact_match: 0, category_fk: "c-lazer" })).run();
  await t.gasto("r1", "NETFLIX.COM 0800");
  await t.app("r1", "NETFLIX.COM 0800");
  await t.sincronizar();
  const d = await t.tx("r1");
  assert.deepEqual([d.category_fk, d.name], ["c-lazer", "NETFLIX.COM 0800"]);
  assert.equal((await t.decisao("r1")).origem, "regra");
  assert.equal(t.ai.chamadas.length, 0, "regra não gasta o Llama");
});

test("Desfazer restaura, a transação volta à fila e a memória deixa de aplicar; 404 e 409", async () => {
  const t = await preparar();
  await t.confirmar2x("IFOOD *SUSHI");
  await t.gasto("n1", "IFOOD *SUSHI");
  await t.app("n1", "IFOOD *SUSHI");
  await t.sincronizar();
  const r = await t.post("/api/ia/desfazer", { tx_id: "n1" });
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { ok: true });
  const d = await t.tx("n1");
  assert.deepEqual([d.category_fk, d.sub_category_fk, d.name, d.date_time_modified], ["c-sem", null, "IFOOD *SUSHI", null], "sem date_time_modified: volta à fila");
  assert.equal((await t.memoria("IFOOD SUSHI")).confirmacoes, 0);
  assert.equal((await t.post("/api/ia/desfazer", { tx_id: "n1" })).status, 409);
  assert.equal((await t.post("/api/ia/desfazer", { tx_id: "nada" })).status, 404);
  assert.equal((await t.get("/api/ia/aplicadas")).itens[0].status, "desfeita");
  await t.sincronizar();
  assert.equal((await t.tx("n1")).category_fk, "c-sem", "a decisão desfeita não volta");
  await t.gasto("n2", "IFOOD *SUSHI");
  await t.sincronizar();
  assert.equal((await t.decisao("n2")).status, "sombra", "memória zerada: vai para o Llama, que só registra");
  // Sem credencial → 401; app web (cookie) com outra origem → 403; mesma origem e então chega ao desfazer de verdade (404 = tx inexistente).
  assert.equal((await t.pedir("/api/ia/desfazer", { method: "POST", body: "{}" })).status, 401);
  const cookie = await entrarComSenha(t.pedir);
  const corpo = JSON.stringify({ tx_id: "nao-existe" });
  assert.equal((await t.pedir("/api/ia/desfazer", { method: "POST", headers: { cookie, origin: "https://outro.test", "content-type": "application/json" }, body: corpo })).status, 403);
  assert.equal((await t.pedir("/api/ia/desfazer", { method: "POST", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: corpo })).status, 404);
});

test("Desfazer não apaga a correção do usuário nem ressuscita linha apagada", async () => {
  const t = await preparar();
  await t.confirmar2x("IFOOD *SUSHI");
  for (const id of ["n1", "n2"]) { await t.gasto(id, "IFOOD *SUSHI"); await t.app(id, "IFOOD *SUSHI"); }
  await t.sincronizar();
  assert.equal((await t.decisao("n1")).status, "aplicada");
  // n1: o usuário corrige depois da IA (Corrigir) e depois toca Desfazer.
  await t.app("n1", "IFOOD *SUSHI", { cat: "c-lazer", nome: "Jantar", editada: true });
  const r = await t.post("/api/ia/desfazer", { tx_id: "n1" });
  assert.equal(r.status, 412);
  assert.deepEqual([(await t.tx("n1")).category_fk, (await t.tx("n1")).name], ["c-lazer", "Jantar"], "a correção do usuário fica");
  assert.equal((await t.decisao("n1")).status, "aplicada");
  // n2: apagada no app depois da IA.
  await t.post("/api/espelho", { linhas: [{ tabela: "transactions", pk: "mb:n2", updated_at: new Date(Date.now() + 1000).toISOString(), deleted_at: new Date().toISOString(), dados: null }] });
  assert.equal((await t.post("/api/ia/desfazer", { tx_id: "n2" })).status, 410);
  assert.equal(await t.tx("n2"), null, "continua apagada");
});

test("favorecido novo: Llama em modo sombra, nada muda no app; a classificação do usuário marca acerto e entra no relatório", async () => {
  const t = await preparar();
  await t.gasto("s1", "TICKETMASTER BR"); await t.gasto("s2", "EVENTIM SP");
  await t.app("s1", "TICKETMASTER BR"); await t.app("s2", "EVENTIM SP");
  await t.sincronizar();
  assert.equal(t.ai.chamadas.length, 1, "um lote só");
  assert.equal((await t.decisao("s1")).status, "sombra");
  assert.equal((await t.tx("s1")).category_fk, "c-sem");
  assert.deepEqual((await t.get("/api/ia/aplicadas")).itens, [], "sombra nunca aparece");
  await t.app("s1", "TICKETMASTER BR", { cat: "c-lazer", editada: true }); // acertou
  await t.app("s2", "EVENTIM SP", { cat: "c-alim", editada: true }); // errou
  assert.equal((await t.decisao("s1")).acerto, 1);
  assert.equal((await t.decisao("s2")).acerto, 0);
  const rel = await t.get("/api/ia/relatorio");
  assert.deepEqual(rel.faixas.map((f) => [f.de, f.ate, f.total, f.acertos]), [[0.7, 0.8, 0, 0], [0.8, 0.9, 0, 0], [0.9, 1, 2, 1]]);
  assert.equal(rel.faixas[2].taxa, 0.5);
  assert.equal(rel.aguardando, 0);
  assert.equal((await t.memoria("TICKETMASTER BR")).confirmacoes, 1, "a classificação também alimenta a memória");
});

test("ia_limiar definido: Llama acima do limiar aplica; abaixo fica em sombra", async () => {
  const t = await preparar({ ai: llama(0.85) });
  await t.db.prepare("INSERT INTO config (chave, valor) VALUES ('ia_limiar', '0.8')").run();
  await t.gasto("l1", "TICKETMASTER BR");
  await t.app("l1", "TICKETMASTER BR");
  await t.sincronizar();
  assert.equal((await t.decisao("l1")).origem, "llama");
  assert.equal((await t.tx("l1")).category_fk, "c-lazer");
  await t.db.prepare("UPDATE config SET valor = '0.9' WHERE chave = 'ia_limiar'").run();
  await t.gasto("l2", "EVENTIM SP");
  await t.sincronizar();
  assert.equal((await t.decisao("l2")).status, "sombra");
});

test("linha já editada pelo usuário nunca é sobrescrita", async () => {
  const t = await preparar();
  await t.confirmar2x("IFOOD *SUSHI");
  await t.gasto("e1", "IFOOD *SUSHI");
  await t.app("e1", "IFOOD *SUSHI", { cat: "c-alim", sub: "c-rest", nome: "Presente", editada: true }); // mesma escolha: memória vai a 3
  await t.gasto("e2", "IFOOD *SUSHI");
  await t.sincronizar();
  assert.equal(await t.decisao("e1"), null, "editada antes da decisão: nem entra");
  assert.equal((await t.tx("e1")).name, "Presente");
  assert.equal((await t.decisao("e2")).status, "pendente");
  await t.app("e2", "IFOOD *SUSHI", { cat: "c-lazer", nome: "Presente", editada: true }); // chega já editada
  const d = await t.tx("e2");
  assert.deepEqual([d.category_fk, d.name], ["c-lazer", "Presente"]);
  assert.equal((await t.decisao("e2")).status, "descartada");
  assert.deepEqual((await t.get("/api/ia/aplicadas")).itens, []);
});

test("Workers AI fora do ar: a sincronização segue sem erro e nada é registrado", async () => {
  const t = await preparar({ ai: llama(null) });
  await t.gasto("f1", "TICKETMASTER BR");
  await t.sincronizar();
  assert.equal(await t.db.prepare("SELECT ok FROM sync_log").first("ok"), 1);
  assert.equal(await t.decisao("f1"), null, "fica para a próxima");
  t.ai.run = llama(0.95).run;
  await t.sincronizar();
  assert.equal((await t.decisao("f1")).status, "sombra");
});

test("kill switch ia_auto = 0 (linha _config do espelho) desliga a decisão", async () => {
  const t = await preparar();
  await t.confirmar2x("IFOOD *SUSHI");
  await t.db.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, server_at, aparelho) VALUES ('_config', 'ia_auto', '{\"v\":\"0\"}', 'x', 'x', 'cel')").run();
  await t.gasto("k1", "IFOOD *SUSHI");
  await t.app("k1", "IFOOD *SUSHI");
  await t.sincronizar();
  assert.equal(await t.decisao("k1"), null);
  assert.equal((await t.tx("k1")).category_fk, "c-sem");
  assert.equal(t.ai.chamadas.length, 0);
});

for (const espelho of MODOS) test(`flag do espelho ${nomeDoModo(espelho)}: só decide com o espelho ligado; os endpoints respondem`, async () => {
  const t = await preparar({ espelho });
  if (espelho) await t.confirmar2x("IFOOD *SUSHI");
  else await t.db.prepare("INSERT INTO ia_memoria (chave, category_fk, confirmacoes, atualizado_em) VALUES ('IFOOD SUSHI', 'c-alim', 5, 'x')").run();
  await t.gasto("m1", "IFOOD *SUSHI");
  await t.sincronizar();
  assert.equal((await t.decisao("m1"))?.status ?? null, espelho ? "pendente" : null);
  assert.equal(await t.db.prepare("SELECT ok FROM sync_log").first("ok"), 1);
  assert.ok(Array.isArray((await t.get("/api/ia/aplicadas")).itens));
  assert.equal((await t.get("/api/ia/relatorio")).faixas.length, 3);
});

test("importação da memória do aparelho: merge mantém o maior número de confirmações", async () => {
  const t = await preparar();
  await t.db.prepare("INSERT INTO ia_memoria (chave, category_fk, sub_category_fk, nome, confirmacoes, atualizado_em) VALUES ('UBER TRIP', 'c-lazer', NULL, NULL, 3, 'x'), ('PADARIA', 'c-alim', NULL, NULL, 1, 'x')").run();
  const r = await t.post("/api/ia/memoria", { padroes: [
    { chave: "UBER TRIP", category_fk: "c-alim", sub_category_fk: null, nome: "Uber", confirmacoes: 2 }, // servidor tem mais: fica
    { chave: "PADARIA", category_fk: "c-alim", sub_category_fk: "c-rest", nome: "Pão", confirmacoes: 4 }, // importada tem mais: troca
    { chave: "CINEMA", category_fk: "c-lazer", sub_category_fk: null, nome: null, confirmacoes: 2 }, // nova
    { chave: "", category_fk: "c-lazer", confirmacoes: 9 }, // inválida
  ] });
  assert.deepEqual(await r.json(), { importados: 2 });
  assert.deepEqual([(await t.memoria("UBER TRIP")).category_fk, (await t.memoria("UBER TRIP")).confirmacoes], ["c-lazer", 3]);
  assert.deepEqual([(await t.memoria("PADARIA")).sub_category_fk, (await t.memoria("PADARIA")).confirmacoes], ["c-rest", 4]);
  assert.equal((await t.memoria("CINEMA")).confirmacoes, 2);
  assert.equal((await t.post("/api/ia/memoria", { padroes: "x" })).status, 400);
  await t.gasto("u1", "CINEMA");
  await t.sincronizar();
  assert.equal((await t.decisao("u1")).origem, "memoria", "importada com 2 confirmações já aplica");
});

test("5 aplicações às 23h viram 1 push às 7h, que abre Feito pela IA", async () => {
  const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const t = await preparar({ extra: { VAPID_PRIVADA: JSON.stringify(await crypto.subtle.exportKey("jwk", par.privateKey)), VAPID_PUBLICA: "pub", VAPID_ASSUNTO: "mailto:a@b.c" } });
  await t.db.prepare("INSERT INTO push_inscricoes (endpoint, criada) VALUES ('https://push.test/abc', 'x')").run();
  await t.confirmar2x("IFOOD *SUSHI");
  await t.sincronizar();
  const toques = () => t.pluggy.chamadas.filter((c) => c.caminho === "/abc").length;
  const antes = toques();
  relogio("2026-11-11T02:07:00.000Z"); // 23:07 BRT
  for (let i = 1; i <= 5; i++) { await t.gasto("p" + i, "IFOOD *SUSHI"); await t.app("p" + i, "IFOOD *SUSHI"); }
  relogio("2026-11-11T02:10:00.000Z");
  await t.sincronizar();
  assert.equal(await t.db.prepare("SELECT count(*) n FROM ia_aplicacoes WHERE status = 'aplicada'").first("n"), 5);
  assert.equal(toques(), antes);
  assert.equal(await t.db.prepare("SELECT count(*) n FROM notificacoes WHERE chave LIKE 'ia:%'").first("n"), 0);
  relogio("2026-11-11T04:07:00.000Z"); // 01:07
  await t.sincronizar();
  assert.equal(toques(), antes);
  relogio("2026-11-11T10:07:00.000Z"); // 07:07
  await t.sincronizar();
  assert.equal(toques(), antes + 1);
  const ia = (await t.db.prepare("SELECT chave, titulo, corpo FROM notificacoes WHERE chave LIKE 'ia:%'").all()).results;
  assert.equal(ia.length, 1);
  assert.equal(ia[0].titulo, "5 gastos classificados pela IA");
  const r = await t.get("/api/notificacoes?desde=" + encodeURIComponent("2026-11-11T00:00:00.000Z"));
  const n = r.notificacoes.find((x) => x.chave.startsWith("ia:"));
  assert.deepEqual(n.item, { tipo: "ia_aplicadas", desde: ia[0].chave.slice(3) });
  assert.equal((await t.get("/api/ia/aplicadas?desde=" + encodeURIComponent(n.item.desde))).itens.length, 5);
  await t.sincronizar();
  assert.equal(await t.db.prepare("SELECT count(*) n FROM notificacoes WHERE chave LIKE 'ia:%'").first("n"), 1, "nada repete");
});

test("alertaIa: singular, desfeita não conta e silêncio segura", () => {
  const dia = "2026-11-10T15:00:00.000Z";
  assert.equal(alertaIa({ aplicadas: [{ tx_id: "a", status: "aplicada", aplicado_em: dia }], agora: dia }).alertas[0].titulo, "1 gasto classificado pela IA");
  assert.deepEqual(alertaIa({ aplicadas: [{ tx_id: "a", status: "desfeita", aplicado_em: dia }], agora: dia }), { alertas: [], avisadas: ["a"] });
  assert.deepEqual(alertaIa({ aplicadas: [{ tx_id: "a", status: "aplicada", aplicado_em: dia }], agora: "2026-11-11T02:00:00.000Z" }), { alertas: [], avisadas: [] });
});

test("transação PENDING não gera decisão; ao postar (id novo) ganha a sua", async () => {
  const t = await preparar();
  await t.db.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES ('p1', 'cc', ?1, 'TICKETMASTER BR', -40, 'DEBIT', 'PENDING', 0, ?2)").bind(HOJE, new Date().toISOString()).run();
  await t.app("p1", "TICKETMASTER BR");
  await t.sincronizar();
  assert.equal(await t.decisao("p1"), null);
  assert.equal(t.ai.chamadas.length, 0, "nem o Llama é chamado");
  await t.gasto("p2", "TICKETMASTER BR"); await t.app("p2", "TICKETMASTER BR");
  await t.sincronizar();
  assert.equal((await t.decisao("p2")).status, "sombra");
});

test("sombra (sem ia_limiar) roda o Llama em segundo plano via waitUntil e ainda é registrada", async () => {
  const t = await preparar();
  await t.gasto("w1", "EVENTIM SP"); await t.app("w1", "EVENTIM SP");
  await t.db.prepare("DELETE FROM sync_log").run();
  const tarefas = [];
  await t.worker.scheduled({ scheduledTime: Date.now() }, t.env, { waitUntil: (p) => tarefas.push(p) });
  await Promise.allSettled(tarefas);
  assert.equal((await t.decisao("w1")).status, "sombra");
});
