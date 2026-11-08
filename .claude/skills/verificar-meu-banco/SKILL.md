---
name: verificar-meu-banco
description: Verifica o Meu Banco localmente (Worker + D1 + mock da API do MCP.AI) depois de mexer em src/, public/ ou mock/. Use antes de commit/PR ou quando pedirem "testa o sync", "valida o painel".
---

# Verificar Meu Banco (local, sem chave real)

1. `pnpm install` · `cp .dev.vars.example .dev.vars` (se faltar) · `rm -rf .wrangler && pnpm db:local`
2. Em segundo plano: `node mock/api-mock.mjs` (porta 8788) e `pnpm dev` (porta 8787). Espere `curl localhost:8787` responder.
3. Login: `curl -c cj.txt -X POST -H "content-type: application/json" -d '{"senha":"teste123"}' localhost:8787/api/login` e use `A="-b cj.txt"` nas checagens abaixo. Antes: `/` sem cookie → **302 /login**, `/api/dados` sem cookie → **401**, senha errada → **401** (~1 s), `/login`, `/manifest.webmanifest`, `/sw.js`, `/icons/icon-192.png` → **200**. Limite: 6 senhas erradas seguidas → as primeiras 401 e depois **429** (5 por minuto por IP; faça este teste por último ou espere 1 min). `.dev.vars` precisa de `SESSION_SECRET` (sem ele tudo dá 500).
3b. Checagens:
   - `curl $A -X POST -H 'Origin: https://mal.com' localhost:8787/api/atualizar` → **403**
   - `curl $A -X POST localhost:8787/api/atualizar` duas vezes → `{"ok":true,"mensagem":"OK"}` nas duas
   - `pnpm exec wrangler d1 execute meu-banco --local --json --command "SELECT account_id, COUNT(*) n, SUM(scheduled) fut FROM transactions GROUP BY 1"` → cartão **64 (3 futuras)**, conta **37**; os números não podem subir na 2ª execução (sem duplicar)
   - `curl $A localhost:8787/api/ferramentas` → conexão "Banco Inter" + lista de endpoints
   - `curl -w %{http_code} localhost:8787/__scheduled` → **200**
3c. Novas rotas: `PUT /api/ajustes/<id>` com `{"category":"Rent","gasto":0}` → 200 (Origin errado → 403, `gasto:5` → 400); rode `/api/atualizar` de novo e confira o ajuste em `/api/historico` e `/api/dados?mes=` (campos `ajuste_categoria`/`ajuste_gasto`); `/api/historico` → 6 meses; `/api/fatura?conta=conta-cartao&de=2026-10-01&ate=9999-12-31` inclui 3 futuras; `POST /api/sair` → cookie `Max-Age=0` e depois **401**.
4. Reconexão: reinicie o mock com `MOCK_RECONNECT=1`, rode `/api/atualizar` e confira em `/api/dados` → `snapshots.avisos` com **1** item e `reconnect_url` https.
5. Build: `pnpm exec wrangler deploy --dry-run` sem erro.
6. Painel (se mexeu em `public/`): Playwright (`playwright-core` + `chrome-headless-shell` de `~/.cache/ms-playwright`) com login pela tela: login 390px, painel claro 1280px, escuro 390px, detalhe da transação (Esc/clique fora com alteração pede "Descartar alterações?", foco volta à linha), fatura aberta; sem erro de console (o 401 do teste de senha errada é esperado) e sem rolagem horizontal. Confira `navigator.serviceWorker.ready` e o manifest. Offline: `setOffline` não afeta o service worker; derrube o `wrangler dev` e recarregue: deve aparecer "Offline: dados de …". "Sair" volta ao /login e apaga os caches `dados-*`.
7. Pare os dois processos (`ps -eo pid,args` + `kill`; não use `pkill -f`, que mata o próprio shell) e confirme 8787/8788 livres.
