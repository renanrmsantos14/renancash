import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarD1 } from "./d1.mjs";
import { criarAmbiente, criarAparelho, simularPluggy, restaurarFetch } from "./ambiente.mjs";
import { idsConexoes, registrarItem, removerItem } from "../src/pluggy.js";
import { ApiCliente } from "../src/api.js";

afterEach(restaurarFetch);
const ID_A = "11111111-1111-4111-8111-111111111111";
const ID_B = "22222222-2222-4222-8222-222222222222";
const T = "2026-11-09T12:00:00.000Z";
const PLUGGY = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo" };

test("idsConexoes copia PLUGGY_ITEM_IDS uma vez e depois usa só o D1", async () => {
  const db = criarD1();
  assert.deepEqual(await idsConexoes(db, { PLUGGY_ITEM_IDS: ` ${ID_A} , ${ID_B} ` }, T), [ID_A, ID_B]);
  await removerItem(db, ID_B, T);
  assert.deepEqual(await idsConexoes(db, { PLUGGY_ITEM_IDS: `${ID_A},${ID_B}` }, T), [ID_A], "removido não volta pelo secret");
  await registrarItem(db, ID_B, T);
  assert.deepEqual((await idsConexoes(db, {}, T)).sort(), [ID_A, ID_B], "registrar de novo reativa");
});

test("ApiCliente usa os ids do D1 antes do secret", async () => {
  simularPluggy(() => ({}));
  assert.deepEqual(await new ApiCliente({ ...PLUGGY, PLUGGY_ITEM_IDS: "x" }, [ID_A]).listarIds(), [ID_A]);
  assert.deepEqual(await new ApiCliente({ ...PLUGGY, PLUGGY_ITEM_IDS: "x" }, []).listarIds(), ["x"]);
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
