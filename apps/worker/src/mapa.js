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
    minimum_payment: num(c.creditData?.minimumPayment),
    overdraft_limit: num(c.bankData?.overdraftContractedLimit),
    overdraft_used: num(c.bankData?.overdraftUsedLimit),
    auto_invested: num(c.bankData?.automaticallyInvestedBalance),
    bank: banco,
    item_id: itemId,
    updated_at: ts,
  };
}

// Sinal pelo tipo (não confia no sinal da API): conta corrente, saída negativa e entrada positiva;
// cartão, compra positiva e estorno/pagamento negativo. Data depois de hoje = parcela futura (scheduled).
const soDigitos = (v) => (v ? String(v).replace(/\D/g, "") : "");

// Outra ponta da transação (paymentData): quem recebeu numa saída, quem pagou numa entrada. `entre_minhas` = 1 quando o
// documento dela é o do titular (CPF/CNPJ completo dos dois lados), 0 quando é outro, null quando não dá para saber.
export function contraparteDe(t, docTitular) {
  const pd = t.paymentData;
  if (!pd) return { contraparte: null, metodo: null, entre_minhas: null };
  const outra = t.type === "DEBIT" ? pd.receiver : pd.payer;
  const doc = soDigitos(outra?.documentNumber?.value);
  const meu = soDigitos(docTitular);
  return {
    contraparte: outra?.name?.trim() || null,
    metodo: pd.paymentMethod ?? null,
    entre_minhas: doc.length >= 11 && meu.length >= 11 ? (doc === meu ? 1 : 0) : null,
  };
}

export function mapearTransacao(t, conta, hoje, ts, docTitular = null) {
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
    bill_id: m?.billId ?? null,
    bill_month: /^\d{4}-\d{2}/.test(m?.billForecastDate ?? "") ? m.billForecastDate.slice(0, 7) : null,
    ...contraparteDe(t, docTitular),
    tipo_credito: m?.otherCreditsType || m?.feeType || null,
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

// Situação da fatura fechada pelos pagamentos (payments[] do /bills): PAID quando cobrem o total, PARTIAL quando
// cobrem parte, CLOSED quando o banco não informa pagamento nenhum (não quer dizer que não foi paga).
export function situacaoFatura(b) {
  const pagos = (b.payments || []).map((p) => num(p.amount)).filter((v) => v != null);
  const pago = Math.round(pagos.reduce((s, v) => s + Math.abs(v), 0) * 100) / 100;
  const total = num(b.totalAmount) ?? 0;
  const situacao = !pagos.length ? "CLOSED" : pago + 0.01 >= total ? "PAID" : pago > 0 ? "PARTIAL" : "CLOSED";
  return { situacao, pago: pagos.length ? pago : null };
}

// Juros, multa e IOF cobrados na fatura (financeCharges[]). Null quando o banco não informa.
function encargosFatura(b) {
  const v = (b.financeCharges || []).map((c) => num(c.amount)).filter((x) => x != null);
  return v.length ? Math.round(v.reduce((s, x) => s + Math.abs(x), 0) * 100) / 100 : null;
}

// Snapshot "faturas:<conta>" no formato que o painel lê. A aberta vem do saldo e do vencimento atual da conta,
// com o pagamento mínimo de creditData.
export function mapearFaturas(contaPluggy, bills) {
  const venc = dia(contaPluggy.creditData?.balanceDueDate);
  const saldo = num(contaPluggy.balance);
  return {
    results: bills
      .filter((b) => dia(b.dueDate) !== venc)
      .map((b) => {
        const { situacao, pago } = situacaoFatura(b);
        return { id: b.id, dueDate: b.dueDate, totalAmount: b.totalAmount, payment_status: situacao, pago, minimo: num(b.minimumPaymentAmount), encargos: encargosFatura(b) };
      }),
    open_bill: venc ? { available: true, due_date: venc, total_amount: saldo, minimum_payment: num(contaPluggy.creditData?.minimumPayment) } : null,
    total_pending_debt: saldo,
  };
}

// Investimentos de uma conexão, para o app somar no patrimônio. Resgate total (TOTAL_WITHDRAWAL) e sem saldo ficam fora.
// `banco`: o da conexão ou, no Meu Pluggy, o nome da conta corrente da mesma conexão sem o final do número.
export function mapearInvestimentos(lista, banco, contasDaConexao, aplicadoPorId = new Map()) {
  const nomeBanco = banco || contasDaConexao.find((c) => c.type === "BANK")?.name?.replace(/\s*[·#].*$/, "") || null;
  // Saldo bruto (amount), o mesmo que o app do banco mostra; o balance é o líquido.
  return lista
    .map((i) => ({ i, saldo: typeof i.amount === "number" && Number.isFinite(i.amount) ? i.amount : num(i.balance) }))
    .filter(({ i, saldo }) => i.status !== "TOTAL_WITHDRAWAL" && saldo != null)
    .map(({ i, saldo }) => ({ id: String(i.id), nome: i.name || i.type || "Investimento", tipo: i.type ?? null, saldo, banco: nomeBanco, ...detalhesInvestimento(aplicadoPorId.has(String(i.id)) && num(i.amountOriginal) == null ? { ...i, amountOriginal: aplicadoPorId.get(String(i.id)) } : i, saldo) }));
}

// Investimentos sem amountOriginal (comum no Open Finance) que valem a consulta das movimentações.
export const semAplicado = (lista) => lista.filter((i) => i.status !== "TOTAL_WITHDRAWAL" && num(i.amountOriginal) == null && i.id != null);

// Aplicado pelas movimentações: compras (BUY) menos resgates (SELL). O resgate inclui o que já rendeu, então depois de um
// resgate parcial o valor fica abaixo do real; resultado <= 0 ou sem compra nenhuma = null (não dá para saber).
export function aplicadoPelasMovimentacoes(movs) {
  let compras = 0, resgates = 0, temCompra = false;
  for (const m of movs || []) {
    const v = Math.abs(num(m.amount) ?? num(m.netAmount) ?? 0);
    if (m.type === "BUY") { compras += v; temCompra = true; }
    else if (m.type === "SELL") resgates += v;
  }
  const aplicado = Math.round((compras - resgates) * 100) / 100;
  return temCompra && aplicado > 0 ? aplicado : null;
}

// O que o Pluggy informa além do saldo (objeto Investment). Campo que o banco não manda fica null e o app esconde.
// `aplicado` = amountOriginal. `rendimento` = saldo bruto − aplicado (o mesmo critério do saldo, que é o bruto);
// sem `aplicado`, usa amountProfit. `liquido` = balance (já sem IR e IOF). Taxas em %, como o Pluggy manda.
export function detalhesInvestimento(i, saldo) {
  const aplicado = num(i.amountOriginal);
  const ir = num(i.taxes), iof = num(i.taxes2);
  const centavos = (v) => Math.round(v * 100) / 100;
  return {
    subtipo: i.subtype ?? null,
    aplicado,
    rendimento: aplicado != null ? centavos(saldo - aplicado) : num(i.amountProfit),
    liquido: num(i.balance),
    impostos: ir == null && iof == null ? null : centavos((ir ?? 0) + (iof ?? 0)),
    // "110% do CDI" (rate + rateType) ou prefixada ("12,5% a.a.", fixedAnnualRate).
    taxa: num(i.rate) != null ? { valor: num(i.rate), indexador: i.rateType || null }
      : num(i.fixedAnnualRate) != null ? { valor: num(i.fixedAnnualRate), indexador: "PRE" } : null,
    rentabilidade_mes: num(i.lastMonthRate),
    rentabilidade_12m: num(i.lastTwelveMonthsRate),
    vencimento: dia(i.dueDate),
    aplicado_em: dia(i.purchaseDate) ?? dia(i.issueDate),
    emissor: i.issuer ?? null,
    isento_ir: typeof i.taxExempt === "boolean" ? i.taxExempt : null,
  };
}
