---
name: verificar-app-web
description: Verifica visualmente o app web do Meu Cashew servido em /app/ (prints Playwright em 1280 e 390, claro e escuro, com console e CSP). Use depois de mexer no layout do app (budget/), em apps/worker/public/app ou na CSP_APP do Worker.
---

# Verificar o app web (/app/) com prints

1. **Build do app** (na raiz do repositório): `export PATH=$HOME/dev/flutter/bin:$PATH JAVA_HOME=$HOME/dev/jdk17 ANDROID_HOME=$HOME/Android/Sdk` e `scripts/compilar.sh web "$PWD/apps/worker/public/app"` (o diretório não é versionado).
2. **Worker local**: `cp apps/worker/.dev.vars.example apps/worker/.dev.vars` (se faltar), `pnpm db:local`, `pnpm mock` (porta 8788, Pluggy falso) e `pnpm dev` (porta 8787) em segundo plano.
3. **Semear (só D1 local)**: login (`POST /api/login` com a senha de `.dev.vars`) e `POST /api/atualizar` (Origin = `http://localhost:8787`) trazem contas e transações do mock. Depois `POST /api/sync` com `registros` de `orcamentos`, `metas`, `dividas` e `assinaturas`; para os orçamentos terem gasto, reenvie as `categorias` do app (`cashew:N`) com o campo `pluggy` (ex.: `["Groceries"]`). Deixe um orçamento estourado para ver o vermelho.
4. **Prints**: `pnpm exec playwright install chromium` (uma vez) e `pnpm --filter @meu-banco/worker prints`. Saída em `apps/worker/.prints/` (não versionado): `app-<w>-<tema>.png`, `-detalhe`, `-busca` (1280) e `-semanimacao`. `PRINTS_LINHA=x,y` ajusta o clique da primeira linha da tabela no 1280; `PRINTS_ESPERA` (ms) o tempo após o pull (o Drift web começa vazio em cada contexto).
5. **Conferir**: o script lista erros de console, violações de CSP e falhas de rede e termina com código 1 se houver algo fora do conhecido (`accounts.google.com/gsi/client`, injetado pelo google_sign_in_web e bloqueado de propósito). Abra os PNGs e confira: grade 232 | 1fr | 360, serifa itálica nos títulos, versalete nos `h2`, um só azul, vermelho só no orçamento estourado, sem sublinhado amarelo (texto fora de `Material`) e a versão `vX.Y.Z · dd/mm/aaaa HH:mm` sem encostar na barra inferior nem no conteúdo.
6. Encerre `wrangler`, o mock e remova `.dev.vars` e `.wrangler` se não forem mais usados.
