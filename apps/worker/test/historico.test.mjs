import { test, afterEach, mock } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, simularPluggy, restaurarFetch } from "./ambiente.mjs";
import { registrarItem } from "../src/pluggy.js";
import { mesSP, registrarRetrato, serieMensal } from "../src/historico.js";

let relogioLigado = false;
afterEach(() => { restaurarFetch(); mock.timers.reset(); relogioLigado = false; });

const ID = "22222222-2222-4222-8222-222222222222";
const ENV = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo" };
const item = (id, nome, saldo, banco = "Inter") => ({ id, nome, banco, saldo });

test("mês é o de São Paulo: 23h do último dia ainda é o mês antigo, 00h SP já é o novo", () => {
  assert.equal(mesSP(new Date("2026-12-01T02:59:00Z")), "2026-11"); // 30/11 23:59 em SP
  assert.equal(mesSP(new Date("2026-12-01T03:00:00Z")), "2026-12"); // 01/12 00:00 em SP
});

test("o retrato do mês é refeito a cada leitura e os meses anteriores ficam congelados", () => {
  let h = registrarRetrato({}, [item("a", "CDB", 100), item("b", "LCI", 50, "Santander")], "2026-10");
  h = registrarRetrato(h, [item("a", "CDB", 120), item("b", "LCI", 55, "Santander")], "2026-11");
  h = registrarRetrato(h, [item("a", "CDB", 130)], "2026-11"); // "b" foi resgatada em novembro
  assert.deepEqual(h["2026-10"].map((i) => i.saldo), [100, 50]);
  assert.deepEqual(h["2026-11"], [{ ...item("a", "CDB", 130), aplicado: null }]);
  assert.deepEqual(serieMensal(h).map((m) => m.mes), ["2026-10", "2026-11"]);
});

test("serieMensal sem histórico é lista vazia", () => {
  assert.deepEqual(serieMensal(null), []);
});

async function sincronizar(amb, agora, investimentos) {
  if (relogioLigado) mock.timers.setTime(Date.parse(agora));
  else { mock.timers.enable({ apis: ["Date"], now: new Date(agora) }); relogioLigado = true; }
  simularPluggy((u) => {
    if (u.pathname.startsWith("/items/")) return { id: ID, status: "UPDATED", connector: { name: "Meu Pluggy" } };
    if (u.pathname === "/accounts") return { results: [{ id: "cc", type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Banco Santander Pessoa Física", number: "57-2", balance: 10 }] };
    if (u.pathname === "/investments") return investimentos();
    return { results: [] };
  });
  await amb.worker.scheduled({ scheduledTime: Date.parse(agora) }, amb.env, amb.ctx);
  await amb.esperar();
}
const inv = (...itens) => ({ totalPages: 1, results: itens.map(([id, name, balance, status]) => ({ id, name, type: "FIXED_INCOME", balance, status: status || "ACTIVE" })) });

test("série no /api/sync: um retrato por mês, virada de mês em SP e aplicação que some", async () => {
  const amb = criarAmbiente(ENV);
  await registrarItem(amb.env.DB, ID, "2026-01-01T00:00:00.000Z");
  const token = await criarAparelho(amb.env);
  await sincronizar(amb, "2026-11-20T15:00:00Z", () => inv(["i1", "CDB", 1000], ["i2", "Poupança", 500]));
  await sincronizar(amb, "2026-12-01T02:30:00Z", () => inv(["i1", "CDB", 1100], ["i2", "Poupança", 520])); // ainda 30/11 em SP
  await sincronizar(amb, "2026-12-01T03:30:00Z", () => inv(["i1", "CDB", 1150], ["i2", "Poupança", 0, "TOTAL_WITHDRAWAL"])); // 01/12: i2 resgatada
  mock.timers.reset();
  const corpo = await (await amb.pedir("/api/sync", { headers: { authorization: "Bearer " + token } })).json();
  assert.deepEqual(corpo.investimentos_mensal.map((m) => m.mes), ["2026-11", "2026-12"]);
  assert.deepEqual(corpo.investimentos_mensal[0].itens.map((i) => [i.id, i.saldo]), [["i1", 1100], ["i2", 520]]); // última leitura de novembro
  assert.deepEqual(corpo.investimentos_mensal[1].itens.map((i) => [i.id, i.saldo]), [["i1", 1150]]);
  assert.equal(corpo.investimentos_mensal[0].itens[0].banco, "Banco Santander Pessoa Física");
});

test("leitura sem aplicações (403) não cria nem apaga retrato; /api/sync sem histórico devolve lista vazia", async () => {
  const amb = criarAmbiente(ENV);
  await registrarItem(amb.env.DB, ID, "2026-01-01T00:00:00.000Z");
  const token = await criarAparelho(amb.env);
  await sincronizar(amb, "2026-11-20T15:00:00Z", () => Response.json({ message: "Forbidden" }, { status: 403 }));
  let corpo = await (await amb.pedir("/api/sync", { headers: { authorization: "Bearer " + token } })).json();
  assert.deepEqual(corpo.investimentos_mensal, []);
  await sincronizar(amb, "2026-11-21T15:00:00Z", () => inv(["i1", "CDB", 10]));
  await sincronizar(amb, "2026-11-22T15:00:00Z", () => Response.json({ message: "Forbidden" }, { status: 403 }));
  mock.timers.reset();
  corpo = await (await amb.pedir("/api/sync", { headers: { authorization: "Bearer " + token } })).json();
  assert.equal(corpo.investimentos_mensal[0].itens[0].saldo, 10);
});

test("resgate total grava o mês vazio; leitura que falhou depois de ter snapshot não grava dado velho", async () => {
  const amb = criarAmbiente(ENV);
  await registrarItem(amb.env.DB, ID, "2026-01-01T00:00:00.000Z");
  const token = await criarAparelho(amb.env);
  await sincronizar(amb, "2026-10-20T15:00:00Z", () => inv(["i1", "CDB", 10]));
  await sincronizar(amb, "2026-11-02T15:00:00Z", () => Response.json({ message: "erro" }, { status: 500 }));
  let corpo = await (await amb.pedir("/api/sync", { headers: { authorization: "Bearer " + token } })).json();
  assert.deepEqual(corpo.investimentos_mensal.map((m) => m.mes), ["2026-10"]);
  await sincronizar(amb, "2026-11-03T15:00:00Z", () => inv());
  mock.timers.reset();
  corpo = await (await amb.pedir("/api/sync", { headers: { authorization: "Bearer " + token } })).json();
  assert.deepEqual(corpo.investimentos_mensal.map((m) => [m.mes, m.itens.length]), [["2026-10", 1], ["2026-11", 0]]);
});
