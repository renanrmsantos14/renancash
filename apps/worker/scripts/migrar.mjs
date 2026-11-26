// Acrescenta ao D1 as colunas que o schema.sql ganhou depois da criação das tabelas. Idempotente: só cria o que falta.
// Uso: pnpm --filter @meu-banco/worker migrar -- --local   (ou --remote). Rode ANTES de publicar o Worker.
// Para uma coluna nova: ponha no CREATE TABLE do schema.sql (instalação nova) e em COLUNAS abaixo (instalação existente).
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

export const COLUNAS = {
  accounts: {
    closing_date: "TEXT",
    minimum_payment: "REAL", // creditData.minimumPayment (fatura aberta)
    overdraft_limit: "REAL", // bankData.overdraftContractedLimit (cheque especial contratado)
    overdraft_used: "REAL", // bankData.overdraftUsedLimit
    auto_invested: "REAL", // bankData.automaticallyInvestedBalance
  },
  transactions: {
    bill_id: "TEXT", // creditCardMetadata.billId
    bill_month: "TEXT", // creditCardMetadata.billForecastDate (AAAA-MM): fatura em que a compra cai
    contraparte: "TEXT", // paymentData: nome de quem recebeu (saída) ou pagou (entrada)
    metodo: "TEXT", // paymentData.paymentMethod (PIX, TED, BOLETO...)
    entre_minhas: "INTEGER", // 1 = a outra ponta é o próprio titular (documento igual ao do /identity)
    tipo_credito: "TEXT", // creditCardMetadata.otherCreditsType ou feeType (REVOLVING_CREDIT, BILL_INSTALLMENT, ANNUAL_FEE...)
  },
  pluggy_items: {
    proximo_sync: "TEXT", // item.nextAutoSyncAt
    consentimento_expira: "TEXT", // item.consentExpiresAt (Open Finance)
  },
};

// Tabelas novas: CREATE IF NOT EXISTS sempre roda (idempotente).
export const TABELAS = [
  "CREATE TABLE IF NOT EXISTS transacoes_removidas (id TEXT PRIMARY KEY, removida_em TEXT NOT NULL);",
  "CREATE INDEX IF NOT EXISTS idx_tx_removidas ON transacoes_removidas(removida_em);",
  "CREATE TABLE IF NOT EXISTS espelho (tabela TEXT NOT NULL, pk TEXT NOT NULL, dados TEXT, updated_at TEXT NOT NULL, deleted_at TEXT, server_at TEXT NOT NULL, aparelho TEXT, PRIMARY KEY (tabela, pk));",
  "CREATE INDEX IF NOT EXISTS idx_espelho_server ON espelho(server_at, tabela, pk);",
  "CREATE TABLE IF NOT EXISTS espelho_meta (chave TEXT PRIMARY KEY, valor TEXT);",
  "CREATE TABLE IF NOT EXISTS mcp_clientes (id TEXT PRIMARY KEY, nome TEXT NOT NULL, destinos TEXT NOT NULL, criado INTEGER NOT NULL);",
  "CREATE TABLE IF NOT EXISTS mcp_oauth (hash TEXT PRIMARY KEY, tipo TEXT NOT NULL, cliente TEXT NOT NULL, dados TEXT, expira INTEGER NOT NULL, criado INTEGER NOT NULL);",
  "CREATE INDEX IF NOT EXISTS idx_mcp_oauth_expira ON mcp_oauth(expira);",
  "CREATE TABLE IF NOT EXISTS anotacoes (id TEXT PRIMARY KEY, valor REAL NOT NULL, data TEXT NOT NULL, receita INTEGER NOT NULL DEFAULT 0, descricao TEXT NOT NULL, titulo TEXT, categoria TEXT, subcategoria TEXT, nota TEXT, conta TEXT, status TEXT NOT NULL DEFAULT 'pendente', transacao_id TEXT, criada TEXT NOT NULL, atualizada TEXT NOT NULL);",
  "CREATE INDEX IF NOT EXISTS idx_anotacoes_status ON anotacoes(status, data);",
];

// Comandos ALTER TABLE para o que falta, dado { tabela: [colunas existentes] }. Tabela ausente fica de fora.
export function alteracoes(existentes) {
  const sql = [];
  for (const [tabela, cols] of Object.entries(COLUNAS)) {
    const tem = existentes[tabela];
    if (!tem?.length) continue;
    for (const [col, tipo] of Object.entries(cols)) if (!tem.includes(col)) sql.push(`ALTER TABLE ${tabela} ADD COLUMN ${col} ${tipo};`);
  }
  return sql;
}

function d1(modo, ...args) {
  const r = spawnSync("wrangler", ["d1", "execute", "meu-banco", modo, ...args], {
    encoding: "utf8",
    shell: process.platform === "win32", // wrangler.cmd; os argumentos são fixos
  });
  if (r.status !== 0) {
    console.error(`wrangler falhou (${r.status}): ${(r.stderr || r.stdout || r.error?.message || "").trim().slice(0, 500)}`);
    process.exit(1);
  }
  return r.stdout;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const modo = process.argv.slice(2).find((a) => a === "--local" || a === "--remote");
  if (!modo) {
    console.error("Informe --local ou --remote.");
    process.exit(1);
  }
  const existentes = {};
  for (const tabela of Object.keys(COLUNAS)) {
    const saida = d1(modo, "--json", "--command", `SELECT name FROM pragma_table_info('${tabela}')`);
    existentes[tabela] = JSON.parse(saida.slice(saida.indexOf("[")))[0]?.results?.map((c) => c.name) ?? [];
  }
  if (!existentes.accounts?.length) {
    console.error("Tabela accounts não existe: rode `pnpm db:local` ou `pnpm db:remote` antes (o schema.sql já traz as colunas).");
    process.exit(1);
  }
  d1(modo, "--command", TABELAS.join(" "));
  const sql = alteracoes(existentes);
  if (!sql.length) console.log("Nenhuma coluna a criar.");
  else {
    d1(modo, "--command", sql.join(" "));
    console.log("Colunas criadas:\n" + sql.join("\n"));
  }
}
