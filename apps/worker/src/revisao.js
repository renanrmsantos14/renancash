// src/revisao.js — fila "Para revisar": o que precisa de uma decisão do usuário no ciclo atual (funções puras, test/revisao.test.mjs).
//
// Decisões e memória ficam na tabela `registros` (tabela `revisoes`, ver packages/core/src/sync.ts), sincronizadas entre aparelhos:
//   id `tx:<transação>`  { tipo: "decisao", tx_id, resposta, categoria_id?, valor, data, descricao }
//   id `dest:<nome>`     { tipo: "destinatario", destinatario, categoria_id }   (memória do Pix enviado a essa pessoa)
// Quem lê empréstimos, devoluções e reembolsos (PR 4) filtra `revisoes` com tipo "decisao" e resposta "emprestimo" | "devolucao" | "reembolso".
// "troco" (Pix enviado à pessoa que mandou um reembolso, `troco_de` = id desse Pix recebido) devolve parte do reembolso: no Worker
// segue como um Pix enviado respondido (gasto normal), então o ciclo dá reembolso − troco abatidos do gasto.
// Empréstimo (resposta "emprestimo", com `pessoa`) não é gasto em nenhuma saída (Pix, envio ao Santander ou compra de débito);
// "devolucao" com `sobra_para: "reembolso"` abate só a sobra do gasto; o perdão (`perdao:<empréstimo>`, valor fixo) vira um gasto
// sintético na data em que foi dado (transacoesDePerdao). Tudo igual ao app (budget/lib/struct/meuBancoMapping.dart).
import { categoriaEfetiva, contextoDeRegistros } from "@meu-banco/core";
import { normalizar, entradasCandidatas, salariosDetectados, somarDias } from "./ciclo.js";
import { regraAuto, DESC_FORA, traduzir } from "../public/regras.js";

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
  const perdoes = new Map();
  for (const r of registros) {
    const d = r.dados;
    if (r.tabela !== "revisoes" || !d) continue;
    if (d.tipo === "perdao" && d.emprestimo_id && d.valor > 0 && /^\d{4}-\d{2}-\d{2}/.test(d.data || "")) perdoes.set(d.emprestimo_id, d);
    else if (d.tipo === "decisao" && d.tx_id && d.resposta) decisoes.set(d.tx_id, d);
    else if (d.tipo === "destinatario" && d.destinatario && d.categoria_id) destinos.set(d.destinatario, d);
  }
  // Troco de um reembolso que não está mais ligado a um gasto vale como Pix enviado sem resposta (igual ao app).
  for (const [id, d] of decisoes) {
    const r = d.resposta === "troco" ? decisoes.get(d.troco_de) : null;
    if (d.resposta === "troco" && !(r?.resposta === "reembolso" && r.reembolso_de)) decisoes.delete(id);
  }
  return { decisoes, destinos, perdoes };
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
    if (dec?.resposta === "emprestimo" && t.amount < 0 && !t.scheduled) return { ...t, revisada: true, ajuste_gasto: 0 };
    const r = tipoDeRevisao(t);
    // Reembolso ligado a uma entrada que não é Pix recebido (estorno de compra no débito, pela aba Pendências): abate igual ao app.
    if (!r) return dec?.resposta === "reembolso" && t.amount > 0 && !t.scheduled ? { ...t, revisada: true, reembolso: true } : t;
    const resposta = dec?.resposta ?? (r.tipo === "pix_enviado" && r.destinatario && destinos.has(r.destinatario) ? "categoria" : null);
    if (r.tipo === "envio_santander") {
      return { ...t, revisada: !!resposta, ajuste_gasto: resposta === "ajuda" ? 1 : 0 };
    }
    // Pix recebido que pagou um empréstimo e passou do saldo: a sobra que o usuário mandou para um reembolso abate o gasto (só ela).
    const sobra = resposta === "devolucao" && dec.sobra_para === "reembolso" && dec.sobra > 0 ? Math.min(dec.sobra, t.amount) : 0;
    if (sobra) return { ...t, revisada: true, reembolso: true, reembolso_valor: sobra };
    return { ...t, revisada: !!resposta, reembolso: resposta === "reembolso", ...(resposta === "renda" ? { renda: true } : {}) };
  });
}

// Perdão de empréstimo: o saldo perdoado vira gasto na data do perdão, numa conta que não seja cartão (a menor por id, como no app).
export function transacoesDePerdao(perdoes, contas) {
  const conta = contas.filter((c) => c.type !== "CREDIT").sort((a, b) => (a.id < b.id ? -1 : 1))[0];
  if (!conta) return [];
  return [...perdoes.values()].map((p) => ({ id: `perdao:${p.emprestimo_id}`, account_id: conta.id, date: String(p.data).slice(0, 10), description: "Perdão de empréstimo", amount: -Number(p.valor), status: "POSTED", scheduled: 0, revisada: true, ajuste_gasto: 1 }));
}

const semAcento = (s) => normalizar(s).replace(/S$/, "");
// Ids das categorias de despesa do usuário que se chamam "Empréstimo" (o jeito antigo de marcar empréstimo, sem pessoa).
const categoriasEmprestimo = (registros) => new Set(registros.flatMap((r) => (r.tabela === "categorias" && !r.deleted_at && r.dados && r.dados.tipo !== "receita" && semAcento(String(r.dados.nome || "")) === "EMPRESTIMO" ? [r.id] : [])));

const item = (t, tipo, extra = {}) => ({ id: `tx:${t.id}`, tipo, tx_id: t.id, data: t.date, descricao: t.description, valor: Math.abs(t.amount), ...extra });

// Itens do ciclo atual sem resposta, do mais novo para o mais antigo; "salário não detectado" (35 dias) vai primeiro,
// com as maiores entradas recentes como candidatas para o usuário marcar (PUT /api/config { salario_id }).
export function filaRevisar({ transacoes, contas, config, resumo, hoje, revisoes = null, registros = [] }) {
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
  return fila.concat(itens, emprestimosSemPessoa({ transacoes, cartoes, revisoes, registros }));
}

// Transações ligadas no app a um empréstimo (divida_id no ajuste).
export const ligadasAEmprestimo = (registros) => new Set(registros.filter((r) => r.tabela === "ajustes" && r.dados?.divida_id).map((r) => r.id));

// Empréstimos que já existem sem pessoa: decisão "emprestimo" sem `pessoa` ou saída na categoria "Empréstimo" (categoria da decisão,
// do ajuste, de regra ou lembrada do destinatário) sem decisão "emprestimo" nem `recategorizado`. Voltam à fila pedindo a pessoa.
function emprestimosSemPessoa({ transacoes, cartoes, revisoes, registros }) {
  if (!revisoes) return [];
  const ids = categoriasEmprestimo(registros);
  const ctx = contextoDeRegistros(registros);
  const ligadas = ligadasAEmprestimo(registros); // a pessoa é a do empréstimo: não há o que perguntar
  const achados = transacoes.filter((t) => {
    if (t.amount >= 0 || t.scheduled || cartoes.has(t.account_id) || t.id.startsWith("perdao:") || ligadas.has(t.id)) return false;
    const dec = revisoes.decisoes.get(t.id);
    if (dec?.resposta === "emprestimo") return !dec.pessoa;
    if (dec?.recategorizado) return false;
    const r = tipoDeRevisao(t);
    const cat = dec?.categoria_id ?? categoriaEfetiva(t, ctx, traduzir, false).categoria_id ?? (r?.destinatario ? revisoes.destinos.get(r.destinatario)?.categoria_id : null);
    return !!cat && ids.has(cat);
  });
  return achados
    .map((t) => { const r = tipoDeRevisao(t); return item(t, "emprestimo_sem_pessoa", r?.destinatario ? { destinatario: r.destinatario } : {}); })
    .sort((a, b) => (a.data < b.data ? 1 : a.data > b.data ? -1 : 0));
}
