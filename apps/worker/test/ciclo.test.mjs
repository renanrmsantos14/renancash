// test/ciclo.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizar, fimDoCiclo, cicloAtual, resumoCiclo, gastoPorDia, contaIgnorada } from "../src/ciclo.js";

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
  assert.deepEqual(cicloAtual(tx, contas, { salario: "SALARIO EMPRESA X" }, "2026-11-20"), { inicio: "2026-11-05", fim: "2026-12-04", semSalario: false, ultimoSalario: "2026-11-05", diasSemSalario: 15, salarioNaoDetectado: false });
  assert.equal(cicloAtual(tx, contas, {}, "2026-11-20").inicio, "2026-11-05"); // dois salários iguais: recorrente, sem config
  assert.deepEqual(cicloAtual([], contas, {}, "2026-11-20").inicio, "2026-11-01");
});
test("salário atrasado estica o fim até hoje", () => {
  assert.equal(cicloAtual([sal("2026-10-05")], contas, { salario: "SALARIO EMPRESA X" }, "2026-11-07").fim, "2026-11-07");
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

test("gastoPorDia soma por dia (gasto + parcela) e preenche os zeros", () => {
  const tx = [
    { account_id: "cc", date: "2026-11-05", description: "MERCADO", amount: -10.1, type: "DEBIT", scheduled: 0 },
    { account_id: "cc", date: "2026-11-05", description: "PADARIA", amount: -5.2, type: "DEBIT", scheduled: 0 },
    { account_id: "cart", date: "2026-11-07", description: "LOJA", amount: 30, type: "DEBIT", scheduled: 1 },
    { account_id: "cc", date: "2026-11-20", description: "FORA", amount: -99, type: "DEBIT", scheduled: 0 },
  ];
  const r = gastoPorDia(tx, contas, "2026-11-05", "2026-11-08");
  assert.deepEqual(r.map((d) => d.data), ["2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"]);
  assert.deepEqual(r.map((d) => d.valor), [15.3, 0, 30, 0]);
});

// ---- Ciclo de salário a salário: reconhecimento por valor ----
const ent = (date, amount, description = "PIX RECEBIDO", conta = "cc") => ({ account_id: conta, date, description, amount, type: "CREDIT", scheduled: 0 });
const inicioDe = (tx, hoje, config = {}, cs = contas) => cicloAtual(tx, cs, config, hoje);

test("salário é reconhecido pelo valor, mesmo com descrição diferente a cada mês", () => {
  const tx = [ent("2026-08-05", 7500, "CREDITO EM CONTA"), ent("2026-09-05", 7480, "TRANSF RECEBIDA"), ent("2026-10-05", 7520, "PAGAMENTO"), ent("2026-10-12", 300)];
  const r = inicioDe(tx, "2026-10-20");
  assert.equal(r.inicio, "2026-10-05");
  assert.equal(r.semSalario, false);
});
test("tolerância de 15%: 7500 → 8600 vira ciclo; 7500 → 8700 não", () => {
  const base = [ent("2026-08-05", 7500), ent("2026-09-05", 7500)];
  assert.equal(inicioDe([...base, ent("2026-10-05", 8600)], "2026-10-20").inicio, "2026-10-05");
  assert.equal(inicioDe([...base, ent("2026-10-05", 8700)], "2026-10-20").inicio, "2026-09-05");
  assert.equal(inicioDe([...base, ent("2026-10-05", 6400)], "2026-10-20").inicio, "2026-10-05");
  assert.equal(inicioDe([...base, ent("2026-10-05", 6300)], "2026-10-20").inicio, "2026-09-05");
});
test("reajuste acompanha: cada salário aceito vira a nova referência", () => {
  const tx = [ent("2026-06-05", 6000), ent("2026-07-05", 6000), ent("2026-08-05", 6800), ent("2026-09-05", 7700), ent("2026-10-05", 8700)];
  assert.equal(inicioDe(tx, "2026-10-20").inicio, "2026-10-05");
});
test("13º, férias e PLR entram como renda e não viram o ciclo, mesmo com valor parecido", () => {
  const base = [ent("2026-10-05", 7500, "SALARIO"), ent("2026-09-05", 7500, "SALARIO")];
  for (const d of ["13º SALARIO 2A PARCELA", "13O SALARIO", "DECIMO TERCEIRO", "FERIAS", "Férias 30 dias", "PLR 2026", "PARTICIPACAO NOS LUCROS"]) {
    const r = inicioDe([...base, ent("2026-11-20", 7500, d)], "2026-11-25");
    assert.equal(r.inicio, "2026-10-05", d);
  }
  // "13" numa data da descrição não é 13º
  assert.equal(inicioDe([...base, ent("2026-11-13", 7500, "SALARIO 13 NOV")], "2026-11-25").inicio, "2026-11-13");
});
test("duas entradas parecidas em menos de 20 dias: vale a primeira", () => {
  const tx = [ent("2026-09-05", 7500), ent("2026-10-05", 7500), ent("2026-10-15", 7400)];
  assert.equal(inicioDe(tx, "2026-10-20").inicio, "2026-10-05");
});
test("config com valor salvo funciona no primeiro uso (uma só entrada)", () => {
  const tx = [ent("2026-11-05", 7500)];
  assert.equal(inicioDe(tx, "2026-11-20").semSalario, true); // sem histórico nem config: mês corrente
  const r = inicioDe(tx, "2026-11-20", { salarioValor: 7500 });
  assert.equal(r.inicio, "2026-11-05");
  assert.equal(r.semSalario, false);
});
test("entrada em conta/cartão do Santander, resgate e agendada não viram salário", () => {
  const cs = [...contas, { id: "st", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta", bank: "Santander" }];
  const tx = [ent("2026-09-05", 7500), ent("2026-10-05", 7500), ent("2026-10-25", 7500, "PIX", "st"), ent("2026-10-26", 7500, "RESGATE CDB"), { ...ent("2026-10-27", 7500), scheduled: 1 }];
  assert.equal(inicioDe(tx, "2026-10-30", {}, cs).inicio, "2026-10-05");
});
test("35 dias sem salário viram pendência; 34 não", () => {
  const tx = [ent("2026-08-05", 7500), ent("2026-09-05", 7500)];
  const a = inicioDe(tx, "2026-10-09"); // 34 dias
  assert.equal(a.diasSemSalario, 34);
  assert.equal(a.salarioNaoDetectado, false);
  const b = inicioDe(tx, "2026-10-10"); // 35 dias
  assert.equal(b.diasSemSalario, 35);
  assert.equal(b.salarioNaoDetectado, true);
  assert.equal(b.ultimoSalario, "2026-09-05");
  assert.equal(b.semSalario, false);
});
test("nenhum salário em todo o histórico: pendente a partir de 35 dias de histórico", () => {
  const tx = [{ account_id: "cc", date: "2026-09-01", description: "MERCADO", amount: -50, scheduled: 0 }];
  const r = inicioDe(tx, "2026-11-05");
  assert.equal(r.semSalario, true);
  assert.equal(r.ultimoSalario, null);
  assert.equal(r.salarioNaoDetectado, true);
  assert.equal(inicioDe([], "2026-11-05").salarioNaoDetectado, false);
});
test("resumo expõe os campos de pendência", () => {
  const r = resumoCiclo({ transacoes: [ent("2026-08-05", 7500), ent("2026-09-05", 7500)], contas, config: {}, hoje: "2026-10-20" });
  assert.equal(r.salarioNaoDetectado, true);
  assert.equal(r.diasSemSalario, 45);
  assert.equal(r.ultimoSalario, "2026-09-05");
});

test("contaIgnorada: corrente e cartão do Santander; poupança/aplicação e Inter não", () => {
  assert.equal(contaIgnorada({ type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta", bank: "Santander" }), true);
  assert.equal(contaIgnorada({ type: "BANK", name: "Santander Conta" }), true);
  assert.equal(contaIgnorada({ type: "CREDIT", name: "Cartão Gold ·1950", bank: "Santander" }), true);
  assert.equal(contaIgnorada({ type: "BANK", subtype: "SAVINGS_ACCOUNT", name: "Poupança Santander" }), false);
  assert.equal(contaIgnorada({ type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta", bank: "Inter" }), false);
  assert.equal(contaIgnorada({ type: "CREDIT", name: "Cartão Inter", bank: "Inter" }), false);
});
test("ciclo e gasto por dia deixam de somar a conta e o cartão do Santander", () => {
  const cs = [...contas, { id: "st", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta", bank: "Santander" }, { id: "stc", type: "CREDIT", name: "Cartão", bank: "Santander" }];
  const tx = [
    ent("2026-11-05", 7500),
    { account_id: "cc", date: "2026-11-10", description: "ENEL", amount: -200, scheduled: 0 },
    { account_id: "st", date: "2026-11-10", description: "MERCADO PAI", amount: -500, scheduled: 0 },
    { account_id: "stc", date: "2026-11-11", description: "LOJA PAI", amount: 900, scheduled: 0 },
    { account_id: "stc", date: "2026-12-11", description: "LOJA PAI 2/2", amount: 900, scheduled: 1 },
  ];
  const r = resumoCiclo({ transacoes: tx, contas: cs, config: { salarioValor: 7500 }, hoje: "2026-11-20" });
  assert.equal(r.gasto, 200);
  assert.equal(r.parcelasCiclo, 0);
  assert.equal(r.parcelasDepois, 0);
  assert.equal(gastoPorDia(tx, cs, "2026-11-10", "2026-11-11").map((d) => d.valor).join(), "200,0");
});
