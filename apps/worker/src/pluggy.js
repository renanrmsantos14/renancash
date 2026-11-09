// Conexões do Pluggy (items) guardadas no D1.
import { hashToken } from "./app.js";

export const REGEX_ITEM = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Ids ativos. Com a tabela vazia (primeira vez), copia o secret PLUGGY_ITEM_IDS; depois o secret é ignorado.
export async function idsConexoes(db, env, agoraIso) {
  if (!(await db.prepare("SELECT count(*) AS n FROM pluggy_items").first("n"))) {
    for (const id of (env.PLUGGY_ITEM_IDS || "").split(",").map((s) => s.trim()).filter(Boolean)) await registrarItem(db, id, agoraIso);
  }
  const { results } = await db.prepare("SELECT id FROM pluggy_items WHERE removido IS NULL ORDER BY criado, id").all();
  return results.map((r) => r.id);
}

export function registrarItem(db, id, agoraIso) {
  return db.prepare("INSERT INTO pluggy_items (id, criado) VALUES (?1, ?2) ON CONFLICT(id) DO UPDATE SET removido = NULL").bind(id, agoraIso).run();
}

export function removerItem(db, id, agoraIso) {
  return db.prepare("UPDATE pluggy_items SET removido = ?2 WHERE id = ?1").bind(id, agoraIso).run();
}

export function atualizarStatus(db, item, agoraIso) {
  return db.prepare("UPDATE pluggy_items SET status = ?2, conector = ?3, atualizado = ?4 WHERE id = ?1")
    .bind(item.id, item.status ?? null, item.connector?.name ?? null, agoraIso).run();
}

const SINCRONIZAR = new Set(["item/updated", "item/error", "item/waiting_user_input", "item/login_succeeded"]);

export function acaoWebhook(ev) {
  if (!ev || typeof ev.itemId !== "string" || !REGEX_ITEM.test(ev.itemId)) return null;
  if (ev.event === "item/created") return "registrar";
  if (ev.event === "item/deleted") return "remover";
  return SINCRONIZAR.has(ev.event) ? "sincronizar" : null;
}

// Compara os SHA-256 (mesmo tamanho), não as strings. Sem secret configurado, nada passa.
export async function webhookValido(request, url, env) {
  const esperado = env.PLUGGY_WEBHOOK_SECRET;
  const recebido = request.headers.get("x-webhook-secret") || url.searchParams.get("s");
  if (!esperado || !recebido) return false;
  return (await hashToken(recebido)) === (await hashToken(esperado));
}
