---
name: verificar-meu-banco
description: Verifica o Meu Banco localmente (Worker + D1 + mock da API do MCP.AI) depois de mexer em src/, public/ ou mock/. Use antes de commit/PR ou quando pedirem "testa o sync", "valida o painel".
---

# Verificar Meu Banco (local, sem chave real)

1. `pnpm install` · `cp .dev.vars.example .dev.vars` (se faltar) · `rm -rf .wrangler && pnpm db:local`
2. Em segundo plano: `node mock/api-mock.mjs` (porta 8788) e `pnpm dev` (porta 8787). Espere `curl localhost:8787` responder.
3. Checagens (senha local `teste123`, `A="-u x:teste123"`):
   - `curl -o /dev/null -w %{http_code} localhost:8787/` → **401**
   - `curl $A -X POST -H 'Origin: https://mal.com' localhost:8787/api/atualizar` → **403**
   - `curl $A -X POST localhost:8787/api/atualizar` duas vezes → `{"ok":true,"mensagem":"OK"}` nas duas
   - `pnpm exec wrangler d1 execute meu-banco --local --json --command "SELECT account_id, COUNT(*) n, SUM(scheduled) fut FROM transactions GROUP BY 1"` → cartão **64 (3 futuras)**, conta **37**; os números não podem subir na 2ª execução (sem duplicar)
   - `curl $A localhost:8787/api/ferramentas` → conexão "Banco Inter" + lista de endpoints
   - `curl -w %{http_code} localhost:8787/__scheduled` → **200**
4. Reconexão: reinicie o mock com `MOCK_RECONNECT=1`, rode `/api/atualizar` e confira em `/api/dados` → `snapshots.avisos` com **1** item e `reconnect_url` https.
5. Build: `pnpm exec wrangler deploy --dry-run` sem erro.
6. Painel (se mexeu em `public/`): print com Playwright em 1280px e 390px (tema escuro), sem erro de console e sem rolagem horizontal.
7. Pare os dois processos (`ps -eo pid,args` + `kill`; não use `pkill -f`, que mata o próprio shell) e confirme 8787/8788 livres.
