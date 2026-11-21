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
const SANTANDER = /santander/i;
const textoBanco = (c) => `${c.name ?? ""} ${c.bank ?? ""}`;
export const contaIgnorada = (c) =>
  (c.type === "CREDIT" || (c.type === "BANK" && (c.subtype == null || c.subtype === "CHECKING_ACCOUNT"))) && SANTANDER.test(textoBanco(c));

// Mesmos bancos que o app reconhece (mbBancosConhecidos, budget/lib/struct/mbSync/bancos.dart), no nome sem acento nem pontuação.
// No Meu Pluggy a conta vem sem banco e o cartão pode se chamar só "GOLD": ele herda o banco de outra conta da mesma conexão
// (mbHerdarBanco no app), senão o cartão do pai entraria no ciclo e nos alertas.
const BANCO_CONHECIDO = /\b(inter|santander|nubank|nu pagamentos|nu financeira|itau|itaucard|bradesco|bradescard|banco do brasil|bb|ourocard|caixa|c6|mercado ?pago|picpay|xp|btg)\b/;
const textoDoBanco = (c) => String(c.bank ?? c.name ?? "");
const bancoConhecido = (c) => BANCO_CONHECIDO.test(textoDoBanco(c).toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, " ").trim());
export function herdarBanco(contas) {
  const porItem = new Map();
  for (const c of contas) if (c.item_id != null && bancoConhecido(c) && !porItem.has(c.item_id)) porItem.set(c.item_id, c);
  return contas.map((c) => {
    const dona = c.item_id != null && !bancoConhecido(c) ? porItem.get(c.item_id) : null;
    return dona ? { ...c, bank: textoDoBanco(dona) } : c;
  });
}

// Poupança não tem carteira no app (vira aplicação): os movimentos dela não são gasto nem renda do ciclo. O saldo continua valendo.
const ehPoupanca = (c) => c.type === "BANK" && c.subtype === "SAVINGS_ACCOUNT";

export function semIgnoradas(transacoes, todas) {
  const contas = herdarBanco(todas);
  const fora = new Set(contas.filter(contaIgnorada).map((c) => c.id));
  const semMovimento = new Set(contas.filter(ehPoupanca).map((c) => c.id));
  return [transacoes.filter((t) => !fora.has(t.account_id) && !semMovimento.has(t.account_id)), contas.filter((c) => !fora.has(c.id))];
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

// Entradas (em ordem de data) em que o salário caiu. `entradas` já vem só com créditos candidatos.
export function salariosDetectados(entradas, config) {
  let referencia = valorBaseSalario(entradas, config);
  const achados = [];
  for (const t of entradas) {
    // Pela descrição marcada o reajuste passa sem teto, mas não o que vem bem abaixo da referência: a 1ª e a 2ª parcela
    // do 13º chegam com a mesma descrição do salário e virariam o início do ciclo (e o salário seguinte cairia nos 20 dias).
    const pelaDescricao = config.salario && normalizar(t.description) === config.salario && (referencia == null || t.amount >= referencia * (1 - TOLERANCIA_SALARIO));
    if (!pelaDescricao && !(referencia != null && parecido(t.amount, referencia))) continue;
    if (achados.length && diasEntre(achados.at(-1).date, t.date) < MIN_DIAS_ENTRE_SALARIOS) continue;
    achados.push(t);
    referencia = t.amount;
  }
  return achados;
}

export const datasDeSalario = (entradas, config) => salariosDetectados(entradas, config).map((t) => t.date);

// Créditos da conta corrente que podem ser salário. O que o usuário já classificou na fila como devolução ou reembolso
// (`revisada`) fica de fora: a decisão dele vale mais que o valor parecido. "Renda" continua candidata (`renda`): salário
// novo ou reajustado que chega por Pix é respondido assim, e sem isso o ciclo ficaria preso no salário antigo.
export function entradasCandidatas(transacoes, contas, hoje) {
  const validas = new Set(contas.filter((c) => c.type !== "CREDIT" && !contaIgnorada(c) && !ehPoupanca(c)).map((c) => c.id));
  const doBanco = transacoes.filter((t) => validas.has(t.account_id) && !t.scheduled && t.date <= hoje);
  const entradas = doBanco
    .filter((t) => t.amount > 0 && (!t.revisada || t.renda) && !regraAuto(t) && !NAO_SALARIO.test(semAcento(t.description)))
    .sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  return { doBanco, entradas };
}

export function cicloAtual(transacoes, contas, config, hoje) {
  const { doBanco, entradas } = entradasCandidatas(transacoes, contas, hoje);
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
// Pix recebido que o usuário marcou como reembolso: abate o gasto como um estorno genérico (não é renda).
// `reembolso_valor`: só a sobra de um Pix que pagou um empréstimo e passou do saldo abate o gasto.
export const abatimento = (t) => (t.reembolso && t.amount > 0 ? t.reembolso_valor ?? t.amount : 0);

export function gastoPorDia(todas, todasContas, inicio, fim) {
  const [transacoes, contas] = semIgnoradas(todas, todasContas);
  const cartao = idsCartao(contas);
  const soma = new Map();
  for (const t of transacoes) {
    if (t.date < inicio || t.date > fim) continue;
    const c = cartao.has(t.account_id);
    soma.set(t.date, (soma.get(t.date) || 0) + valorGasto(t, c) + valorParcela(t, c) - abatimento(t));
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
    if (t.date >= inicio && t.date <= fim) gasto += valorGasto(t, c) - abatimento(t);
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
