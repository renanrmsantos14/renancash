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
