---
name: verificar-saude
description: "Verifica o alerta de saúde do Meu Banco: check diário do Worker (Pluggy, IA, espelho, cron/batimento), contador de erros da IA no seguro(), push com dedup e 'voltou ao normal', rota /api/saude, ferramenta MCP saude e a tela Saúde + aviso da Início no app. Use após mudar apps/worker/src/saude.js, iaSaude.js, ia.js, o cron do wrangler.toml ou budget/lib/pages/saudePage.dart / struct/mbSync/saude.dart."
---
# Verificar Saúde (alerta de nada falhar em silêncio)

## Cobre
- `apps/worker/src/saude.js`: `verificar` (4 itens: `pluggy`, `ia`, `espelho`, `cron`, cada um com `status` ok < atencao < erro, `resumo`, `detalhes`, `acao`), `rodarSaude` (grava `saude:resultado` e `saude:batimento` em `snapshots`, manda 1 push com dedup), `lerSaude` (`atrasado` = batimento há mais de 26 h). Limiares em `LIMITES`.
- `apps/worker/src/iaSaude.js` + `seguro()` em `ia.js`: toda chamada da IA conta em `saude_ia` (balde por hora: ok, vazia, erro, último erro) e o erro é registrado sem quebrar a resposta ao app (devolve `null`/`[]` como antes).
- Sem cron próprio (o plano gratuito aceita 5 por conta e a conta está no limite: o deploy falha com o código 10072): o tick das 10h UTC (07h07 BRT) do cron de sincronização roda `rodarSaude` depois da sincronização, só com `SAUDE = "1"` (no `wrangler.toml`; como `ESPELHO`). Rotas `GET /api/saude` e `POST /api/saude/verificar` (token de aparelho ou sessão). Ferramenta MCP `saude` (só leitura).
- App: `SaudePage` (Meu Banco › "Saúde do app"), aviso na Início (`AlertasBento`, só com problema ou check atrasado), toque no push (`item.tipo == 'saude'`).

## Regras que precisam valer
1. Nunca escrever no D1 de PROD, rodar `wrangler deploy` ou chamar a Pluggy real para provar isto: tudo local, com mock e D1 local.
2. O push é sem conteúdo (vai por `notificacoes`; o app busca o texto): no máximo 1 alerta igual por dia (`saude:<dia>:<assinatura>`); "voltou ao normal" só se o resultado anterior tinha problema.
3. `seguro()` nunca deixa o erro da IA sumir (log + contador) e nunca vaza a descrição do erro para o app.
4. Item que falha ao ser verificado vira `erro` com "Não consegui verificar", nunca some do resultado.
5. Tabela nova entra no `schema.sql` e em `TABELAS` de `scripts/migrar.mjs`.

## Como verificar
1. `cd apps/worker && node --test test/saude.test.mjs` → 19 testes: tudo ok; Pluggy LOGIN_ERROR/sync antigo/conta sem movimento; modelo fora do catálogo, sem AI, timeout; taxa de erro e de respostas vazias em 24 h; espelho (DO fora, tabela ausente, sem escrita); cron/batimento atrasado; dedup; "voltou ao normal"; rotas e MCP; `worker.scheduled` com push mock. Depois a suíte inteira: `node --test test/*.test.mjs`.
2. Cron ao vivo local (sem `[ai]` no wrangler de teste, ver `verificar-worker`): `curl "localhost:8787/cdn-cgi/handler/scheduled?cron=0+11+*+*+*"` → 200, linha `saude:<dia>:...` em `notificacoes`, `GET /api/saude` com `status` e os 4 itens, segundo disparo no mesmo dia sem push novo. Sem binding AI o item `ia` fica em atenção ("A IA não está ligada"): é esperado no local.
3. App (CI "Checks do PR"; local só se houver Flutter 3.24.5): `flutter test test/mb_saude_test.dart` (13 testes: modelo, aviso acende/apaga, tela, Verificar agora, offline, Worker sem a rota) e `PRINTS=1 flutter test test/prints_saude_test.dart --update-goldens` → `saude_ok`, `saude_problema`, `saude_aviso_inicio` em claro e escuro. Olhe os PNGs: texto não pode repetir (resumo igual ao detalhe), nada cortado.
4. Só depois do merge/deploy (não provável no local): cron real das 07h07, push real no aparelho, tela com dados reais, número de Cron Triggers permitido na conta Cloudflare.
