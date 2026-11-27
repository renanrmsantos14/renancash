// Alerta de saúde: cada falha simulada (Pluggy com erro, modelo inexistente, IA vazia, espelho fora, batimento atrasado),
// deduplicação, "voltou ao normal", rotas, ferramenta MCP e o disparo pelo cron. Tudo com mock: nada chama Pluggy nem Workers AI.
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, entrarComSenha, criarAparelho, hubMudo, restaurarFetch } from "./ambiente.mjs";
import { rodarSaude, verificar, lerSaude, CHAVE_RESULTADO } from "../src/saude.js";
import { registrarIa } from "../src/iaSaude.js";
import { sugerir } from "../src/ia.js";
import { tratarMcp } from "../src/mcp.js";

afterEach(restaurarFetch);

const AGORA = new Date("2026-11-27T10:07:00.000Z"); // 07h07 em São Paulo (tick do check)
const h = (horas) => new Date(AGORA.getTime() - horas * 3600_000).toISOString();
const dia = (n) => new Date(AGORA.getTime() - n * 86400_000).toISOString().slice(0, 10);

const IA_OK = { run: async () => ({ response: "ok" }) };
const hubOk = { idFromName: (n) => n, get: () => ({ fetch: async () => Response.json({ ok: true }) }) };

// Ambiente saudável: sincronizou há 1 h, conexão em dia, IA respondendo, espelho com escrita recente, cron e check em dia.
async function saudavel(extra = {}) {
  const amb = criarAmbiente({ AI: IA_OK, ESPELHO: "1", SAUDE: "1", ESPELHO_HUB: hubOk, ...extra });
  const db = amb.env.DB;
  await db.prepare("INSERT INTO sync_log (origem, started_at, finished_at, ok) VALUES ('cron', ?1, ?2, 1)").bind(h(1.1), h(1)).run();
  await db.prepare("INSERT INTO pluggy_items (id, conector, status, criado, atualizado) VALUES ('item-1', 'Banco Exemplo', 'UPDATED', ?1, ?2)").bind(h(900), h(2)).run();
  await db.prepare("INSERT INTO accounts (id, type, name, bank, item_id, updated_at) VALUES ('c1', 'BANK', 'Conta corrente', 'Banco Exemplo', 'item-1', ?1)").bind(h(1)).run();
  for (let i = 0; i < 12; i++) {
    await db.prepare("INSERT INTO transactions (id, account_id, date, description, amount, scheduled, updated_at) VALUES (?1, 'c1', ?2, 'COMPRA', -10, 0, ?3)").bind("t" + i, dia(1 + i * 5), h(1)).run();
  }
  await db.prepare("INSERT INTO espelho (tabela, pk, dados, updated_at, server_at) VALUES ('categories', 'k', '{}', ?1, ?1)").bind(h(5)).run();
  await db.prepare("INSERT INTO espelho_meta (chave, valor) VALUES ('semeado', '1')").run();
  await registrarIa(amb.env, "ok", null, new Date(AGORA.getTime() - 3600_000));
  await db.prepare("INSERT INTO snapshots (key, data, updated_at) VALUES (?1, ?2, ?3)").bind(CHAVE_RESULTADO, JSON.stringify({ verificado_em: h(24), status: "ok", itens: [] }), h(24)).run();
  return amb;
}

const rodar = (env, extra = {}) => {
  const envios = [];
  return rodarSaude(env, { agora: AGORA, enviarPendentes: async () => envios.push(1), ...extra }).then((r) => ({ ...r, envios: envios.length }));
};
const item = (r, id) => r.resultado.itens.find((i) => i.id === id);
const notificacoes = async (db) => (await db.prepare("SELECT chave, titulo, corpo FROM notificacoes ORDER BY chave").all()).results;

test("tudo certo: status ok e nenhum push", async () => {
  const { env } = await saudavel();
  const r = await rodar(env);
  assert.equal(r.resultado.status, "ok", JSON.stringify(r.resultado.itens.map((i) => [i.id, i.status, i.resumo])));
  assert.deepEqual(r.resultado.itens.map((i) => i.id), ["pluggy", "ia", "espelho", "cron"]);
  assert.equal(r.push, "nenhum");
  assert.equal(r.envios, 0);
  assert.deepEqual(await notificacoes(env.DB), []);
  const salvo = await lerSaude(env, AGORA);
  assert.equal(salvo.batimento_em, AGORA.toISOString());
  assert.equal(salvo.atrasado, false);
});

test("Pluggy: item que pede login de novo vira erro com o nome do banco e a ação", async () => {
  const { env } = await saudavel();
  await env.DB.prepare("UPDATE pluggy_items SET status = 'LOGIN_ERROR' WHERE id = 'item-1'").run();
  const r = await rodar(env);
  assert.equal(item(r, "pluggy").status, "erro");
  assert.match(item(r, "pluggy").resumo, /Banco Exemplo pede login de novo/);
  assert.match(item(r, "pluggy").acao, /reconecte/i);
  assert.equal(r.push, "problema");
  assert.equal(r.envios, 1);
  const [n] = await notificacoes(env.DB);
  assert.match(n.titulo, /Bancos \(Pluggy\) precisa de atenção/);
  assert.match(n.corpo, /pede login de novo.*O que fazer: Reconecte/is);
});

test("Pluggy: última sincronização antiga (atenção em 12 h, erro em 30 h) e falha sem sucesso depois", async () => {
  const { env } = await saudavel();
  await env.DB.prepare("UPDATE sync_log SET finished_at = ?1").bind(h(15)).run();
  assert.equal(item(await rodar(env), "pluggy").status, "atencao");
  await env.DB.prepare("UPDATE sync_log SET finished_at = ?1").bind(h(40)).run();
  const r = await rodar(env);
  assert.equal(item(r, "pluggy").status, "erro");
  assert.match(item(r, "pluggy").resumo, /há 40 h/);
  await env.DB.prepare("INSERT INTO sync_log (origem, started_at, finished_at, ok, message) VALUES ('cron', ?1, ?1, 0, 'boom')").bind(h(1)).run();
  assert.match(item(await rodar(env), "pluggy").resumo, /última sincronização falhou/);
});

test("Pluggy: conta que costuma ter movimento e ficou 7 dias sem transação nova", async () => {
  const { env } = await saudavel();
  await env.DB.prepare("DELETE FROM transactions WHERE date >= ?1").bind(dia(8)).run();
  const r = await rodar(env);
  assert.equal(item(r, "pluggy").status, "atencao");
  assert.match(item(r, "pluggy").resumo, /Banco Exemplo Conta corrente sem movimento novo há mais de 7 dias/);
  // conta que quase nunca tem movimento não alerta
  await env.DB.prepare("DELETE FROM transactions WHERE id NOT IN ('t10', 't11')").run();
  assert.equal(item(await rodar(env), "pluggy").status, "ok");
});

test("Pluggy: conta de conexão removida (histórico) não conta como sem movimento", async () => {
  const { env } = await saudavel();
  await env.DB.prepare("DELETE FROM transactions WHERE date >= ?1").bind(dia(8)).run();
  await env.DB.prepare("UPDATE pluggy_items SET removido = ?1 WHERE id = 'item-1'").bind(h(30)).run();
  assert.equal(item(await rodar(env), "pluggy").status, "ok");
});

test("Pluggy: conexão sem atualizar há mais de 3 dias", async () => {
  const { env } = await saudavel();
  await env.DB.prepare("UPDATE pluggy_items SET atualizado = ?1").bind(h(100)).run();
  const r = await rodar(env);
  assert.equal(item(r, "pluggy").status, "atencao");
  assert.match(item(r, "pluggy").resumo, /Banco Exemplo sem atualizar há 4 dias/);
});

test("IA: modelo que saiu do catálogo vira erro e o texto fala em catálogo", async () => {
  const { env } = await saudavel({ AI: { run: async () => { throw new Error("AiError: No such model @cf/meta/llama-3.1-8b-instruct"); } } });
  const r = await rodar(env);
  assert.equal(item(r, "ia").status, "erro");
  assert.match(item(r, "ia").resumo, /saiu do catálogo/);
  assert.equal(r.push, "problema");
});

test("IA: sem binding AI é atenção; timeout da sonda é erro", async () => {
  const { env } = await saudavel({ AI: undefined });
  assert.equal(item(await rodar(env), "ia").status, "atencao");
  const lento = (await saudavel({ AI: { run: () => new Promise(() => {}) } })).env;
  const r = await verificar(lento, AGORA, null, { ...(await import("../src/saude.js")).LIMITES, sonda_ms: 20 });
  assert.match(r.itens.find((i) => i.id === "ia").resumo, /timeout/);
});

test("IA: o seguro() registra a falha no contador sem quebrar a resposta ao app", async () => {
  const { env } = await saudavel({ AI: { run: async () => { throw new Error("modelo inexistente"); } } });
  const antes = console.error;
  console.error = () => {};
  try {
    const resposta = await sugerir(env, { contexto: { categorias: [{ pk: "c1", nome: "Mercado" }] }, lancamentos: [{ id: "1", descricao: "SUPERMERCADO X", valor: -50 }] });
    assert.deepEqual(resposta, { sugestoes: [], ia: false }, "o app continua recebendo resposta válida");
  } finally { console.error = antes; }
  const linha = await env.DB.prepare("SELECT SUM(erro) AS erro, MAX(ultimo_erro) AS msg FROM saude_ia").first();
  assert.equal(linha.erro, 1);
  assert.match(linha.msg, /modelo inexistente/);
  assert.doesNotMatch(linha.msg, /SUPERMERCADO/, "o log nunca leva descrição");
});

test("IA: taxa de erro alta nas últimas 24 h (atenção a partir de 20%, erro a partir de 50%)", async () => {
  const { env } = await saudavel();
  for (let i = 0; i < 7; i++) await registrarIa(env, "ok", null, AGORA);
  for (let i = 0; i < 3; i++) await registrarIa(env, "erro", "AiError: timeout", AGORA);
  const r = await rodar(env);
  assert.equal(item(r, "ia").status, "atencao");
  assert.match(item(r, "ia").resumo, /27% das chamadas da IA falharam em 24 h \(3 de 11\): AiError: timeout/);
  for (let i = 0; i < 20; i++) await registrarIa(env, "erro", "AiError: timeout", AGORA);
  assert.equal(item(await rodar(env), "ia").status, "erro");
});

test("IA: respostas vazias (modelo responde, mas quase nunca sugere) e janela de 24 h", async () => {
  const { env } = await saudavel();
  for (let i = 0; i < 25; i++) await registrarIa(env, "vazia", null, AGORA);
  const r = await rodar(env);
  assert.equal(item(r, "ia").status, "atencao");
  assert.match(item(r, "ia").resumo, /sem sugestão/);
  // falhas de antes da janela não contam
  const { env: env2 } = await saudavel();
  for (let i = 0; i < 20; i++) await registrarIa(env2, "erro", "velho", new Date(AGORA.getTime() - 30 * 3600_000));
  assert.equal(item(await rodar(env2), "ia").status, "ok");
});

test("Espelho: Durable Object fora do ar, tabela ausente e dias sem escrita (só informativo)", async () => {
  const fora = { idFromName: (n) => n, get: () => ({ fetch: async () => { throw new Error("DO reiniciando"); } }) };
  const { env } = await saudavel({ ESPELHO_HUB: fora });
  const r = await rodar(env);
  assert.equal(item(r, "espelho").status, "erro");
  assert.match(item(r, "espelho").resumo, /EspelhoHub não responde \(DO reiniciando\)/);

  const { env: e2 } = await saudavel();
  await e2.DB.prepare("DROP TABLE espelho_meta").run();
  assert.match(item(await rodar(e2), "espelho").resumo, /Faltam as tabelas espelho_meta/);

  const { env: e3 } = await saudavel();
  await e3.DB.prepare("UPDATE espelho SET server_at = ?1").bind(h(24 * 5)).run();
  const r3 = await rodar(e3);
  assert.equal(item(r3, "espelho").status, "ok"); // dias sem editar nada não é falha
  assert.match(item(r3, "espelho").detalhes.find((d) => d.nome === "Última escrita").texto, /Última escrita há 5 dias/);
});

test("Espelho desligado (ESPELHO=0) não é problema", async () => {
  const { env } = await saudavel({ ESPELHO: "0" });
  const r = await rodar(env);
  assert.equal(item(r, "espelho").status, "ok");
  assert.match(item(r, "espelho").resumo, /desligado/);
});

test("Cron: batimento do check diário atrasado e cron de sincronização parado", async () => {
  const { env } = await saudavel();
  await env.DB.prepare("UPDATE snapshots SET data = ?1 WHERE key = ?2").bind(JSON.stringify({ verificado_em: h(60), status: "ok", itens: [] }), CHAVE_RESULTADO).run();
  const r = await rodar(env);
  assert.equal(item(r, "cron").status, "atencao");
  assert.match(item(r, "cron").resumo, /check diário não rodou nas últimas 3 dias/);

  const { env: e2 } = await saudavel();
  await e2.DB.prepare("UPDATE sync_log SET started_at = ?1").bind(h(20)).run();
  const r2 = await rodar(e2);
  assert.equal(item(r2, "cron").status, "erro");
  assert.match(item(r2, "cron").resumo, /cron de sincronização não roda há 20 h/);
});

test("lerSaude: batimento atrasado (> 26 h) liga o aviso do app", async () => {
  const { env } = await saudavel();
  await rodar(env);
  assert.equal((await lerSaude(env, new Date(AGORA.getTime() + 25 * 3600_000))).atrasado, false);
  const tarde = await lerSaude(env, new Date(AGORA.getTime() + 27 * 3600_000));
  assert.equal(tarde.atrasado, true);
  assert.equal(tarde.batimento_em, AGORA.toISOString());
  assert.equal((await lerSaude(criarAmbiente().env, AGORA)).status, "desconhecido");
});

test("deduplicação: o mesmo problema não vira 2º push no mesmo dia; problema novo vira", async () => {
  const { env } = await saudavel();
  await env.DB.prepare("UPDATE pluggy_items SET status = 'LOGIN_ERROR' WHERE id = 'item-1'").run();
  assert.equal((await rodar(env)).push, "problema");
  const de_novo = await rodar(env);
  assert.equal(de_novo.push, "repetido");
  assert.equal(de_novo.envios, 0, "não dispara o push de novo");
  assert.equal((await notificacoes(env.DB)).length, 1);
  // outro problema no mesmo dia muda a assinatura e avisa
  await env.DB.prepare("UPDATE sync_log SET started_at = ?1").bind(h(20)).run();
  assert.equal((await rodar(env)).push, "problema");
  assert.equal((await notificacoes(env.DB)).length, 2);
  // no dia seguinte o mesmo problema avisa de novo (1 vez por dia)
  const amanha = new Date(AGORA.getTime() + 24 * 3600_000);
  const r = await rodar(env, { agora: amanha });
  assert.equal(r.push, "problema");
  assert.equal((await notificacoes(env.DB)).length, 3);
});

test("voltou ao normal: só depois de um dia com problema, uma vez", async () => {
  const { env } = await saudavel();
  await env.DB.prepare("UPDATE pluggy_items SET status = 'LOGIN_ERROR' WHERE id = 'item-1'").run();
  await rodar(env);
  await env.DB.prepare("UPDATE pluggy_items SET status = 'UPDATED' WHERE id = 'item-1'").run();
  const amanha = new Date(AGORA.getTime() + 24 * 3600_000);
  await env.DB.prepare("UPDATE sync_log SET finished_at = ?1, started_at = ?1").bind(new Date(amanha.getTime() - 3600_000).toISOString()).run();
  await env.DB.prepare("UPDATE pluggy_items SET atualizado = ?1").bind(new Date(amanha.getTime() - 3600_000).toISOString()).run();
  await env.DB.prepare("UPDATE espelho SET server_at = ?1").bind(new Date(amanha.getTime() - 3600_000).toISOString()).run();
  await env.DB.prepare("DELETE FROM saude_ia").run();
  await registrarIa(env, "ok", null, new Date(amanha.getTime() - 3600_000));
  const r = await rodar(env, { agora: amanha });
  assert.equal(r.resultado.status, "ok", JSON.stringify(r.resultado.itens.map((i) => [i.id, i.resumo])));
  assert.equal(r.push, "voltou");
  assert.equal(r.envios, 1);
  const todas = await notificacoes(env.DB);
  assert.ok(todas.some((n) => n.chave === "saude:ok:2026-11-28" && /voltou ao normal/i.test(n.titulo)));
  // um terceiro check, ainda ok, não repete
  assert.equal((await rodar(env, { agora: new Date(amanha.getTime() + 1000) })).push, "nenhum", "já voltou: o resultado anterior já era ok");
});

test("o check de saúde não diz 'voltou' sem problema anterior", async () => {
  const { env } = await saudavel();
  assert.equal((await rodar(env)).push, "nenhum");
  assert.equal((await rodar(env)).push, "nenhum");
});

test("rotas: GET /api/saude e POST /api/saude/verificar com o app; MCP saude em leitura", async () => {
  const { env, pedir } = await saudavel();
  assert.equal((await pedir("/api/saude")).status, 401, "sem login não lê");
  const cookie = await entrarComSenha(pedir);
  const antes = await (await pedir("/api/saude", { headers: { cookie } })).json();
  assert.equal(antes.status, "ok", "lê o resultado gravado (o de ontem)");
  await env.DB.prepare("UPDATE pluggy_items SET status = 'LOGIN_ERROR' WHERE id = 'item-1'").run();
  const token = await criarAparelho(env);
  const r = await pedir("/api/saude/verificar", { method: "POST", headers: { authorization: "Bearer " + token } });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).status, "erro");
  const depois = await (await pedir("/api/saude", { headers: { authorization: "Bearer " + token } })).json();
  assert.equal(depois.itens.find((i) => i.id === "pluggy").status, "erro");
  assert.equal(depois.atrasado, false);

  const mcp = async (method, params) => (await (await tratarMcp(new Request("https://x.test/mcp", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }), env, { waitUntil() {} }, { baseCiclo: async () => ({}), atualizar: async () => ({}), enviarPendentes: async () => 0 })).json()).result;
  const ferramenta = (await mcp("tools/list")).tools.find((t) => t.name === "saude");
  assert.equal(ferramenta.annotations.readOnlyHint, true, "a ferramenta saude é só leitura");
  const chamada = await mcp("tools/call", { name: "saude", arguments: {} });
  const dados = JSON.parse(chamada.content[0].text);
  assert.equal(dados.status, "erro");
  assert.equal(dados.itens.find((i) => i.id === "pluggy").status, "erro");
});

test("cron: o tick das 10h UTC roda o check, grava a notificação e dispara o push (mock)", async () => {
  const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const { env, ctx, worker, esperar } = await saudavel({
    VAPID_PRIVADA: JSON.stringify(await crypto.subtle.exportKey("jwk", par.privateKey)), VAPID_PUBLICA: "pub", VAPID_ASSUNTO: "mailto:teste@exemplo.test",
  });
  await env.DB.prepare("UPDATE pluggy_items SET status = 'LOGIN_ERROR'").run();
  await env.DB.prepare("INSERT INTO push_inscricoes (endpoint, criada) VALUES ('https://push.exemplo.test/abc', ?1)").bind(h(1)).run();
  const pushes = [];
  const fetchOriginal = globalThis.fetch;
  globalThis.fetch = async (alvo, init) => { pushes.push(String(alvo)); return new Response(null, { status: 201 }); };
  try {
    // 10h07 UTC = 07h07 BRT: fim do silêncio (22h-7h), o push sai na hora
    await worker.scheduled({ cron: "7 1,4,7,10,13,16,19,22 * * *", scheduledTime: Date.UTC(2026, 10, 27, 10, 7) }, env, ctx);
    await esperar();
  } finally { globalThis.fetch = fetchOriginal; }
  const [n] = await notificacoes(env.DB);
  assert.match(n.chave, /^saude:\d{4}-\d{2}-\d{2}:pluggy-erro/);
  assert.equal(pushes.length, 1, "1 push para o aparelho inscrito");
  assert.match(String(pushes[0]), /push\.exemplo\.test/);
  const sync = await env.DB.prepare("SELECT COUNT(*) AS n FROM sync_log").first("n");
  assert.equal(sync, 2, "o tick sincroniza primeiro (1 linha já existia) e só então roda o check");
});
