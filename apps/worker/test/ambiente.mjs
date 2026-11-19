// Monta env/ctx para chamar worker.fetch no Node, com login, token de aparelho e Pluggy falso.
import worker from "../src/index.js";
import { gerarToken, hashToken } from "../src/app.js";
import { criarD1 } from "./d1.mjs";

// O Workers tem crypto.subtle.timingSafeEqual; o Node não.
crypto.subtle.timingSafeEqual ??= (a, b) => Buffer.from(a).equals(Buffer.from(b));

export const ORIGEM = "https://meu-banco.test";

export function criarAmbiente(extra = {}) {
  const tarefas = [];
  const env = { APP_PASSWORD: "senha", SESSION_SECRET: "segredo", DB: criarD1(), ASSETS: { fetch: async () => new Response("asset") }, ...extra };
  const ctx = { waitUntil: (p) => tarefas.push(p) };
  const pedir = (caminho, init = {}) => worker.fetch(new Request(ORIGEM + caminho, init), env, ctx);
  return { env, ctx, worker, pedir, esperar: () => Promise.allSettled(tarefas) };
}

export async function entrarComSenha(pedir) {
  const r = await pedir("/api/login", { method: "POST", headers: { origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ senha: "senha" }) });
  if (r.status !== 200) throw new Error("login falhou: " + r.status);
  return r.headers.get("set-cookie").split(";")[0];
}

export async function criarAparelho(env, nome = "Celular") {
  const token = gerarToken();
  await env.DB.prepare("INSERT INTO app_tokens (id, nome, hash, criado) VALUES (?1, ?2, ?3, ?4)")
    .bind(crypto.randomUUID(), nome, await hashToken(token), new Date().toISOString()).run();
  return token;
}

// rotas(url, init) devolve um objeto JSON ou uma Response. /auth responde sozinho.
const fetchOriginal = globalThis.fetch;
export function simularPluggy(rotas) {
  const chamadas = [];
  globalThis.fetch = async (alvo, init = {}) => {
    const url = new URL(String(alvo));
    chamadas.push({ metodo: init.method || "GET", caminho: url.pathname, corpo: init.body ? JSON.parse(init.body) : null });
    if (url.pathname === "/auth") return Response.json({ apiKey: "k" });
    const r = await rotas(url, init);
    return r instanceof Response ? r : Response.json(r ?? {});
  };
  return { chamadas };
}
export const restaurarFetch = () => { globalThis.fetch = fetchOriginal; };

// Durable Object do espelho que só engole os avisos (testes que não olham o WebSocket).
export const hubMudo = () => ({ idFromName: (n) => n, get: () => ({ fetch: async () => new Response(null, { status: 204 }) }) });

// Os testes de ciclo, revisões e notificações rodam com a flag desligada (lê `registros`) e ligada (lê o espelho).
export const MODOS = [false, true];
export const extraDoModo = (espelho) => (espelho ? { ESPELHO: "1", ESPELHO_HUB: hubMudo() } : {});
export const nomeDoModo = (espelho) => (espelho ? "[espelho]" : "[registros]");

// Com a flag ligada o espelho precisa estar semeado para aceitar linhas (POST /api/espelho).
export async function semearVazio(pedir, token) {
  const r = await pedir("/api/espelho/semear", { method: "POST", headers: { authorization: "Bearer " + token, "content-type": "application/json" }, body: JSON.stringify({ lote: 0, fim: true, linhas: [] }) });
  if (r.status !== 200) throw new Error("semeio falhou: " + r.status);
}
