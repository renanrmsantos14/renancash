# Alerta de saúde (estado)

- **Nível:** 2 (feature grande; toca cron, push e app, sem escrita em PROD)
- **Etapa:** 7 de 7 — PR aberto, esperando "Checks do PR" e o seu QA/merge
- **Próximo passo:** você revisa o PR, confirma os limiares e faz o merge · **com você**

## Decisões (briefing do Renan em 27/11/2026)
- Check diário no cron `0 11 * * *` (08:00 de São Paulo); o horário muda no `wrangler.toml`.
- Itens: Pluggy, IA, Espelho, Cron/Worker. Resultado em `snapshots` (`saude:resultado`), batimento em `saude:batimento`.
- Contador da IA em tabela nova `saude_ia` (balde por hora), alimentada pelo `seguro()` de `ia.js`.
- Push: mesmo mecanismo do `enviar_resumo` (`notificacoes` + `enviarPendentes`), chave `saude:<dia>:<assinatura>` (1 por dia) e `saude:ok:<dia>` para "voltou ao normal".
- App: tela "Saúde" (Meu Banco › "Saúde do app") e aviso na Início quando há problema ou o batimento atrasa (> 26 h). MCP: ferramenta `saude` (leitura).
- Limiares escolhidos por mim (a confirmar na revisão): sync 12 h/30 h, item 72 h, conta sem movimento 7 dias (com ≥ 8 transações históricas), IA erro 20 %/50 % com amostra ≥ 5, respostas vazias 90 %, espelho 3 dias, batimento 26 h.

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
Cron real das 08:00; push real no aparelho; tela com dados reais; quantos Cron Triggers a conta Cloudflare aceita (este é o 2º cron do Worker); `migrar` aplicando `saude_ia` no D1 de PROD pelo deploy.

## Pontos de decisão do code-review (não aplicados)
- Espelho sem escrita por 3 dias vira "atenção" mesmo saudável (fim de semana sem editar): subir o limiar ou tirar o item?
- "Respostas vazias" conta lista vazia legítima da IA; com 5+ usos sem sugestão no dia pode dar falso alerta.
- `ultimo_erro` (classe + 100 caracteres da mensagem do Workers AI) aparece no push e na tela; o texto nunca leva prompt nosso, mas a mensagem do provedor não é controlada.
- Ordem de entrega: `migrar` (cria `saude_ia`) antes do deploy; senão o 1º check marca IA em erro.
