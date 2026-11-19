// Pull do app: dados do banco, ciclo e avisos. A escrita do usuário é só pelo espelho (/api/espelho).
import { inicioDaJanela } from "@meu-banco/core";
import { hashToken, tokenDoCabecalho } from "./app.js";
import { CHAVE_HISTORICO, serieMensal } from "./historico.js";

export const USO_TOKEN_MS = 60 * 1000; // ultimo_uso é gravado no máximo 1 vez por minuto
export const INTERVALO_ATUALIZAR_MS = 5 * 60 * 1000;

export async function autenticarAparelho(request, db, agoraIso) {
  const token = tokenDoCabecalho(request.headers.get("authorization"));
  if (!token) return null;
  const reg = await db.prepare("SELECT id FROM app_tokens WHERE hash = ?1 AND revogado IS NULL").bind(await hashToken(token)).first();
  if (!reg) return null;
  await db.prepare("UPDATE app_tokens SET ultimo_uso = ?1 WHERE id = ?2 AND (ultimo_uso IS NULL OR ultimo_uso < ?3)")
    .bind(agoraIso, reg.id, new Date(Date.parse(agoraIso) - USO_TOKEN_MS).toISOString()).run();
  return reg.id;
}

const json = (texto) => (texto == null ? null : JSON.parse(texto));

// desde = null → leitura completa (sem exclusões). Senão, tudo que mudou desde (desde − 2 min).
export async function puxar(db, desde, agoraIso, extras = {}) {
  const janela = inicioDaJanela(desde);
  const [contas, transacoes, registros, pendentes, config, snapshots, ultimaSync, removidas] = await db.batch([
    db.prepare("SELECT id, type, subtype, name, bank, balance, credit_limit, available_limit, due_date, closing_date, minimum_payment, overdraft_limit, overdraft_used, auto_invested, item_id, updated_at, (item_id IN (SELECT id FROM pluggy_items WHERE removido IS NOT NULL)) AS removida FROM accounts ORDER BY type, name"),
    db.prepare("SELECT * FROM transactions WHERE ?1 IS NULL OR updated_at > ?1 ORDER BY date, id").bind(janela),
    db.prepare("SELECT tabela, id, dados, updated_at, deleted_at FROM registros WHERE (?1 IS NULL AND deleted_at IS NULL) OR server_at > ?1 ORDER BY server_at").bind(janela),
    db.prepare("SELECT id FROM transactions WHERE status = 'PENDING' ORDER BY id"),
    db.prepare("SELECT chave, valor FROM config"),
    db.prepare("SELECT key, data FROM snapshots WHERE key = 'avisos' OR key LIKE 'faturas:%' OR key LIKE 'investimentos:%' OR key = 'investimentos_mensal' ORDER BY key"),
    db.prepare("SELECT MAX(finished_at) AS f FROM sync_log WHERE ok = 1"),
    // Apagadas no banco: no pull completo, as dos últimos 90 dias (o app pode ter guardado antes de reinstalar).
    db.prepare("SELECT id FROM transacoes_removidas WHERE removida_em > COALESCE(?1, ?2) ORDER BY id").bind(janela, new Date(Date.parse(agoraIso) - 90 * 86400000).toISOString()),
  ]);
  const faturas = {};
  let avisos = [];
  let investimentosMensal = []; // um retrato por mês (aplicações do Inter e do Santander juntas)
  const investimentos = []; // lista completa a cada pull (não segue o `desde`)
  for (const s of snapshots.results) {
    if (s.key === "avisos") avisos = json(s.data) || [];
    else if (s.key === CHAVE_HISTORICO) investimentosMensal = serieMensal(json(s.data));
    else if (s.key.startsWith("investimentos:")) investimentos.push(...(json(s.data) || []));
    else faturas[s.key.slice("faturas:".length)] = json(s.data);
  }
  return {
    agora: agoraIso,
    completo: janela === null,
    contas: contas.results,
    transacoes: transacoes.results,
    registros: registros.results.map((r) => ({ ...r, dados: json(r.dados) })),
    pendentes: pendentes.results.map((p) => p.id),
    removidas: removidas.results.map((r) => r.id),
    config: Object.fromEntries(config.results.map((c) => [c.chave, c.valor])),
    faturas,
    avisos,
    investimentos,
    investimentos_mensal: investimentosMensal,
    sincronizado_em: ultimaSync.results[0]?.f ?? null,
    ...extras,
  };
}

export function esperaAtualizar(ultimoIso, agoraMs) {
  return ultimoIso ? Math.max(0, Date.parse(ultimoIso) + INTERVALO_ATUALIZAR_MS - agoraMs) : 0;
}
