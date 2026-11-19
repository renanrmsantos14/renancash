import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, entrarComSenha, ORIGEM } from "./ambiente.mjs";
import { esperaAtualizar } from "../src/sync.js";

const reg = (over = {}) => ({ tabela: "categorias", id: "c1", dados: { nome: "Mercado", tipo: "despesa" }, updated_at: "2026-11-01T11:00:00.000Z", deleted_at: null, ...over });

async function preparar() {
  const amb = criarAmbiente();
  const token = await criarAparelho(amb.env);
  const auth = { authorization: "Bearer " + token };
  const enviar = (registros, headers = auth) => amb.pedir("/api/sync", { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ registros }) });
  const puxar = (desde, headers = auth) => amb.pedir("/api/sync" + (desde ? "?desde=" + encodeURIComponent(desde) : ""), { headers });
  return { ...amb, auth, enviar, puxar };
}

test("sem token e sem sessão: 401", async () => {
  const { pedir } = await preparar();
  assert.equal((await pedir("/api/sync")).status, 401);
  assert.equal((await pedir("/api/sync", { headers: { authorization: "Bearer mb_" + "x".repeat(43) } })).status, 401);
});

// `registros` virou histórico: o teste grava direto no D1 (o app não escreve mais ali).
const gravar = (db, r, serverAt = "2026-11-01T11:00:00.000Z") =>
  db.prepare("INSERT INTO registros (tabela, id, dados, updated_at, deleted_at, server_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
    .bind(r.tabela, r.id, r.dados ? JSON.stringify(r.dados) : null, r.updated_at, r.deleted_at, serverAt).run();

test("pull completo devolve o histórico de registros e o incremental traz só o que mudou", async () => {
  const { env, puxar } = await preparar();
  await gravar(env.DB, reg());
  await gravar(env.DB, reg({ id: "c2", dados: { nome: "Salário", tipo: "receita" } }));

  const completo = await (await puxar()).json();
  assert.equal(completo.completo, true);
  assert.deepEqual(completo.registros.map((r) => r.id).sort(), ["c1", "c2"]);
  assert.deepEqual(completo.registros.find((r) => r.id === "c1").dados, { nome: "Mercado", tipo: "despesa" });
  for (const k of ["contas", "transacoes", "pendentes", "faturas", "avisos", "config", "agora"]) assert.ok(k in completo, k);
  for (const k of ["sincronizado_em", "ciclo"]) assert.ok(k in completo, k);
  assert.match(completo.ciclo.inicio, /^\d{4}-\d{2}-\d{2}$/);
  const dias = Math.round((Date.parse(completo.ciclo.fim) - Date.parse(completo.ciclo.inicio)) / 86400000) + 1;
  assert.equal(completo.ciclo.por_dia.length, dias);

  const depois = new Date(Date.parse(completo.agora) + 3 * 60_000).toISOString();
  assert.equal((await (await puxar(depois)).json()).registros.length, 0, "fora da sobreposição de 2 min");
});

test("POST /api/sync com registros responde 410 e não grava nada", async () => {
  const { enviar, env } = await preparar();
  const r = await enviar([reg()]);
  assert.equal(r.status, 410);
  assert.match((await r.json()).erro, /descontinuada/);
  assert.equal(await env.DB.prepare("SELECT COUNT(*) AS n FROM registros").first("n"), 0);
});

test("sessão do painel também sincroniza (pull); POST com cookie de outra origem é 403", async () => {
  const { enviar, puxar, pedir } = await preparar();
  const cookie = await entrarComSenha(pedir);
  assert.equal((await puxar(null, { cookie })).status, 200);
  assert.equal((await enviar([reg()], { cookie, origin: ORIGEM })).status, 410);
  assert.equal((await enviar([reg()], { cookie, origin: "https://outro.site" })).status, 403);
});

test("uso grava ultimo_uso; token revogado perde acesso", async () => {
  const { env, puxar } = await preparar();
  assert.equal((await puxar()).status, 200);
  assert.ok(await env.DB.prepare("SELECT ultimo_uso FROM app_tokens").first("ultimo_uso"));
  await env.DB.prepare("UPDATE app_tokens SET revogado = '2026-11-09T00:00:00.000Z'").run();
  assert.equal((await puxar()).status, 401);
});

test("esperaAtualizar: 5 min desde o último Atualizar", () => {
  const t = Date.parse("2026-11-09T12:00:00.000Z");
  assert.equal(esperaAtualizar(null, t), 0);
  assert.equal(esperaAtualizar("2026-11-09T11:57:00.000Z", t), 2 * 60_000);
  assert.equal(esperaAtualizar("2026-11-09T11:55:00.000Z", t), 0);
});
