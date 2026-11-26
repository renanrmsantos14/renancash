// src/anotacoes.js — transação do banco candidata a uma anotação do MCP e a ligação automática (sem importar mcp.js nem iaAuto.js).
import { editadaNoApp } from "./espelho.js";
import { agoraTs, hojeSP } from "./app.js";
import { somarDias } from "./ciclo.js";

const DIAS_ANTES = 3; // o banco pode datar a compra um pouco antes do que foi dito
const DIAS_DEPOIS = 7;
const TOLERANCIA = 0.02; // 2% (compra no exterior, gorjeta); a exata vem primeiro

const sinalGasto = "CASE WHEN a.type = 'CREDIT' THEN t.amount > 0 ELSE t.amount < 0 END";

export async function candidatas(db, an) {
  const tol = Math.max(0.01, an.valor * TOLERANCIA);
  const { results } = await db.prepare(
    `SELECT t.id, t.date, t.description, t.merchant, t.contraparte, t.amount, t.status, a.name AS conta, e.dados AS app, e.deleted_at AS apagada
     FROM transactions t JOIN accounts a ON a.id = t.account_id
     LEFT JOIN espelho e ON e.tabela = 'transactions' AND e.pk = 'mb:' || t.id
     WHERE abs(abs(t.amount) - ?1) <= ?2 AND t.date BETWEEN ?3 AND ?4 AND t.scheduled = 0 AND (${sinalGasto}) = ?5
       AND t.id NOT IN (SELECT transacao_id FROM anotacoes WHERE transacao_id IS NOT NULL AND status IN ('vinculada', 'aplicada', 'automatica') AND id != ?6)
     ORDER BY abs(abs(t.amount) - ?1) > 0.005, abs(julianday(t.date) - julianday(?7)), t.date LIMIT 6`
  ).bind(an.valor, tol, somarDias(an.data, -DIAS_ANTES), somarDias(an.data, DIAS_DEPOIS), an.receita ? 0 : 1, an.id, an.data).all();
  return results.map((t) => {
    const app = t.app && t.apagada == null ? JSON.parse(t.app) : null;
    return {
      transacao_id: t.id, data: t.date, valor: Math.abs(t.amount), valor_exato: Math.abs(Math.abs(t.amount) - an.valor) < 0.005,
      texto_do_banco: t.description, estabelecimento: t.merchant || t.contraparte || null, conta: t.conta, pendente_no_banco: t.status === "PENDING",
      no_app: app ? { titulo: app.name, ja_editada: editadaNoApp(app) } : null,
      ...(t.apagada != null ? { apagada_no_app: true } : {}),
    };
  });
}

// Anotação pendente com exatamente 1 transação compatível (valor exato, postada, não editada no app) é ligada
// sozinha: status 'automatica' + decisão `pendente` em ia_aplicacoes, que aplicarPendentesIa grava como edição da linha `mb:`.
// Duas anotações para a mesma candidata, ou transação que a IA já decidiu/desfez, ficam `pendente` (o Claude confirma). Devolve quantas ligou.
export async function vincularAnotacoesIa(env) {
  const db = env.DB;
  const { results } = await db.prepare("SELECT * FROM anotacoes WHERE status = 'pendente' AND data >= ?1").bind(somarDias(hojeSP(), -30)).all();
  const achadas = [];
  (await Promise.all(results.map(async (an) => [an, await candidatas(db, an)]))).forEach(([an, c]) => {
    const [t] = c;
    if (c.length === 1 && t.valor_exato && !t.pendente_no_banco && !t.apagada_no_app && !t.no_app?.ja_editada) achadas.push({ an, tx: t.transacao_id });
  });
  if (!achadas.length) return 0;
  const { results: fechadas } = await db.prepare("SELECT tx_id FROM ia_aplicacoes WHERE status IN ('aplicada', 'desfeita', 'descartada') AND tx_id IN (SELECT value FROM json_each(?1))")
    .bind(JSON.stringify(achadas.map((x) => x.tx))).all();
  const bloqueadas = new Set(fechadas.map((r) => r.tx_id));
  const livres = achadas.filter((x) => !bloqueadas.has(x.tx) && achadas.filter((y) => y.tx === x.tx).length === 1);
  if (!livres.length) return 0;
  const ts = agoraTs();
  // A transição é condicional ao status (o Claude pode confirmar no mesmo instante): a decisão só entra se a anotação ainda está
  // `pendente` e a anotação só muda se a decisão entrou.
  await db.batch(livres.flatMap(({ an, tx }) => [
    db.prepare(
      `INSERT INTO ia_aplicacoes (tx_id, origem, chave, sugestao, confianca, status, criado_em, atualizado_em)
       SELECT ?1, 'anotacao', ?2, ?3, 1, 'pendente', ?4, ?4 WHERE EXISTS (SELECT 1 FROM anotacoes WHERE id = ?2 AND status = 'pendente')
       ON CONFLICT(tx_id) DO UPDATE SET origem = excluded.origem, chave = excluded.chave, sugestao = excluded.sugestao, confianca = 1, status = 'pendente',
         anterior = NULL, depois = NULL, acerto = NULL, aplicado_em = NULL, atualizado_em = excluded.atualizado_em
       WHERE ia_aplicacoes.status IN ('pendente', 'sombra')`
    ).bind(tx, an.id, JSON.stringify({ name: an.titulo || an.descricao, category_fk: an.categoria ?? null, sub_category_fk: an.subcategoria ?? null, note: an.nota ?? null }), ts),
    db.prepare("UPDATE anotacoes SET status = 'automatica', transacao_id = ?1, atualizada = ?2 WHERE id = ?3 AND status = 'pendente' AND EXISTS (SELECT 1 FROM ia_aplicacoes WHERE tx_id = ?1 AND origem = 'anotacao' AND chave = ?3 AND status = 'pendente')")
      .bind(tx, ts, an.id),
  ]));
  return livres.length;
}
