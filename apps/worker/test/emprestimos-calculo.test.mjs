// Paridade do cálculo de empréstimos com o app (mesma fixture do teste Dart).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { calcularEmprestimos } from "../src/emprestimosCalculo.js";

const { casos } = JSON.parse(readFileSync(new URL("./fixtures/emprestimos-paridade.json", import.meta.url), "utf8"));
const resumo = (e) => ({ id: e.txId, original: e.originalCentavos, restante: e.restanteCentavos, pessoa: e.pessoa, pagamentos: e.pagamentos.length, ...(e.perdoadoCentavos ? { perdoado: e.perdoadoCentavos } : {}) });

for (const c of casos) {
  test(`cálculo igual ao app: ${c.nome}`, () => {
    const r = calcularEmprestimos(c.decisoes, c.perdoes);
    assert.equal(r.devidoCentavos, c.esperado.devido);
    assert.deepEqual(r.abertos.map(resumo), c.esperado.abertos);
    assert.deepEqual(r.quitados.map(resumo), c.esperado.quitados);
  });
}
