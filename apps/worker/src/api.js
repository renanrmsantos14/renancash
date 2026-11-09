// Cliente da API do Pluggy (https://api.pluggy.ai), lendo as conexões feitas no Meu Pluggy.
// Docs: https://docs.pluggy.ai/reference/auth-create · https://docs.pluggy.ai/docs/rate-limits
// Autenticação: POST /auth {clientId, clientSecret} → apiKey (vale 2 h); as demais chamadas levam o cabeçalho X-API-KEY.

const BASE_PADRAO = "https://api.pluggy.ai";
const MAX_PAGINAS_ITENS = 5;

const DICAS = {
  400: "requisição inválida",
  401: "credenciais do Pluggy inválidas: refaça 'wrangler secret put PLUGGY_CLIENT_ID' e 'PLUGGY_CLIENT_SECRET'",
  403: "sem permissão no Pluggy (confira as credenciais e se o recurso está habilitado na sua conta)",
  404: "não encontrado no Pluggy (confira os ids em PLUGGY_ITEM_IDS)",
  429: "limite de requisições do Pluggy",
};

export class ApiCliente {
  constructor(env, ids) {
    if (!env.PLUGGY_CLIENT_ID || !env.PLUGGY_CLIENT_SECRET) throw new Error("Secrets PLUGGY_CLIENT_ID e PLUGGY_CLIENT_SECRET não configurados");
    this.base = (env.PLUGGY_API_URL || BASE_PADRAO).replace(/\/+$/, "");
    this.clientId = env.PLUGGY_CLIENT_ID;
    this.clientSecret = env.PLUGGY_CLIENT_SECRET;
    this.doD1 = ids != null; // lista vazia do D1 = nada a sincronizar (o secret só vale sem lista)
    this.itemIds = ids ?? (env.PLUGGY_ITEM_IDS || "").split(",").map((s) => s.trim()).filter(Boolean);
    this.semV2 = false;
    this.chave = null; // Promise da apiKey (compartilhada entre chamadas simultâneas)
  }

  // Uma requisição HTTP, com nova tentativa no 429 (espera o Retry-After, até 10 s, 3 vezes). Devolve o JSON.
  async #pedir(metodo, caminho, { params, corpo, chave, tentativa = 0 } = {}) {
    const qs = params ? "?" + new URLSearchParams(Object.entries(params).filter(([, v]) => v != null)) : "";
    const headers = { accept: "application/json" };
    if (corpo !== undefined) headers["content-type"] = "application/json";
    if (chave) headers["x-api-key"] = chave;
    const resp = await fetch(`${this.base}${caminho}${qs}`, { method: metodo, headers, body: corpo !== undefined ? JSON.stringify(corpo) : undefined });
    if (resp.status === 429 && tentativa < 3) {
      const espera = Math.min(10, Number(resp.headers.get("retry-after")) || 6);
      await resp.body?.cancel(); // libera a conexão antes de tentar de novo
      await new Promise((r) => setTimeout(r, espera * 1000));
      return this.#pedir(metodo, caminho, { params, corpo, chave, tentativa: tentativa + 1 });
    }
    const texto = await resp.text();
    let json;
    try { json = JSON.parse(texto); } catch { json = null; }
    if (!resp.ok) {
      const dica = DICAS[resp.status] ? ` (${DICAS[resp.status]})` : resp.status >= 500 ? " (instabilidade no Pluggy; tente de novo mais tarde)" : "";
      const msg = json?.message || (json ? "" : texto.slice(0, 200));
      const e = new Error(`${metodo} ${caminho}: HTTP ${resp.status}${dica} ${msg}`.replace(/\s+/g, " ").trim());
      e.status = resp.status;
      throw e;
    }
    return json;
  }

  // renovar = a apiKey (promise) que acabou de falhar; se outra chamada já a trocou, reaproveita a nova em vez de autenticar de novo.
  #autenticar(renovar) {
    if (!this.chave || (renovar && this.chave === renovar)) {
      this.chave = this.#pedir("POST", "/auth", { corpo: { clientId: this.clientId, clientSecret: this.clientSecret } })
        .then((r) => { if (!r?.apiKey) throw new Error("POST /auth: resposta sem apiKey"); return r.apiKey; })
        .catch((e) => { this.chave = null; throw e; });
    }
    return this.chave;
  }

  // Requisição autenticada. Se a apiKey expirar no meio (401/403), autentica de novo uma vez.
  async #autenticado(metodo, caminho, { params, corpo } = {}) {
    const usada = this.#autenticar();
    const chave = await usada; // falha de autenticação sobe direto, sem repetir
    try {
      return await this.#pedir(metodo, caminho, { params, corpo, chave });
    } catch (e) {
      if (e.status !== 401 && e.status !== 403) throw e;
      return this.#pedir(metodo, caminho, { params, corpo, chave: await this.#autenticar(usada) });
    }
  }

  obter(caminho, params) { return this.#autenticado("GET", caminho, { params }); }

  // Token temporário (30 min) do Pluggy Connect. Com itemId, o Connect abre em modo de atualização daquele item.
  async connectToken(itemId) {
    const corpo = { ...(itemId ? { itemId } : {}), options: { clientUserId: "meu-banco", avoidDuplicates: true } };
    const r = await this.#autenticado("POST", "/connect_token", { corpo });
    if (!r?.accessToken) throw new Error("POST /connect_token: resposta sem accessToken");
    return r.accessToken;
  }

  // Pede ao banco dados novos com as credenciais salvas; o fim chega pelo webhook (item/updated).
  atualizarItem(id) { return this.#autenticado("PATCH", `/items/${encodeURIComponent(id)}`, { corpo: {} }); }

  // Webhook único para todos os items (event "all"). Não duplica se já houver um para a mesma URL.
  async criarWebhook(url, secret) {
    const igual = ((await this.obter("/webhooks"))?.results || []).find((w) => w.url === url);
    if (igual) { // regrava o cabeçalho: com o PLUGGY_WEBHOOK_SECRET trocado, o antigo seria recusado com 401 para sempre
      await this.#autenticado("PATCH", `/webhooks/${encodeURIComponent(igual.id)}`, { corpo: { headers: { "x-webhook-secret": secret } } });
      return { id: igual.id, criado: false };
    }
    const r = await this.#autenticado("POST", "/webhooks", { corpo: { event: "all", url, headers: { "x-webhook-secret": secret } } });
    return { id: r?.id, criado: true };
  }

  // Ids das conexões (items): os de PLUGGY_ITEM_IDS ou, se vazio, GET /v2/items (opt-in na conta; o Pluggy não lista items por padrão).
  async listarIds() {
    await this.#autenticar(); // credenciais erradas falham aqui, uma vez só, e não em cada conexão
    if (this.itemIds.length || this.doD1) return this.itemIds;
    const ids = [];
    let proximo = "";
    try {
      for (let i = 0; i < MAX_PAGINAS_ITENS; i++) {
        const r = await this.obter("/v2/items" + proximo);
        ids.push(...(r?.results || []).map((x) => x.id));
        if (!r?.next) break;
        proximo = r.next;
      }
    } catch (e) {
      throw new Error(`Defina PLUGGY_ITEM_IDS (ids das conexões do Meu Pluggy, separados por vírgula): ${e.message}`);
    }
    if (!ids.length) throw new Error("Nenhuma conexão encontrada; defina PLUGGY_ITEM_IDS com os ids do Meu Pluggy");
    return ids;
  }

  item(id) { return this.obter(`/items/${encodeURIComponent(id)}`); }

  async contas(itemId) { return (await this.obter("/accounts", { itemId }))?.results || []; }

  async faturas(accountId) { return (await this.obter("/bills", { accountId, pageSize: 24 }))?.results || []; }

  // Todas as transações da conta. Usa GET /v2/transactions (cursor `after`, dateFrom/dateTo, 500 por página);
  // a v1 (GET /transactions, page/pageSize) vence em 2026-12-31 e só é usada se a v2 responder 403/404/410 (não disponível).
  async transacoes(accountId, from, to, maxPaginas) {
    if (!this.semV2) {
      try {
        return await this.#transacoesV2(accountId, from, to, maxPaginas);
      } catch (e) {
        if (![403, 404, 410].includes(e.status)) throw e;
        this.semV2 = true;
        console.warn("GET /v2/transactions indisponível; usando GET /transactions (v1)", e.message);
      }
    }
    return this.#transacoesV1(accountId, from, to, maxPaginas);
  }

  async #transacoesV2(accountId, dateFrom, dateTo, maxPaginas) {
    const todas = [];
    let after;
    for (let pagina = 1; ; pagina++) {
      if (pagina > maxPaginas) throw new Error(`mais de ${maxPaginas} páginas de transações; reduza IMPORT_DAYS`);
      const r = await this.obter("/v2/transactions", { accountId, dateFrom, dateTo, after });
      todas.push(...(r?.results || []));
      // `next` é uma query string pronta; a doc manda enviar só o valor (decodificado) de `after`.
      after = r?.next ? new URLSearchParams(r.next).get("after") : null;
      if (!after) return todas;
    }
  }

  async #transacoesV1(accountId, from, to, maxPaginas) {
    const todas = [];
    for (let page = 1; ; page++) {
      if (page > maxPaginas) throw new Error(`mais de ${maxPaginas} páginas de transações; reduza IMPORT_DAYS`);
      const r = await this.obter("/transactions", { accountId, from, to, page, pageSize: 500 });
      todas.push(...(r?.results || []));
      if (!r?.results?.length || page >= (r.totalPages || 1)) return todas;
    }
  }
}
