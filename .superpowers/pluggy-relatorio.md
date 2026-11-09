# Troca de fonte: MCP.AI para Pluggy direto

## Fontes consultadas (docs oficiais)
- Auth: https://docs.pluggy.ai/docs/authentication e https://docs.pluggy.ai/reference/auth-create (POST /auth {clientId, clientSecret} -> apiKey)
- Cabeçalho `X-API-KEY` e validade de 2 h: https://v2.docs.pluggy.ai/en/docs/reference/authentication.md
- Listar items: https://docs.pluggy.ai/reference/items-list-by-cursor (GET /v2/items, opt-in, desligado por padrão, exige contato com o suporte); FAQ https://v2.docs.pluggy.ai/en/docs/get-started/faq (não há listagem de items por segurança); https://docs.pluggy.ai/reference/items-retrieve (status UPDATED, LOGIN_ERROR citado em consecutiveFailedLoginAttempts; OUTDATED não aparece na página)
- Contas: https://docs.pluggy.ai/reference/accounts-list (itemId obrigatório; creditData.creditLimit/availableCreditLimit/balanceDueDate)
- Transações: https://docs.pluggy.ai/reference/transactions-list (accountId, from, to, page, pageSize=500, totalPages; creditCardMetadata.installmentNumber/totalInstallments). v1 deprecated, disponível só até 2026-12-31 (hoje usada só como fallback).
- Transações v2: https://docs.pluggy.ai/reference/transactions-list-by-cursor (accountId obrigatório, dateFrom, dateTo, createdAtFrom, ids, after; resposta {results, next}, `next` nulo na última página; sem totalPages; 500 por página; campos id, date, amount, type, status, description, category, accountId... A página NÃO cita creditCardMetadata nem merchant: o mapeamento já tolera a ausência, mas o texto "parcela n/total" depende de description). Changelog: https://v2.docs.pluggy.ai/en/changelog/2026.06.
- Faturas: https://docs.pluggy.ai/reference/bills-list (GET /bills?accountId; id, dueDate, totalAmount, minimumPaymentAmount; sem situação de pagamento)
- Limites: https://docs.pluggy.ai/docs/rate-limits (360 req/min por IP em /auth e /transactions)
- Plano/custo: https://pluggy.ai/pricing (conector MeuPluggy gratuito, máx. 5 conexões ativas por titular, sem SLA; plano Dados a partir de R$ 2.500/mês)

## Confirmado x não confirmado
- Confirmado: auth, X-API-KEY, apiKey de 2 h, /accounts?itemId, paginação de transações, campos de conta e de parcela, /bills, rate limit.
- GET /items não lista: precisa de `PLUGGY_ITEM_IDS` (ou /v2/items liberado pelo suporte). O código aceita os dois; sem nenhum, falha com mensagem pedindo o secret.
- Não confirmado: onde o Meu Pluggy mostra os ids das conexões e as credenciais; se o conector MeuPluggy traz `connector.name` = "Meu Pluggy" (assumido); se o sinal de `amount` do cartão é positivo na compra (o código usa o `type` DEBIT/CREDIT e só cai no sinal da API se o tipo faltar); se o Meu Pluggy expõe /bills; se traz parcelas futuras (as futuras são detectadas por data > hoje). Custo: uso pessoal gratuito pelo conector MeuPluggy segundo a página de preços; a vigência para a sua conta não foi confirmada com o Pluggy.
- Não implementado: forçar atualização do banco (PATCH /items/{id}); o app só lê o que o Pluggy já tem.

## O que mudou
- `src/api.js`: cliente do Pluggy (auth com apiKey compartilhada e renovada em 401/403, 429 com Retry-After, transações via GET /v2/transactions (cursor `after`, dateFrom/dateTo), com fallback para a v1 se a v2 devolver 403/404/410 (lembrado por instância), erros em pt-BR por status).
- `src/mapa.js` (novo): contrato interno. Contas com id do Pluggy (único entre bancos) e nome com o banco ("Cartão Santander"); sinal por tipo (conta: saída negativa; cartão: compra positiva, estorno negativo); `scheduled` = data depois de hoje; parcela "n/total" na descrição; faturas no formato que o painel já lia (aberta = saldo + vencimento da conta; fechadas = /bills, situação "CLOSED").
- `src/index.js`: `sincronizar` itera os items; uma conexão com erro vira aviso e as outras seguem; `/api/ferramentas` mostra o status de cada item; `/api/app/transacoes` e o painel inalterados.
- Painel: já suportava N contas e N cartões (cards por conta, faturas por cartão, filtro de contas). Nenhuma mudança em `public/`. O card "Conta corrente" soma os saldos dos bancos e lista cada conta. Provado com 2 bancos (4 contas) no mock; sem print do painel porque `public/` não mudou.
- Config: removidos MCP_API_KEY e API_URL de wrangler.toml, .dev.vars.example, README e da skill. `PLUGGY_API_URL` existe só no `.dev.vars` local (aponta para o mock).
- `scripts/reimportar.sql` + README: apaga transactions, accounts, snapshots, sync_log; preserva config, app_tokens, push_inscricoes, notificacoes (e ajustes, que ficam órfãos por causa dos ids novos). NÃO executado em nenhum banco remoto. Backup: `wrangler d1 export meu-banco --remote --output=...`.
- Mock `mock/api-mock.mjs` agora fala Pluggy com 2 conexões (Inter via "Meu Pluggy", Santander via connector real).

## Provas
- `pnpm -s test`: 39 testes, 0 falhas (inclui test/api.test.mjs com fetch mockado: auth única, renovação em 401, 429, /v2/items paginado, paginação de transações; test/mapa.test.mjs: 2 bancos, cartão com parcelas, pendente, sinais).
- `node --check` em src/*.js e mock: ok. `wrangler deploy --dry-run`: ok.
- Fluxo local da skill (wrangler dev + mock): 2 sincronizações idempotentes; Inter cartão 64 (3 futuras), conta 37; Santander cartão 4 (1 futura), conta 3; `/api/ferramentas` com 2 itens UPDATED; reconexão (LOGIN_ERROR) gera 1 aviso; credenciais erradas dão ok:false com mensagem em pt-BR; `/api/app/transacoes` com token: 4 contas, 108 transações, 3 pendentes; ciclo com salário ok; cron 200. Portas 8787/8788 livres, processos encerrados.
- Não testado: Pluggy real (sem credenciais), painel no navegador (public/ não mudou).

## Qualidade
- Simplificação: 3 passadas inline (simplify + karpathy-coder). Passada 1: removeu o código de paginação e de merge de status do MCP.AI, PROBLEMA/TAM_PAGINA e num() de index.js (agora em mapa.js/api.js); passada 2: apiKey passou a ser uma Promise compartilhada (evita /auth duplicado em chamadas simultâneas) e a autenticação foi antecipada em listarIds (credencial errada falha uma vez, não por conexão); passada 3: sem mudanças.
- Framework: workers-best-practices aplicada (secrets via wrangler, sem estado mutável global, sem ctx desestruturado, observabilidade já ativa, sem Env duplicado).
- code-review high --fix: 7 achados. Corrigidos: reautenticação compartilhada entre chamadas simultâneas; detecção de parcela já numerada só pelo "n/total" exato; sinal cai no da API quando o type falta; avisos de reconexão não são apagados quando uma conexão falha na leitura. Não corrigidos (aceitos e documentados): sem PATCH /items para forçar atualização; faturas sempre "Fechada" (o Pluggy não informa pagamento) e saldo da conta usado como fatura aberta; 403 por falta de permissão ainda gasta uma reautenticação; `next` de /v2/items assumido como query string.
- Provas finais após o code-review: testes, node --check, dry-run e fluxo local repetidos, ok.


## Migração para /v2/transactions
- Feita em `src/api.js` (`transacoes` -> `#transacoesV2`; `#transacoesV1` é o fallback). Não confirmado sem credenciais reais: se a v2 está habilitada para o conector Meu Pluggy e se devolve `creditCardMetadata`/`merchant`. Sem eles, as parcelas futuras do cartão só aparecem se vierem no resultado; verifique no primeiro sync real.
- Prova: `pnpm -s test` 41/41, `node --check`, `wrangler deploy --dry-run`, fluxo mock com v2 e com `MOCK_SEM_V2=1` (v1): cartão Inter 64 (3 futuras), conta 37, Santander 4 (1) e 3, idempotente.
