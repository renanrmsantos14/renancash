// Alerta de saúde: um check diário (cron 08:00 de São Paulo) olha Pluggy, IA, Espelho e o próprio cron, grava o resultado
// em snapshots e, havendo problema, manda 1 push com a causa e a ação (no máximo 1 vez por dia por conjunto de problemas).
// Quando tudo volta ao normal, manda "voltou ao normal". Nada aqui chama a API do Pluggy: lê só o que o Worker já gravou.
import { MODELO } from "./ia.js";
import { resumoIa } from "./iaSaude.js";
import { espelhoLigado, hubDo } from "./espelho.js";
import { PROBLEMA } from "./mapa.js";
import { stmtAlertas } from "./alertas.js";
import { diaSP } from "./app.js";
import { somarDias } from "./ciclo.js";

export const CRON_SAUDE = "0 11 * * *"; // UTC; 08:00 em São Paulo (sem horário de verão). Mudou aqui, mude no wrangler.toml.
export const CHAVE_RESULTADO = "saude:resultado";
export const CHAVE_BATIMENTO = "saude:batimento";

export const LIMITES = {
  sync_atencao_h: 12, // o cron sincroniza de 3 em 3 h
  sync_erro_h: 30,
  item_atencao_h: 72, // conexão sem atualizar
  conta_sem_tx_dias: 7,
  conta_historico_min: 8, // transações nos 90 dias antes da janela para a conta contar como "movimentada"
  ia_amostra_min: 5,
  ia_erro_atencao: 0.2,
  ia_erro_erro: 0.5,
  ia_vazia: 0.9,
  espelho_escrita_dias: 3,
  cron_sync_atencao_h: 6,
  cron_sync_erro_h: 12,
  batimento_h: 26, // o check é diário; passou disso, atrasou
  sonda_ms: 15000,
};

const ORDEM = { ok: 0, atencao: 1, erro: 2 };
const pior = (lista) => lista.reduce((p, s) => (ORDEM[s] > ORDEM[p] ? s : p), "ok");
const horasDesde = (iso, agora) => (iso ? (agora.getTime() - new Date(iso).getTime()) / 3600_000 : null);
const fmtH = (h) => (h < 48 ? `${Math.round(h)} h` : `${Math.round(h / 24)} dias`);

function item(id, nome, detalhes, acao) {
  const status = pior(detalhes.map((d) => d.status));
  const problemas = detalhes.filter((d) => d.status !== "ok");
  const resumo = problemas.length ? problemas.map((d) => d.texto).join("; ") : detalhes[0]?.texto ?? "Tudo certo";
  return { id, nome, status, resumo, detalhes, acao: status === "ok" ? null : acao };
}

// ---------- Pluggy ----------

async function verificarPluggy(env, agora, L) {
  const db = env.DB;
  const d = [];
  const ultimo = await db.prepare("SELECT MAX(finished_at) AS f FROM sync_log WHERE ok = 1").first("f");
  const h = horasDesde(ultimo, agora);
  if (h === null) d.push({ nome: "Última sincronização", status: "atencao", texto: "Nenhuma sincronização com sucesso registrada" });
  else d.push({ nome: "Última sincronização", status: h > L.sync_erro_h ? "erro" : h > L.sync_atencao_h ? "atencao" : "ok", texto: h > L.sync_atencao_h ? `Última sincronização com sucesso há ${fmtH(h)}` : `Sincronizou há ${fmtH(Math.max(h, 1))}` });
  const falha = await db.prepare("SELECT message, finished_at FROM sync_log WHERE ok = 0 AND finished_at > COALESCE(?1, '') ORDER BY finished_at DESC LIMIT 1").bind(ultimo).first();
  if (falha) d.push({ nome: "Falha recente", status: "atencao", texto: "A última sincronização falhou e ainda não houve outra com sucesso" });

  const { results: itens } = await db.prepare("SELECT id, conector, status, atualizado FROM pluggy_items WHERE removido IS NULL ORDER BY criado").all();
  for (const it of itens) {
    const nome = it.conector || "Conexão " + it.id.slice(0, 6);
    const ha = horasDesde(it.atualizado, agora);
    if (PROBLEMA.test(it.status || "")) d.push({ nome, status: "erro", texto: `${nome} pede login de novo (${it.status})` });
    else if (/ERROR|OUTDATED/.test(it.status || "")) d.push({ nome, status: "atencao", texto: `${nome} com erro no banco (${it.status})` });
    else if (ha !== null && ha > L.item_atencao_h) d.push({ nome, status: "atencao", texto: `${nome} sem atualizar há ${fmtH(ha)}` });
    else d.push({ nome, status: "ok", texto: `${nome} em dia` });
  }

  const hoje = diaSP.format(agora);
  const { results: contas } = await db.prepare(
    `SELECT a.name, a.bank,
       SUM(CASE WHEN t.date >= ?1 THEN 1 ELSE 0 END) AS recentes,
       SUM(CASE WHEN t.date < ?1 AND t.date >= ?2 THEN 1 ELSE 0 END) AS antes
     FROM accounts a LEFT JOIN transactions t ON t.account_id = a.id AND t.scheduled = 0
     WHERE a.item_id IS NULL OR a.item_id NOT IN (SELECT id FROM pluggy_items WHERE removido IS NOT NULL)
     GROUP BY a.id`,
  ).bind(somarDias(hoje, -L.conta_sem_tx_dias), somarDias(hoje, -90 - L.conta_sem_tx_dias)).all();
  for (const c of contas) {
    if (c.recentes === 0 && c.antes >= L.conta_historico_min) {
      const nome = [c.bank, c.name].filter(Boolean).join(" ") || "Conta";
      d.push({ nome, status: "atencao", texto: `${nome} sem movimento novo há mais de ${L.conta_sem_tx_dias} dias (costuma ter)` });
    }
  }
  return item("pluggy", "Bancos (Pluggy)", d, "Reconecte o banco em Meu Banco > Conexões; se estiver tudo certo, toque em Atualizar agora.");
}

// ---------- IA ----------

async function sondarModelo(env, L) {
  let timer;
  const limite = new Promise((_, rej) => (timer = setTimeout(() => rej(new Error("timeout")), L.sonda_ms)));
  try {
    const r = await Promise.race([env.AI.run(MODELO, { messages: [{ role: "user", content: "Responda apenas: ok" }], max_tokens: 5 }), limite]);
    return typeof r?.response === "string" && r.response.trim() ? { ok: true } : { ok: false, motivo: "respondeu vazio" };
  } catch (e) {
    const msg = String(e?.message || e);
    return { ok: false, motivo: /no such model|not found|does not exist|deprecat|5007|1003/i.test(msg) ? "o modelo saiu do catálogo" : msg.slice(0, 80) };
  } finally {
    clearTimeout(timer);
  }
}

async function verificarIa(env, agora, L) {
  const d = [];
  if (!env.AI) {
    d.push({ nome: "Modelo", status: "atencao", texto: "A IA não está ligada neste Worker" });
  } else {
    const s = await sondarModelo(env, L);
    d.push(s.ok
      ? { nome: "Modelo", status: "ok", texto: "O modelo existe e responde" }
      : { nome: "Modelo", status: "erro", texto: `O modelo da IA não responde (${s.motivo})` });
  }
  const r = await resumoIa(env.DB, agora, 24);
  if (r.total >= L.ia_amostra_min) {
    const taxaErro = r.erro / r.total;
    const taxaVazia = r.vazia / r.total;
    const pct = (x) => Math.round(x * 100) + "%";
    if (taxaErro >= L.ia_erro_atencao) {
      d.push({ nome: "Erros nas últimas 24 h", status: taxaErro >= L.ia_erro_erro ? "erro" : "atencao", texto: `${pct(taxaErro)} das chamadas da IA falharam em 24 h (${r.erro} de ${r.total})${r.ultimo_erro ? ": " + r.ultimo_erro : ""}` });
    } else d.push({ nome: "Erros nas últimas 24 h", status: "ok", texto: `${r.erro} falha(s) em ${r.total} chamadas nas últimas 24 h` });
    if (r.total - r.erro >= L.ia_amostra_min && taxaVazia >= L.ia_vazia) d.push({ nome: "Respostas vazias", status: "atencao", texto: `${pct(taxaVazia)} das respostas da IA vieram sem sugestão em 24 h` });
  } else d.push({ nome: "Erros nas últimas 24 h", status: "ok", texto: r.total ? `${r.total} chamada(s) em 24 h, sem problema` : "Sem chamadas da IA em 24 h" });
  return item("ia", "IA de categorias", d, "Confira a constante MODELO em ia.js contra o catálogo do Workers AI e publique de novo.");
}

// ---------- Espelho ----------

async function verificarEspelho(env, agora, L) {
  if (!espelhoLigado(env)) return item("espelho", "Espelho", [{ nome: "Espelho", status: "ok", texto: "Espelho desligado neste ambiente" }], null);
  const d = [];
  const { results: tabelas } = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('espelho', 'espelho_meta')").all();
  const faltam = ["espelho", "espelho_meta"].filter((t) => !tabelas.some((x) => x.name === t));
  if (faltam.length) d.push({ nome: "Tabelas", status: "erro", texto: `Faltam as tabelas ${faltam.join(" e ")} no banco` });
  else d.push({ nome: "Tabelas", status: "ok", texto: "Tabelas do espelho presentes" });

  try {
    if (!env.ESPELHO_HUB) throw new Error("sem binding");
    const r = await Promise.race([hubDo(env).fetch("https://hub/saude"), new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), 5000))]);
    if (r.status !== 200) throw new Error("HTTP " + r.status);
    d.push({ nome: "Durable Object", status: "ok", texto: "O EspelhoHub responde" });
  } catch (e) {
    d.push({ nome: "Durable Object", status: "erro", texto: `O EspelhoHub não responde (${String(e?.message || e).slice(0, 60)})` });
  }

  if (!faltam.length) {
    const ultima = await env.DB.prepare("SELECT MAX(server_at) AS m FROM espelho").first("m");
    const h = horasDesde(ultima, agora);
    if (h === null) d.push({ nome: "Última escrita", status: "atencao", texto: "O espelho ainda não recebeu nenhuma linha" });
    else if (h > L.espelho_escrita_dias * 24) d.push({ nome: "Última escrita", status: "atencao", texto: `Nenhuma escrita no espelho há ${fmtH(h)}` });
    else d.push({ nome: "Última escrita", status: "ok", texto: `Última escrita há ${fmtH(Math.max(h, 1))}` });
  }
  return item("espelho", "Espelho (sincronia entre aparelhos)", d, "Veja os logs do Worker (wrangler tail); se faltar tabela, rode a migração.");
}

// ---------- Cron e Worker ----------

async function verificarCron(env, agora, L, anterior) {
  const d = [];
  const ultimoSync = await env.DB.prepare("SELECT MAX(started_at) AS s FROM sync_log WHERE origem = 'cron'").first("s");
  const h = horasDesde(ultimoSync, agora);
  if (h === null) d.push({ nome: "Cron de sincronização", status: "atencao", texto: "O cron de sincronização ainda não rodou" });
  else if (h > L.cron_sync_atencao_h) d.push({ nome: "Cron de sincronização", status: h > L.cron_sync_erro_h ? "erro" : "atencao", texto: `O cron de sincronização não roda há ${fmtH(h)}` });
  else d.push({ nome: "Cron de sincronização", status: "ok", texto: `Rodou há ${fmtH(Math.max(h, 1))}` });
  const hb = horasDesde(anterior?.verificado_em, agora);
  if (hb !== null && hb > L.batimento_h) d.push({ nome: "Check diário", status: "atencao", texto: `O check diário não rodou nas últimas ${fmtH(hb)}` });
  else d.push({ nome: "Check diário", status: "ok", texto: "O check diário está em dia" });
  return item("cron", "Cron e Worker", d, "Confira os Cron Triggers do Worker no painel da Cloudflare e publique de novo.");
}

// ---------- Orquestração ----------

const lerJson = async (db, chave) => {
  const t = await db.prepare("SELECT data FROM snapshots WHERE key = ?1").bind(chave).first("data");
  try { return t ? JSON.parse(t) : null; } catch { return null; }
};
const gravarJson = (db, chave, valor, ts) =>
  db.prepare("INSERT INTO snapshots (key, data, updated_at) VALUES (?1, ?2, ?3) ON CONFLICT(key) DO UPDATE SET data = ?2, updated_at = ?3").bind(chave, JSON.stringify(valor), ts).run();

export async function verificar(env, agora = new Date(), anterior = null, limites = LIMITES) {
  const secoes = [
    ["pluggy", "Bancos (Pluggy)", () => verificarPluggy(env, agora, limites)],
    ["ia", "IA de categorias", () => verificarIa(env, agora, limites)],
    ["espelho", "Espelho", () => verificarEspelho(env, agora, limites)],
    ["cron", "Cron e Worker", () => verificarCron(env, agora, limites, anterior)],
  ];
  const itens = [];
  for (const [id, nome, fn] of secoes) {
    try {
      itens.push(await fn());
    } catch (e) {
      console.error("Check de saúde falhou em", id, e?.message || e);
      itens.push(item(id, nome, [{ nome, status: "erro", texto: `Não consegui verificar (${String(e?.message || e).slice(0, 80)})` }], "Veja os logs do Worker."));
    }
  }
  return { verificado_em: agora.toISOString(), status: pior(itens.map((i) => i.status)), itens };
}

// O assunto do push: assinatura = quais itens estão em qual estado (o texto muda de hora em hora e não conta).
const assinatura = (r) => r.itens.filter((i) => i.status !== "ok").map((i) => `${i.id}-${i.status}`).join("_");

function montarPush(r) {
  const ruins = r.itens.filter((i) => i.status !== "ok");
  const titulo = ruins.length === 1 ? `RenanCash: ${ruins[0].nome} precisa de atenção` : `RenanCash: ${ruins.length} coisas precisam de atenção`;
  const corpo = ruins.map((i) => `${i.nome}: ${i.resumo}. O que fazer: ${i.acao}`).join("\n");
  return { titulo: titulo.slice(0, 80), corpo: corpo.slice(0, 600) };
}

// Roda o check, grava resultado e batimento e manda o push (se houver). `enviarPendentes` vem do index.js (evita ciclo de import).
// Devolve { resultado, push: "problema" | "voltou" | "repetido" | "nenhum" }.
export async function rodarSaude(env, { agora = new Date(), enviarPendentes } = {}) {
  const anterior = await lerJson(env.DB, CHAVE_RESULTADO);
  const resultado = await verificar(env, agora, anterior);
  const ts = agora.toISOString();
  await gravarJson(env.DB, CHAVE_RESULTADO, resultado, ts);
  await gravarJson(env.DB, CHAVE_BATIMENTO, { em: ts }, ts);
  // Limpeza do contador: falhar (ex.: tabela ainda não migrada) não pode derrubar o check nem o push.
  await env.DB.prepare("DELETE FROM saude_ia WHERE hora < ?1").bind(new Date(agora.getTime() - 8 * 86400_000).toISOString().slice(0, 13)).run().catch((e) => console.error("Limpeza de saude_ia falhou", e?.message || e));

  const dia = diaSP.format(agora);
  let alerta = null;
  let push = "nenhum";
  if (resultado.status !== "ok") {
    alerta = { chave: `saude:${dia}:${assinatura(resultado)}`, ...montarPush(resultado) };
    push = "problema";
  } else if (anterior && anterior.status !== "ok") {
    alerta = { chave: `saude:ok:${dia}`, titulo: "RenanCash voltou ao normal", corpo: "Tudo certo de novo: bancos, IA, espelho e cron estão funcionando." };
    push = "voltou";
  }
  if (alerta) {
    const r = await stmtAlertas(env.DB, [alerta], agora.getTime())[0].run();
    if (!r.meta?.changes) push = "repetido";
    else if (enviarPendentes) await enviarPendentes();
  }
  return { resultado, push };
}

// Último resultado + batimento para o app e para o MCP. `atrasado` = o check diário não rodou nas últimas 26 h.
export async function lerSaude(env, agora = new Date(), limites = LIMITES) {
  const resultado = await lerJson(env.DB, CHAVE_RESULTADO);
  const batimento = (await lerJson(env.DB, CHAVE_BATIMENTO))?.em ?? null;
  const h = horasDesde(batimento, agora);
  return { ...(resultado ?? { verificado_em: null, status: "desconhecido", itens: [] }), batimento_em: batimento, atrasado: batimento === null ? false : h > limites.batimento_h };
}
