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

-- Ajustes feitos no painel (categoria trocada e/ou "não é gasto"). A sincronização nunca mexe nesta tabela.
CREATE TABLE IF NOT EXISTS ajustes (
  transaction_id TEXT PRIMARY KEY,
  category       TEXT,                    -- NULL = mantém a categoria original
  gasto          INTEGER,                 -- NULL = regra automática | 1 = é gasto | 0 = não é gasto
  updated_at     TEXT NOT NULL
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
