import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, entrarComSenha } from "./ambiente.mjs";

test("/app redireciona com 301 para /app/", async () => {
  const r = await criarAmbiente().pedir("/app");
  assert.equal(r.status, 301);
  assert.equal(r.headers.get("location"), "/app/");
});

test("/app/ sem cookie vai para o login com volta", async () => {
  const r = await criarAmbiente().pedir("/app/");
  assert.equal(r.status, 302);
  assert.equal(r.headers.get("location"), "/login?volta=/app/");
});

test("/app/ com cookie serve o app com CSP própria; o painel mantém a dele", async () => {
  const { pedir } = criarAmbiente();
  const cookie = await entrarComSenha(pedir);
  const r = await pedir("/app/", { headers: { cookie } });
  assert.equal(r.status, 200);
  const csp = r.headers.get("content-security-policy");
  assert.match(csp, /'wasm-unsafe-eval'/);
  assert.match(csp, /base-uri 'self'/);
  assert.equal(r.headers.get("cache-control"), "private, no-cache");
  const painel = await pedir("/", { headers: { cookie } });
  assert.match(painel.headers.get("content-security-policy"), /base-uri 'none'/);
  assert.equal(painel.headers.get("cache-control"), "private, no-store");
});

test("sync por cookie: GET sem Origin passa; POST de origem externa é recusado", async () => {
  const { pedir } = criarAmbiente();
  const cookie = await entrarComSenha(pedir);
  assert.equal((await pedir("/api/sync", { headers: { cookie } })).status, 200);
  const r = await pedir("/api/sync", {
    method: "POST",
    headers: { cookie, origin: "https://outro.test", "content-type": "application/json" },
    body: JSON.stringify({ registros: [] }),
  });
  assert.equal(r.status, 403);
});
