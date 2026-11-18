// Traduz o formato do Pluggy para o contrato interno (tabelas accounts/transactions e snapshot de faturas).

const MEU_PLUGGY = /meu\s*pluggy/i;
export const PROBLEMA = /LOGIN_ERROR|WAITING_USER/; // status do item que pede novo login (OUTDATED = só falha temporária)
const ROTULO = { CREDIT: "Cartão", BANK: "Conta" };

const num = (v) => (v == null || v === "" || !Number.isFinite(Number(v)) ? null : Number(v));
const dia = (v) => (v ? String(v).slice(0, 10) : null);

// Banco da conexão. No Meu Pluggy o connector é sempre "Meu Pluggy" (não é um banco): fica sem banco
// e o nome da conta (ex.: "Cartão Santander") é usado como veio.
export function bancoDoItem(item) {
  const nome = item?.connector?.name;
  return nome && !MEU_PLUGGY.test(nome) ? nome : null;
}

// Nome que identifica o banco ("Cartão Santander"), sem repetir se a conta já o traz no nome.
export function nomeConta(c, banco) {
  const base = c.marketingName || c.name || ROTULO[c.type] || "Conta";
  if (!banco || base.toLowerCase().includes(banco.toLowerCase())) return base;
  return `${base} ${banco}`;
}

// Contas de bancos diferentes podem chegar com o mesmo nome: acrescenta o final do número (ou a posição) só nas repetidas.
export function desambiguar(linhas) {
  const vezes = new Map();
  for (const l of linhas) vezes.set(l.name, (vezes.get(l.name) || 0) + 1);
  linhas.forEach((l, i) => {
    if (vezes.get(l.name) > 1) l.name += l.number ? ` ·${String(l.number).slice(-4)}` : ` #${i + 1}`;
  });
  return linhas;
}

// Poupança do Inter: o balance da Pluggy fica travado (R$ 0,33); o saldo real vem em bankData.closingBalance.
function saldoConta(c) {
  const saldo = num(c.balance);
  const fechamento = c.bankData?.closingBalance;
  return c.subtype === "SAVINGS_ACCOUNT" && typeof fechamento === "number" && Number.isFinite(fechamento) && fechamento > (saldo ?? -Infinity) ? fechamento : saldo;
}

export function mapearConta(c, banco, itemId, ts) {
  return {
    id: String(c.id),
    type: c.type,
    subtype: c.subtype ?? null,
    name: nomeConta(c, banco),
    number: c.number ?? null,
    balance: saldoConta(c),
    credit_limit: num(c.creditData?.creditLimit),
    available_limit: num(c.creditData?.availableCreditLimit),
    due_date: dia(c.creditData?.balanceDueDate),
    closing_date: dia(c.creditData?.balanceCloseDate),
    bank: banco,
    item_id: itemId,
    updated_at: ts,
  };
}

// Sinal pelo tipo (não confia no sinal da API): conta corrente, saída negativa e entrada positiva;
// cartão, compra positiva e estorno/pagamento negativo. Data depois de hoje = parcela futura (scheduled).
export function mapearTransacao(t, conta, hoje, ts) {
  const abs = Math.abs(num(t.amount) ?? 0);
  const saida = t.type === "DEBIT";
  const date = dia(t.date);
  const m = t.creditCardMetadata;
  const parcela = m?.totalInstallments > 1 && m.installmentNumber ? `${m.installmentNumber}/${m.totalInstallments}` : "";
  const descricao = t.description ?? "";
  return {
    id: String(t.id),
    account_id: conta.id,
    date,
    description: parcela && !descricao.includes(parcela) ? `${descricao} ${parcela}` : descricao,
    amount: t.type === "DEBIT" || t.type === "CREDIT" ? ((conta.type === "CREDIT" ? saida : !saida) ? abs : -abs) : num(t.amount) ?? 0, // sem tipo, vale o sinal da API
    type: t.type ?? null,
    status: t.status ?? null,
    category: t.category ?? null,
    merchant: t.merchant?.name || t.merchant?.businessName || null,
    scheduled: date > hoje ? 1 : 0,
    updated_at: ts,
  };
}

// Aviso de reconexão (item com login pendente); o Meu Pluggy não tem link direto, então aponta para o portal.
export function avisoItem(item, banco) {
  if (!PROBLEMA.test(item.status || "")) return null;
  return {
    item_id: item.id,
    banco: banco || item.connector?.name || "Conexão",
    mensagem: `A conexão não atualizou (${item.status}${item.error?.message ? ": " + item.error.message : ""}). Reconecte no Meu Pluggy e confirme no app do banco.`,
    reconnect_url: "https://meu.pluggy.ai",
  };
}

// Snapshot "faturas:<conta>" no formato que o painel lê. O Pluggy não informa a situação das faturas
// (todas vêm como "Fechada"); a aberta vem do saldo e do vencimento atual da conta.
export function mapearFaturas(contaPluggy, bills) {
  const venc = dia(contaPluggy.creditData?.balanceDueDate);
  const saldo = num(contaPluggy.balance);
  return {
    results: bills
      .filter((b) => dia(b.dueDate) !== venc)
      .map((b) => ({ id: b.id, dueDate: b.dueDate, totalAmount: b.totalAmount, payment_status: "CLOSED" })),
    open_bill: venc ? { available: true, due_date: venc, total_amount: saldo } : null,
    total_pending_debt: saldo,
  };
}

// Investimentos de uma conexão, para o app somar no patrimônio. Resgate total (TOTAL_WITHDRAWAL) e sem saldo ficam fora.
// `banco`: o da conexão ou, no Meu Pluggy, o nome da conta corrente da mesma conexão sem o final do número.
export function mapearInvestimentos(lista, banco, contasDaConexao) {
  const nomeBanco = banco || contasDaConexao.find((c) => c.type === "BANK")?.name?.replace(/\s*[·#].*$/, "") || null;
  // Saldo bruto (amount), o mesmo que o app do banco mostra; o balance é o líquido.
  return lista
    .map((i) => ({ i, saldo: typeof i.amount === "number" && Number.isFinite(i.amount) ? i.amount : num(i.balance) }))
    .filter(({ i, saldo }) => i.status !== "TOTAL_WITHDRAWAL" && saldo != null)
    .map(({ i, saldo }) => ({ id: String(i.id), nome: i.name || i.type || "Investimento", tipo: i.type ?? null, saldo, banco: nomeBanco }));
}
