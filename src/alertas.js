// src/alertas.js — quais alertas gerar (funções puras). Chave única por alerta evita repetir.
import { valorGasto, traduzir } from "../public/regras.js";
import { somarDias } from "./ciclo.js";

const brl = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const dm = (iso) => iso.slice(8, 10) + "/" + iso.slice(5, 7);
const horaBRT = new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", hourCycle: "h23" });

export const emSilencio = (data) => { const h = Number(horaBRT.format(data)); return h >= 22 || h < 7; };

export function foraDoPadrao(transacoes, contas, hoje) {
  const cartao = new Set(contas.filter((c) => c.type === "CREDIT").map((c) => c.id));
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

export function gerarAlertas({ resumo, transacoes, contas, avisos, hoje }) {
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
  const cartao = new Set(contas.filter((c) => c.type === "CREDIT").map((c) => c.id));
  for (const { t, media } of foraDoPadrao(transacoes, contas, hoje)) {
    out.push({ chave: `fora:${t.id}`, titulo: "Gasto acima do normal",
      corpo: `${brl.format(valorGasto(t, cartao.has(t.account_id)))} em ${t.description} (${traduzir(t.ajuste_categoria || t.category)}): mais que o dobro da sua média (${brl.format(media)}).` });
  }
  for (const a of avisos) {
    out.push({ chave: `reconexao:${hoje}`, titulo: `${a.banco} pediu nova conexão`, corpo: a.mensagem });
    break; // um por dia basta
  }
  return out;
}

export function resumoSemanal({ resumo, transacoes, contas, hoje }) {
  const cartao = new Set(contas.filter((c) => c.type === "CREDIT").map((c) => c.id));
  const desde = somarDias(hoje, -6);
  const semana = transacoes.filter((t) => t.date >= desde && t.date <= hoje).reduce((s, t) => s + valorGasto(t, cartao.has(t.account_id)), 0);
  const ciclo = resumo.limite == null
    ? `No ciclo: ${brl.format(resumo.consumido)}.`
    : `No ciclo: ${brl.format(resumo.consumido)} de ${brl.format(resumo.limite)}; faltam ${brl.format(Math.max(resumo.falta, 0))} em ${resumo.diasRestantes} dias.`;
  return { chave: `semana:${hoje}`, titulo: "Resumo da semana", corpo: `Gastou ${brl.format(semana)} nos últimos 7 dias. ${ciclo}` };
}
