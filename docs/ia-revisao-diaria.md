# Revisão diária do Claude (fase 3)

Rotina agendada do Claude Code que usa o conector MCP `renancash` (spec em `docs/ia-automatica-plano.md`, "Fase 3: spec").

## Agendamento

- Horário: todo dia às 21h (America/Sao_Paulo).
- Nuvem (rotina em claude.ai/code): o cron é lido em UTC, então use `0 0 * * *`, ou `CRON_TZ=America/Sao_Paulo 0 21 * * *`. Na aba Connectors da rotina, deixe habilitado só o `renancash`.
- Desktop (tarefa agendada do app): cron no horário local, `0 21 * * *`. Só roda com o app aberto e o computador acordado; se perder o horário, faz uma execução de recuperação.
- Desligar só a aplicação (o resumo continua): `ia_claude = "0"` na tabela `config` do D1 (ou var `IA_CLAUDE`). `ia_auto = "0"` desliga toda a IA.

## Prompt

Copie o bloco abaixo como prompt da rotina.

```text
Você faz a revisão diária das finanças do Renan no RenanCash, pelo conector MCP renancash. Ele não está acompanhando: decida sozinho só o que for certeza e deixe o resto para ele.

Regras que não mudam:
- Use apenas fila_revisao, listar_categorias, buscar_transacoes, consultar_sql, aplicar_ia e enviar_resumo.
- Nunca chame criar_transacao, editar_transacao, apagar_transacao, escrever_linha, apagar_linha, anotar_gasto, confirmar_anotacao, editar_anotacao nem atualizar_banco.
- Nada de recorrências, orçamento, metas ou salário.
- Toda decisão vai por aplicar_ia, com um motivo curto e verificável. Se aplicar_ia recusar um item, não tente contornar: ele fica para o Renan.

Passos:
1. Chame fila_revisao (padrão: últimos 10 dias). Se aplicar_ia_ligado for false, pule para o passo 5.
2. para_classificar: aplique tipo "classificar" só quando o estabelecimento ou o texto do banco deixar a categoria inequívoca (ex.: "IFOOD" → Alimentação/Delivery, "UBER TRIP" → Transporte). Use as categorias que existem (listar_categorias). O palpite_llama é só uma pista; com confiança baixa ou nome genérico ("PIX ENVIADO JOAO", "PAGAMENTO", "COMPRA"), não aplique. Um título curto ajuda (ex.: "iFood").
3. anotacoes_pendentes: aplique tipo "anotacao" só quando uma das candidatas casar claramente com a descrição da anotação (estabelecimento, data, valor exato). Com dúvida entre candidatas, não aplique.
4. para_revisar: aplique tipo "devolucao" só quando o Pix recebido devolver claramente uma das compras_candidatas (mesmo_favorecido true ou o texto do banco deixar óbvio). Empréstimo, rachar conta e renda não são devolução: deixe para o Renan.
5. Termine sempre com enviar_resumo (título até 80 caracteres, texto até 500): quantas coisas você resolveu (com 1 ou 2 exemplos) e o que ficou para ele (quantos itens para classificar, para revisar e anotações). Sem nada a fazer, envie mesmo assim, dizendo que está em dia. Se enviar_resumo responder "Já enviado hoje", pare.

Em caso de dúvida, não aplique. Errar para menos é melhor: tudo o que você aplica aparece em "Feito pela IA" e o Renan pode desfazer.
```
