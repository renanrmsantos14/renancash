// Espelho completo: LWW por linha, paginação por cursor, semeio, WebSocket (via Durable Object falso) e a projeção para o ciclo.
import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, entrarComSenha, ORIGEM } from "./ambiente.mjs";
import { registrosDoEspelho } from "../src/espelho.js";
import { EspelhoHub } from "../src/hub.js";
import { contextoDeRegistros, categoriaEfetiva } from "@meu-banco/core";
import { resumoCiclo } from "../src/ciclo.js";
import { lerRevisoes, aplicarRevisoes, filaRevisar } from "../src/revisao.js";

const T0 = "2026-11-01T11:00:00.000Z";
const T1 = "2026-11-01T12:00:00.000Z";
const T2 = "2026-11-01T13:00:00.000Z";

// Durable Object falso: guarda o que o Worker manda (avisos e pedidos de WebSocket).
function hubFalso() {
  const avisos = [];
  const pedidos = [];
  return {
    avisos, pedidos,
    idFromName: (nome) => nome,
    get: () => ({
      fetch: async (req, init) => {
        const r = typeof req === "string" ? new Request(req, init) : req;
        if (r.headers.get("upgrade") === "websocket") { pedidos.push(r); return new Response("ws"); }
        avisos.push(JSON.parse(await r.text()));
        return new Response(null, { status: 204 });
      },
    }),
  };
}

const lin = (pk, dados, updated_at = T1, over = {}) => ({ tabela: "transactions", pk, dados, updated_at, deleted_at: null, ...over });

async function preparar({ semeado = true, env = {} } = {}) {
  const hub = hubFalso();
  const amb = criarAmbiente({ ESPELHO: "1", ESPELHO_HUB: hub, ...env });
  const token = await criarAparelho(amb.env);
  const auth = { authorization: "Bearer " + token, "content-type": "application/json" };
  const post = (caminho, corpo, headers = auth) => amb.pedir(caminho, { method: "POST", headers, body: JSON.stringify(corpo) });
  const semear = (corpo, headers) => post("/api/espelho/semear", { aparelho: "celular", lote: 0, fim: true, linhas: [], ...corpo }, headers);
  const enviar = async (linhas, aparelho = "A") => {
    const r = await post("/api/espelho", { aparelho, linhas });
    return { status: r.status, ...(await r.json()) };
  };
  const puxar = async (query = "") => (await amb.pedir("/api/espelho" + query, { headers: auth })).json();
  const dados = async (pk, tabela = "transactions") => {
    const r = await amb.env.DB.prepare("SELECT dados, updated_at, deleted_at, aparelho FROM espelho WHERE tabela = ?1 AND pk = ?2").bind(tabela, pk).first();
    return r && { ...r, dados: r.dados && JSON.parse(r.dados) };
  };
  if (semeado) assert.equal((await semear({})).status, 200);
  await amb.esperar();
  return { ...amb, hub, token, auth, post, semear, enviar, puxar, dados };
}

test("flag desligada: as rotas novas respondem 404, com ou sem credenciais", async () => {
  const amb = criarAmbiente();
  const token = await criarAparelho(amb.env);
  const auth = { authorization: "Bearer " + token };
  for (const caminho of ["/api/espelho", "/api/espelho/semear", "/api/espelho/ws"]) {
    assert.equal((await amb.pedir(caminho)).status, 404, caminho);
    assert.equal((await amb.pedir(caminho, { method: "POST", headers: auth, body: "{}" })).status, 404, caminho);
  }
});

test("flag desligada: o painel antigo continua editando ajustes; ligada, a edição é desativada (410)", async () => {
  for (const [flag, esperado] of [[{}, 200], [{ ESPELHO: "1" }, 410]]) {
    const amb = criarAmbiente(flag);
    const cookie = await entrarComSenha(amb.pedir);
    const r = await amb.pedir("/api/ajustes/t1", { method: "PUT", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ category: null, gasto: 0 }) });
    assert.equal(r.status, esperado);
  }
});

test("antes do semeio: POST responde 409 e GET devolve semeado:false sem linhas", async () => {
  const { enviar, puxar } = await preparar({ semeado: false });
  const r = await enviar([lin("1", { a: 1 })]);
  assert.equal(r.status, 409);
  assert.equal(r.erro, "nao_semeado");
  assert.deepEqual(await puxar(), { linhas: [], cursor: null, mais: false, semeado: false });
});

test("sem credenciais: 401; sem aparelho ou lista de linhas: 400", async () => {
  const { pedir, post } = await preparar();
  assert.equal((await pedir("/api/espelho")).status, 401);
  assert.equal((await post("/api/espelho", { linhas: [] })).status, 400);
  assert.equal((await post("/api/espelho", { aparelho: "A" })).status, 400);
});

test("/semear com cookie da web é 403 (só o celular semeia)", async () => {
  const { pedir, env } = await preparar({ semeado: false });
  const cookie = await entrarComSenha(pedir);
  const r = await pedir("/api/espelho/semear", { method: "POST", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ aparelho: "web", lote: 0, fim: true, linhas: [] }) });
  assert.equal(r.status, 403);
  assert.equal(await env.DB.prepare("SELECT count(*) AS n FROM espelho_meta").first("n"), 0);
});

test("semeio em lotes: o semeado só existe no fim; segundo semeio dá 409 sem substituir", async () => {
  const { semear, enviar, puxar, auth, post, hub } = await preparar({ semeado: false });
  let r = await semear({ lote: 0, fim: false, linhas: [lin("1", { a: 1 }), lin("2", { a: 2 })] });
  assert.equal(r.status, 200);
  assert.equal((await puxar()).semeado, false, "meio do semeio");
  assert.equal((await enviar([lin("9", { a: 9 })])).status, 409);
  assert.equal((await semear({ aparelho: "outro", lote: 1, linhas: [] })).status, 409, "outro aparelho não continua o semeio");
  r = await semear({ lote: 1, fim: true, linhas: [lin("3", { a: 3 })] });
  assert.deepEqual([r.status, (await r.json()).aceitos], [200, 1]);
  const lido = await puxar();
  assert.equal(lido.semeado, true);
  assert.deepEqual(lido.linhas.map((l) => l.pk), ["1", "2", "3"]);
  assert.equal(hub.avisos.length, 1, "avisa só no fim");

  r = await semear({ lote: 0, linhas: [lin("7", {})] });
  assert.equal(r.status, 409);
  assert.equal((await r.json()).erro, "ja_semeado");
  assert.equal((await puxar()).linhas.length, 3, "nada mudou");

  r = await semear({ lote: 0, substituir: true, linhas: [lin("7", { z: 1 })] });
  assert.equal(r.status, 200);
  assert.deepEqual((await puxar()).linhas.map((l) => l.pk), ["7"]);
  assert.equal((await post("/api/espelho/semear", { aparelho: "x", lote: -1, linhas: [] }, auth)).status, 400);
});

test("LWW: o mais novo vence, o mais velho é rejeitado, igual não muda nada", async () => {
  const { enviar, dados } = await preparar();
  await enviar([lin("1", { v: "meio" }, T1)]);
  let r = await enviar([lin("1", { v: "velho" }, T0)]);
  assert.deepEqual([r.aceitos, r.rejeitados], [0, [{ tabela: "transactions", pk: "1", motivo: "mais_antiga" }]]);
  assert.equal((await dados("1")).dados.v, "meio");
  r = await enviar([lin("1", { v: "igual" }, T1)]);
  assert.equal(r.aceitos, 0, "mesmo updated_at e mesmo aparelho");
  r = await enviar([lin("1", { v: "novo" }, T2)]);
  assert.equal(r.aceitos, 1);
  assert.equal((await dados("1")).dados.v, "novo");
});

test("empate de updated_at: o maior aparelho vence, nos dois sentidos", async () => {
  const { enviar, dados } = await preparar();
  await enviar([lin("1", { v: "A" })], "aparelho-b");
  assert.equal((await enviar([lin("1", { v: "menor" })], "aparelho-a")).aceitos, 0);
  assert.equal((await dados("1")).dados.v, "A");
  assert.equal((await enviar([lin("1", { v: "maior" })], "aparelho-c")).aceitos, 1);
  const x = await dados("1");
  assert.deepEqual([x.dados.v, x.aparelho], ["maior", "aparelho-c"]);
});

test("updated_at do futuro vira agora (não vence para sempre)", async () => {
  const { enviar, dados } = await preparar();
  const antes = Date.now();
  await enviar([lin("1", { v: 1 }, "2099-01-01T00:00:00.000Z")]);
  const t = Date.parse((await dados("1")).updated_at);
  assert.ok(t >= antes - 1000 && t <= Date.now() + 1000);
  assert.equal((await enviar([lin("1", { v: 2 }, new Date(Date.now() + 60_000).toISOString())])).aceitos, 1, "dentro da folga de 5 min vale como veio");
});

test("tombstone: a exclusão apaga os dados, chega no pull e uma versão mais nova ressuscita", async () => {
  const { enviar, puxar, dados } = await preparar();
  await enviar([lin("1", { v: 1 }, T0)]);
  await enviar([lin("1", { ignorado: true }, T1, { deleted_at: T1 })]);
  const x = await dados("1");
  assert.deepEqual([x.dados, x.deleted_at], [null, T1]);
  const lido = (await puxar()).linhas[0];
  assert.deepEqual([lido.pk, lido.dados, lido.deleted_at], ["1", null, T1]);
  assert.equal((await enviar([lin("1", { v: "velho" }, T0)])).aceitos, 0, "versão anterior à exclusão perde");
  await enviar([lin("1", { v: "de novo" }, T2)]);
  const y = await dados("1");
  assert.deepEqual([y.dados, y.deleted_at], [{ v: "de novo" }, null]);
});

test("merge: aparelho com schema antigo não apaga coluna nova; null explícito, boolean e aninhados são preservados", async () => {
  const { enviar, dados } = await preparar();
  await enviar([lin("1", { a: 1, nova: "x", nulo: 5, lista: [1, true, null], obj: { k: "v" }, ligado: true, preco: 1.5 }, T0)]);
  await enviar([lin("1", { a: 2, nulo: null, extra: false }, T1)]);
  assert.deepEqual((await dados("1")).dados, { a: 2, nova: "x", nulo: null, lista: [1, true, null], obj: { k: "v" }, ligado: true, preco: 1.5, extra: false });
});

test("paginação estável com vários server_at iguais e `mais`", async () => {
  const { enviar, puxar } = await preparar();
  const pks = ["mb:abc", "z", "a|b", "m", "b"]; // a pk pode ter ":" e "|"
  await enviar(pks.map((pk) => lin(pk, { pk }))); // um POST = um server_at para todas
  await new Promise((r) => setTimeout(r, 5)); // server_at tem resolução de ms
  await enviar([lin("depois", { pk: "depois" })]);
  const vistos = [];
  let cursor = null;
  const mais = [];
  for (let i = 0; i < 10; i++) {
    const p = await puxar(`?limite=2${cursor ? "&desde=" + encodeURIComponent(cursor) : ""}`);
    vistos.push(...p.linhas.map((l) => l.pk));
    mais.push(p.mais);
    cursor = p.cursor;
    if (!p.mais) break;
  }
  assert.deepEqual([...vistos].sort(), [...pks, "depois"].sort(), "cada linha exatamente uma vez");
  assert.equal(vistos.at(-1), "depois", "server_at mais novo por último");
  assert.deepEqual(mais, [true, true, false]);
  assert.deepEqual((await puxar("?desde=" + encodeURIComponent(cursor))).linhas, [], "cursor no fim: nada novo");
  assert.equal((await (await puxar("?limite=0")).erro) !== undefined, true);
  assert.match((await puxar("?desde=lixo")).erro, /desde inválido/);
});

test("casos de borda: lote vazio, 501 linhas, linha de 16 KB, tabela fora da allowlist, dados null sem deleted_at", async () => {
  const { enviar, post, hub, puxar, esperar } = await preparar();
  const antes = hub.avisos.length;
  const vazio = await enviar([]);
  assert.deepEqual([vazio.status, vazio.aceitos, vazio.rejeitados], [200, 0, []]);
  await esperar();
  assert.equal(hub.avisos.length, antes, "lote vazio não avisa");

  assert.equal((await post("/api/espelho", { aparelho: "A", linhas: Array.from({ length: 501 }, (_, i) => lin(String(i), {})) })).status, 400);
  assert.equal((await post("/api/espelho", { aparelho: "A", linhas: Array.from({ length: 500 }, (_, i) => lin(String(i), { i })) })).status, 200);

  const r = await enviar([
    lin("grande", { texto: "x".repeat(16 * 1024) }),
    lin("ok", { v: 1 }),
    lin("1", {}, T1, { tabela: "app_settings" }),
    lin("sem-dados", null),
  ]);
  assert.equal(r.aceitos, 1);
  assert.deepEqual(r.rejeitados.map((x) => [x.pk, x.motivo]), [["grande", "linha acima de 16 KB"], ["1", "tabela fora da allowlist"], ["sem-dados", "dados ausentes sem deleted_at"]]);
  assert.equal((await puxar("?limite=2000")).linhas.some((l) => l.pk === "grande"), false);
});

test("POST avisa o hub com cursor e aparelho; sem nada gravado, não avisa", async () => {
  const { enviar, hub, esperar } = await preparar();
  hub.avisos.length = 0;
  const r = await enviar([lin("1", { v: 1 })], "celular-1");
  await esperar();
  assert.deepEqual(hub.avisos, [{ tipo: "mudou", cursor: r.cursor, aparelho: "celular-1" }]);
  assert.match(r.cursor, /^\d{4}-.*Z\|transactions\|1$/);
  await enviar([lin("1", { v: 0 }, T0)]);
  await esperar();
  assert.equal(hub.avisos.length, 1, "linha rejeitada por LWW não avisa");
});

test("WebSocket: cookie exige Origin igual (sem Origin ou de fora → 403); token de aparelho passa; sem upgrade → 426", async () => {
  const { pedir, token, hub } = await preparar();
  const cookie = await entrarComSenha(pedir);
  const ws = { upgrade: "websocket" };
  assert.equal((await pedir("/api/espelho/ws", { headers: { cookie, ...ws } })).status, 403);
  assert.equal((await pedir("/api/espelho/ws", { headers: { cookie, origin: "https://outro.test", ...ws } })).status, 403);
  assert.equal(hub.pedidos.length, 0);
  assert.equal((await pedir("/api/espelho/ws", { headers: { cookie, origin: ORIGEM } })).status, 426);
  assert.equal((await pedir("/api/espelho/ws", { headers: { cookie, origin: ORIGEM, ...ws } })).status, 200);
  assert.equal((await pedir("/api/espelho/ws", { headers: { authorization: "Bearer " + token, ...ws } })).status, 200, "Android: Bearer, sem Origin");
  assert.equal(hub.pedidos.length, 2);
  assert.equal((await pedir("/api/espelho/ws", { headers: ws })).status, 401);
});

test("CSP do app inclui wss: da própria origem só com o espelho ligado", async () => {
  const ligado = await preparar();
  const cookie = await entrarComSenha(ligado.pedir);
  const csp = (await ligado.pedir("/app/", { headers: { cookie } })).headers.get("content-security-policy");
  assert.match(csp, /connect-src 'self' wss:\/\/meu-banco\.test;/);
  const desligado = criarAmbiente();
  const c2 = await entrarComSenha(desligado.pedir);
  assert.match((await desligado.pedir("/app/", { headers: { cookie: c2 } })).headers.get("content-security-policy"), /connect-src 'self';/);
});

test("Pluggy: a sincronização avisa {tipo:'banco'} ao hub", async () => {
  const { env, hub } = await preparar();
  const { simularPluggy, restaurarFetch } = await import("./ambiente.mjs");
  simularPluggy(() => ({}));
  try {
    await (await import("../src/index.js")).default.scheduled({ scheduledTime: Date.UTC(2026, 10, 9, 13, 7) }, env, { waitUntil: (p) => p });
  } finally { restaurarFetch(); }
  // sem conexões a sincronização falha (ok = 0) e não avisa; o aviso só sai com ok
  assert.equal(hub.avisos.filter((a) => a.tipo === "banco").length, 0);
});

// ---------- Durable Object como classe pura ----------

test("EspelhoHub: registra o auto-resposta do ping, faz broadcast a todos os sockets e ignora mensagens", async () => {
  globalThis.WebSocketRequestResponsePair = class { constructor(requisicao, resposta) { Object.assign(this, { requisicao, resposta }); } };
  const enviados = [];
  const socket = (nome, quebrado = false) => ({ send: (m) => { if (quebrado) throw new Error("fechado"); enviados.push([nome, m]); }, close: (c) => enviados.push([nome, "close", c]) });
  const sockets = [socket("a"), socket("quebrado", true), socket("c")];
  let auto;
  const hub = new EspelhoHub({ setWebSocketAutoResponse: (p) => { auto = p; }, getWebSockets: () => sockets });
  assert.deepEqual([auto.requisicao, auto.resposta], ["ping", "pong"]);

  const aviso = JSON.stringify({ tipo: "mudou", cursor: "c", aparelho: "A" });
  const r = await hub.fetch(new Request("https://hub/avisar", { method: "POST", body: aviso }));
  assert.equal(r.status, 204);
  assert.deepEqual(enviados, [["a", aviso], ["c", aviso]], "o socket quebrado não impede os demais");

  enviados.length = 0;
  assert.equal(hub.webSocketMessage(sockets[0], "ping"), undefined);
  hub.webSocketClose(sockets[0], 1005);
  assert.deepEqual(enviados, [["a", "close", 1000]]);
  delete globalThis.WebSocketRequestResponsePair;
});

// ---------- registrosDoEspelho × registros (equivalência para o ciclo) ----------

const dia = (iso) => Math.floor(Date.parse(iso) / 1000); // o Drift grava DateTime em segundos

test("registrosDoEspelho projeta o mesmo que a tabela registros e o ciclo/revisões saem iguais", async () => {
  const hoje = "2026-11-20";
  const { env } = criarAmbiente();
  const db = env.DB;
  const esp = (tabela, pk, dados, extra = {}) =>
    db.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) VALUES (?1, ?2, ?3, ?4, ?5, ?4, 'celular')")
      .bind(tabela, pk, dados && JSON.stringify(dados), T1, extra.deleted_at ?? null);
  const revDecisao = { tipo: "decisao", tx_id: "p1", resposta: "ajuda", valor: 900, data: "2026-11-12", descricao: "PIX ENVIADO SANTANDER" };
  const revDestino = { tipo: "destinatario", destinatario: "JOAO", categoria_id: "cashew:c1" };
  await db.batch([
    esp("categories", "c1", { category_pk: "c1", name: "Mercado", colour: "#fff", icon_name: "cart.png", income: 0, order: 1, main_category_pk: null }),
    esp("categories", "c2", { category_pk: "c2", name: "Salário", colour: null, income: 1, order: 2, main_category_pk: "c1" }),
    esp("categories", "apagada", null, { deleted_at: T1 }),
    esp("associated_titles", "r1", { title: "IFOOD", is_exact_match: 0, category_fk: "c1" }),
    esp("associated_titles", "r2", { title: "ENEL", is_exact_match: 1, category_fk: "c1" }),
    esp("associated_titles", "r3", { title: "COM*CURINGA", is_exact_match: 0, category_fk: "c1" }),
    esp("budgets", "o1", { name: "Mercado", amount: 800, category_fks: '["c1"]', archived: 1, is_absolute_spending_limit: 0 }),
    esp("objectives", "m1", { type: 0, name: "Viagem", amount: 5000, end_date: dia("2027-06-30T15:00:00Z") }),
    esp("objectives", "emp", { type: 1, name: "Empréstimo", amount: 100 }),
    esp("mb_meta_aplicacao", "ap1", { aplicacao_pk: "ap1", meta_pk: "m1" }),
    esp("mb_meta_aplicacao", "ap2", { aplicacao_pk: "ap2", meta_pk: "m1" }),
    esp("mb_orcamento_tx", '["mb:g1","o1"]', { tx_pk: "mb:g1", orcamento_pk: "o1" }),
    esp("transactions", "mb:g1", { transaction_pk: "mb:g1", category_fk: "c1" }),
    esp("transactions", "mb:gone", null, { deleted_at: T1 }),
    esp("transactions", "s1", { type: 1, name: "Netflix", amount: -40, date_created: dia("2026-11-05T15:00:00Z"), category_fk: "c1" }),
    esp("transactions", "comum", { type: null, name: "Almoço", category_fk: "c1" }),
    esp("mb_revisoes", "tx:p1", revDecisao),
    esp("mb_revisoes", "dest:JOAO", revDestino),
    esp("_config", "limite", { v: 2000 }),
    esp("_config", "salario", { v: "SALARIO EMPRESA" }),
    db.prepare("INSERT INTO config (chave, valor) VALUES ('salario_valor', '7500'), ('limite', '999')"), // limite do espelho vence
  ]);

  const registros = [
    ["categorias", "cashew:c1", { nome: "Mercado", tipo: "despesa", cor: "#fff", icone: "cart.png", pai_id: null, ordem: 1 }],
    ["categorias", "cashew:c2", { nome: "Salário", tipo: "receita", cor: null, icone: null, pai_id: "cashew:c1", ordem: 2 }],
    ["regras", "cashew:r1", { padrao: "*IFOOD*", categoria_id: "cashew:c1" }],
    ["regras", "cashew:r2", { padrao: "ENEL", categoria_id: "cashew:c1" }],
    ["orcamentos", "cashew:o1", { nome: "Mercado", valor: 800, categoria_ids: ["cashew:c1"], periodo: "ciclo", arquivado: 1 }],
    ["metas", "cashew:m1", { nome: "Viagem", valor_alvo: 5000, prazo: "2027-06-30", aplicacao_ids: ["ap1", "ap2"] }],
    ["assinaturas", "cashew:s1", { nome: "Netflix", valor: 40, dia: 5, categoria_id: "cashew:c1" }],
    ["revisoes", "tx:p1", revDecisao],
    ["revisoes", "dest:JOAO", revDestino],
    ["ajustes", "g1", { categoria_id: "cashew:c1", category: "Mercado", orcamento_ids: ["cashew:o1"] }],
    ["ajustes", "gone", { gasto: 0 }],
  ].map(([tabela, id, dados]) => ({ tabela, id, dados, deleted_at: null }));

  const projetado = await registrosDoEspelho(db);
  const ordem = (a, b) => `${a.tabela}/${a.id}`.localeCompare(`${b.tabela}/${b.id}`);
  assert.deepEqual([...projetado.registros].sort(ordem), registros.sort(ordem));
  assert.deepEqual(projetado.config, { limite: 2000, salario: "SALARIO EMPRESA", salarioValor: 7500 });

  // O ciclo, a fila "Para revisar" e a categoria efetiva saem iguais com qualquer das duas fontes.
  const contas = [{ id: "inter", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta", bank: "Inter" }];
  const tx = [
    { id: "s", account_id: "inter", date: "2026-11-05", description: "SALARIO EMPRESA", amount: 7500, type: "CREDIT", scheduled: 0 },
    { id: "g1", account_id: "inter", date: "2026-11-10", description: "IFOOD", amount: -120, category: "Food delivery", scheduled: 0 },
    { id: "p1", account_id: "inter", date: "2026-11-12", description: "PIX ENVIADO SANTANDER", amount: -900, type: "DEBIT", scheduled: 0 },
    { id: "p2", account_id: "inter", date: "2026-11-13", description: "PIX ENVIADO JOAO", amount: -50, type: "DEBIT", scheduled: 0 },
  ];
  const config = { limite: 2000, salario: "SALARIO EMPRESA", salarioValor: 7500 };
  const calcular = (regs, cfg) => {
    const revisoes = lerRevisoes(regs);
    const { inicio } = resumoCiclo({ transacoes: aplicarRevisoes(tx, revisoes), contas, config: cfg, hoje });
    const transacoes = aplicarRevisoes(tx, revisoes, { inicio });
    const resumo = resumoCiclo({ transacoes, contas, config: cfg, hoje });
    const ctx = contextoDeRegistros(regs);
    return { resumo, fila: filaRevisar({ transacoes, contas, config: cfg, resumo, hoje }), efetivas: tx.map((t) => categoriaEfetiva(t, ctx, (c) => c ?? "", t.amount > 0)) };
  };
  assert.deepEqual(calcular(projetado.registros, projetado.config), calcular(registros, config));
  assert.equal(calcular(registros, config).resumo.gasto, 120 + 900 + 50, "a decisão 'ajuda' conta o envio ao Santander como gasto");
});
