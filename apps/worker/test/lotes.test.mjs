// test/lotes.test.mjs — notificações de ponta a ponta: o cron sincroniza, o Worker avalia e o aparelho (ou o Web Push) entrega.
// Relógio fixo: terça 10/11/2026 12h BRT, fora do silêncio.
import { test, mock, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, entrarComSenha, simularPluggy, restaurarFetch, ORIGEM, MODOS, extraDoModo, nomeDoModo } from "./ambiente.mjs";
import { registrarItem } from "../src/pluggy.js";

const ID = "33333333-3333-4333-8333-333333333333";
const ENV = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo" };
const T0 = Date.parse("2026-11-10T15:00:00.000Z");
const HOJE = "2026-11-10";
const sp = (s) => s.replace(/ /g, " ");
const relogio = (iso) => { mock.timers.reset(); mock.timers.enable({ apis: ["Date"], now: Date.parse(iso) }); };
afterEach(() => { restaurarFetch(); mock.timers.reset(); });

// espelho = true: ESPELHO ligado e os orçamentos vêm das linhas `budgets` do espelho (não de `registros`).
async function preparar({ geral = 1000, statusItem = () => "UPDATED", extra = {}, espelho = false } = {}) {
  mock.timers.reset();
  mock.timers.enable({ apis: ["Date"], now: T0 });
  const amb = criarAmbiente({ ...ENV, ...extraDoModo(espelho), ...extra });
  const db = amb.env.DB;
  await registrarItem(db, ID, "2026-11-01T00:00:00.000Z");
  const auth = { authorization: "Bearer " + (await criarAparelho(amb.env)) };
  const ts = new Date().toISOString();
  const pluggy = simularPluggy((u) => {
    if (u.pathname.startsWith("/items/")) return { id: ID, status: statusItem(), connector: { name: "Inter" } };
    if (u.pathname === "/accounts") return { results: [{ id: "cc", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta Inter", balance: 500 }] };
    if (u.host === "push.test") return new Response(null, { status: 201 });
    return { results: [] };
  });
  const orcamento = (pk, nome, valor) => espelho
    ? db.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) VALUES ('budgets', ?1, ?2, ?3, NULL, ?3, 'celular')").bind(pk, JSON.stringify({ name: nome, amount: valor, category_fks: "[]" }), ts)
    : db.prepare("INSERT INTO registros (tabela, id, dados, updated_at, server_at) VALUES ('orcamentos', ?1, ?2, ?3, ?3)").bind("cashew:" + pk, JSON.stringify({ nome, valor, categoria_ids: [], periodo: "ciclo" }), ts);
  const stmts = [
    orcamento("mb:orc:geral", "Geral", geral),
    ...(espelho ? [db.prepare("INSERT INTO espelho_meta (chave, valor) VALUES ('semeado', '1')")] : []),
    ...[["s1", "2026-09-01"], ["s2", "2026-10-05"], ["s3", "2026-11-05"]].map(([id, d]) =>
      db.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES (?1, 'cc', ?2, 'SALARIO EMPRESA', 7500, 'CREDIT', 'POSTED', 0, ?3)").bind(id, d, ts)),
  ];
  await db.batch(stmts);
  const gasto = (id, valor, desc = "MERCADO", data = HOJE) =>
    db.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES (?1, 'cc', ?2, ?3, ?4, 'DEBIT', 'POSTED', 0, ?5)").bind(id, data, desc, -valor, new Date().toISOString()).run();
  const sincronizar = async (hora = null) => { // um tick do cron (sem esperar a trava de 10 min do sync_log)
    await db.prepare("DELETE FROM sync_log").run();
    await amb.worker.scheduled({ scheduledTime: hora ?? Date.now() }, amb.env, amb.ctx);
    await amb.esperar();
  };
  const alertas = async (like = "%") => (await db.prepare("SELECT chave, titulo, corpo FROM notificacoes WHERE chave LIKE ?1 ORDER BY criada").bind(like).all()).results.map((a) => ({ ...a, titulo: sp(a.titulo), corpo: sp(a.corpo) }));
  const celular = async (desde) => (await (await amb.pedir("/api/notificacoes?desde=" + encodeURIComponent(desde), { headers: auth })).json());
  return { ...amb, db, auth, pluggy, gasto, sincronizar, alertas, celular, orcamento };
}

for (const espelho of MODOS) test(`lote: várias compras entre dois ticks viram uma notificação com quanto falta no Geral ${nomeDoModo(espelho)}`, async () => {
  const t = await preparar({ espelho });
  await t.sincronizar(); // 1ª avaliação: só registra o que já existe
  assert.deepEqual(await t.alertas("compras:%"), []);
  await t.gasto("c1", 50); await t.gasto("c2", 30, "PADARIA"); await t.gasto("c3", 40, "FARMACIA");
  await t.sincronizar();
  const [lote, ...resto] = await t.alertas("compras:%");
  assert.deepEqual(resto, []);
  assert.equal(lote.titulo, "3 compras, R$ 120,00");
  assert.equal(lote.corpo, "Faltam R$ 880,00 no Geral até 04/12.");
  await t.sincronizar(); // mesmo estado: nada de novo
  assert.equal((await t.alertas("compras:%")).length, 1);
  mock.timers.tick(3 * 3600_000); // próximo tick do cron
  await t.gasto("c4", 25.5, "CAFE");
  await t.sincronizar();
  assert.equal((await t.alertas("compras:%")).at(-1).titulo, "1 compra, R$ 25,50");
});

for (const espelho of MODOS) test(`80% e 100% do Geral: uma vez por ciclo cada, sem repetir a cada sincronização ${nomeDoModo(espelho)}`, async () => {
  const t = await preparar({ geral: 300, espelho });
  await t.sincronizar();
  await t.gasto("a", 250); // 83%
  await t.sincronizar(); await t.sincronizar();
  assert.deepEqual((await t.alertas("orc%")).map((a) => a.chave), ["orc80:cashew:mb:orc:geral:2026-11-05"]);
  await t.gasto("b", 100); // 350 > 300
  await t.sincronizar(); await t.sincronizar();
  assert.deepEqual((await t.alertas("orc%")).map((a) => a.chave), ["orc80:cashew:mb:orc:geral:2026-11-05", "orc100:cashew:mb:orc:geral:2026-11-05"]);
  assert.match((await t.alertas("orc100%"))[0].corpo, /R\$ 50,00 acima/);
});

for (const espelho of MODOS) test(`outro orçamento estourado não gera aviso (só o Geral) ${nomeDoModo(espelho)}`, async () => {
  const t = await preparar({ espelho });
  await t.orcamento("o1", "Mercado", 10).run();
  await t.sincronizar();
  await t.gasto("a", 200);
  await t.sincronizar();
  assert.deepEqual(await t.alertas("orc%"), []);
});

test("fatura do Inter 3 dias antes; Santander fica de fora; não repete", async () => {
  const t = await preparar();
  const ts = new Date().toISOString();
  await t.db.batch([
    t.db.prepare("INSERT INTO accounts (id, type, name, bank, balance, due_date, updated_at) VALUES ('inter-cc', 'CREDIT', 'Cartão Inter', 'Inter', 800, '2026-11-13', ?1)").bind(ts),
    t.db.prepare("INSERT INTO accounts (id, type, name, bank, balance, due_date, updated_at) VALUES ('st-cc', 'CREDIT', 'Cartão Santander', 'Santander', 900, '2026-11-13', ?1)").bind(ts),
  ]);
  await t.sincronizar(); await t.sincronizar();
  const f = await t.alertas("fatura:%");
  assert.deepEqual(f.map((a) => a.chave), ["fatura:inter-cc:2026-11-13"]);
  assert.equal(f[0].titulo, "Fatura do Cartão Inter vence em 3 dias");
  assert.equal(f[0].corpo, "R$ 800,00 · vence 13/11");
});

test("queda de conexão: uma notificação por queda, o aviso fica na Início e uma nova queda avisa de novo", async () => {
  let status = "LOGIN_ERROR";
  const t = await preparar({ statusItem: () => status });
  await t.sincronizar(); await t.sincronizar();
  const q = await t.alertas("conexao:%");
  assert.equal(q.length, 1);
  assert.match(q[0].titulo, /desconectou$/);
  const sync = await (await t.pedir("/api/sync", { headers: t.auth })).json();
  assert.equal(sync.avisos[0].item_id, ID); // o app lê daqui o banner com "Reconectar"
  status = "UPDATED";
  mock.timers.tick(3 * 3600_000);
  await t.sincronizar();
  assert.equal((await t.alertas("conexao:%")).length, 1);
  mock.timers.tick(3 * 3600_000);
  status = "WAITING_USER_INPUT"; // outra queda, agora aguardando o login
  await t.sincronizar();
  assert.equal((await t.alertas("conexao:%")).length, 2);
});

test("silêncio 22h–7h: o aparelho não recebe nada e às 7h recebe tudo agrupado; bordas 21:59, 22:00, 06:59 e 07:00", async () => {
  const t = await preparar();
  await t.sincronizar();
  const desde = new Date(T0 - 1000).toISOString();
  relogio("2026-11-11T00:50:00.000Z"); // 21:50 BRT
  await t.gasto("n1", 60);
  await t.sincronizar(); // lote criado às 21:50
  relogio("2026-11-11T00:59:00.000Z"); // 21:59
  assert.equal((await t.celular(desde)).notificacoes.length, 1);
  relogio("2026-11-11T01:00:00.000Z"); // 22:00
  assert.deepEqual(await t.celular(desde).then((r) => [r.notificacoes, r.cursor]), [[], desde]);
  relogio("2026-11-11T01:07:00.000Z");
  await t.gasto("n2", 40, "TAXI", "2026-11-10");
  await t.sincronizar(); // 22:07: o alerta é gravado, mas não sai
  relogio("2026-11-11T04:07:00.000Z");
  await t.gasto("n3", 20, "CAFE", "2026-11-10");
  await t.sincronizar(); // 01:07: idem
  relogio("2026-11-11T09:59:00.000Z"); // 06:59
  assert.equal((await t.celular(desde)).notificacoes.length, 0);
  relogio("2026-11-11T10:00:00.000Z"); // 07:00
  const r = await t.celular(desde);
  assert.deepEqual(r.notificacoes.map((n) => sp(n.titulo)), ["1 compra, R$ 60,00", "1 compra, R$ 40,00", "1 compra, R$ 20,00"]);
  assert.equal((await t.celular(r.cursor)).notificacoes.length, 0); // o cursor avançou: nada repete
});

test("Web Push: em silêncio o toque não sai; às 7h07 sai uma vez só para o lote retido", async () => {
  const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const extra = { VAPID_PRIVADA: JSON.stringify(await crypto.subtle.exportKey("jwk", par.privateKey)), VAPID_PUBLICA: "pub", VAPID_ASSUNTO: "mailto:a@b.c" };
  const t = await preparar({ extra });
  await t.db.prepare("INSERT INTO push_inscricoes (endpoint, criada) VALUES ('https://push.test/abc', 'x')").run();
  await t.sincronizar();
  const toques = () => t.pluggy.chamadas.filter((c) => c.caminho === "/abc").length;
  relogio("2026-11-11T02:07:00.000Z"); // 23:07 BRT
  await t.gasto("n1", 60);
  await t.sincronizar();
  assert.equal(toques(), 0);
  assert.equal(await t.db.prepare("SELECT count(*) n FROM notificacoes WHERE enviada_em IS NOT NULL").first("n"), 0);
  relogio("2026-11-11T10:07:00.000Z"); // 07:07 BRT
  await t.sincronizar();
  assert.equal(toques(), 1);
  await t.sincronizar();
  assert.equal(toques(), 1, "sem novidade, sem novo toque");
});

test("domingo 19h (22h UTC): resumo semanal; nos outros ticks não", async () => {
  const t = await preparar({ geral: 2000 });
  await t.gasto("a", 120, "MERCADO", "2026-11-08");
  const dom = Date.parse("2026-11-08T22:07:00.000Z");
  relogio("2026-11-08T22:07:00.000Z");
  await t.sincronizar(dom);
  const [s] = await t.alertas("semana:%");
  assert.equal(s.titulo, "Resumo da semana");
  const linhas = s.corpo.split("\n");
  assert.match(linhas[0], /^Semana: R\$ 120,00\. Ciclo \(05\/11 a \d\d\/\d\d\): R\$ 120,00\.$/);
  assert.equal(linhas[1], "Geral: R$ 120,00 de R$ 2.000,00, faltam R$ 1.880,00.");
  assert.ok(linhas.includes("Para revisar: nada pendente."));
  const outro = await preparar();
  await outro.sincronizar(Date.parse("2026-11-08T19:07:00.000Z")); // domingo 16h BRT
  await outro.sincronizar(Date.parse("2026-11-09T22:07:00.000Z")); // segunda 19h BRT
  assert.deepEqual(await outro.alertas("semana:%"), []);
});

test("Para revisar: notificação leva o item para os botões e some quando outro aparelho responde", async () => {
  const t = await preparar();
  await t.sincronizar();
  await t.gasto("p1", 80, "Pix enviado: Joao Silva");
  await t.db.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES ('e1', 'cc', ?1, 'PIX ENVIADO SANTANDER', -500, 'DEBIT', 'POSTED', 0, ?2)").bind(HOJE, new Date().toISOString()).run();
  await t.sincronizar();
  const desde = new Date(T0 - 1000).toISOString();
  let r = await t.celular(desde);
  const rev = r.notificacoes.filter((n) => n.chave.startsWith("revisar:"));
  assert.deepEqual(rev.map((n) => n.item.tx_id).sort(), ["e1", "p1"]);
  const santander = rev.find((n) => n.item.tx_id === "e1");
  assert.equal(santander.item.tipo, "envio_santander");
  assert.equal(sp(santander.titulo), "Enviado ao Santander: R$ 500,00");
  // O outro aparelho responde: a notificação deixa de ser entregue ao celular.
  await t.db.prepare("INSERT INTO registros (tabela, id, dados, updated_at, deleted_at, server_at) VALUES ('revisoes', 'tx:e1', ?1, ?2, NULL, ?2)")
    .bind(JSON.stringify({ tipo: "decisao", tx_id: "e1", resposta: "ajuda" }), new Date().toISOString()).run();
  r = await t.celular(desde);
  assert.deepEqual(r.notificacoes.filter((n) => n.chave.startsWith("revisar:")).map((n) => n.item.tx_id), ["p1"]);
});

test("celular e computador: o mesmo evento gera uma chave só e cada canal entrega uma vez", async () => {
  const t = await preparar();
  await t.sincronizar();
  await t.gasto("a", 10);
  await t.sincronizar(); await t.sincronizar(); await t.sincronizar();
  assert.equal((await t.alertas("compras:%")).length, 1);
  const desde = new Date(T0 - 1000).toISOString();
  assert.equal((await t.celular(desde)).notificacoes.filter((n) => n.chave.startsWith("compras:")).length, 1);
  // Canal do computador: o service worker chama /entregar; depois de entregue, não volta.
  await t.db.prepare("UPDATE notificacoes SET enviada_em = ?1").bind(new Date().toISOString()).run();
  const cookie = await entrarComSenha(t.pedir);
  const entregar = async () => (await (await t.pedir("/api/notificacoes/entregar", { method: "POST", headers: { cookie, origin: ORIGEM } })).json()).notificacoes;
  assert.equal((await entregar()).filter((n) => n.chave.startsWith("compras:")).length, 1);
  assert.deepEqual(await entregar(), []);
  assert.equal((await t.celular(desde)).notificacoes.filter((n) => n.chave.startsWith("compras:")).length, 1, "o celular tem o próprio cursor");
});
