// test/alertas.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { contextoDeRegistros } from "@meu-banco/core";
import { emSilencio, ID_GERAL, orcamentoGeral, consumoGeral, alertasGeral, comprasNovas, alertaCompras, alertasFatura, alertasConexao, alertasRevisao, linhasMetas, resumoSemanal } from "../src/alertas.js";

const sp = (s) => s.replace(/\u00a0/g, " "); // o Intl usa espaço não separável após R$
const contas = [{ id: "cc", type: "BANK" }, { id: "cart", type: "CREDIT" }];
const compra = (id, date, amount, extra = {}) => ({ id, account_id: "cart", date, description: "POSTO SHELL", amount, category: "Gas stations", scheduled: 0, ...extra });
const resumo = { inicio: "2026-11-05", fim: "2026-12-04", limite: null, gasto: 1000, consumido: 1000, falta: null, percentual: null, diasRestantes: 14 };
const geralReg = (valor, id = ID_GERAL) => ({ tabela: "orcamentos", id, dados: { nome: "Geral", valor, categoria_ids: [], periodo: "ciclo" } });
const geralCom = (valor, consumido) => consumoGeral({ registros: [geralReg(valor)], transacoes: [], contas, resumo: { ...resumo, gasto: consumido, consumido } });

test("silêncio 22h–7h em BRT: bordas 21:59, 22:00, 06:59 e 07:00", () => {
  assert.equal(emSilencio(new Date("2026-11-09T00:59:00Z")), false); // 21:59 BRT
  assert.equal(emSilencio(new Date("2026-11-09T01:00:00Z")), true);  // 22:00 BRT
  assert.equal(emSilencio(new Date("2026-11-09T09:59:00Z")), true);  // 06:59 BRT
  assert.equal(emSilencio(new Date("2026-11-09T10:00:00Z")), false); // 07:00 BRT
});

test("Geral: só o orçamento Geral conta; sem valor definido não há aviso", () => {
  assert.equal(orcamentoGeral([geralReg(0)]), null);
  assert.equal(orcamentoGeral([{ tabela: "orcamentos", id: "o1", dados: { nome: "Mercado", valor: 500 } }]), null);
  assert.equal(orcamentoGeral([geralReg(2000)]).valor, 2000);
  assert.deepEqual(alertasGeral(null), []);
  const arquivado = geralReg(2000);
  arquivado.dados = { ...arquivado.dados, arquivado: 1 };
  assert.equal(orcamentoGeral([arquivado]), null);
});

test("Geral: gasto só em outro orçamento não conta; gasto sem escolha conta", () => {
  const transacoes = [compra("a", "2026-11-06", 300), compra("b", "2026-11-07", 200)];
  const registros = [geralReg(2000), { tabela: "ajustes", id: "b", dados: { orcamento_ids: ["cashew:mb:orc:mercado"] } }];
  const g = consumoGeral({ registros, transacoes, contas, resumo: { ...resumo, gasto: 500, consumido: 500 } });
  assert.equal(g.consumido, 300);
  assert.equal(g.falta, 1700);
  const dois = [{ tabela: "ajustes", id: "b", dados: { orcamento_ids: ["cashew:mb:orc:mercado", ID_GERAL] } }];
  assert.equal(consumoGeral({ registros: [geralReg(2000), ...dois], transacoes, contas, resumo: { ...resumo, gasto: 500, consumido: 500 } }).consumido, 500);
});

test("Geral: 80% e 100% com chave por ciclo; passou direto de 100% só avisa 100%", () => {
  const chaves = (c) => alertasGeral(geralCom(1000, c)).map((a) => a.chave);
  assert.deepEqual(chaves(790), []);
  assert.deepEqual(chaves(800), [`orc80:${ID_GERAL}:2026-11-05`]);
  assert.deepEqual(chaves(1000), [`orc80:${ID_GERAL}:2026-11-05`]); // exatamente o valor ainda não estourou
  assert.deepEqual(chaves(1001), [`orc100:${ID_GERAL}:2026-11-05`]);
  assert.deepEqual(chaves(800), chaves(800)); // mesma chave a cada avaliação: INSERT OR IGNORE não repete
  const [a80] = alertasGeral(geralCom(1000, 850));
  assert.equal(a80.titulo, "80% do orçamento Geral");
  assert.match(a80.corpo, /R\$\s?850,00 de R\$\s?1\.000,00 \(05\/11 a 04\/12\)\. Faltam R\$\s?150,00/);
  const [a100] = alertasGeral(geralCom(1000, 1200));
  assert.equal(a100.titulo, "Orçamento Geral estourado");
  assert.match(a100.corpo, /R\$\s?200,00 acima/);
});

test("compras: primeira avaliação só registra; depois só as novas com gasto, uma notificação para o lote", () => {
  const hoje = "2026-11-10";
  const t1 = compra("a", "2026-11-09", 50);
  const primeira = comprasNovas({ transacoes: [t1], contas, vistas: null, hoje });
  assert.deepEqual(primeira.novas, []);
  assert.deepEqual(primeira.ids, ["a"]);
  const entrada = (extra) => comprasNovas({ transacoes: [t1, compra("b", "2026-11-10", 70), compra("c", "2026-11-10", 50), compra("agend", "2026-11-12", 9, { scheduled: 1 }), compra("antiga", "2026-10-01", 80), compra("estorno", "2026-11-10", -30), ...extra], contas, vistas: ["a"], hoje });
  const { novas, ids } = entrada([]);
  assert.deepEqual(novas.map((t) => t.id), ["b", "c"]);
  assert.ok(ids.includes("estorno") && !ids.includes("antiga") && !ids.includes("agend"));
  const [n] = alertaCompras({ compras: novas, contas, geral: geralCom(1000, 400), agora: "2026-11-10T15:07:00.000Z" });
  assert.equal(n.chave, "compras:2026-11-10T15:07:00.000Z");
  assert.equal(sp(n.titulo), "2 compras, R$ 120,00");
  assert.equal(sp(n.corpo), "Faltam R$ 600,00 no Geral até 04/12.");
  assert.deepEqual(comprasNovas({ transacoes: [t1, compra("b", "2026-11-10", 70)], contas, vistas: ["a", "b"], hoje }).novas, []); // 2ª avaliação: nada novo
});

test("compras: uma compra, Geral estourado e Geral sem valor", () => {
  const t = [compra("a", "2026-11-10", 35.5)];
  assert.equal(sp(alertaCompras({ compras: t, contas, geral: geralCom(1000, 1100), agora: "x" })[0].titulo), "1 compra, R$ 35,50");
  assert.match(alertaCompras({ compras: t, contas, geral: geralCom(1000, 1100), agora: "x" })[0].corpo, /R\$\s?100,00 acima do Geral\./);
  assert.equal(alertaCompras({ compras: t, contas, geral: null, agora: "x" })[0].corpo, "Defina o valor do Geral para ver quanto falta.");
  assert.deepEqual(alertaCompras({ compras: [], contas, geral: null, agora: "x" }), []);
});

test("fatura do Inter: avisa de 3 dias antes até o vencimento, uma chave por vencimento", () => {
  const cartao = (due_date, balance = 420.5) => [{ id: "cart", type: "CREDIT", name: "Cartão Inter · final 1234", balance, due_date }];
  assert.deepEqual(alertasFatura({ contas: cartao("2026-11-24"), hoje: "2026-11-20" }), []); // 4 dias
  const r = alertasFatura({ contas: cartao("2026-11-23"), hoje: "2026-11-20" });
  assert.deepEqual(r.map((a) => a.chave), ["fatura:cart:2026-11-23"]);
  assert.equal(r[0].titulo, "Fatura do Cartão Inter vence em 3 dias");
  assert.match(r[0].corpo, /R\$\s?420,50 · vence 23\/11/);
  assert.equal(alertasFatura({ contas: cartao("2026-11-21"), hoje: "2026-11-20" })[0].titulo, "Fatura do Cartão Inter vence amanhã");
  assert.equal(alertasFatura({ contas: cartao("2026-11-20"), hoje: "2026-11-20" })[0].titulo, "Fatura do Cartão Inter vence hoje");
  assert.deepEqual(alertasFatura({ contas: cartao("2026-11-19"), hoje: "2026-11-20" }), []); // vencida
  assert.deepEqual(alertasFatura({ contas: cartao("2026-11-22", 0), hoje: "2026-11-20" }), []); // nada a pagar
  assert.deepEqual(alertasFatura({ contas: [{ id: "cc", type: "BANK", name: "X", due_date: "2026-11-21", balance: 9 }], hoje: "2026-11-20" }), []);
});

test("conexão caída: um aviso por queda; some da lista, volta a poder avisar", () => {
  const avisos = [{ item_id: "i1", banco: "Banco Inter", mensagem: "m" }];
  const r = alertasConexao({ avisos, avisadas: [], agora: "2026-11-10T15:07:00.000Z" });
  assert.equal(r[0].chave, "conexao:i1:2026-11-10T15:07:00.000Z");
  assert.equal(r[0].titulo, "Banco Inter desconectou");
  assert.deepEqual(alertasConexao({ avisos, avisadas: ["i1"], agora: "x" }), []); // ainda caída: não repete
  assert.equal(alertasConexao({ avisos, avisadas: [], agora: "y" }).length, 1); // voltou e caiu de novo
});

test("para revisar: um aviso por item recente (máx. 5), salário por mês", () => {
  const item = (n, data = "2026-11-10") => ({ id: "tx:" + n, tipo: "pix_enviado", tx_id: n, data, descricao: "Pix para Ana", valor: 120 });
  const r = alertasRevisao({ revisar: [item("a"), item("velho", "2026-11-01"), { id: "salario", tipo: "salario_nao_detectado", dias: 40 }], hoje: "2026-11-10" });
  assert.deepEqual(r.map((a) => a.chave), ["revisar:tx:a", "revisar:salario:2026-11"]);
  assert.equal(sp(r[0].titulo), "Pix enviado: R$ 120,00");
  assert.equal(alertasRevisao({ revisar: Array.from({ length: 9 }, (_, i) => item("n" + i)), hoje: "2026-11-10" }).length, 5);
});

test("metas: mesmo texto do app", () => {
  const saldos = new Map([["a1", 3000], ["a2", 1000]]);
  const l = linhasMetas({ saldos, hoje: "2026-11-10", metas: [
    { nome: "Reserva", valor_alvo: 10000, aplicacao_ids: ["a1", "a2"], prazo: "2026-12-10" },
    { nome: "Viagem", aplicacao_ids: ["a1"] },
    { nome: "Feita", valor_alvo: 2000, aplicacao_ids: ["a1"] },
  ] });
  assert.equal(sp(l[0]), "Reserva: R$ 4.000,00 de R$ 10.000,00 (40%), faltam R$ 6.000,00, prazo 10/12 (30 dias)");
  assert.equal(sp(l[1]), "Viagem: R$ 3.000,00, defina o valor da meta");
  assert.equal(sp(l[2]), "Feita: R$ 3.000,00 de R$ 2.000,00 (100%), meta atingida");
});

test("resumo semanal: semana, ciclo, Geral, maiores categorias, fila e metas", () => {
  const registros = [geralReg(2000), { tabela: "categorias", id: "mercado", dados: { nome: "Mercado", tipo: "despesa", pluggy: ["Groceries"] } }];
  const transacoes = [compra("x", "2026-11-18", 100, { category: "Groceries" }), compra("y", "2026-11-19", 300, { category: "Groceries" }), compra("z", "2026-11-20", 50), compra("velha", "2026-11-06", 900)];
  const r = resumoSemanal({
    resumo: { ...resumo, consumido: 1350 }, transacoes, contas, hoje: "2026-11-22", registros, ctx: contextoDeRegistros(registros.map((x) => ({ ...x, deleted_at: null, dados: x.dados }))),
    geral: consumoGeral({ registros, transacoes, contas, resumo: { ...resumo, gasto: 1350, consumido: 1350 } }),
    revisar: [{ id: "tx:1" }, { id: "tx:2" }], metas: ["Reserva: R$ 4.000,00 de R$ 10.000,00 (40%)"],
  });
  assert.equal(r.chave, "semana:2026-11-22");
  assert.equal(r.titulo, "Resumo da semana");
  const linhas = r.corpo.split("\n");
  assert.match(linhas[0], /^Semana: R\$\s?450,00\. Ciclo \(05\/11 a 04\/12\): R\$\s?1\.350,00\.$/);
  assert.match(linhas[1], /^Geral: R\$\s?1\.350,00 de R\$\s?2\.000,00, faltam R\$\s?650,00\.$/);
  assert.equal(sp(linhas[2]), "Maiores: Combustível R$ 950,00, Mercado R$ 400,00.");
  assert.equal(linhas[3], "Para revisar: 2 itens.");
  assert.match(linhas[4], /^Reserva/);
  assert.doesNotMatch(r.corpo, /undefined|null/);
});

test("Geral: parcela futura do cartão não entra (o app só conta quando ela cai)", () => {
  const g = consumoGeral({ registros: [geralReg(3000)], transacoes: [compra("p", "2026-11-20", 500, { scheduled: 1 })], contas, resumo: { ...resumo, gasto: 2000, consumido: 2500 } });
  assert.equal(g.consumido, 2000);
  assert.deepEqual(alertasGeral(g), []);
});

test("metas: arquivada fica fora do resumo", () => {
  assert.deepEqual(linhasMetas({ metas: [{ nome: "Velha", valor_alvo: 100, arquivado: 1 }], saldos: new Map(), hoje: "2026-11-22" }), []);
});
