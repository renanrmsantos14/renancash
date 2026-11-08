// Cliente da API REST do Banco MCP (MCP.AI). Sem IA: POST JSON com a API key do workspace.
// Documentação pública: https://api.mcp.ai/api/openfinance/_endpoints

const BASE_PADRAO = "https://api.mcp.ai/api/openfinance";

const DICAS = {
  401: "API key inválida ou ausente: refaça 'wrangler secret put MCP_API_KEY'",
  402: "créditos do MCP.AI esgotados ou plano necessário",
  403: "a API key não tem acesso ao Banco MCP neste workspace",
  409: "o banco não está conectado no MCP.AI (conecte em app.mcp.ai)",
  429: "limite de requisições do MCP.AI",
};

export class ApiCliente {
  constructor(env) {
    if (!env.MCP_API_KEY) throw new Error("Secret MCP_API_KEY não configurado");
    this.base = (env.API_URL || BASE_PADRAO).replace(/\/+$/, "");
    this.chave = env.MCP_API_KEY;
  }

  // caminho = rota REST, ex.: "accounts/list"
  async chamar(caminho, args = {}, tentativa = 0) {
    const resp = await fetch(`${this.base}/${caminho}`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${this.chave}` },
      body: JSON.stringify(args),
    });
    if (resp.status === 429 && tentativa < 2) {
      const espera = Math.min(5, Number(resp.headers.get("retry-after")) || 1);
      await resp.body?.cancel(); // libera a conexão antes de tentar de novo
      await new Promise((r) => setTimeout(r, espera * 1000));
      return this.chamar(caminho, args, tentativa + 1);
    }
    const texto = await resp.text();
    let corpo;
    try { corpo = JSON.parse(texto); } catch { corpo = null; }
    if (!resp.ok || !corpo?.ok) {
      const e = corpo?.error || {};
      const dica = DICAS[resp.status] ? ` (${DICAS[resp.status]})` : "";
      const link = e.connect_url || e.checkout_urls?.[0] || "";
      throw new Error(
        `${caminho}: HTTP ${resp.status} ${e.code || ""}${dica} ${e.message || texto.slice(0, 200)} ${link}`.replace(/\s+/g, " ").trim()
      );
    }
    const r = corpo.result;
    return typeof r === "string" ? JSON.parse(r) : r;
  }

  // Lista pública dos endpoints (diagnóstico).
  async endpoints() {
    const resp = await fetch(`${this.base}/_endpoints`);
    if (!resp.ok) throw new Error(`_endpoints: HTTP ${resp.status}`);
    const d = await resp.json();
    const lista = Array.isArray(d) ? d : d.endpoints || [];
    return lista.map((e) => e.id);
  }
}
