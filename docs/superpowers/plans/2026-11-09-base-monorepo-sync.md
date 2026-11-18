# Fase 1: monorepo, sincronização, Pluggy no D1 e backup. Plano de implementação

> **Para agentes:** sub-skill obrigatória: superpowers:subagent-driven-development (recomendada) ou superpowers:executing-plans, tarefa por tarefa. Os passos usam checkbox (`- [ ]`).

- **Objetivo:** criar a base que o app Android (Fase 2) e o web app (Fase 3) vão usar:
  - monorepo com `packages/core`;
  - sincronização em duas vias (`/api/sync`);
  - pareamento por QR;
  - conexões do Pluggy no D1, com connect token, webhook e limite de 30 min no Atualizar;
  - backup diário no R2;
  - importação do Cashew.

  O painel atual não pode regredir.
- **Arquitetura:**
  - O Worker atual (`src/`, JS) passa para `apps/worker` sem mudar de comportamento.
  - As regras puras de sincronização (validação, last-write-wins, janela do cursor) ficam em `packages/core`, escrito em TS apagável. O Worker importa essas regras.
  - Os dados do usuário ficam numa tabela genérica, `registros`.
  - Os testes do Worker rodam no Node, com um D1 falso sobre `node:sqlite`.
- **Stack:**
  - Cloudflare Workers, D1, R2 e Wrangler 4;
  - Node 22.18 ou mais novo, que tem type stripping e `node:sqlite` sem flag;
  - pnpm workspaces;
  - TypeScript 5.9, usado só para tipos;
  - `uqr` para gerar o QR.
- **Spec:** `docs/superpowers/specs/2026-11-09-app-completo-design.md`

## Global Constraints

- **Node:** versão 22.18 ou mais nova. O `core` roda `.ts` direto, sem build e sem flag.
- **TS apagável no `core`:**
  - sem `enum`, sem `namespace` e sem parameter properties;
  - imports relativos terminam em `.ts`;
  - tsconfig com `erasableSyntaxOnly`, `verbatimModuleSyntax`, `allowImportingTsExtensions` e `noEmit`.
- **Dependências:** o `core` não tem dependências de runtime.
- **Worker:** continua em JavaScript (ESM) e respeita o `packageManager` `pnpm@12.18.0` e o lockfile.
- **Textos:** UI e mensagens de erro em pt-BR, com acentos, em UTF-8.
- **Segredos:**
  - o secret do Pluggy fica só no Worker;
  - tokens em claro nunca vão para log nem para o D1, que guarda só o SHA-256.
- **Remoto:** nenhuma tarefa mexe no D1, no R2 ou nos secrets remotos. Os comandos remotos ficam no passo final, e quem roda é o Renan.
- **Limites da sincronização (spec §4.3):**
  - lote de até 500 registros;
  - `dados` de até 8 KB;
  - `id` de 1 a 80 caracteres;
  - folga de relógio de 5 min;
  - sobreposição do cursor de 2 min.
- **Atualizar:** no máximo uma vez a cada 30 min, somando as origens `botao` e `app`.
- **Versão visível:** `apps/worker/scripts/versao.mjs` continua incrementando o PATCH a cada `pnpm push`. Ninguém muda a versão à mão.
- **Commits:** em pt-BR, terminando com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Mapa de arquivos

| Arquivo | Responsabilidade |
|---|---|
| `pnpm-workspace.yaml` | Pacotes `apps/*` e `packages/*` |
| `package.json` (raiz) | Scripts que delegam para os pacotes |
| `packages/core/src/sync.ts` | Tipos `Tabela` e `Registro`, mais `TABELAS`, `validarLote`, `vence`, `mesclar` e `inicioDaJanela` |
| `packages/core/src/index.ts` | Reexporta tudo |
| `apps/worker/` | Worker atual, movido: `src/`, `public/`, `schema.sql`, `scripts/`, `test/`, `mock/` e `wrangler.toml` |
| `apps/worker/src/sync.js` | `autenticarAparelho`, `puxar`, `enviar` e `esperaAtualizar` |
| `apps/worker/src/pluggy.js` | `idsConexoes`, `registrarItem`, `removerItem`, `atualizarStatus`, `acaoWebhook` e `webhookValido` |
| `apps/worker/src/backup.js` | `exportarBanco`, `chaveBackup` e `salvarBackup` |
| `apps/worker/src/api.js` | Novos `connectToken`, `atualizarItem` e `criarWebhook`; os ids passam a vir do D1 |
| `apps/worker/src/index.js` | Rotas novas, `salvarAjuste` em `registros`, QR no `criarToken` e backup no cron |
| `apps/worker/test/d1.mjs` | D1 falso sobre `node:sqlite` |
| `apps/worker/test/ambiente.mjs` | `criarAmbiente`, `entrarComSenha`, `criarAparelho` e `simularPluggy` |
| `apps/worker/scripts/migrar-ajustes.sql` | Copia `ajustes` para `registros` e remove a tabela antiga. Roda uma vez só |
| `apps/worker/scripts/cashew.mjs` | Conversão pura: backup do Cashew → registros → SQL |
| `apps/worker/scripts/importar-cashew.mjs` | CLI que lê o `.sql` do Cashew (um SQLite) e imprime o SQL de importação |

---

### Tarefa 1: Monorepo pnpm com o Worker em `apps/worker`

**Arquivos:**
- Modificar: `pnpm-workspace.yaml`, `package.json`, `.gitignore`, `README.md` e `.claude/skills/verificar-meu-banco/SKILL.md`
- Mover com `git mv` para `apps/worker/`: `src`, `public`, `schema.sql`, `scripts`, `test`, `mock`, `wrangler.toml` e `.dev.vars.example`
- Criar: `apps/worker/package.json`

**Interfaces:**
- Consome: nada.
- Produz:
  - o pacote `@meu-banco/worker`, com os scripts `test`, `dev`, `push`, `db:local`, `db:remote` e `logs`;
  - `pnpm test` na raiz, que roda `pnpm -r test`.

- [ ] **Passo 1: linha de base dos testes**

Rode: `pnpm test 2>&1 | tail -5`
Esperado: `# fail 0`. Anote o número de `# pass`.

- [ ] **Passo 2: mover**

```bash
mkdir -p apps/worker packages
git mv src public schema.sql scripts test mock wrangler.toml .dev.vars.example apps/worker/
```

- [ ] **Passo 3: `apps/worker/package.json`**

A versão `0.0.7` vem do `package.json` da raiz. Daqui em diante, o `versao.mjs` incrementa esta.

```json
{
  "name": "@meu-banco/worker",
  "version": "0.0.7",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test test/*.test.mjs",
    "mock": "node mock/api-mock.mjs",
    "db:local": "wrangler d1 execute meu-banco --local --file=schema.sql",
    "db:remote": "wrangler d1 execute meu-banco --remote --file=schema.sql",
    "dev": "wrangler dev --test-scheduled",
    "push": "node scripts/versao.mjs && wrangler deploy",
    "logs": "wrangler tail"
  },
  "devDependencies": {
    "wrangler": "^4.40.0"
  }
}
```

Antes de salvar, compare com o `package.json` atual (`git show HEAD:package.json`). Mantenha os comandos dos scripts como estão e mude só o caminho, se houver diferença.

- [ ] **Passo 4: `package.json` da raiz**

```json
{
  "name": "meu-banco",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "pnpm -r test",
    "dev": "pnpm --filter @meu-banco/worker dev",
    "push": "pnpm --filter @meu-banco/worker push",
    "logs": "pnpm --filter @meu-banco/worker logs",
    "db:local": "pnpm --filter @meu-banco/worker db:local",
    "db:remote": "pnpm --filter @meu-banco/worker db:remote"
  },
  "packageManager": "pnpm@12.18.0"
}
```

- [ ] **Passo 5: `pnpm-workspace.yaml`**

Acrescente no topo, sem mexer no `allowBuilds` que já existe:

```yaml
packages:
  - apps/*
  - packages/*
```

- [ ] **Passo 6: `.gitignore`**

Acrescente a linha `.worktrees/`. As entradas `node_modules/`, `.wrangler/` e `.dev.vars` não têm `/` inicial, então já valem em qualquer pasta.

- [ ] **Passo 7: instalar e conferir o lockfile**

Rode: `pnpm install 2>&1 | tail -3 && git diff pnpm-lock.yaml | grep -n "wrangler@" | head`

Esperado:
- a instalação termina sem erro;
- os importers `.` e `apps/worker` aparecem;
- a versão resolvida do wrangler não muda.

- [ ] **Passo 8: caminhos na documentação e na verificação**

Rode: `grep -nE "src/|public/|schema\.sql|scripts/|wrangler\.toml|test/" README.md .claude/skills/verificar-meu-banco/SKILL.md | head -40`

Ajuste o que aparecer:
- caminho de arquivo ganha o prefixo `apps/worker/`;
- `pnpm <script>` continua funcionando na raiz;
- `wrangler ...` direto passa a ser `pnpm --filter @meu-banco/worker exec wrangler ...`.

- [ ] **Passo 9: provar**

Rode: `pnpm test 2>&1 | tail -5`
Esperado: `# fail 0`, com o mesmo `# pass` do passo 1.

Rode: `pnpm --filter @meu-banco/worker exec wrangler deploy --dry-run --outdir .wrangler/dry 2>&1 | tail -3`
Esperado: o bundle é gerado sem erro.

- [ ] **Passo 10: commit**

Confira `git status --short`. Só podem aparecer:
- renomeações (R);
- os dois `package.json`, o `pnpm-workspace.yaml`, o `pnpm-lock.yaml` e o `.gitignore`;
- o README e a skill de verificação.

```bash
git add -A
git commit -m "refactor: transforma o repositório em monorepo pnpm com o Worker em apps/worker

Move src, public, schema.sql, scripts, test, mock e wrangler.toml para
apps/worker (pacote @meu-banco/worker, versão 0.0.7). A raiz fica privada
e delega os scripts. Prepara packages/core para o app Android e o web app.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 2: `packages/core` com o protocolo de sincronização

**Arquivos:**
- Criar: `packages/core/package.json`, `packages/core/tsconfig.json`, `packages/core/src/index.ts` e `packages/core/src/sync.ts`
- Teste: `packages/core/test/sync.test.ts`

**Interfaces:**
- Consome: nada.
- Produz, exportado por `@meu-banco/core`:
  - `type Tabela = "categorias" | "regras" | "orcamentos" | "metas" | "dividas" | "assinaturas" | "ajustes" | "lancamentos"`;
  - `interface Registro { tabela: Tabela; id: string; dados: Record<string, unknown> | null; updated_at: string; deleted_at: string | null }`;
  - `TABELAS`;
  - as constantes `MAX_LOTE = 500`, `MAX_DADOS = 8192`, `FOLGA_RELOGIO_MS = 300000` e `SOBREPOSICAO_MS = 120000`;
  - `dadosValidos(tabela, dados): boolean`;
  - `validarLote(entrada: unknown, agora: string): { registros: Registro[]; rejeitados: { indice: number; motivo: string }[] } | { erro: string }`. As datas saem normalizadas com `toISOString()`, e um registro com `deleted_at` sai com `dados: null`;
  - `chave(r)`, que devolve `"tabela:id"`;
  - `vence(novo, atual?)`: só vence um `updated_at` estritamente maior;
  - `mesclar(local: ReadonlyMap<string, Registro>, remotos: readonly Registro[]): Map<string, Registro>`;
  - `inicioDaJanela(desde: string | null): string | null`, que recua 2 min ou devolve `null`.

- [ ] **Passo 1: pacote**

`packages/core/package.json`:

```json
{
  "name": "@meu-banco/core",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "exports": { ".": "./src/index.ts" },
  "scripts": {
    "test": "node --test test/*.test.ts",
    "typecheck": "tsc -p ."
  },
  "devDependencies": {
    "@types/node": "^22.18.0",
    "typescript": "^5.9.3"
  }
}
```

`packages/core/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022"],
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "noEmit": true,
    "allowImportingTsExtensions": true,
    "verbatimModuleSyntax": true,
    "erasableSyntaxOnly": true,
    "types": ["node"]
  },
  "include": ["src", "test"]
}
```

Rode: `pnpm install 2>&1 | tail -2`

- [ ] **Passo 2: teste que falha**

`packages/core/test/sync.test.ts`:

```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { validarLote, vence, mesclar, inicioDaJanela, chave, dadosValidos, MAX_LOTE, type Registro } from "../src/index.ts";

const AGORA = "2026-11-09T12:00:00.000Z";
const cat = (over: Partial<Registro> = {}): Registro => ({
  tabela: "categorias", id: "c1", dados: { nome: "Mercado", tipo: "despesa" },
  updated_at: "2026-11-09T11:00:00.000Z", deleted_at: null, ...over,
});

test("lote válido passa e normaliza as datas", () => {
  const r = validarLote([cat({ updated_at: "2026-11-09T08:00:00-03:00" })], AGORA);
  assert.ok("registros" in r);
  assert.equal(r.registros[0].updated_at, "2026-11-09T11:00:00.000Z");
  assert.deepEqual(r.rejeitados, []);
});

test("entrada que não é lista ou passa do limite é erro do lote inteiro", () => {
  assert.deepEqual(validarLote({}, AGORA), { erro: "registros deve ser uma lista" });
  const muitos = Array.from({ length: MAX_LOTE + 1 }, (_, i) => cat({ id: "c" + i }));
  assert.ok("erro" in validarLote(muitos, AGORA));
});

test("registro inválido é rejeitado sem derrubar o lote", () => {
  const r = validarLote([
    cat(),
    cat({ tabela: "x" as never }),
    cat({ id: "" }),
    cat({ updated_at: "ontem" }),
    cat({ dados: { nome: "Sem tipo" } }),
    cat({ dados: { nome: "Mercado", tipo: "despesa", extra: "y".repeat(8200) } }),
  ], AGORA);
  assert.ok("registros" in r);
  assert.equal(r.registros.length, 1);
  assert.deepEqual(r.rejeitados.map((x) => x.motivo), [
    "tabela desconhecida", "id inválido", "updated_at inválido", "dados inválidos", "dados acima de 8 KB",
  ]);
});

test("relógio adiantado mais de 5 min vira o horário do servidor", () => {
  const r = validarLote([cat({ updated_at: "2026-11-09T12:06:00.000Z" }), cat({ id: "c2", updated_at: "2026-11-09T12:04:00.000Z" })], AGORA);
  assert.ok("registros" in r);
  assert.equal(r.registros[0].updated_at, AGORA);
  assert.equal(r.registros[1].updated_at, "2026-11-09T12:04:00.000Z");
});

test("exclusão aceita dados nulos e sai com dados null", () => {
  const r = validarLote([cat({ dados: null, deleted_at: "2026-11-09T11:30:00.000Z" })], AGORA);
  assert.ok("registros" in r);
  assert.equal(r.registros[0].dados, null);
  assert.equal(r.registros[0].deleted_at, "2026-11-09T11:30:00.000Z");
});

test("campos opcionais aceitam ausência ou null, mas não tipo errado", () => {
  assert.equal(dadosValidos("ajustes", {}), true);
  assert.equal(dadosValidos("ajustes", { category: null, gasto: 0 }), true);
  assert.equal(dadosValidos("ajustes", { gasto: 2 }), false);
  assert.equal(dadosValidos("lancamentos", { data: "2026-11-09", descricao: "Feira", valor: -42.5 }), true);
  assert.equal(dadosValidos("lancamentos", { data: "09/11/2026", descricao: "Feira", valor: -42.5 }), false);
  assert.equal(dadosValidos("orcamentos", { nome: "Casa", valor: 900, categoria_ids: [], periodo: "ciclo" }), true);
  assert.equal(dadosValidos("dividas", { tipo: "emprestimo", nome: "João", sentido: "me_devem", valor_total: 300 }), true);
});

test("last-write-wins: só updated_at estritamente maior vence", () => {
  const atual = cat();
  assert.equal(vence(cat({ updated_at: "2026-11-09T11:00:01.000Z" }), atual), true);
  assert.equal(vence(cat(), atual), false);
  assert.equal(vence(cat({ updated_at: "2026-11-09T10:00:00.000Z" }), atual), false);
  assert.equal(vence(cat(), undefined), true);
});

test("mesclar é idempotente e não altera o mapa local", () => {
  const local = new Map([[chave(cat()), cat()]]);
  const novo = cat({ dados: { nome: "Feira", tipo: "despesa" }, updated_at: "2026-11-09T11:30:00.000Z" });
  const duas = mesclar(mesclar(local, [novo]), [novo, cat()]);
  assert.deepEqual(duas.get("categorias:c1")?.dados, { nome: "Feira", tipo: "despesa" });
  assert.deepEqual(local.get("categorias:c1")?.dados, { nome: "Mercado", tipo: "despesa" });
});

test("janela do cursor recua 2 minutos", () => {
  assert.equal(inicioDaJanela(null), null);
  assert.equal(inicioDaJanela("2026-11-09T12:00:00.000Z"), "2026-11-09T11:58:00.000Z");
});
```

- [ ] **Passo 3: ver falhar**

Rode: `pnpm --filter @meu-banco/core test 2>&1 | tail -5`
Esperado: FAIL com `Cannot find module '.../src/index.ts'`.

- [ ] **Passo 4: implementar**

`packages/core/src/sync.ts`:

```ts
// Protocolo de sincronização dos dados do usuário (tabela genérica `registros` no D1).
// Last-write-wins por registro pelo `updated_at` do cliente; o cursor de leitura usa o `server_at` do servidor.

export type Tabela = "categorias" | "regras" | "orcamentos" | "metas" | "dividas" | "assinaturas" | "ajustes" | "lancamentos";

export interface Registro {
  tabela: Tabela;
  id: string;
  dados: Record<string, unknown> | null;
  updated_at: string;
  deleted_at: string | null;
}

type Campo = "texto" | "numero" | "lista" | "data" | readonly (string | number)[];
type Esquema = Readonly<Record<string, Campo>>; // chave terminada em "?" = opcional (ausente ou null); chaves extras são aceitas

export const TABELAS: Readonly<Record<Tabela, Esquema>> = {
  categorias: { nome: "texto", tipo: ["despesa", "receita"], "cor?": "texto", "icone?": "texto", "pai_id?": "texto", "ordem?": "numero", "pluggy?": "lista" },
  regras: { padrao: "texto", categoria_id: "texto", "conta_id?": "texto", "prioridade?": "numero" },
  orcamentos: { nome: "texto", valor: "numero", categoria_ids: "lista", periodo: ["ciclo", "mensal"] },
  metas: { nome: "texto", valor_alvo: "numero", "valor_atual?": "numero", "prazo?": "data" },
  dividas: { tipo: ["emprestimo"], nome: "texto", "pessoa?": "texto", sentido: ["devo", "me_devem"], valor_total: "numero", "pago?": "numero" },
  assinaturas: { nome: "texto", valor: "numero", dia: "numero", padrao: "texto", status: ["confirmada", "ignorada"], "categoria_id?": "texto" },
  ajustes: { "category?": "texto", "gasto?": [0, 1], "categoria_id?": "texto", "nota?": "texto" },
  lancamentos: { data: "data", descricao: "texto", valor: "numero", "categoria_id?": "texto", "carteira?": "texto", "nota?": "texto" },
};

export const MAX_LOTE = 500;
export const MAX_DADOS = 8192;
export const FOLGA_RELOGIO_MS = 5 * 60_000;
export const SOBREPOSICAO_MS = 2 * 60_000;

const DATA = /^\d{4}-\d{2}-\d{2}$/;

function campoValido(tipo: Campo, v: unknown): boolean {
  if (Array.isArray(tipo)) return (tipo as readonly unknown[]).includes(v);
  if (tipo === "texto") return typeof v === "string" && v.length > 0 && v.length <= 200;
  if (tipo === "numero") return typeof v === "number" && Number.isFinite(v);
  if (tipo === "lista") return Array.isArray(v) && v.every((x) => typeof x === "string");
  return typeof v === "string" && DATA.test(v);
}

export function dadosValidos(tabela: Tabela, dados: unknown): boolean {
  if (!dados || typeof dados !== "object" || Array.isArray(dados)) return false;
  const d = dados as Record<string, unknown>;
  return Object.entries(TABELAS[tabela]).every(([nome, tipo]) => {
    const opcional = nome.endsWith("?");
    const v = d[opcional ? nome.slice(0, -1) : nome];
    return (opcional && v == null) || campoValido(tipo, v);
  });
}

const iso = (v: unknown): string | null => {
  if (typeof v !== "string") return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : new Date(t).toISOString();
};

function problema(bruto: unknown): string | null {
  if (!bruto || typeof bruto !== "object") return "registro inválido";
  const r = bruto as Record<string, unknown>;
  if (typeof r.tabela !== "string" || !Object.hasOwn(TABELAS, r.tabela)) return "tabela desconhecida";
  if (typeof r.id !== "string" || r.id.length < 1 || r.id.length > 80) return "id inválido";
  if (!iso(r.updated_at)) return "updated_at inválido";
  if (r.deleted_at != null) return iso(r.deleted_at) ? null : "deleted_at inválido";
  if (!dadosValidos(r.tabela as Tabela, r.dados)) return "dados inválidos";
  if (JSON.stringify(r.dados).length > MAX_DADOS) return "dados acima de 8 KB";
  return null;
}

export type Rejeitado = { indice: number; motivo: string };

export function validarLote(entrada: unknown, agora: string): { registros: Registro[]; rejeitados: Rejeitado[] } | { erro: string } {
  if (!Array.isArray(entrada)) return { erro: "registros deve ser uma lista" };
  if (entrada.length > MAX_LOTE) return { erro: `no máximo ${MAX_LOTE} registros por envio` };
  const limite = Date.parse(agora) + FOLGA_RELOGIO_MS;
  const corrigir = (v: string) => (Date.parse(v) > limite ? agora : v); // relógio adiantado não vence para sempre
  const registros: Registro[] = [];
  const rejeitados: Rejeitado[] = [];
  entrada.forEach((bruto, indice) => {
    const motivo = problema(bruto);
    if (motivo) return void rejeitados.push({ indice, motivo });
    const r = bruto as Registro;
    const deleted = r.deleted_at == null ? null : corrigir(iso(r.deleted_at) as string);
    registros.push({ tabela: r.tabela, id: r.id, dados: deleted ? null : r.dados, updated_at: corrigir(iso(r.updated_at) as string), deleted_at: deleted });
  });
  return { registros, rejeitados };
}

export const chave = (r: Pick<Registro, "tabela" | "id">): string => `${r.tabela}:${r.id}`;

// Empate fica com o que já existe: o mesmo registro reenviado não muda nada.
export const vence = (novo: Registro, atual: Registro | undefined): boolean => !atual || novo.updated_at > atual.updated_at;

export function mesclar(local: ReadonlyMap<string, Registro>, remotos: readonly Registro[]): Map<string, Registro> {
  const saida = new Map(local);
  for (const r of remotos) if (vence(r, saida.get(chave(r)))) saida.set(chave(r), r);
  return saida;
}

// O pull relê 2 min antes do cursor: uma gravação que terminou logo depois do `agora` anterior não se perde.
export function inicioDaJanela(desde: string | null): string | null {
  return desde === null ? null : new Date(Date.parse(desde) - SOBREPOSICAO_MS).toISOString();
}
```

`packages/core/src/index.ts`:

```ts
export * from "./sync.ts";
```

- [ ] **Passo 5: ver passar e checar os tipos**

Rode: `pnpm --filter @meu-banco/core test 2>&1 | tail -4 && pnpm --filter @meu-banco/core typecheck`
Esperado:
- `# pass 9` e `# fail 0`;
- o `tsc` termina sem saída.

- [ ] **Passo 6: commit**

```bash
git add packages/core pnpm-lock.yaml
git commit -m "feat(core): protocolo de sincronização em TypeScript apagável

Valida lotes de registros (até 500, dados até 8 KB, folga de relógio de
5 min), decide o last-write-wins por updated_at e recua 2 min o cursor de
leitura. Roda direto no Node 22.18+ sem build.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 3: D1 falso, tabela `registros` e ajustes migrados

**Arquivos:**
- Criar: `apps/worker/test/d1.mjs`, `apps/worker/test/ambiente.mjs` e `apps/worker/scripts/migrar-ajustes.sql`
- Modificar:
  - `apps/worker/schema.sql`: troca a tabela `ajustes` por `registros`, `pluggy_items` e a view `v_ajustes`;
  - `apps/worker/src/index.js`: `DE_TX` (perto da linha 162), `historico` (perto da 194) e `salvarAjuste` (perto da 208–222).
- Teste: `apps/worker/test/registros.test.mjs`

**Interfaces:**
- Consome: nada do core.
- Produz:
  - `criarD1()`, com `prepare(sql).bind(...).run()`, `.all()`, `.first(col?)`, `batch(stmts)` e `exec(sql)`. Já vem com o schema carregado;
  - `test/ambiente.mjs`, com:
    - `ORIGEM`;
    - `criarAmbiente(extraEnv?)`, que devolve `{ env, ctx, worker, pedir(caminho, init), esperar() }`;
    - `entrarComSenha(pedir)`, que devolve `"sessao=..."`;
    - `criarAparelho(env, nome?)`, que devolve o token em claro;
    - `simularPluggy(rotas)`, que devolve `{ chamadas }`;
    - `restaurarFetch()`;
  - tabelas `registros(tabela, id, dados, updated_at, deleted_at, server_at)` e `pluggy_items(id, conector, status, criado, atualizado, removido)`;
  - view `v_ajustes(transaction_id, category, gasto, updated_at)`.

- [ ] **Passo 1: D1 falso**

`apps/worker/test/d1.mjs`:

```js
// D1 falso para testes: a API usada pelo Worker (prepare/bind/run/all/first/batch) sobre node:sqlite em memória.
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

const SCHEMA = readFileSync(new URL("../schema.sql", import.meta.url), "utf8");
const valor = (v) => (typeof v === "boolean" ? Number(v) : v === undefined ? null : v); // node:sqlite não aceita boolean
const objeto = (r) => (r == null ? r : { ...r }); // linhas do node:sqlite têm protótipo nulo

class Comando {
  constructor(db, sql, args = []) { this.db = db; this.sql = sql; this.args = args; }
  bind(...args) { return new Comando(this.db, this.sql, args.map(valor)); }
  async run() {
    const r = this.db.prepare(this.sql).run(...this.args);
    return { success: true, meta: { changes: Number(r.changes), last_row_id: Number(r.lastInsertRowid) } };
  }
  async all() { return { success: true, results: this.db.prepare(this.sql).all(...this.args).map(objeto), meta: {} }; }
  async first(coluna) {
    const r = objeto(this.db.prepare(this.sql).get(...this.args));
    return r == null ? null : coluna ? r[coluna] : r;
  }
}

export function criarD1() {
  const db = new DatabaseSync(":memory:");
  db.exec(SCHEMA);
  return {
    prepare: (sql) => new Comando(db, sql),
    exec: async (sql) => { db.exec(sql); return { count: 1 }; },
    async batch(comandos) {
      db.exec("BEGIN");
      try {
        const saida = [];
        for (const c of comandos) saida.push(await c.all());
        db.exec("COMMIT");
        return saida;
      } catch (e) { db.exec("ROLLBACK"); throw e; }
    },
  };
}
```

- [ ] **Passo 2: ambiente de rota**

`apps/worker/test/ambiente.mjs`:

```js
// Monta env/ctx para chamar worker.fetch no Node, com login, token de aparelho e Pluggy falso.
import worker from "../src/index.js";
import { gerarToken, hashToken } from "../src/app.js";
import { criarD1 } from "./d1.mjs";

// O Workers tem crypto.subtle.timingSafeEqual; o Node não.
crypto.subtle.timingSafeEqual ??= (a, b) => Buffer.from(a).equals(Buffer.from(b));

export const ORIGEM = "https://meu-banco.test";

export function criarAmbiente(extra = {}) {
  const tarefas = [];
  const env = { APP_PASSWORD: "senha", SESSION_SECRET: "segredo", DB: criarD1(), ASSETS: { fetch: async () => new Response("asset") }, ...extra };
  const ctx = { waitUntil: (p) => tarefas.push(p) };
  const pedir = (caminho, init = {}) => worker.fetch(new Request(ORIGEM + caminho, init), env, ctx);
  return { env, ctx, worker, pedir, esperar: () => Promise.allSettled(tarefas) };
}

export async function entrarComSenha(pedir) {
  const r = await pedir("/api/login", { method: "POST", headers: { origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ senha: "senha" }) });
  if (r.status !== 200) throw new Error("login falhou: " + r.status);
  return r.headers.get("set-cookie").split(";")[0];
}

export async function criarAparelho(env, nome = "Celular") {
  const token = gerarToken();
  await env.DB.prepare("INSERT INTO app_tokens (id, nome, hash, criado) VALUES (?1, ?2, ?3, ?4)")
    .bind(crypto.randomUUID(), nome, await hashToken(token), new Date().toISOString()).run();
  return token;
}

// rotas(url, init) devolve um objeto JSON ou uma Response. /auth responde sozinho.
const fetchOriginal = globalThis.fetch;
export function simularPluggy(rotas) {
  const chamadas = [];
  globalThis.fetch = async (alvo, init = {}) => {
    const url = new URL(String(alvo));
    chamadas.push({ metodo: init.method || "GET", caminho: url.pathname, corpo: init.body ? JSON.parse(init.body) : null });
    if (url.pathname === "/auth") return Response.json({ apiKey: "k" });
    const r = await rotas(url, init);
    return r instanceof Response ? r : Response.json(r ?? {});
  };
  return { chamadas };
}
export const restaurarFetch = () => { globalThis.fetch = fetchOriginal; };
```

Confira:
- as colunas de `app_tokens` em `schema.sql`; o `INSERT` precisa preencher todas as `NOT NULL`;
- a rota de login e o nome do campo da senha em `index.js` (`entrar`).

Ajuste o helper se algo for diferente.

- [ ] **Passo 3: teste que falha**

`apps/worker/test/registros.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { criarD1 } from "./d1.mjs";
import { criarAmbiente, entrarComSenha, ORIGEM } from "./ambiente.mjs";

const SCHEMA = readFileSync(new URL("../schema.sql", import.meta.url), "utf8");
const MIGRAR = readFileSync(new URL("../scripts/migrar-ajustes.sql", import.meta.url), "utf8");
const hoje = new Date().toISOString().slice(0, 10);

test("schema cria registros, pluggy_items e a view v_ajustes, sem a tabela ajustes", async () => {
  const db = criarD1();
  const nomes = (await db.prepare("SELECT name FROM sqlite_master WHERE name IN ('registros','pluggy_items','v_ajustes','ajustes') ORDER BY name").all()).results.map((r) => r.name);
  assert.deepEqual(nomes, ["pluggy_items", "registros", "v_ajustes"]);
});

test("migração copia os ajustes antigos, remove a tabela e o schema roda de novo sem erro", () => {
  const db = new DatabaseSync(":memory:");
  // estado de produção hoje: só a tabela antiga
  db.exec("CREATE TABLE ajustes (transaction_id TEXT PRIMARY KEY, category TEXT, gasto INTEGER, updated_at TEXT NOT NULL)");
  db.exec("INSERT INTO ajustes VALUES ('t1','Mercado',NULL,'2026-11-01T10:00:00.000Z'), ('t2',NULL,0,'2026-11-02T10:00:00.000Z')");
  db.exec(SCHEMA); // pnpm db:remote
  db.exec(MIGRAR); // migração única
  db.exec(SCHEMA); // db:remote de novo no futuro
  const linhas = db.prepare("SELECT transaction_id, category, gasto, updated_at FROM v_ajustes ORDER BY transaction_id").all().map((r) => ({ ...r }));
  assert.deepEqual(linhas, [
    { transaction_id: "t1", category: "Mercado", gasto: null, updated_at: "2026-11-01T10:00:00.000Z" },
    { transaction_id: "t2", category: null, gasto: 0, updated_at: "2026-11-02T10:00:00.000Z" },
  ]);
  assert.equal(db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'ajustes'").get().n, 0);
});

test("PUT /api/ajustes grava em registros, preserva campos do app e aparece na view", async () => {
  const { env, pedir } = criarAmbiente();
  const cookie = await entrarComSenha(pedir);
  const put = (corpo) => pedir("/api/ajustes/t1", { method: "PUT", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify(corpo) });

  // campo gravado pelo app (Fase 2)
  await env.DB.prepare("INSERT INTO registros VALUES ('ajustes','t1','{\"nota\":\"do app\"}','2026-11-01T00:00:00.000Z',NULL,'2026-11-01T00:00:00.000Z')").run();
  assert.equal((await put({ category: "Mercado", gasto: 0 })).status, 200);
  let r = await env.DB.prepare("SELECT dados, server_at FROM registros WHERE tabela = 'ajustes' AND id = 't1'").first();
  assert.deepEqual(JSON.parse(r.dados), { nota: "do app", category: "Mercado", gasto: 0 });
  assert.ok(r.server_at > "2026-11-01T00:00:00.000Z");
  assert.deepEqual(await env.DB.prepare("SELECT category, gasto FROM v_ajustes WHERE transaction_id = 't1'").first(), { category: "Mercado", gasto: 0 });

  assert.equal((await put({ category: null, gasto: null })).status, 200);
  r = await env.DB.prepare("SELECT dados FROM registros WHERE tabela = 'ajustes' AND id = 't1'").first();
  assert.deepEqual(JSON.parse(r.dados), { nota: "do app" });
});

test("histórico continua lendo o ajuste pela view", async () => {
  const { env, pedir } = criarAmbiente();
  const cookie = await entrarComSenha(pedir);
  await env.DB.prepare("INSERT INTO transactions (id, account_id, date, description, amount, updated_at) VALUES ('t1','c1',?1,'DROGASIL',-68.35,?2)").bind(hoje, new Date().toISOString()).run();
  await env.DB.prepare("INSERT INTO registros VALUES ('ajustes','t1','{\"category\":\"Farmácia\"}','2026-11-05T00:00:00.000Z',NULL,'2026-11-05T00:00:00.000Z')").run();
  const j = await (await pedir("/api/historico", { headers: { cookie } })).json();
  assert.equal(j.transacoes.find((t) => t.id === "t1")?.ajuste_categoria, "Farmácia");
});
```

Confirme o caminho da rota que chama `historico` com `grep -n "historico" apps/worker/src/index.js`. Confirme também as colunas `NOT NULL` de `transactions` no `schema.sql`. Se forem diferentes, ajuste o teste.

- [ ] **Passo 4: ver falhar**

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: falham os 4 testes de `registros.test.mjs`, porque ainda não existem `v_ajustes` nem `migrar-ajustes.sql`.

- [ ] **Passo 5: `schema.sql`**

Em `apps/worker/schema.sql`, apague o bloco do comentário dos ajustes do painel junto com o `CREATE TABLE IF NOT EXISTS ajustes (...)`. No lugar, coloque:

```sql
-- Dados do usuário, sincronizados com os apps (categorias, regras, orçamentos, metas, dívidas, assinaturas,
-- ajustes de transação, lançamentos manuais). Formato de `dados` por tabela: packages/core/src/sync.ts.
-- updated_at = relógio do cliente (last-write-wins); server_at = relógio do servidor (cursor do pull).
CREATE TABLE IF NOT EXISTS registros (
  tabela     TEXT NOT NULL,
  id         TEXT NOT NULL,
  dados      TEXT,                        -- JSON; NULL quando excluído
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  server_at  TEXT NOT NULL,
  PRIMARY KEY (tabela, id)
);
CREATE INDEX IF NOT EXISTS idx_registros_server ON registros(server_at);

-- Ajustes no formato antigo (category/gasto) para as consultas do painel. A sincronização do Pluggy nunca mexe aqui.
CREATE VIEW IF NOT EXISTS v_ajustes AS
  SELECT id AS transaction_id, json_extract(dados, '$.category') AS category, json_extract(dados, '$.gasto') AS gasto, updated_at
  FROM registros WHERE tabela = 'ajustes' AND deleted_at IS NULL;

-- Conexões do Pluggy (items). Substitui o secret PLUGGY_ITEM_IDS, copiado daqui na primeira sincronização.
CREATE TABLE IF NOT EXISTS pluggy_items (
  id         TEXT PRIMARY KEY,
  conector   TEXT,
  status     TEXT,                        -- status do item no Pluggy (UPDATED, LOGIN_ERROR, ...)
  criado     TEXT NOT NULL,
  atualizado TEXT,
  removido   TEXT
);
```

- [ ] **Passo 6: migração**

`apps/worker/scripts/migrar-ajustes.sql`:

```sql
-- Roda UMA vez no D1 remoto, depois de `pnpm db:remote`: copia a tabela antiga `ajustes` para `registros`
-- e a remove. Rodar de novo falha em "no such table: ajustes", sem efeito.
-- json_patch('{}', …) descarta as chaves nulas: {category:null, gasto:0} vira {"gasto":0}.
CREATE TABLE IF NOT EXISTS registros (
  tabela TEXT NOT NULL, id TEXT NOT NULL, dados TEXT, updated_at TEXT NOT NULL, deleted_at TEXT, server_at TEXT NOT NULL,
  PRIMARY KEY (tabela, id)
);
INSERT OR IGNORE INTO registros (tabela, id, dados, updated_at, deleted_at, server_at)
  SELECT 'ajustes', transaction_id, json_patch('{}', json_object('category', category, 'gasto', gasto)), updated_at, NULL, updated_at FROM ajustes;
DROP TABLE ajustes;
```

- [ ] **Passo 7: consultas e `salvarAjuste` em `apps/worker/src/index.js`**

`DE_TX`:

```js
const DE_TX = "FROM transactions t LEFT JOIN v_ajustes a ON a.transaction_id = t.id";
```

Em `historico`, troque o trecho literal `FROM transactions t LEFT JOIN ajustes a ON a.transaction_id = t.id` por `${DE_TX}`. A string vira template literal.

Em `salvarAjuste`, troque o `if (category === null && gasto === null) { DELETE ... } else { INSERT ... }` inteiro por:

```js
  // Merge-patch (RFC 7396): null remove a chave; campos gravados pelo app (ex.: nota) ficam. O painel sempre vence.
  const ts = agora();
  await env.DB.prepare(
    "INSERT INTO registros (tabela, id, dados, updated_at, deleted_at, server_at) VALUES ('ajustes', ?1, json_patch('{}', ?2), ?3, NULL, ?3) " +
      "ON CONFLICT(tabela, id) DO UPDATE SET dados = json_patch(COALESCE(registros.dados, '{}'), ?2), updated_at = ?3, deleted_at = NULL, server_at = ?3"
  ).bind(id, JSON.stringify({ category, gasto }), ts).run();
```

Mantenha a validação de entrada e a resposta de `salvarAjuste` como estão.

- [ ] **Passo 8: ver passar**

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: `# fail 0`, com a linha de base mais 4 testes passando.

Rode: `grep -nE "\bajustes\b" apps/worker/src/*.js`
Esperado: só aparecem `v_ajustes`, `'ajustes'` e a rota `/api/ajustes`.

- [ ] **Passo 9: commit**

```bash
git add apps/worker
git commit -m "feat(worker): tabela registros para dados do usuário e ajustes migrados

Ajustes do painel passam a ser registros (tabela='ajustes') com merge-patch,
lidos pela view v_ajustes. Adiciona pluggy_items, o script único
migrar-ajustes.sql e um D1 falso em node:sqlite para testar rotas.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 4: `/api/sync` (pull e push) com token de aparelho ou sessão

**Arquivos:**
- Criar: `apps/worker/src/sync.js`
- Modificar:
  - `apps/worker/package.json`, com a dependência `@meu-banco/core`;
  - `apps/worker/src/index.js`, no roteador, em `appTransacoes` e em `USO_TOKEN_MS`.
- Teste: `apps/worker/test/sync.test.mjs`

**Interfaces:**
- Consome:
  - `validarLote` e `inicioDaJanela`, de `@meu-banco/core`;
  - `tokenDoCabecalho`, `hashToken` e `normalizarDesde`, de `./app.js`;
  - os helpers da Tarefa 3.
- Produz, em `src/sync.js`:
  - `USO_TOKEN_MS = 60000` e `INTERVALO_ATUALIZAR_MS = 1800000`;
  - `autenticarAparelho(request, db, agoraIso)`: devolve `Promise<string | null>` com o id do token. Grava `ultimo_uso` no máximo uma vez por minuto;
  - `puxar(db, desde, agoraIso)`, que devolve `{ agora, completo, contas, transacoes, registros, pendentes, config, faturas, avisos }`:
    - `registros` traz `dados` já como objeto;
    - `faturas` tem o formato `{ [accountId]: ... }`;
    - `config` tem o formato `{ chave: valor }`;
  - `enviar(db, corpo, agoraIso)`, que devolve `{ status: 200, corpo: { ok: true, aceitos, rejeitados, agora } }` ou `{ status: 400, corpo: { erro } }`;
  - `esperaAtualizar(ultimoIso, agoraMs)`, que devolve quantos ms faltam (0 = liberado).
- Rotas, com Bearer de aparelho ou cookie de sessão (POST com cookie exige mesma origem):
  - `GET /api/sync?desde=ISO`: `desde` inválido responde 400;
  - `POST /api/sync`, com corpo `{ registros }`.

- [ ] **Passo 1: dependência**

Em `apps/worker/package.json`, acrescente:

```json
  "dependencies": {
    "@meu-banco/core": "workspace:*"
  },
```

Rode: `pnpm install 2>&1 | tail -2 && ls -l apps/worker/node_modules/@meu-banco/`
Esperado: `core -> ../../../packages/core`.

- [ ] **Passo 2: teste que falha**

`apps/worker/test/sync.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, entrarComSenha, ORIGEM } from "./ambiente.mjs";
import { esperaAtualizar } from "../src/sync.js";

const reg = (over = {}) => ({ tabela: "categorias", id: "c1", dados: { nome: "Mercado", tipo: "despesa" }, updated_at: "2026-11-09T11:00:00.000Z", deleted_at: null, ...over });

async function preparar() {
  const amb = criarAmbiente();
  const token = await criarAparelho(amb.env);
  const auth = { authorization: "Bearer " + token };
  const enviar = (registros, headers = auth) => amb.pedir("/api/sync", { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ registros }) });
  const puxar = (desde, headers = auth) => amb.pedir("/api/sync" + (desde ? "?desde=" + encodeURIComponent(desde) : ""), { headers });
  return { ...amb, auth, enviar, puxar };
}

test("sem token e sem sessão: 401", async () => {
  const { pedir } = await preparar();
  assert.equal((await pedir("/api/sync")).status, 401);
  assert.equal((await pedir("/api/sync", { headers: { authorization: "Bearer mb_" + "x".repeat(43) } })).status, 401);
});

test("push grava, pull completo devolve e pull incremental traz só o que mudou", async () => {
  const { enviar, puxar } = await preparar();
  const r1 = await (await enviar([reg(), reg({ id: "c2", dados: { nome: "Salário", tipo: "receita" } })])).json();
  assert.equal(r1.aceitos, 2);
  assert.deepEqual(r1.rejeitados, []);

  const completo = await (await puxar()).json();
  assert.equal(completo.completo, true);
  assert.deepEqual(completo.registros.map((r) => r.id).sort(), ["c1", "c2"]);
  assert.deepEqual(completo.registros.find((r) => r.id === "c1").dados, { nome: "Mercado", tipo: "despesa" });
  for (const k of ["contas", "transacoes", "pendentes", "faturas", "avisos", "config", "agora"]) assert.ok(k in completo, k);

  const depois = new Date(Date.parse(completo.agora) + 3 * 60_000).toISOString();
  assert.equal((await (await puxar(depois)).json()).registros.length, 0, "fora da sobreposição de 2 min");
  assert.equal((await (await puxar(completo.agora)).json()).registros.length, 2, "dentro da sobreposição: reentrega idempotente");
});

test("last-write-wins no D1: antigo ou igual não sobrescreve; mais novo sim; exclusão propaga", async () => {
  const { enviar, puxar, env } = await preparar();
  const nome = async () => JSON.parse(await env.DB.prepare("SELECT dados FROM registros WHERE id = 'c1'").first("dados")).nome;
  await enviar([reg()]);
  await enviar([reg({ dados: { nome: "Antigo", tipo: "despesa" }, updated_at: "2026-11-09T10:00:00.000Z" })]);
  await enviar([reg({ dados: { nome: "Igual", tipo: "despesa" } })]);
  assert.equal(await nome(), "Mercado");
  await enviar([reg({ dados: { nome: "Feira", tipo: "despesa" }, updated_at: "2026-11-09T11:30:00.000Z" })]);
  assert.equal(await nome(), "Feira");

  const { agora } = await (await puxar()).json();
  await enviar([reg({ dados: null, deleted_at: "2026-11-09T11:40:00.000Z", updated_at: "2026-11-09T11:40:00.000Z" })]);
  assert.equal((await (await puxar()).json()).registros.length, 0, "pull completo não traz exclusões");
  const inc = await (await puxar(agora)).json();
  assert.equal(inc.registros[0].deleted_at, "2026-11-09T11:40:00.000Z");
  assert.equal(inc.registros[0].dados, null);
});

test("inválidos voltam em rejeitados; lote malformado e desde inválido são 400", async () => {
  const { enviar, pedir, auth } = await preparar();
  const r = await (await enviar([reg(), reg({ id: "" })])).json();
  assert.equal(r.aceitos, 1);
  assert.deepEqual(r.rejeitados, [{ indice: 1, motivo: "id inválido" }]);
  assert.equal((await pedir("/api/sync", { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: "{}" })).status, 400);
  assert.equal((await pedir("/api/sync?desde=ontem", { headers: auth })).status, 400);
});

test("sessão do painel também sincroniza; POST com cookie de outra origem é 403", async () => {
  const { enviar, puxar, pedir } = await preparar();
  const cookie = await entrarComSenha(pedir);
  assert.equal((await puxar(null, { cookie })).status, 200);
  assert.equal((await enviar([reg()], { cookie, origin: ORIGEM })).status, 200);
  assert.equal((await enviar([reg()], { cookie, origin: "https://outro.site" })).status, 403);
});

test("uso grava ultimo_uso; token revogado perde acesso", async () => {
  const { env, puxar } = await preparar();
  assert.equal((await puxar()).status, 200);
  assert.ok(await env.DB.prepare("SELECT ultimo_uso FROM app_tokens").first("ultimo_uso"));
  await env.DB.prepare("UPDATE app_tokens SET revogado = '2026-11-09T00:00:00.000Z'").run();
  assert.equal((await puxar()).status, 401);
});

test("esperaAtualizar: 30 min desde o último Atualizar", () => {
  const t = Date.parse("2026-11-09T12:00:00.000Z");
  assert.equal(esperaAtualizar(null, t), 0);
  assert.equal(esperaAtualizar("2026-11-09T11:50:00.000Z", t), 20 * 60_000);
  assert.equal(esperaAtualizar("2026-11-09T11:20:00.000Z", t), 0);
});
```

- [ ] **Passo 3: ver falhar**

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: FAIL com `Cannot find module '../src/sync.js'`.

- [ ] **Passo 4: `apps/worker/src/sync.js`**

```js
// Sincronização em duas vias com os apps: pull (dados do banco + registros do usuário) e push (registros, LWW).
import { validarLote, inicioDaJanela } from "@meu-banco/core";
import { hashToken, tokenDoCabecalho } from "./app.js";

export const USO_TOKEN_MS = 60 * 1000; // ultimo_uso é gravado no máximo 1 vez por minuto
export const INTERVALO_ATUALIZAR_MS = 30 * 60 * 1000;

export async function autenticarAparelho(request, db, agoraIso) {
  const token = tokenDoCabecalho(request.headers.get("authorization"));
  if (!token) return null;
  const reg = await db.prepare("SELECT id FROM app_tokens WHERE hash = ?1 AND revogado IS NULL").bind(await hashToken(token)).first();
  if (!reg) return null;
  await db.prepare("UPDATE app_tokens SET ultimo_uso = ?1 WHERE id = ?2 AND (ultimo_uso IS NULL OR ultimo_uso < ?3)")
    .bind(agoraIso, reg.id, new Date(Date.parse(agoraIso) - USO_TOKEN_MS).toISOString()).run();
  return reg.id;
}

const json = (texto) => (texto == null ? null : JSON.parse(texto));

// desde = null → leitura completa (sem exclusões). Senão, tudo que mudou desde (desde − 2 min).
export async function puxar(db, desde, agoraIso) {
  const janela = inicioDaJanela(desde);
  const [contas, transacoes, registros, pendentes, config, snapshots] = await db.batch([
    db.prepare("SELECT id, type, name, bank, balance, credit_limit, available_limit, due_date, item_id, updated_at FROM accounts ORDER BY type, name"),
    db.prepare("SELECT * FROM transactions WHERE ?1 IS NULL OR updated_at > ?1 ORDER BY date, id").bind(janela),
    db.prepare("SELECT tabela, id, dados, updated_at, deleted_at FROM registros WHERE (?1 IS NULL AND deleted_at IS NULL) OR server_at > ?1 ORDER BY server_at").bind(janela),
    db.prepare("SELECT id FROM transactions WHERE status = 'PENDING' ORDER BY id"),
    db.prepare("SELECT chave, valor FROM config"),
    db.prepare("SELECT key, data FROM snapshots WHERE key = 'avisos' OR key LIKE 'faturas:%'"),
  ]);
  const faturas = {};
  let avisos = [];
  for (const s of snapshots.results) {
    if (s.key === "avisos") avisos = json(s.data) || [];
    else faturas[s.key.slice("faturas:".length)] = json(s.data);
  }
  return {
    agora: agoraIso,
    completo: janela === null,
    contas: contas.results,
    transacoes: transacoes.results,
    registros: registros.results.map((r) => ({ ...r, dados: json(r.dados) })),
    pendentes: pendentes.results.map((p) => p.id),
    config: Object.fromEntries(config.results.map((c) => [c.chave, c.valor])),
    faturas,
    avisos,
  };
}

// LWW no próprio SQL: só sobrescreve quando o updated_at recebido é estritamente maior.
// `WHERE true` desfaz a ambiguidade do parser do SQLite entre ON CONFLICT e a junção do SELECT.
const SQL_ENVIAR =
  "INSERT INTO registros (tabela, id, dados, updated_at, deleted_at, server_at) " +
  "SELECT json_extract(value, '$.tabela'), json_extract(value, '$.id'), json_extract(value, '$.dados'), json_extract(value, '$.updated_at'), json_extract(value, '$.deleted_at'), ?2 " +
  "FROM json_each(?1) WHERE true " +
  "ON CONFLICT(tabela, id) DO UPDATE SET dados = excluded.dados, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at, server_at = excluded.server_at " +
  "WHERE excluded.updated_at > registros.updated_at";

export async function enviar(db, corpo, agoraIso) {
  const lote = validarLote(corpo?.registros, agoraIso);
  if ("erro" in lote) return { status: 400, corpo: { erro: lote.erro } };
  if (lote.registros.length) await db.prepare(SQL_ENVIAR).bind(JSON.stringify(lote.registros), agoraIso).run();
  return { status: 200, corpo: { ok: true, aceitos: lote.registros.length, rejeitados: lote.rejeitados, agora: agoraIso } };
}

export function esperaAtualizar(ultimoIso, agoraMs) {
  return ultimoIso ? Math.max(0, Date.parse(ultimoIso) + INTERVALO_ATUALIZAR_MS - agoraMs) : 0;
}
```

Atenção: `json_extract(value, '$.dados')` devolve o objeto como texto JSON, e é isso que a coluna `dados` guarda.

Confira os nomes das colunas de `accounts`, `snapshots` e `config` no `schema.sql`. Se algum for diferente, ajuste os `SELECT`.

- [ ] **Passo 5: rotas em `apps/worker/src/index.js`**

1. Imports. Acrescente `import { autenticarAparelho, puxar, enviar } from "./sync.js";` e tire `tokenDoCabecalho` do import de `./app.js`.

2. No roteador, logo depois do `else if` de `/api/app/transacoes`, acrescente:

```js
      else if (ROTAS_APARELHO.has(caminho)) resp = await rotaAparelho(request, env, url, ctx, caminho);
```

   Essa rota fica fora do bloco que exige sessão, porque `rotaAparelho` autentica sozinha.

3. Na seção do App Android, apague `const USO_TOKEN_MS = ...` e acrescente o código abaixo antes de `listarTokens`:

```js
// Rotas dos apps: token de aparelho (Bearer) ou sessão do painel (cookie; POST exige mesma origem).
const ROTAS_APARELHO = new Set(["/api/sync"]);

async function rotaAparelho(request, env, url, ctx, caminho) {
  const ts = agora();
  const aparelho = await autenticarAparelho(request, env.DB, ts);
  if (!aparelho) {
    if (!(await sessaoValida(request, env))) return json({ erro: "Token ou sessão necessários" }, 401, { "www-authenticate": "Bearer" });
    if (request.method !== "GET" && !mesmaOrigem(request, url)) return json({ erro: "Origem não permitida" }, 403);
  }
  const rota = `${request.method} ${caminho}`;
  if (rota === "GET /api/sync") {
    const desde = normalizarDesde(url.searchParams.get("desde"));
    if (desde === undefined) return json({ erro: "Parâmetro desde inválido (use data ISO)" }, 400);
    return json(await puxar(env.DB, desde, ts));
  }
  if (rota === "POST /api/sync") {
    const r = await enviar(env.DB, await request.json().catch(() => null), ts);
    return json(r.corpo, r.status);
  }
  return json({ erro: "Método não permitido" }, 405);
}
```

4. `appTransacoes` passa a autenticar com `autenticarAparelho`. Tire o `UPDATE app_tokens` do batch e preserve as consultas e a resposta:

```js
  const agoraIso = agora();
  if (!(await autenticarAparelho(request, env.DB, agoraIso))) return json({ erro: "Token inválido" }, 401, { "www-authenticate": "Bearer" });
```

- [ ] **Passo 6: ver passar e conferir o bundle**

Rode: `pnpm test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: `# fail 0` no core e no worker.

Rode: `pnpm --filter @meu-banco/worker exec wrangler deploy --dry-run --outdir .wrangler/dry 2>&1 | tail -3 && grep -c "inicioDaJanela" apps/worker/.wrangler/dry/index.js`
Esperado: o build passa e a contagem é 1 ou mais. Isso prova que o esbuild embutiu o `.ts` do core.

- [ ] **Passo 7: commit**

```bash
git add apps/worker pnpm-lock.yaml
git commit -m "feat(worker): /api/sync com pull incremental e push last-write-wins

GET devolve contas, transações, faturas, avisos, config e registros
alterados desde o cursor (sobreposição de 2 min); POST valida no core e
grava com LWW no SQL. Aceita token de aparelho ou sessão do painel.
appTransacoes passa a usar autenticarAparelho.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 5: QR de pareamento ao criar o token

**Arquivos:**
- Modificar:
  - `apps/worker/package.json`, com a dependência `uqr`;
  - `apps/worker/src/index.js`, em `criarToken`;
  - `apps/worker/public/index.html`, no CSS perto da `.caixa` e na caixa do token (perto das linhas 644–646).
- Teste: `apps/worker/test/pareamento.test.mjs`

**Interfaces:**
- Consome: `criarAmbiente`, `entrarComSenha` e `ORIGEM`, da Tarefa 3.
- Produz: `POST /api/app/tokens`, que devolve `{ id, nome, token, link, qr }`:
  - `link` é `"meubanco://parear?u=" + encodeURIComponent(origin) + "&t=" + token`, e é ele que o app da Fase 2 lê;
  - `qr` é o SVG em texto.

- [ ] **Passo 1: dependência**

Rode: `pnpm --filter @meu-banco/worker add uqr@0.1.2 2>&1 | tail -2`

- [ ] **Passo 2: teste que falha**

`apps/worker/test/pareamento.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, entrarComSenha, ORIGEM } from "./ambiente.mjs";

test("criar token devolve link de pareamento e QR em SVG", async () => {
  const { pedir } = criarAmbiente();
  const cookie = await entrarComSenha(pedir);
  const r = await pedir("/api/app/tokens", { method: "POST", headers: { cookie, origin: ORIGEM, "content-type": "application/json" }, body: JSON.stringify({ nome: "Pixel" }) });
  assert.equal(r.status, 201);
  const j = await r.json();
  assert.match(j.token, /^mb_[\w-]{43}$/);
  assert.equal(j.link, `meubanco://parear?u=${encodeURIComponent(ORIGEM)}&t=${j.token}`);
  assert.match(j.qr, /^<svg[\s\S]*<\/svg>\s*$/);
});
```

- [ ] **Passo 3: ver falhar**

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: FAIL, porque `j.link` vem `undefined`.

- [ ] **Passo 4: Worker**

No topo de `index.js`, acrescente `import { renderSVG } from "uqr";`. Em `criarToken`, troque `return json({ id, nome: limpo, token }, 201);` por:

```js
  const link = `meubanco://parear?u=${encodeURIComponent(url.origin)}&t=${token}`;
  return json({ id, nome: limpo, token, link, qr: renderSVG(link, { border: 2 }) }, 201);
```

Se `criarToken` não recebe `url`, passe esse parâmetro pela chamada no roteador.

- [ ] **Passo 5: painel**

Em `public/index.html`, logo depois da regra `.caixa p { ... }`, acrescente o CSS abaixo. O fundo é branco fixo para o QR continuar legível no tema escuro.

```css
  .qr { background: #fff; padding: 8px; border-radius: 8px; width: 216px; margin: 0 auto 12px; }
  .qr svg { display: block; width: 200px; height: 200px; }
```

Troque o `caixa.replaceChildren(...)` do token por:

```js
      const qr = h("div", { class: "qr", role: "img", "aria-label": "QR para parear o app " + r.nome });
      qr.innerHTML = r.qr; // SVG gerado pelo próprio Worker
      caixa.replaceChildren(h("strong", {}, "Token de " + r.nome),
        h("p", { class: "sub" }, "Leia o QR no app ou copie o token. Não será mostrado de novo."), qr, campo, copiar);
```

Preserve os elementos `campo` e `copiar`, que já existem.

- [ ] **Passo 6: ver passar e conferir no painel**

Rode: `pnpm test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: `# fail 0`.

Verificação visual, conforme a skill `.claude/skills/verificar-meu-banco`:
1. Suba `pnpm dev` e entre no painel.
2. Crie um token em Aparelhos.
3. Tire prints claro e escuro com o QR visível e mostre no chat.
4. Leia o QR com um leitor, que deve devolver `meubanco://parear?...`.

- [ ] **Passo 7: commit**

```bash
git add apps/worker pnpm-lock.yaml
git commit -m "feat(worker): QR de pareamento ao criar token de aparelho

POST /api/app/tokens devolve link meubanco://parear e o QR em SVG (uqr);
o painel mostra o QR na caixa do token, com fundo branco para leitura.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 6: conexões do Pluggy no D1, connect token e registro de item

**Arquivos:**
- Criar: `apps/worker/src/pluggy.js`
- Modificar:
  - `apps/worker/src/api.js`: construtor, `obter`, e os novos `#autenticado`, `connectToken`, `atualizarItem` e `criarWebhook`;
  - `apps/worker/src/index.js`: `sincronizar`, `ROTAS_APARELHO` e `rotaAparelho`.
- Teste: `apps/worker/test/pluggy.test.mjs`

**Interfaces:**
- Consome:
  - da Tarefa 3: `criarAmbiente`, `criarAparelho`, `simularPluggy`, `restaurarFetch` e `criarD1`;
  - da Tarefa 4: `rotaAparelho`.
- Produz:
  - `new ApiCliente(env, ids?)`: os ids do D1 têm prioridade sobre `PLUGGY_ITEM_IDS`, e uma lista vazia cai no fallback atual;
  - `connectToken(itemId?)`, que devolve `Promise<string>`;
  - `atualizarItem(id)`;
  - `criarWebhook(url, secret)`, que devolve `Promise<{ id, criado }>`;
  - em `src/pluggy.js`:
    - `REGEX_ITEM` (UUID);
    - `idsConexoes(db, env, agoraIso)`, que devolve `Promise<string[]>`. Com `pluggy_items` vazia, copia os ids de `PLUGGY_ITEM_IDS`;
    - `registrarItem(db, id, agoraIso)` e `removerItem(db, id, agoraIso)`;
    - `atualizarStatus(db, item, agoraIso)`;
  - rotas, com Bearer ou sessão:
    - `POST /api/pluggy/connect-token`, com corpo `{ itemId? }`. Devolve `{ accessToken }`; um `itemId` fora do D1 responde 404;
    - `POST /api/pluggy/items`, com corpo `{ itemId }`. Devolve 201 e sincroniza em `waitUntil`.

- [ ] **Passo 1: teste que falha**

`apps/worker/test/pluggy.test.mjs`:

```js
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarD1 } from "./d1.mjs";
import { criarAmbiente, criarAparelho, simularPluggy, restaurarFetch } from "./ambiente.mjs";
import { idsConexoes, registrarItem, removerItem } from "../src/pluggy.js";
import { ApiCliente } from "../src/api.js";

afterEach(restaurarFetch);
const ID_A = "11111111-1111-4111-8111-111111111111";
const ID_B = "22222222-2222-4222-8222-222222222222";
const T = "2026-11-09T12:00:00.000Z";
const PLUGGY = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo" };

test("idsConexoes copia PLUGGY_ITEM_IDS uma vez e depois usa só o D1", async () => {
  const db = criarD1();
  assert.deepEqual(await idsConexoes(db, { PLUGGY_ITEM_IDS: ` ${ID_A} , ${ID_B} ` }, T), [ID_A, ID_B]);
  await removerItem(db, ID_B, T);
  assert.deepEqual(await idsConexoes(db, { PLUGGY_ITEM_IDS: `${ID_A},${ID_B}` }, T), [ID_A], "removido não volta pelo secret");
  await registrarItem(db, ID_B, T);
  assert.deepEqual((await idsConexoes(db, {}, T)).sort(), [ID_A, ID_B], "registrar de novo reativa");
});

test("ApiCliente usa os ids do D1 antes do secret", async () => {
  simularPluggy(() => ({}));
  assert.deepEqual(await new ApiCliente({ ...PLUGGY, PLUGGY_ITEM_IDS: "x" }, [ID_A]).listarIds(), [ID_A]);
  assert.deepEqual(await new ApiCliente({ ...PLUGGY, PLUGGY_ITEM_IDS: "x" }, []).listarIds(), ["x"]);
});

test("connect-token pede o accessToken ao Pluggy; itemId desconhecido é 404", async () => {
  const { env, pedir } = criarAmbiente(PLUGGY);
  const token = await criarAparelho(env);
  const { chamadas } = simularPluggy((u) => (u.pathname === "/connect_token" ? { accessToken: "ct-123" } : {}));
  const post = (corpo) => pedir("/api/pluggy/connect-token", { method: "POST", headers: { authorization: "Bearer " + token, "content-type": "application/json" }, body: JSON.stringify(corpo) });

  const r = await post({});
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { accessToken: "ct-123" });
  assert.deepEqual(chamadas.find((c) => c.caminho === "/connect_token").corpo, { options: { clientUserId: "meu-banco", avoidDuplicates: true } });

  assert.equal((await post({ itemId: "nao-e-uuid" })).status, 400);
  assert.equal((await post({ itemId: ID_A })).status, 404);
  await registrarItem(env.DB, ID_A, T);
  assert.equal((await post({ itemId: ID_A })).status, 200);
  assert.equal(chamadas.filter((c) => c.caminho === "/connect_token").at(-1).corpo.itemId, ID_A);
});

test("POST /api/pluggy/items registra o item e dispara a sincronização", async () => {
  const { env, pedir, esperar } = criarAmbiente(PLUGGY);
  const token = await criarAparelho(env);
  simularPluggy((u) => (u.pathname.startsWith("/items/") ? { id: ID_A, status: "UPDATED", connector: { name: "Inter" } } : { results: [] }));
  const post = (itemId) => pedir("/api/pluggy/items", { method: "POST", headers: { authorization: "Bearer " + token, "content-type": "application/json" }, body: JSON.stringify({ itemId }) });

  assert.equal((await post("nao-e-uuid")).status, 400);
  assert.equal((await post(ID_A)).status, 201);
  await esperar();
  assert.deepEqual(await env.DB.prepare("SELECT id, status, conector FROM pluggy_items").first(), { id: ID_A, status: "UPDATED", conector: "Inter" });
  assert.equal(await env.DB.prepare("SELECT origem FROM sync_log").first("origem"), "app");
});
```

- [ ] **Passo 2: ver falhar**

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: FAIL com `Cannot find module '../src/pluggy.js'`.

- [ ] **Passo 3: `apps/worker/src/pluggy.js`**

```js
// Conexões do Pluggy (items) guardadas no D1.
export const REGEX_ITEM = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Ids ativos. Com a tabela vazia (primeira vez), copia o secret PLUGGY_ITEM_IDS; depois o secret é ignorado.
export async function idsConexoes(db, env, agoraIso) {
  if (!(await db.prepare("SELECT count(*) AS n FROM pluggy_items").first("n"))) {
    for (const id of (env.PLUGGY_ITEM_IDS || "").split(",").map((s) => s.trim()).filter(Boolean)) await registrarItem(db, id, agoraIso);
  }
  const { results } = await db.prepare("SELECT id FROM pluggy_items WHERE removido IS NULL ORDER BY criado, id").all();
  return results.map((r) => r.id);
}

export function registrarItem(db, id, agoraIso) {
  return db.prepare("INSERT INTO pluggy_items (id, criado) VALUES (?1, ?2) ON CONFLICT(id) DO UPDATE SET removido = NULL").bind(id, agoraIso).run();
}

export function removerItem(db, id, agoraIso) {
  return db.prepare("UPDATE pluggy_items SET removido = ?2 WHERE id = ?1").bind(id, agoraIso).run();
}

export function atualizarStatus(db, item, agoraIso) {
  return db.prepare("UPDATE pluggy_items SET status = ?2, conector = ?3, atualizado = ?4 WHERE id = ?1")
    .bind(item.id, item.status ?? null, item.connector?.name ?? null, agoraIso).run();
}
```

- [ ] **Passo 4: `ApiCliente` (`apps/worker/src/api.js`)**

Leia o arquivo inteiro antes: os nomes privados atuais (`#autenticar`, `#pedir` e afins) mandam. Se forem diferentes, adapte os nomes abaixo.

Construtor, com a nova assinatura e a nova linha dos ids:

```js
  constructor(env, ids) {
    // ...demais campos como estão...
    this.itemIds = ids?.length ? ids : (env.PLUGGY_ITEM_IDS || "").split(",").map((s) => s.trim()).filter(Boolean);
```

Troque `obter` pelo método genérico abaixo e acrescente os novos:

```js
  // Requisição autenticada. Se a apiKey expirar no meio (401/403), autentica de novo uma vez.
  async #autenticado(metodo, caminho, { params, corpo } = {}) {
    const usada = this.#autenticar();
    const chave = await usada;
    try {
      return await this.#pedir(metodo, caminho, { params, corpo, chave });
    } catch (e) {
      if (e.status !== 401 && e.status !== 403) throw e;
      return this.#pedir(metodo, caminho, { params, corpo, chave: await this.#autenticar(usada) });
    }
  }

  obter(caminho, params) { return this.#autenticado("GET", caminho, { params }); }

  // Token temporário (30 min) do Pluggy Connect. Com itemId, o Connect abre em modo de atualização daquele item.
  async connectToken(itemId) {
    const corpo = { ...(itemId ? { itemId } : {}), options: { clientUserId: "meu-banco", avoidDuplicates: true } };
    const r = await this.#autenticado("POST", "/connect_token", { corpo });
    if (!r?.accessToken) throw new Error("POST /connect_token: resposta sem accessToken");
    return r.accessToken;
  }

  // Pede ao banco dados novos com as credenciais salvas; o fim chega pelo webhook (item/updated).
  atualizarItem(id) { return this.#autenticado("PATCH", `/items/${encodeURIComponent(id)}`, { corpo: {} }); }

  // Webhook único para todos os items (event "all"). Não duplica se já houver um para a mesma URL.
  async criarWebhook(url, secret) {
    const igual = ((await this.obter("/webhooks"))?.results || []).find((w) => w.url === url);
    if (igual) return { id: igual.id, criado: false };
    const r = await this.#autenticado("POST", "/webhooks", { corpo: { event: "all", url, headers: { "x-webhook-secret": secret } } });
    return { id: r?.id, criado: true };
  }
```

O `#pedir` precisa:
- aceitar `metodo` e `corpo`;
- mandar `content-type: application/json` com `JSON.stringify(corpo)` sempre que `corpo !== undefined`;
- lançar um erro com `e.status` e uma mensagem `HTTP <status>` quando a resposta não é ok.

Se o atual não fizer isso, estenda o método sem mudar o comportamento do GET.

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# fail"`
Esperado: os testes antigos de `api.test.mjs` continuam passando.

- [ ] **Passo 5: `sincronizar` lê do D1 (`apps/worker/src/index.js`)**

No topo, acrescente: `import { REGEX_ITEM, idsConexoes, registrarItem, atualizarStatus } from "./pluggy.js";`

Em `sincronizar`, troque `const api = new ApiCliente(env);` por:

```js
    const ts = agora();
    const api = new ApiCliente(env, await idsConexoes(db, env, ts));
```

Em seguida, apague a declaração `const ts = agora();` que aparece mais abaixo. Ela vira duplicada, e as linhas que usam `ts` continuam funcionando.

No laço, logo depois de `const [item, contas] = await Promise.all([...]);`, acrescente:

```js
        await atualizarStatus(db, { ...item, id }, ts);
```

- [ ] **Passo 6: rotas em `rotaAparelho`**

Troque a constante:

```js
const ROTAS_APARELHO = new Set(["/api/sync", "/api/pluggy/connect-token", "/api/pluggy/items"]);
```

Antes do `return json({ erro: "Método não permitido" }, 405);`, acrescente:

```js
  if (rota === "POST /api/pluggy/connect-token") {
    const itemId = (await request.json().catch(() => null))?.itemId ?? null;
    if (itemId !== null && !(typeof itemId === "string" && REGEX_ITEM.test(itemId))) return json({ erro: "itemId inválido" }, 400);
    if (itemId && !(await env.DB.prepare("SELECT 1 FROM pluggy_items WHERE id = ?1 AND removido IS NULL").bind(itemId).first())) {
      return json({ erro: "Conexão não encontrada" }, 404);
    }
    return json({ accessToken: await new ApiCliente(env).connectToken(itemId) });
  }
  if (rota === "POST /api/pluggy/items") {
    const itemId = (await request.json().catch(() => null))?.itemId;
    if (!(typeof itemId === "string" && REGEX_ITEM.test(itemId))) return json({ erro: "itemId inválido" }, 400);
    await registrarItem(env.DB, itemId, ts);
    ctx.waitUntil(sincronizar(env, "app").catch((e) => console.error("Sincronização após conectar", e?.stack || e)));
    return json({ ok: true }, 201);
  }
```

- [ ] **Passo 7: ver passar**

Rode: `pnpm test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: `# fail 0`.

- [ ] **Passo 8: commit**

```bash
git add apps/worker
git commit -m "feat(worker): conexões do Pluggy no D1 e connect token para o app

pluggy_items substitui PLUGGY_ITEM_IDS (copiado na primeira sincronização)
e guarda status e conector de cada item. Novas rotas connect-token
(Pluggy Connect, com modo de atualização) e items (registra e sincroniza).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 7: webhook do Pluggy

**Arquivos:**
- Modificar:
  - `apps/worker/src/pluggy.js`, com `acaoWebhook` e `webhookValido`;
  - `apps/worker/src/index.js`, com a rota pública, `webhookPluggy` e a rota de sessão `POST /api/pluggy/webhooks`.
- Teste: `apps/worker/test/webhook.test.mjs`

**Interfaces:**
- Consome:
  - `hashToken`, de `./app.js`;
  - da Tarefa 6: `registrarItem`, `removerItem` e `ApiCliente#criarWebhook`.
- Produz:
  - `acaoWebhook(ev)`, que devolve `"registrar" | "remover" | "sincronizar" | null`;
  - `webhookValido(request, url, env)`, que devolve `Promise<boolean>`. Lê o cabeçalho `x-webhook-secret` e, como reserva, a query `s`;
  - `POST /api/pluggy/webhook`, pública: com secret errado responde 401; com secret certo responde 200 na hora e trabalha em `waitUntil`;
  - `POST /api/pluggy/webhooks`, com sessão e mesma origem, que devolve `{ id, criado }`.

- [ ] **Passo 1: conferir a documentação do Pluggy**

Abra `https://docs.pluggy.ai/reference/webhooks-create` e `https://docs.pluggy.ai/docs/webhooks` e confirme três pontos:
1. `POST /webhooks` aceita `headers` (objeto).
2. Os nomes dos eventos de item.
3. O corpo do evento traz `event` e `itemId`.

Se `headers` **não** for aceito, troque o corpo em `criarWebhook` por `{ event: "all", url: url + "?s=" + encodeURIComponent(secret) }` (o `webhookValido` já aceita `?s=`) e ajuste o último teste. Registre a conclusão na mensagem de commit.

- [ ] **Passo 2: teste que falha**

`apps/worker/test/webhook.test.mjs`:

```js
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, entrarComSenha, simularPluggy, restaurarFetch, ORIGEM } from "./ambiente.mjs";
import { acaoWebhook } from "../src/pluggy.js";

afterEach(restaurarFetch);
const ID = "11111111-1111-4111-8111-111111111111";
const ENV = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo", PLUGGY_WEBHOOK_SECRET: "wh-secreto" };
const evento = (pedir, ev, headers = { "x-webhook-secret": "wh-secreto" }, qs = "") =>
  pedir("/api/pluggy/webhook" + qs, { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify(ev) });

test("acaoWebhook mapeia os eventos de item", () => {
  assert.equal(acaoWebhook({ event: "item/created", itemId: ID }), "registrar");
  assert.equal(acaoWebhook({ event: "item/deleted", itemId: ID }), "remover");
  for (const e of ["item/updated", "item/error", "item/waiting_user_input", "item/login_succeeded"]) assert.equal(acaoWebhook({ event: e, itemId: ID }), "sincronizar");
  assert.equal(acaoWebhook({ event: "connector/status_updated" }), null);
  assert.equal(acaoWebhook({ event: "item/updated", itemId: "x" }), null, "itemId inválido é ignorado");
  assert.equal(acaoWebhook(null), null);
});

test("webhook sem secret, com secret errado ou sem PLUGGY_WEBHOOK_SECRET é 401", async () => {
  const ev = { event: "item/updated", itemId: ID };
  assert.equal((await evento(criarAmbiente(ENV).pedir, ev, {})).status, 401);
  assert.equal((await evento(criarAmbiente(ENV).pedir, ev, { "x-webhook-secret": "errado" })).status, 401);
  assert.equal((await evento(criarAmbiente({}).pedir, ev, { "x-webhook-secret": "qualquer" })).status, 401);
});

test("item/created registra e sincroniza; item/deleted marca removido; secret na query também vale", async () => {
  const { env, pedir, esperar } = criarAmbiente(ENV);
  simularPluggy((u) => (u.pathname.startsWith("/items/") ? { id: ID, status: "UPDATED", connector: { name: "Santander" } } : { results: [] }));
  assert.equal((await evento(pedir, { event: "item/created", itemId: ID })).status, 200);
  await esperar();
  assert.equal(await env.DB.prepare("SELECT conector FROM pluggy_items WHERE id = ?1").bind(ID).first("conector"), "Santander");
  assert.equal(await env.DB.prepare("SELECT origem FROM sync_log").first("origem"), "webhook");

  assert.equal((await evento(pedir, { event: "item/deleted", itemId: ID }, {}, "?s=wh-secreto")).status, 200);
  await esperar();
  assert.ok(await env.DB.prepare("SELECT removido FROM pluggy_items WHERE id = ?1").bind(ID).first("removido"));
});

test("POST /api/pluggy/webhooks registra o webhook uma vez, com o secret no cabeçalho", async () => {
  const { pedir } = criarAmbiente(ENV);
  const cookie = await entrarComSenha(pedir);
  const lista = [];
  const { chamadas } = simularPluggy((u, init) => {
    if (u.pathname !== "/webhooks") return {};
    if ((init.method || "GET") === "GET") return { results: lista };
    lista.push({ id: "w1", url: JSON.parse(init.body).url });
    return { id: "w1" };
  });
  const registrar = () => pedir("/api/pluggy/webhooks", { method: "POST", headers: { cookie, origin: ORIGEM } });
  assert.deepEqual(await (await registrar()).json(), { id: "w1", criado: true });
  assert.deepEqual(await (await registrar()).json(), { id: "w1", criado: false });
  const post = chamadas.find((c) => c.metodo === "POST" && c.caminho === "/webhooks");
  assert.deepEqual(post.corpo, { event: "all", url: ORIGEM + "/api/pluggy/webhook", headers: { "x-webhook-secret": "wh-secreto" } });
});
```

- [ ] **Passo 3: ver falhar**

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: FAIL, porque `acaoWebhook` não é exportada.

- [ ] **Passo 4: `apps/worker/src/pluggy.js`**

Acrescente:

```js
import { hashToken } from "./app.js";

const SINCRONIZAR = new Set(["item/updated", "item/error", "item/waiting_user_input", "item/login_succeeded"]);

export function acaoWebhook(ev) {
  if (!ev || typeof ev.itemId !== "string" || !REGEX_ITEM.test(ev.itemId)) return null;
  if (ev.event === "item/created") return "registrar";
  if (ev.event === "item/deleted") return "remover";
  return SINCRONIZAR.has(ev.event) ? "sincronizar" : null;
}

// Compara os SHA-256 (mesmo tamanho), não as strings. Sem secret configurado, nada passa.
export async function webhookValido(request, url, env) {
  const esperado = env.PLUGGY_WEBHOOK_SECRET;
  const recebido = request.headers.get("x-webhook-secret") || url.searchParams.get("s");
  if (!esperado || !recebido) return false;
  return (await hashToken(recebido)) === (await hashToken(esperado));
}
```

- [ ] **Passo 5: rotas em `apps/worker/src/index.js`**

Acrescente `removerItem`, `acaoWebhook` e `webhookValido` ao import de `./pluggy.js`.

No roteador, logo depois do `/api/login`, coloque a rota pública. Ela fica antes da checagem de sessão:

```js
      else if (caminho === "/api/pluggy/webhook" && request.method === "POST") resp = await webhookPluggy(request, env, url, ctx);
```

Na parte com sessão, junto das outras rotas do painel:

```js
      else if (caminho === "/api/pluggy/webhooks" && request.method === "POST") {
        resp = mesmaOrigem(request, url)
          ? json(await new ApiCliente(env).criarWebhook(url.origin + "/api/pluggy/webhook", env.PLUGGY_WEBHOOK_SECRET || ""))
          : json({ erro: "Origem não permitida" }, 403);
      }
```

Depois de `rotaAparelho`:

```js
// Webhook do Pluggy: responde na hora (o Pluggy espera 2xx em poucos segundos) e trabalha em waitUntil.
// Se outra sincronização estiver rodando, a trava do sync_log descarta esta; o cron cobre o que faltar.
async function webhookPluggy(request, env, url, ctx) {
  if (!(await webhookValido(request, url, env))) return json({ erro: "Não autorizado" }, 401);
  const ev = await request.json().catch(() => null);
  const acao = acaoWebhook(ev);
  if (acao) {
    const ts = agora();
    const tarefa = acao === "remover"
      ? removerItem(env.DB, ev.itemId, ts)
      : (acao === "registrar" ? registrarItem(env.DB, ev.itemId, ts) : Promise.resolve()).then(() => sincronizar(env, "webhook"));
    ctx.waitUntil(tarefa.catch((e) => console.error("Webhook do Pluggy", ev.event, e?.stack || e)));
  }
  return json({ ok: true });
}
```

- [ ] **Passo 6: ver passar**

Rode: `pnpm test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: `# fail 0`.

- [ ] **Passo 7: commit**

```bash
git add apps/worker
git commit -m "feat(worker): webhook do Pluggy com secret no cabeçalho

POST /api/pluggy/webhook (público, valida PLUGGY_WEBHOOK_SECRET por hash)
registra, remove ou sincroniza conforme o evento do item. POST
/api/pluggy/webhooks registra o webhook no Pluggy sem duplicar.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 8: Atualizar com limite de 30 min e pedido ao banco

**Arquivos:**
- Modificar: `apps/worker/src/index.js`, na rota `/api/atualizar`, em `ROTAS_APARELHO`, em `rotaAparelho` e na nova função `atualizarAgora`.
- Teste: `apps/worker/test/atualizar.test.mjs`

**Interfaces:**
- Consome:
  - `esperaAtualizar`, da Tarefa 4;
  - `idsConexoes` e `ApiCliente#atualizarItem`, da Tarefa 6.
- Produz duas rotas: `POST /api/atualizar` (painel, com sessão) e `POST /api/sync/atualizar` (app, com Bearer ou sessão). As duas seguem as mesmas regras:
  - antes de 30 min do último Atualizar, respondem 429 com `{ ok: false, erro, mensagem, liberado_em }` e não chamam o Pluggy;
  - depois disso, fazem um `PATCH /items/{id}` por conexão e chamam `sincronizar`. A resposta traz o retorno do `sincronizar` mais `{ pedidos, falhas }`;
  - a origem no `sync_log` é `botao` para o painel e `app` para o app.

- [ ] **Passo 1: teste que falha**

`apps/worker/test/atualizar.test.mjs`:

```js
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { criarAmbiente, criarAparelho, entrarComSenha, simularPluggy, restaurarFetch, ORIGEM } from "./ambiente.mjs";
import { registrarItem } from "../src/pluggy.js";

afterEach(restaurarFetch);
const ID = "11111111-1111-4111-8111-111111111111";
const ENV = { PLUGGY_CLIENT_ID: "id", PLUGGY_CLIENT_SECRET: "segredo" };
const haMin = (m) => new Date(Date.now() - m * 60_000).toISOString();
const pluggyOk = (u, init) => (init.method === "PATCH" || u.pathname.startsWith("/items/") ? { id: ID, status: "UPDATING" } : { results: [] });

async function preparar(ultimo, rotas = pluggyOk) {
  const amb = criarAmbiente(ENV);
  await registrarItem(amb.env.DB, ID, haMin(100));
  if (ultimo) await amb.env.DB.prepare("INSERT INTO sync_log (origem, started_at, finished_at, ok) VALUES (?1, ?2, ?2, 1)").bind(ultimo.origem, haMin(ultimo.min)).run();
  const token = await criarAparelho(amb.env);
  const pelo_app = () => amb.pedir("/api/sync/atualizar", { method: "POST", headers: { authorization: "Bearer " + token } });
  return { ...amb, pelo_app, pluggy: simularPluggy(rotas) };
}

test("antes de 30 min: 429 com liberado_em e nenhuma chamada ao Pluggy", async () => {
  const { pedir, pluggy } = await preparar({ origem: "app", min: 10 });
  const cookie = await entrarComSenha(pedir);
  const r = await pedir("/api/atualizar", { method: "POST", headers: { cookie, origin: ORIGEM } });
  assert.equal(r.status, 429);
  const j = await r.json();
  assert.equal(j.ok, false);
  assert.match(j.mensagem, /Tente de novo às \d{2}:\d{2}/);
  assert.ok(Date.parse(j.liberado_em) > Date.now() + 19 * 60_000);
  assert.equal(pluggy.chamadas.length, 0);
});

test("cron e webhook não contam para o limite", async () => {
  const { pelo_app, pluggy } = await preparar({ origem: "cron", min: 5 });
  assert.notEqual((await pelo_app()).status, 429);
  assert.ok(pluggy.chamadas.some((c) => c.metodo === "PATCH" && c.caminho === `/items/${ID}`));
});

test("depois de 30 min: PATCH antes da leitura e origem app no sync_log", async () => {
  const { env, pelo_app, pluggy } = await preparar({ origem: "botao", min: 31 });
  const j = await (await pelo_app()).json();
  assert.equal(j.pedidos, 1);
  assert.deepEqual(j.falhas, []);
  const patch = pluggy.chamadas.findIndex((c) => c.metodo === "PATCH");
  const leitura = pluggy.chamadas.findIndex((c) => c.metodo === "GET" && c.caminho === `/items/${ID}`);
  assert.ok(patch >= 0 && patch < leitura, "PATCH antes da leitura");
  assert.equal(await env.DB.prepare("SELECT origem FROM sync_log ORDER BY id DESC").first("origem"), "app");
});

test("PATCH recusado vira falha e a leitura acontece mesmo assim", async () => {
  const recusa = (u, init) => (init.method === "PATCH" ? new Response(JSON.stringify({ message: "não permitido" }), { status: 403 }) : pluggyOk(u, init));
  const { pelo_app, pluggy } = await preparar(null, recusa);
  const j = await (await pelo_app()).json();
  assert.equal(j.pedidos, 0);
  assert.equal(j.falhas.length, 1);
  assert.match(j.falhas[0], /403/);
  assert.ok(pluggy.chamadas.some((c) => c.metodo === "GET" && c.caminho === `/items/${ID}`));
});
```

O 403 no PATCH passa pelo `#autenticado`, que reautentica uma vez e tenta de novo. Como o PATCH recusa de novo, o resultado continua sendo falha. É o comportamento esperado.

Confira as colunas de `sync_log` no `schema.sql`. Se o nome não for `origem` (ou outro dos campos do teste), ajuste o `INSERT`.

- [ ] **Passo 2: ver falhar**

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: FAIL. O primeiro teste recebe outro status em vez de 429.

- [ ] **Passo 3: `atualizarAgora` em `apps/worker/src/index.js`**

Acrescente `esperaAtualizar` ao import de `./sync.js`. Depois de `webhookPluggy`, acrescente o código abaixo. Use a constante de fuso que o arquivo já tem; se não houver, declare `const TZ = "America/Sao_Paulo";`.

```js
const horaSP = (ms) => new Intl.DateTimeFormat("pt-BR", { timeZone: TZ, hour: "2-digit", minute: "2-digit" }).format(new Date(ms));

// Botão Atualizar (painel e apps): no máximo 1 a cada 30 min. Pede ao banco dados novos (PATCH no item) e lê o que o
// Pluggy já tem; quando o banco terminar, o webhook item/updated faz a leitura final.
async function atualizarAgora(env, origem, ctx) {
  const db = env.DB;
  const ultimo = await db.prepare("SELECT MAX(started_at) AS t FROM sync_log WHERE origem IN ('botao', 'app')").first("t");
  const espera = esperaAtualizar(ultimo, Date.now());
  if (espera > 0) {
    const liberado = Date.now() + espera;
    const mensagem = `Atualizado há pouco. Tente de novo às ${horaSP(liberado)}.`;
    return json({ ok: false, erro: mensagem, mensagem, liberado_em: new Date(liberado).toISOString() }, 429);
  }
  const tarefa = (async () => {
    const ids = await idsConexoes(db, env, agora());
    const api = new ApiCliente(env, ids);
    const pedidos = await Promise.allSettled(ids.map((id) => api.atualizarItem(id)));
    const falhas = pedidos.flatMap((p, i) => (p.status === "rejected" ? [`Conexão ${ids[i]}: ${p.reason?.message || p.reason}`] : []));
    for (const f of falhas) console.warn("Atualizar no banco falhou", f);
    return { ...(await sincronizar(env, origem)), pedidos: ids.length - falhas.length, falhas };
  })();
  ctx.waitUntil(tarefa); // se o cliente fechar no meio, a sincronização termina e o sync_log é fechado
  return json(await tarefa);
}
```

Troque o corpo da rota `/api/atualizar` atual por:

```js
        resp = mesmaOrigem(request, url) ? await atualizarAgora(env, "botao", ctx) : json({ erro: "Origem não permitida" }, 403);
```

Antes, confira o que `sincronizar` devolve. Se o handler atual monta uma resposta diferente, por exemplo com status 409 quando a trava está ativa, preserve esse comportamento dentro de `atualizarAgora`.

Acrescente `"/api/sync/atualizar"` a `ROTAS_APARELHO`. Em `rotaAparelho`, antes do 405:

```js
  if (rota === "POST /api/sync/atualizar") return atualizarAgora(env, "app", ctx);
```

O painel já mostra `j.mensagem` quando `!r.ok`: confirme com `grep -n "mensagem" apps/worker/public/index.html`. Assim, o 429 aparece como "Atualizado há pouco. Tente de novo às HH:MM." sem mudar o front.

- [ ] **Passo 4: ver passar**

Rode: `pnpm test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: `# fail 0`.

- [ ] **Passo 5: commit**

```bash
git add apps/worker
git commit -m "feat(worker): Atualizar pede dados novos ao banco, no máximo a cada 30 min

Painel e app compartilham o limite (origens botao e app no sync_log); antes
disso respondem 429 com o horário liberado. Cada conexão recebe PATCH no
Pluggy; falha vira aviso e a leitura segue. O cron continua só lendo.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 9: backup diário do D1 no R2

**Arquivos:**
- Criar: `apps/worker/src/backup.js`
- Modificar: `apps/worker/src/index.js` (`scheduled`) e `apps/worker/wrangler.toml` (binding do R2)
- Teste: `apps/worker/test/backup.test.mjs`

**Interfaces:**
- Consome: `criarD1` e `criarAmbiente`, da Tarefa 3.
- Produz:
  - `exportarBanco(db)`, que devolve `Promise<{ gerado_em, tabelas: { [nome]: linhas[] } }>` com todas as tabelas, menos as que começam com `sqlite_`, `_cf_` e `d1_`;
  - `chaveBackup(data)`, que devolve `"d1/AAAA-MM-DD.json.gz"` com a data em UTC;
  - `salvarBackup(env, data)`, que grava em `env.BACKUP` e devolve a chave;
  - o cron das 06h UTC, que roda o backup depois da sincronização quando `env.BACKUP` existe.

- [ ] **Passo 1: teste que falha**

`apps/worker/test/backup.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { gunzipSync } from "node:zlib";
import { criarD1 } from "./d1.mjs";
import { criarAmbiente } from "./ambiente.mjs";
import { exportarBanco, chaveBackup, salvarBackup } from "../src/backup.js";

const r2 = () => { const objetos = new Map(); return { objetos, put: async (k, v, o) => { objetos.set(k, { v: new Uint8Array(v), o }); } }; };

test("exporta todas as tabelas do usuário, sem as internas", async () => {
  const db = criarD1();
  await db.prepare("CREATE TABLE _cf_KV (k)").run();
  await db.prepare("INSERT INTO config (chave, valor) VALUES ('limite','1500')").run();
  const b = await exportarBanco(db);
  assert.ok(b.gerado_em);
  assert.deepEqual(b.tabelas.config, [{ chave: "limite", valor: "1500" }]);
  for (const t of ["accounts", "transactions", "registros", "pluggy_items", "app_tokens"]) assert.ok(t in b.tabelas, t);
  assert.ok(!("_cf_KV" in b.tabelas));
  assert.ok(!Object.keys(b.tabelas).some((t) => t.startsWith("sqlite_")));
});

test("salvarBackup grava JSON gzip no R2 com a data na chave", async () => {
  const db = criarD1();
  await db.prepare("INSERT INTO config (chave, valor) VALUES ('salario','PAGTO SALARIO')").run();
  const BACKUP = r2();
  const chave = await salvarBackup({ DB: db, BACKUP }, new Date("2026-11-09T06:07:00Z"));
  assert.equal(chave, "d1/2026-11-09.json.gz");
  assert.equal(chaveBackup(new Date("2026-01-02T23:59:00Z")), "d1/2026-01-02.json.gz");
  const salvo = BACKUP.objetos.get(chave);
  assert.equal(salvo.o.httpMetadata.contentType, "application/json");
  assert.equal(salvo.o.httpMetadata.contentEncoding, "gzip");
  assert.deepEqual(JSON.parse(gunzipSync(salvo.v)).tabelas.config, [{ chave: "salario", valor: "PAGTO SALARIO" }]);
});

test("cron das 06h UTC faz o backup; nos outros horários não", async () => {
  for (const [hora, esperado] of [[6, 1], [9, 0]]) {
    const BACKUP = r2();
    const { env, ctx, worker, esperar } = criarAmbiente({ BACKUP });
    await worker.scheduled({ scheduledTime: Date.UTC(2026, 10, 9, hora, 7) }, env, ctx);
    await esperar();
    assert.equal(BACKUP.objetos.size, esperado, `hora ${hora}`);
  }
});
```

No teste do cron não há credenciais do Pluggy, então a sincronização falha e grava `ok=0` no `sync_log`. O backup precisa rodar mesmo assim.

- [ ] **Passo 2: ver falhar**

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: FAIL com `Cannot find module '../src/backup.js'`.

- [ ] **Passo 3: `apps/worker/src/backup.js`**

```js
// Backup diário do D1 inteiro em JSON gzip no R2. Retenção de 30 dias: regra de ciclo de vida do bucket (não é código).
export async function exportarBanco(db) {
  const { results } = await db.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' AND name NOT LIKE 'd1\\_%' ESCAPE '\\' ORDER BY name"
  ).all();
  const lidas = await db.batch(results.map(({ name }) => db.prepare(`SELECT * FROM "${name}"`)));
  return { gerado_em: new Date().toISOString(), tabelas: Object.fromEntries(results.map(({ name }, i) => [name, lidas[i].results])) };
}

export const chaveBackup = (data) => `d1/${data.toISOString().slice(0, 10)}.json.gz`;

export async function salvarBackup(env, data) {
  const texto = JSON.stringify(await exportarBanco(env.DB));
  const gz = await new Response(new Blob([texto]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer();
  const chave = chaveBackup(data);
  await env.BACKUP.put(chave, gz, { httpMetadata: { contentType: "application/json", contentEncoding: "gzip" } });
  return chave;
}
```

- [ ] **Passo 4: cron e `wrangler.toml`**

Em `index.js`, acrescente `import { salvarBackup } from "./backup.js";`. Depois troque o `ctx.waitUntil(...)` de `scheduled` por:

```js
    const t = new Date(evento.scheduledTime);
    const resumo = t.getUTCDay() === 1 && t.getUTCHours() === 0;
    const backup = t.getUTCHours() === 6 && env.BACKUP; // tick das 06h07 UTC = 03h07 BRT
    ctx.waitUntil(sincronizar(env, "cron").finally(async () => {
      if (resumo) await alertaSemanal(env).catch((e) => console.error("Resumo semanal falhou", e?.stack || e));
      if (backup) await salvarBackup(env, t).then((k) => console.log("Backup salvo", k), (e) => console.error("Backup falhou", e?.stack || e));
    }));
```

Preserve a regra atual do resumo semanal; o trecho acima mostra o padrão. Confira também se `wrangler.toml` tem um cron que dispara às 06h07 UTC (`grep -n crons apps/worker/wrangler.toml`). Se não tiver, acrescente `"7 6 * * *"` à lista.

Em `apps/worker/wrangler.toml`, logo depois do bloco `[[d1_databases]]`, acrescente:

```toml
[[r2_buckets]]
binding = "BACKUP"
bucket_name = "meu-banco-backups"
```

- [ ] **Passo 5: ver passar e conferir o build**

Rode: `pnpm test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: `# fail 0`.

Rode: `pnpm --filter @meu-banco/worker exec wrangler deploy --dry-run --outdir .wrangler/dry 2>&1 | grep -iE "BACKUP|error" | head`
Esperado: aparece `env.BACKUP (meu-banco-backups)` e nenhum erro.

- [ ] **Passo 6: commit**

```bash
git add apps/worker
git commit -m "feat(worker): backup diário do D1 em JSON gzip no R2

O tick das 06h07 UTC exporta todas as tabelas (menos as internas) para
d1/AAAA-MM-DD.json.gz no bucket meu-banco-backups. A retenção de 30 dias
fica numa regra de ciclo de vida do bucket.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 10: importação única do backup do Cashew

**Arquivos:**
- Criar: `apps/worker/scripts/cashew.mjs` e `apps/worker/scripts/importar-cashew.mjs`
- Modificar: `apps/worker/package.json`, com o script `importar:cashew`
- Teste: `apps/worker/test/cashew.test.mjs`

**Interfaces:**
- Consome: `criarD1` (Tarefa 3) e `validarLote` (`@meu-banco/core`).
- Produz:
  - `converterCashew({ categorias, orcamentos, objetivos, transacoes, carteiras }, agoraIso)`, que devolve `Registro[]` com ids `cashew:<pk>`;
  - `sqlImportacao(registros, agoraIso)`, que devolve o SQL com `INSERT OR IGNORE INTO registros`, em blocos de 200;
  - o comando `pnpm --filter @meu-banco/worker importar:cashew <backup.sql> > cashew-import.sql`.

**Mapeamento.** As colunas seguem o drift, em snake_case. O Passo 1 confere esses nomes no backup real.

| Cashew | Registro |
|---|---|
| `categories`: `category_pk, name, income, colour, icon_name, main_category_pk, order` | `categorias`: `{nome, tipo: income ? "receita" : "despesa", cor?, icone?, pai_id?: "cashew:"+main, ordem}` |
| `budgets`: `budget_pk, name, amount, category_fks (JSON), archived`. Os arquivados ficam de fora | `orcamentos`: `{nome, valor, categoria_ids, periodo: "mensal"}`. Quando `category_fks` é nulo, vira `[]` (todas as categorias) |
| `objectives` com `type 0` (meta): `objective_pk, name, amount, end_date` | `metas`: `{nome, valor_alvo, valor_atual: |Σ ligadas|, prazo?}` |
| `objectives` com `type 1` (empréstimo): `income` verdadeiro quando o Renan emprestou | `dividas`: `{tipo: "emprestimo", nome, sentido: income ? "me_devem" : "devo", valor_total, pago: |Σ ligadas|}` |
| `transactions`: `transaction_pk, name, amount, note, category_fk, wallet_fk, date_created (s), objective_fk`. As `mb:%` ficam de fora | `lancamentos`: `{data (SP), descricao: name ou "Sem descrição", valor, categoria_id?, carteira?, nota?}` |
| `wallets`: `wallet_pk, name` | o nome da carteira vai para `carteira` |

- [ ] **Passo 1: conferir o esquema real**

Peça ao Renan o arquivo exportado pelo Cashew (Configurações → Backup → Exportar). É um SQLite com extensão `.sql`. Ele não entra no repositório. Rode:

```bash
node -e "const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync(process.argv[1],{readOnly:true});for(const r of d.prepare(\"SELECT sql FROM sqlite_master WHERE name IN ('categories','budgets','objectives','transactions','wallets')\").all())console.log(r.sql)" "<caminho do backup>"
```

Compare a saída com a tabela de mapeamento:
- se algum nome divergir, ajuste o mapeamento e os `SELECT` do Passo 5 antes de seguir;
- se `date_created` tiver 13 dígitos (milissegundos), tire o `* 1000` de `dataSP`;
- se ainda não houver arquivo, siga com o mapeamento acima e marque este passo como pendente no relatório da tarefa.

- [ ] **Passo 2: teste que falha**

`apps/worker/test/cashew.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { validarLote } from "@meu-banco/core";
import { criarD1 } from "./d1.mjs";
import { converterCashew, sqlImportacao } from "../scripts/cashew.mjs";

const AGORA = "2026-11-09T12:00:00.000Z";
// 1762689600 = 09/11/2025 12:00 UTC (2025-11-09 em SP); 1798761600 = 01/01/2027 00:00 UTC (2026-12-31 em SP)
const dados = {
  categorias: [
    { category_pk: "1", name: "Mercado", income: 0, colour: "0xff4caf50", icon_name: "cart.png", main_category_pk: null, order: 2 },
    { category_pk: "2", name: "Hortifruti", income: 0, colour: null, icon_name: null, main_category_pk: "1", order: 0 },
    { category_pk: "3", name: "Salário", income: 1, colour: null, icon_name: null, main_category_pk: null, order: 1 },
  ],
  orcamentos: [
    { budget_pk: "b1", name: "Casa", amount: 900, category_fks: '["1","2"]', archived: 0 },
    { budget_pk: "b2", name: "Velho", amount: 100, category_fks: null, archived: 1 },
  ],
  objetivos: [
    { objective_pk: "o1", type: 0, name: "Viagem", amount: 5000, end_date: 1798761600, income: 0 },
    { objective_pk: "o2", type: 1, name: "João", amount: 300, end_date: null, income: 1 },
  ],
  transacoes: [
    { transaction_pk: "t1", name: "Feira", amount: -42.5, note: "", category_fk: "2", wallet_fk: "w1", date_created: 1762689600, objective_fk: null },
    { transaction_pk: "t2", name: "", amount: 200, note: "guardar", category_fk: null, wallet_fk: "w1", date_created: 1762689600, objective_fk: "o1" },
    { transaction_pk: "t3", name: "João pagou", amount: 100, note: null, category_fk: null, wallet_fk: null, date_created: 1762689600, objective_fk: "o2" },
    { transaction_pk: "mb:abc", name: "Do Meu Banco", amount: -10, note: null, category_fk: null, wallet_fk: "w1", date_created: 1762689600, objective_fk: null },
  ],
  carteiras: [{ wallet_pk: "w1", name: "Inter" }],
};

test("converte categorias, orçamentos, metas, empréstimos e lançamentos", () => {
  const regs = converterCashew(dados, AGORA);
  const por = (t, id) => regs.find((r) => r.tabela === t && r.id === id)?.dados;
  assert.deepEqual(por("categorias", "cashew:2"), { nome: "Hortifruti", tipo: "despesa", pai_id: "cashew:1", ordem: 0 });
  assert.equal(por("categorias", "cashew:3").tipo, "receita");
  assert.equal(por("categorias", "cashew:1").cor, "0xff4caf50");
  assert.deepEqual(por("orcamentos", "cashew:b1"), { nome: "Casa", valor: 900, categoria_ids: ["cashew:1", "cashew:2"], periodo: "mensal" });
  assert.equal(por("orcamentos", "cashew:b2"), undefined, "arquivado fica de fora");
  assert.deepEqual(por("metas", "cashew:o1"), { nome: "Viagem", valor_alvo: 5000, valor_atual: 200, prazo: "2026-12-31" });
  assert.deepEqual(por("dividas", "cashew:o2"), { tipo: "emprestimo", nome: "João", sentido: "me_devem", valor_total: 300, pago: 100 });
  assert.deepEqual(por("lancamentos", "cashew:t1"), { data: "2025-11-09", descricao: "Feira", valor: -42.5, categoria_id: "cashew:2", carteira: "Inter" });
  assert.deepEqual(por("lancamentos", "cashew:t2"), { data: "2025-11-09", descricao: "Sem descrição", valor: 200, carteira: "Inter", nota: "guardar" });
  assert.equal(regs.some((r) => r.id === "cashew:mb:abc"), false, "transação vinda do Meu Banco fica de fora");
  assert.equal(regs.length, 9); // 3 categorias + 1 orçamento + 1 meta + 1 dívida + 3 lançamentos
});

test("tudo o que sai passa na validação do core", () => {
  const r = validarLote(converterCashew(dados, AGORA), AGORA);
  assert.ok("registros" in r);
  assert.deepEqual(r.rejeitados, []);
});

test("SQL gerado roda no D1 e rodar de novo não duplica nem sobrescreve", async () => {
  const db = criarD1();
  const sql = sqlImportacao(converterCashew(dados, AGORA), AGORA);
  await db.exec(sql);
  await db.prepare("UPDATE registros SET dados = '{\"nome\":\"Editado\",\"tipo\":\"despesa\"}' WHERE id = 'cashew:1'").run();
  await db.exec(sql);
  assert.equal(await db.prepare("SELECT count(*) AS n FROM registros").first("n"), 9);
  assert.equal(JSON.parse(await db.prepare("SELECT dados FROM registros WHERE id = 'cashew:1'").first("dados")).nome, "Editado");
});
```

- [ ] **Passo 3: ver falhar**

Rode: `pnpm --filter @meu-banco/worker test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: FAIL com `Cannot find module '../scripts/cashew.mjs'`.

- [ ] **Passo 4: `apps/worker/scripts/cashew.mjs`**

```js
// Conversão do backup do Cashew (drift/SQLite) para registros do Meu Banco. Funções puras; o CLI está em importar-cashew.mjs.
const TZ = "America/Sao_Paulo";
const id = (pk) => "cashew:" + pk;
const dataSP = (segundos) => new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(new Date(segundos * 1000));
const sem = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v != null && v !== "")); // tira opcionais vazios (0 fica)
const lista = (texto) => { try { const v = JSON.parse(texto ?? "[]"); return Array.isArray(v) ? v.map(String) : []; } catch { return []; } };

export function converterCashew({ categorias, orcamentos, objetivos, transacoes, carteiras }, agoraIso) {
  const reg = (tabela, pk, dados) => ({ tabela, id: id(pk), dados, updated_at: agoraIso, deleted_at: null });
  const carteira = new Map(carteiras.map((w) => [String(w.wallet_pk), w.name]));
  const proprias = transacoes.filter((t) => !String(t.transaction_pk).startsWith("mb:"));
  const soma = new Map();
  for (const t of proprias) if (t.objective_fk != null) soma.set(String(t.objective_fk), (soma.get(String(t.objective_fk)) || 0) + Number(t.amount));
  const progresso = (pk) => Math.round(Math.abs(soma.get(String(pk)) || 0) * 100) / 100;

  return [
    ...categorias.map((c) => reg("categorias", c.category_pk, sem({
      nome: c.name, tipo: c.income ? "receita" : "despesa", cor: c.colour, icone: c.icon_name,
      pai_id: c.main_category_pk != null ? id(c.main_category_pk) : null, ordem: Number(c.order ?? 0),
    }))),
    ...orcamentos.filter((b) => !b.archived).map((b) => reg("orcamentos", b.budget_pk, {
      nome: b.name, valor: Number(b.amount), categoria_ids: lista(b.category_fks).map(id), periodo: "mensal",
    })),
    ...objetivos.map((o) => Number(o.type) === 1
      ? reg("dividas", o.objective_pk, { tipo: "emprestimo", nome: o.name, sentido: o.income ? "me_devem" : "devo", valor_total: Number(o.amount), pago: progresso(o.objective_pk) })
      : reg("metas", o.objective_pk, sem({ nome: o.name, valor_alvo: Number(o.amount), valor_atual: progresso(o.objective_pk), prazo: o.end_date != null ? dataSP(Number(o.end_date)) : null }))),
    ...proprias.map((t) => reg("lancamentos", t.transaction_pk, sem({
      data: dataSP(Number(t.date_created)), descricao: t.name?.trim() || "Sem descrição", valor: Number(t.amount),
      categoria_id: t.category_fk != null ? id(t.category_fk) : null, carteira: carteira.get(String(t.wallet_fk)), nota: t.note?.trim(),
    }))),
  ];
}

const texto = (v) => (v == null ? "NULL" : "'" + String(v).replace(/'/g, "''") + "'");

// INSERT OR IGNORE: rodar de novo não duplica nem sobrescreve o que já foi editado no app.
export function sqlImportacao(registros, agoraIso) {
  const linhas = registros.map((r) => `(${texto(r.tabela)}, ${texto(r.id)}, ${texto(JSON.stringify(r.dados))}, ${texto(r.updated_at)}, NULL, ${texto(agoraIso)})`);
  const blocos = [];
  for (let i = 0; i < linhas.length; i += 200) {
    blocos.push(`INSERT OR IGNORE INTO registros (tabela, id, dados, updated_at, deleted_at, server_at) VALUES\n${linhas.slice(i, i + 200).join(",\n")};`);
  }
  return blocos.join("\n") + "\n";
}
```

- [ ] **Passo 5: CLI `apps/worker/scripts/importar-cashew.mjs`**

```js
// Uso: pnpm --filter @meu-banco/worker importar:cashew <backup-do-cashew.sql> > cashew-import.sql
// Lê o backup (SQLite, só leitura) e imprime o SQL para `wrangler d1 execute meu-banco --remote --file=cashew-import.sql`.
import { DatabaseSync } from "node:sqlite";
import { validarLote, MAX_LOTE } from "@meu-banco/core";
import { converterCashew, sqlImportacao } from "./cashew.mjs";

const caminho = process.argv[2];
if (!caminho) { console.error("Informe o caminho do backup do Cashew."); process.exit(1); }
const db = new DatabaseSync(caminho, { readOnly: true });
const ler = (sql) => db.prepare(sql).all().map((r) => ({ ...r }));
const agora = new Date().toISOString();

const registros = converterCashew({
  categorias: ler('SELECT category_pk, name, income, colour, icon_name, main_category_pk, "order" FROM categories'),
  orcamentos: ler("SELECT budget_pk, name, amount, category_fks, archived FROM budgets"),
  objetivos: ler("SELECT objective_pk, type, name, amount, end_date, income FROM objectives"),
  transacoes: ler("SELECT transaction_pk, name, amount, note, category_fk, wallet_fk, date_created, objective_fk FROM transactions"),
  carteiras: ler("SELECT wallet_pk, name FROM wallets"),
}, agora);

// Valida em blocos do tamanho máximo do lote; o que o core rejeitar fica de fora e é listado no stderr.
const rejeitados = new Map();
for (let i = 0; i < registros.length; i += MAX_LOTE) {
  const lote = validarLote(registros.slice(i, i + MAX_LOTE), agora);
  if ("registros" in lote) for (const r of lote.rejeitados) rejeitados.set(r.indice + i, r.motivo);
}
for (const [i, motivo] of rejeitados) console.error(`Ignorado ${registros[i].tabela} ${registros[i].id}: ${motivo}`);
const validos = registros.filter((_, i) => !rejeitados.has(i));
process.stdout.write(sqlImportacao(validos, agora));
const porTabela = Object.entries(Object.groupBy(validos, (r) => r.tabela)).map(([t, l]) => `${t}: ${l.length}`).join(", ");
console.error(`${validos.length} registros (${porTabela}); ${rejeitados.size} ignorados.`);
```

Em `apps/worker/package.json`, acrescente aos scripts: `"importar:cashew": "node scripts/importar-cashew.mjs"`.

- [ ] **Passo 6: ver passar e fazer o teste de fumaça**

Rode: `pnpm test 2>&1 | grep -E "^not ok|# (pass|fail)"`
Esperado: `# fail 0`.

O teste de fumaça só roda se o Renan já tiver entregado o backup no Passo 1:

```bash
pnpm --filter @meu-banco/worker importar:cashew "<caminho do backup>" > "$TMPDIR/cashew-import.sql"
pnpm db:local && pnpm --filter @meu-banco/worker exec wrangler d1 execute meu-banco --local --file="$TMPDIR/cashew-import.sql"
```

Esperado:
- o stderr termina com `N registros (...); 0 ignorados.`;
- o D1 local aceita o SQL.

- [ ] **Passo 7: commit**

```bash
git add apps/worker
git commit -m "feat(worker): importação única do backup do Cashew para registros

converterCashew mapeia categorias, orçamentos ativos, metas, empréstimos e
lançamentos manuais (ids cashew:*, pula os mb:* vindos do Meu Banco) e
gera INSERT OR IGNORE; rodar de novo não duplica nem sobrescreve.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Tarefa 11: qualidade, verificação e documentação

**Arquivos:**
- Modificar:
  - `.claude/skills/verificar-meu-banco/SKILL.md`, para cobrir sync, QR, Atualizar e backup;
  - `README.md`, nas seções sobre Pluggy, sincronização com os apps e backup.

- [ ] **Passo 1: qualidade antes do PR**

Rode a skill `qualidade-antes-do-pr` sobre o diff da fase:
- 2 a 3 passadas de `/simplify` e `karpathy-coder`;
- `workers-best-practices` para o Worker. O core em TS puro não tem skill de framework; registre isso;
- `/code-review high --fix`.

- [ ] **Passo 2: provar de novo**

Rode: `pnpm test 2>&1 | grep -E "^not ok|# (pass|fail)" && pnpm --filter @meu-banco/core typecheck && pnpm --filter @meu-banco/worker exec wrangler deploy --dry-run --outdir .wrangler/dry 2>&1 | tail -2`

Esperado:
- `# fail 0` nos dois pacotes;
- o typecheck sem saída;
- o build sem erro.

- [ ] **Passo 3: ponta a ponta local**

Com `pnpm db:local`, `pnpm mock` e `pnpm dev` rodando, conforme a skill `verificar-meu-banco`:

1. Entre no painel e crie um token em Aparelhos. O QR aparece; copie o token para `$TOKEN` sem mostrá-lo no chat.
2. Pull: `curl -s -H "authorization: Bearer $TOKEN" localhost:8787/api/sync | head -c 300`. Deve vir um JSON com `agora`, `contas` e `registros`.
3. Push:
   ```bash
   curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
     -d '{"registros":[{"tabela":"categorias","id":"teste","dados":{"nome":"Teste","tipo":"despesa"},"updated_at":"2026-11-09T12:00:00Z","deleted_at":null}]}' \
     localhost:8787/api/sync
   ```
   Deve vir `{"ok":true,"aceitos":1,...}`.
4. Clique em Atualizar duas vezes no painel. A segunda mostra "Atualizado há pouco. Tente de novo às HH:MM."
5. Confirme que o painel continua mostrando ciclo, limite, transações e ajustes de categoria, sem regressão. Mostre os prints no chat.

Atualize a skill `verificar-meu-banco` com estes comandos, via `verificacao-manter`.

- [ ] **Passo 4: commit**

```bash
git add README.md .claude/skills/verificar-meu-banco/SKILL.md
git commit -m "docs: sincronização, webhook do Pluggy e backup no README e na verificação

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Passo final: comandos que o Renan roda no remoto

Nada acima mexe no D1, no R2 ou nos secrets remotos. Depois do merge, rode na raiz do checkout principal (`~/dev/meu-banco`), nesta ordem:

```bash
# 0. O checkout principal tem .dev.vars e .wrangler/ na raiz: mova para o Worker
mv .dev.vars apps/worker/ 2>/dev/null; mv .wrangler apps/worker/ 2>/dev/null; pnpm install

# 1. Backup antes de mexer no D1
pnpm --filter @meu-banco/worker exec wrangler d1 export meu-banco --remote --output ~/dev/backups/meu-banco-$(date +%F-%H%M).sql

# 2. Bucket do backup e retenção de 30 dias (confira a sintaxe com --help antes)
pnpm --filter @meu-banco/worker exec wrangler r2 bucket create meu-banco-backups
pnpm --filter @meu-banco/worker exec wrangler r2 bucket lifecycle add --help
pnpm --filter @meu-banco/worker exec wrangler r2 bucket lifecycle add meu-banco-backups expirar-30d d1/ --expire-days 30

# 3. Schema novo (registros, pluggy_items, v_ajustes) e depois a migração única dos ajustes
pnpm db:remote
pnpm --filter @meu-banco/worker exec wrangler d1 execute meu-banco --remote --file=scripts/migrar-ajustes.sql

# 4. Secret do webhook (gerado na hora, não aparece no terminal)
openssl rand -base64 32 | tr -d '\n' | pnpm --filter @meu-banco/worker exec wrangler secret put PLUGGY_WEBHOOK_SECRET

# 5. Publicar (a versão sobe para v0.0.8)
pnpm push

# 6. Registrar o webhook no Pluggy: no painel logado, no console do navegador
#    await (await fetch("/api/pluggy/webhooks", { method: "POST" })).json()   → { id, criado: true }

# 7. Quando houver o backup do Cashew, importar uma vez
pnpm --filter @meu-banco/worker importar:cashew ~/Downloads/<backup-do-cashew>.sql > ~/dev/backups/cashew-import.sql
pnpm --filter @meu-banco/worker exec wrangler d1 execute meu-banco --remote --file=$HOME/dev/backups/cashew-import.sql
```

**Validação depois da publicação:**
1. No painel, a versão é v0.0.8 e os ajustes de categoria antigos continuam aparecendo.
2. O primeiro Atualizar sincroniza; o segundo mostra o horário em que volta a ficar liberado.
3. Depois de um Atualizar, `pnpm logs` mostra o webhook `item/updated` chegando.
4. No dia seguinte, depois das 03h07 BRT, o arquivo `d1/<data>.json.gz` aparece no bucket. Para conferir: `wrangler r2 object get meu-banco-backups/d1/<data>.json.gz --remote --file /dev/null`.
5. Com `pluggy_items` preenchida, o secret `PLUGGY_ITEM_IDS` pode ser apagado. Isso fica para a Fase 4. Para conferir a tabela: `wrangler d1 execute meu-banco --remote --command "SELECT id, status FROM pluggy_items"`.
