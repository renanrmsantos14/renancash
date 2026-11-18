import { test } from "node:test";
import assert from "node:assert/strict";
import { bancoDoItem, desambiguar, nomeConta, mapearConta, mapearTransacao, avisoItem, mapearFaturas, mapearInvestimentos, detalhesInvestimento, aplicadoPelasMovimentacoes, contraparteDe } from "../src/mapa.js";
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
  assert.deepEqual(mapearInvestimentos(lista, null, contas).map(({ id, nome, tipo, saldo, banco }) => ({ id, nome, tipo, saldo, banco })), [
    { id: "1", nome: "CDB", tipo: "FIXED_INCOME", saldo: 1500.5, banco: "Banco Santander Pessoa Física" },
  ]);
  assert.equal(mapearInvestimentos(lista, "Santander", contas)[0].banco, "Santander");
  assert.equal(mapearInvestimentos(lista, null, [])[0].banco, null);
});

test("poupança usa bankData.closingBalance quando maior que balance; corrente e cartão não mudam", () => {
  const m = (c) => mapearConta({ id: "1", type: "BANK", ...c }, "Inter", "i", TS).balance;
  assert.equal(m({ subtype: "SAVINGS_ACCOUNT", balance: 0.33, bankData: { closingBalance: 600.33 } }), 600.33);
  assert.equal(m({ subtype: "SAVINGS_ACCOUNT", balance: 100, bankData: { closingBalance: 50 } }), 100, "menor não vale");
  assert.equal(m({ subtype: "SAVINGS_ACCOUNT", balance: 100, bankData: { closingBalance: "900" } }), 100, "não numérico não vale");
  assert.equal(m({ subtype: "SAVINGS_ACCOUNT", balance: 100 }), 100);
  assert.equal(m({ subtype: "CHECKING_ACCOUNT", balance: 0.33, bankData: { closingBalance: 600.33 } }), 0.33);
  assert.equal(m({ type: "CREDIT", subtype: "CREDIT_CARD", balance: 10, bankData: { closingBalance: 99 } }), 10);
});

test("investimentos usam amount (bruto) quando numérico, senão balance; mantém o filtro", () => {
  const r = mapearInvestimentos([
    { id: "a", name: "Tesouro", balance: 7.1, amount: 7.45 },
    { id: "b", name: "CDB", balance: 430.28, amount: 431.3119 },
    { id: "c", name: "Fundo", balance: 20 },
    { id: "d", name: "Resgatado", balance: 5, amount: 5, status: "TOTAL_WITHDRAWAL" },
    { id: "e", name: "Sem saldo" },
  ], "Inter", []);
  assert.deepEqual(r.map((x) => [x.id, x.saldo]), [["a", 7.45], ["b", 431.3119], ["c", 20]]);
});

test("investimento: aplicado, rendimento, líquido, impostos e taxa vêm do objeto Investment do Pluggy", () => {
  const cdb = {
    id: "c", name: "CDB Inter", type: "FIXED_INCOME", subtype: "CDB", status: "ACTIVE",
    amount: 11234.56, balance: 11050.1, amountOriginal: 10000, amountProfit: 1050.1,
    taxes: 180.2, taxes2: 4.26, rate: 110, rateType: "CDI", dueDate: "2028-03-01T00:00:00.000Z",
    purchaseDate: "2025-03-01T00:00:00.000Z", issuer: "Banco Inter", taxExempt: false,
  };
  const [m] = mapearInvestimentos([cdb], "Inter", []);
  assert.equal(m.saldo, 11234.56);
  assert.equal(m.aplicado, 10000);
  assert.equal(m.rendimento, 1234.56); // bruto, como o saldo
  assert.equal(m.liquido, 11050.1);
  assert.equal(m.impostos, 184.46);
  assert.deepEqual(m.taxa, { valor: 110, indexador: "CDI" });
  assert.equal(m.vencimento, "2028-03-01");
  assert.equal(m.aplicado_em, "2025-03-01");
  assert.equal(m.subtipo, "CDB");
  assert.equal(m.isento_ir, false);
});

test("investimento sem amountOriginal usa amountProfit; sem nada fica null; prefixada vira PRE", () => {
  const d = detalhesInvestimento({ amountProfit: "12.5", fixedAnnualRate: 12.5, lastTwelveMonthsRate: 11.2 }, 500);
  assert.equal(d.aplicado, null);
  assert.equal(d.rendimento, 12.5);
  assert.deepEqual(d.taxa, { valor: 12.5, indexador: "PRE" });
  assert.equal(d.rentabilidade_12m, 11.2);
  const vazio = detalhesInvestimento({ balance: 10 }, 10);
  assert.deepEqual([vazio.aplicado, vazio.rendimento, vazio.impostos, vazio.taxa, vazio.vencimento], [null, null, null, null, null]);
});

test("aplicado pelas movimentações: compras menos resgates; sem compra ou <= 0 é null", () => {
  assert.equal(aplicadoPelasMovimentacoes([{ type: "BUY", amount: 1000 }, { type: "BUY", amount: 500 }, { type: "SELL", amount: 200 }, { type: "TAX", amount: 3 }]), 1300);
  assert.equal(aplicadoPelasMovimentacoes([{ type: "SELL", amount: 10 }]), null);
  assert.equal(aplicadoPelasMovimentacoes([{ type: "BUY", amount: 100 }, { type: "SELL", amount: 150 }]), null);
  assert.equal(aplicadoPelasMovimentacoes(null), null);
  // amountOriginal do Pluggy vence; o das movimentações só entra quando ele falta
  const lista = [{ id: "a", name: "CDB", amount: 1100, amountOriginal: 1000 }, { id: "b", name: "LCI", amount: 520 }];
  const m = mapearInvestimentos(lista, "Inter", [], new Map([["a", 1], ["b", 500]]));
  assert.deepEqual(m.map((i) => [i.aplicado, i.rendimento]), [[1000, 100], [500, 20]]);
});

test("transação: contraparte do Pix, entre minhas contas, fatura prevista e tipo de crédito", () => {
  const conta = { id: "cc", type: "BANK" };
  const pix = {
    id: "p", date: "2026-11-10", description: "PIX ENVIADO", amount: 50, type: "DEBIT", status: "POSTED",
    paymentData: { paymentMethod: "PIX", payer: { name: "Eu" }, receiver: { name: " Maria Souza ", documentNumber: { type: "CPF", value: "111.222.333-44" } } },
  };
  const t = mapearTransacao(pix, conta, "2026-11-18", "ts", "11122233355");
  assert.deepEqual([t.contraparte, t.metodo, t.entre_minhas], ["Maria Souza", "PIX", 0]);
  assert.equal(contraparteDe(pix, "111.222.333-44").entre_minhas, 1);
  assert.equal(contraparteDe(pix, null).entre_minhas, null); // sem /identity
  const recebido = { ...pix, type: "CREDIT", paymentData: { payer: { name: "João", documentNumber: { value: "***.222.333-**" } } } };
  assert.deepEqual(Object.values(contraparteDe(recebido, "11122233344")), ["João", null, null]); // CPF mascarado: não dá para saber
  const cartao = mapearTransacao({ id: "c", date: "2026-11-10", amount: 30, type: "DEBIT", creditCardMetadata: { billId: "b1", billForecastDate: "2026-12", otherCreditsType: "REVOLVING_CREDIT" } }, { id: "k", type: "CREDIT" }, "2026-11-18", "ts");
  assert.deepEqual([cartao.bill_id, cartao.bill_month, cartao.tipo_credito, cartao.contraparte], ["b1", "2026-12", "REVOLVING_CREDIT", null]);
});

test("transferência para o próprio titular não é gasto", async () => {
  const { naoEhGasto, valorGasto } = await import("../public/regras.js");
  const t = { amount: -100, description: "PIX ENVIADO JOSE", entre_minhas: 1, ajuste_gasto: null };
  assert.equal(naoEhGasto(t), true);
  assert.equal(valorGasto(t, false), 0);
  assert.equal(naoEhGasto({ ...t, ajuste_gasto: 1 }), false); // o usuário manda
  assert.equal(naoEhGasto({ ...t, entre_minhas: 0 }), false);
});
