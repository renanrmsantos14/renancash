import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, entrarComSenha, ORIGEM } from "./ambiente.mjs";

test("criar token devolve link de pareamento e QR em SVG", async () => {
  const { pedir } = criarAmbiente();
  const cookie = await entrarComSenha(pedir);
  const r = await pedir("/api/app/tokens", { method: "POST", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ nome: "Pixel" }) });
  assert.equal(r.status, 201);
  const j = await r.json();
  assert.match(j.token, /^mb_[\w-]{43}$/);
  assert.equal(j.link, `meubanco://parear?u=${encodeURIComponent(ORIGEM)}&t=${j.token}`);
  assert.match(j.qr, /^<svg[\s\S]*<\/svg>\s*$/);
});

test("parear com a senha do painel cria token de aparelho que lê transações", async () => {
  const { pedir } = criarAmbiente();
  const r = await pedir("/api/app/parear", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ senha: "senha", nome: "Cashew" }) });
  assert.equal(r.status, 201);
  const { token, url } = await r.json();
  assert.match(token, /^mb_[\w-]{43}$/);
  assert.equal(url, ORIGEM);
  const t = await pedir("/api/app/transacoes", { headers: { authorization: `Bearer ${token}` } });
  assert.equal(t.status, 200);
});

test("parear com senha errada responde 401 e não cria token", async () => {
  const { pedir, env } = criarAmbiente();
  const r = await pedir("/api/app/parear", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ senha: "errada", nome: "Cashew" }) });
  assert.equal(r.status, 401);
  assert.equal((await env.DB.prepare("SELECT COUNT(*) AS n FROM app_tokens").first()).n, 0);
});

test("parear respeita o limite de tentativas e valida o nome", async () => {
  const bloqueado = criarAmbiente({ LIMITE_LOGIN: { limit: async () => ({ success: false }) } });
  const corpo = JSON.stringify({ senha: "senha", nome: "Cashew" });
  assert.equal((await bloqueado.pedir("/api/app/parear", { method: "POST", body: corpo })).status, 429);
  const { pedir } = criarAmbiente();
  assert.equal((await pedir("/api/app/parear", { method: "POST", body: JSON.stringify({ senha: "senha", nome: " " }) })).status, 400);
  assert.equal((await pedir("/api/app/parear", { method: "POST", headers: { origin: "https://outro.site" }, body: corpo })).status, 403);
});
