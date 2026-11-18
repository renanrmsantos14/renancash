import { test } from "node:test";
import assert from "node:assert/strict";
import { validarLote } from "@meu-banco/core";
import { criarD1 } from "./d1.mjs";
import { converterCashew, sqlImportacao } from "../scripts/cashew.mjs";

const AGORA = "2026-11-09T12:00:00.000Z";
// 1762689600 = 09/11/2025 12:00 UTC (2025-11-09 em SP); 1798761600 = 01/01/2027 00:00 UTC (2026-12-31 em SP)
const dados = {
  categorias: [
    { category_pk: "1", name: "Mercado", income: 0, colour: "0xff4caf50", icon_name: "cart.png", main_category_pk: null, order: 2 },
    { category_pk: "2", name: "Hortifruti", income: 0, colour: null, icon_name: null, main_category_pk: "1", order: 0 },
    { category_pk: "3", name: "Salário", income: 1, colour: null, icon_name: null, main_category_pk: null, order: 1 },
  ],
  orcamentos: [
    { budget_pk: "b1", name: "Casa", amount: 900, category_fks: '["1","2"]', archived: 0 },
    { budget_pk: "b2", name: "Velho", amount: 100, category_fks: null, archived: 1 },
  ],
  objetivos: [
    { objective_pk: "o1", type: 0, name: "Viagem", amount: 5000, end_date: 1798761600, income: 0 },
    { objective_pk: "o2", type: 1, name: "João", amount: 300, end_date: null, income: 1 },
  ],
  transacoes: [
    { transaction_pk: "t1", name: "Feira", amount: -42.5, note: "", category_fk: "2", wallet_fk: "w1", date_created: 1762689600, objective_fk: null },
    { transaction_pk: "t2", name: "", amount: 200, note: "guardar", category_fk: null, wallet_fk: "w1", date_created: 1762689600, objective_fk: "o1" },
    { transaction_pk: "t3", name: "João pagou", amount: 100, note: null, category_fk: null, wallet_fk: null, date_created: 1762689600, objective_fk: "o2" },
    { transaction_pk: "mb:abc", name: "Do Meu Banco", amount: -10, note: null, category_fk: null, wallet_fk: "w1", date_created: 1762689600, objective_fk: null },
  ],
  carteiras: [{ wallet_pk: "w1", name: "Inter" }],
};

test("converte categorias, orçamentos, metas, empréstimos e lançamentos", () => {
  const regs = converterCashew(dados, AGORA);
  const por = (t, id) => regs.find((r) => r.tabela === t && r.id === id)?.dados;
  assert.deepEqual(por("categorias", "cashew:2"), { nome: "Hortifruti", tipo: "despesa", pai_id: "cashew:1", ordem: 0 });
  assert.equal(por("categorias", "cashew:3").tipo, "receita");
  assert.equal(por("categorias", "cashew:1").cor, "0xff4caf50");
  assert.deepEqual(por("orcamentos", "cashew:b1"), { nome: "Casa", valor: 900, categoria_ids: ["cashew:1", "cashew:2"], periodo: "mensal" });
  assert.equal(por("orcamentos", "cashew:b2"), undefined, "arquivado fica de fora");
  assert.deepEqual(por("metas", "cashew:o1"), { nome: "Viagem", valor_alvo: 5000, valor_atual: 200, prazo: "2026-12-31" });
  assert.deepEqual(por("dividas", "cashew:o2"), { tipo: "emprestimo", nome: "João", sentido: "me_devem", valor_total: 300, pago: 100 });
  assert.deepEqual(por("lancamentos", "cashew:t1"), { data: "2025-11-09", descricao: "Feira", valor: -42.5, categoria_id: "cashew:2", carteira: "Inter" });
  assert.deepEqual(por("lancamentos", "cashew:t2"), { data: "2025-11-09", descricao: "Sem descrição", valor: 200, carteira: "Inter", nota: "guardar" });
  assert.equal(regs.some((r) => r.id === "cashew:mb:abc"), false, "transação vinda do Meu Banco fica de fora");
  assert.equal(regs.length, 9); // 3 categorias + 1 orçamento + 1 meta + 1 dívida + 3 lançamentos
});

test("tudo o que sai passa na validação do core", () => {
  const r = validarLote(converterCashew(dados, AGORA), AGORA);
  assert.ok("registros" in r);
  assert.deepEqual(r.rejeitados, []);
});

test("SQL gerado roda no D1 e rodar de novo não duplica nem sobrescreve", async () => {
  const db = criarD1();
  const sql = sqlImportacao(converterCashew(dados, AGORA), AGORA);
  await db.exec(sql);
  await db.prepare("UPDATE registros SET dados = '{\"nome\":\"Editado\",\"tipo\":\"despesa\"}' WHERE id = 'cashew:1'").run();
  await db.exec(sql);
  assert.equal(await db.prepare("SELECT count(*) AS n FROM registros").first("n"), 9);
  assert.equal(JSON.parse(await db.prepare("SELECT dados FROM registros WHERE id = 'cashew:1'").first("dados")).nome, "Editado");
});

test("apóstrofo no nome vira SQL válido e volta igual do D1", async () => {
  const db = criarD1();
  const regs = converterCashew({ ...dados, categorias: [{ category_pk: "9", name: "Pao d'Acucar", income: 0, colour: null, icon_name: null, main_category_pk: null, order: 0 }], orcamentos: [], objetivos: [], transacoes: [] }, AGORA);
  await db.exec(sqlImportacao(regs, AGORA));
  assert.equal(JSON.parse(await db.prepare("SELECT dados FROM registros WHERE id = 'cashew:9'").first("dados")).nome, "Pao d'Acucar");
});
