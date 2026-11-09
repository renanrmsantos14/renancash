// Conversão do backup do Cashew (drift/SQLite) para registros do Meu Banco. Funções puras; o CLI está em importar-cashew.mjs.
const TZ = "America/Sao_Paulo";
const id = (pk) => "cashew:" + pk;
const dataSP = (segundos) => new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(new Date(segundos * 1000));
const sem = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v != null && v !== "")); // tira opcionais vazios (0 fica)
const lista = (texto) => { try { const v = JSON.parse(texto ?? "[]"); return Array.isArray(v) ? v.map(String) : []; } catch { return []; } };

export function converterCashew({ categorias, orcamentos, objetivos, transacoes, carteiras }, agoraIso) {
  const reg = (tabela, pk, dados) => ({ tabela, id: id(pk), dados, updated_at: agoraIso, deleted_at: null });
  const carteira = new Map(carteiras.map((w) => [String(w.wallet_pk), w.name]));
  const proprias = transacoes.filter((t) => !String(t.transaction_pk).startsWith("mb:"));
  const soma = new Map();
  for (const t of proprias) if (t.objective_fk != null) soma.set(String(t.objective_fk), (soma.get(String(t.objective_fk)) || 0) + Number(t.amount));
  const progresso = (pk) => Math.round(Math.abs(soma.get(String(pk)) || 0) * 100) / 100;

  return [
    ...categorias.map((c) => reg("categorias", c.category_pk, sem({
      nome: c.name, tipo: c.income ? "receita" : "despesa", cor: c.colour, icone: c.icon_name,
      pai_id: c.main_category_pk != null ? id(c.main_category_pk) : null, ordem: Number(c.order ?? 0),
    }))),
    ...orcamentos.filter((b) => !b.archived).map((b) => reg("orcamentos", b.budget_pk, {
      nome: b.name, valor: Number(b.amount), categoria_ids: lista(b.category_fks).map(id), periodo: "mensal",
    })),
    ...objetivos.map((o) => Number(o.type) === 1
      ? reg("dividas", o.objective_pk, { tipo: "emprestimo", nome: o.name, sentido: o.income ? "me_devem" : "devo", valor_total: Number(o.amount), pago: progresso(o.objective_pk) })
      : reg("metas", o.objective_pk, sem({ nome: o.name, valor_alvo: Number(o.amount), valor_atual: progresso(o.objective_pk), prazo: o.end_date != null ? dataSP(Number(o.end_date)) : null }))),
    ...proprias.map((t) => reg("lancamentos", t.transaction_pk, sem({
      data: dataSP(Number(t.date_created)), descricao: t.name?.trim() || "Sem descrição", valor: Number(t.amount),
      categoria_id: t.category_fk != null ? id(t.category_fk) : null, carteira: carteira.get(String(t.wallet_fk)), nota: t.note?.trim(),
    }))),
  ];
}

const texto = (v) => (v == null ? "NULL" : "'" + String(v).replace(/'/g, "''") + "'");

// INSERT OR IGNORE: rodar de novo não duplica nem sobrescreve o que já foi editado no app.
export function sqlImportacao(registros, agoraIso) {
  const linhas = registros.map((r) => `(${texto(r.tabela)}, ${texto(r.id)}, ${texto(JSON.stringify(r.dados))}, ${texto(r.updated_at)}, NULL, ${texto(agoraIso)})`);
  const blocos = [];
  for (let i = 0; i < linhas.length; i += 200) {
    blocos.push(`INSERT OR IGNORE INTO registros (tabela, id, dados, updated_at, deleted_at, server_at) VALUES\n${linhas.slice(i, i + 200).join(",\n")};`);
  }
  return blocos.join("\n") + "\n";
}
