// Mock da API do Pluggy com dados falsos (2 conexões: Inter e Santander), para testar com "wrangler dev".
// Uso: node mock/api-mock.mjs   (porta 8788; clientId "id-teste", clientSecret "segredo-teste")
import { createServer } from "node:http";

const PORTA = Number(process.env.PORT || 8788);
let ultimoPush = { total: 0, authorization: null, ttl: null }; // último push recebido (para a verificação)
const PEDIR_LOGIN = process.env.MOCK_RECONNECT === "1"; // simula banco pedindo novo login

// Datas pelo calendário de São Paulo (o Worker compara com a data de hoje em SP).
const hojeSP = new Date().toLocaleDateString("sv", { timeZone: "America/Sao_Paulo" });
const dia = (delta) => {
  const d = new Date(hojeSP + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + delta);
  return d.toISOString().slice(0, 10) + "T03:00:00.000Z";
};

const CLIENT_ID = "id-teste", CLIENT_SECRET = "segredo-teste";
const itens = {
  "item-inter": { id: "item-inter", connector: { name: "Meu Pluggy" }, status: PEDIR_LOGIN ? "LOGIN_ERROR" : "UPDATED", executionStatus: "SUCCESS" },
  "item-santander": { id: "item-santander", connector: { name: "Santander" }, status: "UPDATED", executionStatus: "SUCCESS" },
};
const contasPorItem = {
  "item-inter": [
    { id: "conta-cc", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta Corrente Inter", number: "1234567-8", balance: 4823.17 },
    {
      id: "conta-cartao", type: "CREDIT", subtype: "CREDIT_CARD", name: "Cartão Inter Gold", number: "5555", balance: 1342.9,
      creditData: { creditLimit: 8000, availableCreditLimit: 5320.4, balanceDueDate: dia(12) },
    },
  ],
  "item-santander": [
    { id: "sant-cc", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta Corrente", number: "9876", balance: 910.55 },
    {
      id: "sant-cartao", type: "CREDIT", subtype: "CREDIT_CARD", name: "Cartão", number: "4444", balance: 420,
      creditData: { creditLimit: 3000, availableCreditLimit: 2580, balanceDueDate: dia(9) },
    },
  ],
};

const cats = [
  ["Groceries", "SUPERMERCADO PAO DE ACUCAR", 312.4], ["Eating out", "RESTAURANTE SABOR", 89.9],
  ["Gas stations", "POSTO SHELL", 220], ["Pharmacy", "DROGASIL", 64.35], ["Video streaming", "NETFLIX", 55.9],
  ["Taxi and ride-hailing", "UBER *TRIP", 32.5], ["Food delivery", "IFOOD", 74.8], ["Online shopping", "MERCADO LIVRE", 199.99],
];

function transacoes(conta) {
  const out = [];
  if (conta === "sant-cc") {
    out.push({ id: "sc-1", date: dia(-5), description: "PIX RECEBIDO MARIA", amount: 300, type: "CREDIT", status: "POSTED", category: "Transfer - PIX" });
    out.push({ id: "sc-2", date: dia(-3), description: "COMPRA DEBITO MERCADO", amount: -85.4, type: "DEBIT", status: "POSTED", category: "Groceries" });
    out.push({ id: "sc-3", date: dia(0), description: "COMPRA DEBITO CAFE", amount: -12, type: "DEBIT", status: "PENDING", category: "Eating out" });
  } else if (conta === "sant-cartao") {
    out.push({ id: "sk-1", date: dia(-6), description: "AMAZON MARKETPLACE", amount: 149.9, type: "DEBIT", status: "POSTED", category: "Online shopping", merchant: { name: "Amazon" } });
    out.push({ id: "sk-2", date: dia(-2), description: "FARMACIA SAO JOAO", amount: 48.1, type: "DEBIT", status: "POSTED", category: "Pharmacy" });
    out.push({ id: "sk-3", date: dia(-1), description: "ESTORNO AMAZON", amount: -20, type: "CREDIT", status: "POSTED", category: "Online shopping" });
    out.push({ id: "sk-p2", date: dia(30), description: "CELULAR LOJA", amount: 200, type: "DEBIT", status: "POSTED", category: "Electronics", creditCardMetadata: { installmentNumber: 2, totalInstallments: 3 } });
  } else if (conta === "conta-cc") {
    const fixas = [
      ["sal", 2, "SALARIO EMPRESA X", 7500, "Salary"], ["alug", 4, "PIX ENVIADO IMOBILIARIA", -2100, "Rent"],
      ["luz", 6, "ENEL CONTA DE LUZ", -187.32, "Electricity"], ["fat", 8, "PAGAMENTO FATURA CARTAO", -1500, "Credit card payment"],
      ["inv", 3, "APLICACAO CDB", -1000, "Fixed income"], ["pix", 10, "PIX ENVIADO JOAO", -150, "Transfer - PIX"],
    ];
    for (let m = 0; m < 6; m++) {
      for (const [k, dias, description, v, category] of fixas) {
        out.push({ id: `cc-${k}-${m}`, date: dia(-m * 30 - dias), description, amount: v, type: v > 0 ? "CREDIT" : "DEBIT", status: "POSTED", category });
      }
    }
    out.push({ id: "cc-pend", date: dia(0), description: "COMPRA DEBITO PADARIA", amount: -18.5, type: "DEBIT", status: "PENDING", category: "Eating out" });
  } else {
    for (let i = 0; i < 60; i++) {
      const [category, description, v] = cats[i % cats.length];
      out.push({ id: `cart-${i}`, date: dia(-i * 3), description, amount: v + (i % 5), type: "DEBIT", status: i === 0 ? "PENDING" : "POSTED", category, merchant: { name: description } });
    }
    out.push({ id: "cart-pag", date: dia(-8), description: "PAGAMENTO RECEBIDO", amount: -1500, type: "CREDIT", status: "POSTED", category: "Credit card payment" });
    for (let p = 1; p <= 3; p++) {
      out.push({ id: `cart-parc-${p}`, date: dia(p * 30), description: "NOTEBOOK LOJA", amount: 750, type: "DEBIT", status: "POSTED", category: "Electronics", creditCardMetadata: { installmentNumber: p + 1, totalInstallments: 4 } });
    }
  }
  return out;
}

const faturas = () => ["a", "b", "c", "d", "e", "f"].map((k, i) => ({ id: `fat-${k}`, dueDate: dia(-(i + 1) * 30 + 12), totalAmount: 1400 + i * 37.5, minimumPaymentAmount: 200, allowsInstallments: true }));

// Mesmos caminhos e formato do Pluggy: POST /auth, GET e PATCH /items/:id, /accounts, /transactions, /bills (X-API-KEY).
const CHAVE = "chave-mock-" + Date.now();
function rota(caminho, q) {
  const id = /^\/items\/([^/]+)$/.exec(caminho)?.[1];
  if (id) return itens[id] ? [200, itens[id]] : [404, { message: "Item not found" }];
  if (caminho === "/accounts") {
    const r = contasPorItem[q.get("itemId")];
    return r ? [200, { total: r.length, totalPages: 1, page: 1, results: r }] : [404, { message: "Item not found" }];
  }
  if (caminho === "/transactions" || caminho === "/v2/transactions") {
    const v2 = caminho.startsWith("/v2");
    if (v2 && process.env.MOCK_SEM_V2 === "1") return [404, { message: "not found" }]; // simula conta sem a v2 (usa a v1)
    const de = q.get(v2 ? "dateFrom" : "from"), ate = q.get(v2 ? "dateTo" : "to");
    const todas = transacoes(q.get("accountId")).filter((t) => t.date.slice(0, 10) >= de && (!ate || t.date.slice(0, 10) <= ate));
    const tam = v2 ? 25 : Math.min(Number(q.get("pageSize")) || 500, 25); // páginas pequenas para testar a paginação
    if (v2) { // cursor: `after` = deslocamento codificado; `next` é uma query string
      const ini = q.get("after") ? Number(atob(q.get("after"))) : 0;
      const fim = ini + tam;
      return [200, { results: todas.slice(ini, fim), next: fim < todas.length ? `?accountId=${q.get("accountId")}&after=${encodeURIComponent(btoa(String(fim)))}` : null }];
    }
    const pag = Number(q.get("page")) || 1;
    return [200, { total: todas.length, totalPages: Math.max(1, Math.ceil(todas.length / tam)), page: pag, results: todas.slice((pag - 1) * tam, pag * tam) }];
  }
  if (caminho === "/bills") return [200, { total: 6, totalPages: 1, page: 1, results: faturas() }];
  if (caminho === "/v2/items") return process.env.MOCK_LISTA_ITENS === "1" ? [200, { results: Object.values(itens), next: null }] : [403, { message: "Forbidden" }];
  return [404, { message: caminho }];
}

createServer(async (req, res) => {
  let corpo = "";
  for await (const p of req) corpo += p;
  const enviar = (status, obj) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
  const url = new URL(req.url, "http://x");
  // Simula o serviço de push do navegador: /push/morto responde 410 (inscrição expirada); GET devolve o último push.
  if (url.pathname.startsWith("/push/")) {
    if (req.method === "GET") return enviar(200, ultimoPush);
    ultimoPush = { total: ultimoPush.total + 1, authorization: req.headers.authorization || null, ttl: req.headers.ttl || null };
    return enviar(url.pathname.includes("morto") ? 410 : 201, {});
  }
  if (req.method === "POST" && url.pathname === "/auth") {
    const c = JSON.parse(corpo || "{}");
    if (c.clientId !== CLIENT_ID || c.clientSecret !== CLIENT_SECRET) return enviar(401, { code: 401, message: "Invalid credentials" });
    return enviar(200, { apiKey: CHAVE });
  }
  // PATCH /items/:id (botão Atualizar) devolve o item, como o Pluggy.
  if (req.method !== "GET" && !(req.method === "PATCH" && url.pathname.startsWith("/items/"))) return enviar(405, { message: "method not allowed" });
  if (req.headers["x-api-key"] !== CHAVE) return enviar(401, { code: 401, message: "Invalid API key" });
  console.log("←", req.url);
  const [status, obj] = rota(url.pathname, url.searchParams);
  enviar(status, obj);
}).listen(PORTA, () => console.log(`Mock do Pluggy em http://localhost:${PORTA} (clientId: ${CLIENT_ID})`));
