import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { categoriaEfetiva, contextoDeRegistros, padraoCasa, ordenarRegras } from "../src/index.ts";

const MAPA: Record<string, string> = { Pharmacy: "Farmácia", Groceries: "Supermercado" };
const traduzirTeste = (c: string | null) => (c ? MAPA[c] ?? c : "Sem categoria");
const casos = JSON.parse(readFileSync(new URL("./categoria-casos.json", import.meta.url), "utf8"));

for (const caso of casos) {
  test(`categoria efetiva: ${caso.nome}`, () => {
    const r = categoriaEfetiva(caso.tx, contextoDeRegistros(caso.registros), traduzirTeste, caso.receita);
    assert.deepEqual({ fonte: r.fonte, categoria_id: r.categoria_id }, caso.esperado);
  });
}

test("padraoCasa trata o curinga e escapa o resto", () => {
  assert.equal(padraoCasa("A.B*", "A.B qualquer"), true);
  assert.equal(padraoCasa("A.B*", "AxB"), false);
  assert.equal(padraoCasa("  ", "x"), false);
});

test("ordenarRegras não altera a entrada", () => {
  const e = [{ id: "a", padrao: "x", categoria_id: "c" }, { id: "b", padrao: "xx", categoria_id: "c" }];
  assert.deepEqual(ordenarRegras(e).map((r) => r.id), ["b", "a"]);
  assert.equal(e[0].id, "a");
});
