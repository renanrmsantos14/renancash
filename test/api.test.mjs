import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { ApiCliente } from "../src/api.js";

const env = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo", PLUGGY_ITEM_IDS: " a , b ," };
const resposta = (corpo, status = 200, headers = {}) => new Response(JSON.stringify(corpo), { status, headers });
let chamadas, original;
// roteador: função (url, init) → Response
const simular = (fn) => { chamadas = []; globalThis.fetch = async (url, init = {}) => { chamadas.push({ url: String(url), init }); return fn(new URL(url), init); }; };
beforeEach(() => { original = globalThis.fetch; });
afterEach(() => { globalThis.fetch = original; });

test("sem credenciais falha em pt-BR", () => {
  assert.throws(() => new ApiCliente({}), /PLUGGY_CLIENT_ID e PLUGGY_CLIENT_SECRET/);
});

test("autentica uma vez (mesmo com chamadas simultâneas) e envia X-API-KEY", async () => {
  simular((u) => (u.pathname === "/auth" ? resposta({ apiKey: "k1" }) : resposta({ id: "a", status: "UPDATED" })));
  const api = new ApiCliente(env);
  await Promise.all([api.item("a"), api.item("b")]);
  const auth = chamadas.filter((c) => c.url.endsWith("/auth"));
  assert.equal(auth.length, 1);
  assert.deepEqual(JSON.parse(auth[0].init.body), { clientId: "id", clientSecret: "segredo" });
  assert.ok(chamadas.filter((c) => !c.url.endsWith("/auth")).every((c) => c.init.headers["x-api-key"] === "k1"));
});

test("apiKey expirada (401) reautentica e repete uma vez", async () => {
  let n = 0;
  simular((u, init) => {
    if (u.pathname === "/auth") return resposta({ apiKey: "k" + ++n });
    return init.headers["x-api-key"] === "k2" ? resposta({ id: "a" }) : resposta({ message: "expired" }, 401);
  });
  assert.deepEqual(await new ApiCliente(env).item("a"), { id: "a" });
  assert.equal(n, 2);
});

test("erro por status traz dica em pt-BR e o status", async () => {
  simular((u) => (u.pathname === "/auth" ? resposta({ message: "Invalid credentials" }, 401) : resposta({})));
  await assert.rejects(new ApiCliente(env).item("a"), (e) => e.status === 401 && /credenciais do Pluggy inválidas/.test(e.message) && !/segredo/.test(e.message));
  simular((u) => (u.pathname === "/auth" ? resposta({ apiKey: "k" }) : resposta({ message: "x" }, 404)));
  await assert.rejects(new ApiCliente(env).item("zzz"), /HTTP 404 \(não encontrado no Pluggy/);
  simular((u) => (u.pathname === "/auth" ? resposta({ apiKey: "k" }) : resposta({}, 503)));
  await assert.rejects(new ApiCliente(env).contas("a"), /HTTP 503 \(instabilidade/);
});

test("429 espera o Retry-After e tenta de novo", async () => {
  let n = 0;
  simular((u) => (u.pathname === "/auth" ? resposta({ apiKey: "k" }) : ++n === 1 ? resposta({}, 429, { "retry-after": "1" }) : resposta({ results: [{ id: "c1" }] })));
  assert.deepEqual(await new ApiCliente(env).contas("a"), [{ id: "c1" }]);
  assert.equal(n, 2);
}, { timeout: 20000 });

test("listarIds usa PLUGGY_ITEM_IDS; sem ele tenta /v2/items paginado; sem acesso pede o env", async () => {
  simular((u) => resposta({ apiKey: "k" }));
  assert.deepEqual(await new ApiCliente(env).listarIds(), ["a", "b"]);
  simular(() => resposta({ message: "Invalid credentials" }, 401));
  await assert.rejects(new ApiCliente(env).listarIds(), /credenciais do Pluggy inválidas/);
  const sem = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "s" };
  simular((u) => {
    if (u.pathname === "/auth") return resposta({ apiKey: "k" });
    return u.searchParams.get("after") ? resposta({ results: [{ id: "i3" }], next: null }) : resposta({ results: [{ id: "i1" }, { id: "i2" }], next: "?after=x" });
  });
  assert.deepEqual(await new ApiCliente(sem).listarIds(), ["i1", "i2", "i3"]);
  simular((u) => (u.pathname === "/auth" ? resposta({ apiKey: "k" }) : resposta({ message: "Forbidden" }, 403)));
  await assert.rejects(new ApiCliente(sem).listarIds(), /Defina PLUGGY_ITEM_IDS/);
});

test("transacoes pagina por totalPages e manda accountId/from/to; sem to omite o parâmetro", async () => {
  simular((u) => {
    if (u.pathname === "/auth") return resposta({ apiKey: "k" });
    const p = Number(u.searchParams.get("page"));
    return resposta({ page: p, totalPages: 3, total: 5, results: p === 3 ? [{ id: "t5" }] : [{ id: `t${p * 2 - 1}` }, { id: `t${p * 2}` }] });
  });
  const todas = await new ApiCliente(env).transacoes("c1", "2026-05-01", undefined, 10);
  assert.deepEqual(todas.map((t) => t.id), ["t1", "t2", "t3", "t4", "t5"]);
  const u = new URL(chamadas.at(-1).url);
  assert.equal(u.searchParams.get("accountId"), "c1");
  assert.equal(u.searchParams.get("from"), "2026-05-01");
  assert.equal(u.searchParams.get("pageSize"), "500");
  assert.equal(u.searchParams.has("to"), false);
  await assert.rejects(new ApiCliente(env).transacoes("c1", "2026-05-01", "2026-11-01", 2), /mais de 2 páginas/);
});
