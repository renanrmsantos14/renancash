// Conector MCP: OAuth (registro, PKCE, refresh), JSON-RPC e as ferramentas (anotações, transações, linhas, SQL).
import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, ORIGEM } from "./ambiente.mjs";
import { base64url } from "../src/app.js";
import { alertasAnotacoes } from "../src/mcp.js";

const CALLBACK = "https://claude.ai/api/mcp/auth_callback";
const hoje = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" }).format(new Date());
const epoch = (d) => Math.floor(Date.parse(d + "T00:00:00-03:00") / 1000);
const T0 = "2026-01-01T00:00:00.000Z";

function hubFalso() {
  const avisos = [];
  return { avisos, idFromName: (n) => n, get: () => ({ fetch: async (req, init) => { avisos.push(JSON.parse(init?.body ?? (await req.text()))); return new Response(null, { status: 204 }); } }) };
}

async function preparar() {
  const hub = hubFalso();
  const amb = criarAmbiente({ ESPELHO: "1", ESPELHO_HUB: hub });
  const db = amb.env.DB;
  const linha = (tabela, pk, dados) => db.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, deleted_at, server_at, aparelho) VALUES (?1, ?2, ?3, ?4, NULL, ?4, 'cel')").bind(tabela, pk, JSON.stringify(dados), T0).run();
  await db.prepare("INSERT INTO espelho_meta (chave, valor) VALUES ('semeado', '1')").run();
  await linha("categories", "c-alim", { category_pk: "c-alim", name: "Alimentação", income: 0, main_category_pk: null, archived: 0, order: 1 });
  await linha("categories", "c-rest", { category_pk: "c-rest", name: "Restaurante", income: 0, main_category_pk: "c-alim", archived: 0, order: 2 });
  await linha("categories", "c-lazer", { category_pk: "c-lazer", name: "Lazer", income: 0, main_category_pk: null, archived: 0, order: 3 });
  await linha("wallets", "w-nu", { wallet_pk: "w-nu", name: "Nubank", archived: 0 });
  await linha("wallets", "0", { wallet_pk: "0", name: "Dinheiro", archived: 0 });
  await db.prepare("INSERT INTO accounts (id, item_id, type, name, balance, updated_at) VALUES ('acc-cc', 'it', 'CREDIT', 'Nubank Cartão', 0, ?1), ('acc-b', 'it', 'BANK', 'Inter', 100, ?1)").bind(T0).run();
  const tx = (id, conta, valor, data, desc) => db.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 'DEBIT', 'POSTED', ?6)").bind(id, conta, data, desc, valor, T0).run();
  return { ...amb, hub, db, linha, tx };
}

const pkce = async () => {
  const verificador = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const desafio = base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verificador))));
  return { verificador, desafio };
};
const form = (o) => ({ method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(o).toString() });

async function conectar(pedir) {
  const reg = await (await pedir("/oauth/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ client_name: "Claude", redirect_uris: [CALLBACK] }) })).json();
  const { verificador, desafio } = await pkce();
  const campos = { response_type: "code", client_id: reg.client_id, redirect_uri: CALLBACK, code_challenge: desafio, code_challenge_method: "S256", state: "xyz" };
  const r = await pedir("/oauth/authorize", form({ ...campos, senha: "senha" }));
  assert.equal(r.status, 302);
  const volta = new URL(r.headers.get("location"));
  assert.equal(volta.searchParams.get("state"), "xyz");
  const tok = await (await pedir("/oauth/token", form({ grant_type: "authorization_code", code: volta.searchParams.get("code"), redirect_uri: CALLBACK, client_id: reg.client_id, code_verifier: verificador }))).json();
  return { ...tok, client_id: reg.client_id, campos };
}

function cliente(pedir, token) {
  let n = 0;
  const rpc = async (method, params) => (await pedir("/mcp", { method: "POST", headers: { authorization: "Bearer " + token, "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: ++n, method, params }) })).json();
  const ferramenta = async (name, args = {}) => {
    const r = await rpc("tools/call", { name, arguments: args });
    if (r.result.isError) throw new Error(r.result.content[0].text);
    return r.result.structuredContent;
  };
  return { rpc, ferramenta };
}

test("OAuth: metadados, 401 com resource_metadata, PKCE e refresh com rotação", async () => {
  const { pedir } = await preparar();
  const meta = await (await pedir("/.well-known/oauth-authorization-server")).json();
  assert.equal(meta.token_endpoint, ORIGEM + "/oauth/token");
  assert.deepEqual(meta.code_challenge_methods_supported, ["S256"]);
  assert.equal((await (await pedir("/.well-known/oauth-protected-resource/mcp")).json()).resource, ORIGEM + "/mcp");

  const sem = await pedir("/mcp", { method: "POST", body: "{}" });
  assert.equal(sem.status, 401);
  assert.match(sem.headers.get("www-authenticate"), /resource_metadata="https:\/\/meu-banco\.test\/\.well-known\/oauth-protected-resource"/);

  const t = await conectar(pedir);
  assert.match(t.access_token, /^mcpa_/);
  const ini = await cliente(pedir, t.access_token).rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "x", version: "1" } });
  assert.equal(ini.result.protocolVersion, "2025-06-18");
  assert.ok(ini.result.capabilities.tools);

  const novo = await (await pedir("/oauth/token", form({ grant_type: "refresh_token", refresh_token: t.refresh_token, client_id: t.client_id }))).json();
  assert.match(novo.access_token, /^mcpa_/);
  const repetido = await pedir("/oauth/token", form({ grant_type: "refresh_token", refresh_token: t.refresh_token, client_id: t.client_id }));
  assert.equal(repetido.status, 400, "refresh usado não vale de novo");
});

test("OAuth: senha errada, destino estranho, verificador errado e código reusado são recusados", async () => {
  const { pedir } = await preparar();
  const ruim = await pedir("/oauth/register", { method: "POST", body: JSON.stringify({ redirect_uris: ["https://evil.example/cb"] }) });
  assert.equal(ruim.status, 400);

  const reg = await (await pedir("/oauth/register", { method: "POST", body: JSON.stringify({ redirect_uris: [CALLBACK] }) })).json();
  const { verificador, desafio } = await pkce();
  const campos = { response_type: "code", client_id: reg.client_id, redirect_uri: CALLBACK, code_challenge: desafio, code_challenge_method: "S256" };
  const pagina = await pedir("/oauth/authorize?" + new URLSearchParams(campos));
  assert.equal(pagina.status, 200);
  assert.match(pagina.headers.get("content-security-policy"), /form-action 'self' https:\/\/claude\.ai/);
  assert.match(await pagina.text(), /name="senha"/);
  assert.equal((await pedir("/oauth/authorize?" + new URLSearchParams({ ...campos, redirect_uri: "https://claude.ai/outro" }))).status, 400);

  assert.equal((await pedir("/oauth/authorize", form({ ...campos, senha: "errada" }))).status, 401);
  const r = await pedir("/oauth/authorize", form({ ...campos, senha: "senha" }));
  const code = new URL(r.headers.get("location")).searchParams.get("code");
  const troca = (v) => pedir("/oauth/token", form({ grant_type: "authorization_code", code, redirect_uri: CALLBACK, client_id: reg.client_id, code_verifier: v }));
  assert.equal((await troca("x".repeat(43))).status, 400, "verificador errado consome o código");
  assert.equal((await troca(verificador)).status, 400, "código não vale duas vezes");
});

test("anotar_gasto → candidata do banco → confirmar grava título, categoria e nota na transação do app", async () => {
  const { pedir, tx, linha, db, hub, env, esperar } = await preparar();
  const { ferramenta, rpc } = cliente(pedir, (await conectar(pedir)).access_token);
  const nomes = (await rpc("tools/list")).result.tools.map((t) => t.name);
  assert.ok(nomes.includes("anotar_gasto") && nomes.includes("consultar_sql"));

  const a = await ferramenta("anotar_gasto", { valor: 87.5, descricao: "jantar com a Ana no Madero", titulo: "Madero", subcategoria: "restaurante", nota: "aniversário" });
  assert.equal(a.anotacao.categoria, "Alimentação", "subcategoria traz a categoria-mãe");
  assert.deepEqual(a.candidatas_agora, []);

  // Chega no dia seguinte: compra no cartão (positivo) e uma saída de conta com outro valor.
  const amanha = new Date(Date.parse(hoje + "T12:00:00Z") + 86400000).toISOString().slice(0, 10);
  await tx("p1", "acc-cc", 87.5, amanha, "MADERO SHOPPING");
  await tx("p2", "acc-b", -30, amanha, "PIX");
  await tx("p3", "acc-b", 87.5, amanha, "PIX RECEBIDO"); // entrada: não é candidata de gasto
  const [pend] = (await ferramenta("listar_anotacoes")).anotacoes;
  assert.deepEqual(pend.candidatas.map((c) => c.transacao_id), ["p1"]);
  assert.equal(pend.candidatas[0].no_app, null);

  // App ainda não importou: fica vinculada; quando o app grava a linha mb:p1, o Worker aplica.
  const c1 = await ferramenta("confirmar_anotacao", { anotacao_id: a.anotacao.id, transacao_id: "p1" });
  assert.equal(c1.status, "vinculada");
  const tel = await criarAparelho(env);
  const enviar = await pedir("/api/espelho", { method: "POST", headers: { authorization: "Bearer " + tel, "content-type": "application/json" }, body: JSON.stringify({ linhas: [{ tabela: "transactions", pk: "mb:p1", updated_at: new Date().toISOString(), deleted_at: null, dados: { transaction_pk: "mb:p1", name: "MADERO SHOPPING", amount: -87.5, note: "", category_fk: "c-lazer", sub_category_fk: null, wallet_fk: "w-nu", date_created: epoch(amanha), date_time_modified: 0, income: 0, paid: 1 } }] }) });
  assert.equal(enviar.status, 200);
  await esperar(); // waitUntil do aplicarVinculadas
  const linhaApp = JSON.parse((await db.prepare("SELECT dados FROM espelho WHERE tabela = 'transactions' AND pk = 'mb:p1'").first("dados")));
  assert.equal(linhaApp.name, "Madero");
  assert.equal(linhaApp.category_fk, "c-alim");
  assert.equal(linhaApp.sub_category_fk, "c-rest");
  assert.equal(linhaApp.note, "aniversário");
  assert.equal(linhaApp.amount, -87.5, "o resto da linha fica");
  assert.ok(linhaApp.date_time_modified > 978307200, "conta como edição no app");
  assert.ok(hub.avisos.some((x) => x.aparelho === "claude"));
  assert.equal((await ferramenta("listar_anotacoes", { status: "aplicada" })).anotacoes.length, 1);

  // A mesma transação não serve para outra anotação.
  const b = await ferramenta("anotar_gasto", { valor: 87.5, descricao: "outro", data: hoje });
  assert.deepEqual(b.candidatas_agora, []);
  await assert.rejects(ferramenta("confirmar_anotacao", { anotacao_id: b.anotacao.id, transacao_id: "p1" }), /já está ligada/);

  // Linha já no app: confirmar aplica na hora.
  await tx("p9", "acc-cc", 12, hoje, "UBER");
  await linha("transactions", "mb:p9", { transaction_pk: "mb:p9", name: "UBER", amount: -12, note: "", category_fk: "c-lazer", wallet_fk: "w-nu", date_created: epoch(hoje), date_time_modified: 0 });
  const u = await ferramenta("anotar_gasto", { valor: 12, descricao: "uber pro escritório", categoria: "Lazer" });
  assert.equal(u.candidatas_agora[0].no_app.titulo, "UBER");
  assert.equal((await ferramenta("confirmar_anotacao", { anotacao_id: u.anotacao.id, transacao_id: "p9" })).status, "aplicada");
});

test("alerta de anotação com candidata sai uma vez por anotação (chave estável)", async () => {
  const { pedir, tx, db } = await preparar();
  const { ferramenta } = cliente(pedir, (await conectar(pedir)).access_token);
  await ferramenta("anotar_gasto", { valor: 50, descricao: "farmácia" });
  assert.deepEqual(await alertasAnotacoes(db), []);
  await tx("f1", "acc-b", -50, hoje, "DROGASIL");
  const [al] = await alertasAnotacoes(db);
  assert.match(al.chave, /^anotacao:/);
  assert.match(al.corpo, /farmácia \(R\$ 50,00\)/);
});

test("transações: buscar, editar, criar e apagar pelo espelho", async () => {
  const { pedir, tx, linha, db } = await preparar();
  const { ferramenta } = cliente(pedir, (await conectar(pedir)).access_token);
  await tx("q1", "acc-cc", 25, hoje, "IFOOD *RESTAURANTE");
  await linha("transactions", "mb:q1", { transaction_pk: "mb:q1", name: "iFood", amount: -25, note: "", category_fk: "c-lazer", sub_category_fk: null, wallet_fk: "w-nu", date_created: epoch(hoje), date_time_modified: 0, income: 0, paid: 1 });

  const achadas = (await ferramenta("buscar_transacoes", { texto: "restaurante" })).transacoes;
  assert.equal(achadas.length, 1);
  assert.equal(achadas[0].texto_do_banco, "IFOOD *RESTAURANTE");

  const ed = await ferramenta("editar_transacao", { pk: "mb:q1", categoria: "Alimentação", subcategoria: "Restaurante", titulo: "iFood almoço" });
  assert.equal(ed.transacao.subcategoria, "Restaurante");
  assert.equal((await ferramenta("buscar_transacoes", { categoria: "Restaurante" })).transacoes[0].titulo, "iFood almoço");

  const nova = await ferramenta("criar_transacao", { titulo: "Feira", valor: 40, categoria: "Alimentação", carteira: "dinheiro" });
  const crua = JSON.parse(await db.prepare("SELECT dados FROM espelho WHERE tabela = 'transactions' AND pk = ?1").bind(nova.transacao.pk).first("dados"));
  assert.equal(crua.amount, -40);
  assert.equal(crua.wallet_fk, "0");
  assert.equal(crua.date_created, epoch(hoje));

  await ferramenta("apagar_transacao", { pk: nova.transacao.pk });
  assert.ok(await db.prepare("SELECT deleted_at FROM espelho WHERE tabela = 'transactions' AND pk = ?1").bind(nova.transacao.pk).first("deleted_at"));
  await assert.rejects(ferramenta("criar_transacao", { titulo: "x", valor: 1, categoria: "Inexistente", carteira: "Nubank" }), /não existe. Categorias: Alimentação, Lazer/);
});

test("linhas genéricas e SQL só de leitura", async () => {
  const { pedir } = await preparar();
  const { ferramenta } = cliente(pedir, (await conectar(pedir)).access_token);
  await ferramenta("escrever_linha", { tabela: "categories", pk: "c-lazer", campos: { name: "Lazer e cultura" } });
  const [l] = (await ferramenta("ler_linhas", { tabela: "categories", pk: "c-lazer" })).linhas;
  assert.equal(l.dados.name, "Lazer e cultura");
  assert.equal(l.aparelho, "claude");
  await assert.rejects(ferramenta("escrever_linha", { tabela: "budgets", pk: "novo", campos: { name: "x" } }), /nova=true/);
  await ferramenta("apagar_linha", { tabela: "wallets", pk: "0" });
  assert.equal((await ferramenta("listar_contas")).carteiras_do_app.length, 1);

  assert.equal((await ferramenta("consultar_sql", { sql: "SELECT count(*) AS n FROM accounts" })).linhas[0].n, 2);
  for (const sql of ["DELETE FROM accounts", "SELECT 1; DELETE FROM accounts", "WITH x AS (SELECT 1) INSERT INTO config VALUES (1,1)", "SELECT * FROM app_tokens", "SELECT * FROM mcp_oauth"]) {
    await assert.rejects(ferramenta("consultar_sql", { sql }), /Erro/);
  }
});

test("JSON-RPC: notificação responde 202, método desconhecido é -32601", async () => {
  const { pedir } = await preparar();
  const t = (await conectar(pedir)).access_token;
  const h = { authorization: "Bearer " + t, "content-type": "application/json" };
  assert.equal((await pedir("/mcp", { method: "POST", headers: h, body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) })).status, 202);
  const r = await (await pedir("/mcp", { method: "POST", headers: h, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "resources/list" }) })).json();
  assert.equal(r.error.code, -32601);
  assert.equal((await pedir("/mcp", { headers: h })).status, 405);
});
