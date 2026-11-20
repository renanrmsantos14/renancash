import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, MODOS, extraDoModo, nomeDoModo, semearVazio } from "./ambiente.mjs";
import { gravarAlertas } from "../src/alertas.js";

async function preparar(espelho = false) {
  const amb = criarAmbiente(extraDoModo(espelho));
  const token = await criarAparelho(amb.env);
  const auth = { authorization: "Bearer " + token };
  if (espelho) await semearVazio(amb.pedir, token);
  const nova = (chave, criada) => amb.env.DB.prepare("INSERT INTO notificacoes (chave, titulo, corpo, criada) VALUES (?1, ?2, ?3, ?4)").bind(chave, "T " + chave, "corpo", criada).run();
  const pedir = (desde) => amb.pedir("/api/notificacoes" + (desde ? "?desde=" + encodeURIComponent(desde) : ""), { headers: auth });
  return { ...amb, nova, pedir, auth, requisitar: amb.pedir };
}
const agora = Date.parse("2026-11-09T15:00:00.000Z"); // 12h BRT, fora do silêncio
test.beforeEach(() => mock.timers.enable({ apis: ["Date"], now: agora }));
test.afterEach(() => mock.timers.reset());
const iso = (min) => new Date(agora + min * 60_000).toISOString();

for (const espelho of MODOS) test(`sem token: 401; desde inválido: 400 ${nomeDoModo(espelho)}`, async () => {
  const { pedir: pedirSemToken } = criarAmbiente(extraDoModo(espelho));
  assert.equal((await pedirSemToken("/api/notificacoes")).status, 401);
  const { pedir } = await preparar(espelho);
  assert.equal((await pedir("lixo")).status, 400);
});

for (const espelho of MODOS) test(`sem desde: vazio, cursor e resumo; disponivel soma só as BANK ${nomeDoModo(espelho)}`, async () => {
  const { pedir, nova, env } = await preparar(espelho);
  await nova("antiga", iso(-60));
  await env.DB.prepare("INSERT INTO accounts (id, type, name, balance, updated_at) VALUES ('cc','BANK','Inter',100.10,'x'),('cp','BANK','Poup',50.2,'x'),('cart','CREDIT','Nu',-900,'x')").run();
  const r = await (await pedir()).json();
  assert.deepEqual(r.notificacoes, []);
  assert.ok(Date.parse(r.cursor) >= agora);
  assert.equal(r.resumo.disponivel, 150.3);
  assert.deepEqual(Object.keys(r.resumo), ["disponivel", "consumido", "limite", "percentual", "inicio", "fim", "sincronizado_em"]);
  assert.equal(r.resumo.sincronizado_em, null);
});

for (const espelho of MODOS) test(`com desde antigo: até 20 em ordem, cursor anda e segunda chamada vem vazia ${nomeDoModo(espelho)}`, async () => {
  const { pedir, nova } = await preparar(espelho);
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

for (const espelho of MODOS) test(`não mexe em enviada_em nem entregue_em ${nomeDoModo(espelho)}`, async () => {
  const { pedir, nova, env } = await preparar(espelho);
  await nova("x", iso(-10));
  await pedir(iso(-200));
  const l = await env.DB.prepare("SELECT enviada_em, entregue_em FROM notificacoes").first();
  assert.deepEqual([l.enviada_em, l.entregue_em], [null, null]);
});

for (const espelho of MODOS) test(`em silêncio (23h BRT): vazio e o cursor não anda ${nomeDoModo(espelho)}`, async () => {
  const { pedir, nova } = await preparar(espelho);
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

for (const espelho of MODOS) test(`mais de 20 alertas gravados juntos: o cursor não pula nenhum ${nomeDoModo(espelho)}`, async () => {
  const { pedir, env } = await preparar(espelho);
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

// A resposta dada no app (linha mb_revisoes no espelho) tira o item da fila da notificação: a web e o celular leem a mesma decisão.
for (const espelho of MODOS) test(`item "Para revisar" some da notificação depois da resposta ${nomeDoModo(espelho)}`, async () => {
  const { pedir, env, auth, requisitar } = await preparar(espelho);
  const dia = (n) => new Date(agora - n * 86_400_000).toISOString().slice(0, 10);
  const hoje = new Date(agora).toLocaleDateString("sv", { timeZone: "America/Sao_Paulo" });
  const tx = (id, c, d, desc, valor) => env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'POSTED', 0, 'x')").bind(id, c, d, desc, valor, valor > 0 ? "CREDIT" : "DEBIT");
  await env.DB.batch([
    env.DB.prepare("INSERT INTO accounts (id, type, subtype, name, bank, updated_at) VALUES ('inter', 'BANK', 'CHECKING_ACCOUNT', 'Conta', 'Inter', 'x')"),
    tx("s1", "inter", dia(5), "SALARIO EMPRESA", 7500), tx("p1", "inter", hoje, "Pix enviado: Joao", -50),
  ]);
  await env.DB.prepare("INSERT INTO notificacoes (chave, titulo, corpo, criada) VALUES ('revisar:tx:p1', 'Revisar', 'Pix para Joao', ?1)").bind(new Date(agora - 60_000).toISOString()).run();
  const antes = await (await pedir(new Date(agora - 3_600_000).toISOString())).json();
  assert.equal(antes.notificacoes[0].item.tx_id, "p1");
  const decisao = { tipo: "decisao", tx_id: "p1", resposta: "categoria", categoria_id: "cashew:c1" };
  if (espelho) {
    const r = await requisitar("/api/espelho", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify({ linhas: [{ tabela: "mb_revisoes", pk: "tx:p1", dados: { pk: "tx:p1", dados: JSON.stringify(decisao) }, updated_at: new Date(agora).toISOString(), deleted_at: null }] }) });
    assert.equal((await r.json()).aceitos, 1);
  } else {
    await env.DB.prepare("INSERT INTO registros (tabela, id, dados, updated_at, server_at) VALUES ('revisoes', 'tx:p1', ?1, ?2, ?2)").bind(JSON.stringify(decisao), new Date(agora).toISOString()).run();
  }
  const depois = await (await pedir(new Date(agora - 3_600_000).toISOString())).json();
  assert.deepEqual(depois.notificacoes, []);
});
