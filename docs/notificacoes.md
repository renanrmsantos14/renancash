# Notificações do Meu Banco

## Como chega em cada aparelho
- Worker (cron `7 1,4,7,10,13,16,19,22 * * *` UTC = 22h07, 01h07 ... 19h07 de Brasília) consulta a Pluggy, avalia os alertas e grava em `notificacoes` (`INSERT OR IGNORE` na `chave`, então nunca repete).
- Celular (app Android): o Workmanager chama `GET /api/notificacoes?desde=<cursor>` a cada 15 min e mostra notificações locais. Alertas de "Para revisar" trazem `item` e viram botões (as respostas do item).
- Computador/web: Web Push sem conteúdo; o service worker busca `POST /api/notificacoes/entregar` e agrupa mais de um alerta numa só notificação.
- Duplicata: cada evento tem `chave` única; o id Android deriva da chave e a entrega web é global (`entregue_em`).

## Alertas
| Chave | Quando | Texto |
|---|---|---|
| `compras:<ISO>` | lote de compras novas (uma por consulta) | "3 compras, R$ 120,00" / "Faltam R$ 380,00 no Geral até 05/12." |
| `orc80:` / `orc100:` | só orçamento Geral, 1x por ciclo | 80% e 100% |
| `fatura:<conta>:<venc>` | uma vez por vencimento, quando faltarem 3 dias ou menos (só Inter) | "Fatura do Inter vence em 3 dias" |
| `revisar:<id>` / `revisar:salario:<mês>` | item novo da fila (até 5) | "Pix enviado: R$ 50,00" + botões |
| `conexao:<item>:<ISO>` | banco desconectou | "Inter desconectou" |
| `semana:<domingo>` | domingo 19h | gasto da semana e do ciclo, Geral, maiores categorias, pendências, metas |

Silêncio 22h–7h (Brasília): nada é enviado; o cursor do celular não avança e Web Push não dispara. O tick das 07h07 entrega tudo, agrupado.

## Removido ou desligado (contradiz o perfil)
- Alertas de outros orçamentos além do Geral; `limite80`/`limite100` legados.
- Notificação por compra (agora é por lote).
- "Gasto acima do normal", "Entrou dinheiro" (receita), fechamento de fatura, assinaturas.
- Reconexão por dia (`reconexao:<dia>`): vira `conexao:<item>:<ISO>`, uma vez por queda.
- Santander não entra nas contagens de compras nem de fatura.

## Compatibilidade
- App antigo com Worker novo: ignora `item` e mostra título e corpo.
- App novo com Worker antigo: sem `item` não há botões; o payload só abre o app.

## Limites conhecidos
- Duas atualizações simultâneas (webhook e botão) podem gerar dois avisos de lote.
- Mais de 5 itens novos da fila: só os 5 primeiros ganham aviso por rodada.
- Compra PENDING que vira POSTED com outro id pode contar duas vezes no lote.
- Primeiro deploy: itens recentes da fila e quedas em andamento notificam uma vez.
- Botões, entrega às 7h e Web Push reais só se validam em aparelho.
