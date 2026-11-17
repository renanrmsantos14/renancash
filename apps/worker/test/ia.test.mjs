// test/ia.test.mjs — sugestões da aba Pendências (src/ia.js): códigos curtos no prompt, validação da saída do modelo
// (pk precisa existir, sub dentro da categoria, sinal do valor), falhas viram resposta vazia e a rota exige aparelho.
import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho } from "./ambiente.mjs";
import { montarContexto, promptSugerir, promptEntender, lerResposta, validarSugestao, sugerir, entender, MAX_LANCAMENTOS, MODELO } from "../src/ia.js";

const CONTEXTO = {
  categorias: [
    { pk: "cat-alim", nome: "Alimentação", receita: false, subs: [{ pk: "sub-deliv", nome: "Delivery" }, { pk: "sub-rest", nome: "Restaurante" }] },
    { pk: "cat-transp", nome: "Transporte", receita: false, subs: [{ pk: "sub-uber", nome: "Uber" }] },
    { pk: "cat-sal", nome: "Salário", receita: true },
  ],
  vinculos: [{ pk: "obj-mae", nome: "Mãe", tipo: "emprestimo" }, { pk: "x", nome: "Errado", tipo: "outro" }],
  exemplos: [{ descricao: "PIX ENVIADO FABIANA", categoria: "cat-alim", subcategoria: "sub-uber", titulo: "Empréstimo Mãe", vinculo: "obj-mae" }],
};
const PIX = { id: "t1", descricao: "PIX ENVIADO FABIANA SILVA", valor: -500, data: "2026-11-10", conta: "Inter", categoria: "A classificar" };

test("contexto vira códigos curtos; exemplo com sub de outra categoria perde a sub", () => {
  const ctx = montarContexto(CONTEXTO);
  assert.deepEqual([...ctx.cats.keys()], ["C1", "C2", "C3"]);
  assert.deepEqual([...ctx.subs.keys()], ["S1", "S2", "S3"]);
  assert.deepEqual([...ctx.vinculos.keys()], ["V1"]); // tipo desconhecido fica de fora
  assert.deepEqual(ctx.exemplos[0], { descricao: "PIX ENVIADO FABIANA", cat: "C1", sub: "", titulo: "Empréstimo Mãe", vin: "V1" });
  const [sis, usr] = promptSugerir(ctx, [PIX]);
  assert.equal(sis.role, "system");
  assert.match(usr.content, /C1 Alimentação \(despesa\): S1 Delivery, S2 Restaurante/);
  assert.match(usr.content, /V1 Empréstimo: Mãe/);
  assert.match(usr.content, /1\. 2026-11-10 \| Inter \| -R\$ 500,00 \| "PIX ENVIADO FABIANA SILVA" \| categoria atual: A classificar/);
  assert.doesNotMatch(usr.content, /cat-alim|obj-mae/); // pks não vão ao modelo
  assert.match(promptEntender(ctx, PIX, "foi pra minha mãe\u0007")[1].content, /Explicação do usuário: "foi pra minha mãe"/);
});

test("validação: troca códigos por pks e descarta o que não existe", () => {
  const ctx = montarContexto(CONTEXTO);
  assert.deepEqual(validarSugestao({ categoria: "c1", subcategoria: "S2", titulo: "  Almoço  ", vinculo: "", confianca: 0.9, pergunta: "ignorada" }, ctx, PIX),
    { id: "t1", categoria: "cat-alim", subcategoria: "sub-rest", titulo: "Almoço", vinculo: null, confianca: 0.9, pergunta: null });
  // sub de outra categoria e vínculo inexistente caem; confiança baixa mantém a pergunta
  assert.deepEqual(validarSugestao({ categoria: "C1", subcategoria: "S3", titulo: "", vinculo: "V9", confianca: 0.4, pergunta: "Foi empréstimo para a Mãe?" }, ctx, PIX),
    { id: "t1", categoria: "cat-alim", subcategoria: null, titulo: null, vinculo: null, confianca: 0.4, pergunta: "Foi empréstimo para a Mãe?" });
  assert.equal(validarSugestao({ categoria: "C9" }, ctx, PIX), null); // categoria inventada
  assert.equal(validarSugestao({ categoria: "C3", confianca: 1 }, ctx, PIX), null); // receita para saída de dinheiro
  assert.equal(validarSugestao({ categoria: "C1", confianca: 80 }, ctx, PIX).confianca, 0.8); // 0–100 vira 0–1
  assert.equal(validarSugestao({ categoria: "C1", confianca: "x" }, ctx, PIX).confianca, 0);
});

test("lerResposta: aceita objeto ou texto com cercas, uma sugestão por lançamento, linha inexistente ignorada", () => {
  const ctx = montarContexto(CONTEXTO);
  const outro = { ...PIX, id: "t2", descricao: "UBER *TRIP", valor: -23.5 };
  const bruto = { sugestoes: [
    { n: 2, categoria: "C2", subcategoria: "S3", titulo: "Uber", vinculo: "", confianca: 0.95, pergunta: "" },
    { n: 2, categoria: "C1", subcategoria: "", titulo: "", vinculo: "", confianca: 0.1, pergunta: "" },
    { n: 7, categoria: "C1", subcategoria: "", titulo: "", vinculo: "", confianca: 1, pergunta: "" },
  ] };
  assert.deepEqual(lerResposta(bruto, ctx, [PIX, outro]).map((s) => [s.id, s.categoria, s.subcategoria]), [["t2", "cat-transp", "sub-uber"]]);
  assert.equal(lerResposta("```json\n" + JSON.stringify(bruto) + "\n```", ctx, [PIX, outro]).length, 1);
  assert.deepEqual(lerResposta("não é json", ctx, [PIX]), []);
  assert.deepEqual(lerResposta(null, ctx, [PIX]), []);
});

test("sugerir: lote limitado, JSON mode no modelo e falha vira lista vazia", async () => {
  const chamadas = [];
  const AI = { run: async (modelo, opcoes) => { chamadas.push({ modelo, opcoes }); return { response: { sugestoes: [{ n: 1, categoria: "C1", subcategoria: "", titulo: "Empréstimo Mãe", vinculo: "V1", confianca: 0.5, pergunta: "Esse Pix de R$ 500 para Fabiana foi empréstimo para a Mãe?" }] } }; } };
  const muitos = Array.from({ length: 20 }, (_, i) => ({ ...PIX, id: "t" + i }));
  const r = await sugerir({ AI }, { contexto: CONTEXTO, lancamentos: muitos });
  assert.equal(chamadas[0].modelo, MODELO);
  assert.equal(chamadas[0].opcoes.response_format.type, "json_schema");
  assert.equal(chamadas[0].opcoes.messages[1].content.split("\n").filter((l) => /^\d+\. /.test(l)).length, MAX_LANCAMENTOS);
  assert.deepEqual(r.sugestoes, [{ id: "t0", categoria: "cat-alim", subcategoria: null, titulo: "Empréstimo Mãe", vinculo: "obj-mae", confianca: 0.5, pergunta: "Esse Pix de R$ 500 para Fabiana foi empréstimo para a Mãe?" }]);

  const erros = [];
  const original = console.error;
  console.error = (...a) => erros.push(a.join(" "));
  try {
    const falha = await sugerir({ AI: { run: async () => { throw new Error("JSON Mode couldn't be met"); } } }, { contexto: CONTEXTO, lancamentos: [PIX] });
    assert.deepEqual(falha, { sugestoes: [], ia: true });
  } finally {
    console.error = original;
  }
  assert.equal(erros.length, 1);
  assert.doesNotMatch(erros[0], /FABIANA|500/); // nada de descrição ou valor no log
  assert.deepEqual(await sugerir({}, { contexto: CONTEXTO, lancamentos: [PIX] }), { sugestoes: [], ia: false });
});

test("entender: devolve a interpretação da explicação; sem texto não chama o modelo", async () => {
  let chamou = 0;
  const AI = { run: async () => { chamou++; return { response: JSON.stringify({ sugestoes: [{ n: 1, categoria: "C2", subcategoria: "S3", titulo: "Uber", vinculo: "", confianca: 0.9, pergunta: "" }] }) }; } };
  assert.deepEqual((await entender({ AI }, { contexto: CONTEXTO, lancamento: PIX, explicacao: "foi o uber pro aeroporto" })).sugestao,
    { id: "t1", categoria: "cat-transp", subcategoria: "sub-uber", titulo: "Uber", vinculo: null, confianca: 0.9, pergunta: null });
  assert.deepEqual(await entender({ AI }, { contexto: CONTEXTO, lancamento: PIX, explicacao: "   " }), { sugestao: null, ia: true });
  assert.equal(chamou, 1);
});

test("rotas /api/ia exigem token de aparelho e limitam o tamanho do pedido", async () => {
  const AI = { run: async () => ({ response: { sugestoes: [{ n: 1, categoria: "C2", subcategoria: "", titulo: "Uber", vinculo: "", confianca: 0.9, pergunta: "" }] } }) };
  const amb = criarAmbiente({ AI });
  const corpo = JSON.stringify({ contexto: CONTEXTO, lancamentos: [PIX] });
  assert.equal((await amb.pedir("/api/ia/sugerir", { method: "POST", body: corpo })).status, 401);
  const auth = { authorization: "Bearer " + (await criarAparelho(amb.env)), "content-type": "application/json" };
  const r = await amb.pedir("/api/ia/sugerir", { method: "POST", headers: auth, body: corpo });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).sugestoes[0].categoria, "cat-transp");
  const grande = await amb.pedir("/api/ia/entender", { method: "POST", headers: auth, body: "x".repeat(70 * 1024) });
  assert.equal(grande.status, 413);
  const invalido = await amb.pedir("/api/ia/entender", { method: "POST", headers: auth, body: "{" });
  assert.deepEqual(await invalido.json(), { sugestao: null, ia: true });
});
