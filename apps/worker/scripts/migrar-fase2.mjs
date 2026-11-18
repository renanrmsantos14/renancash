// Aplica scripts/migrar-fase2.sql (accounts.closing_date) só se a coluna ainda não existir; pode ser repetido.
// Uso: pnpm --filter @meu-banco/worker migrar:fase2 -- --local   (ou --remote)
// Rode ANTES de publicar o Worker: o código novo lê accounts.closing_date.
import { spawnSync } from "node:child_process";

const modo = process.argv.slice(2).find((a) => a === "--local" || a === "--remote");
if (!modo) {
  console.error("Informe --local ou --remote.");
  process.exit(1);
}

function d1(...args) {
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

const saida = d1("--json", "--command", "SELECT name FROM pragma_table_info('accounts')");
const colunas = JSON.parse(saida.slice(saida.indexOf("[")))[0]?.results?.map((c) => c.name) ?? [];
if (!colunas.length) {
  console.error("Tabela accounts não existe: rode `pnpm db:local` ou `pnpm db:remote` antes (o schema.sql já traz a coluna).");
  process.exit(1);
}
if (colunas.includes("closing_date")) {
  console.log("accounts.closing_date já existe; nada a fazer.");
} else {
  d1("--file=scripts/migrar-fase2.sql");
  console.log("accounts.closing_date criada.");
}
