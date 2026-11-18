import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { COLUNAS, alteracoes } from "../scripts/migrar.mjs";

const colunasDe = (db, t) => db.prepare(`SELECT name FROM pragma_table_info('${t}')`).all().map((c) => c.name);

test("migrar cria só as colunas que faltam e o schema novo já tem todas", () => {
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, closing_date TEXT); CREATE TABLE transactions (id TEXT PRIMARY KEY);");
  const sql = alteracoes({ accounts: colunasDe(db, "accounts"), transactions: colunasDe(db, "transactions"), pluggy_items: [] });
  assert.ok(!sql.some((s) => s.includes("closing_date")));
  assert.ok(!sql.some((s) => s.includes("pluggy_items"))); // tabela ausente fica de fora
  db.exec(sql.join(" "));
  assert.deepEqual(alteracoes({ accounts: colunasDe(db, "accounts"), transactions: colunasDe(db, "transactions") }), []);

  const novo = new DatabaseSync(":memory:");
  novo.exec(readFileSync(new URL("../schema.sql", import.meta.url), "utf8"));
  const existentes = Object.fromEntries(Object.keys(COLUNAS).map((t) => [t, colunasDe(novo, t)]));
  assert.deepEqual(alteracoes(existentes), []);
});
