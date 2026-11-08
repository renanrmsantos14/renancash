// Mock da API REST do Banco MCP (MCP.AI) com dados falsos, para testar com "wrangler dev".
// Uso: node mock/api-mock.mjs   (porta 8788, API key "sk_live_teste")
import { createServer } from "node:http";

const PORTA = Number(process.env.PORT || 8788);
const TOKEN = process.env.MOCK_TOKEN || "sk_live_teste";
let ultimoPush = { total: 0, authorization: null, ttl: null }; // último push recebido (para a verificação)
const PEDIR_LOGIN = process.env.MOCK_RECONNECT === "1"; // simula banco pedindo novo login

const dia = (delta) => {
  const d = new Date();
  d.setDate(d.getDate() + delta);
  return d.toISOString().slice(0, 10) + "T03:00:00.000Z";
};

const contas = [
  { id: "conta-cc", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta Corrente Inter", number: "1234567-8", balance: "4823.17" },
  {
    id: "conta-cartao", type: "CREDIT", subtype: "CREDIT_CARD", name: "Cartão Inter Gold", number: "5555",
    balance: "1342.90",
    creditData: { creditLimit: "8000.00", availableCreditLimit: "5320.40", balanceDueDate: dia(12) },
  },
];

const cats = [
  ["Groceries", "SUPERMERCADO PAO DE ACUCAR", 312.4], ["Eating out", "RESTAURANTE SABOR", 89.9],
  ["Gas stations", "POSTO SHELL", 220], ["Pharmacy", "DROGASIL", 64.35], ["Video streaming", "NETFLIX", 55.9],
  ["Taxi and ride-hailing", "UBER *TRIP", 32.5], ["Food delivery", "IFOOD", 74.8], ["Online shopping", "MERCADO LIVRE", 199.99],
];

function transacoes(conta) {
  const out = [];
  if (conta === "conta-cc") {
    const fixas = [
      ["sal", 2, "SALARIO EMPRESA X", 7500, "Salary"], ["alug", 4, "PIX ENVIADO IMOBILIARIA", -2100, "Rent"],
      ["luz", 6, "ENEL CONTA DE LUZ", -187.32, "Electricity"], ["fat", 8, "PAGAMENTO FATURA CARTAO", -1500, "Credit card payment"],
      ["inv", 3, "APLICACAO CDB", -1000, "Fixed income"], ["pix", 10, "PIX ENVIADO JOAO", -150, "Transfer - PIX"],
    ];
    for (let m = 0; m < 6; m++) {
      for (const [k, dias, description, v, category] of fixas) {
        out.push({ id: `cc-${k}-${m}`, date: dia(-m * 30 - dias), description, amount: v.toFixed(2), type: v > 0 ? "CREDIT" : "DEBIT", status: "POSTED", category });
      }
    }
    out.push({ id: "cc-pend", date: dia(0), description: "COMPRA DEBITO PADARIA", amount: "-18.50", type: "DEBIT", status: "PENDING", category: "Eating out" });
  } else {
    for (let i = 0; i < 60; i++) {
      const [category, description, v] = cats[i % cats.length];
      out.push({ id: `cart-${i}`, date: dia(-i * 3), description, amount: (v + (i % 5)).toFixed(2), type: "DEBIT", status: i === 0 ? "PENDING" : "POSTED", category, merchant: { name: description } });
    }
    out.push({ id: "cart-pag", date: dia(-8), description: "PAGAMENTO RECEBIDO", amount: "-1500.00", type: "CREDIT", status: "POSTED", category: "Credit card payment" });
    for (let p = 1; p <= 3; p++) {
      out.push({ id: `cart-parc-${p}`, date: dia(p * 30), description: `NOTEBOOK LOJA ${p + 1}/4`, amount: "750.00", type: "DEBIT", status: "POSTED", category: "Electronics", scheduled: true });
    }
  }
  return out;
}

function faturas() {
  const st = ["PAID", "PAID", "PAID", "PAST_DUE_UNCONFIRMED", "PAID", "PAID"];
  return {
    results: st.map((s, i) => ({ id: `fat-${i}`, dueDate: dia(-(i + 1) * 30 + 12), totalAmount: (1400 + i * 37.5).toFixed(2), payment_status: s })),
    open_bill: { available: true, due_date: dia(12), total_amount: "1342.90" },
    total_pending_debt: "2679.65",
  };
}

// Mesmos caminhos e formato da API real: POST /api/openfinance/<rota> → { ok, tool, result }
const rotas = {
  "connections/list": () => ({
    connections: [{ connector_id: "612", connector_name: "Banco Inter", item_id: "item-1", status: PEDIR_LOGIN ? "LOGIN_ERROR" : "UPDATED" }],
    count: 1,
  }),
  "connections/sync": () => ({
    results: [PEDIR_LOGIN
      ? { item_id: "item-1", bank: "Banco Inter", status: "LOGIN_ERROR", needs_action: true, reconnect_url: "https://exemplo.com/reconectar", message: "Faça login novamente no Banco Inter." }
      : { item_id: "item-1", bank: "Banco Inter", status: "UPDATED" }],
  }),
  "accounts/list": () => ({ bank: "Banco Inter", item_id: "item-1", results: contas }),
  "transactions/list": (a) => {
    const todas = transacoes(a.account_id).filter((t) => t.date.slice(0, 10) >= a.from && (!a.to || t.date.slice(0, 10) <= a.to));
    const tam = Math.min(a.page_size || 50, 25), pag = a.page || 1; // páginas pequenas para testar a paginação
    return { results: todas.slice((pag - 1) * tam, pag * tam), page: pag, total: todas.length };
  },
  "credit-card-bills/list": () => faturas(),
};

createServer(async (req, res) => {
  let corpo = "";
  for await (const p of req) corpo += p;
  const enviar = (status, obj) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
  const rota = req.url.replace(/^\/api\/openfinance\//, "").split("?")[0];
  if (req.method === "GET" && rota === "_endpoints") return enviar(200, { endpoints: Object.keys(rotas).map((r) => ({ id: r })) });
  // Simula o serviço de push do navegador: /push/morto responde 410 (inscrição expirada); GET devolve o último push.
  if (req.url.startsWith("/push/")) {
    if (req.method === "GET") return enviar(200, ultimoPush);
    ultimoPush = { total: ultimoPush.total + 1, authorization: req.headers.authorization || null, ttl: req.headers.ttl || null };
    return enviar(req.url.includes("morto") ? 410 : 201, {});
  }
  if (req.method !== "POST") return enviar(405, { error: { code: "method_not_allowed" } });
  if (req.headers.authorization !== `Bearer ${TOKEN}`) return enviar(401, { error: { code: "unauthorized", message: "invalid api key" } });
  const fn = rotas[rota];
  if (!fn) return enviar(404, { error: { code: "not_found", message: rota } });
  const args = JSON.parse(corpo || "{}");
  console.log("←", rota, JSON.stringify(args));
  enviar(200, { ok: true, tool: rota, result: fn(args) });
}).listen(PORTA, () => console.log(`Mock da API em http://localhost:${PORTA}/api/openfinance (key: ${TOKEN})`));
