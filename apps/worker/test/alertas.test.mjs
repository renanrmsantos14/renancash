// test/alertas.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { contextoDeRegistros } from "@meu-banco/core";
import { emSilencio, foraDoPadrao, gerarAlertas, resumoSemanal, alertasOrcamentos, alertasFechamento, alertasReceita, alertasAssinaturas } from "../src/alertas.js";

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

const ctxCat = contextoDeRegistros([
  { tabela: "categorias", id: "mercado", dados: { nome: "Mercado", tipo: "despesa", pluggy: ["Groceries"] }, deleted_at: null },
]);
const gasto = (id, date, amount, category) => ({ id, account_id: "cart", date, description: "LOJA", amount, category, scheduled: 0 });

test("orçamento: ciclo usa o período do resumo, mensal usa o mês de hoje; chave não repete", () => {
  const transacoes = [gasto("a", "2026-11-06", 850, "Groceries"), gasto("b", "2026-11-20", 100, "Gas stations"), gasto("c", "2026-10-30", 300, "Groceries")];
  const entrada = (periodo, valor, extra = {}) => ({ orcamentos: [{ id: "o1", nome: "Mercado", valor, categoria_ids: ["mercado"], periodo }], ctx: ctxCat, transacoes, contas, resumo: base, hoje: "2026-11-20", ...extra });
  const r = alertasOrcamentos(entrada("ciclo", 1000));
  assert.deepEqual(r.map((a) => a.chave), ["orc80:o1:2026-11-05"]);
  assert.equal(r[0].titulo, "80% do orçamento Mercado");
  assert.match(r[0].corpo, /05\/11 a 04\/12/);
  assert.deepEqual(alertasOrcamentos(entrada("ciclo", 1000)).map((a) => a.chave), r.map((a) => a.chave));
  assert.deepEqual(alertasOrcamentos(entrada("mensal", 800)).map((a) => a.chave), ["orc80:o1:2026-11-01", "orc100:o1:2026-11-01"]);
  assert.equal(alertasOrcamentos(entrada("mensal", 800)).at(-1).titulo, "Orçamento Mercado estourado");
  assert.deepEqual(alertasOrcamentos(entrada("ciclo", 5000)), []);
  const todas = alertasOrcamentos({ ...entrada("mensal", 1000), orcamentos: [{ id: "o2", nome: "Geral", valor: 1000, categoria_ids: [], periodo: "mensal" }] });
  assert.deepEqual(todas.map((a) => a.chave), ["orc80:o2:2026-11-01"]); // lista vazia = todas (950 de 1000)
});

test("fechamento do cartão: 4 dias não avisa, 3 avisa, hoje e passado", () => {
  const cartao = (closing_date) => [{ id: "cart", type: "CREDIT", name: "Nubank", balance: 420.5, closing_date, due_date: "2026-11-27" }];
  assert.deepEqual(alertasFechamento({ contas: cartao("2026-11-24"), hoje: "2026-11-20" }), []);
  const r = alertasFechamento({ contas: cartao("2026-11-23"), hoje: "2026-11-20" });
  assert.deepEqual(r.map((a) => a.chave), ["fechamento:cart:2026-11-23"]);
  assert.equal(r[0].titulo, "Fatura do Nubank fecha em 3 dias");
  assert.match(r[0].corpo, /Fatura atual: R\$\s?420,50 · vence 27\/11/);
  assert.equal(alertasFechamento({ contas: cartao("2026-11-20"), hoje: "2026-11-20" })[0].titulo, "Fatura do Nubank fecha hoje");
  assert.deepEqual(alertasFechamento({ contas: cartao("2026-11-19"), hoje: "2026-11-20" }), []);
  assert.deepEqual(alertasFechamento({ contas: [{ id: "cc", type: "BANK", name: "X", closing_date: "2026-11-21" }], hoje: "2026-11-20" }), []);
});

test("receita: só crédito na conta corrente, não agendado, últimos 2 dias", () => {
  const cc = [{ id: "cc", type: "BANK", name: "Inter" }, { id: "cart", type: "CREDIT", name: "Nubank" }];
  const t = (id, over) => ({ id, account_id: "cc", date: "2026-11-20", description: "EMPRESA SA", amount: 3000, scheduled: 0, ...over });
  const r = alertasReceita({ transacoes: [t("a"), t("b", { date: "2026-11-18" }), t("c", { date: "2026-11-17" }), t("d", { amount: -10 }), t("e", { scheduled: 1 }), t("f", { account_id: "cart" })], contas: cc, hoje: "2026-11-20" });
  assert.deepEqual(r.map((a) => a.chave), ["receita:a", "receita:b"]);
  assert.equal(r[0].titulo, "Entrou dinheiro");
  assert.match(r[0].corpo, /R\$\s?3\.000,00 de EMPRESA SA em Inter/);
});

test("assinaturas: hoje, amanhã, dia 31 em novembro cai em 30/11 e virada de ano", () => {
  const ass = (dia, status = "confirmada") => [{ id: "s1", nome: "Netflix", valor: 39.9, dia, status }];
  const r = alertasAssinaturas({ assinaturas: ass(31), hoje: "2026-11-29" });
  assert.deepEqual(r.map((a) => a.chave), ["assinatura:s1:2026-11-30"]);
  assert.equal(r[0].titulo, "Netflix cobra amanhã");
  assert.match(r[0].corpo, /R\$\s?39,90/);
  assert.equal(alertasAssinaturas({ assinaturas: ass(30), hoje: "2026-11-30" })[0].titulo, "Netflix cobra hoje");
  assert.deepEqual(alertasAssinaturas({ assinaturas: ass(30), hoje: "2026-11-27" }), []);
  assert.deepEqual(alertasAssinaturas({ assinaturas: ass(30, "sugerida"), hoje: "2026-11-30" }), []);
  assert.deepEqual(alertasAssinaturas({ assinaturas: ass(1), hoje: "2026-12-31" }).map((a) => a.chave), ["assinatura:s1:2027-01-01"]);
});

test("gerarAlertas concatena os alertas novos a partir de registros", () => {
  const registros = [{ tabela: "assinaturas", id: "s1", dados: { nome: "Netflix", valor: 39.9, dia: 21, status: "confirmada" } }];
  const a = gerarAlertas({ resumo: { ...base, limite: null, percentual: null }, transacoes: [], contas, avisos: [], hoje: "2026-11-20", registros });
  assert.deepEqual(a.map((x) => x.chave), ["assinatura:s1:2026-11-21"]);
});
