// src/ciclo.js — ciclo do salário e consumo do limite (funções puras, testadas em test/ciclo.test.mjs).
import { valorGasto, valorParcela } from "../public/regras.js";

export const idsCartao = (contas) => new Set(contas.filter((c) => c.type === "CREDIT").map((c) => c.id));

export const normalizar = (d) =>
  (d || "").toUpperCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .replace(/[^A-Z ]+/g, " ").replace(/\s+/g, " ").trim();

export function somarDias(iso, n) {
  const d = new Date(iso + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function fimDoCiclo(inicio) {
  const [a, m, d] = inicio.split("-").map(Number);
  const ultimo = new Date(Date.UTC(a, m + 1, 0)).getUTCDate(); // último dia do mês seguinte
  const prox = new Date(Date.UTC(a, m, Math.min(d, ultimo), 12));
  return somarDias(prox.toISOString().slice(0, 10), -1);
}

export function cicloAtual(transacoes, contas, salario, hoje) {
  const banco = new Set(contas.filter((c) => c.type !== "CREDIT").map((c) => c.id));
  const datas = salario
    ? transacoes.filter((t) => banco.has(t.account_id) && !t.scheduled && t.amount > 0 && t.date <= hoje && normalizar(t.description) === salario).map((t) => t.date)
    : [];
  if (!datas.length) {
    const inicio = hoje.slice(0, 8) + "01";
    return { inicio, fim: fimDoCiclo(inicio), semSalario: true }; // 1º + 1 mês − 1 = último dia do mês
  }
  const inicio = datas.sort().at(-1);
  const fim = fimDoCiclo(inicio);
  return { inicio, fim: fim < hoje ? hoje : fim, semSalario: false };
}

const dias = (de, ate) => Math.round((Date.parse(ate) - Date.parse(de)) / 86400000);
const centavos = (v) => Math.round(v * 100) / 100;

export function resumoCiclo({ transacoes, contas, config, hoje }) {
  const cartao = idsCartao(contas);
  const { inicio, fim, semSalario } = cicloAtual(transacoes, contas, config.salario || null, hoje);
  let gasto = 0, parcelasCiclo = 0, parcelasDepois = 0;
  for (const t of transacoes) {
    const c = cartao.has(t.account_id);
    if (t.date >= inicio && t.date <= fim) gasto += valorGasto(t, c);
    const p = valorParcela(t, c);
    if (p && t.date >= inicio && t.date <= fim) parcelasCiclo += p;
    else if (p && t.date > fim) parcelasDepois += p;
  }
  const consumido = centavos(gasto + parcelasCiclo);
  const limite = config.limite > 0 ? config.limite : null;
  return {
    inicio, fim, semSalario, diasRestantes: dias(hoje, fim),
    gasto: centavos(gasto), parcelasCiclo: centavos(parcelasCiclo), consumido,
    limite, falta: limite == null ? null : centavos(limite - consumido),
    percentual: limite == null ? null : (consumido / limite) * 100,
    parcelasDepois: centavos(parcelasDepois),
  };
}
