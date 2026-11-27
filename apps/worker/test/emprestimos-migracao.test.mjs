// test/emprestimos-migracao.test.mjs — migração dos empréstimos antigos (objetivos do Cashew) para decisões em mb_revisoes.
// Só dados sintéticos. Spec: docs/features/emprestimos-unificados/spec.md.
import { test, afterEach, mock } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, hubMudo, ORIGEM } from "./ambiente.mjs";
import { calcularEmprestimos } from "../src/emprestimosCalculo.js";

afterEach(() => mock.timers.reset());
const seg = (iso) => Math.floor(Date.parse(iso) / 1000); // Drift grava DateTime em segundos
const ALVO = "/api/emprestimos/migracao";

async function preparar({ espelho = true } = {}) {
  const amb = criarAmbiente(espelho ? { ESPELHO: "1", ESPELHO_HUB: hubMudo() } : {});
  const db = amb.env.DB;
  const token = await criarAparelho(amb.env);
  const auth = { authorization: "Bearer " + token, "content-type": "application/json" };
  let n = 0;
  const ts = () => new Date(Date.parse("2026-11-20T15:00:00.000Z") + ++n * 1000).toISOString();
  const linha = (tabela, pk, dados) => db.prepare("INSERT OR REPLACE INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) VALUES (?1, ?2, ?3, ?4, NULL, ?4, 'cel')").bind(tabela, pk, JSON.stringify(dados), ts()).run();
  if (espelho) await db.prepare("INSERT INTO espelho_meta (chave, valor) VALUES ('semeado', '1')").run();
  const objetivo = (pk, { name = pk, income = 1, amount = 0, archived = 0 } = {}) => linha("objectives", pk, { objective_pk: pk, type: 1, name, amount, income, archived });
  // valor > 0 = empréstimo (despesa, amount negativo); valor < 0 = devolução (receita)
  const lanc = (pk, obj, valor, data, { paid = 1, income } = {}) => linha("transactions", pk, {
    transaction_pk: pk, name: "x", amount: -valor, income: income ?? (valor < 0 ? 1 : 0), paid, objective_loan_fk: obj, date_created: data ? seg(data) : null });
  const decisao = (txId, d) => linha("mb_revisoes", `tx:${txId}`, { pk: `tx:${txId}`, dados: JSON.stringify({ tipo: "decisao", tx_id: txId, resposta: "emprestimo", ...d }) });
  const perdao = (grupo, valor, data) => linha("mb_revisoes", `perdao:${grupo}`, { pk: `perdao:${grupo}`, dados: JSON.stringify({ tipo: "perdao", emprestimo_id: grupo, valor, data }) });
  const get = async (q = "") => { const r = await amb.pedir(ALVO + q, { headers: auth }); return { status: r.status, corpo: await r.json() }; };
  const post = async (sub, corpo) => { const r = await amb.pedir(`${ALVO}/${sub}`, { method: "POST", headers: auth, body: JSON.stringify(corpo) }); await amb.esperar(); return { status: r.status, corpo: await r.json() }; };
  const aplicar = async (objetivos, extra = {}) => post("aplicar", { objetivos, assinatura: (await get()).corpo.assinatura, ...extra });
  const migradas = async () => (await db.prepare("SELECT pk, dados, deleted_at FROM espelho WHERE tabela = 'mb_revisoes' AND pk LIKE 'tx:mig:%' ORDER BY pk").all()).results;
  const vivas = async () => (await migradas()).filter((r) => r.deleted_at == null);
  const devido = async () => {
    const rs = (await db.prepare("SELECT pk, dados FROM espelho WHERE tabela = 'mb_revisoes' AND deleted_at IS NULL").all()).results.map((r) => JSON.parse(JSON.parse(r.dados).dados));
    return calcularEmprestimos(rs.filter((d) => d.tipo === "decisao"), rs.filter((d) => d.tipo === "perdao")).devidoCentavos;
  };
  return { ...amb, db, auth, get, post, aplicar, linha, objetivo, lanc, decisao, perdao, migradas, vivas, devido };
}
const item = (corpo, pk) => corpo.itens.find((i) => i.objetivo === pk);
const soma = (it) => it.diferencas.reduce((s, d) => s + d.centavos, 0);

test("a prévia exige token ou sessão e o espelho ativo", async () => {
  const sem = await preparar({ espelho: false });
  assert.equal((await sem.get()).status, 409);
  const { pedir } = await preparar();
  assert.equal((await pedir(ALVO)).status, 401);
  assert.equal((await pedir(ALVO + "/aplicar", { method: "POST", body: "{}" })).status, 401);
});

test("prévia: empréstimo parcialmente pago (original, pago, saldo, lançamentos) sem escrever nada", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.lanc("l2", "o1", 50, "2026-01-05T15:00:00Z");
  await t.lanc("l3", "o1", -30, "2026-01-10T15:00:00Z");
  const antes = (await t.db.prepare("SELECT COUNT(*) AS n FROM espelho").first("n"));
  const { status, corpo } = await t.get();
  assert.equal(status, 200);
  const it = item(corpo, "o1");
  assert.deepEqual([it.status, it.pessoa, it.originalCentavos, it.pagoCentavos, it.saldoAntigoCentavos, it.saldoNovoCentavos, it.lancamentos], ["pronto", "Ana", 15000, 3000, 12000, 12000, 3]);
  assert.deepEqual(it.diferencas, []);
  assert.deepEqual([corpo.totais.antesCentavos, corpo.totais.depoisCentavos, corpo.totais.diferencaCentavos], [0, 12000, 0]);
  assert.equal(await t.db.prepare("SELECT COUNT(*) AS n FROM espelho").first("n"), antes);
  assert.equal(await t.db.prepare("SELECT COUNT(*) AS n FROM emprestimos_migracao").first("n"), 0);
});

test("prévia lista o que não dá para mapear, com o motivo", async () => {
  const t = await preparar();
  await t.objetivo("devo", { income: 0 });
  await t.lanc("a", "devo", 10, "2026-01-01T15:00:00Z");
  await t.objetivo("fixo", { amount: 500 });
  await t.objetivo("vazio");
  await t.objetivo("soDev");
  await t.lanc("b", "soDev", -10, "2026-01-01T15:00:00Z");
  const { corpo } = await t.get();
  for (const pk of ["devo", "fixo", "vazio", "soDev"]) {
    assert.equal(item(corpo, pk).status, "nao_mapeavel", pk);
    assert.ok(item(corpo, pk).motivos.length, pk);
  }
  assert.equal(corpo.contagem.nao_mapeavel, 4);
});

test("pago a mais: saldo novo não fica negativo e a prévia explica cada centavo", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Beto" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.lanc("l2", "o1", -130, "2026-01-10T15:00:00Z");
  const it = item((await t.get()).corpo, "o1");
  assert.equal(it.saldoAntigoCentavos, -3000);
  assert.equal(it.saldoNovoCentavos, 0);
  assert.equal(soma(it), it.saldoAntigoCentavos - it.saldoNovoCentavos);
  assert.match(it.diferencas[0].motivo, /Pago a mais/);
});

test("devolução anterior ao primeiro empréstimo: fica como diferença; com `ajustar` entra no dia do primeiro", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Caio" });
  await t.lanc("l1", "o1", 100, "2026-02-01T15:00:00Z");
  await t.lanc("l2", "o1", -40, "2026-01-01T15:00:00Z");
  const padrao = item((await t.get()).corpo, "o1");
  assert.deepEqual([padrao.saldoAntigoCentavos, padrao.saldoNovoCentavos, soma(padrao)], [6000, 10000, -4000]);
  assert.match(padrao.diferencas[0].motivo, /anterior ao primeiro/);
  const ajustada = item((await t.get("?ajustar=o1")).corpo, "o1");
  assert.deepEqual([ajustada.saldoNovoCentavos, ajustada.diferencas.length], [6000, 0]);
  const r = await t.post("aplicar", { objetivos: ["o1"], assinatura: (await t.get()).corpo.assinatura, ajustar: ["o1"] });
  assert.equal(r.status, 200);
  const dev = (await t.vivas()).map((l) => JSON.parse(JSON.parse(l.dados).dados)).find((d) => d.resposta === "devolucao");
  assert.deepEqual([dev.data, dev.data_original], ["2026-02-01", "2026-01-01"]);
  assert.equal(await t.devido(), 6000);
});

test("sem pessoa: migra sem o campo `pessoa` (a tela mostra \"Sem pessoa\")", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "  " });
  await t.lanc("l1", "o1", 80, "2026-01-01T15:00:00Z");
  const it = item((await t.get()).corpo, "o1");
  assert.equal(it.pessoa, null);
  assert.ok(it.avisos.some((a) => /Sem pessoa/.test(a)));
  assert.equal((await t.aplicar(["o1"])).status, 200);
  const d = JSON.parse(JSON.parse((await t.vivas())[0].dados).dados);
  assert.ok(!("pessoa" in d));
  const corrigida = await t.post("aplicar", { objetivos: ["o1"], assinatura: (await t.get()).corpo.assinatura, pessoas: { o1: "Dani" } });
  assert.equal(corrigida.corpo.resultado[0].resultado, "ja_migrado"); // idempotente: não grava de novo
});

test("pessoa corrigida na aplicação entra nas decisões", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Empréstimo carro" });
  await t.lanc("l1", "o1", 80, "2026-01-01T15:00:00Z");
  assert.equal((await t.aplicar(["o1"], { pessoas: { o1: "João" } })).status, 200);
  assert.equal(JSON.parse(JSON.parse((await t.vivas())[0].dados).dados).pessoa, "João");
});

test("aplicar: tx_id sintético, transações antigas intactas e a soma antes/depois bate", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("mb:l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.lanc("l2", "o1", -30, "2026-01-10T15:00:00Z");
  await t.decisao("real1", { valor: 200, data: "2026-03-01", pessoa: "Bia" }); // já no modelo novo
  const txAntes = (await t.db.prepare("SELECT pk, dados, updated_at FROM espelho WHERE tabela IN ('transactions', 'objectives') ORDER BY pk").all()).results;
  const p = (await t.get()).corpo;
  assert.deepEqual([p.totais.antesCentavos, p.totais.depoisCentavos], [20000, 27000]);
  const r = await t.aplicar(["o1"]);
  assert.equal(r.status, 200);
  assert.deepEqual([r.corpo.antesCentavos, r.corpo.depoisCentavos], [20000, 27000]);
  assert.equal(await t.devido(), 27000);
  const ids = (await t.vivas()).map((l) => JSON.parse(JSON.parse(l.dados).dados).tx_id);
  assert.deepEqual(ids, ["mig:o1:l2", "mig:o1:mb:l1"]);
  assert.deepEqual((await t.db.prepare("SELECT pk, dados, updated_at FROM espelho WHERE tabela IN ('transactions', 'objectives') ORDER BY pk").all()).results, txAntes);
  const log = await t.db.prepare("SELECT * FROM emprestimos_migracao").first();
  assert.deepEqual([log.objetivo, log.acao, log.saldo_antigo, log.saldo_novo, log.antes, log.depois], ["o1", "aplicar", 7000, 7000, 20000, 27000]);
  assert.equal(item((await t.get()).corpo, "o1").status, "migrado");
});

test("aplicar recusa assinatura velha (409 com prévia nova) e corpo inválido", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  const assinatura = (await t.get()).corpo.assinatura;
  await t.lanc("l2", "o1", -10, "2026-01-02T15:00:00Z"); // mudou depois da prévia
  const r = await t.post("aplicar", { objetivos: ["o1"], assinatura });
  assert.equal(r.status, 409);
  assert.ok(r.corpo.previa.assinatura && r.corpo.previa.assinatura !== assinatura);
  assert.equal((await t.vivas()).length, 0);
  assert.equal((await t.post("aplicar", { objetivos: [], assinatura })).status, 400);
  assert.equal((await t.post("aplicar", { objetivos: ["o1"] })).status, 400);
});

test("em lote e idempotente: reaplicar não grava de novo; devo é recusado", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.objetivo("o2", { name: "Bia" });
  await t.lanc("l2", "o2", 50, "2026-01-02T15:00:00Z");
  await t.objetivo("devo", { income: 0 });
  await t.lanc("l3", "devo", 70, "2026-01-02T15:00:00Z");
  const r = await t.aplicar(["o1", "o2", "devo", "nada"]);
  assert.deepEqual(r.corpo.resultado.map((x) => x.resultado), ["recusado", "nao_encontrado"]);
  assert.deepEqual(r.corpo.aplicados.map((a) => a.objetivo), ["o1", "o2"]);
  assert.equal(await t.devido(), 15000);
  const n = (await t.vivas()).length;
  const de_novo = await t.aplicar(["o1", "o2"]);
  assert.deepEqual(de_novo.corpo.resultado.map((x) => x.resultado), ["ja_migrado", "ja_migrado"]);
  assert.equal((await t.vivas()).length, n);
});

test("desfazer: apaga só as decisões migradas e volta ao estado anterior", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.decisao("real1", { valor: 200, data: "2026-03-01", pessoa: "Bia" });
  await t.aplicar(["o1"]);
  assert.equal(await t.devido(), 30000);
  const r = await t.post("desfazer", { objetivo: "o1" });
  assert.equal(r.status, 200);
  assert.deepEqual([r.corpo.removidas, r.corpo.antesCentavos, r.corpo.depoisCentavos], [1, 30000, 20000]);
  assert.equal(await t.devido(), 20000);
  assert.equal((await t.vivas()).length, 0);
  assert.equal(await t.db.prepare("SELECT COUNT(*) AS n FROM espelho WHERE tabela = 'mb_revisoes' AND pk = 'tx:real1' AND deleted_at IS NULL").first("n"), 1);
  assert.equal(item((await t.get()).corpo, "o1").status, "pronto");
  assert.deepEqual((await t.db.prepare("SELECT acao FROM emprestimos_migracao ORDER BY id").all()).results.map((x) => x.acao), ["aplicar", "desfazer"]);
  assert.equal((await t.post("desfazer", { objetivo: "o1" })).status, 409); // já não está migrado
  assert.equal((await t.aplicar(["o1"])).status, 200); // e dá para migrar de novo
});

test("empréstimo perdoado no modelo novo: o desfazer é bloqueado", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.aplicar(["o1"]);
  await t.perdao("mig:o1:l1", 100, "2026-02-01");
  assert.equal(await t.devido(), 0);
  const r = await t.post("desfazer", { objetivo: "o1" });
  assert.equal(r.status, 409);
  assert.match(r.corpo.erro, /perdão/);
  assert.equal((await t.vivas()).length, 1);
});

test("pagamento novo em cima do empréstimo migrado bloqueia o desfazer", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.aplicar(["o1"]);
  await t.decisao("pix1", { resposta: "devolucao", valor: 40, data: "2026-02-01", emprestimo_id: "mig:o1:l1" });
  assert.equal((await t.post("desfazer", { objetivo: "o1" })).status, 409);
});

test("devolução antiga sem vínculo (FIFO): a prévia explica o efeito nos outros e o desfazer volta ao estado anterior", async () => {
  const t = await preparar();
  await t.decisao("e1", { valor: 100, data: "2026-01-20", pessoa: "Eva" });
  await t.decisao("d1", { resposta: "devolucao", valor: 80, data: "2026-02-01" }); // sem emprestimo_id: abate o mais antigo
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z"); // mais antigo que e1: passa a ser abatido primeiro
  const { totais } = (await t.get()).corpo;
  assert.equal(totais.antesCentavos, 2000);
  const efeito = totais.efeitosSobreOutros.reduce((s, e) => s + e.centavos, 0);
  assert.ok(totais.efeitosSobreOutros.length >= 1);
  assert.equal(totais.depoisCentavos - totais.antesCentavos, totais.saldoNovoCentavos + efeito); // Σ fecha ao centavo
  await t.aplicar(["o1"]);
  assert.equal(await t.devido(), totais.depoisCentavos);
  const r = await t.post("desfazer", { objetivo: "o1" }); // nada mudou fora da migração: volta a 2000
  assert.equal(r.status, 200);
  assert.equal(await t.devido(), 2000);
});

test("mudança de saldo de outro empréstimo depois da migração bloqueia o desfazer", async () => {
  const t = await preparar();
  await t.decisao("e1", { valor: 100, data: "2026-01-20", pessoa: "Eva" });
  await t.decisao("d1", { resposta: "devolucao", valor: 80, data: "2026-02-01" });
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.aplicar(["o1"]);
  await t.decisao("e2", { valor: 30, data: "2026-03-01", pessoa: "Fê" }); // lançamento novo no modelo novo
  const r = await t.post("desfazer", { objetivo: "o1" });
  assert.equal(r.status, 409);
  assert.ok(r.corpo.emprestimos.length >= 1);
});

test("lançamento que já tem decisão própria no modelo novo não é contado duas vezes", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("mb:abc", "o1", 100, "2026-01-01T15:00:00Z");
  await t.lanc("l2", "o1", 60, "2026-01-02T15:00:00Z");
  await t.decisao("abc", { valor: 100, data: "2026-01-01", pessoa: "Ana" }); // decisão `tx:abc` (id real)
  const it = item((await t.get()).corpo, "o1");
  assert.deepEqual([it.saldoAntigoCentavos, it.saldoNovoCentavos, soma(it)], [16000, 6000, 10000]);
  assert.match(it.diferencas[0].motivo, /Já contado/);
  await t.aplicar(["o1"]);
  assert.equal(await t.devido(), 16000); // 100 (decisão real) + 60 (migrado): a soma bate com o saldo antigo
});

test("lançamento sem data e não pago: o sem data vira diferença; o não pago é só aviso", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.lanc("l2", "o1", 25, null);
  await t.lanc("l3", "o1", 70, "2026-01-03T15:00:00Z", { paid: 0 });
  const it = item((await t.get()).corpo, "o1");
  assert.deepEqual([it.saldoAntigoCentavos, it.saldoNovoCentavos, soma(it)], [12500, 10000, 2500]);
  assert.equal(it.diferencas[0].motivo, "Sem data");
  assert.ok(it.avisos.some((a) => /não pago/.test(a)));
});

test("arquivado com saldo e sinal divergente pedem revisão", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana", archived: 1 });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.objetivo("o2", { name: "Bia" });
  await t.lanc("l2", "o2", 100, "2026-01-01T15:00:00Z", { income: 1 }); // despesa marcada como receita
  const { corpo } = await t.get();
  assert.equal(item(corpo, "o1").status, "revisar");
  assert.equal(item(corpo, "o2").status, "revisar");
  assert.equal((await t.aplicar(["o1"])).status, 200); // revisar se aplica, mas só por confirmação explícita
});

test("status migrado vem das decisões vivas: um novo semeio que as apague volta a oferecer a migração", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.aplicar(["o1"]);
  await t.db.prepare("UPDATE espelho SET dados = NULL, deleted_at = ?1 WHERE tabela = 'mb_revisoes' AND pk LIKE 'tx:mig:%'").bind(new Date().toISOString()).run();
  assert.equal(item((await t.get()).corpo, "o1").status, "pronto");
  assert.equal(await t.db.prepare("SELECT COUNT(*) AS n FROM emprestimos_migracao").first("n"), 1); // histórico preservado
});

test("lançamento antigo muda depois da migração: status desatualizado", async () => {
  const t = await preparar();
  await t.objetivo("o1", { name: "Ana" });
  await t.lanc("l1", "o1", 100, "2026-01-01T15:00:00Z");
  await t.aplicar(["o1"]);
  await t.lanc("l1", "o1", 120, "2026-01-01T15:00:00Z");
  const it = item((await t.get()).corpo, "o1");
  assert.equal(it.status, "desatualizado");
  const r = await t.post("aplicar", { objetivos: ["o1"], assinatura: (await t.get()).corpo.assinatura });
  assert.equal(r.corpo.resultado[0].resultado, "recusado"); // não migra por cima: desfaz e migra de novo
});

test("aplicar com cookie do app web exige a mesma origem", async () => {
  const t = await preparar();
  const entrar = await t.pedir("/api/login", { method: "POST", headers: { origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ senha: "senha" }) });
  const cookie = entrar.headers.get("set-cookie").split(";")[0];
  const corpo = JSON.stringify({ objetivos: ["o1"], assinatura: "x" });
  const alheia = await t.pedir(`${ALVO}/aplicar`, { method: "POST", headers: { cookie, origin: "https://outro.test", "content-type": "application/json" }, body: corpo });
  assert.equal(alheia.status, 403);
  const propria = await t.pedir(`${ALVO}/desfazer`, { method: "POST", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ objetivo: "o1" }) });
  assert.equal(propria.status, 409); // passou da autenticação; o2 não está migrado
  assert.equal((await t.pedir(ALVO, { headers: { cookie } })).status, 200); // GET da prévia com cookie
});
