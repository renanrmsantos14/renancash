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

test("push grava, pull completo devolve e pull incremental traz só o que mudou", async () => {
  const { enviar, puxar } = await preparar();
  const r1 = await (await enviar([reg(), reg({ id: "c2", dados: { nome: "Salário", tipo: "receita" } })])).json();
  assert.equal(r1.aceitos, 2);
  assert.deepEqual(r1.rejeitados, []);

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
  assert.equal((await (await puxar(completo.agora)).json()).registros.length, 2, "dentro da sobreposição: reentrega idempotente");
});

test("last-write-wins no D1: antigo ou igual não sobrescreve; mais novo sim; exclusão propaga", async () => {
  const { enviar, puxar, env } = await preparar();
  const nome = async () => JSON.parse(await env.DB.prepare("SELECT dados FROM registros WHERE id = 'c1'").first("dados")).nome;
  await enviar([reg()]);
  await enviar([reg({ dados: { nome: "Antigo", tipo: "despesa" }, updated_at: "2026-11-01T10:00:00.000Z" })]);
  await enviar([reg({ dados: { nome: "Igual", tipo: "despesa" } })]);
  assert.equal(await nome(), "Mercado");
  await enviar([reg({ dados: { nome: "Feira", tipo: "despesa" }, updated_at: "2026-11-01T11:30:00.000Z" })]);
  assert.equal(await nome(), "Feira");

  const { agora } = await (await puxar()).json();
  await enviar([reg({ dados: null, deleted_at: "2026-11-01T11:40:00.000Z", updated_at: "2026-11-01T11:40:00.000Z" })]);
  assert.equal((await (await puxar()).json()).registros.length, 0, "pull completo não traz exclusões");
  const inc = await (await puxar(agora)).json();
  assert.equal(inc.registros[0].deleted_at, "2026-11-01T11:40:00.000Z");
  assert.equal(inc.registros[0].dados, null);
});

test("mesmo id duas vezes no lote: fica o updated_at mais novo; empate, o primeiro", async () => {
  const { enviar, env } = await preparar();
  const nome = async () => JSON.parse(await env.DB.prepare("SELECT dados FROM registros WHERE id = 'c1'").first("dados")).nome;
  const r = await (await enviar([
    reg({ dados: { nome: "Velho", tipo: "despesa" }, updated_at: "2026-11-01T10:00:00.000Z" }),
    reg({ dados: { nome: "Novo", tipo: "despesa" }, updated_at: "2026-11-01T11:00:00.000Z" }),
  ])).json();
  assert.equal(r.ok, true);
  assert.equal(await nome(), "Novo", "mais novo vence mesmo vindo depois");
  await enviar([
    reg({ dados: { nome: "Novo-invertido", tipo: "despesa" }, updated_at: "2026-11-01T11:10:00.000Z" }),
    reg({ dados: { nome: "Antigo-depois", tipo: "despesa" }, updated_at: "2026-11-01T10:30:00.000Z" }),
  ]);
  assert.equal(await nome(), "Novo-invertido", "mais novo vence mesmo vindo antes");
  await enviar([
    reg({ id: "c3", dados: { nome: "Primeiro", tipo: "despesa" } }),
    reg({ id: "c3", dados: { nome: "Segundo", tipo: "despesa" } }),
  ]);
  const c3 = JSON.parse(await env.DB.prepare("SELECT dados FROM registros WHERE id = 'c3'").first("dados"));
  assert.equal(c3.nome, "Primeiro", "empate: o primeiro vence");
});

test("inválidos voltam em rejeitados; lote malformado e desde inválido são 400", async () => {
  const { enviar, pedir, auth } = await preparar();
  const r = await (await enviar([reg(), reg({ id: "" })])).json();
  assert.equal(r.aceitos, 1);
  assert.deepEqual(r.rejeitados, [{ indice: 1, motivo: "id inválido" }]);
  assert.equal((await pedir("/api/sync", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: "{}" })).status, 400);
  assert.equal((await pedir("/api/sync?desde=ontem", { headers: auth })).status, 400);
});

test("sessão do painel também sincroniza; POST com cookie de outra origem é 403", async () => {
  const { enviar, puxar, pedir } = await preparar();
  const cookie = await entrarComSenha(pedir);
  assert.equal((await puxar(null, { cookie })).status, 200);
  assert.equal((await enviar([reg()], { cookie, origin: ORIGEM })).status, 200);
  assert.equal((await enviar([reg()], { cookie, origin: "https://outro.site" })).status, 403);
});

test("uso grava ultimo_uso; token revogado perde acesso", async () => {
  const { env, puxar } = await preparar();
  assert.equal((await puxar()).status, 200);
  assert.ok(await env.DB.prepare("SELECT ultimo_uso FROM app_tokens").first("ultimo_uso"));
  await env.DB.prepare("UPDATE app_tokens SET revogado = '2026-11-09T00:00:00.000Z'").run();
  assert.equal((await puxar()).status, 401);
});

test("esperaAtualizar: 30 min desde o último Atualizar", () => {
  const t = Date.parse("2026-11-09T12:00:00.000Z");
  assert.equal(esperaAtualizar(null, t), 0);
  assert.equal(esperaAtualizar("2026-11-09T11:50:00.000Z", t), 20 * 60_000);
  assert.equal(esperaAtualizar("2026-11-09T11:20:00.000Z", t), 0);
});
