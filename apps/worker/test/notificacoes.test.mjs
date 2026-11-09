import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho } from "./ambiente.mjs";
import { gravarAlertas } from "../src/alertas.js";

async function preparar() {
  const amb = criarAmbiente();
  const auth = { authorization: "Bearer " + (await criarAparelho(amb.env)) };
  const nova = (chave, criada) => amb.env.DB.prepare("INSERT INTO notificacoes (chave, titulo, corpo, criada) VALUES (?1, ?2, ?3, ?4)").bind(chave, "T " + chave, "corpo", criada).run();
  const pedir = (desde) => amb.pedir("/api/notificacoes" + (desde ? "?desde=" + encodeURIComponent(desde) : ""), { headers: auth });
  return { ...amb, nova, pedir };
}
const agora = Date.parse("2026-11-09T15:00:00.000Z"); // 12h BRT, fora do silêncio
test.beforeEach(() => mock.timers.enable({ apis: ["Date"], now: agora }));
test.afterEach(() => mock.timers.reset());
const iso = (min) => new Date(agora + min * 60_000).toISOString();

test("sem token: 401; desde inválido: 400", async () => {
  const { pedir: pedirSemToken } = criarAmbiente();
  assert.equal((await pedirSemToken("/api/notificacoes")).status, 401);
  const { pedir } = await preparar();
  assert.equal((await pedir("lixo")).status, 400);
});

test("sem desde: vazio, cursor e resumo; disponivel soma só as BANK", async () => {
  const { pedir, nova, env } = await preparar();
  await nova("antiga", iso(-60));
  await env.DB.prepare("INSERT INTO accounts (id, type, name, balance, updated_at) VALUES ('cc','BANK','Inter',100.10,'x'),('cp','BANK','Poup',50.2,'x'),('cart','CREDIT','Nu',-900,'x')").run();
  const r = await (await pedir()).json();
  assert.deepEqual(r.notificacoes, []);
  assert.ok(Date.parse(r.cursor) >= agora);
  assert.equal(r.resumo.disponivel, 150.3);
  assert.deepEqual(Object.keys(r.resumo), ["disponivel", "consumido", "limite", "percentual", "inicio", "fim", "sincronizado_em"]);
  assert.equal(r.resumo.sincronizado_em, null);
});

test("com desde antigo: até 20 em ordem, cursor anda e segunda chamada vem vazia", async () => {
  const { pedir, nova } = await preparar();
  for (let i = 0; i < 25; i++) await nova("n" + String(i).padStart(2, "0"), iso(-100 + i));
  const desde = iso(-200);
  const r = await (await pedir(desde)).json();
  assert.equal(r.notificacoes.length, 20);
  assert.equal(r.notificacoes[0].chave, "n00");
  assert.equal(r.cursor, r.notificacoes[19].criada);
  const r2 = await (await pedir(r.cursor)).json();
  assert.deepEqual(r2.notificacoes.map((n) => n.chave), ["n20", "n21", "n22", "n23", "n24"]);
  assert.deepEqual((await (await pedir(r2.cursor)).json()).notificacoes, []);
});

test("não mexe em enviada_em nem entregue_em", async () => {
  const { pedir, nova, env } = await preparar();
  await nova("x", iso(-10));
  await pedir(iso(-200));
  const l = await env.DB.prepare("SELECT enviada_em, entregue_em FROM notificacoes").first();
  assert.deepEqual([l.enviada_em, l.entregue_em], [null, null]);
});

test("em silêncio (23h BRT): vazio e o cursor não anda", async () => {
  const { pedir, nova } = await preparar();
  mock.timers.reset();
  mock.timers.enable({ apis: ["Date"], now: new Date("2026-11-09T02:00:00.000Z") }); // 23h de 08/11 em BRT
  try {
    await nova("n", "2026-11-09T01:00:00.000Z");
    const desde = "2026-11-09T00:30:00.000Z";
    const r = await (await pedir(desde)).json();
    assert.deepEqual(r.notificacoes, []);
    assert.equal(r.cursor, desde);
  } finally { mock.timers.reset(); mock.timers.enable({ apis: ["Date"], now: agora }); }
});

test("mais de 20 alertas gravados juntos: o cursor não pula nenhum", async () => {
  const { pedir, env } = await preparar();
  await gravarAlertas(env.DB, Array.from({ length: 45 }, (_, i) => ({ chave: "k" + String(i).padStart(2, "0"), titulo: "t", corpo: "c" })), agora - 3_600_000);
  const vistas = [];
  let cursor = iso(-200);
  for (let i = 0; i < 4; i++) {
    const r = await (await pedir(cursor)).json();
    vistas.push(...r.notificacoes.map((n) => n.chave));
    cursor = r.cursor;
  }
  assert.deepEqual(vistas, Array.from({ length: 45 }, (_, i) => "k" + String(i).padStart(2, "0")));
});
