// test/revisao.test.mjs — fila "Para revisar": cada tipo de item, memória por destinatário, "não conta até responder",
// sincronização entre dois aparelhos e Pix classificado que não vira salário.
import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, MODOS, extraDoModo, nomeDoModo, semearVazio } from "./ambiente.mjs";
import { somarDias } from "../src/ciclo.js";
import { tipoDeRevisao } from "../src/revisao.js";

const hoje = new Date().toLocaleDateString("sv", { timeZone: "America/Sao_Paulo" });
const dia = (d) => somarDias(hoje, -d);

// espelho = true: a flag ESPELHO liga e as respostas chegam como linhas `mb_revisoes` ({pk, dados: texto JSON}) em POST /api/espelho (o que o app faz),
// não como registros em POST /api/sync; o Worker lê as decisões do espelho.
async function ambiente(transacoes, espelho = false) {
  const amb = criarAmbiente(extraDoModo(espelho));
  const tokenA = await criarAparelho(amb.env, "Celular");
  const aparelhoA = { authorization: "Bearer " + tokenA };
  const aparelhoB = { authorization: "Bearer " + (await criarAparelho(amb.env, "Computador")) };
  if (espelho) await semearVazio(amb.pedir, tokenA);
  const agora = new Date().toISOString();
  await amb.env.DB.batch([
    amb.env.DB.prepare("INSERT INTO accounts (id, type, subtype, name, bank, updated_at) VALUES ('inter', 'BANK', 'CHECKING_ACCOUNT', 'Conta', 'Inter', ?1)").bind(agora),
    ...transacoes.map(([id, d, desc, valor]) =>
      amb.env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES (?1, 'inter', ?2, ?3, ?4, ?5, 'POSTED', 0, ?6)")
        .bind(id, dia(d), desc, valor, valor > 0 ? "CREDIT" : "DEBIT", agora)),
  ]);
  const ciclo = async (auth) => (await (await amb.pedir("/api/sync", { headers: auth })).json()).ciclo;
  const enviar = async (auth, registros) => {
    if (espelho) {
      // Categorias e ajustes de categoria vão como o app manda: linhas `categories` e `transactions` (mb:<id>); as revisões como `mb_revisoes`.
      const linhas = registros.map((r) => r.tabela === "categorias"
        ? { tabela: "categories", pk: r.id, dados: { name: r.dados.nome, income: r.dados.tipo === "receita" ? 1 : 0 }, updated_at: r.updated_at, deleted_at: r.deleted_at }
        : r.tabela === "ajustes"
          ? { tabela: "transactions", pk: `mb:${r.id}`, dados: { category_fk: r.dados.categoria_id, type: 0 }, updated_at: r.updated_at, deleted_at: r.deleted_at }
          : { tabela: `mb_${r.tabela}`, pk: r.id, dados: r.dados == null ? null : { pk: r.id, dados: JSON.stringify(r.dados) }, updated_at: r.updated_at, deleted_at: r.deleted_at });
      const r = await amb.pedir("/api/espelho", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify({ linhas }) });
      const corpo = await r.json();
      assert.deepEqual(corpo.rejeitados ?? [], [], JSON.stringify(corpo));
      return corpo;
    }
    // F5: o app só escreve pelo espelho; o modo legado grava direto no histórico `registros` (setup).
    await amb.env.DB.batch(registros.map((r) => amb.env.DB.prepare("INSERT INTO registros (tabela, id, dados, updated_at, deleted_at, server_at) VALUES (?1, ?2, ?3, ?4, ?5, ?4) ON CONFLICT(tabela, id) DO UPDATE SET dados = excluded.dados, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at")
      .bind(r.tabela, r.id, r.dados ? JSON.stringify(r.dados) : null, r.updated_at, r.deleted_at ?? null)));
    const corpo = { ok: true, rejeitados: [] };
    assert.deepEqual(corpo.rejeitados ?? [], [], JSON.stringify(corpo));
    return corpo;
  };
  return { amb, A: aparelhoA, B: aparelhoB, ciclo, enviar, espelho };
}

const salarios = [["s1", 70, "SALARIO EMPRESA", 7500], ["s2", 40, "SALARIO EMPRESA", 7500], ["s3", 10, "SALARIO EMPRESA", 7500]];
const decisao = (tx, resposta, extra = {}) => ({
  tabela: "revisoes", id: `tx:${tx}`, updated_at: new Date().toISOString(), deleted_at: null,
  dados: { tipo: "decisao", tx_id: tx, resposta, ...extra },
});
const destino = (nome, categoria_id) => ({
  tabela: "revisoes", id: `dest:${nome}`, updated_at: new Date().toISOString(), deleted_at: null,
  dados: { tipo: "destinatario", destinatario: nome, categoria_id },
});

test("tipoDeRevisao reconhece os três tipos de Pix e envio ao Santander", () => {
  assert.deepEqual(tipoDeRevisao({ description: "Pix enviado: João Silva", amount: -50 }), { tipo: "pix_enviado", destinatario: "JOAO SILVA" });
  assert.deepEqual(tipoDeRevisao({ description: "PIX ENVIADO SANTANDER BRASIL", amount: -500, category: "Same person transfer" }), { tipo: "envio_santander" });
  assert.deepEqual(tipoDeRevisao({ description: "Pix recebido: Maria", amount: 80 }), { tipo: "pix_recebido" });
  assert.equal(tipoDeRevisao({ description: "MERCADO", amount: -50 }), null);
  assert.equal(tipoDeRevisao({ description: "Aplicação Santander CDB", amount: -50 }), null);
  assert.equal(tipoDeRevisao({ description: "Pix enviado: João", amount: -50, scheduled: 1 }), null);
});

for (const espelho of MODOS) test(`cada tipo de item entra na fila do ciclo atual; o que é anterior ao ciclo e o salário ficam de fora ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo } = await ambiente([...salarios,
    ["p1", 5, "Pix enviado: Joao Silva", -50], ["e1", 4, "PIX ENVIADO SANTANDER", -800], ["r1", 3, "Pix recebido: Maria", 90],
    ["velho", 20, "Pix enviado: Antigo", -10], ["mercado", 2, "MERCADO", -100]], espelho);
  const fila = (await ciclo(A)).revisar;
  assert.deepEqual(fila.map((i) => [i.tipo, i.tx_id, i.valor]), [["pix_recebido", "r1", 90], ["envio_santander", "e1", 800], ["pix_enviado", "p1", 50]]);
  assert.equal(fila[2].destinatario, "JOAO SILVA");
});

for (const espelho of MODOS) test(`não conta até responder: Santander fica fora do gasto; Pix enviado conta; ajuda vira gasto ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo, enviar } = await ambiente([...salarios, ["p1", 5, "Pix enviado: Joao", -50], ["e1", 4, "PIX ENVIADO SANTANDER", -800]], espelho);
  assert.equal((await ciclo(A)).gasto, 50);
  await enviar(A, [decisao("e1", "ajuda")]);
  assert.equal((await ciclo(A)).gasto, 850);
  await enviar(A, [{ ...decisao("e1", "emprestimo", { valor: 800, data: dia(4), pessoa: "Pai" }), updated_at: new Date(Date.now() + 1000).toISOString() }]);
  const c = await ciclo(A);
  assert.equal(c.gasto, 50);
  assert.deepEqual(c.revisar.map((i) => i.tx_id), ["p1"]);
});

for (const espelho of MODOS) test(`envio ao Santander de ciclo anterior sem resposta não é reclassificado ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo } = await ambiente([...salarios, ["velho", 20, "PIX ENVIADO SANTANDER", -300], ["novo", 4, "PIX ENVIADO SANTANDER", -800]], espelho);
  const c = await ciclo(A);
  assert.equal(c.gasto, 0);
  assert.deepEqual(c.revisar.map((i) => i.tx_id), ["novo"]);
});

for (const espelho of MODOS) test(`Pix enviado: a resposta e a memória do destinatário tiram da fila os próximos Pix para a mesma pessoa ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo, enviar } = await ambiente([...salarios, ["p1", 5, "Pix enviado: Joao Silva", -50], ["p2", 2, "Pix enviado: Joao Silva", -70], ["p3", 1, "Pix enviado: Ana", -20]], espelho);
  assert.equal((await ciclo(A)).revisar.length, 3);
  await enviar(A, [decisao("p1", "categoria", { categoria_id: "cat-lazer", destinatario: "JOAO SILVA" }), destino("JOAO SILVA", "cat-lazer")]);
  assert.deepEqual((await ciclo(A)).revisar.map((i) => i.tx_id), ["p3"]);
});

for (const espelho of MODOS) test(`sincroniza entre dois aparelhos: resposta do celular some da fila do computador ${nomeDoModo(espelho)}`, async () => {
  const { A, B, ciclo, enviar, amb } = await ambiente([...salarios, ["e1", 4, "PIX ENVIADO SANTANDER", -800], ["r1", 3, "Pix recebido: Maria", 90]], espelho);
  assert.equal((await ciclo(B)).revisar.length, 2);
  await enviar(A, [decisao("r1", "devolucao", { valor: 90, data: dia(3) })]);
  assert.deepEqual((await ciclo(B)).revisar.map((i) => i.tx_id), ["e1"]);
  if (espelho) { // o computador recebe a decisão pelo pull do espelho
    const puxado = await (await amb.pedir("/api/espelho", { headers: B })).json();
    assert.equal(JSON.parse(puxado.linhas.find((l) => l.tabela === "mb_revisoes").dados.dados).resposta, "devolucao");
    return;
  }
  const puxado = await (await amb.pedir("/api/sync", { headers: B })).json();
  const reg = puxado.registros.find((r) => r.tabela === "revisoes");
  assert.equal(reg.dados.resposta, "devolucao"); // o computador recebe a decisão pelo pull normal
});

for (const espelho of MODOS) test(`Pix classificado não vira salário: Pix de valor parecido só vira o ciclo se o usuário não respondeu ${nomeDoModo(espelho)}`, async () => {
  const base = [["s1", 70, "SALARIO EMPRESA", 7500], ["s2", 40, "SALARIO EMPRESA", 7500], ["r1", 3, "Pix recebido: Pai", 7400]];
  const sem = await ambiente(base, espelho);
  const antes = await sem.ciclo(sem.A);
  assert.equal(antes.inicio, dia(3)); // sem resposta, o valor parecido é tratado como salário e não vai para a fila
  assert.equal(antes.revisar.length, 0);
  const com = await ambiente(base, espelho);
  await com.enviar(com.A, [decisao("r1", "devolucao")]);
  const depois = await com.ciclo(com.A);
  assert.equal(depois.inicio, dia(40)); // a decisão do usuário vence: o Pix não vira o ciclo
  assert.equal(depois.salarioNaoDetectado, true);
  assert.deepEqual(depois.revisar.map((i) => i.tipo), ["salario_nao_detectado"]);
});

for (const espelho of MODOS) test(`reembolso abate o gasto como estorno genérico; devolução e renda não mexem no gasto ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo, enviar } = await ambiente([...salarios, ["g1", 6, "MERCADO", -200], ["r1", 3, "Pix recebido: Maria", 60], ["r2", 2, "Pix recebido: Pai", 100]], espelho);
  assert.equal((await ciclo(A)).gasto, 200);
  await enviar(A, [decisao("r1", "reembolso"), decisao("r2", "renda")]);
  const c = await ciclo(A);
  assert.equal(c.gasto, 140);
  assert.equal(c.revisar.length, 0);
});

// Conta rachada com troco (caso sintético de 18/11): gasto 76,23, Pix recebido +50 ligado ao gasto, Pix enviado −11,88 de troco à mesma pessoa.
// O Geral conta a parte de quem pagou: 76,23 − 50 + 11,88 = 38,11, igual ao que o app mostra.
const racha = [...salarios, ["g1", 2, "99food Pizza Hut", -76.23], ["r1", 2, "Pix recebido - Ana Souza", 50], ["t1", 1, "Pix enviado devolvido - Ana Souza", -11.88]];
for (const espelho of MODOS) test(`troco devolve parte do reembolso: o Geral conta 76,23 − 50 + 11,88 = 38,11 ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo, enviar } = await ambiente(racha, espelho);
  await enviar(A, [decisao("r1", "reembolso", { reembolso_de: "g1" }), decisao("t1", "troco", { troco_de: "r1" })]);
  const c = await ciclo(A);
  assert.ok(Math.abs(c.gasto - 38.11) < 0.005, `gasto ${c.gasto}`);
  assert.equal(c.revisar.some((i) => i.tx_id === "t1"), false);
});

for (const espelho of MODOS) test(`troco de reembolso desligado do gasto volta para a fila e não abate nada ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo, enviar } = await ambiente(racha, espelho);
  await enviar(A, [decisao("r1", "reembolso"), decisao("t1", "troco", { troco_de: "r1" })]); // reembolso sem `reembolso_de`
  const c = await ciclo(A);
  assert.equal(c.revisar.some((i) => i.tx_id === "t1"), true);
});

const categoriaEmprestimo = { tabela: "categorias", id: "cat-emp", updated_at: new Date().toISOString(), deleted_at: null, dados: { tipo: "despesa", nome: "Empréstimo", pluggy: [] } };
const perdao = (emprestimo, valor, data) => ({ tabela: "revisoes", id: `perdao:${emprestimo}`, updated_at: new Date().toISOString(), deleted_at: null, dados: { tipo: "perdao", emprestimo_id: emprestimo, valor, data } });

for (const espelho of MODOS) test(`empréstimo com pessoa sai do Geral em Pix enviado e em compra de débito; o perdão vira gasto na data ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo, enviar } = await ambiente([...salarios, ["p1", 6, "Pix enviado: Isabel Souza", -250], ["u1", 5, "UBER *TRIP", -15.95], ["m1", 3, "MERCADO", -100]], espelho);
  assert.equal((await ciclo(A)).gasto, 365.95);
  await enviar(A, [decisao("p1", "emprestimo", { pessoa: "Isabel", valor: 250, data: dia(6) }), decisao("u1", "emprestimo", { pessoa: "Isabel", valor: 15.95, data: dia(5) })]);
  const c = await ciclo(A);
  assert.equal(c.gasto, 100);
  assert.equal(c.revisar.length, 0);
  await enviar(A, [perdao("p1", 40, dia(1))]);
  assert.equal((await ciclo(A)).gasto, 140);
});

for (const espelho of MODOS) test(`empréstimo antigo sem pessoa (categoria Empréstimo ou decisão sem pessoa) volta à fila e some ao informar a pessoa ou recategorizar ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo, enviar } = await ambiente([...salarios, ["p1", 6, "Pix enviado: Isabel Souza", -250], ["u1", 5, "UBER *TRIP", -15.95], ["e1", 4, "PIX ENVIADO SANTANDER", -60]], espelho);
  await enviar(A, [categoriaEmprestimo, decisao("p1", "categoria", { categoria_id: espelho ? "cashew:cat-emp" : "cat-emp", destinatario: "ISABEL SOUZA" }), decisao("e1", "emprestimo", { valor: 60, data: dia(4) }),
    { tabela: "ajustes", id: "u1", updated_at: new Date().toISOString(), deleted_at: null, dados: { categoria_id: "cat-emp" } }]);
  let c = await ciclo(A);
  assert.deepEqual(c.revisar.filter((i) => i.tipo === "emprestimo_sem_pessoa").map((i) => i.tx_id).sort(), ["e1", "p1", "u1"]);
  assert.equal(c.revisar.find((i) => i.tx_id === "p1").destinatario, "ISABEL SOUZA");
  await enviar(A, [decisao("p1", "emprestimo", { pessoa: "Isabel", valor: 250, data: dia(6) }), decisao("e1", "emprestimo", { pessoa: "Pai", valor: 60, data: dia(4) }),
    decisao("u1", "categoria", { categoria_id: "cat-outra", recategorizado: 1 })]);
  c = await ciclo(A);
  assert.deepEqual(c.revisar.filter((i) => i.tipo === "emprestimo_sem_pessoa"), []);
});

for (const espelho of MODOS) test(`Pix que paga empréstimo e passa do saldo: a sobra para reembolso abate só ela do gasto ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo, enviar } = await ambiente([...salarios, ["g1", 6, "MERCADO", -200], ["r1", 3, "Pix recebido: Maria", 100]], espelho);
  await enviar(A, [decisao("r1", "devolucao", { emprestimo_id: "x", sobra: 30, sobra_para: "reembolso", reembolso_de: "g1" })]);
  assert.equal((await ciclo(A)).gasto, 170);
});

for (const espelho of MODOS) test(`salário não detectado em 35 dias vira item com candidatas; PUT /api/config por token marca o salário ${nomeDoModo(espelho)}`, async () => {
  const { A, ciclo, amb } = await ambiente([["s1", 80, "SALARIO EMPRESA", 7500], ["x1", 12, "TRANSFERENCIA RECEBIDA EMPRESA", 6000], ["x2", 6, "PIX RECEBIDO EXTRA", 100]], espelho);
  const c = await ciclo(A);
  assert.equal(c.salarioNaoDetectado, true);
  const item = c.revisar.find((i) => i.tipo === "salario_nao_detectado");
  assert.equal(item.candidatos[0].tx_id, "x1");
  const r = await amb.pedir("/api/config", { method: "PUT", headers: { ...A, "content-type": "application/json" }, body: JSON.stringify({ salario_id: "x1" }) });
  assert.equal(r.status, 200);
  const depois = await ciclo(A);
  assert.equal(depois.salarioNaoDetectado, false);
  assert.equal(depois.inicio, dia(12));
  assert.equal(depois.revisar.some((i) => i.tipo === "salario_nao_detectado"), false);
});

for (const espelho of MODOS) test(`PUT /api/config exige token ou sessão ${nomeDoModo(espelho)}`, async () => {
  const { amb } = await ambiente([], espelho);
  const r = await amb.pedir("/api/config", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ limite: 100 }) });
  assert.equal(r.status, 401);
});
