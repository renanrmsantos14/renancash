# Meu Banco

Painel pessoal com saldo, cartão, faturas e transações de todos os bancos conectados no **Meu Pluggy** (ex.: Banco Inter e Santander, conta corrente e cartão de cada um), lidos direto da API do **Pluggy** (https://api.pluggy.ai).
Roda 100% no plano gratuito da Cloudflare: Workers + Workers Assets + D1 + Cron Triggers. Não usa IA.

```
apps/worker/public/index.html   painel (HTML + JS puro, tema claro/escuro, gráficos SVG, detalhe da transação, faturas)
apps/worker/public/login.html   tela de login
apps/worker/public/sw.js        service worker (cache do shell e dos dados, modo offline)
apps/worker/public/manifest.webmanifest, apps/worker/public/icons/, apps/worker/public/apple-touch-icon.png   PWA instalável
apps/worker/scripts/icones.mjs  gera os PNG dos ícones (node apps/worker/scripts/icones.mjs)
apps/worker/src/index.js        Worker: login por cookie, API do painel, sincronização (cron e botão)
apps/worker/src/api.js          cliente da API do Pluggy (autenticação, paginação, nova tentativa no 429)
apps/worker/src/mapa.js         traduz contas, transações e faturas do Pluggy para o formato interno
apps/worker/src/ciclo.js        ciclo do salário, limite e parcelas comprometidas
apps/worker/src/alertas.js      decide quais alertas gerar (limite, gasto fora do padrão, reconexão, resumo semanal)
apps/worker/src/push.js         envio de Web Push (VAPID) sem biblioteca
apps/worker/scripts/vapid.mjs   gera o par de chaves VAPID
apps/worker/schema.sql          tabelas do D1
apps/worker/mock/api-mock.mjs   Pluggy falso (2 conexões: Inter e Santander) para teste local
apps/worker/scripts/reimportar.sql  apaga contas/transações/faturas importadas, para reimportar do zero
apps/worker/scripts/versao.mjs  incrementa a versão mostrada no canto do painel a cada deploy
apps/worker/src/backup.js       backup diário do D1 no R2
apps/worker/scripts/cashew.mjs, importar-cashew.mjs   importação única do backup do Cashew
packages/core/src/sync.ts       validação e regras de sincronização dos registros (TypeScript, sem dependências)
```

## 1. Preparar o PC (uma vez)

1. Instale o **Node.js LTS** em https://nodejs.org (aceite as opções padrão). Feche e abra o terminal.
2. Confira: `node -v` (precisa ser 22.18 ou mais novo: o pacote `core` roda `.ts` direto, sem build).
3. Ative o pnpm: `corepack enable` (ou `npm install -g pnpm`).
4. Na pasta do projeto: `pnpm install`.

## 2. Testar localmente com o mock (opcional, recomendado)

```powershell
copy apps\worker\.dev.vars.example apps\worker\.dev.vars        # Linux/macOS: cp apps/worker/.dev.vars.example apps/worker/.dev.vars
pnpm db:local                        # cria as tabelas no banco local
```

Terminal 1: `pnpm mock` · Terminal 2: `pnpm dev`

Abra http://localhost:8787 → tela de login, senha `teste123` → clique **Atualizar**.
Para testar o cron: abra http://localhost:8787/__scheduled no navegador.
Para simular uma conexão pedindo novo login: pare o mock e rode `MOCK_RECONNECT=1` (PowerShell: `$env:MOCK_RECONNECT=1`) antes de `pnpm mock`.

## 3. Configurar o Pluggy (Meu Pluggy)

1. Em https://meu.pluggy.ai conecte seus bancos (Inter, Santander…) e confirme que as conexões aparecem como atualizadas.
2. Pegue o **Client ID** e o **Client Secret** do seu acesso à API (o Meu Pluggy ou o Dashboard do Pluggy, https://dashboard.pluggy.ai, mostram as credenciais da aplicação).
3. Anote o **id de cada conexão** (item, um UUID por banco conectado). O Pluggy não lista as conexões por padrão (`GET /v2/items` é opt-in e exige pedir a liberação ao suporte), então guarde os ids no secret `PLUGGY_ITEM_IDS`, separados por vírgula. Sem ele, o app tenta `GET /v2/items` e, se a conta não tiver acesso, mostra o erro pedindo o `PLUGGY_ITEM_IDS`.

O que o app usa:

| Item | Valor |
|---|---|
| URL base | `https://api.pluggy.ai` |
| Autenticação | `POST /auth` com `clientId`/`clientSecret` devolve a `apiKey` (vale 2 h; o app pede uma por sincronização e renova se expirar); as demais chamadas levam `X-API-KEY` |
| Endpoints | `GET /items/{id}`, `GET /accounts?itemId=`, `GET /v2/transactions?accountId&dateFrom&dateTo&after` (paginação por cursor: segue `next` até vir nulo; a v1 `GET /transactions` vence em 2026-12-31 e só é usada como fallback se a v2 responder 403/404/410), `GET /bills?accountId=` |
| Limite | 360 requisições por minuto por IP em `/auth` e `/transactions` (v1) (https://docs.pluggy.ai/docs/rate-limits); o app espera o `Retry-After` no 429 |

Como o Pluggy vira o formato interno:

- **Contas**: cada conta do Pluggy é uma linha, com o id do Pluggy (único entre bancos). O nome identifica o banco: se a conexão é de um banco (`connector.name`), ele é acrescentado ao nome ("Cartão Santander"). No Meu Pluggy o conector é "Meu Pluggy" (não é banco), então o nome da conta vale como veio; se duas contas ficarem com o mesmo nome, o final do número é acrescentado. O painel lista N contas e N cartões, cada cartão com seu limite, fatura aberta e faturas.
- **Valor com sinal**: definido pelo tipo (`DEBIT`/`CREDIT`), não pelo sinal da API. Conta corrente: saída negativa. Cartão: compra positiva, estorno negativo.
- **Pendentes** (`status = PENDING`) e **parcelas futuras** (data depois de hoje): o cartão é buscado sem `to` para trazê-las; a parcela (`creditCardMetadata`) é acrescentada à descrição ("NOTEBOOK LOJA 2/4"), se ainda não vier nela.
- **Faturas**: `GET /bills` lista as faturas fechadas; a aberta vem do saldo e do vencimento da conta (`creditData`). O Pluggy não informa se a fatura foi paga, então todas aparecem como "Fechada".
- **Conexão com problema** (`LOGIN_ERROR`, `WAITING_USER_INPUT`...): aviso amarelo no painel, com link para o Meu Pluggy. `OUTDATED` é falha temporária e não avisa.

Custo: o uso pessoal com o conector **MeuPluggy** é gratuito segundo https://pluggy.ai/pricing (limite de 5 conexões ativas por titular, sem SLA, sem contrato; o plano pago "Dados" começa em R$ 2.500/mês). Esse conector só enxerga o que você conectou no Meu Pluggy. Não confirmei com o Pluggy se as credenciais da sua conta valem para esse uso; a cobrança por requisição só se aplica a planos pagos. Cada atualização faz 1 `/auth`, 2 por conexão (`items` e `accounts`), 1+ por conta (`transactions`) e 1 por cartão (`bills`): cerca de 12 chamadas com 2 bancos; a cada 3 horas são ~100 por dia. Se mudar de plano, mude o cron no `apps/worker/wrangler.toml`.

## Pluggy: webhook e conexões

O Pluggy avisa o Worker quando uma conexão muda (`item/updated`, `item/error`, `item/waiting_user_input`, `item/login_succeeded`), quando é criada e quando é apagada. O Worker responde na hora e sincroniza em segundo plano. A sincronização roda no alarme do Durable Object (`EspelhoHub`), que não tem o corte de ~30 s do `waitUntil`; se outra estiver em andamento, ele tenta de novo a cada minuto (até 12 vezes), então o aviso do segundo banco não se perde até o cron.

1. Crie um segredo aleatório e guarde como secret: `node -e "console.log(crypto.randomUUID()+crypto.randomUUID())" | pnpm --filter @meu-banco/worker exec wrangler secret put PLUGGY_WEBHOOK_SECRET`.
2. Logado no painel, registre o webhook (uma vez): `POST /api/pluggy/webhooks`. Ele aponta para `https://<seu-worker>/api/pluggy/webhook` e o Pluggy envia o segredo no cabeçalho `x-webhook-secret`. Sem `PLUGGY_WEBHOOK_SECRET` essa rota responde **500** ("PLUGGY_WEBHOOK_SECRET ausente"), e o webhook recusa tudo com 401.
3. **Rotação do secret**: depois de trocar o `PLUGGY_WEBHOOK_SECRET`, chame `POST /api/pluggy/webhooks` de novo. Se já existe um webhook para a mesma URL, ele é atualizado (`PATCH /webhooks/:id`) com o cabeçalho novo; sem isso, o Pluggy continuaria enviando o segredo antigo e levaria 401.

As conexões ativas ficam na tabela `pluggy_items` do D1: na primeira sincronização ela copia o `PLUGGY_ITEM_IDS`, e depois o D1 manda (o secret deixa de valer). `item/created` registra a conexão, `item/deleted` a marca como removida.

## Sincronização com os apps (`/api/sync`)

Cada aparelho tem um token (**Ajustar → Apps conectados**; veja "App Android"). O token vai em `Authorization: Bearer mb_...`:

- `GET /api/sync?desde=<ISO opcional>`: contas, transações, `registros` (categorias, orçamentos, metas, ajustes etc.), pendentes, config, faturas e avisos. Sem `desde` vem tudo; com `desde`, só o que mudou (relê 2 min antes por segurança). Guarde o `agora` da resposta para o próximo `desde`.
- `POST /api/sync` com `{"registros":[{tabela,id,dados,updated_at,deleted_at}]}`: envia mudanças. Vale o `updated_at` mais novo (last-write-wins por registro). Limites: 500 registros por lote, `dados` até 8 KB, `id` de 1 a 80 caracteres, relógio até 5 min adiantado. Devolve `{ok, aceitos, rejeitados}`.
- `GET /api/notificacoes?desde=<ISO>`: alertas gerados pelo Worker (limite, orçamentos, fechamento da fatura, receita, assinaturas, fora do padrão, reconexão), até 20 por chamada, mais um `resumo` (disponível, consumido, limite, ciclo, última sincronização). Sem `desde`, só devolve o `cursor` inicial (não despeja o histórico). Das 22h às 7h (Brasília) responde vazio e o cursor não anda. Guarde o `cursor` para a próxima chamada.
- Sem token válido (e sem sessão), 401.

## Atualizar (botão e apps)

O botão **Atualizar** do painel e `POST /api/sync/atualizar` (apps) pedem ao banco dados novos (`PATCH /items/{id}` no Pluggy) e leem o que já existe; quando o banco termina, o webhook faz a leitura final. **Limite: uma vez a cada 5 minutos**, somando painel e apps. Antes disso a resposta é **429** com "Atualizado há pouco. Tente de novo às HH:MM." (horário de Brasília) e `liberado_em`. O cron e os webhooks não contam para o limite.

## Backup diário do D1 (R2)

Todo dia, no tick das 07h07 UTC (04h07 BRT) do cron, o Worker grava o D1 inteiro em `d1/AAAA-MM-DD.json.gz` no bucket R2 `meu-banco-backups` (binding `BACKUP`). Uma falha no backup só é registrada no log e não impede a sincronização.

- Crie o bucket **privado** (sem domínio público nem acesso `r2.dev`): `pnpm --filter @meu-banco/worker exec wrangler r2 bucket create meu-banco-backups`. O backup contém os hashes de `app_tokens` e as conexões de `pluggy_items`, além de todas as transações.
- Retenção de 30 dias: regra de ciclo de vida do bucket (Dashboard da Cloudflare → R2 → bucket → Configurações → Regras de objeto), prefixo `d1/`. Não é código.
- Testar local: `pnpm dev` e `curl "localhost:8787/cdn-cgi/handler/scheduled?cron=7+1,4,7,10,13,16,19,22+*+*+*&time=1794208020000"` (07:07 UTC). O R2 local fica em `apps/worker/.wrangler/state`.

## Importar o Cashew (uma vez)

Importa categorias, orçamentos, metas, empréstimos e lançamentos do backup do Cashew como `registros`. Rodar de novo não duplica nem sobrescreve o que foi editado depois (`INSERT OR IGNORE`).

```powershell
pnpm --filter @meu-banco/worker importar:cashew caminho\do\backup-cashew.sql > cashew-import.sql
pnpm --filter @meu-banco/worker exec wrangler d1 execute meu-banco --remote --file=cashew-import.sql
```

O comando imprime no terminal quantos registros foram convertidos e quais foram ignorados (e por quê). **Pendente**: os nomes das tabelas e colunas do Cashew (`categories`, `budgets`, `objectives`, `transactions`, `wallets`) vêm de suposição; ainda falta conferir contra um backup real. Faça isso e rode primeiro com `--local` antes de importar no banco real. Transações pagas/futuras do Cashew entram como lançamentos normais.

## Reimportar do zero (troca de fonte de dados)

Os ids de conta e de transação do Pluggy são diferentes dos antigos; para não misturar as duas fontes, apague o que foi importado e sincronize de novo. **Faça backup antes** e confira o alvo (`--remote` é o banco real):

```powershell
pnpm --filter @meu-banco/worker exec wrangler d1 export meu-banco --remote --output=backup-AAAA-MM-DD.sql
pnpm --filter @meu-banco/worker exec wrangler d1 execute meu-banco --remote --file=scripts/reimportar.sql
```

O `apps/worker/scripts/reimportar.sql` apaga só `transactions`, `accounts`, `snapshots` (faturas e avisos) e `sync_log`. Preserva `config` (limite e salário do ciclo), `app_tokens`, `push_inscricoes`, `notificacoes` e as sessões (cookie assinado, não fica no banco). Os `ajustes` também ficam, mas ficam órfãos: a categoria/"não é gasto" que você marcou em transações antigas não vale para as novas (ids novos). Depois, clique **Atualizar** no painel: a primeira carga busca 180 dias (`IMPORT_DAYS`).

## 4. Publicar na Cloudflare

```powershell
pnpm --filter @meu-banco/worker exec wrangler login                       # abre o navegador; autorize a conta nova
pnpm --filter @meu-banco/worker exec wrangler d1 create meu-banco         # copie o "database_id" mostrado
```

Edite o `apps/worker/wrangler.toml` e cole o `database_id`.

```powershell
pnpm db:remote                        # cria as tabelas no D1 da nuvem (--remote)
pnpm --filter @meu-banco/worker exec wrangler secret put PLUGGY_CLIENT_ID       # Client ID do Pluggy (não aparece na tela)
pnpm --filter @meu-banco/worker exec wrangler secret put PLUGGY_CLIENT_SECRET   # Client Secret do Pluggy
pnpm --filter @meu-banco/worker exec wrangler secret put PLUGGY_ITEM_IDS        # ids das conexões do Meu Pluggy, separados por vírgula
pnpm --filter @meu-banco/worker exec wrangler secret put APP_PASSWORD     # senha do painel: use 16+ caracteres
node -e "console.log(crypto.randomUUID()+crypto.randomUUID())" | pnpm --filter @meu-banco/worker exec wrangler secret put SESSION_SECRET   # chave das sessões (aleatória)
pnpm push                             # incrementa a versão e publica
```

O deploy mostra o endereço, algo como `https://meu-banco.SEU-USUARIO.workers.dev`.
Na primeira vez a Cloudflare pede para escolher o subdomínio `workers.dev`.

## 5. Primeiro acesso

1. Entre em `https://meu-banco.SEU-USUARIO.workers.dev` com a `APP_PASSWORD`, depois abra `/api/ferramentas`. Deve mostrar cada conexão com o status (`UPDATED`...). Se der erro aqui, o problema são as credenciais ou os ids do Pluggy.
2. Abra a raiz do site e clique **Atualizar**. A primeira carga busca 180 dias (`IMPORT_DAYS`) e pode levar alguns minutos.
3. Daí em diante o cron atualiza sozinho a cada 3 horas (minuto 7 das horas 0, 3, 6… UTC = 21h, 0h, 3h… em Brasília). O mesmo cron envia os alertas pendentes e, no domingo às 21h07, o resumo semanal.
4. No celular, veja "Instalar no celular" abaixo.

## Login

O painel tem tela própria de login (não usa mais Basic Auth). A senha é o secret `APP_PASSWORD` (o mesmo de antes). Ao entrar, o Worker grava o cookie `sessao` (HttpOnly, Secure, SameSite=Strict, 30 dias), assinado com HMAC-SHA256 com chave formada pelo secret aleatório `SESSION_SECRET` + `APP_PASSWORD`: **trocar qualquer um dos dois encerra todas as sessões** (use isso se perder o celular). Senha errada espera 1 s e devolve 401; mais de 5 tentativas por minuto do mesmo IP dão 429 (na nuvem o contador da Cloudflare é aproximado, por local, então o bloqueio pode demorar algumas tentativas a mais). O botão **Sair** apaga o cookie e o cache de dados do aparelho.
Sem sessão, páginas redirecionam para `/login` e `/api/*` devolve 401. Só `/login`, `POST /api/login`, `/manifest.webmanifest`, `/sw.js` e os ícones são públicos.

## Instalar no celular

- **iPhone (Safari)**: abra o endereço, toque em Compartilhar → **Adicionar à Tela de Início**. O painel mostra essa dica uma vez (dá para fechar).
- **Android/desktop (Chrome)**: toque em **Instalar** no cabeçalho (ou no menu do navegador → Instalar app).
- Sem internet, o app abre com a última cópia dos dados e mostra a faixa "Offline: dados de dd/mm HH:mm".

## Migração do banco (ajustes para `registros`)

Os ajustes (categoria trocada e "não é gasto") saíram da tabela `ajustes` e agora ficam em `registros` (`tabela = 'ajustes'`), lidos pela view `v_ajustes`. No banco já em uso, rode **uma vez**, nesta ordem, logo antes do deploy (faça o backup antes):

```powershell
pnpm --filter @meu-banco/worker exec wrangler d1 export meu-banco --remote --output=backup-AAAA-MM-DD.sql
pnpm db:remote
pnpm --filter @meu-banco/worker exec wrangler d1 execute meu-banco --remote --file=scripts/migrar-ajustes.sql
```

`db:remote` só cria o que falta (`registros`, `pluggy_items`) e recria a view `v_ajustes`. O `migrar-ajustes.sql` copia `ajustes` para `registros` e apaga a tabela antiga; rodar de novo só falha com "no such table: ajustes", sem efeito. Sem ele, os ajustes somem do painel depois do deploy. (Local: `pnpm db:local`, o banco novo já nasce sem `ajustes`.) A sincronização do Pluggy nunca altera os ajustes.

## Gráficos, ajustes e faturas

- Gastos por mês (6 meses) e saldo da conta corrente (6 meses) usam `GET /api/historico`. O saldo é reconstruído de trás para frente (saldo atual menos as transações), não é saldo real gravado.
- Tocar numa transação abre o detalhe: dá para trocar a categoria e marcar/desmarcar "Não é gasto" (`PUT /api/ajustes/:id`). O ajuste vale mais que a regra automática.
- Tocar numa fatura lista as compras dela (`GET /api/fatura`). A API do Pluggy não usa um campo que o painel consiga ligar à fatura (o app não lê o `billId` das compras) nem informa a data de fechamento. Por isso a fatura abrange as compras entre dois fechamentos **estimados em 7 dias antes do vencimento** (`CORTE_FATURA` em `apps/worker/public/index.html`); a fatura aberta inclui as parcelas futuras. O valor oficial é sempre o `totalAmount` da tabela. Se o seu cartão fecha em outro prazo, ajuste a constante.

Opcional, camada extra: Cloudflare Zero Trust → Access → Applications → adicione o domínio `meu-banco.SEU-USUARIO.workers.dev` com política "e-mail = o seu" (gratuito até 50 usuários). A senha do Worker continua valendo.

## Se der erro

- **Voltou para a tela de login sozinho**: a sessão expirou (30 dias) ou a `APP_PASSWORD` mudou. Entre de novo.
- **Painel antigo no celular depois do deploy**: feche e abra o app; o service worker troca de versão no próximo acesso com internet.
- **Botão Instalar não aparece**: só em Chrome/Android com HTTPS; no iPhone use Compartilhar → Adicionar à Tela de Início.
- **"no such table: ajustes"** (ou `config`, `notificacoes`, `push_inscricoes`): faltou `pnpm db:remote`.

A mensagem de erro aparece no painel (faixa vermelha) e no `/api/ferramentas`.

- **401**: Client ID/Secret errados ou expirados. Refaça `pnpm --filter @meu-banco/worker exec wrangler secret put PLUGGY_CLIENT_ID` e `PLUGGY_CLIENT_SECRET` (não precisa novo deploy).
- **403**: sem permissão no Pluggy (credenciais de outra aplicação, ou recurso não liberado na conta).
- **404**: id de conexão errado ou apagado em `PLUGGY_ITEM_IDS`. Confira em `/api/ferramentas`.
- **"Defina PLUGGY_ITEM_IDS"**: o Pluggy não listou as conexões; crie o secret com os ids (seção 3).
- **429**: limite de requisições do Pluggy; o app espera o `Retry-After` e tenta de novo.
- **Aviso amarelo "A conexão não atualizou"**: o banco expirou o consentimento. Reconecte em https://meu.pluggy.ai, confirme no app do banco e clique **Atualizar**.
- **"Já existe uma atualização em andamento"**: espere até 10 minutos; o bloqueio expira sozinho.
- **"Exceeded CPU" / "Too many subrequests"** nos logs: reduza `IMPORT_DAYS` (ex.: `"90"`), faça deploy, clique Atualizar e depois volte para 180 se quiser.
- **"no such table"**: faltou `pnpm db:remote`.
- **"mais de 10 páginas de transações"**: reduza `IMPORT_DAYS`.
- **Ver logs ao vivo**: `pnpm logs` (`wrangler tail`) e clique Atualizar. Também no painel Cloudflare → Workers → meu-banco → Logs. O histórico de execuções fica na tabela `sync_log`:
  `pnpm --filter @meu-banco/worker exec wrangler d1 execute meu-banco --remote --command "SELECT * FROM sync_log ORDER BY id DESC LIMIT 5"`

## Ciclo, limite e alertas

- **Marcar o salário (uma vez)**: toque no crédito do salário na lista de transações e em **Este é o meu salário**. O ciclo começa no último crédito com a mesma descrição e termina na véspera do próximo (início + 1 mês − 1 dia). Sem salário marcado, o painel usa o mês do calendário e pede a marcação.
- **Limite**: no card do ciclo, toque em **Ajustar**, digite o valor total do ciclo e salve. O card mostra consumido, quanto falta e a porcentagem (barra verde, amarela a partir de 80%, vermelha acima de 100%). Consumido = gastos lançados no ciclo + parcelas futuras que caem até o fim dele; as parcelas dos ciclos seguintes aparecem à parte.
- **O que gera notificação**:
  - limite em 80% e em 100% (uma vez por ciclo cada);
  - gasto fora do padrão: compra acima de 2× a média da categoria nos últimos 6 meses, com mínimo de R$ 100 e pelo menos 3 compras de histórico, olhando só os últimos 3 dias;
  - banco pedindo reconexão (uma vez por dia enquanto durar);
  - resumo semanal, domingo às 21h07 (no tick de segunda 00h07 UTC do cron de sincronização).
- **Silêncio das 22h às 7h** (America/Sao_Paulo): o alerta é gravado e sai na primeira sincronização depois das 7h (09h07). Há um cron só, `7 */3 * * *` (o plano gratuito da Cloudflare permite 5 por conta).
- **Push só com Chrome no Android** (PWA instalado ou não). No iPhone não há push. A notificação não leva conteúdo: o service worker busca o texto ao receber o aviso. Ative em **Ajustar → Ativar notificações** e use **Enviar notificação de teste** para conferir.

### Chaves VAPID (uma vez, na publicação)

```powershell
node apps/worker/scripts/vapid.mjs vapid-publica.txt | pnpm --filter @meu-banco/worker exec wrangler secret put VAPID_PRIVADA
```

A chave privada só sai pelo pipe e vira secret (nunca em arquivo nem na tela). Copie o conteúdo de `vapid-publica.txt` para `VAPID_PUBLICA` no `apps/worker/wrangler.toml`, apague o arquivo e rode `pnpm push`. **Trocar as chaves VAPID exige reativar as notificações no celular** (as inscrições antigas deixam de valer).

Push local: no `apps/worker/.dev.vars` ponha `PUSH_HTTP_LOCAL=1` e um par de teste gerado fora do repositório (`node apps/worker/scripts/vapid.mjs <pasta-temporaria>/vapid-local.txt > <pasta-temporaria>/vapid-local.json`); o mock (porta 8788) simula o serviço de push.

## App Android (Cashew)

- **Criar token**: no painel, **Ajustar → Apps conectados**, informe o nome do aparelho e toque em **Criar token**. O token (`mb_...`) aparece uma única vez: copie e cole no app. No D1 fica só o SHA-256.
- **Rota**: `GET /api/app/transacoes?desde=<ISO opcional>` com `Authorization: Bearer mb_...` (sem cookie). Devolve `agora`, `contas`, `transacoes` (alteradas depois de `desde`, ou tudo sem `desde`, com a categoria já ajustada no painel) e `ids_pendentes`. Guarde `agora` e use como próximo `desde`. Token ausente, inválido ou revogado → 401.
- **Revogar**: em **Apps conectados**, **Revogar** e confirme (ou `DELETE /api/app/tokens/<id>` com sessão). O app passa a receber 401 na hora. Perdeu o aparelho: revogue e crie outro.
- Aplique o schema novo antes: `pnpm db:remote` (só `CREATE TABLE IF NOT EXISTS`).

## Segurança

- As credenciais do Pluggy (`PLUGGY_CLIENT_ID`, `PLUGGY_CLIENT_SECRET`) e `PLUGGY_ITEM_IDS` só existem como secrets no Worker; o navegador nunca as recebe e ela não está em nenhum arquivo do projeto. `.dev.vars` está no `.gitignore`.
- Todas as rotas, inclusive o HTML, exigem sessão (`run_worker_first = true`), exceto as públicas do login/PWA. Senha comparada em tempo constante; POST/PUT conferem o `Origin`.
- Dados do banco são exibidos só com `textContent` (sem `innerHTML`), com CSP restrita e `no-store`.

## Regras do painel

- Gastos por categoria = débitos da conta corrente + compras do cartão no mês, **sem** pagamento de fatura, investimentos/poupança/"porquinho", transferência entre contas próprias e parcelas futuras.
- Valores das faturas vêm do `totalAmount` do banco (não da soma das transações).
- O ciclo do salário, o limite e os alertas estão na seção "Ciclo, limite e alertas".
- Parcelas futuras e transações pendentes são apagadas e regravadas a cada sincronização, para não duplicar.

### Migração da Fase 2 (`accounts.closing_date`)

Em banco já existente, rode **antes** de `pnpm push` (o Worker novo lê a coluna; sem ela, `/api/sync` e `/api/dados` dão 500). O script confere a coluna e só altera se faltar, então repetir é seguro (o SQLite não tem `ADD COLUMN IF NOT EXISTS`):

```powershell
pnpm --filter @meu-banco/worker migrar:fase2 -- --remote
```

Banco novo (`pnpm db:remote`) já nasce com a coluna. Use `-- --local` para o D1 local.

## App web em `/app/`

O Worker serve o build web do Meu Cashew em `/app/`, só com sessão (cookie). Sem sessão, vai para `/login?volta=/app/` e volta ao app depois do login. O app usa a mesma origem e o cookie, sem token `mb_`.

- **Deploy pelo GitHub Actions** (`.github/workflows/deploy.yml`): a cada push na main que mexe em `apps/`, `packages/` ou nos arquivos do pnpm, depois de cada release do app (o `release-android.yml` chama este workflow) ou manualmente (**Actions → Deploy Worker → Run workflow**). Compila o web do app (`budget/`), roda testes e typecheck, aplica `migrar:fase2 -- --remote` (idempotente), roda `pnpm push` e grava a versão publicada no main com `[skip ci]`. Secrets: `CLOUDFLARE_API_TOKEN` (Workers Scripts: Edit, D1: Edit) e `CLOUDFLARE_ACCOUNT_ID`.
- **Build local** (na raiz do repositório): `scripts/compilar.sh web "$PWD/apps/worker/public/app"`. A pasta `apps/worker/public/app/` não é versionada.
- **Renderer**: CanvasKit (padrão do Flutter 3.24). Se der tela branca ou erro de wasm no console, o plano B é `--web-renderer html` em `scripts/compilar.sh`.
- **CSP própria** em `/app/`: acrescenta `'wasm-unsafe-eval'` e `base-uri 'self'` (o painel mantém `base-uri 'none'`).
- `pnpm push` falha com instrução se `public/app/index.html` não existir.
