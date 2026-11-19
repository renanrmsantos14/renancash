// Espelho completo: LWW por linha, paginação por cursor, semeio, WebSocket (via Durable Object falso) e a projeção para o ciclo.
import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, entrarComSenha, ORIGEM } from "./ambiente.mjs";
import { deTx, registrosDoEspelho } from "../src/espelho.js";
import { criarD1 } from "./d1.mjs";
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
        if (r.headers.get("upgrade")?.toLowerCase() === "websocket") { pedidos.push(r); return new Response("ws"); }
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
  // O aparelho do LWW é o id do token (não vem do corpo): cada `quem` é um aparelho.
  const novo = async (nome = "Celular") => {
    const t = await criarAparelho(amb.env, nome);
    const id = await amb.env.DB.prepare("SELECT id FROM app_tokens ORDER BY rowid DESC LIMIT 1").first("id");
    return { id, token: t, auth: { authorization: "Bearer " + t, "content-type": "application/json" } };
  };
  const { id: aparelhoId, token, auth } = await novo();
  const principal = { id: aparelhoId, auth };
  const post = (caminho, corpo, headers = auth) => amb.pedir(caminho, { method: "POST", headers, body: JSON.stringify(corpo) });
  const semear = (corpo, headers) => post("/api/espelho/semear", { lote: 0, fim: true, linhas: [], ...corpo }, headers);
  const enviar = async (linhas, quem = principal) => {
    const r = await post("/api/espelho", { linhas }, quem.auth);
    return { status: r.status, ...(await r.json()) };
  };
  const puxar = async (query = "") => (await amb.pedir("/api/espelho" + query, { headers: auth })).json();
  const dados = async (pk, tabela = "transactions") => {
    const r = await amb.env.DB.prepare("SELECT dados, updated_at, deleted_at, aparelho FROM espelho WHERE tabela = ?1 AND pk = ?2").bind(tabela, pk).first();
    return r && { ...r, dados: r.dados && JSON.parse(r.dados) };
  };
  if (semeado) assert.equal((await semear({})).status, 200);
  await amb.esperar();
  return { ...amb, hub, token, auth, aparelhoId, novo, post, semear, enviar, puxar, dados };
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
  const { enviar, puxar, aparelhoId } = await preparar({ semeado: false });
  const r = await enviar([lin("1", { a: 1 })]);
  assert.equal(r.status, 409);
  assert.equal(r.erro, "nao_semeado");
  assert.deepEqual(await puxar(), { linhas: [], cursor: null, mais: false, semeado: false, aparelho: aparelhoId });
});

test("sem credenciais: 401; sem lista de linhas: 400", async () => {
  const { pedir, post } = await preparar();
  assert.equal((await pedir("/api/espelho")).status, 401);
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
  const { semear, enviar, puxar, auth, post, hub, novo } = await preparar({ semeado: false });
  let r = await semear({ lote: 0, fim: false, linhas: [lin("1", { a: 1 }), lin("2", { a: 2 })] });
  assert.equal(r.status, 200);
  assert.equal((await puxar()).semeado, false, "meio do semeio");
  assert.equal((await enviar([lin("9", { a: 9 })])).status, 409);
  assert.equal((await semear({ lote: 1, linhas: [] }, (await novo("Outro")).auth)).status, 409, "outro aparelho não continua o semeio");
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

  const antes = (await puxar()).cursor;
  r = await semear({ lote: 0, substituir: true, linhas: [lin("7", { z: 1 })] });
  assert.equal(r.status, 200);
  const depois = (await puxar()).linhas;
  assert.deepEqual(depois.filter((l) => l.dados).map((l) => l.pk), ["7"]);
  assert.deepEqual(depois.filter((l) => !l.dados).map((l) => [l.pk, l.deleted_at != null]).sort(), [["1", true], ["2", true], ["3", true]], "as linhas que não vieram no novo semeio viram tombstone");
  assert.ok((await puxar(`?desde=${encodeURIComponent(antes)}`)).linhas.length >= 4, "os outros aparelhos recebem os tombstones pelo cursor");
  assert.equal((await post("/api/espelho/semear", { lote: -1, linhas: [] }, auth)).status, 400);
});

test("LWW: o mais novo vence, o mais velho é rejeitado com a versão vencedora, reenvio idêntico é aceito", async () => {
  const { enviar, dados, aparelhoId } = await preparar();
  await enviar([lin("1", { v: "meio" }, T1)]);
  let r = await enviar([lin("1", { v: "velho" }, T0)]);
  assert.equal(r.aceitos, 0);
  assert.deepEqual(r.rejeitados, [{ tabela: "transactions", pk: "1", motivo: "mais_antiga", atual: { dados: { v: "meio" }, updated_at: T1, deleted_at: null, aparelho: aparelhoId } }]);
  assert.equal((await dados("1")).dados.v, "meio");
  r = await enviar([lin("1", { v: "meio" }, T1)]);
  assert.deepEqual([r.aceitos, r.rejeitados], [1, []], "mesmo updated_at e mesmo aparelho: idempotente");
  r = await enviar([lin("1", { v: "novo" }, T2)]);
  assert.equal(r.aceitos, 1);
  assert.equal((await dados("1")).dados.v, "novo");
  assert.equal(r.aparelho, aparelhoId);
  assert.equal("cursor" in r, false, "o POST não devolve cursor global");
});

test("o aparelho vem da autenticação: o do corpo é ignorado e a sessão do painel é \"web\"", async () => {
  const { enviar, dados, post, pedir, hub, esperar, aparelhoId, auth } = await preparar();
  hub.avisos.length = 0;
  await post("/api/espelho", { aparelho: "forjado", linhas: [lin("1", { v: 1 })] }, auth);
  assert.equal((await dados("1")).aparelho, aparelhoId);
  await esperar();
  assert.equal(hub.avisos[0].aparelho, aparelhoId);
  const cookie = await entrarComSenha(pedir);
  const r = await pedir("/api/espelho", { method: "POST", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ linhas: [lin("2", { v: 1 })] }) });
  assert.equal((await r.json()).aparelho, "web");
  assert.equal((await dados("2")).aparelho, "web");
});

test("empate de updated_at: o maior aparelho vence, nos dois sentidos", async () => {
  const { enviar, dados, novo } = await preparar();
  const [menor, meio, maior] = (await Promise.all([novo("a"), novo("b"), novo("c")])).sort((x, y) => (x.id < y.id ? -1 : 1));
  await enviar([lin("1", { v: "A" })], meio);
  assert.equal((await enviar([lin("1", { v: "menor" })], menor)).aceitos, 0);
  assert.equal((await dados("1")).dados.v, "A");
  assert.equal((await enviar([lin("1", { v: "maior" })], maior)).aceitos, 1);
  const x = await dados("1");
  assert.deepEqual([x.dados.v, x.aparelho], ["maior", maior.id]);
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

test("merge: objeto vazio nunca vira NULL e o texto dos números reais não é arredondado", async () => {
  const { enviar, dados, puxar, pedir, auth } = await preparar();
  await enviar([lin("vazio", {}, T0)]);
  await enviar([lin("vazio", {}, T1)]);
  assert.deepEqual((await dados("vazio")).dados, {});
  await enviar([lin("real", { preco: 0.30000000000000004, outro: 1 }, T0)]);
  await enviar([lin("real", { outro: 2 }, T1)]);
  const bruto = await (await pedir("/api/espelho?limite=2000", { headers: auth })).text();
  assert.match(bruto, /"preco":0\.30000000000000004/);
  assert.equal((await dados("real")).dados.outro, 2);
  assert.equal((await puxar()).linhas.find((l) => l.pk === "vazio").dados != null, true);
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
    lin("acentos", { texto: "é".repeat(9000) }), // 9000 caracteres, 18 KB em UTF-8
    lin("emoji", { texto: "😀".repeat(4200) }), // 4200 caracteres (8400 em UTF-16), 16,8 KB em UTF-8
  ]);
  assert.equal(r.aceitos, 1);
  assert.deepEqual(r.rejeitados.map((x) => [x.pk, x.motivo]), [["grande", "linha acima de 16 KB"], ["1", "tabela fora da allowlist"], ["sem-dados", "dados ausentes sem deleted_at"], ["acentos", "linha acima de 16 KB"], ["emoji", "linha acima de 16 KB"]]);
  assert.equal((await puxar("?limite=2000")).linhas.some((l) => l.pk === "grande"), false);
});

test("POST avisa o hub com cursor e aparelho; sem nada gravado, não avisa", async () => {
  const { enviar, hub, esperar } = await preparar();
  hub.avisos.length = 0;
  const r = await enviar([lin("1", { v: 1 })]);
  await esperar();
  assert.equal(hub.avisos.length, 1);
  assert.deepEqual([hub.avisos[0].tipo, hub.avisos[0].aparelho], ["mudou", r.aparelho]);
  assert.match(hub.avisos[0].cursor, /^\d{4}-.*Z\|transactions\|1$/, "o cursor do aviso é só uma dica");
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
  assert.equal((await pedir("/api/espelho/ws", { headers: { authorization: "Bearer " + token, upgrade: "WebSocket" } })).status, 200, "Upgrade sem diferenciar maiúsculas");
  assert.equal(hub.pedidos.length, 3);
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
    esp("transactions", "mb:g1", { transaction_pk: "mb:g1", category_fk: "c1", name: "IFOOD", note: "Pendente" }),
    esp("transactions", "mb:g2", { transaction_pk: "mb:g2", category_fk: "c9", name: "  Almoço com cliente  ", note: "reembolsável", objective_loan_fk: "emp", date_time_modified: dia("2026-11-12T12:00:00Z") }),
    esp("transactions", "mb:g3", { transaction_pk: "mb:g3", category_fk: "c9", name: "Texto do banco", note: "Nota do banco", date_time_modified: dia("2000-01-01T00:00:00Z") }), // não editada: texto não vira ajuste
    esp("transactions", "mb:inv:x1", { transaction_pk: "mb:inv:x1", category_fk: "c1", name: "CDB" }), // investimento do banco: fora
    db.prepare("INSERT INTO transactions (id, account_id, date, description, amount, updated_at) VALUES ('g1', 'inter', '2026-11-10', 'IFOOD', -120, ''), ('g2', 'inter', '2026-11-11', 'RESTAURANTE X', -80, '')"),
    esp("transactions", "mb:gone", null, { deleted_at: T1 }),
    esp("transactions", "s1", { type: 1, name: "Netflix", amount: -40, date_created: dia("2026-11-05T15:00:00Z"), category_fk: "c1" }),
    esp("transactions", "comum", { type: null, name: "Almoço", category_fk: "c1" }),
    esp("mb_revisoes", "tx:p1", revDecisao),
    esp("mb_revisoes", "dest:JOAO", revDestino),
    esp("_config", "limite", { v: 2000 }),
    esp("_config", "salario", { v: "SALARIO EMPRESA" }),
    db.prepare("INSERT INTO config (chave, valor) VALUES ('salario_valor', '7500'), ('limite', '999')"), // limite do espelho vence
    db.prepare("INSERT INTO registros (tabela, id, dados, updated_at, server_at) VALUES ('categorias', 'cashew:c1', ?1, ?2, ?2)").bind(JSON.stringify({ nome: "Mercado", tipo: "despesa", pluggy: ["Groceries"] }), T1), // o pluggy só existe aqui
  ]);

  const registros = [
    ["categorias", "cashew:c1", { nome: "Mercado", tipo: "despesa", cor: "#fff", icone: "cart.png", pai_id: null, ordem: 1, pluggy: ["Groceries"] }],
    ["categorias", "cashew:c2", { nome: "Salário", tipo: "receita", cor: null, icone: null, pai_id: "cashew:c1", ordem: 2 }],
    ["regras", "cashew:r1", { padrao: "*IFOOD*", categoria_id: "cashew:c1" }],
    ["regras", "cashew:r2", { padrao: "ENEL", categoria_id: "cashew:c1" }],
    ["orcamentos", "cashew:o1", { nome: "Mercado", valor: 800, categoria_ids: ["cashew:c1"], periodo: "ciclo", arquivado: 1 }],
    ["dividas", "cashew:emp", { tipo: "emprestimo", nome: "Empréstimo", sentido: "devo", valor_total: 100 }],
    ["metas", "cashew:m1", { nome: "Viagem", valor_alvo: 5000, prazo: "2027-06-30", aplicacao_ids: ["ap1", "ap2"] }],
    ["assinaturas", "cashew:s1", { nome: "Netflix", valor: 40, dia: 5, categoria_id: "cashew:c1" }],
    ["revisoes", "tx:p1", revDecisao],
    ["revisoes", "dest:JOAO", revDestino],
    ["ajustes", "g1", { categoria_id: "cashew:c1", category: "Mercado", orcamento_ids: ["cashew:o1"] }],
    ["ajustes", "g2", { divida_id: "cashew:emp", nome: "Almoço com cliente", nota: "reembolsável" }],
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

// ---------- F4: ciclo, painel antigo e alertas leem o espelho ----------

test("com a flag ligada, ciclo, /api/dados, histórico e fatura leem os ajustes do espelho e ignoram `registros`", async () => {
  const hoje = new Date().toLocaleDateString("sv", { timeZone: "America/Sao_Paulo" });
  const dia = (n) => new Date(Date.parse(hoje + "T12:00:00Z") - n * 86_400_000).toISOString().slice(0, 10);
  const { pedir, env, auth, enviar, esperar } = await preparar();
  const ts = new Date().toISOString();
  const tx = (id, d, desc, valor) => env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES (?1, 'inter', ?2, ?3, ?4, ?5, 'POSTED', 0, ?6)").bind(id, d, desc, valor, valor > 0 ? "CREDIT" : "DEBIT", ts);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO accounts (id, type, subtype, name, bank, updated_at) VALUES ('inter', 'BANK', 'CHECKING_ACCOUNT', 'Conta', 'Inter', ?1)").bind(ts),
    tx("s1", dia(5), "SALARIO EMPRESA", 7500), tx("g1", dia(2), "MERCADO", -100), tx("g2", dia(1), "FARMACIA", -50), tx("g3", dia(1), "PADARIA", -30),
    // o painel antigo zerou o g2 em `registros`: com a flag ligada isso não vale mais
    env.DB.prepare("INSERT INTO registros (tabela, id, dados, updated_at, server_at) VALUES ('ajustes', 'g2', '{\"gasto\":0}', ?1, ?1)").bind(ts),
  ]);
  const gasto = async () => (await (await pedir("/api/sync", { headers: auth })).json()).ciclo.gasto;
  assert.equal(await gasto(), 180, "sem nada no espelho: tudo conta");
  // o app exclui o g1 (tombstone `mb:g1`) e recategoriza o g3
  const novas = [
    { tabela: "categories", pk: "c1", dados: { name: "Padaria", income: 0 }, updated_at: ts, deleted_at: null },
    { tabela: "transactions", pk: "mb:g1", dados: null, updated_at: ts, deleted_at: ts },
    { tabela: "transactions", pk: "mb:g3", dados: { category_fk: "c1" }, updated_at: ts, deleted_at: null },
  ];
  assert.equal((await enviar(novas)).aceitos, 3);
  await esperar();
  assert.equal(await gasto(), 80, "g1 zerado pelo espelho; g2 continua contando");
  const cookie = await entrarComSenha(pedir);
  const lista = async (caminho, chave = "transacoes") => Object.fromEntries((await (await pedir(caminho, { headers: { cookie } })).json())[chave].map((t) => [t.id, [t.ajuste_gasto, t.ajuste_categoria]]));
  const esperado = { g1: [0, null], g2: [null, null], g3: [null, "Padaria"], s1: [null, null] };
  assert.deepEqual(await lista("/api/dados?mes=" + hoje.slice(0, 7)), esperado);
  assert.deepEqual(await lista("/api/historico"), esperado);
  assert.deepEqual(await lista(`/api/fatura?conta=inter&de=${dia(10)}&ate=${hoje}`), esperado);
});

// ---------- F4: correções do code-review ----------

const hojeSP = () => new Date().toLocaleDateString("sv", { timeZone: "America/Sao_Paulo" });
const diasAtras = (n) => new Date(Date.parse(hojeSP() + "T12:00:00Z") - n * 86_400_000).toISOString().slice(0, 10);
// Conta corrente, salário há 5 dias e as transações dadas ([id, dia, descrição, valor]).
async function semearCiclo(env, txs) {
  const ts = new Date().toISOString();
  const tx = (id, d, desc, valor) => env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES (?1, 'inter', ?2, ?3, ?4, ?5, 'POSTED', 0, ?6)").bind(id, d, desc, valor, valor > 0 ? "CREDIT" : "DEBIT", ts);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO accounts (id, type, subtype, name, bank, updated_at) VALUES ('inter', 'BANK', 'CHECKING_ACCOUNT', 'Conta', 'Inter', ?1)").bind(ts),
    tx("s1", diasAtras(5), "SALARIO EMPRESA", 7500),
    ...txs.map(([id, d, desc, valor]) => tx(id, diasAtras(d), desc, valor)),
  ]);
}
const gastoDoCiclo = async (pedir, auth) => (await (await pedir("/api/sync", { headers: auth })).json()).ciclo.gasto;

test("review 1: a junção com v_ajustes_espelho usa a PK do espelho, sem varrer a tabela", async () => {
  const { env } = await preparar();
  const plano = (await env.DB.prepare(`EXPLAIN QUERY PLAN SELECT t.id, a.category ${deTx(true)} WHERE t.date >= ?1`).bind("2026-01-01").all()).results.map((r) => r.detail).join("\n");
  assert.doesNotMatch(plano, /SCAN (e|a|espelho)\b/, plano);
  assert.match(plano, /SEARCH \w+ USING (COVERING )?INDEX \w*espelho\w* \(tabela=\? AND pk=\?\)/, plano);
});

test("review 2: ESPELHO ligado e ainda não semeado segue em `registros`, e passa ao espelho depois do semeio", async () => {
  const { env, pedir, auth, enviar, semear, esperar } = await preparar({ semeado: false });
  await semearCiclo(env, [["g1", 2, "MERCADO", -100], ["g2", 1, "FARMACIA", -50]]);
  const ts = new Date().toISOString();
  await env.DB.prepare("INSERT INTO registros (tabela, id, dados, updated_at, server_at) VALUES ('ajustes', 'g2', '{\"gasto\":0}', ?1, ?1)").bind(ts).run();
  assert.equal(await gastoDoCiclo(pedir, auth), 100, "não semeado: vale o ajuste de `registros`");
  assert.equal((await semear({})).status, 200);
  await esperar();
  assert.equal(await gastoDoCiclo(pedir, auth), 150, "semeado: o ajuste antigo deixa de valer");
  // durante um `substituir` (lote 0 apaga o "semeado") volta para `registros`
  assert.equal((await semear({ lote: 0, fim: false, substituir: true })).status, 200);
  assert.equal(await gastoDoCiclo(pedir, auth), 100, "semeio em andamento: `registros`");
  void enviar;
});

test("review 3: `_config` com tombstone sobrescreve a tabela `config` com null", async () => {
  const db = criarD1();
  await db.batch([
    db.prepare("INSERT INTO config (chave, valor) VALUES ('limite', '500'), ('salario', 'EMPRESA'), ('salario_valor', '7500')"),
    db.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) VALUES ('_config', 'limite', NULL, ?1, ?1, ?1, 'web'), ('_config', 'salario', '{\"v\":\"OUTRA\"}', ?1, NULL, ?1, 'web')").bind(T1),
  ]);
  const { config } = await registrosDoEspelho(db);
  assert.equal(config.limite, null, "o tombstone apagou o limite antigo");
  assert.equal(config.salario, "OUTRA");
  assert.equal(config.salarioValor, 7500, "sem `_config`, a tabela antiga vale");
});

test("review 4: PUT /api/config grava primeiro no espelho; se ele falha, devolve erro e não grava `config`", async () => {
  const { env, pedir } = await preparar();
  const cookie = await entrarComSenha(pedir);
  const put = (corpo) => pedir("/api/config", { method: "PUT", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify(corpo) });
  const original = env.DB;
  env.DB = new Proxy(original, { get: (d, k) => (k === "batch" ? async () => { throw new Error("D1 fora"); } : d[k].bind(d)) });
  const r = await put({ limite: 1234 });
  env.DB = original;
  assert.equal(r.status, 502);
  assert.equal(await env.DB.prepare("SELECT count(*) AS n FROM config").first("n"), 0, "config intocado");
  assert.equal(await env.DB.prepare("SELECT count(*) AS n FROM espelho WHERE tabela = '_config'").first("n"), 0);
  assert.equal((await put({ limite: 1234 })).status, 200);
  assert.equal(await env.DB.prepare("SELECT valor FROM config WHERE chave = 'limite'").first("valor"), "1234");
});

test("review 4: a edição do painel vence um `_config` do app com relógio adiantado (max(agora, atual + 1 ms))", async () => {
  const { env, pedir } = await preparar();
  const adiantado = new Date(Date.now() + 120_000).toISOString(); // dentro da folga de 5 min: o servidor aceita como está
  await env.DB.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) VALUES ('_config', 'limite', '{\"v\":999}', ?1, NULL, ?1, 'celular')").bind(adiantado).run();
  const cookie = await entrarComSenha(pedir);
  const r = await pedir("/api/config", { method: "PUT", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ limite: 2000 }) });
  assert.equal(r.status, 200);
  const l = await env.DB.prepare("SELECT dados, updated_at, aparelho FROM espelho WHERE tabela = '_config' AND pk = 'limite'").first();
  assert.deepEqual([JSON.parse(l.dados).v, l.aparelho], [2000, "web"]);
  assert.ok(l.updated_at > adiantado);
});

test("review 5: renomear a categoria faz o pull incremental devolver a transação", async () => {
  const { env, pedir, auth, enviar, esperar } = await preparar();
  await semearCiclo(env, [["g1", 2, "MERCADO", -100]]);
  await enviar([
    { tabela: "categories", pk: "c1", dados: { name: "Mercado", income: 0 }, updated_at: T1, deleted_at: null },
    lin("mb:g1", { category_fk: "c1" }),
  ]);
  await esperar();
  const pull = async (desde) => (await pedir("/api/app/transacoes" + (desde ? "?desde=" + encodeURIComponent(desde) : ""), { headers: auth })).json();
  const primeiro = await pull();
  assert.equal(primeiro.transacoes.find((t) => t.id === "g1").categoria, "Mercado");
  await new Promise((r) => setTimeout(r, 5));
  assert.equal((await enviar([{ tabela: "categories", pk: "c1", dados: { name: "Supermercado", income: 0 }, updated_at: T2, deleted_at: null }])).aceitos, 1);
  const segundo = await pull(primeiro.agora);
  assert.deepEqual(segundo.transacoes.map((t) => [t.id, t.categoria]), [["g1", "Supermercado"]]);
  assert.deepEqual((await pull(segundo.agora)).transacoes, [], "sem mudança nova: nada");
});

test("review 6: transação ligada a empréstimo não conta no gasto do ciclo, com a flag ligada e desligada", async () => {
  const txs = [["g1", 2, "MERCADO", -100], ["emp", 1, "PIX AMIGO", -300]];
  // ligada: o app manda objective_loan_fk na transação `mb:`
  const ligado = await preparar();
  await semearCiclo(ligado.env, txs);
  assert.equal(await gastoDoCiclo(ligado.pedir, ligado.auth), 400);
  await ligado.enviar([
    { tabela: "objectives", pk: "o1", dados: { name: "Amigo", type: 1, income: 0, amount: 300 }, updated_at: T1, deleted_at: null },
    lin("mb:emp", { objective_loan_fk: "o1" }),
  ]);
  await ligado.esperar();
  assert.equal(await gastoDoCiclo(ligado.pedir, ligado.auth), 100, "ligada: o empréstimo fica fora");
  // desligada: o ajuste `divida_id` está em `registros`
  const antigo = criarAmbiente();
  await semearCiclo(antigo.env, txs);
  const token = await criarAparelho(antigo.env);
  const authAntigo = { authorization: "Bearer " + token };
  assert.equal(await gastoDoCiclo(antigo.pedir, authAntigo), 400);
  const ts = new Date().toISOString();
  await antigo.env.DB.prepare("INSERT INTO registros (tabela, id, dados, updated_at, server_at) VALUES ('ajustes', 'emp', '{\"divida_id\":\"cashew:o1\"}', ?1, ?1)").bind(ts).run();
  assert.equal(await gastoDoCiclo(antigo.pedir, authAntigo), 100, "desligada: o empréstimo fica fora");
});
