import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, simularPluggy, restaurarFetch } from "./ambiente.mjs";
import { registrarItem } from "../src/pluggy.js";

afterEach(restaurarFetch);
const ID = "22222222-2222-4222-8222-222222222222";
const ENV = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo" };

async function sincronizarCom(investimentos) {
  const amb = criarAmbiente(ENV);
  await registrarItem(amb.env.DB, ID, new Date(Date.now() - 100 * 60_000).toISOString());
  const token = await criarAparelho(amb.env);
  simularPluggy((u) => {
    if (u.pathname.startsWith("/items/")) return { id: ID, status: "UPDATED", connector: { name: "Meu Pluggy" } };
    if (u.pathname === "/accounts") return { results: [{ id: "cc", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Banco Santander Pessoa Física", number: "57-2", balance: 10 }] };
    if (u.pathname === "/investments") return investimentos();
    return { results: [] };
  });
  await amb.worker.scheduled({ scheduledTime: Date.UTC(2026, 10, 9, 12, 7) }, amb.env, amb.ctx);
  await amb.esperar();
  const r = await amb.pedir("/api/sync", { headers: { authorization: "Bearer " + token } });
  return { amb, token, corpo: await r.json() };
}

test("investimentos do Pluggy chegam ao app com banco e subtipo da conta", async () => {
  const { corpo } = await sincronizarCom(() => ({ totalPages: 1, results: [{ id: "i1", name: "CDB", type: "FIXED_INCOME", balance: 1500, status: "ACTIVE" }] }));
  assert.deepEqual(corpo.investimentos, [{ id: "i1", nome: "CDB", tipo: "FIXED_INCOME", saldo: 1500, banco: "Banco Santander Pessoa Física" }]);
  assert.equal(corpo.contas[0].subtype, "CHECKING_ACCOUNT");
});

test("investimentos sem permissão (403) não viram aviso nem derrubam a sincronização", async () => {
  const { amb, corpo } = await sincronizarCom(() => Response.json({ message: "Forbidden" }, { status: 403 }));
  assert.deepEqual(corpo.investimentos, []);
  const log = await amb.env.DB.prepare("SELECT ok, message FROM sync_log").first();
  assert.deepEqual([log.ok, log.message], [1, "OK"]);
});
