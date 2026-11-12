// src/ciclo.js — ciclo do salário e consumo do limite (funções puras, testadas em test/ciclo.test.mjs).
import { valorGasto, valorParcela, regraAuto } from "../public/regras.js";

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

// Conta que não é do usuário: conta corrente e cartão do Santander (quem usa é o pai).
// Mesma regra de mbContaIgnorada no app (budget/lib/struct/meuBancoMapping.dart); poupança e aplicações de lá continuam valendo.
export const contaIgnorada = (c) =>
  (c.type === "CREDIT" || (c.type === "BANK" && (c.subtype == null || c.subtype === "CHECKING_ACCOUNT"))) &&
  /santander/i.test(`${c.name ?? ""} ${c.bank ?? ""}`);

export function semIgnoradas(transacoes, contas) {
  const fora = new Set(contas.filter(contaIgnorada).map((c) => c.id));
  return [transacoes.filter((t) => !fora.has(t.account_id)), contas.filter((c) => !fora.has(c.id))];
}

// Salário = entrada na conta corrente com valor até 15% acima ou abaixo do salário anterior (reajustes acompanham,
// pois cada salário aceito vira a nova referência). Sem salário em 35 dias, fica pendente para o usuário.
export const TOLERANCIA_SALARIO = 0.15;
export const MIN_DIAS_ENTRE_SALARIOS = 20; // duas entradas parecidas em menos de 20 dias: vale a primeira
export const DIAS_SEM_SALARIO = 35;

// 13º, férias e PLR são renda, mas não viram o ciclo.
const NAO_SALARIO = /\b13 ?([º°]|o\b)|\b13 ?salario|decimo terceiro|ferias|\bplr\b|participacao (nos? )?(lucros|resultados)/;
const semAcento = (d) => (d || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
const parecido = (valor, referencia) => Math.abs(valor - referencia) <= referencia * TOLERANCIA_SALARIO;
const diasEntre = (de, ate) => Math.round((Date.parse(ate) - Date.parse(de)) / 86400000);

// Referência inicial: o valor salvo na config (usuário marcou o salário) ou, sem isso, a maior entrada que se repete
// em 2+ meses. Sem nenhuma das duas (primeiro uso, sem histórico) não há salário e vale o mês corrente.
export function valorBaseSalario(entradas, config) {
  if (config.salarioValor > 0) return config.salarioValor;
  for (const e of [...entradas].sort((a, b) => b.amount - a.amount)) {
    const meses = new Set(entradas.filter((x) => parecido(x.amount, e.amount)).map((x) => x.date.slice(0, 7)));
    if (meses.size >= 2) return e.amount;
  }
  return null;
}

// Datas (crescentes) em que o salário caiu. `entradas` já vem só com créditos candidatos, em ordem de data.
export function datasDeSalario(entradas, config) {
  let referencia = valorBaseSalario(entradas, config);
  const datas = [];
  for (const t of entradas) {
    const pelaDescricao = config.salario && normalizar(t.description) === config.salario; // marcação antiga (só descrição)
    if (!pelaDescricao && !(referencia != null && parecido(t.amount, referencia))) continue;
    if (datas.length && diasEntre(datas.at(-1), t.date) < MIN_DIAS_ENTRE_SALARIOS) continue;
    datas.push(t.date);
    referencia = t.amount;
  }
  return datas;
}

export function cicloAtual(transacoes, contas, config, hoje) {
  const validas = new Set(contas.filter((c) => c.type !== "CREDIT" && !contaIgnorada(c)).map((c) => c.id));
  const doBanco = transacoes.filter((t) => validas.has(t.account_id) && !t.scheduled && t.date <= hoje);
  const entradas = doBanco
    .filter((t) => t.amount > 0 && !regraAuto(t) && !NAO_SALARIO.test(semAcento(t.description)))
    .sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  const ultimoSalario = datasDeSalario(entradas, config).at(-1) ?? null;
  // Sem salário nenhum, conta desde o começo do histórico (ou hoje, sem transações).
  const desde = ultimoSalario ?? doBanco.reduce((m, t) => (t.date < m ? t.date : m), hoje);
  const diasSemSalario = diasEntre(desde, hoje);
  const pendencia = { ultimoSalario, diasSemSalario, salarioNaoDetectado: diasSemSalario >= DIAS_SEM_SALARIO };
  if (!ultimoSalario) {
    const inicio = hoje.slice(0, 8) + "01";
    return { inicio, fim: fimDoCiclo(inicio), semSalario: true, ...pendencia }; // 1º + 1 mês − 1 = último dia do mês
  }
  const fim = fimDoCiclo(ultimoSalario);
  return { inicio: ultimoSalario, fim: fim < hoje ? hoje : fim, semSalario: false, ...pendencia };
}

const dias = (de, ate) => Math.round((Date.parse(ate) - Date.parse(de)) / 86400000);
const centavos = (v) => Math.round(v * 100) / 100;

export function gastoPorDia(todas, todasContas, inicio, fim) {
  const [transacoes, contas] = semIgnoradas(todas, todasContas);
  const cartao = idsCartao(contas);
  const soma = new Map();
  for (const t of transacoes) {
    if (t.date < inicio || t.date > fim) continue;
    const c = cartao.has(t.account_id);
    soma.set(t.date, (soma.get(t.date) || 0) + valorGasto(t, c) + valorParcela(t, c));
  }
  const saida = [];
  for (let d = inicio; d <= fim; d = somarDias(d, 1)) saida.push({ data: d, valor: centavos(soma.get(d) || 0) });
  return saida;
}

export function resumoCiclo({ transacoes: todas, contas: todasContas, config, hoje }) {
  const [transacoes, contas] = semIgnoradas(todas, todasContas);
  const cartao = idsCartao(contas);
  const { inicio, fim, semSalario, ultimoSalario, diasSemSalario, salarioNaoDetectado } = cicloAtual(transacoes, contas, config, hoje);
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
    inicio, fim, semSalario, ultimoSalario, diasSemSalario, salarioNaoDetectado, diasRestantes: dias(hoje, fim),
    gasto: centavos(gasto), parcelasCiclo: centavos(parcelasCiclo), consumido,
    limite, falta: limite == null ? null : centavos(limite - consumido),
    percentual: limite == null ? null : (consumido / limite) * 100,
    parcelasDepois: centavos(parcelasDepois),
  };
}
