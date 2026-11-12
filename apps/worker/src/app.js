// src/app.js — token de aparelho e resposta de /api/app/transacoes (funções puras, testadas em test/app.test.mjs).
import { categoriaEfetiva } from "../public/regras.js";

const REGEX_TOKEN = /^mb_[A-Za-z0-9_-]{43}$/; // 32 bytes em base64url (43 chars, sem padding)

export const base64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export const gerarToken = () => "mb_" + base64url(crypto.getRandomValues(new Uint8Array(32)));

export async function hashToken(token) {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)));
  return [...h].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Extrai o token de "Authorization: Bearer mb_..."; null se ausente ou fora do formato.
export function tokenDoCabecalho(valor) {
  const m = /^Bearer (\S+)$/i.exec(valor || "");
  return m && REGEX_TOKEN.test(m[1]) ? m[1] : null;
}

// `desde` opcional (ISO). Devolve null (sem filtro), uma string ISO normalizada ou undefined se inválido.
export function normalizarDesde(valor) {
  if (valor == null || valor === "") return null;
  const t = Date.parse(valor);
  return Number.isNaN(t) ? undefined : new Date(t).toISOString();
}

export function montarResposta({ agora, contas, transacoes, pendentes, investimentos = [] }) {
  return {
    agora,
    contas: contas.map((c) => ({
      id: c.id, tipo: c.type, subtipo: c.subtype, nome: c.name, banco: c.bank, saldo: c.balance,
      limite: c.credit_limit, limite_disponivel: c.available_limit, vencimento: c.due_date,
    })),
    transacoes: transacoes.map((t) => ({
      id: t.id, conta_id: t.account_id, data: t.date, descricao: t.description, valor: t.amount, tipo: t.type,
      status: t.status, categoria: categoriaEfetiva(t), estabelecimento: t.merchant, futura: !!t.scheduled,
    })),
    ids_pendentes: pendentes.map((p) => p.id),
    investimentos, // lista completa a cada resposta (não segue o `desde`)
  };
}
