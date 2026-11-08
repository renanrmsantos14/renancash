// test/ciclo.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizar, fimDoCiclo, cicloAtual, resumoCiclo } from "../src/ciclo.js";

const contas = [{ id: "cc", type: "BANK" }, { id: "cart", type: "CREDIT" }];
const sal = (date) => ({ account_id: "cc", date, description: `SALARIO EMPRESA X ${date.slice(5, 7)}/2026`, amount: 7500, type: "CREDIT", scheduled: 0 });

test("normalizar ignora números, data e acentos", () => {
  assert.equal(normalizar("Salário EMPRESA X 10/2026"), "SALARIO EMPRESA X");
});
test("fimDoCiclo ajusta fim de mês", () => {
  assert.equal(fimDoCiclo("2026-11-05"), "2026-12-04");
  assert.equal(fimDoCiclo("2026-01-31"), "2026-02-27");
});
test("ciclo começa no último salário; sem salário usa o mês", () => {
  const tx = [sal("2026-10-05"), sal("2026-11-05")];
  assert.deepEqual(cicloAtual(tx, contas, "SALARIO EMPRESA X", "2026-11-20"), { inicio: "2026-11-05", fim: "2026-12-04", semSalario: false });
  assert.deepEqual(cicloAtual(tx, contas, null, "2026-11-20"), { inicio: "2026-11-01", fim: "2026-11-30", semSalario: true });
});
test("salário atrasado estica o fim até hoje", () => {
  assert.equal(cicloAtual([sal("2026-10-05")], contas, "SALARIO EMPRESA X", "2026-11-07").fim, "2026-11-07");
});
test("resumo: gasto do ciclo + parcelas que caem no ciclo; limite e falta", () => {
  const tx = [
    sal("2026-11-05"),
    { account_id: "cc", date: "2026-11-01", description: "ANTES DO CICLO", amount: -999, scheduled: 0 },
    { account_id: "cc", date: "2026-11-10", description: "ENEL", amount: -200, category: "Electricity", scheduled: 0 },
    { account_id: "cart", date: "2026-11-12", description: "IFOOD", amount: 100, category: "Food delivery", scheduled: 0 },
    { account_id: "cart", date: "2026-11-30", description: "NOTEBOOK 2/4", amount: 750, category: "Electronics", scheduled: 1 },
    { account_id: "cart", date: "2026-12-30", description: "NOTEBOOK 3/4", amount: 750, category: "Electronics", scheduled: 1 },
    { account_id: "cc", date: "2026-11-15", description: "APLICACAO CDB", amount: -1000, scheduled: 0 },
  ];
  const r = resumoCiclo({ transacoes: tx, contas, config: { limite: 2000, salario: "SALARIO EMPRESA X" }, hoje: "2026-11-20" });
  assert.equal(r.gasto, 300);
  assert.equal(r.parcelasCiclo, 750);
  assert.equal(r.consumido, 1050);
  assert.equal(r.falta, 950);
  assert.equal(Math.round(r.percentual), 53);
  assert.equal(r.parcelasDepois, 750);
  assert.equal(r.diasRestantes, 14);
});
test("sem limite: falta e percentual nulos", () => {
  const r = resumoCiclo({ transacoes: [], contas, config: {}, hoje: "2026-11-20" });
  assert.equal(r.limite, null);
  assert.equal(r.percentual, null);
});
