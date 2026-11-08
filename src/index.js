import { ApiCliente } from "./api.js";

const TZ = "America/Sao_Paulo";
const LINHAS_POR_INSERT = 400; // linhas por comando SQL (via json_each, 1 parâmetro só)
const TAM_PAGINA = 500; // máximo da API
const MAX_PAGINAS = 10; // limite de segurança (subrequests do plano grátis)
const PROBLEMA = /LOGIN_ERROR|OUTDATED|WAITING_USER/; // status de conexão que pede novo login
const DIAS_REIMPORTAR = 10; // relê os últimos dias para pegar lançamentos que o banco posta com atraso

export default {
  async fetch(request, env, ctx) {
    const auth = await checarSenha(request, env);
    if (auth) return seguranca(auth);
    const url = new URL(request.url);
    try {
      let resp;
      if (url.pathname === "/api/dados" && request.method === "GET") resp = await dados(env, url);
      else if (url.pathname === "/api/atualizar" && request.method === "POST") {
        if (!mesmaOrigem(request, url)) resp = json({ erro: "Origem não permitida" }, 403);
        else {
          // waitUntil: se o navegador fechar no meio, a sincronização termina e o sync_log é fechado.
          const tarefa = sincronizar(env, "botao");
          ctx.waitUntil(tarefa);
          resp = json(await tarefa);
        }
      } else if (url.pathname === "/api/ferramentas" && request.method === "GET") {
        // Diagnóstico: testa a API key listando as conexões e mostra os endpoints disponíveis.
        const api = new ApiCliente(env);
        const [conexoes, endpoints] = await Promise.all([api.chamar("connections/list"), api.endpoints()]);
        resp = json({ conexoes, endpoints });
      } else if (url.pathname.startsWith("/api/")) resp = json({ erro: "Rota não encontrada" }, 404);
      else resp = await env.ASSETS.fetch(request);
      return seguranca(resp);
    } catch (e) {
      console.error("Erro na requisição", url.pathname, e?.stack || e);
      return seguranca(json({ erro: String(e?.message || e) }, 500));
    }
  },

  async scheduled(_evento, env, ctx) {
    ctx.waitUntil(sincronizar(env, "cron"));
  },
};

// ---------- Segurança ----------

async function checarSenha(request, env) {
  if (!env.APP_PASSWORD) return new Response("APP_PASSWORD não configurado.", { status: 500 });
  const cab = request.headers.get("authorization") || "";
  let senha = "";
  if (cab.startsWith("Basic ")) {
    try {
      const dec = new TextDecoder().decode(Uint8Array.from(atob(cab.slice(6)), (c) => c.charCodeAt(0)));
      senha = dec.slice(dec.indexOf(":") + 1); // usuário é ignorado
    } catch {} // base64 inválido = senha vazia
  }
  if (await iguais(senha, env.APP_PASSWORD)) return null;
  return new Response("Senha necessária.", {
    status: 401,
    headers: { "www-authenticate": 'Basic realm="Meu Banco", charset="UTF-8"' },
  });
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
    "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
  );
  return r;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json; charset=utf-8" } });
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

async function dados(env, url) {
  const db = env.DB;
  const mesParam = url.searchParams.get("mes");
  const mes = /^\d{4}-\d{2}$/.test(mesParam || "") ? mesParam : hojeSP().slice(0, 7);
  const [contas, transacoes, meses, snaps, ultimaOk, ultima] = await db.batch([
    db.prepare("SELECT * FROM accounts ORDER BY type, name"),
    db.prepare(
      "SELECT id, account_id, date, description, amount, type, status, category, merchant, scheduled FROM transactions WHERE date >= ?1 AND date <= ?2 ORDER BY date DESC, id"
    ).bind(mes + "-01", mes + "-31"),
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
      .filter((x) => x.needs_action || x.reconnect_url || PROBLEMA.test(x.status || ""))
      .map((x) => ({
        banco: x.bank || x.connector_name || x.name || "Banco",
        mensagem: x.message || "O banco pede um novo login (" + (x.status || "ação necessária") + ").",
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
