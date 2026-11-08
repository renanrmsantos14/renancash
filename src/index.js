import { ApiCliente } from "./api.js";
import { resumoCiclo, normalizar } from "./ciclo.js";
import { gerarAlertas, resumoSemanal, emSilencio } from "./alertas.js";
import { enviarPush } from "./push.js";

const TZ = "America/Sao_Paulo";
const LINHAS_POR_INSERT = 400; // linhas por comando SQL (via json_each, 1 parâmetro só)
const TAM_PAGINA = 500; // máximo da API
const MAX_PAGINAS = 10; // limite de segurança (subrequests do plano grátis)
const PROBLEMA = /LOGIN_ERROR|WAITING_USER/; // status que pede novo login (OUTDATED = só falha temporária)
const DIAS_REIMPORTAR = 10; // relê os últimos dias para pegar lançamentos que o banco posta com atraso

export default {
  async fetch(request, env, ctx) {
    if (!env.APP_PASSWORD || !env.SESSION_SECRET) return seguranca(new Response("APP_PASSWORD ou SESSION_SECRET não configurado.", { status: 500 }));
    const url = new URL(request.url);
    const caminho = url.pathname;
    try {
      let resp;
      if (caminho === "/api/login" && request.method === "POST") resp = await entrar(request, env, url);
      else if (PUBLICO.test(caminho)) resp = await env.ASSETS.fetch(request);
      else if (!(await sessaoValida(request, env))) {
        resp = caminho.startsWith("/api/") ? json({ erro: "Sessão necessária" }, 401) : new Response(null, { status: 302, headers: { location: "/login" } });
      } else if (caminho === "/api/sair" && request.method === "POST") {
        resp = mesmaOrigem(request, url) ? json({ ok: true }, 200, { "set-cookie": cookie("", 0) }) : json({ erro: "Origem não permitida" }, 403);
      } else if (caminho === "/api/dados" && request.method === "GET") resp = await dados(env, url);
      else if (caminho === "/api/historico" && request.method === "GET") resp = await historico(env);
      else if (caminho === "/api/fatura" && request.method === "GET") resp = await fatura(env, url);
      else if (/^\/api\/ajustes\/[^/]+$/.test(caminho) && request.method === "PUT") {
        resp = mesmaOrigem(request, url) ? await salvarAjuste(request, env, caminho.slice(13)) : json({ erro: "Origem não permitida" }, 403);
      } else if (caminho === "/api/atualizar" && request.method === "POST") {
        if (!mesmaOrigem(request, url)) resp = json({ erro: "Origem não permitida" }, 403);
        else {
          // waitUntil: se o navegador fechar no meio, a sincronização termina e o sync_log é fechado.
          const tarefa = sincronizar(env, "botao");
          ctx.waitUntil(tarefa);
          resp = json(await tarefa);
        }
      } else if (caminho === "/api/ciclo" && request.method === "GET") resp = await ciclo(env);
      else if (caminho === "/api/config" && request.method === "PUT") resp = await salvarConfig(request, env, url);
      else if (caminho === "/api/push" && (request.method === "POST" || request.method === "DELETE")) resp = await inscreverPush(request, env, url);
      else if (caminho === "/api/push/teste" && request.method === "POST") resp = await testePush(request, env, url);
      else if (caminho === "/api/notificacoes/entregar" && request.method === "POST") resp = await entregarNotificacoes(request, env, url);
      else if (caminho === "/api/ferramentas" && request.method === "GET") {
        // Diagnóstico: testa a API key listando as conexões e mostra os endpoints disponíveis.
        const api = new ApiCliente(env);
        const [conexoes, endpoints] = await Promise.all([api.chamar("connections/list"), api.endpoints()]);
        resp = json({ conexoes, endpoints });
      } else if (caminho.startsWith("/api/")) resp = json({ erro: "Rota não encontrada" }, 404);
      else resp = await env.ASSETS.fetch(request);
      return seguranca(resp);
    } catch (e) {
      console.error("Erro na requisição", caminho, e?.stack || e);
      return seguranca(json({ erro: String(e?.message || e) }, 500));
    }
  },

  async scheduled(evento, env, ctx) {
    // Crons em UTC (BRT = UTC-3): "0 10 * * *" = 07h, fim do silêncio; "0 23 * * SUN" = domingo 20h, resumo.
    if (evento.cron === "0 10 * * *") ctx.waitUntil(enviarPendentes(env));
    else if (evento.cron === "0 23 * * SUN") ctx.waitUntil(alertaSemanal(env));
    else ctx.waitUntil(sincronizar(env, "cron"));
  },

};

// ---------- Segurança ----------

// Páginas e arquivos que o navegador precisa antes do login.
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
  const assinatura = new Uint8Array(await crypto.subtle.sign("HMAC", chave, new TextEncoder().encode(String(expira))));
  return btoa(String.fromCharCode(...assinatura)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const cookie = (valor, segundos) => `sessao=${valor}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${segundos}`;

async function sessaoValida(request, env) {
  const m = /(?:^|;\s*)sessao=(\d+)\.([\w-]+)/.exec(request.headers.get("cookie") || "");
  if (!m || Number(m[1]) < Date.now() / 1000) return false;
  return iguais(m[2], await assinar(m[1], env));
}

async function entrar(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  // Limite por IP (binding de rate limit): 5 tentativas por minuto, além da espera de 1 s por erro.
  const ip = request.headers.get("cf-connecting-ip") || "local";
  if (env.LIMITE_LOGIN && !(await env.LIMITE_LOGIN.limit({ key: ip })).success) {
    return json({ erro: "Muitas tentativas. Espere 1 minuto." }, 429);
  }
  const corpo = await request.json().catch(() => null);
  if (!(await iguais(typeof corpo?.senha === "string" ? corpo.senha : "", env.APP_PASSWORD))) {
    await new Promise((r) => setTimeout(r, 1000)); // freia tentativa em série
    return json({ erro: "Senha incorreta" }, 401);
  }
  const expira = Math.floor(Date.now() / 1000) + SESSAO_SEGUNDOS;
  return json({ ok: true }, 200, { "set-cookie": cookie(`${expira}.${await assinar(expira, env)}`, SESSAO_SEGUNDOS) });
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

function seguranca(resp) {
  const r = new Response(resp.body, resp);
  r.headers.set("x-content-type-options", "nosniff");
  r.headers.set("x-frame-options", "DENY");
  r.headers.set("referrer-policy", "no-referrer");
  r.headers.set("cache-control", "private, no-store");
  r.headers.set(
    "content-security-policy",
    "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; manifest-src 'self'; worker-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
  );
  return r;
}

function json(obj, status = 200, extra = {}) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json; charset=utf-8", ...extra } });
}

// ---------- Datas ----------

const agora = () => new Date().toISOString();
const hojeSP = () => new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(new Date());

function somarDias(isoData, dias) {
  const d = new Date(isoData + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + dias);
  return d.toISOString().slice(0, 10);
}

// ---------- API do painel ----------

// Transações já com o ajuste do painel (categoria e "gasto"), numa consulta só.
const COLUNAS_TX = "t.id, t.account_id, t.date, t.description, t.amount, t.type, t.status, t.category, t.merchant, t.scheduled, a.category AS ajuste_categoria, a.gasto AS ajuste_gasto";
const DE_TX = "FROM transactions t LEFT JOIN ajustes a ON a.transaction_id = t.id";

async function dados(env, url) {
  const db = env.DB;
  const mesParam = url.searchParams.get("mes");
  const mes = /^\d{4}-\d{2}$/.test(mesParam || "") ? mesParam : hojeSP().slice(0, 7);
  const [contas, transacoes, meses, snaps, ultimaOk, ultima] = await db.batch([
    db.prepare("SELECT * FROM accounts ORDER BY type, name"),
    db.prepare(`SELECT ${COLUNAS_TX} ${DE_TX} WHERE t.date >= ?1 AND t.date <= ?2 ORDER BY t.date DESC, t.id`).bind(mes + "-01", mes + "-31"),
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
    "SELECT t.id, t.account_id, t.date, t.description, t.amount, t.category, a.category AS ajuste_categoria, a.gasto AS ajuste_gasto FROM transactions t LEFT JOIN ajustes a ON a.transaction_id = t.id WHERE t.date >= ?1 AND t.scheduled = 0"
  ).bind(de).all();
  return json({ mesAtual: hoje.slice(0, 7), de, transacoes: results });
}

// Compras de um cartão numa janela de datas (a fatura), incluindo parcelas futuras.
async function fatura(env, url) {
  const [conta, de, ate] = ["conta", "de", "ate"].map((k) => url.searchParams.get(k) || "");
  if (!conta || !/^\d{4}-\d{2}-\d{2}$/.test(de) || !/^\d{4}-\d{2}-\d{2}$/.test(ate)) return json({ erro: "Parâmetros inválidos" }, 400);
  const { results } = await env.DB.prepare(`SELECT ${COLUNAS_TX} ${DE_TX} WHERE t.account_id = ?1 AND t.date >= ?2 AND t.date <= ?3 ORDER BY t.date DESC, t.id`)
    .bind(conta, de, ate).all();
  return json({ transacoes: results });
}

async function salvarAjuste(request, env, idUrl) {
  let id = "";
  try { id = decodeURIComponent(idUrl); } catch {}
  const c = await request.json().catch(() => null);
  const category = c?.category ?? null;
  const gasto = c?.gasto ?? null;
  const valido = id && id.length <= 100 && (category === null || (typeof category === "string" && category && category.length <= 80)) && (gasto === null || gasto === 0 || gasto === 1);
  if (!valido) return json({ erro: "Dados inválidos" }, 400);
  if (category === null && gasto === null) await env.DB.prepare("DELETE FROM ajustes WHERE transaction_id = ?1").bind(id).run();
  else {
    await env.DB.prepare(
      "INSERT INTO ajustes (transaction_id, category, gasto, updated_at) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(transaction_id) DO UPDATE SET category = excluded.category, gasto = excluded.gasto, updated_at = excluded.updated_at"
    ).bind(id, category, gasto, agora()).run();
  }
  return json({ ok: true });
}

// ---------- Ciclo, limite e alertas ----------

async function lerConfig(db) {
  const { results } = await db.prepare("SELECT chave, valor FROM config").all();
  const c = Object.fromEntries(results.map((r) => [r.chave, r.valor]));
  return { limite: c.limite ? Number(c.limite) : null, salario: c.salario || null };
}

// Base do ciclo e dos alertas: 200 dias de transações (6 meses de média + ciclo atual) e todas as parcelas futuras.
async function baseCiclo(env) {
  const hoje = hojeSP();
  const [tx, contas, config] = await Promise.all([
    env.DB.prepare(`SELECT ${COLUNAS_TX} ${DE_TX} WHERE t.date >= ?1`).bind(somarDias(hoje, -200)).all(),
    env.DB.prepare("SELECT id, type FROM accounts").all(),
    lerConfig(env.DB),
  ]);
  const transacoes = tx.results;
  return { hoje, transacoes, contas: contas.results, config, resumo: resumoCiclo({ transacoes, contas: contas.results, config, hoje }) };
}

async function ciclo(env) {
  const [b, notif] = await Promise.all([
    baseCiclo(env),
    env.DB.prepare("SELECT chave, titulo, corpo, criada FROM notificacoes ORDER BY criada DESC LIMIT 20").all(),
  ]);
  return json({ ciclo: { ...b.resumo, salario: b.config.salario }, notificacoes: notif.results, push: { publica: env.VAPID_PUBLICA || null } });
}

async function salvarConfig(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const corpo = await request.json().catch(() => null);
  if (!corpo || typeof corpo !== "object") return json({ erro: "JSON inválido" }, 400);
  const ops = [];
  if ("limite" in corpo) {
    const v = corpo.limite;
    if (v === null) ops.push(env.DB.prepare("DELETE FROM config WHERE chave = 'limite'"));
    else if (typeof v === "number" && v > 0 && v <= 1e6) ops.push(env.DB.prepare("INSERT OR REPLACE INTO config (chave, valor) VALUES ('limite', ?1)").bind(String(v)));
    else return json({ erro: "Limite deve ser um valor entre R$ 0,01 e R$ 1.000.000" }, 400);
  }
  if ("salario_id" in corpo) {
    const t = await env.DB.prepare("SELECT t.description, t.amount, a.type FROM transactions t JOIN accounts a ON a.id = t.account_id WHERE t.id = ?1").bind(String(corpo.salario_id)).first();
    if (!t) return json({ erro: "Transação não encontrada" }, 404);
    if (t.type === "CREDIT" || !(t.amount > 0) || !normalizar(t.description)) return json({ erro: "Escolha um crédito da conta corrente" }, 400);
    ops.push(env.DB.prepare("INSERT OR REPLACE INTO config (chave, valor) VALUES ('salario', ?1)").bind(normalizar(t.description)));
  }
  if (!ops.length) return json({ erro: "Nada para salvar" }, 400);
  await env.DB.batch(ops);
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

function gravarAlertas(db, alertas) {
  if (!alertas.length) return null;
  return db.batch(alertas.map((a) =>
    db.prepare("INSERT OR IGNORE INTO notificacoes (chave, titulo, corpo, criada) VALUES (?1, ?2, ?3, ?4)").bind(a.chave, a.titulo, a.corpo, agora())));
}

// Um push (sem conteúdo) por inscrição quando há alerta não enviado. Respeita o silêncio das 22h às 7h.
async function enviarPendentes(env, ignorarSilencio = false) {
  if (!env.VAPID_PRIVADA || (!ignorarSilencio && emSilencio(new Date()))) return 0;
  const pend = await env.DB.prepare("SELECT COUNT(*) n FROM notificacoes WHERE enviada_em IS NULL").first();
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

async function avaliarAlertas(env) {
  const b = await baseCiclo(env);
  const avisos = JSON.parse((await env.DB.prepare("SELECT data FROM snapshots WHERE key = 'avisos'").first())?.data || "[]");
  await gravarAlertas(env.DB, gerarAlertas({ ...b, avisos }));
  await enviarPendentes(env);
}

async function alertaSemanal(env) {
  const b = await baseCiclo(env);
  await gravarAlertas(env.DB, [resumoSemanal(b)]);
  await enviarPendentes(env);
}

async function testePush(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  await gravarAlertas(env.DB, [{ chave: "teste:" + agora(), titulo: "Teste do Meu Banco", corpo: "As notificações estão funcionando." }]);
  return json({ ok: true, enviados: await enviarPendentes(env, true) });
}

async function entregarNotificacoes(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const { results } = await env.DB.prepare(
    "UPDATE notificacoes SET entregue_em = ?1 WHERE chave IN (SELECT chave FROM notificacoes WHERE enviada_em IS NOT NULL AND entregue_em IS NULL ORDER BY criada DESC LIMIT 5) RETURNING chave, titulo, corpo"
  ).bind(agora()).all();
  return json({ notificacoes: results });
}

// ---------- Sincronização ----------

async function sincronizar(env, origem) {
  const db = env.DB;

  // Evita duas sincronizações ao mesmo tempo (cron + botão): checagem e registro num comando só (atômico no D1).
  const limite = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const log = await db
    .prepare(
      "INSERT INTO sync_log (origem, started_at) SELECT ?1, ?2 WHERE NOT EXISTS (SELECT 1 FROM sync_log WHERE ok IS NULL AND started_at > ?3) RETURNING id"
    )
    .bind(origem, agora(), limite)
    .first();
  if (!log) return { ok: false, mensagem: "Já existe uma atualização em andamento. Tente em alguns minutos." };
  const avisos = [];
  let ok = 1;

  try {
    const api = new ApiCliente(env);

    // 1) Conexões (bancos ligados no MCP.AI)
    const rconn = await api.chamar("connections/list");
    const conexoes = rconn?.connections || [];
    if (!conexoes.length) throw new Error("Nenhum banco conectado no MCP.AI");

    // 2) Força o banco a atualizar. Se falhar, segue com os dados atuais.
    let sync = null;
    try {
      sync = await api.chamar("connections/sync", { items: conexoes.map((c) => c.item_id), wait: true });
    } catch (e) {
      avisos.push("force_sync falhou: " + e.message);
      console.warn("force_sync falhou", e.message);
    }
    // Um status por banco; o resultado do sync (pós-atualização) prevalece sobre o connections/list (pré).
    const porItem = new Map();
    for (const x of [...conexoes, ...(Array.isArray(sync?.results) ? sync.results : [])]) {
      if (x) porItem.set(x.item_id, { connector_name: porItem.get(x.item_id)?.connector_name, ...x });
    }
    const reconectar = [...porItem.values()]
      .filter((x) => x.needs_action || PROBLEMA.test(x.status || "")) // reconnect_url vem sempre, mesmo com a conexão ok
      .map((x) => ({
        banco: x.bank || x.connector_name || x.name || "Banco",
        mensagem:
          x.message ||
          `O banco não atualizou (${x.executionStatus || x.status || "ação necessária"})` +
            (x.lastUpdatedAt ? `; dados de ${String(x.lastUpdatedAt).slice(8, 10)}/${String(x.lastUpdatedAt).slice(5, 7)}` : "") +
            ". Reconecte e confirme no app do banco.",
        reconnect_url: /^https:\/\//.test(x.reconnect_url || "") ? x.reconnect_url : null,
      }));
    await salvarSnapshot(db, "avisos", reconectar);

    // 3) Contas de cada conexão
    const linhasContas = [];
    for (const conn of conexoes) {
      const rc = await api.chamar("accounts/list", { item: conn.item_id });
      for (const c of rc?.results || []) {
        linhasContas.push({
          id: String(c.id),
          type: c.type,
          subtype: c.subtype ?? null,
          name: c.name ?? null,
          number: c.number ?? null,
          balance: num(c.balance),
          credit_limit: num(c.creditData?.creditLimit),
          available_limit: num(c.creditData?.availableCreditLimit),
          due_date: c.creditData?.balanceDueDate ? String(c.creditData.balanceDueDate).slice(0, 10) : null,
          bank: rc.bank ?? conn.connector_name ?? null,
          item_id: rc.item_id ?? conn.item_id,
          updated_at: agora(),
        });
      }
    }
    if (!linhasContas.length) throw new Error("accounts/list não retornou contas");
    await db.prepare(upsertSql("accounts", Object.keys(linhasContas[0]))).bind(JSON.stringify(linhasContas)).run();

    // 4) Transações e 5) faturas, conta por conta
    const hoje = hojeSP();
    const diasImport = parseInt(env.IMPORT_DAYS, 10) || 180;
    for (const conta of linhasContas) {
      try {
        const n = await sincronizarConta(db, api, conta, hoje, diasImport);
        console.log(`Conta ${conta.name}: ${n} transações`);
      } catch (e) {
        avisos.push(`Transações de ${conta.name}: ${e.message}`);
        console.error("Erro transações", conta.id, e.message);
      }
      if (conta.type === "CREDIT") {
        try {
          const f = await api.chamar("credit-card-bills/list", { account_id: conta.id, include_open_bill: true, page_size: 24 });
          await salvarSnapshot(db, "faturas:" + conta.id, f);
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

  const mensagem = avisos.join(" | ").slice(0, 2000) || "OK";
  await db
    .prepare("UPDATE sync_log SET finished_at = ?1, ok = ?2, message = ?3 WHERE id = ?4")
    .bind(agora(), ok, mensagem, log.id)
    .run();
  if (ok) await avaliarAlertas(env).catch((e) => console.error("Alertas falharam", e?.stack || e));
  return { ok: !!ok, mensagem };
}

async function sincronizarConta(db, api, conta, hoje, diasImport) {
  const ultima = await db
    .prepare(
      "SELECT MAX(CASE WHEN scheduled = 0 AND date <= ?2 THEN date END) AS d, MIN(CASE WHEN status = 'PENDING' AND scheduled = 0 THEN date END) AS p FROM transactions WHERE account_id = ?1"
    )
    .bind(conta.id, hoje)
    .first();
  let de = ultima?.d ? somarDias(ultima.d, -DIAS_REIMPORTAR) : somarDias(hoje, -diasImport);
  if (ultima?.p && ultima.p < de) de = ultima.p; // relê pendentes antigas para não duplicarem quando forem postadas
  const args = { account_id: conta.id, from: de };
  if (conta.type !== "CREDIT") args.to = hoje; // cartão sem "to" para trazer parcelas futuras

  // A REST pagina: busca até vir página vazia, menor que a primeira, ou o fim indicado pela API.
  const todas = [];
  let tamanho = 0;
  for (let page = 1; ; page++) {
    if (page > MAX_PAGINAS) throw new Error(`mais de ${MAX_PAGINAS} páginas de transações; reduza IMPORT_DAYS`);
    const r = await api.chamar("transactions/list", { ...args, page, page_size: TAM_PAGINA });
    const lote = r?.results || [];
    todas.push(...lote);
    tamanho ||= lote.length;
    const fim = r?.has_more === false || (r?.total_pages && page >= r.total_pages) || (r?.total != null && todas.length >= r.total);
    if (!lote.length || lote.length < tamanho || fim) break;
  }
  const ts = agora();
  const linhas = todas.map((t) => ({
    id: String(t.id),
    account_id: conta.id,
    date: String(t.date).slice(0, 10),
    description: t.description ?? "",
    amount: num(t.amount) ?? 0,
    type: t.type ?? null,
    status: t.status ?? null,
    category: t.category ?? null,
    merchant: typeof t.merchant === "string" ? t.merchant : t.merchant?.name || t.merchant?.businessName || null,
    scheduled: t.scheduled ? 1 : 0,
    updated_at: ts,
  }));

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

function salvarSnapshot(db, key, data) {
  return db
    .prepare("INSERT INTO snapshots (key, data, updated_at) VALUES (?1, ?2, ?3) ON CONFLICT(key) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at")
    .bind(key, JSON.stringify(data ?? null), agora())
    .run();
}

function num(v) {
  if (v == null || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
