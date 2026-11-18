// src/revisao.js — fila "Para revisar": o que precisa de uma decisão do usuário no ciclo atual (funções puras, test/revisao.test.mjs).
//
// Decisões e memória ficam na tabela `registros` (tabela `revisoes`, ver packages/core/src/sync.ts), sincronizadas entre aparelhos:
//   id `tx:<transação>`  { tipo: "decisao", tx_id, resposta, categoria_id?, valor, data, descricao }
//   id `dest:<nome>`     { tipo: "destinatario", destinatario, categoria_id }   (memória do Pix enviado a essa pessoa)
// Quem lê empréstimos, devoluções e reembolsos (PR 4) filtra `revisoes` com tipo "decisao" e resposta "emprestimo" | "devolucao" | "reembolso".
import { normalizar, entradasCandidatas, salariosDetectados, somarDias } from "./ciclo.js";
import { regraAuto, DESC_FORA } from "../public/regras.js";

const PIX_ENVIADO = /^PIX (ENVIAD[OA]|ENVIO)\b ?/;
const PIX_RECEBIDO = /^PIX (RECEBID[OA]|RECEBIMENTO)\b ?/;
const MAX_DESTINATARIO = 60;
const DIAS_CANDIDATOS_SALARIO = 60;
const MAX_CANDIDATOS_SALARIO = 5;

// Que tipo de pergunta a transação gera (ou null). Mesma regra em budget/lib/struct/mbSync/revisao.dart.
export function tipoDeRevisao(t) {
  if (t.scheduled) return null;
  const d = normalizar(t.description);
  if (t.amount < 0) {
    // Dinheiro do Inter para o Santander: a categoria "transferência entre minhas contas" não impede a pergunta.
    if (/\bSANTANDER\b/.test(d)) return DESC_FORA.test(t.description || "") ? null : { tipo: "envio_santander" };
    if (regraAuto(t)) return null;
    const m = PIX_ENVIADO.exec(d);
    return m ? { tipo: "pix_enviado", destinatario: d.slice(m[0].length, m[0].length + MAX_DESTINATARIO).trim() || null } : null;
  }
  if (t.amount > 0 && !regraAuto(t) && PIX_RECEBIDO.test(d)) return { tipo: "pix_recebido" };
  return null;
}

// Decisões por transação e memória por destinatário, lidas dos registros (ignora os malformados).
export function lerRevisoes(registros) {
  const decisoes = new Map();
  const destinos = new Map();
  for (const r of registros) {
    const d = r.dados;
    if (r.tabela !== "revisoes" || !d) continue;
    if (d.tipo === "decisao" && d.tx_id && d.resposta) decisoes.set(d.tx_id, d);
    else if (d.tipo === "destinatario" && d.destinatario && d.categoria_id) destinos.set(d.destinatario, d);
  }
  return { decisoes, destinos };
}

// Aplica as respostas nas transações:
//  - Inter → Santander: não é gasto até responder; "ajuda" vira gasto, "empréstimo" e "investimento" ficam de fora;
//  - Pix recebido com resposta (devolução, reembolso ou renda) não pode virar salário; "reembolso" também abate o gasto;
//  - `revisada` marca o que já tem resposta (ou memória do destinatário) e sai da fila.
//  - cartão não pergunta; antes do ciclo (`inicio`) só vale o que o usuário já respondeu (o histórico não é reclassificado),
//    como no app (budget/lib/struct/meuBancoMapping.dart).
export function aplicarRevisoes(transacoes, { decisoes, destinos }, { cartoes = new Set(), inicio = null } = {}) {
  return transacoes.map((t) => {
    const dec = decisoes.get(t.id);
    if (cartoes.has(t.account_id) || (inicio && t.date < inicio && !dec)) return t;
    const r = tipoDeRevisao(t);
    if (!r) return t;
    const resposta = dec?.resposta ?? (r.tipo === "pix_enviado" && r.destinatario && destinos.has(r.destinatario) ? "categoria" : null);
    if (r.tipo === "envio_santander") {
      return { ...t, revisada: !!resposta, ajuste_gasto: resposta === "ajuda" ? 1 : 0 };
    }
    return { ...t, revisada: !!resposta, reembolso: resposta === "reembolso" };
  });
}

const item = (t, tipo, extra = {}) => ({ id: `tx:${t.id}`, tipo, tx_id: t.id, data: t.date, descricao: t.description, valor: Math.abs(t.amount), ...extra });

// Itens do ciclo atual sem resposta, do mais novo para o mais antigo; "salário não detectado" (35 dias) vai primeiro,
// com as maiores entradas recentes como candidatas para o usuário marcar (PUT /api/config { salario_id }).
export function filaRevisar({ transacoes, contas, config, resumo, hoje }) {
  const fila = [];
  const { entradas } = entradasCandidatas(transacoes, contas, hoje);
  const salarios = new Set(salariosDetectados(entradas, config).map((t) => t.id)); // Pix recebido que já é o salário não vira pergunta
  if (resumo.salarioNaoDetectado) {
    const desde = somarDias(hoje, -DIAS_CANDIDATOS_SALARIO);
    const candidatos = entradas
      .filter((t) => t.date >= desde)
      .sort((a, b) => b.amount - a.amount)
      .slice(0, MAX_CANDIDATOS_SALARIO)
      .map((t) => ({ tx_id: t.id, data: t.date, descricao: t.description, valor: t.amount }));
    fila.push({ id: "salario", tipo: "salario_nao_detectado", dias: resumo.diasSemSalario, candidatos });
  }
  const cartoes = new Set(contas.filter((c) => c.type === "CREDIT").map((c) => c.id));
  const itens = transacoes
    .filter((t) => !cartoes.has(t.account_id) && !t.revisada && !salarios.has(t.id) && t.date >= resumo.inicio && t.date <= hoje)
    .flatMap((t) => { const r = tipoDeRevisao(t); return r ? [item(t, r.tipo, r.destinatario !== undefined ? { destinatario: r.destinatario } : {})] : []; })
    .sort((a, b) => (a.data < b.data ? 1 : a.data > b.data ? -1 : 0));
  return fila.concat(itens);
}
