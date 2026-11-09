# Núcleo: ciclo do salário, limite e alertas — Plano de implementação

> **Para agentes:** use superpowers:subagent-driven-development (recomendado) ou superpowers:executing-plans, tarefa por tarefa. Passos com checkbox (`- [ ]`). Implementar com **Sonnet** (nunca Fable).

**Objetivo:** mostrar quanto já foi gasto no ciclo do salário em relação a um limite total, e avisar no Android (push do PWA) quando o limite chegar a 80% ou 100%, quando houver gasto fora do padrão, quando o banco pedir reconexão e no resumo semanal.

**Arquitetura:** a regra de "o que é gasto" sai do `public/index.html` para um módulo compartilhado (`public/regras.js`), usado pelo navegador e pelo Worker. O cálculo do ciclo e dos alertas são funções puras (`src/ciclo.js`, `src/alertas.js`), testadas com `node --test`. O Worker grava os alertas na tabela `notificacoes`, com chave única para não repetir, e manda um **Web Push sem conteúdo**, assinado só com VAPID (ES256 via WebCrypto). Ao receber o push, o service worker busca os alertas pendentes com o cookie da sessão e mostra as notificações. Isso evita criptografar o conteúdo (RFC 8291) e não usa nenhuma biblioteca.

**Stack:** Cloudflare Workers + D1 + Cron Triggers, JS puro (ESM), `node --test` (Node 22), Web Push/VAPID, wrangler 4, pnpm 12.

**Spec:** a seção "Decisões" abaixo, tirada do grilling de 08/11/2026 (memória `meu-banco-roadmap`).

## Decisões (spec)

- Só o Renan, só Inter PF, uso algumas vezes por semana. Foco: controlar gastos.
- **Ciclo** = do crédito do salário até a véspera do próximo. O usuário marca **uma vez** qual crédito é o salário (botão no detalhe da transação). O ciclo começa na data do último crédito com a mesma descrição normalizada. O fim previsto é início + 1 mês − 1 dia. Sem salário marcado: usa o mês do calendário e pede para marcar.
- **Limite** = um valor total fixo que o usuário digita. Mostra consumido, quanto falta e a %.
- **Parcelas:** cada parcela conta no ciclo em que cai. Consumido = gastos lançados no ciclo + parcelas futuras que caem até o fim do ciclo. Mostrar à parte as parcelas já comprometidas nos ciclos seguintes.
- **Push só no Android** (Chrome, PWA instalado ou não). Eventos:
  - limite em 80% e em 100% (uma vez por ciclo cada);
  - gasto fora do padrão: compra com valor maior que 2× a média da mesma categoria nos últimos 6 meses, com mínimo de R$ 100 e pelo menos 3 compras de histórico; só olha os últimos 3 dias;
  - banco pediu reconexão (uma vez por dia enquanto durar);
  - resumo semanal no domingo às 20h.
- **Silêncio das 22h às 7h** (America/Sao_Paulo): o alerta é gravado e sai às 7h. A sincronização continua a cada 3 h.
- O app **não pode depender de IA** (nada de IA neste plano).
- A chave privada VAPID é secret (`wrangler secret put VAPID_PRIVADA`), nunca vai para o repositório nem aparece na tela.

## Restrições globais

- Responder e comentar em pt-BR, com acentos e UTF-8.
- Nenhuma dependência nova de runtime; só APIs nativas (WebCrypto, fetch, Intl).
- Dados do banco no DOM só com `textContent` ou `h()`, nunca `innerHTML`. CSP atual: `script-src 'self' 'unsafe-inline'`.
- POST, PUT e DELETE conferem o `Origin` com `mesmaOrigem(request, url)` (já existe em `src/index.js:113`).
- Overlays: clique fora, X e Esc fecham. Com alteração não salva, pergunta "Descartar alterações?". Durante o salvamento não fecham. Usar `abrirSheet({ titulo, corpo, gatilho, sujo })`, que já faz tudo isso.
- Versão visível `vX.Y.Z · dd/mm/aaaa HH:mm`: o `pnpm push` já incrementa.
- Fuso: `America/Sao_Paulo`. O Brasil não tem horário de verão desde 2019, então BRT = UTC−3 fixo nos crons.
- Plano grátis da Cloudflare: no máximo 5 Cron Triggers por conta. O plano usa 3.
- Commits em português, detalhados, terminando com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Antes do commit final: skills `qualidade-antes-do-pr` e `verificacao-manter`.

## Mapa de arquivos

| Arquivo | Papel |
|---|---|
| `public/regras.js` (novo) | `CATEGORIAS`, `traduzir`, `regraAuto`, `naoEhGasto`, `valorGasto(t, cartao)`, `valorParcela(t, cartao)`. Compartilhado pelo navegador e pelo Worker. |
| `src/ciclo.js` (novo) | `normalizar`, `somarDias`, `fimDoCiclo`, `cicloAtual`, `resumoCiclo` (puros). |
| `src/alertas.js` (novo) | `emSilencio`, `foraDoPadrao`, `gerarAlertas`, `resumoSemanal` (puros). |
| `src/push.js` (novo) | `jwtVapid`, `enviarPush` (VAPID, push sem conteúdo). |
| `scripts/vapid.mjs` (novo) | Gera o par de chaves VAPID: a pública vai para um arquivo e a privada (JWK) sai no stdout, para o pipe do `wrangler secret put`. |
| `test/*.test.mjs` (novo) | Testes das funções puras. |
| `schema.sql` | Tabelas `config`, `push_inscricoes` e `notificacoes`. |
| `src/index.js` | Rotas `/api/ciclo`, `/api/config`, `/api/push`, `/api/push/teste` e `/api/notificacoes/entregar`; `avaliarAlertas` e `enviarPendentes`; `scheduled` por cron. |
| `wrangler.toml` | 2 crons novos; vars `VAPID_PUBLICA` e `VAPID_ASSUNTO`. |
| `public/index.html` | Vira `<script type="module">` importando `regras.js`; card do ciclo; sheet "Ciclo e alertas"; botão "Este é o meu salário". |
| `public/sw.js` | `regras.js` no shell; `/api/ciclo` no cache de dados; eventos `push` e `notificationclick`. |
| `mock/api-mock.mjs` | Endpoint falso de push (`POST /push/:id`, `GET /push/_ultimo`). |
| `package.json` | Script `"test": "node --test test/"`. |
| `README.md`, `.dev.vars.example`, `.claude/skills/verificar-meu-banco/SKILL.md` | Documentação e verificação. |

---

### Tarefa 1: Regra de gasto compartilhada (`public/regras.js`)

**Arquivos:**
- Criar: `public/regras.js`
- Modificar: `public/index.html` (linhas 168–243: `<script>`, `CATEGORIAS`, `traduzir`, `CAT_FORA`, `DESC_FORA`, `regraAuto`, `naoEhGasto`, `valorGasto`)
- Modificar: `public/sw.js:6` (`ARQUIVOS`)
- Modificar: `package.json` (script `test`)
- Teste: `test/regras.test.mjs`

**Interfaces:**
- Produz:
  - `CATEGORIAS: Record<string,string>`
  - `traduzir(c?: string): string`
  - `regraAuto(t): boolean`
  - `naoEhGasto(t): boolean`
  - `valorGasto(t, cartao: boolean): number`, que dá 0 para parcela futura (`scheduled`) e para o que não é gasto
  - `valorParcela(t, cartao: boolean): number`, que dá o valor de uma parcela futura que é gasto, senão 0
  - `t` = `{ category, description, amount, scheduled, ajuste_gasto }`

- [ ] **Passo 1: Teste que falha**

```js
// test/regras.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { valorGasto, valorParcela, naoEhGasto, traduzir } from "../public/regras.js";

test("débito da conta conta como gasto positivo; crédito não", () => {
  assert.equal(valorGasto({ amount: -187.32, category: "Electricity" }, false), 187.32);
  assert.equal(valorGasto({ amount: 7500, category: "Salary" }, false), 0);
});
test("cartão: compra soma, estorno subtrai, pagamento de fatura fica fora", () => {
  assert.equal(valorGasto({ amount: 220, category: "Gas stations" }, true), 220);
  assert.equal(valorGasto({ amount: -30, category: "Gas stations" }, true), -30);
  assert.equal(valorGasto({ amount: -1500, category: "Credit card payment" }, true), 0);
});
test("aplicação/porquinho não é gasto; ajuste manual vence a regra", () => {
  assert.equal(naoEhGasto({ description: "APLICACAO CDB", amount: -1000 }), true);
  assert.equal(naoEhGasto({ description: "APLICACAO CDB", ajuste_gasto: 1 }), false);
  assert.equal(naoEhGasto({ description: "IFOOD", ajuste_gasto: 0 }), true);
});
test("parcela futura: fora de valorGasto, dentro de valorParcela", () => {
  const p = { amount: 750, category: "Electronics", scheduled: 1 };
  assert.equal(valorGasto(p, true), 0);
  assert.equal(valorParcela(p, true), 750);
  assert.equal(valorParcela({ ...p, scheduled: 0 }, true), 0);
});
test("traduzir", () => {
  assert.equal(traduzir("Rent"), "Aluguel");
  assert.equal(traduzir(null), "Sem categoria");
});
```

Acrescente em `package.json`, dentro de `scripts`: `"test": "node --test test/"`.

- [ ] **Passo 2: Rodar e ver falhar**

Comando: `pnpm -s test`
Esperado: FALHA com `Cannot find module '.../public/regras.js'`.

- [ ] **Passo 3: Implementar**

Crie `public/regras.js` movendo **literalmente** de `public/index.html`:
- o objeto `CATEGORIAS` inteiro (começa na linha 190);
- `traduzir`, `CAT_FORA`, `DESC_FORA`, `regraAuto` e `naoEhGasto` (linhas 224–231), todos com `export`.

Acrescente:

```js
// Valor que entra nos totais de gasto. Cartão: compra positiva, estorno negativo. Conta: só saída (amount < 0).
// Parcela futura (scheduled) fica fora: ela entra pelo valorParcela no ciclo em que cai.
export const valorGasto = (t, cartao) =>
  t.scheduled || naoEhGasto(t) ? 0 : cartao ? t.amount : t.amount < 0 ? -t.amount : 0;
export const valorParcela = (t, cartao) =>
  !t.scheduled || naoEhGasto(t) ? 0 : cartao ? t.amount : t.amount < 0 ? -t.amount : 0;
```

Em `public/index.html`:
- troque `<script>` (linha 168) por `<script type="module">`;
- logo na primeira linha do script, coloque `import { CATEGORIAS, traduzir, regraAuto, naoEhGasto, valorGasto as gastoDe, valorParcela } from "/regras.js";`;
- apague as definições movidas e troque a linha 243 por `const valorGasto = (t) => gastoDe(t, ehCartao(t));`.

Antes, confira com `rg -n "onclick=|window\.\w+ =" public/index.html` que nenhum handler inline depende de função global (módulo não cria globais). Esperado: nenhuma ocorrência.

Em `public/sw.js:6`, acrescente `"/regras.js"` em `ARQUIVOS`.

Confira em `src/index.js:58` que `/regras.js` **não** precisa ser público: o painel só carrega depois do login. Deixe como está.

- [ ] **Passo 4: Rodar e ver passar**

Comando: `pnpm -s test`. Esperado: 5 testes ok.
Depois: `pnpm dev` com o mock, entre com `teste123` e confira que gráficos, categorias e total do mês continuam com os mesmos números de antes (compare com um print de antes).

- [ ] **Passo 5: Commit**

```bash
git add public/regras.js public/index.html public/sw.js package.json test/regras.test.mjs
git commit -m "Move a regra de gasto para public/regras.js, compartilhada com o Worker"
```

---

### Tarefa 2: Cálculo do ciclo (`src/ciclo.js`)

**Arquivos:**
- Criar: `src/ciclo.js`
- Teste: `test/ciclo.test.mjs`

**Interfaces:**
- Consome: `valorGasto` e `valorParcela` de `../public/regras.js`.
- Produz:
  - `normalizar(desc: string): string` (maiúsculas, sem acento, sem números nem pontuação, espaços colapsados);
  - `somarDias(iso, n): string`;
  - `fimDoCiclo(inicio: "YYYY-MM-DD"): string` (início + 1 mês − 1 dia, com o dia ajustado ao fim do mês);
  - `cicloAtual(transacoes, contas, salario: string|null, hoje): { inicio, fim, semSalario: boolean }`;
  - `resumoCiclo({ transacoes, contas, config, hoje }) → { inicio, fim, semSalario, diasRestantes, gasto, parcelasCiclo, consumido, limite: number|null, falta: number|null, percentual: number|null, parcelasDepois }`.
  - `config = { limite?: number, salario?: string }`; `contas = [{ id, type }]` (`type === "CREDIT"` é cartão).

- [ ] **Passo 1: Teste que falha**

```js
// test/ciclo.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizar, fimDoCiclo, cicloAtual, resumoCiclo } from "../src/ciclo.js";

const contas = [{ id: "cc", type: "BANK" }, { id: "cart", type: "CREDIT" }];
const sal = (date) => ({ account_id: "cc", date, description: `SALARIO EMPRESA X ${date.slice(5, 7)}/2026`, amount: 7500, type: "CREDIT", scheduled: 0 });

test("normalizar ignora números, data e acentos", () => {
  assert.equal(normalizar("Salário EMPRESA X 10/2026"), "SALARIO EMPRESA X");
});
test("fimDoCiclo ajusta fim de mês", () => {
  assert.equal(fimDoCiclo("2026-11-05"), "2026-12-04");
  assert.equal(fimDoCiclo("2026-01-31"), "2026-02-27");
});
test("ciclo começa no último salário; sem salário usa o mês", () => {
  const tx = [sal("2026-10-05"), sal("2026-11-05")];
  assert.deepEqual(cicloAtual(tx, contas, "SALARIO EMPRESA X", "2026-11-20"), { inicio: "2026-11-05", fim: "2026-12-04", semSalario: false });
  assert.deepEqual(cicloAtual(tx, contas, null, "2026-11-20"), { inicio: "2026-11-01", fim: "2026-11-30", semSalario: true });
});
test("salário atrasado estica o fim até hoje", () => {
  assert.equal(cicloAtual([sal("2026-10-05")], contas, "SALARIO EMPRESA X", "2026-11-07").fim, "2026-11-07");
});
test("resumo: gasto do ciclo + parcelas que caem no ciclo; limite e falta", () => {
  const tx = [
    sal("2026-11-05"),
    { account_id: "cc", date: "2026-11-01", description: "ANTES DO CICLO", amount: -999, scheduled: 0 },
    { account_id: "cc", date: "2026-11-10", description: "ENEL", amount: -200, category: "Electricity", scheduled: 0 },
    { account_id: "cart", date: "2026-11-12", description: "IFOOD", amount: 100, category: "Food delivery", scheduled: 0 },
    { account_id: "cart", date: "2026-11-30", description: "NOTEBOOK 2/4", amount: 750, category: "Electronics", scheduled: 1 },
    { account_id: "cart", date: "2026-12-30", description: "NOTEBOOK 3/4", amount: 750, category: "Electronics", scheduled: 1 },
    { account_id: "cc", date: "2026-11-15", description: "APLICACAO CDB", amount: -1000, scheduled: 0 },
  ];
  const r = resumoCiclo({ transacoes: tx, contas, config: { limite: 2000, salario: "SALARIO EMPRESA X" }, hoje: "2026-11-20" });
  assert.equal(r.gasto, 300);
  assert.equal(r.parcelasCiclo, 750);
  assert.equal(r.consumido, 1050);
  assert.equal(r.falta, 950);
  assert.equal(Math.round(r.percentual), 53);
  assert.equal(r.parcelasDepois, 750);
  assert.equal(r.diasRestantes, 14);
});
test("sem limite: falta e percentual nulos", () => {
  const r = resumoCiclo({ transacoes: [], contas, config: {}, hoje: "2026-11-20" });
  assert.equal(r.limite, null);
  assert.equal(r.percentual, null);
});
```

- [ ] **Passo 2: Rodar e ver falhar**

Comando: `pnpm -s test`. Esperado: FALHA `Cannot find module '../src/ciclo.js'`.

- [ ] **Passo 3: Implementar**

```js
// src/ciclo.js — ciclo do salário e consumo do limite (funções puras, testadas em test/ciclo.test.mjs).
import { valorGasto, valorParcela } from "../public/regras.js";

export const normalizar = (d) =>
  (d || "").toUpperCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
    .replace(/[^A-Z ]+/g, " ").replace(/\s+/g, " ").trim();

export function somarDias(iso, n) {
  const d = new Date(iso + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function fimDoCiclo(inicio) {
  const [a, m, d] = inicio.split("-").map(Number);
  const ultimo = new Date(Date.UTC(a, m + 1, 0)).getUTCDate(); // último dia do mês seguinte
  const prox = new Date(Date.UTC(a, m, Math.min(d, ultimo), 12));
  return somarDias(prox.toISOString().slice(0, 10), -1);
}

export function cicloAtual(transacoes, contas, salario, hoje) {
  const banco = new Set(contas.filter((c) => c.type !== "CREDIT").map((c) => c.id));
  const datas = salario
    ? transacoes.filter((t) => banco.has(t.account_id) && !t.scheduled && t.amount > 0 && t.date <= hoje && normalizar(t.description) === salario).map((t) => t.date)
    : [];
  if (!datas.length) {
    const inicio = hoje.slice(0, 8) + "01";
    return { inicio, fim: fimDoCiclo(inicio), semSalario: true }; // 1º + 1 mês − 1 = último dia do mês
  }
  const inicio = datas.sort().at(-1);
  const fim = fimDoCiclo(inicio);
  return { inicio, fim: fim < hoje ? hoje : fim, semSalario: false };
}

const dias = (de, ate) => Math.round((Date.parse(ate) - Date.parse(de)) / 86400000);
const centavos = (v) => Math.round(v * 100) / 100;

export function resumoCiclo({ transacoes, contas, config, hoje }) {
  const cartao = new Set(contas.filter((c) => c.type === "CREDIT").map((c) => c.id));
  const { inicio, fim, semSalario } = cicloAtual(transacoes, contas, config.salario || null, hoje);
  let gasto = 0, parcelasCiclo = 0, parcelasDepois = 0;
  for (const t of transacoes) {
    const c = cartao.has(t.account_id);
    if (t.date >= inicio && t.date <= fim) gasto += valorGasto(t, c);
    const p = valorParcela(t, c);
    if (p && t.date >= inicio && t.date <= fim) parcelasCiclo += p;
    else if (p && t.date > fim) parcelasDepois += p;
  }
  const consumido = centavos(gasto + parcelasCiclo);
  const limite = config.limite > 0 ? config.limite : null;
  return {
    inicio, fim, semSalario, diasRestantes: dias(hoje, fim),
    gasto: centavos(gasto), parcelasCiclo: centavos(parcelasCiclo), consumido,
    limite, falta: limite == null ? null : centavos(limite - consumido),
    percentual: limite == null ? null : (consumido / limite) * 100,
    parcelasDepois: centavos(parcelasDepois),
  };
}
```

- [ ] **Passo 4: Rodar e ver passar**

Comando: `pnpm -s test`. Esperado: todos ok.

- [ ] **Passo 5: Commit**

```bash
git add src/ciclo.js test/ciclo.test.mjs
git commit -m "Calcula o ciclo do salário e o consumo do limite (src/ciclo.js)"
```

---

### Tarefa 3: Regras dos alertas (`src/alertas.js`)

**Arquivos:**
- Criar: `src/alertas.js`
- Teste: `test/alertas.test.mjs`

**Interfaces:**
- Consome: `valorGasto` e `traduzir` (regras.js); `somarDias` (ciclo.js); o resumo de `resumoCiclo`.
- Produz:
  - `emSilencio(data: Date): boolean`, que vale entre 22h e 7h em BRT;
  - `foraDoPadrao(transacoes, contas, hoje): Array<{ t, media }>`;
  - `gerarAlertas({ resumo, transacoes, contas, avisos, hoje }): Array<{ chave, titulo, corpo }>`;
  - `resumoSemanal({ resumo, transacoes, contas, hoje }): { chave, titulo, corpo }`.
  - Chaves: `limite80:<inicio>`, `limite100:<inicio>`, `fora:<id>`, `reconexao:<hoje>`, `semana:<hoje>`.
  - `avisos` = snapshot `avisos` do D1 (`[{ banco, mensagem, reconnect_url }]`).
  - A categoria efetiva é `t.ajuste_categoria || t.category`.

- [ ] **Passo 1: Teste que falha**

```js
// test/alertas.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { emSilencio, foraDoPadrao, gerarAlertas, resumoSemanal } from "../src/alertas.js";

const contas = [{ id: "cc", type: "BANK" }, { id: "cart", type: "CREDIT" }];
const compra = (id, date, amount, category = "Gas stations") => ({ id, account_id: "cart", date, description: "POSTO SHELL", amount, category, scheduled: 0 });
const base = { inicio: "2026-11-05", fim: "2026-12-04", limite: 2000, consumido: 1000, falta: 1000, percentual: 50, diasRestantes: 14 };

test("silêncio 22h–7h em BRT", () => {
  assert.equal(emSilencio(new Date("2026-11-08T01:30:00Z")), true);  // 22:30 BRT
  assert.equal(emSilencio(new Date("2026-11-08T10:00:00Z")), false); // 07:00 BRT
  assert.equal(emSilencio(new Date("2026-11-08T09:59:00Z")), true);  // 06:59 BRT
});
test("fora do padrão: > 2x média, >= R$100, 3+ compras de histórico, últimos 3 dias", () => {
  const hist = [compra("a", "2026-09-01", 200), compra("b", "2026-10-01", 210), compra("c", "2026-10-20", 220)];
  assert.equal(foraDoPadrao([...hist, compra("n", "2026-11-19", 500)], contas, "2026-11-20").length, 1);
  assert.equal(foraDoPadrao([...hist, compra("n", "2026-11-10", 500)], contas, "2026-11-20").length, 0); // antiga
  assert.equal(foraDoPadrao([...hist.slice(0, 2), compra("n", "2026-11-19", 500)], contas, "2026-11-20").length, 0); // pouco histórico
  assert.equal(foraDoPadrao([compra("a", "2026-09-01", 30), compra("b", "2026-10-01", 30), compra("c", "2026-10-02", 30), compra("n", "2026-11-19", 90)], contas, "2026-11-20").length, 0); // < R$100
});
test("limite: 80% e 100% com chave por ciclo", () => {
  const c = (percentual) => gerarAlertas({ resumo: { ...base, percentual }, transacoes: [], contas, avisos: [], hoje: "2026-11-20" }).map((a) => a.chave);
  assert.deepEqual(c(50), []);
  assert.deepEqual(c(85), ["limite80:2026-11-05"]);
  assert.deepEqual(c(110), ["limite80:2026-11-05", "limite100:2026-11-05"]);
});
test("reconexão: uma chave por dia", () => {
  const a = gerarAlertas({ resumo: { ...base, limite: null, percentual: null }, transacoes: [], contas, avisos: [{ banco: "Banco Inter", mensagem: "Faça login" }], hoje: "2026-11-20" });
  assert.deepEqual(a.map((x) => x.chave), ["reconexao:2026-11-20"]);
});
test("resumo semanal soma os últimos 7 dias", () => {
  const r = resumoSemanal({ resumo: base, transacoes: [compra("x", "2026-11-18", 100), compra("y", "2026-11-01", 999)], contas, hoje: "2026-11-22" });
  assert.equal(r.chave, "semana:2026-11-22");
  assert.match(r.corpo, /R\$\s?100,00/);
});
```

- [ ] **Passo 2: Rodar e ver falhar**

Comando: `pnpm -s test`. Esperado: FALHA `Cannot find module '../src/alertas.js'`.

- [ ] **Passo 3: Implementar**

```js
// src/alertas.js — quais alertas gerar (funções puras). Chave única por alerta evita repetir.
import { valorGasto, traduzir } from "../public/regras.js";
import { somarDias } from "./ciclo.js";

const brl = new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" });
const dm = (iso) => iso.slice(8, 10) + "/" + iso.slice(5, 7);
const horaBRT = new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", hourCycle: "h23" });

export const emSilencio = (data) => { const h = Number(horaBRT.format(data)); return h >= 22 || h < 7; };

export function foraDoPadrao(transacoes, contas, hoje) {
  const cartao = new Set(contas.filter((c) => c.type === "CREDIT").map((c) => c.id));
  const recente = somarDias(hoje, -3), desde = somarDias(hoje, -180);
  const cat = (t) => t.ajuste_categoria || t.category || "";
  const valor = (t) => valorGasto(t, cartao.has(t.account_id));
  const historico = {};
  for (const t of transacoes) {
    if (t.date >= desde && t.date < recente && valor(t) > 0) (historico[cat(t)] ||= []).push(valor(t));
  }
  return transacoes
    .filter((t) => t.date >= recente && t.date <= hoje && valor(t) >= 100)
    .map((t) => {
      const h = historico[cat(t)] || [];
      return { t, media: h.length >= 3 ? h.reduce((a, b) => a + b, 0) / h.length : null };
    })
    .filter(({ t, media }) => media != null && valor(t) > 2 * media);
}

export function gerarAlertas({ resumo, transacoes, contas, avisos, hoje }) {
  const out = [];
  const { percentual: p, consumido, limite, falta, inicio, fim } = resumo;
  if (p != null && p >= 80) {
    out.push({ chave: `limite80:${inicio}`, titulo: "80% do limite do ciclo",
      corpo: `Você já usou ${brl.format(consumido)} de ${brl.format(limite)} (${Math.floor(p)}%). Faltam ${brl.format(Math.max(falta, 0))} até ${dm(fim)}.` });
  }
  if (p != null && p >= 100) {
    out.push({ chave: `limite100:${inicio}`, titulo: "Limite do ciclo estourado",
      corpo: `Você usou ${brl.format(consumido)} de ${brl.format(limite)}: ${brl.format(consumido - limite)} acima.` });
  }
  const cartao = new Set(contas.filter((c) => c.type === "CREDIT").map((c) => c.id));
  for (const { t, media } of foraDoPadrao(transacoes, contas, hoje)) {
    out.push({ chave: `fora:${t.id}`, titulo: "Gasto acima do normal",
      corpo: `${brl.format(valorGasto(t, cartao.has(t.account_id)))} em ${t.description} (${traduzir(t.ajuste_categoria || t.category)}): mais que o dobro da sua média (${brl.format(media)}).` });
  }
  for (const a of avisos) {
    out.push({ chave: `reconexao:${hoje}`, titulo: `${a.banco} pediu nova conexão`, corpo: a.mensagem });
    break; // um por dia basta
  }
  return out;
}

export function resumoSemanal({ resumo, transacoes, contas, hoje }) {
  const cartao = new Set(contas.filter((c) => c.type === "CREDIT").map((c) => c.id));
  const desde = somarDias(hoje, -6);
  const semana = transacoes.filter((t) => t.date >= desde && t.date <= hoje).reduce((s, t) => s + valorGasto(t, cartao.has(t.account_id)), 0);
  const ciclo = resumo.limite == null
    ? `No ciclo: ${brl.format(resumo.consumido)}.`
    : `No ciclo: ${brl.format(resumo.consumido)} de ${brl.format(resumo.limite)}; faltam ${brl.format(Math.max(resumo.falta, 0))} em ${resumo.diasRestantes} dias.`;
  return { chave: `semana:${hoje}`, titulo: "Resumo da semana", corpo: `Gastou ${brl.format(semana)} nos últimos 7 dias. ${ciclo}` };
}
```

- [ ] **Passo 4: Rodar e ver passar**

Comando: `pnpm -s test`. Esperado: todos ok.

- [ ] **Passo 5: Commit**

```bash
git add src/alertas.js test/alertas.test.mjs
git commit -m "Define os alertas de limite, gasto fora do padrão, reconexão e resumo semanal"
```

---

### Tarefa 4: Web Push com VAPID (`src/push.js`, `scripts/vapid.mjs`)

**Arquivos:**
- Criar: `src/push.js`, `scripts/vapid.mjs`
- Teste: `test/push.test.mjs`

**Interfaces:**
- Produz:
  - `jwtVapid(audiencia: string, assunto: string, jwkPrivada: JsonWebKey, agoraS: number): Promise<string>`;
  - `enviarPush(endpoint: string, env): Promise<number>`, que devolve o status HTTP; 404 ou 410 = inscrição morta.
  - `env.VAPID_PUBLICA` é base64url da chave pública raw (65 bytes); `env.VAPID_PRIVADA` é a JWK em JSON; `env.VAPID_ASSUNTO` é a URL https do app.

- [ ] **Passo 1: Teste que falha**

```js
// test/push.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { jwtVapid } from "../src/push.js";

test("JWT VAPID ES256 válido para a chave pública", async () => {
  const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", par.privateKey);
  const jwt = await jwtVapid("https://fcm.googleapis.com", "https://exemplo.dev", jwk, 1_800_000_000);
  const [h, p, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { typ: "JWT", alg: "ES256" });
  const corpo = JSON.parse(Buffer.from(p, "base64url"));
  assert.equal(corpo.aud, "https://fcm.googleapis.com");
  assert.equal(corpo.exp, 1_800_000_000 + 12 * 3600);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, par.publicKey, Buffer.from(s, "base64url"), new TextEncoder().encode(`${h}.${p}`));
  assert.equal(ok, true);
});
```

- [ ] **Passo 2: Rodar e ver falhar**

Comando: `pnpm -s test`. Esperado: FALHA `Cannot find module '../src/push.js'`.

- [ ] **Passo 3: Implementar**

```js
// src/push.js — Web Push sem conteúdo: só o JWT VAPID (RFC 8292). O service worker busca o texto em /api/notificacoes/entregar.
const b64u = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const parte = (obj) => b64u(new TextEncoder().encode(JSON.stringify(obj)));

export async function jwtVapid(audiencia, assunto, jwkPrivada, agoraS) {
  const chave = await crypto.subtle.importKey("jwk", jwkPrivada, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const corpo = `${parte({ typ: "JWT", alg: "ES256" })}.${parte({ aud: audiencia, exp: agoraS + 12 * 3600, sub: assunto })}`;
  const assinatura = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, chave, new TextEncoder().encode(corpo));
  return `${corpo}.${b64u(assinatura)}`;
}

export async function enviarPush(endpoint, env) {
  const jwt = await jwtVapid(new URL(endpoint).origin, env.VAPID_ASSUNTO, JSON.parse(env.VAPID_PRIVADA), Math.floor(Date.now() / 1000));
  const r = await fetch(endpoint, { method: "POST", headers: { TTL: "86400", Urgency: "normal", Authorization: `vapid t=${jwt}, k=${env.VAPID_PUBLICA}` } });
  await r.body?.cancel();
  return r.status;
}
```

```js
// scripts/vapid.mjs — gera as chaves VAPID. Uso:
//   node scripts/vapid.mjs vapid-publica.txt | npx wrangler secret put VAPID_PRIVADA
// A pública vai para o arquivo (copie para VAPID_PUBLICA no wrangler.toml); a privada só sai pelo pipe.
import { writeFileSync } from "node:fs";
const destino = process.argv[2];
if (!destino) { console.error("Informe o arquivo da chave pública."); process.exit(1); }
const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
writeFileSync(destino, Buffer.from(await crypto.subtle.exportKey("raw", par.publicKey)).toString("base64url"));
process.stdout.write(JSON.stringify(await crypto.subtle.exportKey("jwk", par.privateKey)));
```

Acrescente `vapid-*.txt` ao `.gitignore`. A pública não é segredo, mas assim não vai parar no repositório por acidente.

- [ ] **Passo 4: Rodar e ver passar**

Comando: `pnpm -s test`. Esperado: todos ok.

- [ ] **Passo 5: Commit**

```bash
git add src/push.js scripts/vapid.mjs test/push.test.mjs .gitignore
git commit -m "Adiciona envio de Web Push com VAPID (ES256 via WebCrypto, sem bibliotecas)"
```

---

### Tarefa 5: Schema, rotas e crons no Worker

**Arquivos:**
- Modificar: `schema.sql` (fim do arquivo)
- Modificar: `src/index.js`:
  - roteador (linhas 17–40);
  - `scheduled` (linhas 50–52);
  - fim de `sincronizar` (linhas 314–321);
  - funções novas depois de `salvarAjuste` (linha 196).
- Modificar: `wrangler.toml`: `crons` (linha 20) e `[vars]` (linha 30).
- Modificar: `mock/api-mock.mjs` (antes da checagem de `authorization`, linha 93).
- Modificar: `.dev.vars.example`.

**Interfaces:**
- Consome: `resumoCiclo` e `normalizar` (ciclo.js); `gerarAlertas`, `resumoSemanal` e `emSilencio` (alertas.js); `enviarPush` (push.js).
- Produz (HTTP, todas exigem sessão):
  - `GET /api/ciclo` → `{ ciclo: <resumoCiclo>, notificacoes: [{ chave, titulo, corpo, criada }] (últimas 20), push: { publica } }`;
  - `PUT /api/config` com `{ limite?: number|null, salario_id?: string }` → `{ ok: true }`. Erros: 400 para limite ≤ 0, não numérico ou acima de 1.000.000, e para salario_id que não é crédito da conta corrente; 404 para id inexistente;
  - `POST /api/push` com `{ endpoint }` → `{ ok: true }`; `DELETE /api/push` com `{ endpoint }` → `{ ok: true }`;
  - `POST /api/push/teste` → `{ ok: true, enviados: n }`, ignorando o silêncio;
  - `POST /api/notificacoes/entregar` → `{ notificacoes: [...] }`, com as já enviadas por push e ainda não entregues (até 5), que passam a ter `entregue_em`.

- [ ] **Passo 1: Schema**

Acrescente ao fim de `schema.sql`:

```sql
-- Configuração do ciclo: chave "limite" (número) e "salario" (descrição normalizada do crédito do salário).
CREATE TABLE IF NOT EXISTS config (
  chave TEXT PRIMARY KEY,
  valor TEXT NOT NULL
);
-- Inscrições de Web Push do navegador (só o endpoint: o push vai sem conteúdo).
CREATE TABLE IF NOT EXISTS push_inscricoes (
  endpoint TEXT PRIMARY KEY,
  criada   TEXT NOT NULL
);
-- Alertas. A chave única evita repetir (ex.: limite80:2026-11-05). enviada_em = push enviado; entregue_em = mostrado pelo service worker.
CREATE TABLE IF NOT EXISTS notificacoes (
  chave       TEXT PRIMARY KEY,
  titulo      TEXT NOT NULL,
  corpo       TEXT NOT NULL,
  criada      TEXT NOT NULL,
  enviada_em  TEXT,
  entregue_em TEXT
);
CREATE INDEX IF NOT EXISTS idx_notif_criada ON notificacoes(criada);
```

Rode `pnpm db:local`. Esperado: sucesso.

- [ ] **Passo 2: Funções do Worker** (em `src/index.js`, depois de `salvarAjuste`)

```js
import { resumoCiclo, normalizar } from "./ciclo.js";
import { gerarAlertas, resumoSemanal, emSilencio } from "./alertas.js";
import { enviarPush } from "./push.js";
// (os imports vão no topo do arquivo, junto do import de ApiCliente)

const hojeBRT = () => new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(new Date()); // YYYY-MM-DD

async function lerConfig(db) {
  const { results } = await db.prepare("SELECT chave, valor FROM config").all();
  const c = Object.fromEntries(results.map((r) => [r.chave, r.valor]));
  return { limite: c.limite ? Number(c.limite) : null, salario: c.salario || null };
}

// Base do ciclo e dos alertas: 200 dias de transações (6 meses de média + ciclo atual) e todas as parcelas futuras.
async function baseCiclo(env) {
  const hoje = hojeBRT();
  const [tx, contas, config] = await Promise.all([
    env.DB.prepare(`SELECT ${COLUNAS_TX} ${DE_TX} WHERE t.date >= ?1`).bind(somarDias(hoje, -200)).all(),
    env.DB.prepare("SELECT id, type FROM accounts").all(),
    lerConfig(env.DB),
  ]);
  const transacoes = tx.results;
  return { hoje, transacoes, contas: contas.results, config, resumo: resumoCiclo({ transacoes, contas: contas.results, config, hoje }) };
}

async function ciclo(env) {
  const [b, notif] = await Promise.all([
    baseCiclo(env),
    env.DB.prepare("SELECT chave, titulo, corpo, criada FROM notificacoes ORDER BY criada DESC LIMIT 20").all(),
  ]);
  return json({ ciclo: { ...b.resumo, salario: b.config.salario }, notificacoes: notif.results, push: { publica: env.VAPID_PUBLICA || null } });
}

async function salvarConfig(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const corpo = await request.json().catch(() => null);
  if (!corpo || typeof corpo !== "object") return json({ erro: "JSON inválido" }, 400);
  const ops = [];
  if ("limite" in corpo) {
    const v = corpo.limite;
    if (v === null) ops.push(env.DB.prepare("DELETE FROM config WHERE chave = 'limite'"));
    else if (typeof v === "number" && v > 0 && v <= 1e6) ops.push(env.DB.prepare("INSERT OR REPLACE INTO config (chave, valor) VALUES ('limite', ?1)").bind(String(v)));
    else return json({ erro: "Limite deve ser um valor entre R$ 0,01 e R$ 1.000.000" }, 400);
  }
  if ("salario_id" in corpo) {
    const t = await env.DB.prepare("SELECT t.description, t.amount, a.type FROM transactions t JOIN accounts a ON a.id = t.account_id WHERE t.id = ?1").bind(String(corpo.salario_id)).first();
    if (!t) return json({ erro: "Transação não encontrada" }, 404);
    if (t.type === "CREDIT" || !(t.amount > 0) || !normalizar(t.description)) return json({ erro: "Escolha um crédito da conta corrente" }, 400);
    ops.push(env.DB.prepare("INSERT OR REPLACE INTO config (chave, valor) VALUES ('salario', ?1)").bind(normalizar(t.description)));
  }
  if (!ops.length) return json({ erro: "Nada para salvar" }, 400);
  await env.DB.batch(ops);
  return json({ ok: true });
}

async function inscreverPush(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const endpoint = (await request.json().catch(() => null))?.endpoint;
  const permitido = /^https:\/\//.test(endpoint || "") || (env.PUSH_HTTP_LOCAL === "1" && /^http:\/\/localhost[:/]/.test(endpoint || ""));
  if (!permitido || endpoint.length > 1000) return json({ erro: "Endpoint inválido" }, 400);
  if (request.method === "DELETE") await env.DB.prepare("DELETE FROM push_inscricoes WHERE endpoint = ?1").bind(endpoint).run();
  else await env.DB.prepare("INSERT OR REPLACE INTO push_inscricoes (endpoint, criada) VALUES (?1, ?2)").bind(endpoint, agora()).run();
  return json({ ok: true });
}

function gravarAlertas(db, alertas) {
  if (!alertas.length) return null;
  return db.batch(alertas.map((a) =>
    db.prepare("INSERT OR IGNORE INTO notificacoes (chave, titulo, corpo, criada) VALUES (?1, ?2, ?3, ?4)").bind(a.chave, a.titulo, a.corpo, agora())));
}

// Um push (sem conteúdo) por inscrição quando há alerta não enviado. Respeita o silêncio das 22h às 7h.
async function enviarPendentes(env, ignorarSilencio = false) {
  if (!env.VAPID_PRIVADA || (!ignorarSilencio && emSilencio(new Date()))) return 0;
  const pend = await env.DB.prepare("SELECT COUNT(*) n FROM notificacoes WHERE enviada_em IS NULL").first();
  if (!pend.n) return 0;
  const { results } = await env.DB.prepare("SELECT endpoint FROM push_inscricoes").all();
  let enviados = 0;
  for (const { endpoint } of results) {
    const status = await enviarPush(endpoint, env).catch((e) => (console.error("push", e.message), 0));
    if (status === 404 || status === 410) await env.DB.prepare("DELETE FROM push_inscricoes WHERE endpoint = ?1").bind(endpoint).run();
    else if (status >= 200 && status < 300) enviados++;
  }
  if (enviados) await env.DB.prepare("UPDATE notificacoes SET enviada_em = ?1 WHERE enviada_em IS NULL").bind(agora()).run();
  return enviados;
}

async function avaliarAlertas(env) {
  const b = await baseCiclo(env);
  const avisos = JSON.parse((await env.DB.prepare("SELECT data FROM snapshots WHERE key = 'avisos'").first())?.data || "[]");
  await gravarAlertas(env.DB, gerarAlertas({ ...b, avisos }));
  await enviarPendentes(env);
}

async function alertaSemanal(env) {
  const b = await baseCiclo(env);
  await gravarAlertas(env.DB, [resumoSemanal(b)]);
  await enviarPendentes(env);
}

async function testePush(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  await gravarAlertas(env.DB, [{ chave: "teste:" + agora(), titulo: "Teste do Meu Banco", corpo: "As notificações estão funcionando." }]);
  return json({ ok: true, enviados: await enviarPendentes(env, true) });
}

async function entregarNotificacoes(request, env, url) {
  if (!mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  const { results } = await env.DB.prepare(
    "UPDATE notificacoes SET entregue_em = ?1 WHERE chave IN (SELECT chave FROM notificacoes WHERE enviada_em IS NOT NULL AND entregue_em IS NULL ORDER BY criada DESC LIMIT 5) RETURNING chave, titulo, corpo"
  ).bind(agora()).all();
  return json({ notificacoes: results });
}
```

Confira com `rg -n "^const somarDias|^function somarDias" src/index.js` que o `somarDias` de `src/index.js:140` tem a mesma assinatura `(iso, dias)`; use esse. **Não** importe o de `ciclo.js` no index, para não declarar duas vezes.

- [ ] **Passo 3: Roteador, `scheduled` e gancho no sync**

No roteador, junto das outras rotas:

```js
      else if (caminho === "/api/ciclo" && request.method === "GET") resp = await ciclo(env);
      else if (caminho === "/api/config" && request.method === "PUT") resp = await salvarConfig(request, env, url);
      else if (caminho === "/api/push" && (request.method === "POST" || request.method === "DELETE")) resp = await inscreverPush(request, env, url);
      else if (caminho === "/api/push/teste" && request.method === "POST") resp = await testePush(request, env, url);
      else if (caminho === "/api/notificacoes/entregar" && request.method === "POST") resp = await entregarNotificacoes(request, env, url);
```

Troque `scheduled`:

```js
  async scheduled(evento, env, ctx) {
    // Crons em UTC (BRT = UTC-3): "0 10 * * *" = 07h, fim do silêncio; "0 23 * * SUN" = domingo 20h, resumo.
    if (evento.cron === "0 10 * * *") ctx.waitUntil(enviarPendentes(env));
    else if (evento.cron === "0 23 * * SUN") ctx.waitUntil(alertaSemanal(env));
    else ctx.waitUntil(sincronizar(env, "cron"));
  },
```

No fim de `sincronizar`, depois do `UPDATE sync_log` e antes do `return`:

```js
  if (ok) await avaliarAlertas(env).catch((e) => console.error("Alertas falharam", e?.stack || e));
```

- [ ] **Passo 4: Config**

`wrangler.toml`:

```toml
[triggers]
crons = ["7 */3 * * *", "0 10 * * *", "0 23 * * SUN"]
```

Em `[vars]`, acrescente `VAPID_ASSUNTO = "https://meu-banco.renanrmsantos14.workers.dev"` e `VAPID_PUBLICA = ""`. A Tarefa 7 preenche a pública; até lá o `enviarPendentes` sai cedo porque não há `VAPID_PRIVADA`. No local, o `.dev.vars` sobrescreve as duas.

`.dev.vars.example`: acrescente `PUSH_HTTP_LOCAL=1`. Para testar o push local, gere um par com `node scripts/vapid.mjs vapid-local.txt > vapid-local.json`, depois `VAPID_PUBLICA=<conteúdo de vapid-local.txt>` e `VAPID_PRIVADA=<conteúdo de vapid-local.json em uma linha>`. Isso vale **só para teste local**; não é a chave de produção.

`mock/api-mock.mjs`: antes da linha `if (req.method !== "POST")`:

```js
  if (req.url.startsWith("/push/")) {
    if (req.method === "GET") return enviar(200, ultimoPush);
    ultimoPush = { total: ultimoPush.total + 1, authorization: req.headers.authorization || null, ttl: req.headers.ttl || null };
    return enviar(req.url.includes("morto") ? 410 : 201, {});
  }
```

e no topo `let ultimoPush = { total: 0, authorization: null, ttl: null };`. Antes, confira com `rg -n "function \w+\(|const \w+ = \(" mock/api-mock.mjs` o nome do helper que responde JSON; se não for `enviar(status, obj)`, use o nome que existir.

- [ ] **Passo 5: Verificar local**

Suba `node mock/api-mock.mjs` e `pnpm dev` (passos 1–3 da skill `verificar-meu-banco`) e faça login com `curl -c cj.txt`. Depois, com `A="-b cj.txt -H Origin:http://localhost:8787"`:
- `curl $A -X POST localhost:8787/api/atualizar` → ok.
- `curl $A localhost:8787/api/ciclo`: `ciclo.semSalario` = **true**, `limite` = **null**.
- `curl $A -X PUT -H content-type:application/json -d '{"salario_id":"cc-sal-0"}' localhost:8787/api/config` → `{"ok":true}`. Em seguida `/api/ciclo` deve trazer `semSalario:false` e `inicio` = data do `cc-sal-0`.
- `-d '{"salario_id":"cart-1"}'` → **400**; `-d '{"limite":-5}'` → **400**; `-d '{"limite":"abc"}'` → **400**.
- `-d '{"limite":500}'`, depois `/api/atualizar` e `/api/ciclo`: `percentual` > 100. `pnpm exec wrangler d1 execute meu-banco --local --command "SELECT chave FROM notificacoes"` mostra `limite80:` e `limite100:`. Repetir `/api/atualizar` **não** cria linhas novas.
- `curl $A -X POST -H content-type:application/json -d '{"endpoint":"http://localhost:8788/push/abc"}' localhost:8787/api/push` → ok. Depois `curl $A -X POST localhost:8787/api/push/teste` → `enviados: 1`, e `curl localhost:8788/push/_ultimo` → `total` ≥ 1, `authorization` começando com `vapid t=` e `ttl` `"86400"`.
- `curl $A -X POST localhost:8787/api/notificacoes/entregar` → até 5 notificações; a segunda chamada → lista vazia.
- Endpoint `http://localhost:8788/push/morto` + `/api/push/teste` → a linha some de `push_inscricoes`.
- `curl $A -X POST -H Origin:https://mal.com localhost:8787/api/push/teste` → **403**.
- `curl "localhost:8787/__scheduled?cron=0+23+*+*+SUN"` → 200 e uma linha `semana:<hoje>` em `notificacoes`.
- `pnpm -s test` e `node --check src/index.js` ok.

- [ ] **Passo 6: Commit**

```bash
git add schema.sql src/index.js wrangler.toml mock/api-mock.mjs .dev.vars.example
git commit -m "Grava alertas do ciclo, envia push e agenda resumo semanal e fim do silêncio"
```

---

### Tarefa 6: Painel e service worker

**Arquivos:**
- Modificar: `public/index.html`:
  - HTML: novo `<section id="ciclo">` logo depois de `<div id="avisos">` (linha 134);
  - `carregar` (linha 265) e `render` (linha 282);
  - `abrirDetalhe` (linhas 546–606);
  - CSS das barras.
- Modificar: `public/sw.js`: `ROTAS_DADOS` (linha 7) e eventos novos no fim.

**Interfaces:**
- Consome: `GET /api/ciclo`, `PUT /api/config`, `POST/DELETE /api/push`, `POST /api/push/teste` e `POST /api/notificacoes/entregar` (Tarefa 5); `abrirSheet`, `tentarFechar`, `fecharSheet`, `h`, `api`, `moeda`, `dataBR` (já em `index.html`).
- Produz: variável `C` (resposta de `/api/ciclo`) e `renderCiclo()`.

- [ ] **Passo 0: Conferir os nomes dos helpers**

`rg -n "const (\\$|h|api|moeda|dataBR|dataHora|ativar|abrirSheet|fecharSheet|sheet) =|function (h|api|moeda|dataBR|dataHora|ativar|abrirSheet|fecharSheet)\(" public/index.html`. Se `dataHora` não existir, use `dataBR(n.criada.slice(0, 10))`. Se o estado de salvamento do sheet tiver outro nome que não `sheet.salvando`, use o que `abrirDetalhe` já usa.

- [ ] **Passo 1: Dados**

Em `carregar`, acrescente `api("/api/ciclo").catch(() => null)` ao `Promise.all` e guarde em `let C = null;`, declarada junto de `let D`. Chame `renderCiclo()` no fim de `render()`.

- [ ] **Passo 2: Card do ciclo**

```js
function renderCiclo() {
  const el = $("ciclo");
  if (!C) return el.replaceChildren();
  const c = C.ciclo;
  const p = c.percentual == null ? null : Math.min(c.percentual, 100);
  const nivel = c.percentual >= 100 ? "estourado" : c.percentual >= 80 ? "alerta" : "";
  el.replaceChildren(
    h("div", { class: "ciclo-topo" },
      h("h2", {}, "Ciclo " + dataBR(c.inicio).slice(0, 5) + " → " + dataBR(c.fim).slice(0, 5)),
      h("span", { class: "sub" }, c.diasRestantes === 1 ? "falta 1 dia" : "faltam " + c.diasRestantes + " dias"),
      ativar(h("button", { type: "button", class: "ghost", id: "cicloConfig" }, "Ajustar"), (ev) => abrirConfigCiclo(ev.currentTarget))),
    c.semSalario ? h("div", { class: "aviso" }, "Usando o mês do calendário. Para seguir o salário, abra o crédito do salário na lista e toque em \"Este é o meu salário\".") : null,
    c.limite == null
      ? h("p", {}, "Gasto no ciclo: ", h("b", {}, moeda(c.consumido)), ". Defina um limite em Ajustar.")
      : [
          h("div", { class: "barra " + nivel, role: "progressbar", "aria-valuemin": 0, "aria-valuemax": 100, "aria-valuenow": Math.round(p), "aria-label": "Uso do limite do ciclo" },
            barraPreenchida(p)),
          h("p", {}, h("b", {}, moeda(c.consumido)), " de " + moeda(c.limite) + " (" + Math.floor(c.percentual) + "%) · ",
            c.falta >= 0 ? "falta " + moeda(c.falta) : h("b", { class: "neg" }, moeda(-c.falta) + " acima")),
        ],
    c.parcelasCiclo || c.parcelasDepois
      ? h("p", { class: "sub" }, "Inclui " + moeda(c.parcelasCiclo) + " de parcelas que caem neste ciclo · " + moeda(c.parcelasDepois) + " já comprometidos nos próximos")
      : null,
    C.notificacoes.length
      ? h("details", {}, h("summary", {}, "Últimos alertas"),
          h("ul", { class: "alertas" }, C.notificacoes.map((n) => h("li", {}, h("b", {}, n.titulo), " " + n.corpo, h("span", { class: "sub" }, " · " + dataHora(n.criada))))))
      : null,
  );
}
```

Antes de usar, confira em `public/index.html:463` se `ativar(el, fn)` devolve `el`. Se não devolver, crie o botão, chame `ativar` e use a variável.

HTML (depois da linha 134): `<section class="card" id="ciclo" aria-live="polite"></section>`

Preenchimento da barra via `transform: scaleX` (GPU, sem reflow), com a proporção definida pelo CSSOM (`style.setProperty` não esbarra na CSP). A barra anima só na primeira pintura do card; nas re-renderizações (Salvar, marcar salário) vai direto do valor antigo para o novo, porque a transição já cuida disso:

```js
// Começa no valor anterior (0 na primeira pintura) e desliza até o novo no frame seguinte.
function barraPreenchida(p, de = "0") {
  const s = h("span", {});
  s.style.setProperty("--p", de);
  requestAnimationFrame(() => requestAnimationFrame(() => s.style.setProperty("--p", String(p / 100))));
  return s;
}
```

Em `renderCiclo`, logo no início, guarde `const de = el.querySelector(".barra span")?.style.getPropertyValue("--p") || "0";` e chame `barraPreenchida(p, de)`. Assim a barra cresce do zero ao abrir e, depois de Salvar ou marcar o salário, desliza do valor velho para o novo.

CSS, no `<style>`, com os tokens que já existem (`--barra`, `--verde`, `--laranja`, `--vermelho`, `--suave`). Regras de design aplicadas (ui-ux-pro-max, emil-design-eng e animate):
- movimento só em `transform` e `opacity`;
- curva ease-out forte e até 600 ms na barra (entrada informativa), 160 ms em hover e press;
- `prefers-reduced-motion` desliga tudo;
- números com `tabular-nums`;
- área de toque mínima de 44 px no "Ajustar";
- cor nunca é o único sinal: o texto já diz "% " e "acima".

```css
.barra{height:10px;border-radius:999px;background:var(--barra);overflow:hidden;margin:10px 0 8px}
.barra span{display:block;height:100%;border-radius:inherit;background:var(--verde);
  transform-origin:left;transform:scaleX(var(--p,0));
  transition:transform .6s cubic-bezier(.23,1,.32,1),background-color .2s ease-out}
.barra.alerta span{background:var(--laranja)}
.barra.estourado span{background:var(--vermelho)}
#ciclo .sub{color:var(--suave);font-size:13px}
#ciclo b{font-variant-numeric:tabular-nums}
.ciclo-topo{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}
.ciclo-topo h2{margin:0}
.ciclo-topo .ghost{margin-left:auto;min-height:44px}
.alertas{padding-left:18px;margin:6px 0}
.alertas li+li{margin-top:6px}
button{transition:transform .16s cubic-bezier(.23,1,.32,1)}
button:active:not(:disabled){transform:scale(.97)}
@media (prefers-reduced-motion:reduce){.barra span,button{transition:none}}
```

Não anime: a lista "Últimos alertas" (`<details>` nativo, abre na hora), os textos de status e o valor em reais. Com uso algumas vezes por semana, a barra animando na abertura é o único movimento que acrescenta informação: mostra de onde o consumo veio.

- [ ] **Passo 3: Sheet "Ciclo e alertas"**

```js
const b64uParaBytes = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));

async function inscricaoAtual() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) return null;
  return (await navigator.serviceWorker.ready).pushManager.getSubscription();
}

async function abrirConfigCiclo(gatilho) {
  const ini = C.ciclo.limite == null ? "" : String(C.ciclo.limite);
  const inp = h("input", { id: "cfgLimite", type: "number", inputmode: "decimal", min: "1", step: "0.01", placeholder: "Ex.: 4000" });
  inp.value = ini;
  const erro = h("div", { class: "aviso erro", role: "alert", hidden: true });
  const status = h("p", { class: "sub", role: "status" });
  const salvar = h("button", { type: "button" }, "Salvar limite");
  const pushBtn = h("button", { type: "button", class: "sec" });
  const teste = h("button", { type: "button", class: "ghost", hidden: true }, "Enviar notificação de teste");
  const sujo = () => inp.value !== ini;
  const falhar = (e) => { erro.textContent = e.message; erro.hidden = false; };

  const sub = await inscricaoAtual().catch(() => null);
  const suportado = "PushManager" in window && C.push.publica;
  pushBtn.textContent = sub ? "Desativar notificações" : "Ativar notificações";
  pushBtn.hidden = !suportado;
  teste.hidden = !sub;
  status.textContent = !suportado ? "Notificações indisponíveis neste navegador." : Notification.permission === "denied" ? "Notificações bloqueadas: libere nas configurações do navegador." : "";

  salvar.addEventListener("click", async () => {
    if (!sujo()) return fecharSheet();
    const v = inp.value.trim() === "" ? null : Number(inp.value);
    if (v !== null && !(v > 0)) return falhar(new Error("Informe um valor maior que zero, ou deixe vazio para remover."));
    sheet.salvando = true; salvar.disabled = true; erro.hidden = true;
    try {
      await api("/api/config", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ limite: v }) });
      C = await api("/api/ciclo"); renderCiclo();
      sheet.salvando = false; fecharSheet();
    } catch (e) { sheet.salvando = false; salvar.disabled = false; falhar(e); }
  });

  pushBtn.addEventListener("click", async () => {
    pushBtn.disabled = true; erro.hidden = true;
    try {
      const atual = await inscricaoAtual();
      if (atual) {
        await api("/api/push", { method: "DELETE", headers: { "content-type": "application/json" }, body: JSON.stringify({ endpoint: atual.endpoint }) });
        await atual.unsubscribe();
        pushBtn.textContent = "Ativar notificações"; teste.hidden = true; status.textContent = "Notificações desativadas.";
      } else {
        if ((await Notification.requestPermission()) !== "granted") throw new Error("Permissão negada. Libere as notificações nas configurações do navegador.");
        const nova = await (await navigator.serviceWorker.ready).pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64uParaBytes(C.push.publica) });
        await api("/api/push", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ endpoint: nova.endpoint }) });
        pushBtn.textContent = "Desativar notificações"; teste.hidden = false; status.textContent = "Notificações ativadas neste aparelho.";
      }
    } catch (e) { falhar(e); }
    pushBtn.disabled = false;
  });

  teste.addEventListener("click", async () => {
    teste.disabled = true; erro.hidden = true;
    try {
      const r = await api("/api/push/teste", { method: "POST" });
      status.textContent = r.enviados ? "Teste enviado; deve chegar em alguns segundos." : "Nenhum aparelho recebeu. Desative e ative de novo.";
    } catch (e) { falhar(e); }
    teste.disabled = false;
  });

  abrirSheet({
    titulo: "Ciclo e alertas", gatilho, sujo,
    corpo: h("div", {},
      h("label", { class: "campo", for: "cfgLimite" }, "Limite total do ciclo (R$)", inp),
      h("p", { class: "sub" }, C.ciclo.salario ? "Salário: " + C.ciclo.salario : "Salário ainda não marcado."),
      erro,
      h("div", { class: "botoes" }, salvar, pushBtn, teste),
      status,
      h("p", { class: "sub" }, "Alertas: 80% e 100% do limite, gasto acima do normal, banco pedindo reconexão e resumo no domingo às 20h. Silêncio das 22h às 7h.")),
  });
}
```

- [ ] **Passo 4: Botão "Este é o meu salário" em `abrirDetalhe`**

Depois de `const campos = [...]`:

```js
  const ehSalario = !cartao && t.amount > 0 && !t.scheduled;
  const marcarSalario = ehSalario ? h("button", { type: "button", class: "ghost" }, "Este é o meu salário") : null;
  marcarSalario?.addEventListener("click", async () => {
    marcarSalario.disabled = true; erro.hidden = true;
    try {
      await api("/api/config", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ salario_id: t.id }) });
      C = await api("/api/ciclo"); renderCiclo();
      marcarSalario.textContent = "Salário marcado ✓";
    } catch (e) { erro.textContent = e.message; erro.hidden = false; marcarSalario.disabled = false; }
  });
```

Coloque `marcarSalario` dentro de `h("div", { class: "botoes" }, salvar, cancelar, marcarSalario)`. Ele não muda o `sujo()`: grava na hora.

- [ ] **Passo 5: Service worker**

`public/sw.js:7`: `const ROTAS_DADOS = /^\/api\/(dados|historico|fatura|ciclo)$/;`

No fim:

```js
// Push sem conteúdo: busca os alertas com o cookie da sessão. Sem sessão ou sem rede, mostra um aviso genérico.
self.addEventListener("push", (e) => e.waitUntil(mostrarAlertas()));
async function mostrarAlertas() {
  let lista = [];
  try {
    const r = await fetch("/api/notificacoes/entregar", { method: "POST" });
    if (r.ok) lista = (await r.json()).notificacoes;
  } catch {}
  const icone = "/icons/icon-192.png";
  if (!lista.length) return self.registration.showNotification("Meu Banco", { body: "Você tem alertas novos. Abra o app para ver.", icon: icone, tag: "meu-banco" });
  await Promise.all(lista.map((n) => self.registration.showNotification(n.titulo, { body: n.corpo, icon: icone, tag: n.chave })));
}
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: "window" }).then((ws) => (ws[0] ? ws[0].focus() : self.clients.openWindow("/"))));
});
```

- [ ] **Passo 6: Verificar (UI)**

Rode `pnpm dev` com o mock e o Playwright da skill `verificar-meu-banco`, passo 6. Confira:
- card do ciclo em 390 px e 1280 px, nos temas claro e escuro; sem rolagem horizontal;
- barra cresce do zero ao abrir; com `page.emulateMedia({ reducedMotion: "reduce" })` aparece direto no valor; "Ajustar" com altura ≥ 44 px (`boundingBox`);
- "Ajustar" → digitar limite → Esc pede "Descartar alterações?", clique fora também; Salvar atualiza a barra (80% amarela, 100% vermelha);
- detalhe do crédito `SALARIO EMPRESA X` → "Este é o meu salário" → o card mostra o ciclo novo;
- `context.grantPermissions(["notifications"])`, depois "Ativar notificações" → linha em `push_inscricoes` (no Chromium headless o endpoint é do FCM; confira só que a linha foi criada);
- sem erros no console.

Copie os prints para `/home/renan/.t3/userdata/attachments/meu-banco-ciclo-*.png`.

- [ ] **Passo 7: Commit**

```bash
git add public/index.html public/sw.js
git commit -m "Mostra o ciclo do salário com limite e alertas no painel; push no service worker"
```

---

### Tarefa 7: Produção, documentação e verificação

**Arquivos:**
- Modificar: `wrangler.toml` (`VAPID_PUBLICA`), `README.md`, `.claude/skills/verificar-meu-banco/SKILL.md`

- [ ] **Passo 1: Chaves VAPID de produção** (a privada não aparece na tela)

```bash
node scripts/vapid.mjs vapid-publica.txt | pnpm -s exec wrangler secret put VAPID_PRIVADA
```

Cole o conteúdo de `vapid-publica.txt` em `VAPID_PUBLICA` no `wrangler.toml`.

- [ ] **Passo 2: Migrar e publicar**

```bash
pnpm db:remote   # cria config, push_inscricoes e notificacoes (CREATE IF NOT EXISTS, não apaga nada)
pnpm push        # vira v0.0.5
```

Esperado: o deploy lista os 3 crons e `VAPID_PUBLICA`.

- [ ] **Passo 3: Validar em produção**

- Sem cookie, `/api/ciclo` → **401**.
- Pedir ao Renan, no celular Android:
  1. abrir o app, tocar em "Ajustar", definir o limite e tocar em "Ativar notificações";
  2. tocar em "Enviar notificação de teste" → a notificação "Teste do Meu Banco" chega;
  3. abrir o crédito do salário → "Este é o meu salário" → o card mostra o ciclo certo.
- `pnpm exec wrangler d1 execute meu-banco --remote --command "SELECT COUNT(*) FROM push_inscricoes"` → 1.

- [ ] **Passo 4: Documentação e skill de verificação**

- README: seção "Ciclo, limite e alertas", cobrindo:
  - como marcar o salário;
  - limite;
  - o que gera notificação;
  - silêncio das 22h às 7h;
  - push só com Chrome/Android;
  - o comando de `VAPID_PRIVADA`;
  - "trocar as chaves VAPID exige reativar as notificações no celular".
- Skill `verificar-meu-banco`: passo novo com as checagens do Passo 5 da Tarefa 5 e do Passo 6 da Tarefa 6, incluindo `pnpm -s test`.

- [ ] **Passo 5: Qualidade e commit final**

Skills `qualidade-antes-do-pr` (2–3 passadas de `/simplify` + `karpathy-coder`, depois `/code-review high --fix`) e `verificacao-manter`. Depois:

```bash
git add wrangler.toml README.md .claude/skills/verificar-meu-banco/SKILL.md
git commit   # mensagem detalhada em pt-BR + Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
git push origin main
```

---

## Riscos conhecidos

- **Salário em duas partes** (adiantamento + saldo) ou com descrição que muda: o ciclo começa no último crédito com a mesma descrição normalizada. Se a descrição mudar, é preciso marcar de novo. Fica de fora deste plano.
- **Data das parcelas futuras:** vem do Pluggy (`scheduled`). Se o Inter datar a parcela pelo vencimento da fatura e não pela compra, a parcela pode cair no ciclo seguinte. Conferir com dados reais na Tarefa 7.
- **Push sem conteúdo depende do cookie:** se a sessão de 30 dias expirar, o aviso chega genérico ("Abra o app"). É aceitável para um app pessoal.
- **Primeiro deploy:** o `foraDoPadrao` olha os últimos 3 dias, então pode gerar até alguns alertas logo na primeira sincronização.
