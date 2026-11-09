import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, entrarComSenha, simularPluggy, restaurarFetch, ORIGEM } from "./ambiente.mjs";
import { acaoWebhook } from "../src/pluggy.js";

afterEach(restaurarFetch);
const ID = "11111111-1111-4111-8111-111111111111";
const ENV = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo", PLUGGY_WEBHOOK_SECRET: "wh-secreto" };
const evento = (pedir, ev, headers = { "x-webhook-secret": "wh-secreto" }, qs = "") =>
  pedir("/api/pluggy/webhook" + qs, { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify(ev) });

test("acaoWebhook mapeia os eventos de item", () => {
  assert.equal(acaoWebhook({ event: "item/created", itemId: ID }), "registrar");
  assert.equal(acaoWebhook({ event: "item/deleted", itemId: ID }), "remover");
  for (const e of ["item/updated", "item/error", "item/waiting_user_input", "item/login_succeeded"]) assert.equal(acaoWebhook({ event: e, itemId: ID }), "sincronizar");
  assert.equal(acaoWebhook({ event: "connector/status_updated" }), null);
  assert.equal(acaoWebhook({ event: "item/updated", itemId: "x" }), null, "itemId inválido é ignorado");
  assert.equal(acaoWebhook(null), null);
});

test("webhook sem secret, com secret errado ou sem PLUGGY_WEBHOOK_SECRET é 401", async () => {
  const ev = { event: "item/updated", itemId: ID };
  assert.equal((await evento(criarAmbiente(ENV).pedir, ev, {})).status, 401);
  assert.equal((await evento(criarAmbiente(ENV).pedir, ev, { "x-webhook-secret": "errado" })).status, 401);
  assert.equal((await evento(criarAmbiente({}).pedir, ev, { "x-webhook-secret": "qualquer" })).status, 401);
});

test("item/created registra e sincroniza; item/deleted marca removido; secret na query também vale", async () => {
  const { env, pedir, esperar } = criarAmbiente(ENV);
  simularPluggy((u) => (u.pathname.startsWith("/items/") ? { id: ID, status: "UPDATED", connector: { name: "Santander" } } : { results: [] }));
  assert.equal((await evento(pedir, { event: "item/created", itemId: ID })).status, 200);
  await esperar();
  assert.equal(await env.DB.prepare("SELECT conector FROM pluggy_items WHERE id = ?1").bind(ID).first("conector"), "Santander");
  assert.equal(await env.DB.prepare("SELECT origem FROM sync_log").first("origem"), "webhook");

  assert.equal((await evento(pedir, { event: "item/deleted", itemId: ID }, {}, "?s=wh-secreto")).status, 200);
  await esperar();
  assert.ok(await env.DB.prepare("SELECT removido FROM pluggy_items WHERE id = ?1").bind(ID).first("removido"));
});

test("POST /api/pluggy/webhooks registra o webhook uma vez, com o secret no cabeçalho", async () => {
  const { pedir } = criarAmbiente(ENV);
  const cookie = await entrarComSenha(pedir);
  const lista = [];
  const { chamadas } = simularPluggy((u, init) => {
    if (u.pathname !== "/webhooks") return {};
    if ((init.method || "GET") === "GET") return { results: lista };
    lista.push({ id: "w1", url: JSON.parse(init.body).url });
    return { id: "w1" };
  });
  const registrar = () => pedir("/api/pluggy/webhooks", { method: "POST", headers: { cookie, origin: ORIGEM } });
  assert.deepEqual(await (await registrar()).json(), { id: "w1", criado: true });
  assert.deepEqual(await (await registrar()).json(), { id: "w1", criado: false });
  const post = chamadas.find((c) => c.metodo === "POST" && c.caminho === "/webhooks");
  assert.deepEqual(post.corpo, { event: "all", url: ORIGEM + "/api/pluggy/webhook", headers: { "x-webhook-secret": "wh-secreto" } });
});
