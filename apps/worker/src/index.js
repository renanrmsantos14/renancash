import { contextoDeRegistros } from "@meu-banco/core";
import { renderSVG } from "uqr";
import { ApiCliente } from "./api.js";
import { bancoDoItem, desambiguar, mapearConta, mapearTransacao, avisoItem, mapearFaturas, mapearInvestimentos, mapearEmprestimos, semAplicado, aplicadoPelasMovimentacoes } from "./mapa.js";
import { resumoCiclo, gastoPorDia, normalizar, somarDias, semIgnoradas } from "./ciclo.js";
import { lerRevisoes, aplicarRevisoes, filaRevisar } from "./revisao.js";
import { stmtAlertas, gravarAlertas, resumoSemanal, emSilencio, consumoGeral, alertasGeral, comprasNovas, alertaCompras, alertasFatura, alertasCredito, alertasConsentimento, alertasEmprestimos, alertasConexao, alertasRevisao, linhasMetas, doTipo } from "./alertas.js";
import { REGEX_ITEM, idsConexoes, registrarItem, esquecerItem, limparRemovidas, listarConexoes, atualizarStatus, acaoWebhook, webhookValido, apagarTransacoes, idsRemovidos } from "./pluggy.js";
import { enviarPush } from "./push.js";
import { salvarBackup } from "./backup.js";
import { autenticarAparelho, puxar, enviar, esperaAtualizar } from "./sync.js";
import { CHAVE_HISTORICO, mesSP, registrarRetrato } from "./historico.js";
import { base64url, gerarToken, hashToken, normalizarDesde, montarResposta } from "./app.js";
import { sugerir, entender } from "./ia.js";
import { avisar, configDe, enviarEspelho, espelhoLigado, hubDo, puxarEspelho, registrosDoEspelho, semear } from "./espelho.js";

export { EspelhoHub } from "./hub.js";

const TZ = "America/Sao_Paulo";
const LINHAS_POR_INSERT = 400; // linhas por comando SQL (via json_each, 1 parâmetro só)
const MAX_PAGINAS = 10; // limite de segurança (subrequests do plano grátis)
const VALIDADE_ALERTA_MS = 48 * 3600 * 1000; // alerta não enviado/entregue há mais que isso é velho demais para virar notificação
const TRAVA_MS = 10 * 60 * 1000; // sync_log aberto há menos que isso = sincronização em andamento
const MSG_OCUPADO = "Já existe uma atualização em andamento. Tente em alguns minutos.";
const DIAS_REIMPORTAR = 10; // relê os últimos dias para pegar lançamentos que o banco posta com atraso

export default {
  async fetch(request, env, ctx) {
    if (!env.APP_PASSWORD || !env.SESSION_SECRET) return seguranca(new Response("APP_PASSWORD ou SESSION_SECRET não configurado.", { status: 500 }));
    const url = new URL(request.url);
    const caminho = url.pathname;
    const idToken = /^\/api\/app\/tokens\/([^/]+)$/.exec(caminho)?.[1];
    try {
      let resp;
      if (caminho === "/app") return seguranca(new Response(null, { status: 301, headers: { location: "/app/" } }));
      if (caminho.startsWith("/app/")) {
        // Manifest e ícones ficam públicos: o navegador os busca sem cookie para instalar o PWA.
        if (!APP_PUBLICO.test(caminho) && !(await sessaoValida(request, env))) return seguranca(new Response(null, { status: 302, headers: { location: "/login?volta=/app/" } }));
        const r = seguranca(await env.ASSETS.fetch(request), cspApp(env, url));
        r.headers.set("cache-control", "private, no-cache");
        return r;
      }
      if (caminho === "/api/login" && request.method === "POST") resp = await entrar(request, env, url);
      else if (caminho === "/api/app/parear" && request.method === "POST") resp = await parearComSenha(request, env, url);
      else if (caminho === "/api/pluggy/webhook" && request.method === "POST") resp = await webhookPluggy(request, env, url, ctx);
      else if (PUBLICO.test(caminho)) resp = await env.ASSETS.fetch(request);
      else if (caminho === "/api/app/transacoes" && request.method === "GET") resp = await appTransacoes(request, env, url); // Bearer, sem cookie
      else if (ROTAS_ESPELHO.has(caminho)) resp = espelhoLigado(env) ? await rotaEspelho(request, env, url, caminho, ctx) : json({ erro: "Rota não encontrada" }, 404);
      else if (ROTAS_APARELHO.has(caminho) || ROTA_CONEXAO.test(caminho)) resp = await rotaAparelho(request, env, url, caminho, ctx); // Bearer ou cookie
      else if (!(await sessaoValida(request, env))) {
        resp = caminho.startsWith("/api/") ? json({ erro: "Sessão necessária" }, 401) : new Response(null, { status: 302, headers: { location: "/login" } });
      } else if (caminho === "/api/sair" && request.method === "POST") {
        resp = mesmaOrigem(request, url) ? json({ ok: true }, 200, { "set-cookie": cookie("", 0) }) : json({ erro: "Origem não permitida" }, 403);
      } else if (caminho === "/api/dados" && request.method === "GET") resp = await dados(env, url);
      else if (caminho === "/api/historico" && request.method === "GET") resp = await historico(env);
      else if (caminho === "/api/fatura" && request.method === "GET") resp = await fatura(env, url);
      else if (/^\/api\/ajustes\/[^/]+$/.test(caminho) && request.method === "PUT") {
        if (espelhoLigado(env)) resp = json({ erro: "Edição pelo painel desativada: o app é a fonte dos ajustes" }, 410);
        else resp = mesmaOrigem(request, url) ? await salvarAjuste(request, env, caminho.slice(13)) : json({ erro: "Origem não permitida" }, 403);
      } else if (caminho === "/api/pluggy/webhooks" && request.method === "POST") {
        if (!mesmaOrigem(request, url)) resp = json({ erro: "Origem não permitida" }, 403);
        else if (!env.PLUGGY_WEBHOOK_SECRET) resp = json({ erro: "PLUGGY_WEBHOOK_SECRET ausente" }, 500);
        else resp = json(await new ApiCliente(env).criarWebhook(url.origin + "/api/pluggy/webhook", env.PLUGGY_WEBHOOK_SECRET));
      } else if (caminho === "/api/atualizar" && request.method === "POST") {
        resp = mesmaOrigem(request, url) ? await atualizarAgora(env, "botao", ctx) : json({ erro: "Origem não permitida" }, 403);
      } else if (caminho === "/api/ciclo" && request.method === "GET") resp = await ciclo(env);
      else if (caminho === "/api/push" && (request.method === "POST" || request.method === "DELETE")) resp = await inscreverPush(request, env, url);
      else if (caminho === "/api/push/teste" && request.method === "POST") resp = await testePush(request, env, url);
      else if (caminho === "/api/notificacoes/entregar" && request.method === "POST") resp = await entregarNotificacoes(request, env, url);
      else if (caminho === "/api/app/tokens" && request.method === "GET") resp = await listarTokens(env);
      else if (caminho === "/api/app/tokens" && request.method === "POST") resp = await criarToken(request, env, url);
      else if (request.method === "DELETE" && idToken) resp = await revogarToken(request, env, url, idToken);
      else if (caminho === "/api/ferramentas" && request.method === "GET") {
        // Diagnóstico: testa as credenciais do Pluggy e mostra o status de cada conexão.
        const api = await clientePluggy(env.DB, env, agora());
        const itens = await Promise.all((await api.listarIds()).map((id) => api.item(id).then((i) => ({ id, conector: i.connector?.name, status: i.status, executionStatus: i.executionStatus, lastUpdatedAt: i.lastUpdatedAt }), (e) => ({ id, erro: e.message }))));
        resp = json({ itens });
      } else if (caminho.startsWith("/api/")) resp = json({ erro: "Rota não encontrada" }, 404);
      else resp = await env.ASSETS.fetch(request);
      return resp.status === 101 ? resp : seguranca(resp); // upgrade de WebSocket: a resposta do DO não pode ser recriada
    } catch (e) {
      console.error("Erro na requisição", caminho, e?.stack || e);
      return seguranca(json({ erro: String(e?.message || e) }, 500));
    }
  },

  async scheduled(evento, env, ctx) {
    // Um cron só (plano gratuito: 5 por conta), de 3 em 3 horas em horário de Brasília (22h07, 01h07, ..., 19h07).
    // Cada sincronização envia os alertas pendentes, então o que ficou retido no silêncio (22h-7h) sai no tick das 07h07.
    // O tick de domingo 19h07 BRT (22h UTC) também manda o resumo semanal; o de 04h07 BRT (07h UTC) faz o backup.
    const t = new Date(evento.scheduledTime);
    const resumo = t.getUTCDay() === 0 && t.getUTCHours() === 22;
    const backup = t.getUTCHours() === 7 && env.BACKUP;
    ctx.waitUntil(sincronizar(env, "cron").finally(async () => {
      if (resumo) await alertaSemanal(env);
      // O backup nunca derruba a sincronização: em falha, só registra o erro (sem segredos).
      if (backup) await salvarBackup(env, t).then((k) => console.log("Backup salvo", k), (e) => console.error("Backup falhou", e?.message || e));
    }));
  },
};

// ---------- Segurança ----------

// Páginas e arquivos que o navegador precisa antes do login.
const APP_PUBLICO = /^\/app\/(manifest\.json|favicon\.(png|ico)|icons\/[\w.-]+\.png)$/;
const PUBLICO = /^\/(login|login\.html|manifest\.webmanifest|sw\.js|apple-touch-icon\.png|icons\/[\w.-]+)$/;
const SESSAO_SEGUNDOS = 30 * 24 * 3600;

// Cookie "sessao" = <expiraEm>.<HMAC-SHA256>. A chave usa SESSION_SECRET (aleatório: um cookie vazado não permite
// adivinhar a senha offline) + APP_PASSWORD. Trocar qualquer um dos dois derruba todas as sessões.
// A chave fica em memória por isolate; é refeita só se os secrets mudarem.
let chaveSessao = null;
async function chaveDe(senha) {
  if (chaveSessao?.senha !== senha) {
    const base = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("meu-banco:sessao:" + senha));
    chaveSessao = { senha, chave: await crypto.subtle.importKey("raw", base, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]) };
  }
  return chaveSessao.chave;
}

async function assinar(expira, env) {
  const chave = await chaveDe(env.SESSION_SECRET + ":" + env.APP_PASSWORD);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", chave, new TextEncoder().encode(String(expira)))));
}

const cookie = (valor, segundos) => `sessao=${valor}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${segundos}`;

async function sessaoValida(request, env) {
  const m = /(?:^|;\s*)sessao=(\d+)\.([\w-]+)/.exec(request.headers.get("cookie") || "");
  if (!m || Number(m[1]) < Date.now() / 1000) return false;
  return iguais(m[2], await assinar(m[1], env));
}

async function entrar(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const { erro } = await conferirSenha(request, env);
  if (erro) return erro;
  const expira = Math.floor(Date.now() / 1000) + SESSAO_SEGUNDOS;
  return json({ ok: true }, 200, { "set-cookie": cookie(`${expira}.${await assinar(expira, env)}`, SESSAO_SEGUNDOS) });
}

// Pareamento sem QR: o app manda a senha do painel e recebe um token de aparelho.
async function parearComSenha(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const { erro, corpo } = await conferirSenha(request, env);
  if (erro) return erro;
  const novo = await inserirToken(env, corpo.nome);
  return novo ? json({ token: novo.token, url: url.origin }, 201) : json({ erro: "Informe um nome de 1 a 40 caracteres" }, 400);
}

// Limite por IP (binding de rate limit): 5 tentativas por minuto, além da espera de 1 s por erro.
async function conferirSenha(request, env) {
  const ip = request.headers.get("cf-connecting-ip") || "local";
  if (env.LIMITE_LOGIN && !(await env.LIMITE_LOGIN.limit({ key: ip })).success) {
    return { erro: json({ erro: "Muitas tentativas. Espere 1 minuto." }, 429) };
  }
  const corpo = await request.json().catch(() => null);
  if (!(await iguais(typeof corpo?.senha === "string" ? corpo.senha : "", env.APP_PASSWORD))) {
    await new Promise((r) => setTimeout(r, 1000)); // freia tentativa em série
    return { erro: json({ erro: "Senha incorreta" }, 401) };
  }
  return { corpo };
}

// Comparação em tempo constante (compara os hashes, que têm o mesmo tamanho).
async function iguais(a, b) {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(ha, hb);
}

function mesmaOrigem(request, url) {
  const origem = request.headers.get("origin");
  return !origem || origem === url.origin;
}

const CSP_PAINEL = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; manifest-src 'self'; worker-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";
const CSP_APP = "default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; manifest-src 'self'; worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";

// Com o espelho ligado o app abre um WebSocket na própria origem; 'self' não cobre wss: em todos os navegadores.
const cspApp = (env, url) => (espelhoLigado(env) ? CSP_APP.replace("connect-src 'self'", `connect-src 'self' wss://${url.host}`) : CSP_APP);

function seguranca(resp, csp = CSP_PAINEL) {
  const r = new Response(resp.body, resp);
  r.headers.set("x-content-type-options", "nosniff");
  r.headers.set("x-frame-options", "DENY");
  r.headers.set("referrer-policy", "no-referrer");
  r.headers.set("cache-control", "private, no-store");
  r.headers.set("content-security-policy", csp);
  return r;
}

function json(obj, status = 200, extra = {}) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json; charset=utf-8", ...extra } });
}

// ---------- Datas ----------

const agora = () => new Date().toISOString();
const hojeSP = () => new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(new Date());

// Segmento de URL malformado (%) vira "", que as rotas já tratam como id inválido.
const decodificar = (segmento) => { try { return decodeURIComponent(segmento); } catch { return ""; } };

// ---------- API do painel ----------

// Transações já com o ajuste do painel (categoria e "gasto"), numa consulta só.
const COLUNAS_TX = "t.id, t.account_id, t.date, t.description, t.amount, t.type, t.status, t.category, t.merchant, t.scheduled, t.entre_minhas, t.tipo_credito, t.contraparte, t.bill_month, a.category AS ajuste_categoria, a.gasto AS ajuste_gasto";
// Com ESPELHO = 1 os ajustes vêm do espelho (v_ajustes_espelho), não de `registros`.
const deTx = (env) => `FROM transactions t LEFT JOIN ${espelhoLigado(env) ? "v_ajustes_espelho" : "v_ajustes"} a ON a.transaction_id = t.id`;

async function dados(env, url) {
  const db = env.DB;
  const mesParam = url.searchParams.get("mes");
  const mes = /^\d{4}-\d{2}$/.test(mesParam || "") ? mesParam : hojeSP().slice(0, 7);
  const [contas, transacoes, meses, snaps, ultimaOk, ultima] = await db.batch([
    db.prepare("SELECT * FROM accounts ORDER BY type, name"),
    db.prepare(`SELECT ${COLUNAS_TX} ${deTx(env)} WHERE t.date >= ?1 AND t.date <= ?2 ORDER BY t.date DESC, t.id`).bind(mes + "-01", mes + "-31"),
    db.prepare("SELECT DISTINCT substr(date, 1, 7) AS mes FROM transactions ORDER BY mes DESC LIMIT 60"),
    db.prepare("SELECT key, data, updated_at FROM snapshots"),
    db.prepare("SELECT finished_at FROM sync_log WHERE ok = 1 ORDER BY id DESC LIMIT 1"),
    db.prepare("SELECT origem, started_at, finished_at, ok, message FROM sync_log ORDER BY id DESC LIMIT 1"),
  ]);
  const snapshots = {};
  for (const s of snaps.results) snapshots[s.key] = JSON.parse(s.data);
  return json({
    mes,
    meses: meses.results.map((m) => m.mes),
    contas: contas.results,
    transacoes: transacoes.results,
    snapshots,
    ultimaAtualizacao: ultimaOk.results[0]?.finished_at ?? null,
    ultimaExecucao: ultima.results[0] ?? null,
  });
}

// Últimos 6 meses (campos mínimos) para os gráficos; o cliente aplica a regra de "não é gasto".
async function historico(env) {
  const hoje = hojeSP();
  const de = new Date(Date.UTC(+hoje.slice(0, 4), +hoje.slice(5, 7) - 6, 1)).toISOString().slice(0, 10);
  const { results } = await env.DB.prepare(
    `SELECT t.id, t.account_id, t.date, t.description, t.amount, t.category, a.category AS ajuste_categoria, a.gasto AS ajuste_gasto ${deTx(env)} WHERE t.date >= ?1 AND t.scheduled = 0`
  ).bind(de).all();
  return json({ mesAtual: hoje.slice(0, 7), de, transacoes: results });
}

// Compras de um cartão numa janela de datas (a fatura), incluindo parcelas futuras.
async function fatura(env, url) {
  const [conta, de, ate] = ["conta", "de", "ate"].map((k) => url.searchParams.get(k) || "");
  if (!conta || !/^\d{4}-\d{2}-\d{2}$/.test(de) || !/^\d{4}-\d{2}-\d{2}$/.test(ate)) return json({ erro: "Parâmetros inválidos" }, 400);
  const { results } = await env.DB.prepare(`SELECT ${COLUNAS_TX} ${deTx(env)} WHERE t.account_id = ?1 AND t.date >= ?2 AND t.date <= ?3 ORDER BY t.date DESC, t.id`)
    .bind(conta, de, ate).all();
  return json({ transacoes: results });
}

async function salvarAjuste(request, env, idUrl) {
  const id = decodificar(idUrl);
  const c = await request.json().catch(() => null);
  const category = c?.category ?? null;
  const gasto = c?.gasto ?? null;
  const valido = id && id.length <= 100 && (category === null || (typeof category === "string" && category && category.length <= 80)) && (gasto === null || gasto === 0 || gasto === 1);
  if (!valido) return json({ erro: "Dados inválidos" }, 400);
  // Merge-patch (RFC 7396): null remove a chave; campos gravados pelo app (ex.: nota) ficam. O painel sempre vence.
  const ts = agora();
  await env.DB.prepare(
    "INSERT INTO registros (tabela, id, dados, updated_at, deleted_at, server_at) VALUES ('ajustes', ?1, json_patch('{}', ?2), ?3, NULL, ?3) " +
      "ON CONFLICT(tabela, id) DO UPDATE SET dados = json_patch(COALESCE(registros.dados, '{}'), ?2), updated_at = ?3, deleted_at = NULL, server_at = ?3"
  ).bind(id, JSON.stringify({ category, gasto }), ts).run();
  return json({ ok: true });
}

// ---------- Ciclo, limite e alertas ----------

async function lerConfig(db) {
  const { results } = await db.prepare("SELECT chave, valor FROM config").all();
  return configDe(results);
}

// Base do ciclo e dos alertas: 200 dias de transações (6 meses de média + ciclo atual) e todas as parcelas futuras.
async function baseCiclo(env) {
  const hoje = hojeSP();
  const [tx, contas, lido] = await Promise.all([
    env.DB.prepare(`SELECT ${COLUNAS_TX} ${deTx(env)} WHERE t.date >= ?1`).bind(somarDias(hoje, -200)).all(),
    env.DB.prepare("SELECT id, type, subtype, name, bank, balance, closing_date, due_date FROM accounts").all(),
    // Com o espelho ligado, configurações, ajustes, revisões, metas e o resto vêm só do espelho (registrosDoEspelho).
    espelhoLigado(env) ? registrosDoEspelho(env.DB) : Promise.all([
      lerConfig(env.DB),
      env.DB.prepare("SELECT tabela, id, dados FROM registros WHERE deleted_at IS NULL AND tabela IN ('categorias','regras','orcamentos','ajustes','assinaturas','revisoes','metas')").all(),
    ]).then(([config, regs]) => ({ config, registros: regs.results.flatMap((r) => { try { return [{ tabela: r.tabela, id: r.id, dados: JSON.parse(r.dados), deleted_at: null }]; } catch { return []; } }) })),
  ]);
  const { config, registros } = lido;
  // Conta e cartão do Santander ficam fora de tudo que sai daqui (ciclo, alertas, resumo semanal, "disponível").
  const [semIgnorar, contasUsadas] = semIgnoradas(tx.results, contas.results);
  // As respostas da fila "Para revisar" mexem no que conta como gasto e no que pode ser salário antes de qualquer cálculo.
  // O início do ciclo não depende dos envios ao Santander: 1ª passada acha o ciclo, 2ª limita a reclassificação a ele.
  const revisoes = lerRevisoes(registros);
  const cartoes = new Set(contasUsadas.filter((c) => c.type === "CREDIT").map((c) => c.id));
  const { inicio } = resumoCiclo({ transacoes: aplicarRevisoes(semIgnorar, revisoes, { cartoes }), contas: contasUsadas, config, hoje });
  const transacoes = aplicarRevisoes(semIgnorar, revisoes, { cartoes, inicio });
  const resumo = resumoCiclo({ transacoes, contas: contasUsadas, config, hoje });
  return { hoje, transacoes, contas: contasUsadas, config, registros, ctx: contextoDeRegistros(registros), resumo, revisar: filaRevisar({ transacoes, contas: contasUsadas, config, resumo, hoje }) };
}

async function ciclo(env) {
  const [b, notif] = await Promise.all([
    baseCiclo(env),
    env.DB.prepare("SELECT chave, titulo, corpo, criada FROM notificacoes ORDER BY criada DESC LIMIT 20").all(),
  ]);
  return json({ ciclo: { ...b.resumo, salario: b.config.salario }, notificacoes: notif.results, push: { publica: env.VAPID_PUBLICA || null } });
}

async function salvarConfig(request, env, url, ctx) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const corpo = await request.json().catch(() => null);
  if (!corpo || typeof corpo !== "object") return json({ erro: "JSON inválido" }, 400);
  const ops = [];
  const novas = {}; // chave -> valor novo (null apaga): com ESPELHO = 1 também vai para `_config`, que vence a tabela `config`
  if ("limite" in corpo) {
    const v = corpo.limite;
    if (v === null) { ops.push(env.DB.prepare("DELETE FROM config WHERE chave = 'limite'")); novas.limite = null; }
    else if (typeof v === "number" && v > 0 && v <= 1e6) { ops.push(env.DB.prepare("INSERT OR REPLACE INTO config (chave, valor) VALUES ('limite', ?1)").bind(String(v))); novas.limite = v; }
    else return json({ erro: "Limite deve ser um valor entre R$ 0,01 e R$ 1.000.000" }, 400);
  }
  if ("salario_id" in corpo) {
    const t = await env.DB.prepare("SELECT t.description, t.amount, a.type FROM transactions t JOIN accounts a ON a.id = t.account_id WHERE t.id = ?1").bind(String(corpo.salario_id)).first();
    if (!t) return json({ erro: "Transação não encontrada" }, 404);
    if (t.type === "CREDIT" || !(t.amount > 0) || !normalizar(t.description)) return json({ erro: "Escolha um crédito da conta corrente" }, 400);
    ops.push(env.DB.prepare("INSERT OR REPLACE INTO config (chave, valor) VALUES ('salario', ?1)").bind(normalizar(t.description)));
    ops.push(env.DB.prepare("INSERT OR REPLACE INTO config (chave, valor) VALUES ('salario_valor', ?1)").bind(String(t.amount)));
    novas.salario = normalizar(t.description);
    novas.salario_valor = t.amount;
  }
  if (!ops.length) return json({ erro: "Nada para salvar" }, 400);
  await env.DB.batch(ops);
  if (espelhoLigado(env)) {
    const ts = agora();
    const linhas = Object.entries(novas).map(([pk, v]) => ({ tabela: "_config", pk, dados: v === null ? null : { v }, updated_at: ts, deleted_at: v === null ? ts : null }));
    const r = await enviarEspelho(env.DB, { linhas }, ts, "web");
    if (r.gravadas) ctx.waitUntil(avisar(env, { tipo: "mudou", cursor: r.cursor, aparelho: "web" }).catch((e) => console.error("Aviso do espelho falhou", e?.stack || e)));
  }
  return json({ ok: true });
}

async function inscreverPush(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const endpoint = (await request.json().catch(() => null))?.endpoint;
  const permitido = /^https:\/\//.test(endpoint || "") || (env.PUSH_HTTP_LOCAL === "1" && /^http:\/\/localhost[:/]/.test(endpoint || ""));
  if (!permitido || endpoint.length > 1000) return json({ erro: "Endpoint inválido" }, 400);
  if (request.method === "DELETE") await env.DB.prepare("DELETE FROM push_inscricoes WHERE endpoint = ?1").bind(endpoint).run();
  else await env.DB.prepare("INSERT OR REPLACE INTO push_inscricoes (endpoint, criada) VALUES (?1, ?2)").bind(endpoint, agora()).run();
  return json({ ok: true });
}

const validadeAlerta = () => new Date(Date.now() - VALIDADE_ALERTA_MS).toISOString();

// Um push (sem conteúdo) por inscrição quando há alerta não enviado. Respeita o silêncio das 22h às 7h.
async function enviarPendentes(env, ignorarSilencio = false) {
  if (!env.VAPID_PRIVADA || (!ignorarSilencio && emSilencio(new Date()))) return 0;
  const pend = await env.DB.prepare("SELECT COUNT(*) n FROM notificacoes WHERE enviada_em IS NULL AND criada > ?1").bind(validadeAlerta()).first();
  if (!pend.n) return 0;
  const { results } = await env.DB.prepare("SELECT endpoint FROM push_inscricoes").all();
  let enviados = 0;
  for (const { endpoint } of results) {
    const status = await enviarPush(endpoint, env).catch((e) => (console.error("push", e.message), 0));
    if (status === 404 || status === 410) await env.DB.prepare("DELETE FROM push_inscricoes WHERE endpoint = ?1").bind(endpoint).run();
    else if (status >= 200 && status < 300) enviados++;
  }
  if (enviados) await env.DB.prepare("UPDATE notificacoes SET enviada_em = ?1 WHERE enviada_em IS NULL").bind(agora()).run();
  return enviados;
}

const lerSnapshot = async (db, key, vazio) => {
  try { return JSON.parse((await db.prepare("SELECT data FROM snapshots WHERE key = ?1").bind(key).first("data")) ?? "null") ?? vazio; } catch { return vazio; }
};

// Avalia o que mudou desde a última sincronização. Alertas e snapshots de controle saem no mesmo batch: ou grava tudo ou nada,
// então uma compra não é avisada duas vezes nem se perde.
async function avaliarAlertas(env) {
  const db = env.DB;
  const b = await baseCiclo(env);
  const [avisos, vistas, avisadas, conexoes] = await Promise.all([lerSnapshot(db, "avisos", []), lerSnapshot(db, "compras_vistas", null), lerSnapshot(db, "conexoes_avisadas", []),
    db.prepare("SELECT id, conector, consentimento_expira FROM pluggy_items WHERE removido IS NULL AND consentimento_expira IS NOT NULL").all().then((r) => r.results)]);
  const emprestimos = (await db.prepare("SELECT data FROM snapshots WHERE key LIKE 'emprestimos:%'").all()).results
    .flatMap((s) => { try { return JSON.parse(s.data) || []; } catch { return []; } });
  const ts = agora();
  const geral = consumoGeral(b);
  const { novas, ids } = comprasNovas({ ...b, vistas });
  const alertas = [
    ...alertasConexao({ avisos, avisadas, agora: ts }),
    ...alertasGeral(geral),
    ...alertaCompras({ compras: novas, contas: b.contas, geral, agora: ts }),
    ...alertasFatura(b),
    ...alertasCredito(b),
    ...alertasConsentimento({ conexoes, hoje: b.hoje }),
    ...alertasEmprestimos({ emprestimos }),
    ...alertasRevisao(b),
  ];
  await db.batch([...stmtAlertas(db, alertas), stmtSnapshot(db, "compras_vistas", ids), stmtSnapshot(db, "conexoes_avisadas", avisos.map((a) => a.item_id))]);
  await enviarPendentes(env);
}

async function alertaSemanal(env) {
  const b = await baseCiclo(env);
  const conexoes = await idsConexoes(env.DB, env, agora());
  const { results } = await env.DB.prepare("SELECT key, data FROM snapshots WHERE key LIKE 'investimentos:%'").all();
  const saldos = new Map(results.filter((r) => conexoes.includes(r.key.slice("investimentos:".length))).flatMap((r) => JSON.parse(r.data) || []).map((i) => [i.id, i.saldo]));
  const metas = linhasMetas({ metas: doTipo(b.registros, "metas"), saldos, hoje: b.hoje });
  await gravarAlertas(env.DB, [resumoSemanal({ ...b, geral: consumoGeral(b), metas })]);
  await enviarPendentes(env);
}

async function testePush(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  await gravarAlertas(env.DB, [{ chave: "teste:" + agora(), titulo: "Teste do RenanCash", corpo: "As notificações estão funcionando." }]);
  return json({ ok: true, enviados: await enviarPendentes(env, true) });
}

async function entregarNotificacoes(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const { results } = await env.DB.prepare(
    "UPDATE notificacoes SET entregue_em = ?1 WHERE chave IN (SELECT chave FROM notificacoes WHERE enviada_em IS NOT NULL AND entregue_em IS NULL AND criada > ?2 ORDER BY criada DESC LIMIT 20) RETURNING chave, titulo, corpo"
  ).bind(agora(), validadeAlerta()).all();
  return json({ notificacoes: results });
}

// ---------- App Android (token de aparelho) ----------

// Rotas dos apps: token de aparelho (Bearer) ou sessão do painel (cookie; POST exige mesma origem).
const ROTAS_APARELHO = new Set(["/api/config", "/api/sync", "/api/notificacoes", "/api/sync/atualizar", "/api/pluggy/connect-token", "/api/pluggy/items", "/api/ia/sugerir", "/api/ia/entender"]);
const MAX_CORPO_IA = 64 * 1024; // contexto + lote pequeno cabem com folga
const ROTAS_ESPELHO = new Set(["/api/espelho", "/api/espelho/semear", "/api/espelho/ws"]);
const ROTA_CONEXAO = /^\/api\/pluggy\/items\/[^/]+$/; // DELETE de uma conexão

// Token de aparelho (aparelho = id do token) ou sessão do painel (aparelho = null); cookie em POST exige mesma origem.
async function identificar(request, env, url, ts) {
  const aparelho = await autenticarAparelho(request, env.DB, ts);
  if (aparelho) return { aparelho };
  if (!(await sessaoValida(request, env))) return { erro: json({ erro: "Token ou sessão necessários" }, 401, { "www-authenticate": "Bearer" }) };
  if (request.method !== "GET" && !mesmaOrigem(request, url)) return { erro: json({ erro: "Origem não permitida" }, 403) };
  return { aparelho: null };
}

// Espelho completo (atrás da flag ESPELHO). O semeio só vale com token de aparelho; o WebSocket do navegador (cookie) exige Origin igual.
// A identidade do aparelho (desempate do LWW, `mudou`) é o id do token; a sessão do painel é "web".
async function rotaEspelho(request, env, url, caminho, ctx) {
  const quem = await identificar(request, env, url, agora());
  if (quem.erro) return quem.erro;
  const aparelho = quem.aparelho ?? "web";
  const rota = `${request.method} ${caminho}`;
  const avisarClientes = (aviso) => ctx.waitUntil(avisar(env, aviso).catch((e) => console.error("Aviso do espelho falhou", e?.stack || e)));
  if (rota === "GET /api/espelho/ws") {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return json({ erro: "Upgrade de WebSocket necessário" }, 426);
    if (!quem.aparelho && request.headers.get("origin") !== url.origin) return json({ erro: "Origem não permitida" }, 403);
    return hubDo(env).fetch(request);
  }
  if (rota === "GET /api/espelho") {
    const r = await puxarEspelho(env.DB, url.searchParams.get("desde"), url.searchParams.get("limite"), aparelho);
    return json(r.corpo, r.status);
  }
  if (rota === "POST /api/espelho") {
    const r = await enviarEspelho(env.DB, await request.json().catch(() => null), agora(), aparelho);
    if (r.gravadas) avisarClientes({ tipo: "mudou", cursor: r.cursor, aparelho }); // o cursor é só uma dica: o cliente puxa pelo próprio
    return json(r.corpo, r.status);
  }
  if (rota === "POST /api/espelho/semear") {
    if (!quem.aparelho) return json({ erro: "O semeio só vale com o token do aparelho" }, 403);
    const r = await semear(env.DB, await request.json().catch(() => null), agora(), aparelho);
    if (r.fim) avisarClientes({ tipo: "mudou", cursor: r.corpo.cursor, aparelho });
    return json(r.corpo, r.status);
  }
  return json({ erro: "Método não permitido" }, 405);
}

async function rotaAparelho(request, env, url, caminho, ctx) {
  const ts = agora();
  const quem = await identificar(request, env, url, ts);
  if (quem.erro) return quem.erro;
  const rota = `${request.method} ${caminho}`;
  if (rota === "GET /api/sync") {
    const desde = normalizarDesde(url.searchParams.get("desde"));
    if (desde === undefined) return json({ erro: "Parâmetro desde inválido (use data ISO)" }, 400);
    const b = await baseCiclo(env);
    return json(await puxar(env.DB, desde, ts, { ciclo: { ...b.resumo, salario: b.config.salario ?? null, por_dia: gastoPorDia(b.transacoes, b.contas, b.resumo.inicio, b.resumo.fim), revisar: b.revisar } }));
  }
  if (rota === "PUT /api/config") return salvarConfig(request, env, url, ctx); // app marca o salário da fila "Para revisar"
  if (rota === "GET /api/notificacoes") {
    const desde = normalizarDesde(url.searchParams.get("desde"));
    if (desde === undefined) return json({ erro: "Parâmetro desde inválido (use data ISO)" }, 400);
    return json(await notificacoesAparelho(env, desde, ts));
  }
  if (rota === "POST /api/sync") {
    const r = await enviar(env.DB, await request.json().catch(() => null), ts);
    return json(r.corpo, r.status);
  }
  if (rota === "POST /api/sync/atualizar") return atualizarAgora(env, "app", ctx);
  if (rota === "POST /api/ia/sugerir" || rota === "POST /api/ia/entender") {
    const texto = await request.text();
    if (texto.length > MAX_CORPO_IA) return json({ erro: "Pedido grande demais" }, 413);
    let corpo = null;
    try {
      corpo = JSON.parse(texto);
    } catch {}
    return json(await (rota === "POST /api/ia/sugerir" ? sugerir : entender)(env, corpo));
  }
  if (rota === "POST /api/pluggy/connect-token") {
    const itemId = (await request.json().catch(() => null))?.itemId ?? null;
    if (itemId !== null && !(typeof itemId === "string" && REGEX_ITEM.test(itemId))) return json({ erro: "itemId inválido" }, 400);
    if (itemId && !(await idsConexoes(env.DB, env, ts)).includes(itemId)) {
      return json({ erro: "Conexão não encontrada" }, 404);
    }
    return json({ accessToken: await new ApiCliente(env).connectToken(itemId) });
  }
  if (rota === "GET /api/pluggy/items") return json({ conexoes: await listarConexoes(env.DB, env, ts) });
  if (request.method === "DELETE" && ROTA_CONEXAO.test(caminho)) {
    const itemId = caminho.slice("/api/pluggy/items/".length);
    if (!REGEX_ITEM.test(itemId)) return json({ erro: "itemId inválido" }, 400);
    if (!(await idsConexoes(env.DB, env, ts)).includes(itemId)) {
      const jaRemovido = await env.DB.prepare("SELECT 1 AS r FROM pluggy_items WHERE id = ?1 AND removido IS NOT NULL").bind(itemId).first("r");
      return jaRemovido ? json({ ok: true }) : json({ erro: "Conexão não encontrada" }, 404);
    }
    try {
      await new ApiCliente(env).removerItem(itemId);
    } catch (e) {
      if (e.status !== 404) return json({ erro: e.message }, 502); // já sumiu no Pluggy: segue e limpa aqui
    }
    await esquecerItem(env.DB, itemId, ts);
    return json({ ok: true });
  }
  if (rota === "POST /api/pluggy/items") {
    const itemId = (await request.json().catch(() => null))?.itemId;
    if (!(typeof itemId === "string" && REGEX_ITEM.test(itemId))) return json({ erro: "itemId inválido" }, 400);
    await adicionarItem(env, itemId, ts);
    ctx.waitUntil(sincronizar(env, "app").catch((e) => console.error("Sincronização após conectar", e?.stack || e)));
    return json({ ok: true }, 201);
  }
  return json({ erro: "Método não permitido" }, 405);
}

// Notificações para o app: só leitura (enviada_em e entregue_em são do Web Push). Em silêncio (22h–7h) o cursor não anda.
async function notificacoesAparelho(env, desde, ts) {
  const b = await baseCiclo(env);
  const sinc = await env.DB.prepare("SELECT MAX(finished_at) AS f FROM sync_log WHERE ok = 1").first("f");
  const disponivel = Math.round(b.contas.filter((c) => c.type === "BANK").reduce((s, c) => s + (c.balance || 0), 0) * 100) / 100;
  const { consumido, limite, percentual, inicio, fim } = b.resumo;
  const resumo = { disponivel, consumido, limite, percentual, inicio, fim, sincronizado_em: sinc ?? null };
  if (desde === null) return { cursor: ts, notificacoes: [], resumo };
  if (emSilencio(new Date(ts))) return { cursor: desde, notificacoes: [], resumo };
  const piso = desde > validadeAlerta() ? desde : validadeAlerta();
  const { results } = await env.DB.prepare("SELECT chave, titulo, corpo, criada FROM notificacoes WHERE criada > ?1 ORDER BY criada LIMIT 20").bind(piso).all();
  // "Para revisar": leva o item (o app mostra os botões das opções) e some com o aviso de item já respondido em outro aparelho.
  const fila = new Map(b.revisar.map((i) => [i.tipo === "salario_nao_detectado" ? "salario" : i.id, i]));
  const notificacoes = results.flatMap((n) => {
    if (!n.chave.startsWith("revisar:")) return [n];
    const k = n.chave.startsWith("revisar:salario:") ? "salario" : n.chave.slice("revisar:".length);
    const item = fila.get(k);
    return !item ? [] : k === "salario" ? [n] : [{ ...n, item }];
  });
  return { cursor: results.at(-1)?.criada ?? desde, notificacoes, resumo };
}

// Webhook do Pluggy: responde na hora (o Pluggy espera 2xx em poucos segundos) e trabalha em waitUntil.
// Se outra sincronização estiver rodando, a trava do sync_log descarta esta; o cron cobre o que faltar.
async function webhookPluggy(request, env, url, ctx) {
  if (!(await webhookValido(request, url, env))) return json({ erro: "Não autorizado" }, 401);
  const ev = await request.json().catch(() => null);
  const acao = acaoWebhook(ev);
  if (acao) {
    const ts = agora();
    const tarefa = acao === "apagar"
      ? apagarTransacoes(env.DB, idsRemovidos(ev), ts)
      : acao === "remover"
      ? esquecerItem(env.DB, ev.itemId, ts)
      : (acao === "registrar" ? adicionarItem(env, ev.itemId, ts) : Promise.resolve()).then(() => sincronizar(env, "webhook"));
    ctx.waitUntil(tarefa.catch((e) => console.error("Webhook do Pluggy", ev.event, e?.stack || e)));
  }
  return json({ ok: true });
}

// A 1ª linha em pluggy_items desliga o secret e a descoberta via /v2/items: antes de gravá-la, copia as conexões que já
// existem, senão só a nova seria sincronizada.
async function adicionarItem(env, id, ts) {
  const db = env.DB;
  if (!(await idsConexoes(db, env, ts)).length && !(await db.prepare("SELECT count(*) AS n FROM pluggy_items").first("n"))) {
    try {
      for (const existente of await new ApiCliente(env).listarIds()) await registrarItem(db, existente, ts);
    } catch (e) {
      console.warn("Descoberta das conexões antes de registrar", e?.message || e); // sem /v2/items: fica só a nova
    }
  }
  await registrarItem(db, id, ts);
}

const horaSP = (ms) => new Intl.DateTimeFormat("pt-BR", { timeZone: TZ, hour: "2-digit", minute: "2-digit" }).format(new Date(ms));

// Botão Atualizar (painel e apps): no máximo 1 a cada 5 min. Pede ao banco dados novos (PATCH no item) e lê o que o
// Pluggy já tem; quando o banco terminar, o webhook item/updated faz a leitura final.
async function atualizarAgora(env, origem, ctx) {
  const db = env.DB;
  // Com outra sincronização em andamento, sincronizar() recusaria sem gravar no sync_log: nem pede ao banco nem libera o limite.
  const { ultimo, ocupado } = await db.prepare(
    "SELECT MAX(CASE WHEN origem IN ('botao', 'app') THEN started_at END) AS ultimo, MAX(ok IS NULL AND started_at > ?1) AS ocupado FROM sync_log"
  ).bind(new Date(Date.now() - TRAVA_MS).toISOString()).first();
  if (ocupado) return json({ ok: false, mensagem: MSG_OCUPADO });
  const espera = esperaAtualizar(ultimo, Date.now());
  if (espera > 0) {
    const liberado = Date.now() + espera;
    const mensagem = `Atualizado há pouco. Tente de novo às ${horaSP(liberado)}.`;
    return json({ ok: false, erro: mensagem, mensagem, liberado_em: new Date(liberado).toISOString() }, 429);
  }
  const tarefa = (async () => {
    const api = await clientePluggy(db, env, agora());
    const ids = await api.listarIds().catch(() => []); // falha de credencial ou descoberta aparece na sincronização abaixo
    const pedidos = await Promise.allSettled(ids.map((id) => api.atualizarItem(id)));
    const falhas = pedidos.flatMap((p, i) => (p.status === "rejected" ? [`Conexão ${ids[i]}: ${p.reason?.message || p.reason}`] : []));
    for (const f of falhas) console.warn("Atualizar no banco falhou", f);
    return { ...(await sincronizar(env, origem)), pedidos: ids.length - falhas.length, falhas };
  })();
  // O erro já chega ao cliente por `await tarefa`; o catch só evita rejeição não tratada quando o cliente desconecta e a tarefa segue.
  ctx.waitUntil(tarefa.catch(() => {}));
  return json(await tarefa);
}

async function listarTokens(env) {
  const { results } = await env.DB.prepare("SELECT id, nome, criado, ultimo_uso, revogado FROM app_tokens ORDER BY criado DESC").all();
  return json({ tokens: results });
}

async function criarToken(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const novo = await inserirToken(env, (await request.json().catch(() => null))?.nome);
  if (!novo) return json({ erro: "Informe um nome de 1 a 40 caracteres" }, 400);
  const link = `meubanco://parear?u=${encodeURIComponent(url.origin)}&t=${novo.token}`;
  return json({ ...novo, link, qr: renderSVG(link, { border: 2 }) }, 201);
}

async function inserirToken(env, nome) {
  const limpo = typeof nome === "string" ? nome.trim() : "";
  if (!limpo || limpo.length > 40) return null;
  const token = gerarToken();
  const id = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO app_tokens (id, nome, hash, criado) VALUES (?1, ?2, ?3, ?4)").bind(id, limpo, await hashToken(token), agora()).run();
  return { id, nome: limpo, token };
}

async function revogarToken(request, env, url, idUrl) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const id = decodificar(idUrl);
  const t = await env.DB.prepare("SELECT revogado FROM app_tokens WHERE id = ?1").bind(id).first();
  if (!t) return json({ erro: "Token não encontrado" }, 404);
  if (!t.revogado) await env.DB.prepare("UPDATE app_tokens SET revogado = ?1 WHERE id = ?2").bind(agora(), id).run();
  return json({ ok: true });
}

// Dados para o app: só leitura, autenticado por Bearer. `agora` vira o próximo `desde`. Limite conhecido: uma
// sincronização em andamento grava com o `ts` do início (< agora) e essas linhas podem escapar do filtro; a releitura de
// DIAS_REIMPORTAR dias a cada sincronização as traz de volta na rodada seguinte.
async function appTransacoes(request, env, url) {
  const agoraIso = agora();
  if (!(await autenticarAparelho(request, env.DB, agoraIso))) return json({ erro: "Token inválido" }, 401, { "www-authenticate": "Bearer" });
  const desde = normalizarDesde(url.searchParams.get("desde"));
  if (desde === undefined) return json({ erro: "Parâmetro desde inválido (use data ISO)" }, 400);
  const db = env.DB;
  const [contas, tx, pend] = await db.batch([
    db.prepare("SELECT id, type, name, bank, balance, credit_limit, available_limit, due_date FROM accounts ORDER BY type, name"),
    db.prepare(`SELECT ${COLUNAS_TX} ${deTx(env)} WHERE ?1 IS NULL OR t.updated_at > ?1 OR a.updated_at > ?1 ORDER BY t.date, t.id`).bind(desde),
    db.prepare("SELECT id FROM transactions WHERE status = 'PENDING' ORDER BY id"),
  ]);
  return json(montarResposta({ agora: agoraIso, contas: contas.results, transacoes: tx.results, pendentes: pend.results }));
}

// ---------- Sincronização ----------

// D1 nunca semeado (sem secret): mantém a descoberta via /v2/items; com linhas, o D1 manda (lista vazia = nada a sincronizar).
async function clientePluggy(db, env, ts) {
  const conexoes = await idsConexoes(db, env, ts);
  const semeado = conexoes.length || (await db.prepare("SELECT count(*) AS n FROM pluggy_items").first("n"));
  return new ApiCliente(env, semeado ? conexoes : undefined);
}

async function sincronizar(env, origem) {
  const db = env.DB;

  // Evita duas sincronizações ao mesmo tempo (cron + botão): checagem e registro num comando só (atômico no D1).
  const limite = new Date(Date.now() - TRAVA_MS).toISOString();
  const log = await db
    .prepare(
      "INSERT INTO sync_log (origem, started_at) SELECT ?1, ?2 WHERE NOT EXISTS (SELECT 1 FROM sync_log WHERE ok IS NULL AND started_at > ?3) RETURNING id"
    )
    .bind(origem, agora(), limite)
    .first();
  if (!log) return { ok: false, mensagem: MSG_OCUPADO };
  const avisos = [];
  let ok = 1;

  try {
    const ts = agora();
    const api = await clientePluggy(db, env, ts);

    // 1) Conexões (items do Meu Pluggy) e contas de cada uma. Uma conexão com erro vira aviso; as demais seguem.
    const ids = await api.listarIds();
    const linhasContas = [];
    const brutas = new Map(); // id da conta → conta do Pluggy (faturas)
    const reconectar = [];
    const lidas = new Set(); // conexões cujos investimentos foram lidos com sucesso nesta rodada
    const titulares = new Map(); // conexão → CPF/CNPJ do titular (só em memória, para `entre_minhas`)
    for (const id of ids) {
      try {
        const [item, contas] = await Promise.all([api.item(id), api.contas(id)]);
        await atualizarStatus(db, { ...item, id }, ts);
        const banco = bancoDoItem(item);
        const aviso = avisoItem(item, banco);
        if (aviso) reconectar.push(aviso);
        const daConexao = contas.map((c) => mapearConta(c, banco, id, ts));
        for (const c of contas) brutas.set(String(c.id), c);
        linhasContas.push(...daConexao);
        // Empréstimos: 403/404 = produto não liberado na conexão (fica sem); outro erro mantém o snapshot anterior.
        try {
          await salvarSnapshot(db, "emprestimos:" + id, mapearEmprestimos(await api.emprestimos(id), banco ?? daConexao.find((c) => c.type === "BANK")?.name?.replace(/\s*[·#].*$/, "")));
        } catch (e) {
          if (![403, 404].includes(e.status)) console.warn("Empréstimos indisponíveis", id, e.message);
        }
        // Sem o produto identidade (403/404) ou com erro, a transação só fica sem `entre_minhas`.
        titulares.set(id, await api.documentoTitular(id).catch(() => null));
        // Erro nos investimentos mantém o snapshot anterior; 403/404 (produto não liberado na conexão) não vira aviso.
        try {
          const invs = await api.investimentos(id);
          await salvarSnapshot(db, "investimentos:" + id, mapearInvestimentos(invs, banco, daConexao, await aplicadoDasMovimentacoes(api, invs)));
          lidas.add(id);
        } catch (e) {
          if (![403, 404].includes(e.status)) avisos.push(`Investimentos da conexão ${id}: ${e.message}`);
          console.warn("Investimentos indisponíveis", id, e.message);
        }
      } catch (e) {
        avisos.push(`Conexão ${id}: ${e.message}`);
        console.error("Erro conexão", id, e.message);
      }
    }
    if (!avisos.length) await salvarSnapshot(db, "avisos", reconectar); // conexão que falhou na leitura mantém os avisos anteriores
    await registrarHistoricoInvestimentos(db, ids, lidas);
    desambiguar(linhasContas);
    if (!linhasContas.length) throw new Error("Nenhuma conta encontrada nas conexões do Pluggy");
    await db.prepare(upsertSql("accounts", Object.keys(linhasContas[0]))).bind(JSON.stringify(linhasContas)).run();

    // 4) Transações e 5) faturas, conta por conta
    const hoje = hojeSP();
    const diasImport = parseInt(env.IMPORT_DAYS, 10) || 180;
    for (const conta of linhasContas) {
      try {
        const n = await sincronizarConta(db, api, conta, hoje, diasImport, titulares.get(conta.item_id));
        console.log(`Conta ${conta.name}: ${n} transações`);
      } catch (e) {
        avisos.push(`Transações de ${conta.name}: ${e.message}`);
        console.error("Erro transações", conta.id, e.message);
      }
      if (conta.type === "CREDIT") {
        try {
          // Sem a lista de faturas (ex.: conta sem acesso a /bills) o painel ainda mostra a fatura aberta.
          const bills = await api.faturas(conta.id).catch((e) => { console.warn("Faturas indisponíveis", conta.id, e.message); return []; });
          await salvarSnapshot(db, "faturas:" + conta.id, mapearFaturas(brutas.get(conta.id), bills));
        } catch (e) {
          avisos.push(`Faturas de ${conta.name}: ${e.message}`);
          console.error("Erro faturas", conta.id, e.message);
        }
      }
    }
  } catch (e) {
    ok = 0;
    avisos.unshift(e.message);
    console.error("Sincronização falhou", e?.stack || e);
  }

  await limparRemovidas(db).catch((e) => console.error("Limpeza das conexões removidas", e?.stack || e));
  const mensagem = avisos.join(" | ").slice(0, 2000) || "OK";
  await db
    .prepare("UPDATE sync_log SET finished_at = ?1, ok = ?2, message = ?3 WHERE id = ?4")
    .bind(agora(), ok, mensagem, log.id)
    .run();
  if (ok) await avaliarAlertas(env).catch((e) => console.error("Alertas falharam", e?.stack || e));
  if (ok && espelhoLigado(env)) await avisar(env, { tipo: "banco" }).catch((e) => console.error("Aviso do espelho falhou", e?.stack || e));
  return { ok: !!ok, mensagem };
}

async function sincronizarConta(db, api, conta, hoje, diasImport, docTitular) {
  const ultima = await db
    .prepare(
      "SELECT MAX(CASE WHEN scheduled = 0 AND date <= ?2 THEN date END) AS d, MIN(CASE WHEN status = 'PENDING' AND scheduled = 0 THEN date END) AS p FROM transactions WHERE account_id = ?1"
    )
    .bind(conta.id, hoje)
    .first();
  let de = ultima?.d ? somarDias(ultima.d, -DIAS_REIMPORTAR) : somarDias(hoje, -diasImport);
  if (ultima?.p && ultima.p < de) de = ultima.p; // relê pendentes antigas para não duplicarem quando forem postadas
  // Cartão sem "to" para trazer parcelas futuras.
  const todas = await api.transacoes(conta.id, de, conta.type === "CREDIT" ? undefined : hoje, MAX_PAGINAS);
  const ts = agora();
  const linhas = todas.map((t) => mapearTransacao(t, conta, hoje, ts, docTitular));

  // Apaga parcelas futuras e pendentes da janela (podem mudar de id) e regrava tudo num lote atômico.
  const comandos = [
    db.prepare("DELETE FROM transactions WHERE account_id = ?1 AND (scheduled = 1 OR (status = 'PENDING' AND date >= ?2))").bind(conta.id, de),
  ];
  if (linhas.length) {
    const sql = upsertSql("transactions", Object.keys(linhas[0]));
    for (let i = 0; i < linhas.length; i += LINHAS_POR_INSERT) {
      comandos.push(db.prepare(sql).bind(JSON.stringify(linhas.slice(i, i + LINHAS_POR_INSERT))));
    }
  }
  await db.batch(comandos);
  return linhas.length;
}

// INSERT ... SELECT FROM json_each(?1): muitas linhas com 1 só parâmetro (D1 limita 100 parâmetros por comando).
// O "WHERE true" é obrigatório: sem ele o SQLite lê o ON CONFLICT como cláusula de JOIN.
function upsertSql(tabela, colunas) {
  const sel = colunas.map((c) => `json_extract(value, '$.${c}')`).join(", ");
  const upd = colunas.filter((c) => c !== "id").map((c) => `${c} = excluded.${c}`).join(", ");
  return `INSERT INTO ${tabela} (${colunas.join(", ")}) SELECT ${sel} FROM json_each(?1) WHERE true ON CONFLICT(id) DO UPDATE SET ${upd}`;
}

// Para os investimentos sem amountOriginal, o aplicado vem das movimentações (no máximo MAX_MOVIMENTOS consultas por
// conexão). Falha numa consulta só deixa aquele investimento sem aplicado.
const MAX_MOVIMENTOS = 20;
async function aplicadoDasMovimentacoes(api, invs) {
  const out = new Map();
  for (const i of semAplicado(invs).slice(0, MAX_MOVIMENTOS)) {
    try {
      const v = aplicadoPelasMovimentacoes(await api.movimentosInvestimento(i.id));
      if (v != null) out.set(String(i.id), v);
    } catch (e) {
      console.warn("Movimentações do investimento indisponíveis", i.id, e.message);
    }
  }
  return out;
}

// Retrato do mês corrente a partir dos snapshots de investimentos (Inter e Santander juntos). Nunca derruba a sincronização.
// Só grava se todas as conexões com snapshot foram lidas agora (leitura falha deixaria saldo velho no mês novo); lista vazia
// vale (resgate total). Snapshots de conexões removidas (fora de `ids`) são ignorados.
async function registrarHistoricoInvestimentos(db, ids, lidas) {
  try {
    const { results } = await db.prepare("SELECT key, data FROM snapshots WHERE key LIKE 'investimentos:%' OR key = ?1").bind(CHAVE_HISTORICO).all();
    const historico = results.find((s) => s.key === CHAVE_HISTORICO);
    const atuais = results.filter((s) => s.key !== CHAVE_HISTORICO && ids.includes(s.key.slice("investimentos:".length)));
    if (!atuais.length || atuais.some((s) => !lidas.has(s.key.slice("investimentos:".length)))) return;
    const lista = atuais.flatMap((s) => {
      const v = JSON.parse(s.data);
      return Array.isArray(v) ? v : [];
    });
    await salvarSnapshot(db, CHAVE_HISTORICO, registrarRetrato(historico ? JSON.parse(historico.data) : {}, lista, mesSP()));
  } catch (e) {
    console.warn("Histórico de investimentos não gravado", e.message);
  }
}

const stmtSnapshot = (db, key, data) => db
  .prepare("INSERT INTO snapshots (key, data, updated_at) VALUES (?1, ?2, ?3) ON CONFLICT(key) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at")
  .bind(key, JSON.stringify(data ?? null), agora());
const salvarSnapshot = (db, key, data) => stmtSnapshot(db, key, data).run();
