// Conexões do Pluggy (items) guardadas no D1.
import { hashToken } from "./app.js";
import { PROBLEMA } from "./mapa.js";

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

const REMOVIDOS = "SELECT id FROM pluggy_items WHERE removido IS NOT NULL";

// Contas de conexão removida continuam no banco (as transações antigas dependem do tipo e do banco delas para o
// ciclo e para o sinal no app), mas sem saldo; faturas, investimentos e avisos dessa conexão somem.
// Roda ao remover e de novo no fim de cada sincronização (uma que estava em andamento pode ter regravado os dados).
export async function limparRemovidas(db) {
  await db.batch([
    db.prepare(`UPDATE accounts SET balance = 0, available_limit = NULL WHERE item_id IN (${REMOVIDOS}) AND balance IS NOT 0`),
    db.prepare(`DELETE FROM snapshots WHERE key IN (SELECT 'investimentos:' || id FROM pluggy_items WHERE removido IS NOT NULL)
      OR key IN (SELECT 'faturas:' || id FROM accounts WHERE item_id IN (${REMOVIDOS}))`),
  ]);
  const bruto = await db.prepare("SELECT data FROM snapshots WHERE key = 'avisos'").first("data");
  const avisos = bruto ? JSON.parse(bruto) : [];
  if (!Array.isArray(avisos) || !avisos.length) return;
  const fora = new Set((await db.prepare(REMOVIDOS).all()).results.map((r) => r.id));
  const restantes = avisos.filter((a) => !fora.has(a?.item_id));
  if (restantes.length !== avisos.length) {
    await db.prepare("UPDATE snapshots SET data = ?1 WHERE key = 'avisos'").bind(JSON.stringify(restantes)).run();
  }
}

// Conexão removida (pelo app ou pelo Pluggy): sai das sincronizações. As transações ficam, como histórico.
export async function esquecerItem(db, id, agoraIso) {
  await db.prepare("UPDATE pluggy_items SET removido = ?2 WHERE id = ?1").bind(id, agoraIso).run();
  await limparRemovidas(db);
}

// Conexões ativas, cada uma com o banco, o status no Pluggy e as contas (tela "Contas conectadas" do app).
// precisaReconectar segue a mesma regra dos avisos (PROBLEMA): o app só mostra.
export async function listarConexoes(db, env, agoraIso) {
  await idsConexoes(db, env, agoraIso); // instalação nova: copia as conexões do secret
  const [itens, contas] = await db.batch([
    db.prepare("SELECT id, conector, status, criado, atualizado, proximo_sync, consentimento_expira FROM pluggy_items WHERE removido IS NULL ORDER BY criado, id"),
    db.prepare(`SELECT id, item_id, type, subtype, name, bank, balance FROM accounts WHERE item_id IS NOT NULL AND item_id NOT IN (${REMOVIDOS}) ORDER BY type, name`),
  ]);
  const porItem = new Map();
  for (const { item_id, ...c } of contas.results) porItem.set(item_id, [...(porItem.get(item_id) ?? []), c]);
  return itens.results.map((i) => {
    const daConexao = porItem.get(i.id) ?? [];
    return {
      id: i.id,
      banco: i.conector ?? daConexao[0]?.bank ?? null,
      status: i.status ?? null,
      precisaReconectar: PROBLEMA.test(i.status ?? ""),
      criado: i.criado ?? null,
      atualizado: i.atualizado ?? null,
      proximoSync: i.proximo_sync ?? null,
      consentimentoExpira: i.consentimento_expira ?? null,
      contas: daConexao,
    };
  });
}

export function atualizarStatus(db, item, agoraIso) {
  return db.prepare("UPDATE pluggy_items SET status = ?2, conector = ?3, atualizado = ?4, proximo_sync = ?5, consentimento_expira = ?6 WHERE id = ?1")
    .bind(item.id, item.status ?? null, item.connector?.name ?? null, agoraIso, item.nextAutoSyncAt ?? null, item.consentExpiresAt ?? null).run();
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
