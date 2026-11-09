// Uso: pnpm --filter @meu-banco/worker importar:cashew <backup-do-cashew.sql> > cashew-import.sql
// Lê o backup (SQLite, só leitura) e imprime o SQL para `wrangler d1 execute meu-banco --remote --file=cashew-import.sql`.
import { DatabaseSync } from "node:sqlite";
import { validarLote, MAX_LOTE } from "@meu-banco/core";
import { converterCashew, sqlImportacao } from "./cashew.mjs";

const caminho = process.argv[2];
if (!caminho) { console.error("Informe o caminho do backup do Cashew."); process.exit(1); }
const db = new DatabaseSync(caminho, { readOnly: true });
const ler = (sql) => db.prepare(sql).all().map((r) => ({ ...r }));
const agora = new Date().toISOString();

const registros = converterCashew({
  categorias: ler('SELECT category_pk, name, income, colour, icon_name, main_category_pk, "order" FROM categories'),
  orcamentos: ler("SELECT budget_pk, name, amount, category_fks, archived FROM budgets"),
  objetivos: ler("SELECT objective_pk, type, name, amount, end_date, income FROM objectives"),
  transacoes: ler("SELECT transaction_pk, name, amount, note, category_fk, wallet_fk, date_created, objective_fk FROM transactions"),
  carteiras: ler("SELECT wallet_pk, name FROM wallets"),
}, agora);

// Valida em blocos do tamanho máximo do lote; o que o core rejeitar fica de fora e é listado no stderr.
const rejeitados = new Map();
for (let i = 0; i < registros.length; i += MAX_LOTE) {
  const lote = validarLote(registros.slice(i, i + MAX_LOTE), agora);
  if ("registros" in lote) for (const r of lote.rejeitados) rejeitados.set(r.indice + i, r.motivo);
}
for (const [i, motivo] of rejeitados) console.error(`Ignorado ${registros[i].tabela} ${registros[i].id}: ${motivo}`);
const validos = registros.filter((_, i) => !rejeitados.has(i));
process.stdout.write(sqlImportacao(validos, agora));
const porTabela = Object.entries(Object.groupBy(validos, (r) => r.tabela)).map(([t, l]) => `${t}: ${l.length}`).join(", ");
console.error(`${validos.length} registros (${porTabela}); ${rejeitados.size} ignorados.`);
