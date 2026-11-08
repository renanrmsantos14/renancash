# Meu Banco

Painel pessoal com saldo, cartão, faturas e transações do Banco Inter, lidos da API REST do **Banco MCP** do MCP.AI (Open Finance Brasil).
Usa a REST (e não o protocolo MCP) porque o MCP só aceita login OAuth, que não funciona num robô rodando sozinho; a REST aceita uma API key fixa e expõe as mesmas ferramentas.
Roda 100% no plano gratuito da Cloudflare: Workers + Workers Assets + D1 + Cron Triggers. Não usa IA.

```
public/index.html   painel (HTML + JS puro, tema claro/escuro automático)
src/index.js        Worker: senha, API do painel, sincronização (cron e botão)
src/api.js          cliente da API REST do MCP.AI (com paginação e nova tentativa no 429)
schema.sql          tabelas do D1
mock/api-mock.mjs   API falsa (mesmo formato da real) para teste local
scripts/versao.mjs  incrementa a versão mostrada no canto do painel a cada deploy
```

## 1. Preparar o PC (uma vez)

1. Instale o **Node.js LTS** em https://nodejs.org (aceite as opções padrão). Feche e abra o terminal.
2. Confira: `node -v` (precisa ser 18 ou maior).
3. Ative o pnpm: `corepack enable` (ou `npm install -g pnpm`).
4. Na pasta do projeto: `pnpm install`.

## 2. Testar localmente com o mock (opcional, recomendado)

```powershell
copy .dev.vars.example .dev.vars        # Linux/macOS: cp .dev.vars.example .dev.vars
pnpm db:local                        # cria as tabelas no banco local
```

Terminal 1: `pnpm mock` · Terminal 2: `pnpm dev`

Abra http://localhost:8787 → usuário qualquer, senha `teste123` → clique **Atualizar**.
Para testar o cron: abra http://localhost:8787/__scheduled no navegador.
Para simular o banco pedindo novo login: pare o mock e rode `set MOCK_RECONNECT=1` (PowerShell: `$env:MOCK_RECONNECT=1`) antes de `pnpm mock`.

## 3. Pegar a API key no MCP.AI

1. Entre em https://app.mcp.ai e confirme que o **Banco MCP** está ligado e o Banco Inter conectado (status "UPDATED").
2. Vá em **Settings → API keys** (endereço direto: https://app.mcp.ai/settings/api-keys) e crie uma API key do workspace. Ela começa com `sk_live_…`. Copie na hora: normalmente ela só aparece uma vez.
3. Não use a "URL do servidor MCP" (`https://api.mcp.ai/banco?tools=true`): ela é para Claude/ChatGPT/Cursor e pede login OAuth.

O que o app usa (já configurado no `wrangler.toml`):

| Item | Valor |
|---|---|
| URL base | `https://api.mcp.ai/api/openfinance` (var `API_URL`) |
| Autenticação | `Authorization: Bearer sk_live_…` (secret `MCP_API_KEY`) |
| Endpoints | `connections/list`, `connections/sync`, `accounts/list`, `transactions/list`, `credit-card-bills/list` |

Lista pública e oficial dos endpoints: https://api.mcp.ai/api/openfinance/_endpoints

Custo: cada atualização faz cerca de 6 a 10 chamadas (2 por conta). Com o cron de 3 em 3 horas são ~60 por dia. Se o seu plano no MCP.AI cobrar por chamada, mude o cron no `wrangler.toml` (ex.: `"7 */6 * * *"` = 6 em 6 horas).

## 4. Publicar na Cloudflare

```powershell
npx wrangler login                       # abre o navegador; autorize a conta nova
npx wrangler d1 create meu-banco         # copie o "database_id" mostrado
```

Edite o `wrangler.toml` e cole o `database_id`.

```powershell
pnpm db:remote                        # cria as tabelas no D1 da nuvem (--remote)
npx wrangler secret put MCP_API_KEY      # cole a sk_live_… do MCP.AI (não aparece na tela)
npx wrangler secret put APP_PASSWORD     # senha do painel: use 16+ caracteres
pnpm push                             # incrementa a versão e publica
```

O deploy mostra o endereço, algo como `https://meu-banco.SEU-USUARIO.workers.dev`.
Na primeira vez a Cloudflare pede para escolher o subdomínio `workers.dev`.

## 5. Primeiro acesso

1. Abra `https://meu-banco.SEU-USUARIO.workers.dev/api/ferramentas` → usuário qualquer + `APP_PASSWORD`. Deve mostrar suas conexões (Banco Inter) e a lista de endpoints. Se der erro aqui, o problema é a API key.
2. Abra a raiz do site e clique **Atualizar**. A primeira carga busca 180 dias (`IMPORT_DAYS`) e pode levar até alguns minutos por causa do `force_sync`.
3. Daí em diante o cron atualiza sozinho a cada 3 horas (minuto 7 das horas 0, 3, 6… UTC = 21h, 0h, 3h… em Brasília).
4. No celular: abra o endereço e use "Adicionar à tela inicial".

Opcional, camada extra: Cloudflare Zero Trust → Access → Applications → adicione o domínio `meu-banco.SEU-USUARIO.workers.dev` com política "e-mail = o seu" (gratuito até 50 usuários). A senha do Worker continua valendo.

## Se der erro

A mensagem de erro aparece no painel (faixa vermelha) e no `/api/ferramentas`.

- **401 unauthorized**: API key errada. Refaça `npx wrangler secret put MCP_API_KEY` (não precisa novo deploy).
- **403 forbidden / key_scope_mismatch**: a key é de outro workspace ou não tem acesso ao Banco MCP. Crie a key no mesmo workspace onde o banco está conectado.
- **402 insufficient_credits**: acabaram os créditos/plano do MCP.AI. Recarregue ou diminua a frequência do cron.
- **409 not_connected**: o banco não está conectado no MCP.AI. Conecte em app.mcp.ai.
- **404 / endpoint errado**: confira se `API_URL` é `https://api.mcp.ai/api/openfinance` e compare os nomes em https://api.mcp.ai/api/openfinance/_endpoints. Os caminhos ficam nas chamadas `api.chamar("…")` em `src/index.js`.
- **429**: limite de 2 requisições/s; o app já espera e tenta de novo.
- **Aviso amarelo "faça login novamente"**: o Inter expirou o consentimento do Open Finance. Clique em **Reconectar o banco** (ou reconecte em app.mcp.ai), refaça o login no app do banco e clique **Atualizar**.
- **"Já existe uma atualização em andamento"**: espere até 10 minutos; o bloqueio expira sozinho.
- **"Exceeded CPU" / "Too many subrequests"** nos logs: reduza `IMPORT_DAYS` (ex.: `"90"`), faça deploy, clique Atualizar e depois volte para 180 se quiser.
- **"no such table"**: faltou `pnpm db:remote`.
- **"mais de 10 páginas de transações"**: reduza `IMPORT_DAYS`.
- **Ver logs ao vivo**: `pnpm logs` (`wrangler tail`) e clique Atualizar. Também no painel Cloudflare → Workers → meu-banco → Logs. O histórico de execuções fica na tabela `sync_log`:
  `npx wrangler d1 execute meu-banco --remote --command "SELECT * FROM sync_log ORDER BY id DESC LIMIT 5"`

## Segurança

- A API key do MCP.AI só existe como secret no Worker; o navegador nunca a recebe e ela não está em nenhum arquivo do projeto. `.dev.vars` está no `.gitignore`.
- Todas as rotas, inclusive o HTML, passam pela senha (`run_worker_first = true`). Comparação em tempo constante.
- Dados do banco são exibidos só com `textContent` (sem `innerHTML`), com CSP restrita e `no-store`.

## Regras do painel

- Gastos por categoria = débitos da conta corrente + compras do cartão no mês, **sem** pagamento de fatura, investimentos/poupança/"porquinho", transferência entre contas próprias e parcelas futuras.
- Valores das faturas vêm do `totalAmount` do banco (não da soma das transações).
- Parcelas futuras e transações pendentes são apagadas e regravadas a cada sincronização, para não duplicar.
