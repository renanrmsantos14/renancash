import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, entrarComSenha, simularPluggy, restaurarFetch, ORIGEM } from "./ambiente.mjs";
import { registrarItem } from "../src/pluggy.js";

afterEach(restaurarFetch);
const ID = "11111111-1111-4111-8111-111111111111";
const ENV = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo" };
const haMin = (m) => new Date(Date.now() - m * 60_000).toISOString();
const pluggyOk = (u, init) => (init.method === "PATCH" || u.pathname.startsWith("/items/") ? { id: ID, status: "UPDATING" } : { results: [] });

async function preparar(ultimo, rotas = pluggyOk) {
  const amb = criarAmbiente(ENV);
  await registrarItem(amb.env.DB, ID, haMin(100));
  if (ultimo) await amb.env.DB.prepare("INSERT INTO sync_log (origem, started_at, finished_at, ok) VALUES (?1, ?2, ?2, 1)").bind(ultimo.origem, haMin(ultimo.min)).run();
  const token = await criarAparelho(amb.env);
  const pelo_app = () => amb.pedir("/api/sync/atualizar", { method: "POST", headers: { authorization: "Bearer " + token } });
  return { ...amb, pelo_app, pluggy: simularPluggy(rotas) };
}

test("antes de 10 min: 429 com liberado_em e nenhuma chamada ao Pluggy", async () => {
  const { pedir, pluggy } = await preparar({ origem: "app", min: 5 });
  const cookie = await entrarComSenha(pedir);
  const r = await pedir("/api/atualizar", { method: "POST", headers: { cookie, origin: ORIGEM } });
  assert.equal(r.status, 429);
  const j = await r.json();
  assert.equal(j.ok, false);
  assert.match(j.mensagem, /Tente de novo às \d{2}:\d{2}/);
  assert.ok(Date.parse(j.liberado_em) > Date.now() + 4 * 60_000);
  assert.equal(pluggy.chamadas.length, 0);
});

test("cron e webhook não contam para o limite", async () => {
  const { pelo_app, pluggy } = await preparar({ origem: "cron", min: 5 });
  assert.notEqual((await pelo_app()).status, 429);
  assert.ok(pluggy.chamadas.some((c) => c.metodo === "PATCH" && c.caminho === `/items/${ID}`));
});

test("depois de 10 min: PATCH antes da leitura e origem app no sync_log", async () => {
  const { env, pelo_app, pluggy } = await preparar({ origem: "botao", min: 11 });
  const j = await (await pelo_app()).json();
  assert.equal(j.pedidos, 1);
  assert.deepEqual(j.falhas, []);
  const patch = pluggy.chamadas.findIndex((c) => c.metodo === "PATCH");
  const leitura = pluggy.chamadas.findIndex((c) => c.metodo === "GET" && c.caminho === `/items/${ID}`);
  assert.ok(patch >= 0 && patch < leitura, "PATCH antes da leitura");
  assert.equal(await env.DB.prepare("SELECT origem FROM sync_log ORDER BY id DESC").first("origem"), "app");
});

test("PATCH recusado vira falha e a leitura acontece mesmo assim", async () => {
  const recusa = (u, init) => (init.method === "PATCH" ? new Response(JSON.stringify({ message: "não permitido" }), { status: 403 }) : pluggyOk(u, init));
  const { pelo_app, pluggy } = await preparar(null, recusa);
  const j = await (await pelo_app()).json();
  assert.equal(j.pedidos, 0);
  assert.equal(j.falhas.length, 1);
  assert.match(j.falhas[0], /403/);
  assert.ok(pluggy.chamadas.some((c) => c.metodo === "GET" && c.caminho === `/items/${ID}`));
});
