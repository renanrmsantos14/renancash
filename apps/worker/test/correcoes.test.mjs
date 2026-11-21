// Regressões da revisão geral do backend: data no fuso de SP, banco herdado, poupança, salário, reembolso, pagamento no cartão e alarme do webhook.
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, simularPluggy, restaurarFetch } from "./ambiente.mjs";
import { EspelhoHub } from "../src/index.js";
import { diaDaTransacao, mapearTransacao } from "../src/mapa.js";
import { herdarBanco, semIgnoradas, resumoCiclo, entradasCandidatas, salariosDetectados } from "../src/ciclo.js";
import { aplicarRevisoes } from "../src/revisao.js";
import { valorGasto } from "../public/regras.js";

afterEach(restaurarFetch);

test("data da transação: hora real vira o dia de São Paulo; data pura, meia-noite UTC e 03h00Z ficam como vieram", () => {
  assert.equal(diaDaTransacao("2026-11-21T01:30:00.000Z"), "2026-11-20"); // Pix de 20/11 às 22h30
  assert.equal(diaDaTransacao("2026-11-20T15:00:00.000Z"), "2026-11-20");
  assert.equal(diaDaTransacao("2026-11-20T03:00:00.000Z"), "2026-11-20");
  assert.equal(diaDaTransacao("2026-11-20T00:00:00.000Z"), "2026-11-20");
  assert.equal(diaDaTransacao("2026-11-20T00:00:00"), "2026-11-20");
  assert.equal(diaDaTransacao("2026-11-20"), "2026-11-20");
  assert.equal(diaDaTransacao(null), null);
  const t = mapearTransacao({ id: 1, date: "2026-11-21T01:30:00.000Z", amount: -50, type: "DEBIT" }, { id: "c", type: "BANK" }, "2026-11-20", "ts");
  assert.equal(t.date, "2026-11-20");
  assert.equal(t.scheduled, 0, "compra de hoje à noite não é parcela futura");
});

test("cartão sem banco no nome herda o Santander da mesma conexão e sai do ciclo; poupança não gera gasto", () => {
  const contas = [
    { id: "cc-s", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "SANTANDER ·1234", bank: null, item_id: "s" },
    { id: "gold", type: "CREDIT", name: "GOLD", bank: null, item_id: "s" },
    { id: "cc-i", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "BANCO INTER ·69-6", bank: null, item_id: "i" },
    { id: "poup", type: "BANK", subtype: "SAVINGS_ACCOUNT", name: "Poupança", bank: null, item_id: "i" },
  ];
  assert.match(herdarBanco(contas).find((c) => c.id === "gold").bank, /santander/i);
  const tx = [
    { id: "1", account_id: "gold", date: "2026-11-10", description: "LOJA", amount: 900, scheduled: 0 },
    { id: "2", account_id: "cc-i", date: "2026-11-10", description: "COMPRA DEBITO MERCADO", amount: -100, scheduled: 0 },
    { id: "3", account_id: "poup", date: "2026-11-10", description: "PIX ENVIADO FULANO", amount: -70, scheduled: 0 },
  ];
  const [semTx, semContas] = semIgnoradas(tx, contas);
  assert.deepEqual(semTx.map((t) => t.id), ["2"]);
  assert.deepEqual(semContas.map((c) => c.id), ["cc-i", "poup"], "a poupança continua nas contas (saldo)");
  assert.equal(resumoCiclo({ transacoes: tx, contas, config: {}, hoje: "2026-11-20" }).consumido, 100);
});

const CONTAS = [{ id: "cc", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "BANCO INTER" }];
const entrada = (id, date, amount, description = "PIX RECEBIDO EMPRESA LTDA", extra = {}) => ({ id, account_id: "cc", date, description, amount, scheduled: 0, ...extra });

test("salário por Pix respondido como renda continua candidato; devolução e reembolso não", () => {
  const tx = [entrada("a", "2026-10-05", 5000), entrada("b", "2026-11-05", 7000), entrada("c", "2026-11-06", 7000, "PIX RECEBIDO FULANO")];
  const decisoes = new Map([["b", { tipo: "decisao", tx_id: "b", resposta: "renda" }], ["c", { tipo: "decisao", tx_id: "c", resposta: "devolucao" }]]);
  const aplicadas = aplicarRevisoes(tx, { decisoes, destinos: new Map() });
  const { entradas } = entradasCandidatas(aplicadas, CONTAS, "2026-11-20");
  assert.deepEqual(entradas.map((t) => t.id), ["a", "b"]);
});

test("13º com a descrição do salário (metade do valor) não vira o início do ciclo; reajuste acima de 15% pela descrição vale", () => {
  const config = { salario: "PIX RECEBIDO EMPRESA LTDA", salarioValor: 5000 };
  const tx = [entrada("s1", "2026-11-05", 5000), entrada("d13", "2026-11-30", 2500), entrada("s2", "2026-12-05", 6200)];
  assert.deepEqual(salariosDetectados(tx, config).map((t) => t.id), ["s1", "s2"]);
});

test("reembolso ligado a uma entrada que não é Pix recebido abate o gasto", () => {
  const tx = [entrada("e", "2026-11-10", 200, "ESTORNO COMPRA DEBITO")];
  const decisoes = new Map([["e", { tipo: "decisao", tx_id: "e", resposta: "reembolso", reembolso_de: "x" }]]);
  const [t] = aplicarRevisoes(tx, { decisoes, destinos: new Map() });
  assert.equal(t.reembolso, true);
  assert.equal(aplicarRevisoes(tx, { decisoes: new Map(), destinos: new Map() })[0].reembolso, undefined);
});

test("pagamento no cartão sem categoria não abate o gasto; estorno abate", () => {
  assert.equal(valorGasto({ amount: -1500, description: "PAGAMENTO ON LINE" }, true), 0);
  assert.equal(valorGasto({ amount: -50, description: "CREDITO LOJA X" }, true), -50);
  assert.equal(valorGasto({ amount: -80, description: "PAGAMENTO DE BOLETO" }, false), 80, "na conta corrente pagamento é saída");
});

test("webhook com o Durable Object: agenda no alarme em vez de sincronizar no waitUntil; o alarme sincroniza e repete se ocupado", async () => {
  const pedidos = [];
  const hub = { idFromName: (n) => n, get: () => ({ fetch: async (u) => { pedidos.push(new URL(u).pathname); return new Response(null, { status: 202 }); } }) };
  const ID = "11111111-1111-4111-8111-111111111111";
  const { env, pedir, esperar } = criarAmbiente({ PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "s", PLUGGY_WEBHOOK_SECRET: "wh", ESPELHO_HUB: hub });
  simularPluggy((u) => (u.pathname.startsWith("/items/") ? { id: ID, status: "UPDATED", connector: { name: "Inter" } } : { results: [] }));
  const r = await pedir("/api/pluggy/webhook", { method: "POST", headers: { "x-webhook-secret": "wh", "content-type": "application/json" }, body: JSON.stringify({ event: "item/created", itemId: ID }) });
  assert.equal(r.status, 200);
  await esperar();
  assert.deepEqual(pedidos, ["/sincronizar"]);
  assert.equal(await env.DB.prepare("SELECT count(*) AS n FROM sync_log").first("n"), 0, "nada rodou no waitUntil");

  const guardado = new Map();
  const alarmes = [];
  const ctx = { setWebSocketAutoResponse() {}, storage: { get: async (k) => guardado.get(k), put: async (k, v) => void guardado.set(k, v), delete: async (k) => void guardado.delete(k), setAlarm: async (t) => void alarmes.push(t) } };
  globalThis.WebSocketRequestResponsePair ??= class {};
  const objeto = new EspelhoHub(ctx, env);
  await objeto.alarm();
  assert.equal(await env.DB.prepare("SELECT origem FROM sync_log").first("origem"), "webhook");
  assert.equal(alarmes.length, 0);
  // Trava ocupada: reagenda para daqui a 1 min e conta a espera.
  await env.DB.prepare("INSERT INTO sync_log (origem, started_at) VALUES ('cron', ?1)").bind(new Date().toISOString()).run();
  await objeto.alarm();
  assert.equal(alarmes.length, 1);
  assert.equal(guardado.get("esperas"), 1);
});

test("GET /api/espelho diz quem semeou (o app termina o semeio cuja resposta se perdeu sem trocar pela nuvem)", async () => {
  const hub = { idFromName: (n) => n, get: () => ({ fetch: async () => new Response(null, { status: 204 }) }) };
  const { env, pedir } = criarAmbiente({ ESPELHO: "1", ESPELHO_HUB: hub });
  const token = await criarAparelho(env);
  const cab = { authorization: "Bearer " + token, "content-type": "application/json" };
  await pedir("/api/espelho/semear", { method: "POST", headers: cab, body: JSON.stringify({ lote: 0, fim: true, linhas: [] }) });
  const c = await (await pedir("/api/espelho?limite=1", { headers: cab })).json();
  assert.equal(c.semeado, true);
  assert.equal(c.semeado_por, c.aparelho);
});
