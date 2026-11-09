// test/alertas.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { emSilencio, foraDoPadrao, gerarAlertas, resumoSemanal } from "../src/alertas.js";

const contas = [{ id: "cc", type: "BANK" }, { id: "cart", type: "CREDIT" }];
const compra = (id, date, amount, category = "Gas stations") => ({ id, account_id: "cart", date, description: "POSTO SHELL", amount, category, scheduled: 0 });
const base = { inicio: "2026-11-05", fim: "2026-12-04", limite: 2000, consumido: 1000, falta: 1000, percentual: 50, diasRestantes: 14 };

test("silêncio 22h–7h em BRT", () => {
  assert.equal(emSilencio(new Date("2026-11-08T01:30:00Z")), true);  // 22:30 BRT
  assert.equal(emSilencio(new Date("2026-11-08T10:00:00Z")), false); // 07:00 BRT
  assert.equal(emSilencio(new Date("2026-11-08T09:59:00Z")), true);  // 06:59 BRT
});
test("fora do padrão: > 2x média, >= R$100, 3+ compras de histórico, últimos 3 dias", () => {
  const hist = [compra("a", "2026-09-01", 200), compra("b", "2026-10-01", 210), compra("c", "2026-10-20", 220)];
  assert.equal(foraDoPadrao([...hist, compra("n", "2026-11-19", 500)], contas, "2026-11-20").length, 1);
  assert.equal(foraDoPadrao([...hist, compra("n", "2026-11-10", 500)], contas, "2026-11-20").length, 0); // antiga
  assert.equal(foraDoPadrao([...hist.slice(0, 2), compra("n", "2026-11-19", 500)], contas, "2026-11-20").length, 0); // pouco histórico
  assert.equal(foraDoPadrao([compra("a", "2026-09-01", 30), compra("b", "2026-10-01", 30), compra("c", "2026-10-02", 30), compra("n", "2026-11-19", 90)], contas, "2026-11-20").length, 0); // < R$100
});
test("limite: 80% e 100% com chave por ciclo", () => {
  const c = (percentual) => gerarAlertas({ resumo: { ...base, percentual }, transacoes: [], contas, avisos: [], hoje: "2026-11-20" }).map((a) => a.chave);
  assert.deepEqual(c(50), []);
  assert.deepEqual(c(85), ["limite80:2026-11-05"]);
  assert.deepEqual(c(110), ["limite80:2026-11-05", "limite100:2026-11-05"]);
});
test("reconexão: uma chave por dia", () => {
  const a = gerarAlertas({ resumo: { ...base, limite: null, percentual: null }, transacoes: [], contas, avisos: [{ banco: "Banco Inter", mensagem: "Faça login" }], hoje: "2026-11-20" });
  assert.deepEqual(a.map((x) => x.chave), ["reconexao:2026-11-20"]);
});
test("resumo semanal soma os últimos 7 dias", () => {
  const r = resumoSemanal({ resumo: base, transacoes: [compra("x", "2026-11-18", 100), compra("y", "2026-11-01", 999)], contas, hoje: "2026-11-22" });
  assert.equal(r.chave, "semana:2026-11-22");
  assert.match(r.corpo, /R\$\s?100,00/);
});
