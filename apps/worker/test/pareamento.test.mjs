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
