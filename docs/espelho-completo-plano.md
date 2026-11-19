# Espelho completo do RenanCash — plano

Decisões do usuário (18/11/2026): nuvem (D1) é a única verdade; cada linha de cada tabela sincroniza inteira; escrita otimista com fila; tempo real por Durable Object + WebSocket (fallback pull 60 s); conflito por linha, vence o `updated_at` mais novo; troca única com o APK como verdade (a web nunca semeia); dados iguais e aparência local; ciclo, alertas e notificações do Worker migram para o espelho.

Decisões complementares (18/11): o painel antigo do Worker perde a edição (`PUT /api/ajustes` desativado; fica só leitura); as marcações de Classificar (revisados, padrões) e Arrumar (juntados) sincronizam (descobrir onde vivem e incluir na allowlist); `username`, `outlinedIcons` e `colorTintCategoryIcon` sincronizam (não entram em `mbConfigsLocais`).

Volume real (backup do APK, 18/11): ~690 transações, 69 categorias, 193 títulos associados, 7 metas, 6 carteiras, 1 orçamento, 11 aplicações de meta. Primeira carga ≈ 1.000 linhas: cabe folgado no D1 grátis.

## 1. Desenho

### 1.1 D1 (`apps/worker/schema.sql`, idempotente)
```sql
CREATE TABLE IF NOT EXISTS espelho (
  tabela TEXT NOT NULL, pk TEXT NOT NULL,
  dados TEXT,                 -- JSON da linha inteira; NULL se apagada
  updated_at TEXT NOT NULL,   -- ISO ms do aparelho (corrigido se vier do futuro)
  deleted_at TEXT,
  server_at TEXT NOT NULL,    -- ISO ms do servidor; cursor
  aparelho TEXT,
  PRIMARY KEY (tabela, pk));
CREATE INDEX IF NOT EXISTS idx_espelho_server ON espelho(server_at, tabela, pk);
CREATE TABLE IF NOT EXISTS espelho_meta (chave TEXT PRIMARY KEY, valor TEXT); -- semeado, semeado_por, semeado_em
```
`registros` fica como histórico; para de receber escrita do app na F5.

### 1.2 API (rotas de aparelho, `rotaAparelho`; Bearer ou cookie)
- `POST /api/espelho` `{aparelho, linhas:[{tabela, pk, dados|null, updated_at, deleted_at}]}` — até 500 linhas, 16 KB/linha; tabela fora da allowlist é rejeitada; `updated_at` > agora + `FOLGA_RELOGIO_MS` vira agora; LWW em SQL via `json_each` (padrão do `SQL_ENVIAR` de `sync.js`); empate → maior `aparelho`. Quando o envio vence, junta as colunas novas sobre as antigas (aparelho com schema antigo não apaga coluna nova; null explícito precisa ser preservado → testar `json_patch`, senão `json_group_object` sobre `json_each` das duas versões). Antes do semeio: 409 `{erro:"nao_semeado"}`. Resposta `{aceitos, rejeitados:[{tabela,pk,motivo}], cursor}`; depois `ctx.waitUntil(avisar({tipo:"mudou", cursor, aparelho}))`.
- `GET /api/espelho?desde=<server_at|tabela|pk>&limite=2000` → `{linhas, cursor, mais, semeado}`; paginação por `(server_at, tabela, pk) > cursor`, com tombstones; sem `baseCiclo`.
- `POST /api/espelho/semear` — só Bearer de aparelho (cookie → 403). Lotes `{lote, linhas, fim}`; se já `semeado` → 409, salvo `substituir:true`. Primeiro lote limpa o espelho; o último grava `semeado`.
- `GET /api/espelho/ws` — upgrade repassado ao DO `EspelhoHub` (`idFromName("principal")`). Autenticação no Worker antes de repassar: Android com `Authorization: Bearer` (`IOWebSocketChannel` aceita headers); web com cookie `sessao` + `Origin` igual à origem do app (sem Origin válido → 403). Plano B: `POST /api/espelho/ticket` devolve ticket HMAC de 60 s em `?t=`.

### 1.3 Durable Object `EspelhoHub` (`apps/worker/src/hub.js`)
SQLite backend (`new_sqlite_classes`, obrigatório no grátis), Hibernation API (`ctx.acceptWebSocket`, `webSocketMessage`, `webSocketClose`), `setWebSocketAutoResponse("ping","pong")`. `fetch("/avisar")` interno faz broadcast de `{tipo:"mudou", cursor, aparelho}` ou `{tipo:"banco"}`; o cliente ignora `mudou` do próprio aparelho. Não guarda dados. `wrangler.toml`: `[[durable_objects.bindings]] name="ESPELHO_HUB" class_name="EspelhoHub"` + `[[migrations]] tag="v1" new_sqlite_classes=["EspelhoHub"]`; exportar de `src/index.js`. `sincronizar` (Pluggy) e o cron avisam `{tipo:"banco"}`. CSP: `connect-src` precisa cobrir `wss:` da própria origem.

### 1.4 Schema local (criado em `beforeOpen`, fora das migrações Drift)
- `mb_saida(tabela, pk, em, PRIMARY KEY(tabela,pk))` — fila coalescida.
- `mb_espelho_ctl(id INTEGER PRIMARY KEY CHECK(id=0), aplicando INTEGER)` — flag dos triggers (em `main`; trigger não vê `temp`).
- `mb_apagados(tabela, pk, em, PRIMARY KEY(tabela,pk))` — o mapeador `mb:` não recria o que foi apagado.
- `mb_revisoes(pk TEXT PRIMARY KEY, dados TEXT)` — substitui as revisões de `mb_registros` (`tx:<id>`, `dest:<nome>`).
- Estado: `espelho_cursor`, `espelho_aparelho` (UUID), `espelho_pronto` em `mb_estado`.
- Triggers gerados por `PRAGMA table_info` para cada tabela espelhada (INSERT/UPDATE/DELETE):
  ```sql
  CREATE TRIGGER IF NOT EXISTS mb_esp_<t>_upd_<hash> AFTER UPDATE ON <t>
  WHEN (SELECT aplicando FROM mb_espelho_ctl WHERE id=0)=0 AND (OLD.c1 IS NOT NEW.c1 OR ...)
  BEGIN INSERT INTO mb_saida VALUES('<t>', <pk_expr>, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    ON CONFLICT(tabela,pk) DO UPDATE SET em=excluded.em; END;
  ```
  Fora da comparação/envio: `date_time_modified`, `method_added`, `shared*` (reaproveitar `mbLinhaSem` de `linha.dart`). Hash da lista de colunas no nome: `beforeOpen` apaga `mb_esp_*` de hash diferente e recria; `onUpgrade` derruba todos os `mb_esp_*` no início.
- Allowlist (igual nos dois lados): `wallets, transactions, categories, category_budget_limits, associated_titles, budgets, scanner_templates, objectives`, `mb_orcamento_tx`, `mb_meta_aplicacao` (pk = JSON das chaves compostas), `mb_revisoes`, e a entidade virtual `_config`. Fora: `app_settings` (cópia), `delete_logs`, `mb_registros`, `mb_aplicado`, chaves derivadas de `mb_estado`.
- `_config`: uma linha por chave (`pk`=chave, `dados`=`{"v":valor}`), ligada em `updateSettings()` (`settings.dart`): chave fora de `mbConfigsLocais` grava em `mb_saida('_config', chave)`; aplicar remoto chama `updateSettings(chave, v, sincronizar:false)`.
- `mbConfigsLocais` (denylist com prefixos; o resto sincroniza): theme, temaPronto, accentColor, acento, accentSystemColor, materialYou, font, increaseTextContrast, appAnimations, animationSpeed, batterySaver; `widget*`, `homePageOrder*`, `show*` de Início/FullScreen, `customNavBarShortcut*`, expandedNavigationSidebar; locale e formato de números; haptic, notificações, requireAuth, selectedWalletPk; contadores, dicas, premium, backup, login, `*SetFiltersString`, `*LastPage`, meuBancoDesde, databaseJustImported. A allowlist `mbConfigsSincronizadas` sai.

### 1.5 Cliente (`budget/lib/struct/mbSync/espelho.dart`)
- Push: lê `mb_saida` em lotes de 500; `SELECT * FROM <t> WHERE <pk>` (ausente → tombstone); remove colunas excluídas; `updated_at = em`; POST; depois `DELETE FROM mb_saida WHERE tabela=? AND pk=? AND em=?` (edição feita durante o envio não se perde). Rejeitado por LWW sai da fila; o pull traz a vencedora.
- Pull: `GET desde=cursor` enquanto `mais`; grava o cursor só depois de aplicar.
- Aplicar (uma transação): `aplicando=1`; UPSERT `INSERT ... ON CONFLICT(pk) DO UPDATE SET` só nas colunas locais (PRAGMA em cache; nada de `INSERT OR REPLACE`, que dispara DELETE); tombstone → DELETE + `mb_apagados`; pular linha com `mb_saida.em > updated_at` remoto; `aplicando=0`. Valores crus do SQLite (DateTime inteiro), sem conversão.
- Agendador (`agendador.dart`): debounce 2 s após mudança em `mb_saida`; `mudou` no WS → pull imediato; pull 60 s; backoff 5/15/60 s. `banco`, abrir o app ou 15 min → pull do banco (`/api/sync`, que continua alimentando contas, faturas, ciclo e o mapeador `mb:`).
- WS: `web_socket_channel` (já no lock). Android `IOWebSocketChannel` com header; web `HtmlWebSocketChannel` em `wss://<origem>/api/espelho/ws`. Reconexão 1–60 s, ping 30 s; Android só em primeiro plano.

### 1.6 Transações `mb:`
O mapeador continua no app e as linhas `mb:` são espelhadas como qualquer outra. `mbMapearPull`/`_aplicar`: insere só se não existe localmente e não está em `mb_apagados`; atualiza só colunas vindas do banco (amount, date_created, original_date_due, wallet_fk, income, marca "Pendente", name/note se o usuário não editou) e só quando diferem. `dateTimeModified` fixo em 2000 e `_semEdicao` deixam de ser necessários. Revisão edita a linha direto (categoria ou tombstone) e grava em `mb_revisoes`; o "repuxar" sai. Ping-pong evitado por valores iguais + WHEN do trigger.

### 1.7 Servidor lendo o espelho
`registrosDoEspelho(db)` (`apps/worker/src/espelho.js`) projeta, só leitura, o mesmo formato que `baseCiclo` lê hoje de `registros`: categorias ← `categories`; regras ← `associated_titles`; orçamentos ← `budgets` + `category_budget_limits`; metas ← `objectives`; revisões ← `mb_revisoes`; ajustes derivados das linhas `mb:` de `transactions` (`category_fk`→`categoria_id`, tombstone `mb:`→`{gasto:0}`, `orcamento_ids` de `mb_orcamento_tx`); `config` (limite, salario, salario_valor) de `_config` com fallback na tabela `config`. `ciclo.js`, `alertas.js` e `revisao.js` não mudam.

### 1.8 Semeio e troca única
1. Publicar Worker e web com o espelho ligado e o servidor sem `semeado`. A web vê `semeado:false`, mostra "Aguardando o celular enviar os dados", não escreve nem semeia.
2. APK novo, primeiro boot: confirmação "Este celular vira a fonte oficial" → `/semear` em lotes → cursor → triggers → `espelho_pronto`.
3. Web (e qualquer outro aparelho) recebe `semeado:true` (WS ou pull) → apaga o local (`mbLimparDadosLocais` adaptado), baixa tudo, `espelho_pronto`.
4. Na F5 sai o botão "Enviar tudo como oficial" (`meuBancoPage.dart`) e `oficial.dart`; fica "Recomeçar pela nuvem".

## 2. Fases (cada uma testável e mergeável)

### F1 — Worker: espelho + DO, atrás de flag `env.ESPELHO`
Arquivos: `apps/worker/schema.sql`; `apps/worker/src/espelho.js` (novo: `enviarEspelho`, `puxarEspelho`, `semear`, `registrosDoEspelho`, allowlist); `apps/worker/src/hub.js` (novo); `apps/worker/src/index.js` (rotas, `ROTAS_APARELHO`, upgrade WS, `export { EspelhoHub }`, aviso `banco`, CSP); `apps/worker/wrangler.toml`; `packages/core/src/sync.ts` (validação do lote, `MAX_LOTE`, `FOLGA_RELOGIO_MS`).
Testes (`apps/worker/test/espelho.test.mjs`, sobre `test/d1.mjs`): LWW, empate, futuro, tombstone; merge de coluna nova; paginação estável com server_at igual; 409 antes do semeio; `/semear` com cookie → 403; WS sem Origin → 403; equivalência `registrosDoEspelho` × `registros` no `resumoCiclo`; DO como classe pura com mocks.
Verificação: `pnpm test`; `wrangler dev` com dois clientes WS e um POST; deploy com flag desligada não muda nada.
Riscos: `json_patch` e null; JSON1 no node:sqlite; cookie no upgrade e CSP `wss:`.

### F2 — App: fila, triggers, push/pull/aplicar e WS, atrás de flag
Arquivos: `budget/lib/struct/mbSync/espelho.dart`, `espelhoTriggers.dart` (novos); `budget/lib/database/tables.dart` (`beforeOpen`/`onUpgrade`); `mbSync/armazem.dart` (DDLs); `mbSync/configuracoes.dart` (`mbConfigsLocais`, `_config`); `budget/lib/struct/settings.dart` (gancho); `mbSync/agendador.dart`; `mbSync/cliente.dart`; `mbSync/linha.dart`.
Testes: `mb_espelho_triggers_test.dart` (insert/update/delete enfileiram; no-op não; `aplicando=1` não; coluna nova recria; onUpgrade); `mb_espelho_aplicar_test.dart` (upsert parcial, tombstone + `mb_apagados`, local mais novo preservado, coluna desconhecida ignorada); `mb_espelho_ciclo_test.dart` (dois bancos Drift em memória + servidor falso com LWW: A→B, offline reenviado, conflito igual dos dois lados); `mb_espelho_config_test.dart`.
Verificação: `flutter test`; `flutter build web` e conferir triggers no sql.js; APK debug contra `wrangler dev`.
Riscos: sql.js regrava o IndexedDB a cada commit (debounce); isolate do workmanager (`mbPrepararIsolate` com o mesmo `beforeOpen`).

Implementado (F2, atrás de `appStateSettings['mbEspelho']`, desligada por padrão e fora do sync):
- Onde ficaram as marcações: vivem em `mb_estado` (chaves `ia_revisados`, `ia_padroes`, `arrumar_juntados`) e viajam na entidade `_config` com pk `estado:<chave>` (`mbEstadoEspelhado` em `espelho.dart`); as demais chaves de `mb_estado` são derivadas e não sincronizam. Gancho: `mbGravarEstado` em `armazem.dart`.
- Lista única de tabelas e DDLs: `mbTabelasEspelhadas` em `espelhoTriggers.dart`. Triggers `mb_esp_<tabela>_{ins,upd,del}_<hash>` derivados do `PRAGMA table_info`; hash novo (coluna nova) recria sozinho em `beforeOpen`; `onUpgrade` derruba antes de migrar.
- Divergências do plano: (1) `mb_espelho_ctl` ganhou a coluna `ativo`: com a flag desligada os triggers não enfileiram e a fila é esvaziada ao desligar, para não crescer sem limite; (2) `mbConfigsLocais` virou a função `mbConfigLocal` (lista exata + prefixos `widget`/`customNavBarShortcut` + sufixos `SetFiltersString`/`LastPage`), e `mbConfigsSincronizadas` continua existindo até a F5; (3) `espelho_pronto` fica para a F3; (4) o isolate do workmanager não abre o banco, então não precisa do `beforeOpen`; (5) [revisto na correção do code-review] o trigger de delete também grava `mb_apagados` e o de insert limpa; o mapeador `mb:` de `meuBancoSync.dart` já filtra por ele quando a flag está ligada; (6) `mb_meta_aplicacao` tem pk simples, não composta; (7) nomes de coluna entre aspas nos triggers e no upsert (`order` é reservada); (8) WebSocket com `web_socket_channel` (cabeçalho Bearer no IO, cookie na web).
- O que a F3 precisa mudar no mapper `mb:` (não mexido na F2; as linhas `mb:` já entram na fila como qualquer outra): inserir só se a linha não existe local nem em `mb_apagados`; no update gravar só as colunas vindas do banco; registrar exclusão local em `mb_apagados`; remover o `dateTimeModified` fixo em 2000 e `_semEdicao` (a edição passa a valer pelo trigger); mover as revisões de `mb_registros` para `mb_revisoes`; remover o "repuxar".

### F3 — Semeio e troca pelo Android
Arquivos: `espelho.dart` (`semearDoCelular`, `substituirPelaNuvem`); `budget/lib/pages/meuBancoPage.dart`; `mbSync/oficial.dart` (`mbLimparDadosLocais`); migração de revisões de `mb_registros` → `mb_revisoes`.
Testes: semear em lotes e retomar após falha; web com `semeado:false` não escreve; substituir apaga e baixa tudo.
Verificação: backup R2/export D1 antes; semear do APK; contagem por tabela D1 × local; totais da Início na web.

### F4 — Ciclo, alertas e push leem o espelho
Arquivos: `apps/worker/src/index.js` (`baseCiclo`, `/api/dados`, `/api/ciclo`, `notificacoesAparelho`, `avaliarAlertas`, `alertaSemanal`, painel antigo), `espelho.js`, `sync.js` (ciclo só no pull do banco).
Testes: adaptar `ciclo-sync.test.mjs`, `alertas.test.mjs`, `revisao.test.mjs`, `notificacoes.test.mjs`; equivalência da F1 vira regressão.
Verificação: `/api/notificacoes` com token do celular devolve as mesmas revisões; resposta pela notificação chega à web.
Risco: projeção de ajustes divergir em estorno e investimento `mb:inv:`.

### F5 — Remover o caminho antigo
Remover: `projetarLocal.dart`, `oficial.dart` (menos `mbLimparDadosLocais`), `detectar.dart`, a aplicação de `registros` em `aplicarLocal.dart`, envio em `meuBancoSync.dart` (`_sincronizarUmaVez`), repuxar, o botão, `POST /api/sync` com registros (410). Manter: pull do banco, Pluggy, IA, notificações, workmanager, `registros` no D1.
Verificação: uma semana de uso real antes de apagar; grep por `mbTornarOficial|projetar|detectarMudancasLocais` vazio.

## 3. Riscos
| Risco | Mitigação |
|---|---|
| Ping-pong `mb:` | Mapeador só grava colunas do banco quando diferem + WHEN contra no-op |
| Relógio errado | Folga de 5 min; futuro vira agora |
| Coluna nova num só aparelho | Merge no servidor; upsert só de colunas conhecidas |
| Trigger quebrar migração | Drop no `onUpgrade`, recriação com hash no `beforeOpen` |
| sql.js lento | Debounce, lotes, um commit por pull |
| Cota D1/DO | Pull sem `baseCiclo`; ping por auto-response |
| Semeio errado | Só Bearer, confirmação, backup antes, `substituir` explícito |
| WS bloqueado | Pull 60 s sempre; ticket como plano B |
| Edição perdida no envio | `DELETE ... WHERE em=?` |

## 4. Não confirmado no planejamento
Limites atuais de D1/DO grátis; `connect-src 'self'` e `wss:`; JSON1/`json_patch` com null no node:sqlite; `aplicarLocal.dart`, `classificarDados.dart`, `arrumarDados.dart`, `backup.js`, `app.js`; índices de `transactions` no D1; isolate do workmanager com o mesmo `beforeOpen`.

## 5. Mudanças de contrato na F1

- Flag `ESPELHO="1"` (var do Worker; desligada por padrão, rotas novas respondem 404). O app pode checar a flag por 404 em `/api/espelho`.
- `aparelho` não vem mais do corpo (o do corpo é ignorado): é o id do token Bearer, e a sessão por cookie é "web". Vale para o desempate do LWW, `semeando`, `semeado_por` e o aviso `mudou`. POST e GET `/api/espelho` (e o semear) devolvem `aparelho` (o id autenticado) para o cliente filtrar o próprio `mudou`.
- `/semear` usa `lote` 0-based, `fim` e `substituir`. Respostas: 409 `ja_semeado` (já semeado, sem `substituir`), 409 `semeio_nao_iniciado` (lote > 0 sem o lote 0 antes), 403 com cookie. O espelho só vira `semeado` no lote com `fim: true`; antes disso o POST responde 409 `nao_semeado`.
- POST `/api/espelho` não devolve mais `cursor` (um cursor global faria o cliente pular linhas de outros aparelhos); o `mudou` leva o cursor só como dica.
- `rejeitados` com `motivo:"mais_antiga"` trazem `atual: {dados, updated_at, deleted_at, aparelho}` (a versão vencedora do servidor) para o cliente aplicar. Reenvio idêntico (mesmo `updated_at` e mesmo aparelho) conta como aceito, sem regravar.
- Janela de sobreposição: o cliente pede a primeira página de cada pull com `desde` recuado 30 s (aplicar repetido é idempotente). No servidor, `server_at` é tirado logo antes do `db.batch` (depois de auth, parse, validação e leitura) para a linha não ficar atrás de um cursor já entregue.
- Merge de colunas feito no Worker (leitura + gravação), preservando o texto JSON dos valores (sem arredondar reais); `{}` nunca vira NULL. Corrida entre dois aparelhos com schemas diferentes pode perder uma coluna; o LWW em si é garantido pelo SQL.
- `semear` com `substituir` não apaga: no `fim`, as linhas vivas que o novo semeio não trouxe viram tombstone (`deleted_at` e `server_at` novos), e os outros aparelhos as recebem pelo cursor.
- Limites de lote e de 16 KB por linha em bytes UTF-8.
- O aviso `{"tipo":"mudou","cursor","aparelho"}` também sai no `fim` do semeio; `{"tipo":"banco"}` sai quando a sincronização do Pluggy dá certo.
- `PUT /api/ajustes/:id` responde 410 com a flag ligada (o painel antigo perde a edição; F4).
- Ticket HMAC do WebSocket (plano B) não foi implementado: Android usa Bearer no cabeçalho e a web usa cookie com checagem de Origin.
- Limite prático: o D1 aceita cerca de 1 MB por comando SQL; o Worker divide o POST em lotes de 1 MB.
- `registrosDoEspelho` projeta categorias, regras, orçamentos, metas, assinaturas, revisões e ajustes (`mb:`). Limitações: o ajuste não leva a categoria aplicada, nome/nota/divida_id, nem `pluggy` das categorias; dívidas não são projetadas.

### Correções do code-review (PR #95)
- Contrato do Worker: o POST não devolve `cursor` (o cliente só adota cursor do GET); `rejeitados` `mais_antiga` traz `atual`, aplicado na hora; rejeição por tamanho ou tabela desconhecida fica em `mb_estado.espelho_rejeitados`; `aparelho` autenticado vem no POST/GET e é guardado em `mb_estado.espelho_aparelho_servidor` (o `mudou` próprio é filtrado por ele); a primeira página de cada pull recua 30 s só no `server_at`.
- `date_time_modified` agora viaja no espelho (fora só da comparação do WHEN do trigger de update), para o outro aparelho não tratar a transação `mb:` como não editada.
- Linha que falha no upsert vai para `mb_espelho_falhas` (JSON) e é reaplicada nos pulls seguintes; contador em `mb_estado.espelho_falhas`.
- `mbEspelhoPrepararBanco` no `beforeOpen` tem try/catch; o hash do nome do trigger cobre o SQL completo; o push é agendado pela mudança em `mb_saida` (debounce 2 s); a config remota faz um único refresh no fim do pull; a flag `mbEspelho` liga e desliga `ativo`, agendador e WS em execução (`mbEspelhoReavaliar`); o backoff do WS só zera depois de 30 s aberto; `mbUriWsEspelho` mantém o prefixo do caminho.

### F3 implementada (semeio e troca pelo Android)
- Liga sozinho: com o Worker em `ESPELHO=1`, `GET /api/espelho` responde e o aparelho decide (`MbEspelho.avaliar`, chamado pelo agendador do espelho em `agendador.dart`); 404 mantém o sync antigo e o espelho desligado. `appStateSettings['mbEspelho']` virou só o desligamento de emergência: `false` desliga tudo; `true` força (desenvolvimento e testes); ausente = automático. `mbEspelhoLigado()` = `mbEspelho != false` e (`mbEspelho == true` ou aparelho pronto).
- Estado: `mb_estado.espelho_pronto = '1'` marca o aparelho pronto (só depois de o semeio ter o `fim` aceito ou de a troca ter baixado tudo); `mb_estado.espelho_semeio` guarda `{lote, ultima, em}` do semeio em andamento; notifiers `mbFaseEspelho`, `mbProgressoEspelho` e `mbEspelhoPronto`. Só `mbEspelhoReavaliar` liga a fila (`mb_espelho_ctl.ativo`).
- Android com `semeado:false`: `EspelhoFase` (main.dart) mostra "Este celular vira a fonte oficial"; ao confirmar, `semearDoCelular` envia em lotes de 500 numerados de 0 (ordem estável tabela, pk; mesma `updated_at` em todo o semeio; `_config` com as configurações que não são de aparência e as marcações), retoma do último lote confirmado e, depois do `fim`, grava cursor, liga a fila e marca `espelho_pronto`. Semeio interrompido retoma sozinho, sem nova confirmação. `ja_semeado` (409) vira troca.
- Web com `semeado:false`: "Aguardando o celular enviar os dados"; não escreve (o servidor também bloqueia o cookie com 403). Abre o WebSocket, e o `mudou` do fim do semeio dispara a troca.
- Aparelho que vê `semeado:true` sem estar pronto: `substituirPelaNuvem` apaga as tabelas espelhadas (menos a carteira e a categoria `0`), `mb_apagados`, a fila, as falhas e o estado do sync antigo (`mb_registros`, `mb_aplicado`, `mb_estado` exceto chaves `espelho_*`), volta `selectedWalletPk` para `0`, baixa tudo do cursor zero e marca pronto. Aparência (`mbConfigLocal`) não é tocada. Se o download cair, o aparelho segue não pronto e a rodada seguinte refaz. `mbTrocarConta` não serve aqui (apagaria `espelho_aparelho`).
- Revisões: `mbMigrarRevisoes` copia as decisões vivas de `mb_registros` para `mb_revisoes` antes do semeio; com o espelho ligado `mbLerEspelho`/`mbGravarEspelho` leem e gravam `revisoes` em `mb_revisoes`.
- Mapper `mb:`: com o espelho ligado o update não reescreve `paid`, `skip_paid` e `method_added`; inserir só se não existe local nem em `mb_apagados` e a exclusão local em `mb_apagados` já vinham da F2.
- Desvios conscientes (para a F4/F5): (1) `_semEdicao` (2000) e o `dateTimeModified` fixo ficam: é o que distingue "nome/nota não editados" no mapper, e agora viaja pelo espelho em `date_time_modified`; (2) o "repuxar" e a categoria no update ficam até a revisão editar a linha direto (F4); (3) o sync antigo segue rodando em paralelo até a F5, e o Worker (`baseCiclo`/`revisar`) segue lendo `registros` antigos até a F4, então decisões novas gravadas só em `mb_revisoes` não chegam a ele até lá.
- Em Configurações > Meu Banco, com o espelho ligado some "Enviar tudo como oficial" e "Recomeçar pela nuvem" usa `substituirPelaNuvem`.
- Correções da revisão (code-review do PR #96): (1) `_recuar` mantém `|tabela|pk` e recua só o `server_at` (o Worker responde 400 a cursor sem o sufixo; o servidor falso agora valida o mesmo regex). (2) Com o espelho ligado o pull do sync antigo descarta as `revisoes` do Worker (não entram em `mb_revisoes`). (3) Android com `semeado:true` pede confirmação (fase `confirmarTroca`, com contagem de pendências de `mb_registros`); a web troca sozinha. (4) Uma trava por banco (`_exclusivo`) cobre enviar, puxar, semear e trocar. (5) `semeio_nao_iniciado` limpa `espelho_semeio` e recomeça do lote 0. (6) `mbEspelhoPronto` é atualizado ao marcar pronto e o sync antigo chama `mbEspelhoCarregarEstado` antes de rodar. (7) "Aguardando o celular enviar os dados" é banner sem bloqueio (o sync antigo segue valendo até o semeio); a sobreposição cobre só confirmações, `semeando`, `trocando` e `erro` ("Tentar de novo" / "Agora não"). (8) A fila (`mb_saida`) liga no início do semeio e `espelho_pronto` não a apaga: edições feitas entre tentativas sobem depois. (9) O 404 fica guardado por 6 h ou até abrir o app. (10) `mbEspelhoPermitido()` é o helper do desligamento de emergência.
