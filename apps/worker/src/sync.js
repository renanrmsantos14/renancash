// Sincronização em duas vias com os apps: pull (dados do banco + registros do usuário) e push (registros, LWW).
import { validarLote, inicioDaJanela } from "@meu-banco/core";
import { hashToken, tokenDoCabecalho } from "./app.js";

export const USO_TOKEN_MS = 60 * 1000; // ultimo_uso é gravado no máximo 1 vez por minuto
export const INTERVALO_ATUALIZAR_MS = 30 * 60 * 1000;

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
export async function puxar(db, desde, agoraIso) {
  const janela = inicioDaJanela(desde);
  const [contas, transacoes, registros, pendentes, config, snapshots] = await db.batch([
    db.prepare("SELECT id, type, name, bank, balance, credit_limit, available_limit, due_date, item_id, updated_at FROM accounts ORDER BY type, name"),
    db.prepare("SELECT * FROM transactions WHERE ?1 IS NULL OR updated_at > ?1 ORDER BY date, id").bind(janela),
    db.prepare("SELECT tabela, id, dados, updated_at, deleted_at FROM registros WHERE (?1 IS NULL AND deleted_at IS NULL) OR server_at > ?1 ORDER BY server_at").bind(janela),
    db.prepare("SELECT id FROM transactions WHERE status = 'PENDING' ORDER BY id"),
    db.prepare("SELECT chave, valor FROM config"),
    db.prepare("SELECT key, data FROM snapshots WHERE key = 'avisos' OR key LIKE 'faturas:%'"),
  ]);
  const faturas = {};
  let avisos = [];
  for (const s of snapshots.results) {
    if (s.key === "avisos") avisos = json(s.data) || [];
    else faturas[s.key.slice("faturas:".length)] = json(s.data);
  }
  return {
    agora: agoraIso,
    completo: janela === null,
    contas: contas.results,
    transacoes: transacoes.results,
    registros: registros.results.map((r) => ({ ...r, dados: json(r.dados) })),
    pendentes: pendentes.results.map((p) => p.id),
    config: Object.fromEntries(config.results.map((c) => [c.chave, c.valor])),
    faturas,
    avisos,
  };
}

// LWW no próprio SQL: só sobrescreve quando o updated_at recebido é estritamente maior.
// `WHERE true` desfaz a ambiguidade do parser do SQLite entre ON CONFLICT e a junção do SELECT.
const SQL_ENVIAR =
  "INSERT INTO registros (tabela, id, dados, updated_at, deleted_at, server_at) " +
  "SELECT json_extract(value, '$.tabela'), json_extract(value, '$.id'), json_extract(value, '$.dados'), json_extract(value, '$.updated_at'), json_extract(value, '$.deleted_at'), ?2 " +
  "FROM json_each(?1) WHERE true " +
  "ON CONFLICT(tabela, id) DO UPDATE SET dados = excluded.dados, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at, server_at = excluded.server_at " +
  "WHERE excluded.updated_at > registros.updated_at";

export async function enviar(db, corpo, agoraIso) {
  const lote = validarLote(corpo?.registros, agoraIso);
  if ("erro" in lote) return { status: 400, corpo: { erro: lote.erro } };
  if (lote.registros.length) await db.prepare(SQL_ENVIAR).bind(JSON.stringify(lote.registros), agoraIso).run();
  return { status: 200, corpo: { ok: true, aceitos: lote.registros.length, rejeitados: lote.rejeitados, agora: agoraIso } };
}

export function esperaAtualizar(ultimoIso, agoraMs) {
  return ultimoIso ? Math.max(0, Date.parse(ultimoIso) + INTERVALO_ATUALIZAR_MS - agoraMs) : 0;
}
