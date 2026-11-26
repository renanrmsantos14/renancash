import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { criarD1 } from "./d1.mjs";
import { criarAmbiente, entrarComSenha, ORIGEM } from "./ambiente.mjs";

const SCHEMA = readFileSync(new URL("../schema.sql", import.meta.url), "utf8");
const MIGRAR = readFileSync(new URL("../scripts/migrar-ajustes.sql", import.meta.url), "utf8");
const hoje = new Date().toISOString().slice(0, 10);

test("schema cria registros, pluggy_items e a view v_ajustes, sem a tabela ajustes", async () => {
  const db = criarD1();
  const nomes = (await db.prepare("SELECT name FROM sqlite_master WHERE name IN ('registros','pluggy_items','v_ajustes','ajustes') ORDER BY name").all()).results.map((r) => r.name);
  assert.deepEqual(nomes, ["pluggy_items", "registros", "v_ajustes"]);
});

test("migração copia os ajustes antigos, remove a tabela e o schema roda de novo sem erro", () => {
  const db = new DatabaseSync(":memory:");
  // estado de produção hoje: só a tabela antiga
  db.exec("CREATE TABLE ajustes (transaction_id TEXT PRIMARY KEY, category TEXT, gasto INTEGER, updated_at TEXT NOT NULL)");
  db.exec("INSERT INTO ajustes VALUES ('t1','Mercado',NULL,'2026-11-01T10:00:00.000Z'), ('t2',NULL,0,'2026-11-02T10:00:00.000Z')");
  db.exec(SCHEMA); // pnpm db:remote
  db.exec(MIGRAR); // migração única
  db.exec(SCHEMA); // db:remote de novo no futuro
  const linhas = db.prepare("SELECT transaction_id, category, gasto, updated_at FROM v_ajustes ORDER BY transaction_id").all().map((r) => ({ ...r }));
  assert.deepEqual(linhas, [
    { transaction_id: "t1", category: "Mercado", gasto: null, updated_at: "2026-11-01T10:00:00.000Z" },
    { transaction_id: "t2", category: null, gasto: 0, updated_at: "2026-11-02T10:00:00.000Z" },
  ]);
  assert.equal(db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'ajustes'").get().n, 0);
});

test("PUT /api/ajustes grava em registros, preserva campos do app e aparece na view", async () => {
  const { env, pedir } = criarAmbiente();
  const cookie = await entrarComSenha(pedir);
  const put = (corpo) => pedir("/api/ajustes/t1", { method: "PUT", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify(corpo) });

  // campo gravado pelo app
  await env.DB.prepare("INSERT INTO registros VALUES ('ajustes','t1','{\"nota\":\"do app\"}','2026-11-01T00:00:00.000Z',NULL,'2026-11-01T00:00:00.000Z')").run();
  assert.equal((await put({ category: "Mercado", gasto: 0 })).status, 200);
  let r = await env.DB.prepare("SELECT dados, server_at FROM registros WHERE tabela = 'ajustes' AND id = 't1'").first();
  assert.deepEqual(JSON.parse(r.dados), { nota: "do app", category: "Mercado", gasto: 0 });
  assert.ok(r.server_at > "2026-11-01T00:00:00.000Z");
  assert.deepEqual(await env.DB.prepare("SELECT category, gasto FROM v_ajustes WHERE transaction_id = 't1'").first(), { category: "Mercado", gasto: 0 });

  assert.equal((await put({ category: null, gasto: null })).status, 200);
  r = await env.DB.prepare("SELECT dados FROM registros WHERE tabela = 'ajustes' AND id = 't1'").first();
  assert.deepEqual(JSON.parse(r.dados), { nota: "do app" });
});

test("histórico continua lendo o ajuste pela view", async () => {
  const { env, pedir } = criarAmbiente();
  const cookie = await entrarComSenha(pedir);
  await env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, updated_at) VALUES ('t1','c1',?1,'DROGASIL',-68.35,?2)").bind(hoje, new Date().toISOString()).run();
  await env.DB.prepare("INSERT INTO registros VALUES ('ajustes','t1','{\"category\":\"Farmácia\"}','2026-11-05T00:00:00.000Z',NULL,'2026-11-05T00:00:00.000Z')").run();
  const j = await (await pedir("/api/historico", { headers: { cookie } })).json();
  assert.equal(j.transacoes.find((t) => t.id === "t1")?.ajuste_categoria, "Farmácia");
});

test("v_ajustes usa o relógio do servidor e mantém a exclusão visível ao pull incremental", () => {
  const db = new DatabaseSync(":memory:");
  db.exec(SCHEMA);
  db.exec("INSERT INTO registros VALUES ('ajustes','t1',NULL,'2026-11-01T10:00:00.000Z','2026-11-01T10:00:00.000Z','2026-11-09T12:00:00.000Z')");
  assert.deepEqual({ ...db.prepare("SELECT category, gasto, updated_at FROM v_ajustes WHERE transaction_id = 't1'").get() }, { category: null, gasto: null, updated_at: "2026-11-09T12:00:00.000Z" });
});
