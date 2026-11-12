import { test } from "node:test";
import assert from "node:assert/strict";
import { bancoDoItem, desambiguar, nomeConta, mapearConta, mapearTransacao, avisoItem, mapearFaturas, mapearInvestimentos } from "../src/mapa.js";
import { valorGasto, valorParcela } from "../public/regras.js";

const HOJE = "2026-11-08", TS = "2026-11-08T12:00:00.000Z";

test("banco: connector real vence; Meu Pluggy não é banco", () => {
  assert.equal(bancoDoItem({ connector: { name: "Santander" } }), "Santander");
  assert.equal(bancoDoItem({ connector: { name: "Meu Pluggy" } }), null);
  assert.equal(bancoDoItem({}), null);
});

test("nomes repetidos entre bancos ganham o final do número; únicos ficam", () => {
  const l = desambiguar([{ name: "Cartão", number: "1111" }, { name: "Cartão", number: "4444" }, { name: "Conta" }]);
  assert.deepEqual(l.map((x) => x.name), ["Cartão ·1111", "Cartão ·4444", "Conta"]);
  assert.deepEqual(desambiguar([{ name: "Cartão" }, { name: "Cartão" }]).map((x) => x.name), ["Cartão #1", "Cartão #2"]);
});

test("nome identifica o banco sem repetir", () => {
  assert.equal(nomeConta({ type: "CREDIT", name: "Cartão" }, "Santander"), "Cartão Santander");
  assert.equal(nomeConta({ type: "BANK", name: "Conta Corrente Inter" }, "Inter"), "Conta Corrente Inter");
  assert.equal(nomeConta({ type: "CREDIT" }, null), "Cartão");
});

test("conta de cartão traz limite, disponível e vencimento", () => {
  const c = mapearConta({ id: "x", type: "CREDIT", subtype: "CREDIT_CARD", name: "Cartão", balance: "420.5", creditData: { creditLimit: 3000, availableCreditLimit: 2580, balanceDueDate: "2026-11-17T00:00:00.000Z", balanceCloseDate: "2026-11-10T00:00:00.000Z" } }, "Santander", "item-s", TS);
  assert.deepEqual([c.id, c.name, c.balance, c.credit_limit, c.available_limit, c.due_date, c.closing_date, c.bank, c.item_id], ["x", "Cartão Santander", 420.5, 3000, 2580, "2026-11-17", "2026-11-10", "Santander", "item-s", ]);
});

test("transação de conta: saída negativa, entrada positiva, mesmo se a API vier com o sinal invertido", () => {
  const conta = { id: "cc", type: "BANK" };
  assert.equal(mapearTransacao({ id: 1, date: "2026-11-01T03:00:00Z", amount: -10, type: "DEBIT" }, conta, HOJE, TS).amount, -10);
  assert.equal(mapearTransacao({ id: 1, date: "2026-11-01", amount: 10, type: "DEBIT" }, conta, HOJE, TS).amount, -10);
  assert.equal(mapearTransacao({ id: 2, date: "2026-11-01", amount: -7500, type: "CREDIT" }, conta, HOJE, TS).amount, 7500);
});

test("sem type vale o sinal da API", () => {
  assert.equal(mapearTransacao({ id: 1, date: "2026-11-01", amount: -42 }, { id: "cc", type: "BANK" }, HOJE, TS).amount, -42);
});

test("cartão: compra positiva, estorno negativo; pendente; merchant; id vira texto", () => {
  const conta = { id: "k", type: "CREDIT" };
  const compra = mapearTransacao({ id: 9, date: "2026-11-07", amount: -149.9, type: "DEBIT", status: "PENDING", category: "Groceries", merchant: { name: "Amazon" } }, conta, HOJE, TS);
  assert.deepEqual([compra.id, compra.amount, compra.status, compra.merchant, compra.scheduled, compra.account_id], ["9", 149.9, "PENDING", "Amazon", 0, "k"]);
  assert.equal(mapearTransacao({ id: 10, date: "2026-11-07", amount: 20, type: "CREDIT" }, conta, HOJE, TS).amount, -20);
});

test("parcela futura: scheduled, numeração na descrição e regra de gasto do painel", () => {
  const conta = { id: "k", type: "CREDIT" };
  const p = mapearTransacao({ id: 11, date: "2026-12-08T03:00:00Z", description: "NOTEBOOK LOJA", amount: 750, type: "DEBIT", creditCardMetadata: { installmentNumber: 2, totalInstallments: 4 } }, conta, HOJE, TS);
  assert.equal(p.scheduled, 1);
  assert.equal(p.description, "NOTEBOOK LOJA 2/4");
  assert.equal(valorGasto(p, true), 0);
  assert.equal(valorParcela(p, true), 750);
  // já numerada ou à vista: não mexe
  assert.equal(mapearTransacao({ id: 12, date: "2026-11-01", description: "LOJA 1/3", amount: 1, type: "DEBIT", creditCardMetadata: { installmentNumber: 1, totalInstallments: 3 } }, conta, HOJE, TS).description, "LOJA 1/3");
  assert.equal(mapearTransacao({ id: 13, date: "2026-11-01", description: "LOJA", amount: 1, type: "DEBIT", creditCardMetadata: { installmentNumber: 1, totalInstallments: 1 } }, conta, HOJE, TS).description, "LOJA");
});

test("item com login pendente vira aviso; OUTDATED e UPDATED não", () => {
  assert.match(avisoItem({ status: "LOGIN_ERROR" }, "Santander").mensagem, /LOGIN_ERROR/);
  assert.equal(avisoItem({ status: "LOGIN_ERROR" }, "Santander").banco, "Santander");
  assert.equal(avisoItem({ id: "item-1", status: "LOGIN_ERROR" }, "Santander").item_id, "item-1");
  assert.equal(avisoItem({ status: "OUTDATED" }, "X"), null);
  assert.equal(avisoItem({ status: "UPDATED" }, "X"), null);
});

test("faturas: aberta vem da conta; a de mesmo vencimento não duplica", () => {
  const f = mapearFaturas({ balance: 420, creditData: { balanceDueDate: "2026-11-17T00:00:00" } }, [
    { id: "a", dueDate: "2026-11-17T00:00:00", totalAmount: 420 }, { id: "b", dueDate: "2026-10-17T00:00:00", totalAmount: 300 },
  ]);
  assert.deepEqual(f.results.map((b) => b.id), ["b"]);
  assert.equal(f.results[0].payment_status, "CLOSED");
  assert.deepEqual(f.open_bill, { available: true, due_date: "2026-11-17", total_amount: 420 });
  assert.equal(mapearFaturas({ balance: 1 }, []).open_bill, null);
});

test("investimentos: resgate total fica fora; banco vem da conta corrente no Meu Pluggy", () => {
  const lista = [
    { id: 1, name: "CDB", type: "FIXED_INCOME", balance: "1500.5", status: "ACTIVE" },
    { id: 2, name: "Fundo", type: "MUTUAL_FUND", balance: 0, status: "TOTAL_WITHDRAWAL" },
    { id: 3, type: "EQUITY", balance: null },
  ];
  const contas = [{ type: "CREDIT", name: "GOLD" }, { type: "BANK", name: "Banco Santander Pessoa Física ·57-2" }];
  assert.deepEqual(mapearInvestimentos(lista, null, contas), [
    { id: "1", nome: "CDB", tipo: "FIXED_INCOME", saldo: 1500.5, banco: "Banco Santander Pessoa Física" },
  ]);
  assert.equal(mapearInvestimentos(lista, "Santander", contas)[0].banco, "Santander");
  assert.equal(mapearInvestimentos(lista, null, [])[0].banco, null);
});
