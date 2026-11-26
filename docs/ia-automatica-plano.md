# IA automática no RenanCash

Objetivo: quase nada manual no app. A IA aplica sozinha o que tem certeza, avisa e deixa desfazer; o que é dúvida vai para a fila.

Decidido em 26/11/2026 (sessão de planejamento com o Renan).

## Decisões

| Tema | Decisão |
|---|---|
| Autonomia | Aplica e avisa; com dúvida, pergunta. Tudo desfazível. |
| Motor | Workers AI (Llama 3.3, já em `apps/worker/src/ia.js`) para o volume; Claude via MCP para as dúvidas. |
| Custo | R$ 0 extra (cota do Workers AI + assinatura do claude.ai). |
| Quando aplicar sozinho | Memória do favorecido confirmada 2+ vezes, regra do usuário, ou Llama acima do limiar medido. |
| Llama | 2 semanas em **modo sombra** (registra o que faria, não aplica); depois, limiar definido pela taxa de acerto real (meta ≥ 95% na faixa). |
| Onde roda | No Worker, quando a transação chega da Pluggy. |
| Aviso | Push em lote (respeita silêncio 22h–7h) + lista "Feito pela IA" com Desfazer. |
| Correção | Vira memória na hora (sincronizada) e exemplo para o Llama. |
| Anotações do MCP | Aplica sozinha quando há exatamente 1 candidata compatível (fase 2). |
| Para revisar | Só devolução de compra é automática (fase 2); reembolso e renda continuam perguntando. |
| Empréstimos | IA só sugere a pessoa (fase 2). |
| Claude | Revisão diária às 21h pelo MCP: aplica o que tiver certeza e manda resumo como push do app (fase 3). |
| Fora do escopo | Recorrências, orçamento sugerido, detecção de salário. |

## Fases (um PR cada)

1. **Base**: memória no servidor, classificação automática no Worker, modo sombra do Llama, "Feito pela IA", push em lote.
2. Anotações MCP automáticas, devolução de compra, sugestão de pessoa no empréstimo.
3. Revisão diária do Claude às 21h.

Pré-requisito: PR #124 (conector MCP) mergeado e publicado.

## Fase 1: spec

### Estado atual (conferido no código em 26/11/2026)

- O app cria as linhas `transactions/mb:<id>` do espelho (`budget/lib/struct/meuBancoMapping.dart`); o Worker não cria.
- Sugestão do Llama só na fila "Para classificar", nunca aplicada sem toque (`apps/worker/src/ia.js:213`, `budget/lib/struct/mbSync/classificarDados.dart`).
- Padrão por favorecido fica **só no aparelho** (`mbSugestaoLocal`, `budget/lib/struct/mbSync/classificar.dart:282`).
- Memória de destinatário de Pix já é sincronizada (`dest:<nome>`, `apps/worker/src/revisao.js:5`).
- O MCP já aplica patch em `mb:<id>` e, se a linha ainda não existe, aplica quando o app a envia (`aplicarVinculadas`, `apps/worker/src/mcp.js`; gatilho em `index.js` no `POST /api/espelho`).

### Desenho

1. **Memória no servidor.** Tabela `ia_memoria (chave, categoria_fk, sub_category_fk, nome, confirmacoes, atualizado_em)`, chave = `mbChavePadrao` portada para JS (mesma normalização do app). Alimentada por:
   - confirmação na fila "Para classificar" e edição de categoria de uma `mb:` no app (o Worker detecta no `POST /api/espelho` quando `category_fk` muda numa `mb:` com `date_time_modified >= 978307200`);
   - Desfazer/correção de algo da IA (conta como confirmação do valor novo e zera a anterior).
   - Migração única: o app envia os padrões locais existentes (`mbSugestaoLocal`) para o Worker no primeiro sync.
2. **Decisão na chegada.** Depois de `/api/atualizar` (e do cron), para cada transação nova da Pluggy sem decisão:
   - regra do usuário (`associated_titles`) ou memória com `confirmacoes >= 2` → decisão `aplicar`, origem `memoria`/`regra`;
   - senão, Llama (`sugerir`, em lote) → decisão `sombra` (guarda sugestão e confiança, **não aplica**);
   - falha ou cota do Workers AI → nada; fica na fila como hoje.
   - Grava em `ia_aplicacoes (tx_id, origem, sugestao JSON, confianca, status [pendente|aplicada|sombra|desfeita], anterior JSON, criado_em, aplicado_em)`.
3. **Aplicação.** Mesmo mecanismo das anotações vinculadas: se `mb:<tx_id>` existe no espelho, patch na hora (`name`, `category_fk`, `sub_category_fk`, `date_time_modified` = agora); senão, aplica no próximo `POST /api/espelho` com essa linha. Guarda em `anterior` os valores antes do patch. Não sobrescreve linha já editada pelo usuário (`editadaNoApp`).
4. **Modo sombra.** Quando o usuário confirma/corrige a transação, o Worker compara com a sugestão `sombra` e marca acerto/erro. Endpoint de relatório: acerto por faixa de confiança (0,7–0,8, 0,8–0,9, 0,9–1). Liga o auto-aplicar do Llama por uma config (`ia_limiar`, ausente = desligado).
5. **"Feito pela IA".** `GET /api/ia/aplicadas?desde=` (Bearer) e `POST /api/ia/desfazer {tx_id}` (restaura `anterior`, status `desfeita`, grava correção na memória). Tela no app: lista dos últimos 14 dias com Desfazer e "Corrigir" (abre o editor normal; a edição vira memória).
6. **Push em lote.** Alerta novo em `alertas.js`: "N gastos classificados pela IA" agrupando as aplicações desde o último aviso; usa o silêncio 22h–7h existente; toque abre "Feito pela IA".

### Critérios de aceite

- Gasto de favorecido já confirmado 2x chega pela Pluggy → aparece no app já com nome e categoria, sem passar pela fila, e listado em "Feito pela IA".
- Desfazer restaura nome e categoria anteriores, a transação volta à fila e a memória passa a refletir a correção.
- Favorecido novo → Llama só registra (status `sombra`); a transação segue na fila normal; nada muda no app.
- Linha editada pelo usuário nunca é sobrescrita pela IA.
- Workers AI fora do ar → nenhum erro visível; fila igual a hoje.
- Push em lote: 5 aplicações às 23h → um único push às 7h.
- Relatório de acerto do modo sombra disponível por faixa de confiança.
- Testes no Worker para cada item acima (`node --test`), com flag desligada e ligada do espelho; passo novo em `verificar-worker`.

### Riscos

- LWW: o app pode enviar a linha `mb:` inteira logo depois do patch e apagar a classificação. Mitigação: o patch usa `updated_at` = max(agora, atual + 1 ms) e o app já respeita `date_time_modified`; testar com dois aparelhos.
- A aplicação depende de o app enviar a linha `mb:`; com o app fechado sem sync em segundo plano, a classificação só aparece ao abrir. Não verificado se o APK sincroniza em segundo plano.
- Confiança do Llama é autodeclarada e tende a ser otimista: por isso o modo sombra.
- Fase 3: não verificado se uma tarefa agendada na nuvem do Claude Code acessa o conector personalizado do claude.ai; alternativa é rodar no desktop.

## Fase 2: spec

### Estado atual (conferido no código em 26/11/2026, branch com a fase 1)

- **Anotações.** `candidatas` (`apps/worker/src/mcp.js:85`) busca por valor (tolerância 2%, `TOLERANCIA`, `mcp.js:16`) e data (−3/+7 dias), sinal de gasto/receita, e exclui transações já ligadas a anotação `vinculada`/`aplicada`; devolve `valor_exato`, `pendente_no_banco` e `no_app.ja_editada`. Só `confirmar_anotacao` (`mcp.js:334`) muda para `vinculada`; `aplicarVinculadas` (`mcp.js:122`) grava o patch (`patchDaAnotacao`: `name`, categoria, `note`) **sem** checar `editadaNoApp` e sem `ia_aplicacoes`. `alertasAnotacoes` (`mcp.js:135`) avisa "confirme com o Claude" quando há candidata. As instruções do MCP dizem "Nunca confirme sozinho" (`mcp.js:516`).
- **Fase 1.** `decidirIa` (`apps/worker/src/iaAuto.js:93`) roda no fim da sincronização, antes de `avaliarAlertas` (`apps/worker/src/index.js:899`), e ignora transação que já tem linha em `ia_aplicacoes` (`tx_id` é PK, `apps/worker/schema.sql:202`). `aplicarPendentesIa` (`iaAuto.js:174`) sempre grava `category_fk` e guarda em `anterior` só nome/categoria (`campos`, `iaAuto.js:170`). `desfazerIa` (`iaAuto.js:285`) só sabe restaurar linha `mb:`. `alertaIa` (`apps/worker/src/alertas.js:184`) escreve "N gastos classificados pela IA". Rótulos de origem no app: `rotuloOrigem` (`budget/lib/struct/mbSync/iaAplicadas.dart:34`).
- **Para revisar.** Pix recebido gera `pix_recebido` (`apps/worker/src/revisao.js:33`) com respostas `devolucao` ("Me pagou um empréstimo"), `reembolso` e `renda` (`budget/lib/struct/mbSync/revisao.dart:180`). "Devolução de compra" não existe como resposta: o mecanismo que zera um gasto é `reembolso` com `reembolso_de` = id do gasto (`budget/lib/struct/mbSync/reembolso.dart:1-12`; no Worker, `revisao.js:70,78`). Decisões ficam no espelho, tabela `mb_revisoes`, pk `tx:<id>`, `dados = {pk, dados: "<JSON>"}` (`apps/worker/src/espelho.js:260`, `budget/lib/struct/mbSync/espelhoTriggers.dart:45`). `gravar` (`espelho.js:129`) aceita qualquer tabela e `deleted_at`.
- **Empréstimos.** A pessoa sugerida hoje é o nome do destinatário do Pix (`_nomeSugerido`, `budget/lib/pages/homePage/homePageParaRevisar.dart:224`); "envio ao Santander" e empréstimo sem destinatário abrem com o campo vazio. A decisão `emprestimo` já guarda `destinatario` e `pessoa` (`revisao.dart:297,304`), mas nada lê essa dupla como memória. `dest:<nome>` guarda só categoria (`revisao.js:5`).

### Desenho

Sem tabela nova e sem migração: `ia_aplicacoes` ganha só valores novos de `origem` (`anotacao`, `devolucao`) e `anotacoes` ganha o status `automatica` (comentários do `schema.sql` atualizados). Tudo atrás do kill switch `ia_auto` da fase 1.

1. **Anotação aplicada sozinha** (`mcp.js` + `iaAuto.js`).
   - `vincularAnotacoesIa(env)` (nova, em `mcp.js`, exportando `candidatas`), chamada no início de `decidirIa`, depois de `configIa` e antes da query de transações novas (assim a anotação ganha da memória/Llama na mesma transação).
   - Para cada anotação `pendente` com `data >= hoje − 30`: `c = await candidatas(db, an)`. Liga sozinha só se `c.length === 1` **e** essa candidata tem `valor_exato`, `!pendente_no_banco`, `!no_app?.ja_editada` e a transação não tem linha em `ia_aplicacoes` com status `aplicada`/`desfeita`/`descartada`. Se duas anotações apontam para a mesma única candidata, nenhuma liga. Qualquer outro caso: fica `pendente`, como hoje.
   - Ao ligar (um batch): `UPDATE anotacoes SET status = 'automatica', transacao_id = ?` e `INSERT INTO ia_aplicacoes (tx_id, origem = 'anotacao', chave = <id da anotação>, sugestao = {name, category_fk, sub_category_fk, note}, confianca = 1, status = 'pendente')` com `ON CONFLICT(tx_id) DO UPDATE ... WHERE status IN ('pendente', 'sombra')` (substitui decisão ainda não aplicada; a sombra perde a medição dessa transação).
   - Aplicação: `aplicarPendentesIa` (reuso). Ajustes: o patch só leva `category_fk`/`sub_category_fk` se a sugestão tiver categoria e leva `note` se houver; `campos` passa a incluir `note` (para `anterior`/`depois` e o Desfazer). Depois da reserva, para as de origem `anotacao`: `UPDATE anotacoes SET status = 'aplicada' WHERE id = chave AND status = 'automatica'`. Descartada (linha editada no app): anotação volta a `pendente` com `transacao_id = NULL` (a candidata agora está `ja_editada`, então pede confirmação).
   - `candidatas` exclui também status `automatica`; `listar_anotacoes` aceita `automatica` no enum; `editar_anotacao` numa `automatica`: `desvincular`/`descartar` chamam `desfazerIa` antes. `INSTRUCOES` (`mcp.js:516`): "o app liga sozinho quando há exatamente 1 transação compatível; com 0 ou 2+, mostre as candidatas e confirme".
   - `desfazerIa` com origem `anotacao`: restaura como hoje (agora com `note`), não mexe em `ia_memoria` (troca a condição `dec.origem !== "regra"` por `["memoria", "llama"].includes(dec.origem)`) e volta a anotação para `pendente` com `transacao_id = NULL`. Assumido: depois de desfeita, não liga de novo sozinha (a linha `desfeita` em `ia_aplicacoes` bloqueia); a anotação pede confirmação pelo Claude.
   - Assumido: anotação criada depois de a transação já existir (`candidatas_agora` em `anotar_gasto`) continua pedindo confirmação na conversa; a automática vale só na sincronização. Assumido: a aplicação da anotação não conta como confirmação na `ia_memoria` (memória só aprende com edição no app, como na fase 1).

2. **Devolução de compra automática** (`iaAuto.js`, função nova `decidirDevolucoes(env, ctx)`, chamada em `decidirIa` logo após `vincularAnotacoesIa`).
   - Entrada: transações `t` na janela `DIAS_REIMPORTAR`, conta não cartão, `status != 'PENDING'`, `tipoDeRevisao(t)?.tipo === 'pix_recebido'` (`revisao.js:23`, reuso), sem linha viva `mb_revisoes/tx:<t.id>` e sem linha em `ia_aplicacoes`.
   - Candidatas `c` (mesma consulta para todas): conta não cartão, `c.amount = −t.amount` ao centavo, `c.date` entre `t.date − 30` (`mbJanelaReembolsoDias`) e `t.date`, `scheduled = 0`, não `PENDING`, mesmo favorecido: `nomeDaPessoa(t.description) === nomeDaPessoa(c.description)` (porta de `mbNomeDaPessoa`, `reembolso.dart`; vazio não casa) **ou** `normalizarRevisao(t.contraparte) === normalizarRevisao(c.contraparte ?? c.merchant)` com os dois não vazios. Excluir `c` que já é `reembolso_de` de alguma decisão, que tem decisão `emprestimo`, ou que já é alvo de outra devolução da IA (`ia_aplicacoes.sugestao.reembolso_de`, status `pendente`/`aplicada`).
   - Exatamente 1 candidata e a compra não disputada por outro Pix desta rodada → grava com `gravar` (aparelho `ia`) a linha `mb_revisoes`, pk `tx:<t.id>`, `dados = {pk, dados: JSON.stringify({tipo: "decisao", tx_id, resposta: "reembolso", reembolso_de: c.id, valor, data, descricao, ia: "devolucao"})}` — mesmo formato de `mbRegistrosDeResposta` (`revisao.dart:271`). Não depende da linha `mb:` existir, então já nasce `aplicada`: `INSERT INTO ia_aplicacoes (origem = 'devolucao', sugestao = {reembolso_de, compra: c.description}, anterior = NULL, depois = <decisão>, status = 'aplicada', aplicado_em = agora)`. 0 ou 2+ candidatas: nada, segue na fila. Falha do `gravar`: nada é inserido (tenta na próxima).
   - Assumido: resposta `reembolso` com `reembolso_de` é a representação certa de "devolução de compra" (abate o gasto inteiro na categoria dele, igual ao app); não se cria resposta nova. Assumido: só devolução total (valor exato) e só a partir de conta corrente; estorno de cartão fica como está.
   - `desfazerIa` com origem `devolucao`: lê `mb_revisoes/tx:<id>`; se não existe, foi apagada, ou o JSON difere de `depois` em `resposta`/`reembolso_de` → 412 "Respondida no app depois da IA"; senão grava tombstone (`deleted_at = agora`) via `gravar`. O Pix volta à fila "Para revisar" e não é decidido de novo (linha `desfeita`).
   - `listarAplicadas`: para `devolucao` devolve `depois = {name: "Devolução: <compra>", category_fk: null}` e `tipo: "devolucao"`; o app (`iaAplicadas.dart`) lê `tipo`, `rotuloOrigem` ganha `'anotacao' => 'Anotação'` e `'devolucao' => 'Devolução de compra'`, e `feitoPelaIaPage.dart` esconde "Corrigir" no cartão de devolução (só Desfazer).

3. **Pessoa sugerida no empréstimo** (só app, nada aplicado, nada em `ia_aplicacoes`).
   - `mbPessoaLembrada(Iterable<Map> decisoes, String? destinatario)` em `budget/lib/struct/mbSync/emprestimos.dart`: a `pessoa` da decisão `emprestimo` mais recente (por `data`) com o mesmo `destinatario` e `pessoa` não vazia; senão null.
   - `_nomeSugerido` (`homePageParaRevisar.dart:224`) passa a ser `mbPessoaLembrada(...) ?? <nome do destinatário como hoje>`; vale para `pix_enviado` com categoria Empréstimo e `emprestimo_sem_pessoa`. O campo continua editável e só grava ao tocar em "Criar empréstimo" ou num empréstimo (`mbEscolherPessoaDoEmprestimo`, já existe). Quando vier da memória, o rótulo do campo mostra "Sugestão: usada antes para <destinatário>".
   - Assumido: "envio ao Santander" (sem destinatário) continua sem sugestão; sem Llama nesta fase.

4. **Push em lote.** `alertaIa` (`alertas.js:184`) e `naoAvisadasIa` passam a ler `origem`; se todas forem classificação (`memoria`/`regra`/`llama`/`anotacao`) o título segue "N gastos classificados pela IA"; com alguma `devolucao`, "N itens resolvidos pela IA". Mesmo silêncio 22h–7h e mesmo destino ("Feito pela IA").

### Critérios de aceite

- Anotação "45, almoço" e chega 1 transação de −45,00 postada, não editada → aparece no app com título/categoria/nota da anotação, a anotação fica `aplicada`, item em "Feito pela IA" com origem "Anotação", e não sai o push "confirme com o Claude".
- Mesma anotação com 2 transações compatíveis (ou 1 a −45,50, ou ainda `PENDING`, ou já editada no app) → nada é aplicado; `listar_anotacoes` mostra as candidatas e o push de confirmação sai como hoje.
- Duas anotações de 45 e uma só transação → nenhuma liga sozinha.
- Desfazer de anotação → nome, categoria e nota de antes voltam, a anotação volta a `pendente` sem `transacao_id`, e a próxima sincronização não liga de novo.
- Transação com decisão de memória ainda `pendente` + anotação única → vence a anotação; com memória já `aplicada` → anotação não liga sozinha.
- Pix recebido de R$ 120,00 de "LOJA X" com 1 Pix enviado de −120,00 para "LOJA X" 10 dias antes → sai da fila "Para revisar", decisão `reembolso` com `reembolso_de` na compra, o ciclo deixa de contar a compra, item "Devolução de compra" em "Feito pela IA".
- Duas compras de −120,00 para "LOJA X" na janela, ou valor diferente, ou compra com 31 dias, ou compra já reembolsada → segue na fila, nada gravado.
- Desfazer da devolução → tombstone em `mb_revisoes/tx:<id>`, o Pix volta à fila; se o usuário respondeu no app depois da IA → 412 e nada muda.
- Decisão já existente em `mb_revisoes/tx:<id>` (resposta do usuário) nunca é sobrescrita.
- Pix enviado para "JOAO SILVA" marcado antes como empréstimo da pessoa "Pai" → novo Pix para "JOAO SILVA" na categoria Empréstimo abre o seletor com "Pai" preenchido; nada é gravado sem toque.
- `ia_auto = "0"` → nenhuma das três coisas acontece; fila e anotações iguais a hoje.
- Push: 1 anotação + 1 devolução às 23h → um único push às 7h, "2 itens resolvidos pela IA".
- Testes: `apps/worker/test/ia-auto.test.mjs` (anotação e devolução: 0/1/2 candidatas, disputa, desfazer, kill switch, editada no app) e `mcp.test.mjs` (status `automatica`, exclusão em `candidatas`, `editar_anotacao`); teste Dart de `mbPessoaLembrada`; passos novos em `verificar-worker` e `verificar-pendencias`.

### Riscos

- **Devolução falsa.** Pix recebido do mesmo nome e mesmo valor pode ser outra coisa (a pessoa pagou de volta um empréstimo informal, ou uma venda). Mitigação: valor exato, 1 candidata só, janela de 30 dias, Desfazer; se o relatório mostrar desfazer frequente, desligar só esta parte (proposta: chave `ia_devolucao = "0"` no mesmo `configIa`). Não medido.
- **Nome do favorecido.** A descrição do Pix recebido e a do enviado podem trazer o nome diferente (razão social × nome fantasia); aí não casa e segue perguntando (falha segura). `contraparte` vem do `paymentData` da Pluggy e não verifiquei com que frequência vem preenchido nos dois lados.
- **LWW em `mb_revisoes`.** O app não guarda `updated_at` nessa tabela (`armazem.dart:36`): se o usuário responder o mesmo Pix offline e sincronizar depois, a resposta dele chega com hora posterior e ganha (desejado); a linha `ia_aplicacoes` fica `aplicada` apontando para algo que mudou — o Desfazer responde 412. Testar com dois aparelhos.
- **Anotação × MCP aberto.** Se o Claude chamar `confirmar_anotacao` no mesmo instante em que a sincronização liga a anotação, o `UPDATE ... WHERE status = 'pendente'` condicional precisa ser a única porta (as duas transições usam a condição de status; sem ela, aplicação dupla).
- `aplicarVinculadas` continua sem checar `editadaNoApp` (comportamento atual para confirmação manual); fora do escopo, mas é a mesma classe de risco.

## Fase 3: spec

### Estado atual (conferido no código em 26/11/2026, branch com a fase 2)

- O MCP (`apps/worker/src/mcp.js`) tem 16 ferramentas; nenhuma grava em `ia_aplicacoes`. `editar_transacao` grava como edição do app (aparelho `claude`, `date_time_modified` novo): não aparece em "Feito pela IA" nem tem Desfazer.
- `ia_aplicacoes` (PK `tx_id`) aceita qualquer `origem`; `aplicarPendentesIa` aplica a `pendente` quando a linha `mb:` existe e descarta se foi editada no app; `desfazerIa` restaura `anterior`. A anotação ligada sozinha usa `origem = 'anotacao'` e `chave = <id da anotação>`; a devolução usa `origem = 'devolucao'` e grava `mb_revisoes/tx:<id>`.
- "Para classificar" no app = linhas `mb:` não editadas (`classificarDados.dart`); "Para revisar" = `filaRevisar` (`revisao.js`), exposto ao MCP por `deps.baseCiclo().revisar`.
- Push: `notificacoes` (PK `chave`, `INSERT OR IGNORE`) + `enviarPendentes` (`index.js`, respeita `emSilencio` 22h–7h; o cron das 7h entrega o que ficou). Chave `ia:*` abre "Feito pela IA" (`notificacoesAparelho`; o app só confere `item.tipo`). O push em lote "N gastos classificados pela IA" sai de `naoAvisadasIa` (aplicado e não avisado).
- `configIa` lê `ia_auto`, `ia_limiar` e `ia_devolucao` de `_config` do espelho, tabela `config` e vars `IA_*`.

### Desenho

1. **`fila_revisao {dias?}`** (só leitura; padrão 10, máximo 30). Núcleo em `src/revisaoClaude.js` (importa `iaAuto.js`, `anotacoes.js`, `espelho.js`, `revisao.js`; não importa `mcp.js`).
   - `para_classificar`: transações do banco na janela, `scheduled = 0`, não `PENDING`, linha `mb:` viva e não editada (ou ainda não importada), sem decisão em `ia_aplicacoes` além de `sombra`, e que não sejam `pix_recebido` nem `envio_santander` (essas são do "Para revisar"). Cada item traz texto do banco, valor, conta, título atual no app e, quando houver, o palpite do Llama em sombra (categoria por nome + confiança).
   - `para_revisar`: Pix recebidos de `b.revisar` com as compras candidatas a devolução (valor exato, até 30 dias antes, conta corrente, não usadas por outra devolução/empréstimo), com `mesmo_favorecido`.
   - `outros_para_revisar`: os demais itens de `b.revisar` (só para o resumo; o Claude não decide).
   - `anotacoes_pendentes`: anotações `pendente` com `candidatas` (mesma função da fase 2).
   - `kill_switch`: `{ia_auto, ia_claude}` para o Claude saber se `aplicar_ia` vai recusar.
2. **`aplicar_ia {itens: [...]}`** (até 30 por chamada; resultado item a item, um erro não para os outros). Recusa tudo se o espelho não está pronto, `ia_auto = "0"` ou `ia_claude = "0"`. Grava sempre `origem = 'claude'`, `confianca = 1`, `avisada_em = agora` (o resumo é o aviso; não sai o push em lote) e `sugestao.motivo`.
   - `{tipo: "classificar", tx_id, categoria, subcategoria?, titulo?, motivo}`: categoria por nome ou pk (`resolverCategoria` do MCP + `resolver` do `iaAuto.js`, que confere receita × gasto). Só sem decisão ou com `sombra` (`ON CONFLICT ... WHERE status = 'sombra'`); linha `mb:` editada → recusa. Entra `pendente` e `aplicarPendentesIa` grava na hora (ou quando o app importar a linha).
   - `{tipo: "anotacao", anotacao_id, tx_id, motivo}`: anotação `pendente`, transação entre as `candidatas` dela, não `PENDING`, não apagada nem editada no app, sem decisão `aplicada`/`desfeita`/`descartada`. Mesma transição condicional da fase 2 (`anotacoes.status = 'automatica'`), com `chave = <id da anotação>` e `sugestao.anotacao_id`; o resto (aplicar, descartar, desfazer, `editar_anotacao`) passa a reconhecer a anotação por `anotacaoDe(dec)` (origem `anotacao`, ou `claude` com `sugestao.anotacao_id`).
   - `{tipo: "devolucao", tx_id, reembolso_de, motivo}`: Pix `pix_recebido` em conta corrente, não `PENDING`, sem resposta viva em `mb_revisoes` e sem decisão em `ia_aplicacoes` além de `sombra`; compra com valor exato, até 30 dias antes e não usada. Grava a mesma resposta `reembolso` da fase 2 (`ia: "claude"`) e a linha `aplicada` com `sugestao = {reembolso_de, compra, motivo}`. Aqui o favorecido pode ser diferente (é o que o Claude acrescenta à regra automática).
   - Assumido: o que o Claude aplica não conta como confirmação em `ia_memoria` (`aprenderIa` já ignora o valor aplicado que volta) e o Desfazer não zera memória (só `memoria`/`llama`): um erro do Claude não vira regra automática.
3. **`enviar_resumo {titulo, texto}`**: título até 80 caracteres e texto até 500 (acima disso recusa, para o Claude encurtar). Chave `ia:claude:<dia em SP>` com `INSERT OR IGNORE`: no máximo 1 por dia; o segundo responde `{enviado: false, motivo: "Já enviado hoje"}`. Chama `enviarPendentes` (via `deps`); entre 22h e 7h fica para o cron das 7h. Abre "Feito pela IA". Funciona com `ia_claude = "0"` (o resumo pode dizer só o que ficou pendente).
4. **Kill switch `ia_claude = "0"`** (mesmas três fontes, var `IA_CLAUDE`): desliga só `aplicar_ia`. `ia_auto = "0"` também desliga.
5. **Prompt da rotina** em `docs/ia-revisao-diaria.md`: começar por `fila_revisao`, aplicar só com certeza alta, nunca criar/apagar/editar fora de `aplicar_ia`, terminar com `enviar_resumo`. `INSTRUCOES` do MCP ganha: `aplicar_ia` e `enviar_resumo` são da revisão diária; numa conversa, só com o ok do Renan.
6. **App**: `MbIaAplicada.rotuloOrigem` ganha `'claude' => 'Revisão do Claude'`; o cartão de devolução passa a ser reconhecido por `tipo == 'devolucao'` (que `listarAplicadas` passa a mandar também na devolução do Claude), então o Claude-devolução também esconde "Corrigir".
7. Sem tabela nem coluna nova: só os valores `origem = 'claude'` e `ia_claude` (comentários do `schema.sql`).

### Critérios de aceite

- `fila_revisao` lista um gasto `mb:` não editado sem decisão (com o palpite em sombra, se houver) e não lista o já editado, o já aplicado pela IA, nem Pix recebido.
- `aplicar_ia` classificar → a linha `mb:` muda, item "Revisão do Claude" em "Feito pela IA", Desfazer devolve nome e categoria de antes; `ia_memoria` não muda.
- `aplicar_ia` numa transação editada no app, já aplicada pela memória, desfeita, com categoria de receita num gasto ou com categoria inexistente → recusa daquele item, nada gravado; os outros itens da chamada seguem.
- Anotação pendente com 2 candidatas: `aplicar_ia` anotação na escolhida → título, categoria e nota gravados, anotação `aplicada`; Desfazer volta a anotação para `pendente`. Transação fora das candidatas → recusa.
- Devolução: Pix recebido de 120,00 + compra −120,00 de outro favorecido 10 dias antes → `aplicar_ia` devolução grava `reembolso`; valor diferente, 31 dias ou compra já reembolsada → recusa; Desfazer grava tombstone.
- `ia_claude = "0"` → `aplicar_ia` recusa tudo; `fila_revisao` e `enviar_resumo` funcionam.
- `enviar_resumo` às 21h → 1 notificação `ia:claude:<dia>` e push; segunda chamada no mesmo dia → `enviado: false`; às 23h → gravada sem push (sai às 7h); texto com mais de 500 caracteres → erro.
- As aplicações do Claude não geram o push em lote "N gastos classificados pela IA".
- Testes: `apps/worker/test/revisao-claude.test.mjs`; `budget/test/mb_ia_aplicadas_test.dart` (rótulo e `tipo`); passo 6k em `verificar-worker`.

### Riscos

- **A rotina pode chamar ferramentas que criam ou apagam.** `criar_transacao`, `apagar_*` e `escrever_linha` continuam no MCP (a conversa usa); o servidor não distingue a rotina da conversa (mesmo token OAuth). A restrição fica no prompt. Mitigação possível depois: token próprio para a rotina com lista de ferramentas reduzida. Não feito.
- **Medição do Llama.** Trocar a `sombra` pela decisão do Claude tira aquela transação da taxa de acerto do Llama (o acerto só é medido quando o Renan edita). Volume pequeno; aceitável.
- **Conector na nuvem.** A rotina na nuvem só enxerga o `renancash` se o conector estiver habilitado nela (aba Connectors da rotina). Não verificado se o OAuth do conector customizado funciona dentro da rotina.
- **Ordem do aviso.** Uma classificação `pendente` do Claude cuja linha `mb:` só chega depois do resumo é aplicada sem push próprio (já nasce avisada); aparece em "Feito pela IA".
- **Certeza do Claude.** Não há limiar numérico: depende do prompt e do `motivo` gravado em cada item. `/api/ia/relatorio` só mede o Llama; o acompanhamento é por "Feito pela IA" (rótulo "Revisão do Claude"). Desfazer frequente → `ia_claude = "0"`.
