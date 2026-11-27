// Contador de saúde da IA (tabela saude_ia, um balde por hora UTC). Fica fora de ia.js para o check (saude.js) ler sem ciclo de import.
// Nunca derruba quem chama: sem DB (testes) ou com erro de gravação, só registra no console.

export const horaUtc = (d = new Date()) => d.toISOString().slice(0, 13);

// tipo: "ok" | "vazia" | "erro". `erro` leva o tipo e o começo da mensagem (nunca prompt, descrição ou valor).
export async function registrarIa(env, tipo, erro = null, agora = new Date()) {
  if (!env?.DB) return;
  try {
    await env.DB.prepare(
      `INSERT INTO saude_ia (hora, ok, vazia, erro, ultimo_erro, atualizado) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
       ON CONFLICT(hora) DO UPDATE SET ok = ok + ?2, vazia = vazia + ?3, erro = erro + ?4, ultimo_erro = COALESCE(?5, ultimo_erro), atualizado = ?6`,
    ).bind(horaUtc(agora), tipo === "ok" ? 1 : 0, tipo === "vazia" ? 1 : 0, tipo === "erro" ? 1 : 0, erro ? String(erro).slice(0, 140) : null, agora.toISOString()).run();
  } catch (e) {
    console.error("Contador da IA não gravou:", e?.message || e);
  }
}

// Soma das últimas `horas` horas: { ok, vazia, erro, total, ultimo_erro }.
export async function resumoIa(db, agora = new Date(), horas = 24) {
  const desde = horaUtc(new Date(agora.getTime() - horas * 3600_000));
  const r = await db.prepare("SELECT COALESCE(SUM(ok),0) AS ok, COALESCE(SUM(vazia),0) AS vazia, COALESCE(SUM(erro),0) AS erro FROM saude_ia WHERE hora >= ?1").bind(desde).first();
  const ultimo = await db.prepare("SELECT ultimo_erro FROM saude_ia WHERE hora >= ?1 AND ultimo_erro IS NOT NULL ORDER BY hora DESC LIMIT 1").bind(desde).first("ultimo_erro");
  return { ok: r.ok, vazia: r.vazia, erro: r.erro, total: r.ok + r.vazia + r.erro, ultimo_erro: ultimo ?? null };
}
