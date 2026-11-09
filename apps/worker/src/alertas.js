// src/alertas.js — quais alertas gerar (funções puras). Chave única por alerta evita repetir.
import { categoriaEfetiva, contextoDeRegistros } from "@meu-banco/core";
import { valorGasto, traduzir, naoEhGasto } from "../public/regras.js";
import { somarDias, idsCartao } from "./ciclo.js";

const brl = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const dm = (iso) => iso.slice(8, 10) + "/" + iso.slice(5, 7);
const dias = (de, ate) => Math.round((Date.parse(ate) - Date.parse(de)) / 86400000);
const horaBRT = new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", hourCycle: "h23" });

export const emSilencio = (data) => { const h = Number(horaBRT.format(data)); return h >= 22 || h < 7; };

export function foraDoPadrao(transacoes, contas, hoje) {
  const cartao = idsCartao(contas);
  const recente = somarDias(hoje, -3), desde = somarDias(hoje, -180);
  const cat = (t) => t.ajuste_categoria || t.category || "";
  const valor = (t) => valorGasto(t, cartao.has(t.account_id));
  const historico = {};
  for (const t of transacoes) {
    if (t.date >= desde && t.date < recente && valor(t) > 0) (historico[cat(t)] ||= []).push(valor(t));
  }
  return transacoes
    .filter((t) => t.date >= recente && t.date <= hoje && valor(t) >= 100)
    .map((t) => {
      const h = historico[cat(t)] || [];
      return { t, media: h.length >= 3 ? h.reduce((a, b) => a + b, 0) / h.length : null };
    })
    .filter(({ t, media }) => media != null && valor(t) > 2 * media);
}

const ultimoDiaDoMes = (a, m) => new Date(Date.UTC(a, m, 0)).getUTCDate(); // m = 1..12

export function alertasOrcamentos({ orcamentos, ctx, transacoes, contas, resumo, hoje }) {
  const cartao = idsCartao(contas);
  const [a, m] = hoje.split("-").map(Number);
  const out = [];
  for (const o of orcamentos) {
    const mensal = o.periodo === "mensal";
    const inicio = mensal ? hoje.slice(0, 8) + "01" : resumo.inicio;
    const fim = mensal ? `${hoje.slice(0, 8)}${String(ultimoDiaDoMes(a, m)).padStart(2, "0")}` : resumo.fim;
    const ids = Array.isArray(o.categoria_ids) ? o.categoria_ids : [];
    const gasto = transacoes
      .filter((t) => t.date >= inicio && t.date <= fim && (!ids.length || ids.includes(categoriaEfetiva(t, ctx, traduzir, false).categoria_id)))
      .reduce((s, t) => s + valorGasto(t, cartao.has(t.account_id)), 0);
    const pct = o.valor > 0 ? (gasto / o.valor) * 100 : 0;
    const resto = `Você usou ${brl.format(gasto)} de ${brl.format(o.valor)} (${dm(inicio)} a ${dm(fim)}).`;
    const nome = o.nome || "sem nome";
    if (pct > 100) out.push({ chave: `orc100:${o.id}:${inicio}`, titulo: `Orçamento ${nome} estourado`, corpo: `${resto} ${brl.format(gasto - o.valor)} acima.` });
    else if (pct >= 80) out.push({ chave: `orc80:${o.id}:${inicio}`, titulo: `80% do orçamento ${nome}`, corpo: resto });
  }
  return out;
}

export function alertasFechamento({ contas, hoje }) {
  const out = [];
  for (const c of contas) {
    if (c.type !== "CREDIT" || !c.closing_date) continue;
    const n = dias(hoje, c.closing_date);
    if (n < 0 || n > 3) continue;
    out.push({ chave: `fechamento:${c.id}:${c.closing_date}`,
      titulo: `Fatura do ${c.name} fecha ${n === 0 ? "hoje" : `em ${n} ${n === 1 ? "dia" : "dias"}`}`,
      corpo: `Fatura atual: ${brl.format(c.balance || 0)}${c.due_date ? ` · vence ${dm(c.due_date)}` : ""}` });
  }
  return out;
}

export function alertasReceita({ transacoes, contas, hoje }) {
  const bancos = new Map(contas.filter((c) => c.type === "BANK").map((c) => [c.id, c]));
  const desde = somarDias(hoje, -2);
  return transacoes
    .filter((t) => bancos.has(t.account_id) && t.amount > 0 && !t.scheduled && !naoEhGasto(t) && t.date >= desde)
    .map((t) => ({ chave: `receita:${t.id}`, titulo: "Entrou dinheiro", corpo: `${brl.format(t.amount)} de ${t.description || "origem não informada"} em ${bancos.get(t.account_id).name}` }));
}

export function alertasAssinaturas({ assinaturas, hoje }) {
  const [a, m, d] = hoje.split("-").map(Number);
  const dataDoMes = (ano, mes, dia) => {
    const ajustado = new Date(Date.UTC(ano, mes - 1, 1));
    const y = ajustado.getUTCFullYear(), mm = ajustado.getUTCMonth() + 1;
    return `${y}-${String(mm).padStart(2, "0")}-${String(Math.min(dia, ultimoDiaDoMes(y, mm))).padStart(2, "0")}`;
  };
  const out = [];
  for (const s of assinaturas) {
    if (s.status !== "confirmada") continue;
    const atual = dataDoMes(a, m, s.dia);
    const proxima = atual >= hoje ? atual : dataDoMes(a, m + 1, s.dia);
    const n = dias(hoje, proxima);
    if (n > 1) continue;
    out.push({ chave: `assinatura:${s.id}:${proxima}`, titulo: `${s.nome || "Assinatura"} cobra ${n === 0 ? "hoje" : "amanhã"}`, corpo: brl.format(s.valor) });
  }
  return out;
}

// `criada` única por alerta (base + 1 ms cada): o cursor do app (criada > ?) não pula alertas além do corte do LIMIT.
export function gravarAlertas(db, alertas, base = Date.now()) {
  if (!alertas.length) return null;
  return db.batch(alertas.map((a, i) =>
    db.prepare("INSERT OR IGNORE INTO notificacoes (chave, titulo, corpo, criada) VALUES (?1, ?2, ?3, ?4)").bind(a.chave, a.titulo, a.corpo, new Date(base + i).toISOString())));
}

const doTipo = (registros, tabela) => registros.filter((r) => r.tabela === tabela && r.dados).map((r) => ({ id: r.id, ...r.dados }));

export function gerarAlertas({ resumo, transacoes, contas, avisos, hoje, registros = [], ctx = contextoDeRegistros([]) }) {
  const out = [];
  const { percentual: p, consumido, limite, falta, inicio, fim } = resumo;
  if (p != null && p >= 80) {
    out.push({ chave: `limite80:${inicio}`, titulo: "80% do limite do ciclo",
      corpo: `Você já usou ${brl.format(consumido)} de ${brl.format(limite)} (${Math.floor(p)}%). Faltam ${brl.format(Math.max(falta, 0))} até ${dm(fim)}.` });
  }
  if (p != null && p >= 100) {
    out.push({ chave: `limite100:${inicio}`, titulo: "Limite do ciclo estourado",
      corpo: `Você usou ${brl.format(consumido)} de ${brl.format(limite)}: ${brl.format(consumido - limite)} acima.` });
  }
  const cartao = idsCartao(contas);
  for (const { t, media } of foraDoPadrao(transacoes, contas, hoje)) {
    out.push({ chave: `fora:${t.id}`, titulo: "Gasto acima do normal",
      corpo: `${brl.format(valorGasto(t, cartao.has(t.account_id)))} em ${t.description} (${traduzir(t.ajuste_categoria || t.category)}): mais que o dobro da sua média (${brl.format(media)}).` });
  }
  if (avisos[0]) out.push({ chave: `reconexao:${hoje}`, titulo: `${avisos[0].banco} pediu nova conexão`, corpo: avisos[0].mensagem }); // um por dia basta
  out.push(
    ...alertasOrcamentos({ orcamentos: doTipo(registros, "orcamentos"), ctx, transacoes, contas, resumo, hoje }),
    ...alertasFechamento({ contas, hoje }),
    ...alertasReceita({ transacoes, contas, hoje }),
    ...alertasAssinaturas({ assinaturas: doTipo(registros, "assinaturas"), hoje }),
  );
  return out;
}

export function resumoSemanal({ resumo, transacoes, contas, hoje }) {
  const cartao = idsCartao(contas);
  const desde = somarDias(hoje, -6);
  const semana = transacoes.filter((t) => t.date >= desde && t.date <= hoje).reduce((s, t) => s + valorGasto(t, cartao.has(t.account_id)), 0);
  const ciclo = resumo.limite == null
    ? `No ciclo: ${brl.format(resumo.consumido)}.`
    : `No ciclo: ${brl.format(resumo.consumido)} de ${brl.format(resumo.limite)}; faltam ${brl.format(Math.max(resumo.falta, 0))} em ${resumo.diasRestantes} dias.`;
  return { chave: `semana:${hoje}`, titulo: "Resumo da semana", corpo: `Gastou ${brl.format(semana)} nos últimos 7 dias. ${ciclo}` };
}
