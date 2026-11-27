# Alerta de saúde (estado)

- **Nível:** 2 (feature grande; toca cron, push e app, sem escrita em PROD)
- **Etapa:** 7 de 7 — PR aberto, esperando "Checks do PR" e o seu QA/merge
- **Próximo passo:** você revisa o PR, confirma os limiares e faz o merge · **com você**

## Decisões (briefing do Renan em 27/11/2026)
- Check diário no tick das 10h UTC (07h07 de São Paulo) do cron único de sincronização (`HORA_SAUDE_UTC` em `saude.js`; a Cloudflare recusou um 2º cron: limite de 5 do plano gratuito).
- Itens: Pluggy, IA, Espelho, Cron/Worker. Resultado em `snapshots` (`saude:resultado`), batimento em `saude:batimento`.
- Contador da IA em tabela nova `saude_ia` (balde por hora), alimentada pelo `seguro()` de `ia.js`.
- Push: mesmo mecanismo do `enviar_resumo` (`notificacoes` + `enviarPendentes`), chave `saude:<dia>:<assinatura>` (1 por dia) e `saude:ok:<dia>` para "voltou ao normal".
- App: tela "Saúde" (Meu Banco › "Saúde do app") e aviso na Início quando há problema ou o batimento atrasa (> 26 h). MCP: ferramenta `saude` (leitura).
- Limiares escolhidos por mim (a confirmar na revisão): sync 12 h/30 h, item 72 h, conta sem movimento 7 dias (com ≥ 8 transações históricas), IA erro 20 %/50 % com amostra ≥ 5, respostas vazias 90 %, batimento 26 h.

## Restrições
Sem merge, sem `wrangler deploy`, sem escrita no D1 de PROD, sem Pluggy real; repo público (fixtures sem dado real).

## Tarefas e provas
- [x] `saude.js`, `iaSaude.js`, `seguro()` com contador, cron + batimento, rotas `/api/saude`, MCP `saude`
- [x] `node --test test/saude.test.mjs`: 19/19 (uma falha simulada por caso)
- [x] `wrangler dev --test-scheduled`: cron gerou a notificação e o push mock (cabeçalho `vapid`), 2º disparo no mesmo dia sem push novo, `GET /api/saude` ok
- [x] App: `SaudePage`, aviso na Início, toque no push; `flutter test test/mb_saude_test.dart` 13/13; prints `saude_*` em claro e escuro (no PR)
- [x] skill `verificar-saude` (+ índice e `verificar-worker`)
- [x] qualidade: 2 passadas de simplificação (reuso de `somarDias`, helpers redundantes fora), `/code-review high --fix` (conta de conexão removida ignorada; aviso da Início mostra o problema real; limpeza de `saude_ia` não derruba o check); worker 317/317, app 13/13
- [ ] "Checks do PR" no CI

## Fica para depois do merge (não provável no local)
Cron real das 07h07; push real no aparelho; tela com dados reais; `migrar` aplicando `saude_ia` no D1 de PROD pelo deploy.

## Decisões do code-review (Renan: "faz tudo sem me consultar", 27/11/2026)
- Espelho: dias sem escrita deixam de ser alerta (só informativo); tabelas e Durable Object seguem checados.
- Respostas vazias: só contam com ≥ 20 respostas sem erro em 24 h (lista vazia também é resposta legítima).
- `ultimo_erro` (classe + 100 caracteres da mensagem do Workers AI) fica: ajuda a achar a causa e a mensagem do provedor não leva o nosso prompt.
- Ordem de entrega: o `deploy.yml` roda `migrar --remote` antes do `wrangler deploy`, então `saude_ia` existe antes do 1º check.
