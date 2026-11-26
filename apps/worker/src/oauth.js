// OAuth 2.1 do conector MCP (claude.ai, Claude Code): registro dinâmico (RFC 7591), código com PKCE S256 e refresh com rotação.
// Só o SHA-256 de códigos e tokens fica no D1 (tabela mcp_oauth). A tela de autorização pede a senha do painel (APP_PASSWORD).
import { agoraS, base64url, gerarToken, hashToken } from "./app.js";

const ACESSO_S = 3600; // token de acesso: 1 h
const REFRESH_S = 90 * 24 * 3600; // refresh: 90 dias, trocado a cada uso
const CODIGO_S = 300; // código de autorização: 5 min, uso único
// Destinos aceitos no registro: o callback do claude.ai/claude.com e clientes locais (Claude Code).
const DESTINO_OK = /^(https:\/\/(claude\.ai|claude\.com)\/|http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/)/;

const json = (obj, status = 200) => Response.json(obj, { status }); // no-store e demais cabeçalhos: seguranca() no index.js
const erroOAuth = (erro, descricao, status = 400) => json({ error: erro, error_description: descricao }, status);
const html = (corpo, status = 200) => new Response(corpo, { status, headers: { "content-type": "text/html; charset=utf-8" } });
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

export const metadadosRecurso = (origem) => ({
  resource: origem + "/mcp",
  authorization_servers: [origem],
  bearer_methods_supported: ["header"],
  resource_name: "RenanCash",
});

export const metadadosServidor = (origem) => ({
  issuer: origem,
  authorization_endpoint: origem + "/oauth/authorize",
  token_endpoint: origem + "/oauth/token",
  registration_endpoint: origem + "/oauth/register",
  response_types_supported: ["code"],
  grant_types_supported: ["authorization_code", "refresh_token"],
  code_challenge_methods_supported: ["S256"],
  token_endpoint_auth_methods_supported: ["none"],
  scopes_supported: ["renancash"],
});

export async function registrarCliente(request, db) {
  const corpo = await request.json().catch(() => null);
  const destinos = Array.isArray(corpo?.redirect_uris) ? corpo.redirect_uris.filter((u) => typeof u === "string") : [];
  if (!destinos.length || destinos.length > 5) return erroOAuth("invalid_redirect_uri", "Informe de 1 a 5 redirect_uris");
  const ruim = destinos.find((u) => !DESTINO_OK.test(u));
  if (ruim) return erroOAuth("invalid_redirect_uri", "Destino não permitido: " + ruim);
  const nome = typeof corpo.client_name === "string" ? corpo.client_name.slice(0, 80) : "Cliente MCP";
  const id = "mcp_" + crypto.randomUUID();
  const criado = agoraS();
  await db.prepare("INSERT INTO mcp_clientes (id, nome, destinos, criado) VALUES (?1, ?2, ?3, ?4)").bind(id, nome, JSON.stringify(destinos), criado).run();
  return json({
    client_id: id, client_name: nome, redirect_uris: destinos, client_id_issued_at: criado,
    grant_types: ["authorization_code", "refresh_token"], response_types: ["code"], token_endpoint_auth_method: "none",
  }, 201);
}

async function clienteDe(db, id) {
  const c = id ? await db.prepare("SELECT id, nome, destinos FROM mcp_clientes WHERE id = ?1").bind(id).first() : null;
  return c && { ...c, destinos: JSON.parse(c.destinos) };
}

// Confere o pedido de autorização (GET mostra o formulário, POST repete os campos escondidos).
async function pedidoValido(db, p) {
  const cliente = await clienteDe(db, p.get("client_id"));
  if (!cliente) return { erro: "Cliente desconhecido. Remova e adicione o conector de novo." };
  const destino = p.get("redirect_uri");
  if (!cliente.destinos.includes(destino)) return { erro: "redirect_uri não registrado para este cliente." };
  if (p.get("response_type") !== "code") return { erro: "response_type deve ser code." };
  if (p.get("code_challenge_method") !== "S256" || !/^[\w-]{43,128}$/.test(p.get("code_challenge") || "")) return { erro: "PKCE S256 obrigatório." };
  return { cliente, destino };
}

const CAMPOS = ["response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "scope", "resource"];

function pagina({ cliente, params, erro }) {
  const escondidos = CAMPOS.filter((k) => params.get(k) != null).map((k) => `<input type="hidden" name="${k}" value="${esc(params.get(k))}">`).join("");
  return `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Autorizar acesso · RenanCash</title><style>
:root{color-scheme:light dark;--bg:#f6f6f4;--card:#fff;--tx:#1c1c1a;--sub:#6b6b66;--ac:#0f766e;--er:#b42318}
@media (prefers-color-scheme:dark){:root{--bg:#121211;--card:#1c1c1b;--tx:#ededea;--sub:#a3a39d;--ac:#2dd4bf;--er:#f97066}}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--tx);font:16px/1.5 system-ui,sans-serif;padding:16px;box-sizing:border-box}
main{background:var(--card);border-radius:16px;padding:28px;max-width:380px;width:100%;box-shadow:0 1px 3px #0002}
h1{font-size:20px;margin:0 0 8px}p{color:var(--sub);margin:0 0 20px}.er{color:var(--er)}
input[type=password]{width:100%;box-sizing:border-box;padding:12px;border-radius:10px;border:1px solid #8885;background:transparent;color:inherit;font:inherit}
button{margin-top:14px;width:100%;padding:12px;border:0;border-radius:10px;background:var(--ac);color:#fff;font:600 16px system-ui;cursor:pointer}
</style></head><body><main><h1>Autorizar ${esc(cliente.nome)}</h1>
<p>Este conector poderá ler e alterar todos os dados do RenanCash. Digite a senha do painel para liberar.</p>
${erro ? `<p class="er" role="alert">${esc(erro)}</p>` : ""}
<form method="post" action="/oauth/authorize">${escondidos}
<label for="s">Senha</label><input id="s" type="password" name="senha" autocomplete="current-password" required autofocus>
<button type="submit">Autorizar</button></form></main></body></html>`;
}

// `conferirSenha(senha)` devolve null (ok) ou { erro } (senha errada, muitas tentativas).
export async function autorizar(request, db, url, conferirSenha) {
  const params = request.method === "POST" ? new URLSearchParams(await request.text()) : url.searchParams;
  const v = await pedidoValido(db, params);
  if (v.erro) return html(`<!doctype html><meta charset="utf-8"><title>Erro</title><p>${esc(v.erro)}</p>`, 400);
  if (request.method !== "POST") return html(pagina({ cliente: v.cliente, params }));
  const negada = await conferirSenha(params.get("senha") || "");
  if (negada) return html(pagina({ cliente: v.cliente, params, erro: negada.erro }), negada.status);
  const codigo = gerarToken("mcpc_");
  await db.prepare("INSERT INTO mcp_oauth (hash, tipo, cliente, dados, expira, criado) VALUES (?1, 'codigo', ?2, ?3, ?4, ?5)")
    .bind(await hashToken(codigo), v.cliente.id, JSON.stringify({ destino: v.destino, desafio: params.get("code_challenge") }), agoraS() + CODIGO_S, agoraS()).run();
  const volta = new URL(v.destino);
  volta.searchParams.set("code", codigo);
  if (params.get("state") != null) volta.searchParams.set("state", params.get("state"));
  return Response.redirect(volta.toString(), 302);
}

async function desafioDe(verificador) {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verificador))));
}

// Consome uma linha (código ou refresh) de uma vez: DELETE ... RETURNING impede o reuso em corrida.
async function consumir(db, valor, tipo) {
  if (typeof valor !== "string" || !valor) return null;
  const r = await db.prepare("DELETE FROM mcp_oauth WHERE hash = ?1 AND tipo = ?2 RETURNING cliente, dados, expira").bind(await hashToken(valor), tipo).first();
  return r && r.expira > agoraS() ? { cliente: r.cliente, dados: JSON.parse(r.dados || "{}") } : null;
}

async function emitir(db, cliente) {
  const acesso = gerarToken("mcpa_");
  const refresh = gerarToken("mcpr_");
  const t = agoraS();
  await db.batch([
    db.prepare("INSERT INTO mcp_oauth (hash, tipo, cliente, dados, expira, criado) VALUES (?1, 'acesso', ?2, NULL, ?3, ?4)").bind(await hashToken(acesso), cliente, t + ACESSO_S, t),
    db.prepare("INSERT INTO mcp_oauth (hash, tipo, cliente, dados, expira, criado) VALUES (?1, 'refresh', ?2, NULL, ?3, ?4)").bind(await hashToken(refresh), cliente, t + REFRESH_S, t),
    db.prepare("DELETE FROM mcp_oauth WHERE expira < ?1").bind(t), // faxina
  ]);
  return json({ access_token: acesso, token_type: "Bearer", expires_in: ACESSO_S, refresh_token: refresh, scope: "renancash" });
}

export async function trocarToken(request, db) {
  const p = new URLSearchParams(await request.text());
  const tipo = p.get("grant_type");
  if (tipo === "authorization_code") {
    const c = await consumir(db, p.get("code"), "codigo");
    if (!c || c.cliente !== p.get("client_id") || c.dados.destino !== p.get("redirect_uri")) return erroOAuth("invalid_grant", "Código inválido, vencido ou já usado");
    if ((await desafioDe(p.get("code_verifier") || "")) !== c.dados.desafio) return erroOAuth("invalid_grant", "code_verifier não confere");
    return emitir(db, c.cliente);
  }
  if (tipo === "refresh_token") {
    const r = await consumir(db, p.get("refresh_token"), "refresh");
    if (!r || r.cliente !== p.get("client_id")) return erroOAuth("invalid_grant", "Refresh token inválido ou vencido");
    return emitir(db, r.cliente);
  }
  return erroOAuth("unsupported_grant_type", "Use authorization_code ou refresh_token");
}

// Bearer do MCP: devolve o id do cliente ou null.
export async function acessoValido(request, db) {
  const m = /^Bearer (mcpa_[\w-]{43})$/.exec(request.headers.get("authorization") || "");
  if (!m) return null;
  const r = await db.prepare("SELECT cliente, expira FROM mcp_oauth WHERE hash = ?1 AND tipo = 'acesso'").bind(await hashToken(m[1])).first();
  return r && r.expira > agoraS() ? r.cliente : null;
}
