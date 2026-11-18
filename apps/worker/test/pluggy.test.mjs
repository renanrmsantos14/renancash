import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarD1 } from "./d1.mjs";
import { criarAmbiente, criarAparelho, entrarComSenha, simularPluggy, restaurarFetch } from "./ambiente.mjs";
import { idsConexoes, registrarItem, esquecerItem } from "../src/pluggy.js";
import { ApiCliente } from "../src/api.js";

afterEach(restaurarFetch);
const ID_A = "11111111-1111-4111-8111-111111111111";
const ID_B = "22222222-2222-4222-8222-222222222222";
const T = "2026-11-09T12:00:00.000Z";
const PLUGGY = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo" };

test("idsConexoes copia PLUGGY_ITEM_IDS uma vez e depois usa só o D1", async () => {
  const db = criarD1();
  assert.deepEqual(await idsConexoes(db, { PLUGGY_ITEM_IDS: ` ${ID_A} , ${ID_B} ` }, T), [ID_A, ID_B]);
  await esquecerItem(db, ID_B, T);
  assert.deepEqual(await idsConexoes(db, { PLUGGY_ITEM_IDS: `${ID_A},${ID_B}` }, T), [ID_A], "removido não volta pelo secret");
  await registrarItem(db, ID_B, T);
  assert.deepEqual((await idsConexoes(db, {}, T)).sort(), [ID_A, ID_B], "registrar de novo reativa");
});

test("ApiCliente usa os ids do D1 antes do secret", async () => {
  simularPluggy(() => ({}));
  assert.deepEqual(await new ApiCliente({ ...PLUGGY, PLUGGY_ITEM_IDS: "x" }, [ID_A]).listarIds(), [ID_A]);
  assert.deepEqual(await new ApiCliente({ ...PLUGGY, PLUGGY_ITEM_IDS: "x" }, []).listarIds(), [], "lista vazia do D1 não volta ao secret");
  assert.deepEqual(await new ApiCliente({ ...PLUGGY, PLUGGY_ITEM_IDS: "x" }).listarIds(), ["x"]);
});

test("connect-token pede o accessToken ao Pluggy; itemId desconhecido é 404", async () => {
  const { env, pedir } = criarAmbiente(PLUGGY);
  const token = await criarAparelho(env);
  const { chamadas } = simularPluggy((u) => (u.pathname === "/connect_token" ? { accessToken: "ct-123" } : {}));
  const post = (corpo) => pedir("/api/pluggy/connect-token", { method: "POST", headers: { authorization: "Bearer " + token, "content-type": "application/json" }, body: JSON.stringify(corpo) });

  const r = await post({});
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { accessToken: "ct-123" });
  assert.deepEqual(chamadas.find((c) => c.caminho === "/connect_token").corpo, { options: { clientUserId: "meu-banco", avoidDuplicates: true } });

  assert.equal((await post({ itemId: "nao-e-uuid" })).status, 400);
  assert.equal((await post({ itemId: ID_A })).status, 404);
  await registrarItem(env.DB, ID_A, T);
  assert.equal((await post({ itemId: ID_A })).status, 200);
  await esquecerItem(env.DB, ID_A, T);
  assert.equal((await post({ itemId: ID_A })).status, 404);
  await registrarItem(env.DB, ID_A, T);
  assert.equal(chamadas.filter((c) => c.caminho === "/connect_token").at(-1).corpo.itemId, ID_A);
});

test("POST /api/pluggy/items registra o item e dispara a sincronização", async () => {
  const { env, pedir, esperar } = criarAmbiente(PLUGGY);
  const token = await criarAparelho(env);
  simularPluggy((u) => (u.pathname.startsWith("/items/") ? { id: ID_A, status: "UPDATED", connector: { name: "Inter" } } : { results: [] }));
  const post = (itemId) => pedir("/api/pluggy/items", { method: "POST", headers: { authorization: "Bearer " + token, "content-type": "application/json" }, body: JSON.stringify({ itemId }) });

  assert.equal((await post("nao-e-uuid")).status, 400);
  assert.equal((await post(ID_A)).status, 201);
  await esperar();
  assert.deepEqual(await env.DB.prepare("SELECT id, status, conector FROM pluggy_items").first(), { id: ID_A, status: "UPDATED", conector: "Inter" });
  assert.equal(await env.DB.prepare("SELECT origem FROM sync_log").first("origem"), "app");
});

test("connect-token aceita itemId que só existe no secret (instalação nova)", async () => {
  const { env, pedir } = criarAmbiente({ ...PLUGGY, PLUGGY_ITEM_IDS: ID_B });
  const token = await criarAparelho(env);
  simularPluggy((u) => (u.pathname === "/connect_token" ? { accessToken: "ct" } : {}));
  const r = await pedir("/api/pluggy/connect-token", { method: "POST", headers: { authorization: "Bearer " + token, "content-type": "application/json" }, body: JSON.stringify({ itemId: ID_B }) });
  assert.equal(r.status, 200);
});

test("sincronizar com todas as conexões removidas não busca os ids do secret", async () => {
  const { env, pedir } = criarAmbiente({ ...PLUGGY, PLUGGY_ITEM_IDS: ID_A });
  await idsConexoes(env.DB, env, T);
  await esquecerItem(env.DB, ID_A, T);
  const { chamadas } = simularPluggy(() => ({ results: [] }));
  await pedir("/api/atualizar", { method: "POST", headers: { origin: "https://meu-banco.test", cookie: await entrarComSenha(pedir) } });
  assert.equal(chamadas.filter((c) => c.caminho.startsWith("/items/") || c.caminho === "/accounts").length, 0);
});

test("sincronizar com D1 vazio e sem secret ainda descobre as conexões via /v2/items", async () => {
  const { env, pedir } = criarAmbiente(PLUGGY);
  const { chamadas } = simularPluggy(() => ({ results: [] }));
  await pedir("/api/atualizar", { method: "POST", headers: { origin: "https://meu-banco.test", cookie: await entrarComSenha(pedir) } });
  assert.ok(chamadas.some((c) => c.caminho === "/v2/items"));
  assert.equal(await env.DB.prepare("SELECT count(*) AS n FROM pluggy_items").first("n"), 0);
});

const pluggyUmBanco = (u) => {
  if (u.pathname === "/v2/items") return { results: [{ id: ID_A }] };
  if (u.pathname === `/items/${ID_A}`) return { id: ID_A, status: "UPDATED", connector: { name: "Banco Teste" } };
  if (u.pathname === "/accounts") return { results: [{ id: "conta-1", type: "BANK", name: "Corrente", balance: 10 }] };
  return { results: [] };
};

test("/api/ferramentas lista as conexões do D1 sem consultar /v2/items", async () => {
  const { env, pedir } = criarAmbiente(PLUGGY);
  await registrarItem(env.DB, ID_A, T);
  const { chamadas } = simularPluggy(pluggyUmBanco);
  const r = await pedir("/api/ferramentas", { headers: { cookie: await entrarComSenha(pedir) } });
  assert.deepEqual((await r.json()).itens.map((i) => i.id), [ID_A]);
  assert.ok(!chamadas.some((c) => c.caminho === "/v2/items"));
});

test("sincronizar com D1 vazio e sem secret grava as contas descobertas via /v2/items", async () => {
  const { env, pedir } = criarAmbiente(PLUGGY);
  simularPluggy(pluggyUmBanco);
  const r = await pedir("/api/atualizar", { method: "POST", headers: { origin: "https://meu-banco.test", cookie: await entrarComSenha(pedir) } });
  assert.equal((await r.json()).ok, true);
  assert.equal(await env.DB.prepare("SELECT item_id FROM accounts WHERE id = 'conta-1'").first("item_id"), ID_A);
});

test("POST /api/pluggy/items antes da 1ª sincronização mantém as conexões do secret e as descobertas", async () => {
  const doSecret = criarAmbiente({ ...PLUGGY, PLUGGY_ITEM_IDS: ID_A });
  simularPluggy(() => ({ results: [] }));
  const post = async (amb) => amb.pedir("/api/pluggy/items", { method: "POST", headers: { authorization: "Bearer " + (await criarAparelho(amb.env)), "content-type": "application/json" }, body: JSON.stringify({ itemId: ID_B }) });
  assert.equal((await post(doSecret)).status, 201);
  await doSecret.esperar();
  assert.deepEqual((await idsConexoes(doSecret.env.DB, {}, T)).sort(), [ID_A, ID_B]);

  const descoberta = criarAmbiente(PLUGGY);
  simularPluggy((u) => (u.pathname === "/v2/items" ? { results: [{ id: ID_A }] } : { results: [] }));
  assert.equal((await post(descoberta)).status, 201);
  await descoberta.esperar();
  assert.deepEqual((await idsConexoes(descoberta.env.DB, {}, T)).sort(), [ID_A, ID_B]);
});

test("GET /api/pluggy/items lista as conexões ativas com banco, status e contas", async () => {
  const { env, pedir } = criarAmbiente(PLUGGY);
  const token = await criarAparelho(env);
  await registrarItem(env.DB, ID_A, T);
  await registrarItem(env.DB, ID_B, T);
  await esquecerItem(env.DB, ID_B, T);
  await env.DB.prepare("UPDATE pluggy_items SET status = 'UPDATED', conector = 'Inter', atualizado = ?1 WHERE id = ?2").bind(T, ID_A).run();
  await env.DB.prepare("INSERT INTO accounts (id, type, subtype, name, bank, balance, item_id, updated_at) VALUES ('c1', 'BANK', 'CHECKING_ACCOUNT', 'Conta Inter', 'Inter', 10.5, ?1, ?2)").bind(ID_A, T).run();

  const sem = await pedir("/api/pluggy/items");
  assert.equal(sem.status, 401);
  const r = await pedir("/api/pluggy/items", { headers: { authorization: "Bearer " + token } });
  assert.equal(r.status, 200);
  const { conexoes } = await r.json();
  assert.equal(conexoes.length, 1);
  assert.deepEqual(conexoes[0], {
    id: ID_A, banco: "Inter", status: "UPDATED", precisaReconectar: false, criado: T, atualizado: T, proximoSync: null, consentimentoExpira: null,
    contas: [{ id: "c1", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta Inter", bank: "Inter", balance: 10.5 }],
  });
});

test("DELETE /api/pluggy/items/:id apaga no Pluggy, zera as contas, limpa faturas, investimentos e avisos e mantém transações", async () => {
  const { env, pedir } = criarAmbiente(PLUGGY);
  const token = await criarAparelho(env);
  await registrarItem(env.DB, ID_A, T);
  await env.DB.prepare("INSERT INTO accounts (id, type, name, bank, balance, item_id, updated_at) VALUES ('c1', 'CREDIT', 'Cartão', 'Inter', 1, ?1, ?2)").bind(ID_A, T).run();
  await env.DB.prepare("INSERT INTO snapshots (key, data, updated_at) VALUES ('faturas:c1', '[]', ?1), (?2, '[]', ?1)").bind(T, "investimentos:" + ID_A).run();
  await env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, updated_at) VALUES ('t1', 'c1', '2026-11-01', 'Mercado', -10, ?1)").bind(T).run();
  const { chamadas } = simularPluggy(() => ({}));
  const apagar = (id) => pedir("/api/pluggy/items/" + id, { method: "DELETE", headers: { authorization: "Bearer " + token } });

  await env.DB.prepare("INSERT INTO snapshots (key, data, updated_at) VALUES ('avisos', ?1, ?2)")
    .bind(JSON.stringify([{ item_id: ID_A, banco: "Inter" }, { item_id: ID_B, banco: "Nubank" }]), T).run();

  assert.equal((await apagar("nao-e-uuid")).status, 400);
  assert.equal((await apagar(ID_B)).status, 404);
  assert.equal((await apagar(ID_A)).status, 200);
  assert.equal((await apagar(ID_A)).status, 200, "remover de novo é idempotente");
  assert.ok(chamadas.some((c) => c.metodo === "DELETE" && c.caminho === "/items/" + ID_A));
  assert.deepEqual(await idsConexoes(env.DB, {}, T), []);
  // a conta fica (tipo e banco servem às transações antigas), sem saldo
  assert.deepEqual(await env.DB.prepare("SELECT type, balance FROM accounts WHERE id = 'c1'").first(), { type: "CREDIT", balance: 0 });
  assert.deepEqual(JSON.parse(await env.DB.prepare("SELECT data FROM snapshots WHERE key = 'avisos'").first("data")), [{ item_id: ID_B, banco: "Nubank" }]);
  assert.equal(await env.DB.prepare("SELECT count(*) AS n FROM snapshots WHERE key <> 'avisos'").first("n"), 0);
  assert.equal(await env.DB.prepare("SELECT count(*) AS n FROM transactions").first("n"), 1);
  const sync = await (await pedir("/api/sync", { headers: { authorization: "Bearer " + token } })).json();
  assert.equal(sync.contas.find((c) => c.id === "c1").removida, 1);
});

test("DELETE /api/pluggy/items/:id segue quando o Pluggy já não tem o item (404) e para em outro erro", async () => {
  const { env, pedir } = criarAmbiente(PLUGGY);
  const token = await criarAparelho(env);
  await registrarItem(env.DB, ID_A, T);
  await registrarItem(env.DB, ID_B, T);
  simularPluggy((u) => new Response(JSON.stringify({ message: "x" }), { status: u.pathname.endsWith(ID_A) ? 404 : 500 }));
  const apagar = (id) => pedir("/api/pluggy/items/" + id, { method: "DELETE", headers: { authorization: "Bearer " + token } });
  assert.equal((await apagar(ID_A)).status, 200);
  assert.equal((await apagar(ID_B)).status, 502);
  assert.deepEqual(await idsConexoes(env.DB, {}, T), [ID_B]);
});
