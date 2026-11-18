// Diagnóstico só de leitura: saldos crus da Pluggy, sem passar pelo mapeamento e sem gravar no D1.
const CAMPOS = ["id", "itemId", "type", "subtype", "name", "number", "balance", "currencyCode", "bankData"];

// Campos de saldo além da lista fixa (balances, availableBalance, blockedBalance...).
function resumirConta(c) {
  const r = {};
  for (const k of CAMPOS) if (k in c) r[k] = c[k];
  for (const k of Object.keys(c)) if (!(k in r) && /balance/i.test(k)) r[k] = c[k];
  if (c.creditData) r.creditData = { creditLimit: c.creditData.creditLimit, availableCreditLimit: c.creditData.availableCreditLimit };
  return r;
}

const resumirInvestimento = (i) => ({ id: i.id, name: i.name, type: i.type, subtype: i.subtype, balance: i.balance, amount: i.amount, date: i.date, status: i.status });

// Ids das conexões sem semear o D1 (idsConexoes grava): D1 se já tiver conexões, senão o secret PLUGGY_ITEM_IDS.
export async function idsSomenteLeitura(db, env) {
  const total = await db.prepare("SELECT count(*) AS n FROM pluggy_items").first("n");
  if (!total) return (env.PLUGGY_ITEM_IDS || "").split(",").map((s) => s.trim()).filter(Boolean);
  const { results } = await db.prepare("SELECT id FROM pluggy_items WHERE removido IS NULL ORDER BY criado, id").all();
  return results.map((r) => r.id);
}

export async function contasBrutas(api) {
  const conexoes = await Promise.all((await api.listarIds()).map(async (itemId) => {
    const [contas, investimentos] = await Promise.allSettled([api.contas(itemId), api.investimentos(itemId)]);
    return {
      itemId,
      contas: contas.status === "fulfilled" ? contas.value.map(resumirConta) : { erro: contas.reason?.message },
      investimentos: investimentos.status === "fulfilled" ? investimentos.value.map(resumirInvestimento) : { erro: investimentos.reason?.message },
    };
  }));
  return { conexoes };
}
