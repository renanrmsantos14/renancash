// src/app.js — token de aparelho e resposta de /api/app/transacoes (funções puras, testadas em test/app.test.mjs).
import { categoriaEfetiva } from "../public/regras.js";

const REGEX_TOKEN = /^mb_[A-Za-z0-9_-]{43}$/; // 32 bytes em base64url (43 chars, sem padding)

export const base64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export const gerarToken = (prefixo = "mb_") => prefixo + base64url(crypto.getRandomValues(new Uint8Array(32)));
export const agoraTs = () => new Date().toISOString();
export const DIAS_REIMPORTAR = 10; // relê os últimos dias para pegar lançamentos que o banco posta com atraso (sync e IA)
export const agoraS = () => Math.floor(Date.now() / 1000);
export const diaSP = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" });
export const hojeSP = () => diaSP.format(new Date());

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

export function montarResposta({ agora, contas, transacoes, pendentes }) {
  return {
    agora,
    contas: contas.map((c) => ({
      id: c.id, tipo: c.type, nome: c.name, banco: c.bank, saldo: c.balance,
      limite: c.credit_limit, limite_disponivel: c.available_limit, vencimento: c.due_date,
    })),
    transacoes: transacoes.map((t) => ({
      id: t.id, conta_id: t.account_id, data: t.date, descricao: t.description, valor: t.amount, tipo: t.type,
      status: t.status, categoria: categoriaEfetiva(t), estabelecimento: t.merchant, futura: !!t.scheduled,
    })),
    ids_pendentes: pendentes.map((p) => p.id),
  };
}
