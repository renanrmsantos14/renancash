## Qualidade

**Simplificação (3 passadas, `/simplify` + `karpathy-coder`, cirúrgicas; rotas, payloads e DOM/ids intactos)**
- Passada 1 (karpathy-coder): removida asserção vazia (`"hash" in r`) do teste; `revogarToken` ganhou a ordem de parâmetros `(request, env, url)` dos vizinhos e o id sai do grupo de captura da regex, sem `slice(16)` mágico; `abrirApps` não usa mais o fallback `execCommand` (copiar falhando agora avisa e seleciona o campo, em vez de marcar "Copiado").
- Passada 2 (`/simplify`, ângulos reuso/simplificação/eficiência/altitude): `base64url` extraído para `src/app.js` e reutilizado por `gerarToken` e pela assinatura do cookie de sessão (antes duplicado).
- Passada 3: sem mudanças adicionais.

**Framework (`workers-best-practices`, src/)**: sem achados no diff: token via `crypto.getRandomValues`, sem segredo em código, sem estado mutável de requisição em módulo, sem trabalho assíncrono solto (o `UPDATE ultimo_uso` vai no `db.batch` aguardado), sem buffering de corpo grande. Observabilidade (`wrangler.toml`) fora do escopo desta mudança.

**Code review (`/code-review high --fix`)**, foco no Bearer
- Confirmado correto: só o SHA-256 (hex) do token de 256 bits é gravado; busca por igualdade no hash com `revogado IS NULL` (revogação imediata); o bypass de sessão vale só para `GET /api/app/transacoes`, e `GET/POST/DELETE /api/app/tokens` seguem com cookie e Origin; a listagem não devolve `hash` nem token.
- Corrigido: `abrirApps` substituía o sheet de config sem checar limite não salvo ou salvamento em curso (agora bloqueia com aviso); criar novo token com o anterior ainda não copiado perdia o token da tela (agora bloqueia); `SELECT *` em `accounts` virou lista explícita de colunas (não lê `number`/`item_id`); removido `cache-control` redundante (`seguranca()` já força `no-store`); comentário sobre a janela de `desde` corrigido.
- Não corrigido (muda contrato ou escopo; decisão antes de o app consumir):
  1. Janela de perda do `desde`: sincronização em andamento grava `updated_at` do início (< `agora`); a releitura de 10 dias a cada sincronização as recupera na rodada seguinte.
  2. Transações apagadas/recriadas com id novo (parcelas futuras) não são informadas ao app (`ids_pendentes` cobre só pendentes).
  3. `ajuste_gasto` ("não é gasto") não vai na resposta; totais do app podem divergir do painel.
  4. A rota Bearer não tem rate limit (token de 256 bits; risco só de custo/cota).
  5. A sincronização regrava `updated_at` de toda linha relida, então o delta sempre traz ~10 dias.

**Provas**: `pnpm -s test` 22/22; `node --check src/index.js` ok; `wrangler deploy --dry-run` ok; seção 3e da skill `verificar-meu-banco` rodada com mock + `pnpm dev` (D1 local): 401 sem/com cookie/Bearer falso, 400 `desde` inválido, 403 Origin, 400 nome vazio/41 chars, 201 com `{id,nome,token}`, resposta com `agora/contas(2)/transacoes(100)/ids_pendentes`, `desde=agora` -> `[]`, lista sem `hash`/token, revogação 403/404/200 e Bearer 401 depois, `length(hash)` 64; painel a 390px (Playwright): limite sujo bloqueia, token mostrado uma vez, clipboard igual, Esc pede "Descartar alterações?", "Revogar" pede "Confirmar", foco volta a `#cicloConfig`, sem rolagem horizontal e sem erro de console.
