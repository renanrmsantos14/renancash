import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, entrarComSenha, ORIGEM } from "./ambiente.mjs";
import { somarDias } from "../src/ciclo.js";

const hoje = new Date().toLocaleDateString("sv", { timeZone: "America/Sao_Paulo" });

async function sincronizarCiclo(dias) {
  const amb = criarAmbiente();
  const token = await criarAparelho(amb.env);
  const agora = new Date().toISOString();
  const conta = (id, type, subtype, name, bank) =>
    amb.env.DB.prepare("INSERT INTO accounts (id, type, subtype, name, bank, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)").bind(id, type, subtype, name, bank, agora);
  await amb.env.DB.batch([conta("inter", "BANK", "CHECKING_ACCOUNT", "Conta", "Inter"), conta("st", "BANK", "CHECKING_ACCOUNT", "Conta", "Santander"), conta("stc", "CREDIT", null, "Cartão", "Santander")]);
  const tx = (id, conta, d, desc, valor) =>
    amb.env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'POSTED', 0, ?7)")
      .bind(id, conta, somarDias(hoje, -d), desc, valor, valor > 0 ? "CREDIT" : "DEBIT", agora);
  await amb.env.DB.batch([
    tx("s1", "inter", 70, "PAGAMENTO", 7500), tx("s2", "inter", 40, "PAGAMENTO", 7500), tx("s3", "inter", 10, "TRANSFERENCIA", 7450),
    tx("d13", "inter", 5, "13o SALARIO", 7500),
    tx("g1", "inter", 3, "MERCADO", -100), tx("g2", "st", 3, "MERCADO PAI", -900), tx("g3", "stc", 2, "LOJA PAI", 400),
  ]);
  const r = await amb.pedir("/api/sync", { headers: { authorization: "Bearer " + token } });
  return (await r.json()).ciclo;
}

test("GET /api/sync: ciclo vira no salário por valor, ignora 13º e Santander", async () => {
  const c = await sincronizarCiclo();
  assert.equal(c.inicio, somarDias(hoje, -10));
  assert.equal(c.semSalario, false);
  assert.equal(c.ultimoSalario, somarDias(hoje, -10));
  assert.equal(c.salarioNaoDetectado, false);
  assert.equal(c.gasto, 100);
});

test("PUT /api/config com salario_id guarda também o valor do salário", async () => {
  const amb = criarAmbiente();
  const cookie = await entrarComSenha(amb.pedir);
  const agora = new Date().toISOString();
  await amb.env.DB.batch([
    amb.env.DB.prepare("INSERT INTO accounts (id, type, subtype, name, bank, updated_at) VALUES ('inter', 'BANK', 'CHECKING_ACCOUNT', 'Conta', 'Inter', ?1)").bind(agora),
    amb.env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES ('s', 'inter', ?1, 'PAGAMENTO', 7500, 'CREDIT', 'POSTED', 0, ?2)").bind(hoje, agora),
  ]);
  const r = await amb.pedir("/api/config", { method: "PUT", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ salario_id: "s" }) });
  assert.equal(r.status, 200);
  const cfg = Object.fromEntries((await amb.env.DB.prepare("SELECT chave, valor FROM config").all()).results.map((x) => [x.chave, x.valor]));
  assert.deepEqual(cfg, { salario: "PAGAMENTO", salario_valor: "7500" });
});

test("alertas, resumo semanal e disponível não contam conta nem cartão do Santander", async () => {
  const amb = criarAmbiente();
  const token = await criarAparelho(amb.env);
  const agora = new Date().toISOString();
  const conta = (id, type, subtype, bank, saldo) =>
    amb.env.DB.prepare("INSERT INTO accounts (id, type, subtype, name, bank, balance, updated_at) VALUES (?1, ?2, ?3, 'Conta', ?4, ?5, ?6)").bind(id, type, subtype, bank, saldo, agora);
  const tx = (id, c, valor) =>
    amb.env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, type, status, scheduled, updated_at) VALUES (?1, ?2, ?3, 'MERCADO', ?4, 'DEBIT', 'POSTED', 0, ?5)").bind(id, c, somarDias(hoje, -1), valor, agora);
  await amb.env.DB.batch([
    conta("inter", "BANK", "CHECKING_ACCOUNT", "Inter", 100), conta("st", "BANK", "CHECKING_ACCOUNT", "Santander", 5000), conta("stc", "CREDIT", null, "Santander", -900),
    tx("g1", "inter", -100), tx("g2", "st", -900), tx("g3", "stc", 400),
  ]);
  await amb.worker.scheduled({ scheduledTime: Date.UTC(2026, 10, 8, 22, 7) }, amb.env, amb.ctx); // domingo 22h07 UTC = 19h07 BRT: resumo semanal
  await amb.esperar();
  const semana = await amb.env.DB.prepare("SELECT corpo FROM notificacoes WHERE chave LIKE 'semana:%'").first("corpo");
  assert.match(semana, /Semana: R\$\s100,00\./);
  const r = await (await amb.pedir("/api/notificacoes", { headers: { authorization: "Bearer " + token } })).json();
  assert.equal(r.resumo.disponivel, 100);
  assert.equal(r.resumo.consumido, 100);
});
