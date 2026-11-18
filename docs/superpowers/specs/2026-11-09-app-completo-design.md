# Meu Banco: app completo (Android e web), design

- **Data:** 09/11/2026
- **Status:** aprovado na sessão de definição (grilling) de 08–09/11/2026
- **Ponto de partida:** branch `feat/pluggy-direto` (v0.0.7, PRs #1 a #3 empilhados)

## 1. Objetivo

Trocar o fork do Cashew e o painel atual por um produto só, o Meu Banco, que tenha:

- um app Android próprio;
- um web app pensado para desktop;
- a mesma base de dados e a mesma lógica nos dois, ligados ao Pluggy pelo Worker que já existe;
- visual "Editorial tinta", bonito e animado sem exagero.

Usuário único: Renan, com vários aparelhos.

## 2. Escopo da versão 1

| Área | Inclui |
|---|---|
| Contas e saldos | Contas do Pluggy (Inter, Santander), saldo disponível, poupanças |
| Cartão | Fatura aberta, limite, fechamento, vencimento, faturas anteriores |
| Transações | Do Pluggy e manuais; editar categoria, marcar se conta como gasto, dividir |
| Orçamentos | Por categoria, com o período no ciclo do salário ou no mês |
| Metas | Valor-alvo, valor atual e prazo |
| Dívidas | Parcelamentos do cartão (derivados do Pluggy) e empréstimos entre pessoas (cadastro manual) |
| Gráficos | Gasto por dia no ciclo, por categoria, evolução mensal |
| Assinaturas | O app detecta cobranças recorrentes e sugere; vira assinatura só depois da confirmação, e então avisa antes de cada cobrança |
| Alertas | Ver a seção 7 |
| Widget Android | Saldo disponível, gasto no ciclo com medidor e hora da última sincronização |

Fora da v1: mais de um usuário, investimentos, iOS, Open Finance sem o Pluggy.

## 3. Arquitetura

Monorepo pnpm no repositório `meu-banco`:

```
apps/
  worker/   Cloudflare Worker atual (API, cron, D1, Web Push), mais a sincronização e o pareamento
  mobile/   Expo (React Native), Android; Reanimated para animação
  web/      React + Vite, desktop; Motion para animação; build servido pelo próprio Worker (static assets)
packages/
  core/     TypeScript sem dependências: tipos, protocolo de sincronização, ciclo, categorias e regras,
            detecção de assinaturas e parcelamentos
```

- O `core` usa só TypeScript "apagável" (sem enum nem namespace), com imports terminando em `.ts`. Assim o Node 22.18+ roda o código direto, sem build. O esbuild (Wrangler), o Vite e o Metro também importam o `.ts`.
- O Worker continua em JavaScript e importa o `core`.
- O secret do Pluggy fica só no Worker. Os apps nunca falam direto com a API do Pluggy: só abrem o Pluggy Connect com um token temporário que o Worker gera.

```
[Pluggy API] ⇄ Worker ⇄ D1 (fonte da verdade)
                 ⇅ /api/sync (token por aparelho ou cookie de sessão)
        app Android (SQLite + fila)    web desktop (IndexedDB + fila)
```

## 4. Dados e sincronização

### 4.1 Dois tipos de dado

1. **Dados do banco** (`accounts`, `transactions`, faturas em `snapshots`). Só o Worker grava, a partir do Pluggy. Os apps só leem.
2. **Dados do usuário.** Os apps e o painel gravam, nas duas direções. Ficam numa tabela genérica:

```sql
registros (
  tabela     TEXT,  -- categorias | regras | orcamentos | metas | dividas | assinaturas | ajustes | lancamentos
  id         TEXT,  -- gerado no cliente (UUID); em ajustes, é o id da transação
  dados      TEXT,  -- JSON validado pelo core
  updated_at TEXT,  -- relógio do cliente, no momento da edição (vale para o last-write-wins)
  deleted_at TEXT,  -- exclusão lógica (tombstone)
  server_at  TEXT,  -- relógio do servidor, no momento da gravação (vale para o cursor)
  PRIMARY KEY (tabela, id)
)
```

Uma tabela só, porque é um usuário e pouco volume. Assim a sincronização, o last-write-wins e o backup não repetem código por entidade, e quem valida o formato de cada `tabela` é o `core`.

A antiga tabela `ajustes` vira registros `tabela = 'ajustes'`, copiados uma única vez por `migrar-ajustes.sql`, que depois remove a tabela antiga. A view `v_ajustes`, com as mesmas colunas, mantém funcionando as consultas do painel atual (o nome é outro para não colidir com a tabela durante a migração).

### 4.2 Formato de `dados` por tabela

- `categorias`: `{nome, tipo: "despesa"|"receita", cor?, icone?, pai_id?, ordem?, pluggy?: string[]}`. O campo `pluggy` lista as categorias do Pluggy mapeadas para esta.
- `regras`: `{padrao, categoria_id, conta_id?, prioridade?}`. O `padrao` é texto sem diferença de maiúsculas, com `*` como curinga.
- `orcamentos`: `{nome, valor, categoria_ids: string[], periodo: "ciclo"|"mensal"}`
- `metas`: `{nome, valor_alvo, valor_atual?, prazo?}`
- `dividas`: `{tipo: "emprestimo", nome, pessoa?, sentido: "devo"|"me_devem", valor_total, pago?}`. Os parcelamentos não ficam aqui: são derivados das transações do cartão.
- `assinaturas`: `{nome, valor, dia, padrao, status: "confirmada"|"ignorada", categoria_id?}`
- `ajustes`: `{category?, gasto?: 0|1, categoria_id?, nota?}`. Os campos `category` e `gasto` são os de hoje.
- `lancamentos`: `{data, descricao, valor, categoria_id?, carteira?, nota?}`. Em `valor`, negativo é saída.

### 4.3 Protocolo

- **Pull:** `GET /api/sync?desde=<ISO>` devolve:
  - `agora`;
  - `contas`;
  - `transacoes` alteradas;
  - `registros` com `server_at > desde`;
  - `pendentes`;
  - `config`;
  - `faturas`;
  - `avisos`.

  O cliente guarda `agora` e usa como próximo `desde`. O servidor recua 2 minutos a janela (sobreposição), para não perder uma gravação que ainda estava terminando. Os registros repetidos são inofensivos, porque a mesclagem é idempotente. Sem `desde`, o pull é completo e não traz as exclusões.
- **Push:** `POST /api/sync` com `{registros: [...]}`, até 500 por lote:
  - o `core` valida cada registro; um inválido volta em `rejeitados` e não derruba o lote;
  - grava com `ON CONFLICT ... DO UPDATE ... WHERE excluded.updated_at > registros.updated_at`, o last-write-wins por registro; em empate, fica o que já está gravado;
  - um `updated_at` mais de 5 minutos no futuro vira o horário do servidor, para que um relógio adiantado não vença para sempre.
- **Offline:**
  - o app guarda tudo em SQLite e a web em IndexedDB;
  - toda edição entra numa fila local;
  - ao voltar a rede, o cliente faz push da fila e depois pull.
- **Exclusão:** `deleted_at` preenchido. Os tombstones ficam no D1; não há limpeza na v1.

### 4.4 Autenticação

- **Aparelho:**
  - `Authorization: Bearer mb_…`, um token por aparelho;
  - a tabela `app_tokens` já existe: o D1 guarda o SHA-256, e o painel lista e revoga.
- **Web:** cookie de sessão atual; nos POSTs, checagem de mesma origem.
- **Pareamento:**
  - o painel cria o token e mostra um QR com `meubanco://parear?u=<origem>&t=<token>`;
  - o app lê o QR e guarda o token no armazenamento seguro;
  - enquanto o web app novo não existe, o QR fica no painel atual.

## 5. Pluggy

- **Conexões no D1:** a tabela `pluggy_items` substitui o secret `PLUGGY_ITEM_IDS`.
  - Na primeira sincronização, se a tabela estiver vazia, o Worker copia os ids do secret. Depois, o secret pode ser apagado.
- **Conectar um banco:**
  1. O app chama `POST /api/pluggy/connect-token`.
  2. O Worker pede um `accessToken` ao Pluggy (`POST /connect_token`).
  3. O app abre o Pluggy Connect.
  4. No sucesso, o app registra o item em `POST /api/pluggy/items`.
- **Reconectar:**
  - item com erro de login gera o aviso e o alerta "Reconectar";
  - o app abre o Connect em modo de atualização (`connect-token` com `itemId`).
- **Webhook:**
  - `POST /api/pluggy/webhook`, com o secret `PLUGGY_WEBHOOK_SECRET` no cabeçalho `x-webhook-secret`, comparado por hash;
  - responde 200 na hora e trabalha em `waitUntil`;
  - os eventos `item/created`, `item/updated`, `item/error`, `item/waiting_user_input` e `item/login_succeeded` disparam a sincronização;
  - `item/deleted` marca o item como removido;
  - o painel registra o webhook pela rota `POST /api/pluggy/webhooks`.
- **Botão Atualizar:**
  - pede ao banco dados novos (`PATCH /items/{id}`) e depois lê;
  - no máximo uma vez a cada 30 minutos, contando painel e apps juntos;
  - se chamado antes, responde 429 com o horário liberado;
  - quando o Pluggy termina, o webhook faz a leitura final.
- **Cron:** a cada 3 horas, só lê o que o Pluggy já tem; nunca pede atualização ao banco.

## 6. Categorias e regras

- As categorias são do usuário. A categoria de uma transação é a primeira que existir, nesta ordem:
  1. o ajuste manual;
  2. a regra automática que casar (maior prioridade, depois o padrão mais longo);
  3. o mapeamento da categoria do Pluggy;
  4. "Sem categoria".
- A função fica no `core`, e o Worker (alertas de orçamento) e os apps usam a mesma.
- Criar uma regra a partir de uma transação ("Regra automática `DROGASIL*` → Farmácia") é a interação principal do detalhe da transação.

## 7. Alertas e notificações

- **Quando avisa:**
  - limite do ciclo e cada orçamento aos 80% e ao passar de 100%;
  - 3 dias antes de a fatura fechar;
  - quando entra uma receita;
  - quando um banco pede login de novo ("Reconectar");
  - antes de cada cobrança de assinatura confirmada;
  - gasto fora do padrão e resumo semanal, como já existe hoje.
- **Regras gerais:** a chave de cada alerta não repete no mesmo ciclo, e o silêncio vai das 22h às 7h (BRT), como hoje.
- **Entrega:**
  - **Desktop:** Web Push VAPID, como hoje.
  - **Android:** sem Firebase. O app confere em segundo plano (expo-background-task) as notificações pendentes e mostra cada uma como notificação local. A latência é de minutos, o que basta para dados que mudam a cada sincronização.

## 8. Visual: "Editorial tinta"

- **Princípios:**
  - sem cartões: as seções são separadas por um filete de 1px;
  - títulos em serifa itálica;
  - rótulos em versalete pequeno;
  - números grandes em Geist 300, com algarismos tabulares;
  - um azul só, como acento;
  - o vermelho só para alerta.
- **Tokens:**
  - tipografia:
    ```
    --f: 'Geist', system-ui, sans-serif;  --serif: Georgia, 'Iowan Old Style', serif;  --mono: 'Geist Mono'
    h1: italic 400 26px/1.1 serif, tracking -.02em
    h2: 500 12px Geist, uppercase, tracking .08em, cor --mu
    rótulo: 500 11.5px/1.2;  número grande: 300 50px/1 (desktop 64px), tracking -.045em
    ```
  - forma: medidor 2px, sem raio; barras sem raio; botões com raio 8px; marcas de conta 32px com raio 6px;
  - cores claras: `--bg #F7F6F3`, `--surf #FBFBFA`, `--tx #17181C`, `--mu #77767A`, `--line rgba(20,20,30,.08)`, `--acc #2340D8`, `--warn #B42318`, `--warnbg #FDEBEC`, `--warntx #9F2F2D`, `--pos #2F6B3A`, `--chip #E8ECFB`;
  - cores escuras: `--bg #0F1114`, `--surf #15181C`, `--tx #ECEDEF`, `--mu #8D9097`, `--line rgba(255,255,255,.08)`, `--acc #8EA4FF`, `--warn #F0726B`, `--warnbg rgba(240,114,107,.12)`, `--warntx #F59A94`, `--pos #7FCB92`, `--chip rgba(142,164,255,.12)`.
- **Tema:** segue o sistema. O claro e o escuro usam a mesma paleta.
- **Movimento:**
  - curva ease-out `cubic-bezier(.23,1,.32,1)`, sem mola;
  - entrada: subida de 8px com fade, em 420ms, escalonada a cada 55ms;
  - medidores crescem em scaleX (900ms); as barras do gráfico, em scaleY escalonado (28ms);
  - o número do saldo conta até o valor em 900ms;
  - toque: `scale(.97)` em 140–160ms;
  - nada anima em ação de teclado (Ctrl+K, atalhos);
  - `prefers-reduced-motion` desliga tudo.
- **Celular:**
  - a tela Início tem, nesta ordem:
    - ciclo;
    - saudação;
    - "Disponível agora";
    - gasto no ciclo (medidor e barras por dia);
    - contas;
    - cartão;
    - últimas transações;
  - barra inferior com Início, Transações, Orçamentos e Metas.
- **Desktop (layout aprovado):**
  - grade com três colunas: 232px, 1fr e 360px;
  - lateral com a marca em serifa e a navegação (Início, Transações, Orçamentos, Metas, Dívidas, Assinaturas, depois as contas); no rodapé, "Sincronizado há N min" e a versão;
  - topo com busca (Ctrl+K) e Atualizar;
  - painel em duas colunas, com saldo e gráfico, gasto no ciclo, cartão, transações e orçamentos;
  - detalhe fixo à direita, com valor, conta, categoria, Pluggy, fatura, regra automática e histórico, e os botões Dividir e "Mudar categoria" (C);
  - atalhos de teclado.
- **Referências visuais desta sessão:** `meu-banco-desktop-claro.png`, `meu-banco-desktop-escuro.png` e `meu-banco-celular-editorial.png`, em `/home/renan/.t3/userdata/attachments/`.

## 9. Distribuição e versão

- **APK:**
  - gerado no GitHub Actions com `expo prebuild` e Gradle;
  - assinado com a keystore guardada nos secrets do repositório;
  - publicado no GitHub Release;
  - o app compara a versão dele com o último Release e avisa quando há atualização.
- **Web:** `pnpm push` gera o web app e publica junto com o Worker.
- **Versão:**
  - cada app tem versão própria, `vX.Y.Z · dd/mm/aaaa HH:mm` (America/Sao_Paulo), visível num canto de todas as telas;
  - a publicação incrementa o PATCH.

## 10. Backup

- **Diário:** o cron das 06:07 UTC (03:07 BRT) exporta todas as tabelas do D1 em JSON com gzip para o bucket R2 `meu-banco-backups` (`d1/AAAA-MM-DD.json.gz`).
- **Retenção:** uma regra de ciclo de vida do R2 apaga cada arquivo depois de 30 dias.
- **Time Travel:** o do D1 (30 dias) continua valendo.

## 11. Migração

- **Fork do Cashew:**
  - continua em uso até o app novo cobrir o dia a dia, e então é arquivado;
  - o backup do Cashew (arquivo `.sql`, que é um SQLite) é importado para o D1 uma única vez, pelo script `importar-cashew`;
  - o que entra:
    - as categorias;
    - os orçamentos não arquivados;
    - as metas;
    - os empréstimos;
    - as transações manuais;
  - as transações vindas do Meu Banco (`mb:*`) não entram;
  - os ids recebem o prefixo `cashew:`, então rodar de novo não duplica nada.
- **Painel atual:** continua no ar até o web app novo cobrir ciclo, limite e alertas; depois o web app o substitui.
- **`/api/app/transacoes`:** usado pelo fork, continua funcionando até o fork ser arquivado.

## 12. Fases

| Fase | Entrega | Pronto quando |
|---|---|---|
| 1. Base | Monorepo, `core`, `registros` e `/api/sync`, pareamento por QR, Pluggy no D1 (connect token, webhook, Atualizar com limite de 30 min), backup no R2, importação do Cashew | Testes passam; `pnpm push` publica; painel atual sem regressão; pull e push validados com curl e token de aparelho |
| 2. Android | Worker: categoria efetiva no core, dados de parcela e fechamento, alertas novos. App Expo: telas, offline, Connect, widget, conferência em segundo plano, CI do APK e aviso de atualização | APK instalado, pareado por QR, funcionando offline, alertas chegando |
| 3. Web desktop | `apps/web` servido pelo Worker, Web Push, Ctrl+K, detalhe fixo | Cobre ciclo, limite e alertas; o painel antigo sai |
| 4. Encerramento | Fork do Cashew arquivado; `/api/app/transacoes` removido; secret `PLUGGY_ITEM_IDS` apagado | |

Cada fase tem um plano próprio em `docs/superpowers/plans/`.

## 13. Riscos

- **Connect e itens do Meu Pluggy:**
  - **Risco:** os itens conectados pelo meu.pluggy.ai podem não aceitar o modo de atualização do Connect, nem `PATCH /items`, com as credenciais da aplicação.
  - **O que fazer:** se o PATCH falhar, o Worker registra um aviso e só lê; o "Reconectar" continua apontando para meu.pluggy.ai até o Connect ser validado.
- **Cabeçalho no webhook do Pluggy:**
  - **Risco:** o cadastro de webhook pode não aceitar cabeçalhos personalizados.
  - **O que fazer:** se não aceitar, o secret vai na query string (`?s=`), com a mesma comparação por hash. Confira na documentação ao implementar.
- **Relógio dos aparelhos:** o last-write-wins depende do relógio do cliente. A folga de 5 minutos e o empate a favor do que já está gravado limitam o estrago.
- **Notificação no Android sem Firebase:** chega com minutos de atraso, e o sistema pode adiar a tarefa em segundo plano. É aceito para este uso.
- **v1 da API do Pluggy:** vence em 31/12/2026. O código já usa a v2, e a v1 é só fallback.
