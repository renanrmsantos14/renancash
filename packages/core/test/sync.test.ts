import { test } from "node:test";
import assert from "node:assert/strict";
import { validarLote, vence, mesclar, inicioDaJanela, chave, dadosValidos, MAX_LOTE, type Registro } from "../src/index.ts";

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
