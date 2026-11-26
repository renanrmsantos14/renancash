-- Tabelas do Meu Banco (Cloudflare D1 / SQLite)

CREATE TABLE IF NOT EXISTS accounts (
  id              TEXT PRIMARY KEY,
  type            TEXT NOT NULL,          -- BANK | CREDIT
  subtype         TEXT,
  name            TEXT,
  number          TEXT,
  balance         REAL,
  credit_limit    REAL,
  available_limit REAL,
  due_date        TEXT,
  closing_date    TEXT,
  minimum_payment REAL,                   -- pagamento mínimo da fatura aberta
  overdraft_limit REAL,                   -- cheque especial contratado
  overdraft_used  REAL,                   -- cheque especial em uso
  auto_invested   REAL,                   -- saldo aplicado automaticamente
  bank            TEXT,
  item_id         TEXT,
  updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS transactions (
  id          TEXT PRIMARY KEY,
  account_id  TEXT NOT NULL,
  date        TEXT NOT NULL,              -- YYYY-MM-DD
  description TEXT,
  amount      REAL NOT NULL,
  type        TEXT,                       -- DEBIT | CREDIT
  status      TEXT,                       -- POSTED | PENDING
  category    TEXT,
  merchant    TEXT,
  scheduled   INTEGER NOT NULL DEFAULT 0, -- 1 = parcela futura
  bill_id     TEXT,                       -- fatura do Pluggy (creditCardMetadata.billId)
  bill_month  TEXT,                       -- AAAA-MM da fatura em que a compra cai (billForecastDate)
  contraparte TEXT,                       -- nome de quem recebeu/pagou (paymentData)
  metodo      TEXT,                       -- PIX, TED, BOLETO...
  entre_minhas INTEGER,                   -- 1 = a outra ponta é o próprio titular
  tipo_credito TEXT,                      -- REVOLVING_CREDIT, BILL_INSTALLMENT, ANNUAL_FEE...
  updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tx_date ON transactions(date);
CREATE INDEX IF NOT EXISTS idx_tx_account_date ON transactions(account_id, date);

-- Transações que o banco apagou (webhook transactions/deleted): o pull manda os ids para os apps apagarem também.
CREATE TABLE IF NOT EXISTS transacoes_removidas (
  id          TEXT PRIMARY KEY,
  removida_em TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tx_removidas ON transacoes_removidas(removida_em);

CREATE TABLE IF NOT EXISTS snapshots (
  key        TEXT PRIMARY KEY,            -- ex.: faturas:<account_id>, avisos
  data       TEXT NOT NULL,               -- JSON
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  origem      TEXT,                       -- cron | botao
  started_at  TEXT NOT NULL,
  finished_at TEXT,
  ok          INTEGER,                    -- NULL = rodando, 1 = ok, 0 = erro
  message     TEXT
);

-- Dados do usuário, sincronizados com os apps (categorias, regras, orçamentos, metas, dívidas, assinaturas,
-- ajustes de transação, lançamentos manuais). Formato de `dados` por tabela: packages/core/src/sync.ts.
-- updated_at = relógio do cliente (last-write-wins); server_at = relógio do servidor (cursor do pull).
CREATE TABLE IF NOT EXISTS registros (
  tabela     TEXT NOT NULL,
  id         TEXT NOT NULL,
  dados      TEXT,                        -- JSON; NULL quando excluído
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  server_at  TEXT NOT NULL,
  PRIMARY KEY (tabela, id)
);
CREATE INDEX IF NOT EXISTS idx_registros_server ON registros(server_at);

-- Ajustes no formato antigo (category/gasto) para as consultas do painel. A sincronização do Pluggy nunca mexe aqui.
-- updated_at = server_at (o cursor de /api/app/transacoes é do servidor); excluído fica com category/gasto NULL (dados NULL)
-- para a exclusão também chegar ao pull incremental. DROP + CREATE: rodar o schema de novo atualiza a view.
DROP VIEW IF EXISTS v_ajustes;
CREATE VIEW v_ajustes AS
  SELECT id AS transaction_id, json_extract(dados, '$.category') AS category, json_extract(dados, '$.gasto') AS gasto, server_at AS updated_at
  FROM registros WHERE tabela = 'ajustes';

-- Conexões do Pluggy (items). Substitui o secret PLUGGY_ITEM_IDS, copiado daqui na primeira sincronização.
CREATE TABLE IF NOT EXISTS pluggy_items (
  id         TEXT PRIMARY KEY,
  conector   TEXT,
  status     TEXT,                        -- status do item no Pluggy (UPDATED, LOGIN_ERROR, ...)
  criado     TEXT NOT NULL,
  atualizado TEXT,
  proximo_sync TEXT,                      -- nextAutoSyncAt
  consentimento_expira TEXT,              -- consentExpiresAt (Open Finance)
  removido   TEXT
);

-- Configuração do ciclo: chave "limite" (número) e "salario" (descrição normalizada do crédito do salário).
CREATE TABLE IF NOT EXISTS config (
  chave TEXT PRIMARY KEY,
  valor TEXT NOT NULL
);
-- Inscrições de Web Push do navegador (só o endpoint: o push vai sem conteúdo).
CREATE TABLE IF NOT EXISTS push_inscricoes (
  endpoint TEXT PRIMARY KEY,
  criada   TEXT NOT NULL
);
-- Alertas. A chave única evita repetir (ex.: limite80:2026-11-05). enviada_em = push enviado; entregue_em = mostrado pelo service worker.
CREATE TABLE IF NOT EXISTS notificacoes (
  chave       TEXT PRIMARY KEY,
  titulo      TEXT NOT NULL,
  corpo       TEXT NOT NULL,
  criada      TEXT NOT NULL,
  enviada_em  TEXT,
  entregue_em TEXT
);
CREATE INDEX IF NOT EXISTS idx_notif_criada ON notificacoes(criada);

-- Tokens de aparelho (app Android). Só o SHA-256 (hex) do token é guardado; o token em claro aparece uma vez, na criação.
CREATE TABLE IF NOT EXISTS app_tokens (
  id        TEXT PRIMARY KEY,
  nome      TEXT NOT NULL,
  hash      TEXT NOT NULL UNIQUE,
  criado    TEXT NOT NULL,
  ultimo_uso TEXT,
  revogado  TEXT
);

-- Espelho completo do app: a linha inteira de cada tabela em JSON. Conflito por linha (LWW): vence o updated_at mais novo,
-- empate para o maior `aparelho`. Excluída = dados NULL + deleted_at (tombstone). server_at é o cursor de leitura.
CREATE TABLE IF NOT EXISTS espelho (
  tabela     TEXT NOT NULL,
  pk         TEXT NOT NULL,
  dados      TEXT,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  server_at  TEXT NOT NULL,
  aparelho   TEXT,
  PRIMARY KEY (tabela, pk)
);
CREATE INDEX IF NOT EXISTS idx_espelho_server ON espelho(server_at, tabela, pk);
-- Estado do espelho: semeado, semeado_por, semeado_em (e semeando, durante o semeio em lotes).
CREATE TABLE IF NOT EXISTS espelho_meta (
  chave TEXT PRIMARY KEY,
  valor TEXT
);

-- A view v_ajustes_espelho foi removida: o SQLite materializava a view e a junção virava O(tx x espelho). deTx (espelho.js) junta direto em `espelho`.
DROP VIEW IF EXISTS v_ajustes_espelho;

-- Conector MCP (claude.ai): clientes do registro dinâmico e códigos/tokens OAuth (só o SHA-256; expira em epoch segundos).
CREATE TABLE IF NOT EXISTS mcp_clientes (
  id       TEXT PRIMARY KEY,
  nome     TEXT NOT NULL,
  destinos TEXT NOT NULL,                 -- JSON: redirect_uris
  criado   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS mcp_oauth (
  hash    TEXT PRIMARY KEY,
  tipo    TEXT NOT NULL,                  -- codigo | acesso | refresh
  cliente TEXT NOT NULL,
  dados   TEXT,                           -- código: { destino, desafio }
  expira  INTEGER NOT NULL,
  criado  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mcp_oauth_expira ON mcp_oauth(expira);

-- Gastos contados ao Claude antes de o banco lançar. pendente -> vinculada (ligada a transacao_id) -> aplicada (gravada no espelho).
CREATE TABLE IF NOT EXISTS anotacoes (
  id           TEXT PRIMARY KEY,
  valor        REAL NOT NULL,             -- positivo
  data         TEXT NOT NULL,             -- AAAA-MM-DD
  receita      INTEGER NOT NULL DEFAULT 0,
  descricao    TEXT NOT NULL,
  titulo       TEXT,
  categoria    TEXT,                      -- category_pk do app
  subcategoria TEXT,
  nota         TEXT,
  conta        TEXT,
  status       TEXT NOT NULL DEFAULT 'pendente', -- pendente | vinculada | automatica (ligada pela IA, aguardando aplicar) | aplicada | descartada
  transacao_id TEXT,                      -- id da transação do banco (transactions.id)
  criada       TEXT NOT NULL,
  atualizada   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_anotacoes_status ON anotacoes(status, data);

-- IA automática (docs/ia-automatica-plano.md). Memória por favorecido: chave = mbChavePadrao da descrição do banco; a mesma
-- escolha confirmada pelo usuário soma 1, outra escolha troca e volta a 1; Desfazer zera (deixa de aplicar sozinha).
CREATE TABLE IF NOT EXISTS ia_memoria (
  chave           TEXT PRIMARY KEY,
  category_fk     TEXT NOT NULL,
  sub_category_fk TEXT,
  nome            TEXT,                   -- título escrito pelo usuário (null = mantém o do banco)
  confirmacoes    INTEGER NOT NULL DEFAULT 1,
  atualizado_em   TEXT NOT NULL
);
-- Uma decisão por transação do banco. pendente (espera a linha mb: no espelho) -> aplicada -> desfeita; sombra = sugestão do
-- Llama só registrada (acerto 1/0 quando o usuário classifica); descartada = a linha já tinha sido editada pelo usuário.
CREATE TABLE IF NOT EXISTS ia_aplicacoes (
  tx_id         TEXT PRIMARY KEY,         -- transactions.id (linha do espelho = 'mb:' || tx_id)
  origem        TEXT NOT NULL,            -- memoria | regra | llama | anotacao | devolucao
  chave         TEXT,                     -- ia_memoria.chave
  sugestao      TEXT,                     -- JSON {name, category_fk, sub_category_fk, note?}; devolucao: {reembolso_de, compra}
  confianca     REAL,
  status        TEXT NOT NULL,            -- pendente | aplicada | sombra | desfeita | descartada
  anterior      TEXT,                     -- JSON {name, category_fk, sub_category_fk, date_time_modified} antes da aplicação
  depois        TEXT,                     -- JSON do que foi gravado
  acerto        INTEGER,
  criado_em     TEXT NOT NULL,
  aplicado_em   TEXT,
  atualizado_em TEXT NOT NULL,
  avisada_em    TEXT                      -- push em lote já enviado
);
CREATE INDEX IF NOT EXISTS idx_ia_aplicacoes_status ON ia_aplicacoes(status, atualizado_em);
CREATE INDEX IF NOT EXISTS idx_ia_aplicacoes_aviso ON ia_aplicacoes(tx_id) WHERE aplicado_em IS NOT NULL AND avisada_em IS NULL;
