// src/alertas.js — quais alertas gerar (funções puras). Chave única por alerta evita repetir.
import { categoriaEfetiva, contextoDeRegistros } from "@meu-banco/core";
import { valorGasto, valorParcela, traduzir } from "../public/regras.js";
import { somarDias, idsCartao, abatimento } from "./ciclo.js";

const brl = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const dm = (iso) => iso.slice(8, 10) + "/" + iso.slice(5, 7);
const dias = (de, ate) => Math.round((Date.parse(ate) - Date.parse(de)) / 86400000);
const horaBRT = new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", hourCycle: "h23" });

export const emSilencio = (data) => { const h = Number(horaBRT.format(data)); return h >= 22 || h < 7; };

export const doTipo = (registros, tabela) => registros.filter((r) => r.tabela === tabela && r.dados).map((r) => ({ id: r.id, ...r.dados }));

// ---------- Orçamento Geral ----------

// Id do Geral entre os aparelhos (prefixo "cashew:" + pk `mb:orc:geral` do app, ver orcamentos.dart).
export const ID_GERAL = "cashew:mb:orc:geral";

// Só o Geral gera aviso (perfil: alertas de 80% e 100% apenas no orçamento padrão). Sem valor definido, não há o que avisar.
export function orcamentoGeral(registros) {
  const todos = doTipo(registros, "orcamentos").filter((o) => o.arquivado !== 1); // arquivado no app não gera aviso
  const g = todos.find((o) => o.id === ID_GERAL) || todos.find((o) => (o.nome || "").trim().toLowerCase() === "geral");
  return g && g.valor > 0 ? g : null;
}

// Quanto do ciclo conta no Geral: tudo o que o ciclo consumiu, menos o que o usuário mandou só para outros orçamentos
// (ajuste `orcamento_ids` sem o Geral). Sem escolha, a transação é do Geral.
export function consumoGeral({ registros, transacoes, contas, resumo }) {
  const g = orcamentoGeral(registros);
  if (!g) return null;
  const cartao = idsCartao(contas);
  const escolhas = new Map(doTipo(registros, "ajustes").filter((a) => Array.isArray(a.orcamento_ids)).map((a) => [a.id, a.orcamento_ids]));
  let consumido = resumo.consumido;
  for (const t of transacoes) {
    const ids = escolhas.get(t.id);
    if (!ids || ids.includes(g.id) || t.date < resumo.inicio || t.date > resumo.fim) continue;
    const c = cartao.has(t.account_id);
    consumido -= valorGasto(t, c) + valorParcela(t, c) - abatimento(t);
  }
  consumido = Math.round(consumido * 100) / 100;
  return { valor: g.valor, consumido, falta: Math.round((g.valor - consumido) * 100) / 100, percentual: (consumido / g.valor) * 100, inicio: resumo.inicio, fim: resumo.fim };
}

// 80% e 100% do Geral, uma vez por ciclo cada (a chave leva o início do ciclo). Passou de 100% de uma vez: só o aviso de 100%.
// Mesma regra de mbNivelOrcamento (app): estoura quando o gasto passa do valor.
export function alertasGeral(geral) {
  if (!geral) return [];
  const { valor, consumido, percentual, inicio, fim } = geral;
  const resto = `Você usou ${brl.format(consumido)} de ${brl.format(valor)} (${dm(inicio)} a ${dm(fim)}).`;
  if (consumido > valor) return [{ chave: `orc100:${ID_GERAL}:${inicio}`, titulo: "Orçamento Geral estourado", corpo: `${resto} ${brl.format(consumido - valor)} acima.` }];
  if (percentual >= 80) return [{ chave: `orc80:${ID_GERAL}:${inicio}`, titulo: "80% do orçamento Geral", corpo: `${resto} Faltam ${brl.format(geral.falta)}.` }];
  return [];
}

// ---------- Compras (uma notificação por lote) ----------

const DIAS_COMPRAS = 7; // compra mais antiga que isso chegando agora é histórico tardio, não "compra nova"

// Compras ainda não avisadas. `vistas` = ids já vistos (guardados entre sincronizações); null = primeira vez, só registra.
// Devolve também os ids a guardar: toda transação da janela, para uma edição do usuário (gasto 0 → 1) não virar "compra nova".
export function comprasNovas({ transacoes, contas, vistas, hoje }) {
  const cartao = idsCartao(contas);
  const desde = somarDias(hoje, -DIAS_COMPRAS);
  const janela = transacoes.filter((t) => !t.scheduled && t.date >= desde && t.date <= hoje);
  const conhecidas = new Set(vistas || []);
  const novas = vistas ? janela.filter((t) => !conhecidas.has(t.id) && valorGasto(t, cartao.has(t.account_id)) > 0) : [];
  return { novas, ids: janela.map((t) => t.id) };
}

export function alertaCompras({ compras, contas, geral, agora }) {
  if (!compras.length) return [];
  const cartao = idsCartao(contas);
  const total = compras.reduce((s, t) => s + valorGasto(t, cartao.has(t.account_id)), 0);
  const n = compras.length;
  const quanto = !geral ? "Defina o valor do Geral para ver quanto falta."
    : geral.falta >= 0 ? `Faltam ${brl.format(geral.falta)} no Geral até ${dm(geral.fim)}.`
    : `${brl.format(-geral.falta)} acima do Geral.`;
  return [{ chave: `compras:${agora}`, titulo: `${n} ${n === 1 ? "compra" : "compras"}, ${brl.format(total)}`, corpo: quanto }];
}

// ---------- Fatura do cartão (Inter) ----------

export const DIAS_AVISO_FATURA = 3;

// Aviso 3 dias antes do vencimento (e no dia, se o primeiro aviso passou). Só cartão com valor a pagar; o do Santander já vem de fora.
export function alertasFatura({ contas, hoje }) {
  const out = [];
  for (const c of contas) {
    if (c.type !== "CREDIT" || !c.due_date || !(c.balance > 0)) continue;
    const n = dias(hoje, c.due_date);
    if (n < 0 || n > DIAS_AVISO_FATURA) continue;
    const nome = (c.name || "cartão").replace(/\s*[·#].*$/, "");
    out.push({ chave: `fatura:${c.id}:${c.due_date}`,
      titulo: `Fatura do ${nome} vence ${n === 0 ? "hoje" : n === 1 ? "amanhã" : `em ${n} dias`}`,
      corpo: `${brl.format(c.balance)} · vence ${dm(c.due_date)}` });
  }
  return out;
}

// ---------- Queda de conexão ----------

// Uma notificação por queda: `avisos` = conexões com problema agora, `avisadas` = ids já notificados (o app limpa o id quando volta).
export function alertasConexao({ avisos, avisadas, agora }) {
  const ja = new Set(avisadas || []);
  return avisos.filter((a) => a.item_id && !ja.has(a.item_id)).map((a) => ({
    chave: `conexao:${a.item_id}:${agora}`, titulo: `${a.banco} desconectou`,
    corpo: "O app não consegue mais ler essa conta. Toque em Reconectar na Início." }));
}

// ---------- Para revisar ----------

const DIAS_REVISAO = 2;
const MAX_REVISAO = 5;
const ROTULO_ITEM = { pix_enviado: "Pix enviado", envio_santander: "Enviado ao Santander", pix_recebido: "Pix recebido" };

// Uma notificação por item novo da fila (o app mostra os botões das opções do item). Só item recente: o que já estava na fila
// antes do aviso existir fica para a Início. Limite por rodada para um lote grande não virar enxurrada.
export function alertasRevisao({ revisar, hoje }) {
  const desde = somarDias(hoje, -DIAS_REVISAO);
  const out = [];
  for (const i of revisar) {
    if (out.length >= MAX_REVISAO) break;
    if (i.tipo === "salario_nao_detectado") {
      out.push({ chave: `revisar:salario:${hoje.slice(0, 7)}`, titulo: "Salário não detectado", corpo: `Faz ${i.dias} dias sem salário. Marque qual entrada foi o salário.` });
    } else if (i.data >= desde) {
      out.push({ chave: `revisar:${i.id}`, titulo: `${ROTULO_ITEM[i.tipo] || "Para revisar"}: ${brl.format(i.valor)}`,
        corpo: `${i.descricao || "Sem descrição"} (${dm(i.data)})` });
    }
  }
  return out;
}

// `criada` única por alerta (base + 1 ms cada): o cursor do app (criada > ?) não pula alertas além do corte do LIMIT.
export const stmtAlertas = (db, alertas, base = Date.now()) => alertas.map((a, i) =>
  db.prepare("INSERT OR IGNORE INTO notificacoes (chave, titulo, corpo, criada) VALUES (?1, ?2, ?3, ?4)").bind(a.chave, a.titulo, a.corpo, new Date(base + i).toISOString()));

export function gravarAlertas(db, alertas, base = Date.now()) {
  return alertas.length ? db.batch(stmtAlertas(db, alertas, base)) : null;
}

// ---------- Resumo semanal (domingo 19h) ----------

// Linha de cada meta (mesmo texto de mbResumoMetas, no app). Saldo = soma dos saldos das aplicações ligadas à meta.
export function linhasMetas({ metas, saldos, hoje }) {
  return metas.filter((m) => m.nome).map((m) => {
    const saldo = (m.aplicacao_ids || []).reduce((s, id) => s + (saldos.get(id) || 0), 0);
    const alvo = m.valor_alvo > 0 ? m.valor_alvo : 0;
    const falta = Math.max(alvo - saldo, 0);
    const n = m.prazo ? dias(hoje, m.prazo.slice(0, 10)) : null;
    const partes = [
      alvo ? `${brl.format(saldo)} de ${brl.format(alvo)} (${Math.floor(Math.min(saldo / alvo, 1) * 100)}%)` : brl.format(saldo),
      !alvo && "defina o valor da meta",
      alvo && falta > 0 && `faltam ${brl.format(falta)}`,
      alvo && falta === 0 && "meta atingida",
      m.prazo && (n < 0 ? `prazo venceu em ${dm(m.prazo)}` : n === 0 ? "prazo é hoje" : `prazo ${dm(m.prazo)} (${n} ${n === 1 ? "dia" : "dias"})`),
    ].filter(Boolean);
    return `${m.nome}: ${partes.join(", ")}`;
  });
}

const TOP_CATEGORIAS = 3;

// Maiores categorias do ciclo (gasto líquido, sem Santander: `transacoes` já vem filtrado).
export function topCategorias({ transacoes, contas, resumo, registros, ctx }) {
  const cartao = idsCartao(contas);
  const nomes = new Map(doTipo(registros, "categorias").map((c) => [c.id, c.nome]));
  const soma = new Map();
  for (const t of transacoes) {
    if (t.scheduled || t.date < resumo.inicio || t.date > resumo.fim) continue;
    const c = cartao.has(t.account_id);
    const v = valorGasto(t, c) + valorParcela(t, c) - abatimento(t);
    if (!v) continue;
    const e = categoriaEfetiva(t, ctx, traduzir, false);
    const nome = (e.categoria_id && nomes.get(e.categoria_id)) || (e.category && traduzir(e.category)) || "Sem categoria";
    soma.set(nome, (soma.get(nome) || 0) + v);
  }
  return [...soma].filter(([, v]) => v > 0).sort((a, b) => b[1] - a[1]).slice(0, TOP_CATEGORIAS);
}

export function resumoSemanal({ resumo, transacoes, contas, hoje, registros = [], ctx = contextoDeRegistros([]), geral = null, revisar = [], metas = [] }) {
  const cartao = idsCartao(contas);
  const desde = somarDias(hoje, -6);
  const semana = transacoes.filter((t) => !t.scheduled && t.date >= desde && t.date <= hoje).reduce((s, t) => s + valorGasto(t, cartao.has(t.account_id)), 0);
  const linhas = [`Semana: ${brl.format(semana)}. Ciclo (${dm(resumo.inicio)} a ${dm(resumo.fim)}): ${brl.format(resumo.consumido)}.`];
  if (geral) linhas.push(geral.falta >= 0 ? `Geral: ${brl.format(geral.consumido)} de ${brl.format(geral.valor)}, faltam ${brl.format(geral.falta)}.` : `Geral: ${brl.format(geral.consumido)} de ${brl.format(geral.valor)}, ${brl.format(-geral.falta)} acima.`);
  const top = topCategorias({ transacoes, contas, resumo, registros, ctx });
  if (top.length) linhas.push(`Maiores: ${top.map(([n, v]) => `${n} ${brl.format(v)}`).join(", ")}.`);
  linhas.push(revisar.length ? `Para revisar: ${revisar.length} ${revisar.length === 1 ? "item" : "itens"}.` : "Para revisar: nada pendente.");
  linhas.push(...metas);
  return { chave: `semana:${hoje}`, titulo: "Resumo da semana", corpo: linhas.join("\n") };
}
