// D1 falso para testes: a API usada pelo Worker (prepare/bind/run/all/first/batch) sobre node:sqlite em memória.
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

const SCHEMA = readFileSync(new URL("../schema.sql", import.meta.url), "utf8");
const valor = (v) => (typeof v === "boolean" ? Number(v) : v === undefined ? null : v); // node:sqlite não aceita boolean
const objeto = (r) => (r == null ? r : { ...r }); // linhas do node:sqlite têm protótipo nulo

class Comando {
  constructor(db, sql, args = []) { this.db = db; this.sql = sql; this.args = args; }
  bind(...args) { return new Comando(this.db, this.sql, args.map(valor)); }
  async run() {
    const r = this.db.prepare(this.sql).run(...this.args);
    return { success: true, meta: { changes: Number(r.changes), last_row_id: Number(r.lastInsertRowid) } };
  }
  async all() { return { success: true, results: this.db.prepare(this.sql).all(...this.args).map(objeto), meta: {} }; }
  async first(coluna) {
    const r = objeto(this.db.prepare(this.sql).get(...this.args));
    return r == null ? null : coluna ? r[coluna] : r;
  }
}

export function criarD1() {
  const db = new DatabaseSync(":memory:");
  db.exec(SCHEMA);
  return {
    prepare: (sql) => new Comando(db, sql),
    exec: async (sql) => { db.exec(sql); return { count: 1 }; },
    async batch(comandos) {
      db.exec("BEGIN");
      try {
        const saida = [];
        for (const c of comandos) saida.push(await c.all());
        db.exec("COMMIT");
        return saida;
      } catch (e) { db.exec("ROLLBACK"); throw e; }
    },
  };
}
