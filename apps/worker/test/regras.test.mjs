import { test } from "node:test";
import assert from "node:assert/strict";
import { valorGasto, valorParcela, naoEhGasto, traduzir } from "../public/regras.js";

test("débito da conta conta como gasto positivo; crédito não", () => {
  assert.equal(valorGasto({ amount: -187.32, category: "Electricity" }, false), 187.32);
  assert.equal(valorGasto({ amount: 7500, category: "Salary" }, false), 0);
});
test("cartão: compra soma, estorno subtrai, pagamento de fatura fica fora", () => {
  assert.equal(valorGasto({ amount: 220, category: "Gas stations" }, true), 220);
  assert.equal(valorGasto({ amount: -30, category: "Gas stations" }, true), -30);
  assert.equal(valorGasto({ amount: -1500, category: "Credit card payment" }, true), 0);
});
test("aplicação/porquinho não é gasto; ajuste manual vence a regra", () => {
  assert.equal(naoEhGasto({ description: "APLICACAO CDB", amount: -1000 }), true);
  assert.equal(naoEhGasto({ description: "APLICACAO CDB", ajuste_gasto: 1 }), false);
  assert.equal(naoEhGasto({ description: "IFOOD", ajuste_gasto: 0 }), true);
});
test("parcela futura: fora de valorGasto, dentro de valorParcela", () => {
  const p = { amount: 750, category: "Electronics", scheduled: 1 };
  assert.equal(valorGasto(p, true), 0);
  assert.equal(valorParcela(p, true), 750);
  assert.equal(valorParcela({ ...p, scheduled: 0 }, true), 0);
});
test("traduzir", () => {
  assert.equal(traduzir("Rent"), "Aluguel");
  assert.equal(traduzir(null), "Sem categoria");
});
