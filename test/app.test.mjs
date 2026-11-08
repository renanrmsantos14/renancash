import { test } from "node:test";
import assert from "node:assert/strict";
import { gerarToken, hashToken, tokenDoCabecalho, normalizarDesde, montarResposta } from "../src/app.js";

test("token tem prefixo mb_ e 32 bytes em base64url, sem repetir", () => {
  const a = gerarToken(), b = gerarToken();
  assert.match(a, /^mb_[A-Za-z0-9_-]{43}$/);
  assert.notEqual(a, b);
});

test("hash é SHA-256 em hex, estável", async () => {
  assert.equal(await hashToken("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

test("tokenDoCabecalho aceita só Bearer mb_ válido", () => {
  const t = gerarToken();
  assert.equal(tokenDoCabecalho("Bearer " + t), t);
  assert.equal(tokenDoCabecalho("bearer " + t), t);
  for (const v of [null, "", t, "Basic " + t, "Bearer abc", "Bearer mb_curto", "Bearer " + t + "x"]) assert.equal(tokenDoCabecalho(v), null);
});

test("normalizarDesde", () => {
  assert.equal(normalizarDesde(null), null);
  assert.equal(normalizarDesde(""), null);
  assert.equal(normalizarDesde("2026-11-08T12:00:00Z"), "2026-11-08T12:00:00.000Z");
  assert.equal(normalizarDesde("lixo"), undefined);
});

test("montarResposta renomeia campos, aplica ajuste de categoria e converte futura", () => {
  const r = montarResposta({
    agora: "2026-11-08T12:00:00.000Z",
    contas: [{ id: "c1", type: "CREDIT", name: "Cartão", bank: "Inter", balance: -10, credit_limit: 100, available_limit: 90, due_date: "2026-11-15" }],
    transacoes: [
      { id: "t1", account_id: "c1", date: "2026-11-01", description: "X", amount: 5, type: "DEBIT", status: "POSTED", category: "Shopping", ajuste_categoria: "Rent", merchant: "Loja", scheduled: 0 },
      { id: "t2", account_id: "c1", date: "2026-12-01", description: "Y", amount: 7, type: "DEBIT", status: "PENDING", category: null, ajuste_categoria: null, merchant: null, scheduled: 1 },
    ],
    pendentes: [{ id: "t2" }],
  });
  assert.deepEqual(r.contas[0], { id: "c1", tipo: "CREDIT", nome: "Cartão", banco: "Inter", saldo: -10, limite: 100, limite_disponivel: 90, vencimento: "2026-11-15" });
  assert.equal(r.transacoes[0].categoria, "Rent");
  assert.equal(r.transacoes[0].futura, false);
  assert.equal(r.transacoes[1].categoria, null);
  assert.equal(r.transacoes[1].futura, true);
  assert.deepEqual(r.ids_pendentes, ["t2"]);
  assert.equal("hash" in r, false);
});
