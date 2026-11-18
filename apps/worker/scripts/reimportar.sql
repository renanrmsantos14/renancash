-- Reimportação do zero: apaga só o que a sincronização importa do Pluggy.
-- Preserva config (limite, salário/ciclo), app_tokens, push_inscricoes, notificacoes e ajustes
-- (os ajustes ficam órfãos: os ids de transação do Pluggy são novos).
-- Faça backup antes: wrangler d1 export meu-banco --remote --output=backup-AAAA-MM-DD.sql
-- Depois: wrangler d1 execute meu-banco --remote --file=scripts/reimportar.sql e clique em "Atualizar" no painel.
DELETE FROM transactions;
DELETE FROM accounts;
DELETE FROM snapshots;   -- faturas:<conta> e avisos
DELETE FROM sync_log;
