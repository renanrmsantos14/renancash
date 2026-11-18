import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, entrarComSenha, simularPluggy, restaurarFetch } from "./ambiente.mjs";

afterEach(restaurarFetch);
const ID_A = "11111111-1111-4111-8111-111111111111";
const ENV = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo", PLUGGY_ITEM_IDS: ID_A };
const CONTA = { id: "c1", itemId: ID_A, type: "BANK", subtype: "SAVINGS_ACCOUNT", name: "Poupança", number: "123", balance: 0.33, currencyCode: "BRL", bankData: { transferNumber: "0001/123", closingBalance: 600.33, automaticallyInvestedBalance: 600 }, availableBalance: 600.33, owner: "segredo-pessoal", creditData: { creditLimit: 1000, availableCreditLimit: 400, brand: "X" } };
const INV = { id: "i1", name: "CDB", type: "FIXED_INCOME", subtype: "CDB", balance: 10, amount: 9, date: "2026-11-01", status: "ACTIVE", code: "x" };
const rotas = (u) => (u.pathname === "/accounts" ? { results: [CONTA] } : u.pathname === "/investments" ? { results: [INV], totalPages: 1 } : {});

test("contas-brutas exige sessão e não chama o Pluggy sem ela", async () => {
  const { pedir } = criarAmbiente(ENV);
  const { chamadas } = simularPluggy(rotas);
  assert.equal((await pedir("/api/pluggy/contas-brutas")).status, 401);
  assert.equal(chamadas.length, 0);
});

test("contas-brutas devolve bankData, campos de saldo e investimentos resumidos", async () => {
  const { pedir } = criarAmbiente(ENV);
  const cookie = await entrarComSenha(pedir);
  simularPluggy(rotas);
  const r = await pedir("/api/pluggy/contas-brutas", { headers: { cookie } });
  assert.equal(r.status, 200);
  const [con] = (await r.json()).conexoes;
  assert.equal(con.itemId, ID_A);
  assert.equal(con.contas[0].bankData.closingBalance, 600.33);
  assert.equal(con.contas[0].balance, 0.33);
  assert.equal(con.contas[0].availableBalance, 600.33);
  assert.equal("owner" in con.contas[0], false);
  assert.deepEqual(con.contas[0].creditData, { creditLimit: 1000, availableCreditLimit: 400 });
  assert.deepEqual(con.investimentos, [{ id: "i1", name: "CDB", type: "FIXED_INCOME", subtype: "CDB", balance: 10, amount: 9, date: "2026-11-01", status: "ACTIVE" }]);
});

test("contas-brutas não grava nada no D1", async () => {
  const { env, pedir } = criarAmbiente(ENV);
  const cookie = await entrarComSenha(pedir);
  simularPluggy(rotas);
  const gravacoes = [];
  const prepare = env.DB.prepare.bind(env.DB);
  env.DB.prepare = (sql) => { if (!/^\s*select/i.test(sql)) gravacoes.push(sql); return prepare(sql); };
  assert.equal((await pedir("/api/pluggy/contas-brutas", { headers: { cookie } })).status, 200);
  assert.deepEqual(gravacoes, []);
});
