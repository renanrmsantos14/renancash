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

const rotaTx = (v2, v1) => (u) => (u.pathname === "/auth" ? resposta({ apiKey: "k" }) : u.pathname === "/v2/transactions" ? v2(u) : v1(u));

test("transacoes v2: segue o cursor `after` de `next`, manda dateFrom/dateTo e omite dateTo no cartão", async () => {
  simular(rotaTx((u) => {
    const after = u.searchParams.get("after");
    if (!after) return resposta({ results: [{ id: "t1" }, { id: "t2" }], next: "?accountId=c1&after=a%2Fb%3D%3D" });
    assert.equal(after, "a/b=="); // decodificado
    return resposta({ results: [{ id: "t3" }], next: null });
  }, () => resposta({}, 500)));
  const todas = await new ApiCliente(env).transacoes("c1", "2026-05-01", undefined, 10);
  assert.deepEqual(todas.map((t) => t.id), ["t1", "t2", "t3"]);
  const u = new URL(chamadas.at(-2).url);
  assert.equal(u.searchParams.get("accountId"), "c1");
  assert.equal(u.searchParams.get("dateFrom"), "2026-05-01");
  assert.equal(u.searchParams.has("dateTo"), false);
  assert.equal(u.searchParams.has("from"), false);
  simular(rotaTx(() => resposta({ results: [{ id: "x" }], next: "?after=mais" }), () => resposta({}, 500)));
  await assert.rejects(new ApiCliente(env).transacoes("c1", "2026-05-01", "2026-11-01", 2), /mais de 2 páginas/);
});

test("transacoes: v2 indisponível (404) cai na v1 paginada por totalPages e lembra a escolha", async () => {
  simular(rotaTx(() => resposta({ message: "nf" }, 404), (u) => {
    const p = Number(u.searchParams.get("page"));
    return resposta({ page: p, totalPages: 2, results: [{ id: `v1-${p}` }] });
  }));
  const api = new ApiCliente(env);
  assert.deepEqual((await api.transacoes("c1", "2026-05-01", "2026-11-01", 10)).map((t) => t.id), ["v1-1", "v1-2"]);
  const u = new URL(chamadas.at(-1).url);
  assert.equal(u.searchParams.get("from"), "2026-05-01");
  assert.equal(u.searchParams.get("to"), "2026-11-01");
  const antes = chamadas.filter((c) => c.url.includes("/v2/")).length;
  await api.transacoes("c2", "2026-05-01", undefined, 10);
  assert.equal(chamadas.filter((c) => c.url.includes("/v2/")).length, antes); // não tenta a v2 de novo
});

test("transacoes: erro 5xx na v2 não cai na v1", async () => {
  simular(rotaTx(() => resposta({}, 503), () => resposta({ results: [] })));
  await assert.rejects(new ApiCliente(env).transacoes("c1", "2026-05-01", undefined, 10), /HTTP 503/);
});
