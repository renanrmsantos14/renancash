-- Roda UMA vez no D1 remoto, depois de `pnpm db:remote`: copia a tabela antiga `ajustes` para `registros`
-- e a remove. Rodar de novo falha em "no such table: ajustes", sem efeito.
-- json_patch('{}', …) descarta as chaves nulas: {category:null, gasto:0} vira {"gasto":0}.
CREATE TABLE IF NOT EXISTS registros (
  tabela TEXT NOT NULL, id TEXT NOT NULL, dados TEXT, updated_at TEXT NOT NULL, deleted_at TEXT, server_at TEXT NOT NULL,
  PRIMARY KEY (tabela, id)
);
INSERT OR IGNORE INTO registros (tabela, id, dados, updated_at, deleted_at, server_at)
  SELECT 'ajustes', transaction_id, json_patch('{}', json_object('category', category, 'gasto', gasto)), updated_at, NULL, updated_at FROM ajustes;
DROP TABLE ajustes;
