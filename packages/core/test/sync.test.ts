import { test } from "node:test";
import assert from "node:assert/strict";
import { validarLote, validarLinhasEspelho, vence, mesclar, inicioDaJanela, chave, dadosValidos, MAX_LOTE, type Registro } from "../src/index.ts";

const AGORA = "2026-11-09T12:00:00.000Z";
const cat = (over: Partial<Registro> = {}): Registro => ({
  tabela: "categorias", id: "c1", dados: { nome: "Mercado", tipo: "despesa" },
  updated_at: "2026-11-09T11:00:00.000Z", deleted_at: null, ...over,
});

test("lote válido passa e normaliza as datas", () => {
  const r = validarLote([cat({ updated_at: "2026-11-09T08:00:00-03:00" })], AGORA);
  assert.ok("registros" in r);
  assert.equal(r.registros[0].updated_at, "2026-11-09T11:00:00.000Z");
  assert.deepEqual(r.rejeitados, []);
});

test("entrada que não é lista ou passa do limite é erro do lote inteiro", () => {
  assert.deepEqual(validarLote({}, AGORA), { erro: "registros deve ser uma lista" });
  const muitos = Array.from({ length: MAX_LOTE + 1 }, (_, i) => cat({ id: "c" + i }));
  assert.ok("erro" in validarLote(muitos, AGORA));
});

test("registro inválido é rejeitado sem derrubar o lote", () => {
  const r = validarLote([
    cat(),
    cat({ tabela: "x" as never }),
    cat({ id: "" }),
    cat({ updated_at: "ontem" }),
    cat({ dados: { nome: "Sem tipo" } }),
    cat({ dados: { nome: "Mercado", tipo: "despesa", extra: "y".repeat(8200) } }),
  ], AGORA);
  assert.ok("registros" in r);
  assert.equal(r.registros.length, 1);
  assert.deepEqual(r.rejeitados.map((x) => x.motivo), [
    "tabela desconhecida", "id inválido", "updated_at inválido", "dados inválidos", "dados acima de 8 KB",
  ]);
});

test("relógio adiantado mais de 5 min vira o horário do servidor", () => {
  const r = validarLote([cat({ updated_at: "2026-11-09T12:06:00.000Z" }), cat({ id: "c2", updated_at: "2026-11-09T12:04:00.000Z" })], AGORA);
  assert.ok("registros" in r);
  assert.equal(r.registros[0].updated_at, AGORA);
  assert.equal(r.registros[1].updated_at, "2026-11-09T12:04:00.000Z");
});

test("exclusão aceita dados nulos e sai com dados null", () => {
  const r = validarLote([cat({ dados: null, deleted_at: "2026-11-09T11:30:00.000Z" })], AGORA);
  assert.ok("registros" in r);
  assert.equal(r.registros[0].dados, null);
  assert.equal(r.registros[0].deleted_at, "2026-11-09T11:30:00.000Z");
});

test("campos opcionais aceitam ausência ou null, mas não tipo errado", () => {
  assert.equal(dadosValidos("ajustes", {}), true);
  assert.equal(dadosValidos("ajustes", { category: null, gasto: 0 }), true);
  assert.equal(dadosValidos("ajustes", { gasto: 2 }), false);
  assert.equal(dadosValidos("lancamentos", { data: "2026-11-09", descricao: "Feira", valor: -42.5 }), true);
  assert.equal(dadosValidos("lancamentos", { data: "09/11/2026", descricao: "Feira", valor: -42.5 }), false);
  assert.equal(dadosValidos("orcamentos", { nome: "Casa", valor: 900, categoria_ids: [], periodo: "ciclo" }), true);
  assert.equal(dadosValidos("dividas", { tipo: "emprestimo", nome: "João", sentido: "me_devem", valor_total: 300 }), true);
});

test("last-write-wins: só updated_at estritamente maior vence", () => {
  const atual = cat();
  assert.equal(vence(cat({ updated_at: "2026-11-09T11:00:01.000Z" }), atual), true);
  assert.equal(vence(cat(), atual), false);
  assert.equal(vence(cat({ updated_at: "2026-11-09T10:00:00.000Z" }), atual), false);
  assert.equal(vence(cat(), undefined), true);
});

test("mesclar é idempotente e não altera o mapa local", () => {
  const local = new Map([[chave(cat()), cat()]]);
  const novo = cat({ dados: { nome: "Feira", tipo: "despesa" }, updated_at: "2026-11-09T11:30:00.000Z" });
  const duas = mesclar(mesclar(local, [novo]), [novo, cat()]);
  assert.deepEqual(duas.get("categorias:c1")?.dados, { nome: "Feira", tipo: "despesa" });
  assert.deepEqual(local.get("categorias:c1")?.dados, { nome: "Mercado", tipo: "despesa" });
});

test("janela do cursor recua 2 minutos", () => {
  assert.equal(inicioDaJanela(null), null);
  assert.equal(inicioDaJanela("2026-11-09T12:00:00.000Z"), "2026-11-09T11:58:00.000Z");
});

test("revisoes: decisão e memória de destinatário válidas; resposta desconhecida é rejeitada", () => {
  const base = { tabela: "revisoes" as const, updated_at: "2026-11-09T11:00:00.000Z", deleted_at: null };
  assert.ok(dadosValidos("revisoes", { tipo: "decisao", tx_id: "t1", resposta: "ajuda", valor: 800, data: "2026-11-09" }));
  assert.ok(dadosValidos("revisoes", { tipo: "destinatario", destinatario: "JOAO", categoria_id: "c1" }));
  assert.ok(!dadosValidos("revisoes", { tipo: "decisao", tx_id: "t1", resposta: "voar" }));
  const r = validarLote([{ ...base, id: "tx:t1", dados: { tipo: "decisao", tx_id: "t1", resposta: "voar" } }], AGORA);
  assert.ok("rejeitados" in r && r.rejeitados.length === 1);
});

test("meta aceita aplicacao_ids (lista de ids) e valor_alvo 0 para meta sem valor definido", () => {
  const meta = (dados: Record<string, unknown>) => dadosValidos("metas", dados);
  assert.ok(meta({ nome: "Reserva de emergência", valor_alvo: 0, aplicacao_ids: ["a1", "a2"] }));
  assert.ok(meta({ nome: "Viagem", valor_alvo: 5000, prazo: "2027-06-30" })); // sem aplicações: formato antigo
  assert.ok(!meta({ nome: "Viagem", valor_alvo: 5000, aplicacao_ids: "a1" }));
  assert.ok(!meta({ nome: "Viagem", valor_alvo: 5000, aplicacao_ids: [1] }));
});

test("carteiras: nome obrigatório, demais campos opcionais e tipados", () => {
  assert.ok(dadosValidos("carteiras", { nome: "Nubank" }));
  assert.ok(dadosValidos("carteiras", { nome: "Nubank", cor: "FF0000", icone: "bank.png", ordem: 2, moeda: "brl", decimais: 2 }));
  assert.ok(!dadosValidos("carteiras", { cor: "FF0000" }));
  assert.ok(!dadosValidos("carteiras", { nome: "Nubank", ordem: "1" }));
});

test("lançamento agendado/recorrente: campos opcionais tipados", () => {
  const base = { data: "2026-12-05", descricao: "Aluguel", valor: -1500 };
  assert.ok(dadosValidos("lancamentos", base));
  assert.ok(dadosValidos("lancamentos", { ...base, tipo: "recorrente", pago: 0, pulado: 0, proxima_criada: 1, repeticao: "mensal", periodo: 1, fim: "2027-06-05", vencimento: "2026-12-05", fim_nulo: null }));
  assert.ok(dadosValidos("lancamentos", { ...base, tipo: "agendada", fim: null, repeticao: null }));
  assert.ok(!dadosValidos("lancamentos", { ...base, tipo: "assinatura" }));
  assert.ok(!dadosValidos("lancamentos", { ...base, pago: 2 }));
  assert.ok(!dadosValidos("lancamentos", { ...base, repeticao: "quinzenal" }));
  assert.ok(!dadosValidos("lancamentos", { ...base, fim: "05/06/2027" }));
});

test("limites: orcamento_id, categoria_id e valor obrigatórios", () => {
  assert.ok(dadosValidos("limites", { orcamento_id: "cashew:b1", categoria_id: "cashew:c1", valor: 30 }));
  assert.ok(!dadosValidos("limites", { orcamento_id: "cashew:b1", valor: 30 }));
  assert.ok(!dadosValidos("limites", { orcamento_id: "cashew:b1", categoria_id: "cashew:c1", valor: "30" }));
});

test("orçamento: arquivado e limite_absoluto opcionais (0 ou 1)", () => {
  const base = { nome: "Casa", valor: 500, categoria_ids: [], periodo: "ciclo" };
  assert.ok(dadosValidos("orcamentos", base));
  assert.ok(dadosValidos("orcamentos", { ...base, arquivado: 1, limite_absoluto: 0 }));
  assert.ok(dadosValidos("orcamentos", { ...base, arquivado: null }));
  assert.ok(!dadosValidos("orcamentos", { ...base, arquivado: true }));
  assert.ok(!dadosValidos("orcamentos", { ...base, limite_absoluto: 2 }));
});

test("ajuste aceita nome e nota editados (texto não vazio)", () => {
  assert.ok(dadosValidos("ajustes", { nome: "Almoço com cliente", nota: "reembolsável" }));
  assert.ok(dadosValidos("ajustes", { nome: null, nota: null, gasto: 1 }));
  assert.ok(!dadosValidos("ajustes", { nome: "" }));
  assert.ok(!dadosValidos("ajustes", { nome: 5 }));
});

test("configuração guarda o valor serializado em JSON", () => {
  assert.ok(dadosValidos("configuracoes", { valor: "true" }));
  assert.ok(dadosValidos("configuracoes", { valor: JSON.stringify(["a", "b"]) }));
  assert.ok(!dadosValidos("configuracoes", { valor: true }));
  assert.ok(!dadosValidos("configuracoes", { valor: "" }));
  assert.ok(!dadosValidos("configuracoes", { valor: "x".repeat(4001) }));
});

test("espelho: valida allowlist, pk, tamanho, dados nulos e normaliza datas", () => {
  const ok = { tabela: "transactions", pk: "mb:abc", dados: { name: "x" }, updated_at: "2026-11-09T08:00:00-03:00", deleted_at: null };
  const r = validarLinhasEspelho([
    ok,
    { ...ok, tabela: "app_settings" },
    { ...ok, pk: "" },
    { ...ok, dados: null },
    { ...ok, dados: { x: "a".repeat(16 * 1024) } },
    { ...ok, pk: "m1", dados: { a: 1 }, deleted_at: "2026-11-09T12:00:00.000Z" },
    { ...ok, pk: "m2", updated_at: "2099-01-01T00:00:00.000Z" },
  ], AGORA);
  assert.ok("linhas" in r);
  assert.deepEqual(r.linhas.map((l) => l.pk), ["mb:abc", "m1", "m2"]);
  assert.equal(r.linhas[0].updated_at, "2026-11-09T11:00:00.000Z");
  assert.equal(r.linhas[1].dados, null, "exclusão não leva dados");
  assert.equal(r.linhas[2].updated_at, AGORA, "futuro vira agora");
  assert.deepEqual(r.rejeitados.map((x) => x.motivo), ["tabela fora da allowlist", "pk inválida", "dados ausentes sem deleted_at", "linha acima de 16 KB"]);
  assert.ok("erro" in validarLinhasEspelho(Array.from({ length: MAX_LOTE + 1 }, () => ok), AGORA));
  assert.ok("erro" in validarLinhasEspelho({}, AGORA));
  assert.deepEqual(validarLinhasEspelho([], AGORA), { linhas: [], rejeitados: [] });
});
