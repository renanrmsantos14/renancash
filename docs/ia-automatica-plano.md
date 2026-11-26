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
