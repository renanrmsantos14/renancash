import { test } from "node:test";
import assert from "node:assert/strict";
import { gunzipSync } from "node:zlib";
import { criarD1 } from "./d1.mjs";
import { criarAmbiente } from "./ambiente.mjs";
import { exportarBanco, chaveBackup, salvarBackup } from "../src/backup.js";

const r2 = () => { const objetos = new Map(); return { objetos, put: async (k, v, o) => { objetos.set(k, { v: new Uint8Array(v), o }); } }; };

test("exporta todas as tabelas do usuário, sem as internas", async () => {
  const db = criarD1();
  await db.prepare("CREATE TABLE _cf_KV (k)").run();
  await db.prepare("INSERT INTO config (chave, valor) VALUES ('limite','1500')").run();
  const b = await exportarBanco(db);
  assert.ok(b.gerado_em);
  assert.deepEqual(b.tabelas.config, [{ chave: "limite", valor: "1500" }]);
  for (const t of ["accounts", "transactions", "registros", "pluggy_items", "app_tokens"]) assert.ok(t in b.tabelas, t);
  assert.ok(!("_cf_KV" in b.tabelas));
  assert.ok(!Object.keys(b.tabelas).some((t) => t.startsWith("sqlite_")));
});

test("salvarBackup grava JSON gzip no R2 com a data na chave", async () => {
  const db = criarD1();
  await db.prepare("INSERT INTO config (chave, valor) VALUES ('salario','PAGTO SALARIO')").run();
  const BACKUP = r2();
  const chave = await salvarBackup({ DB: db, BACKUP }, new Date("2026-11-09T06:07:00Z"));
  assert.equal(chave, "d1/2026-11-09.json.gz");
  assert.equal(chaveBackup(new Date("2026-01-02T23:59:00Z")), "d1/2026-01-02.json.gz");
  const salvo = BACKUP.objetos.get(chave);
  assert.equal(salvo.o.httpMetadata.contentType, "application/json");
  assert.equal(salvo.o.httpMetadata.contentEncoding, "gzip");
  assert.deepEqual(JSON.parse(gunzipSync(salvo.v)).tabelas.config, [{ chave: "salario", valor: "PAGTO SALARIO" }]);
});

test("cron das 06h UTC faz o backup; nos outros horários não", async () => {
  for (const [hora, esperado] of [[6, 1], [9, 0]]) {
    const BACKUP = r2();
    const { env, ctx, worker, esperar } = criarAmbiente({ BACKUP });
    await worker.scheduled({ scheduledTime: Date.UTC(2026, 10, 9, hora, 7) }, env, ctx);
    await esperar();
    assert.equal(BACKUP.objetos.size, esperado, `hora ${hora}`);
  }
});

test("tabela com aspas no nome é exportada com o identificador escapado", async () => {
  const db = criarD1();
  await db.prepare('CREATE TABLE "a""b" (x)').run();
  await db.prepare('INSERT INTO "a""b" (x) VALUES (1)').run();
  assert.deepEqual((await exportarBanco(db)).tabelas['a"b'], [{ x: 1 }]);
});

test("falha ao gravar no R2 não derruba a sincronização do cron", async () => {
  const BACKUP = { put: async () => { throw new Error("R2 fora do ar"); } };
  const { env, ctx, worker, esperar } = criarAmbiente({ BACKUP });
  const erros = [];
  const original = console.error;
  console.error = (...a) => erros.push(a.join(" "));
  try {
    await worker.scheduled({ scheduledTime: Date.UTC(2026, 10, 9, 6, 7) }, env, ctx);
    const [resultado] = await esperar();
    assert.equal(resultado.status, "fulfilled");
  } finally { console.error = original; }
  assert.ok(erros.some((e) => e.includes("Backup falhou") && e.includes("R2 fora do ar")));
  assert.equal(await env.DB.prepare("SELECT count(*) AS n FROM sync_log").first("n"), 1, "a sincronização rodou");
});
