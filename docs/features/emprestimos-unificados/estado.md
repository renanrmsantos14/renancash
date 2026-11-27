# Empréstimos unificados

- Nível: 3 (migra dado financeiro real existente; sem volta fácil se mal feito)
- Etapa: 6 de 7 Revisar (construído e provado local; falta revisão adversarial do diff, PR em rascunho)
- Próximo passo: ciclo 2 da revisão Opus (se necessário), CI do PR, tirar do rascunho · sozinho
- Branch e PR: feature/emprestimos-unificados · PR #129 (rascunho)
- Protótipo: sem protótipo (prévia em texto/cartão; UI mínima dentro de Empréstimos)
- Go: 27/11/2026 via brief da thread e3bee913 (nível 3, sem executar nada em PROD)
- PROD: ainda não (a migração só roda por ação do Renan no app, após merge)
- Atualizado: 27/11/2026 16:50

## Decisões
| Data | Decisão | Por quê | Quem decidiu |
|---|---|---|---|
| 27/11/2026 | `tx_id` sintético `mig:<obj>:<tx>` | id real faria o app apagar a transação antiga | IA (revisão Opus: não quebra nada hoje) |
| 27/11/2026 | Não editar a linha do objetivo; marcar "migrado" em `emprestimos_migracao` | evita mexer em dado real; desfazer trivial | IA |
| 27/11/2026 | Status migrado vem das decisões vivas; tabela D1 é histórico | novo semeio do celular pode apagar decisões; revisão Opus #2 | IA |
| 27/11/2026 | Desfazer simula o cálculo e bloqueia se mudar outro saldo | devolução FIFO antiga pode ter abatido `mig:` (Opus #3) | IA |
| 27/11/2026 | Cálculo portado para JS (`migracaoEmprestimos.js`) com fixture de paridade com Dart | prévia/aplicar testáveis no Worker | IA |

## Tarefas e provas
| # | Tarefa | Depende de | Cenário (ação → resultado) | Prova | Nível | Resultado |
|---|---|---|---|---|---|---|
| 1 | Port do cálculo + planejador | - | objetivo sintético → eventos e saldo | node --test (paridade JS/Dart) | 2 | ok |
| 2 | Prévia e reconciliação | 1 | parcial, perdoado, sem pessoa, pago a mais → soma bate/explicada | node --test (25 testes da migração) | 2 | ok |
| 3 | Aplicar/desfazer + rotas + tabela | 2 | aplicar → decisões no espelho; desfazer → volta; assinatura mudou → 409 | node --test (Worker 330/330) | 3 | ok |
| 4 | UI Flutter (prévia, confirmar, desfazer) | 3 | Empréstimos → "Empréstimos antigos" → prévia → confirmar | flutter test (8 da migração, 40 com os de empréstimos) + prints sintéticos; CI Checks pendente | 2 | ok local; CI no PR |
| 5 | Simulação contra o backup | 3 | prévia e aplicar em D1 falso (cópia local) | 6 prontos, 1 não mapeável; aplicar/desfazer ok nos dois modos; soma explicada | 3 | ok |

## Ações críticas (só nível 3)
| # | Ação | Alvo real | Simulação | Backup conferido | Plano de volta | Executada em |
|---|---|---|---|---|---|---|
| 1 | Aplicar migração em PROD | D1 de PROD (`espelho`, `emprestimos_migracao`) | tarefa 5 (backup local) | `backup-d1` do dia, antes do toque | botão Desfazer por empréstimo; restaurar backup | NÃO nesta entrega (só o Renan, no app, após merge) |

## Pendências e fora de escopo
- `devo`, valor fixo e moedas diferentes ficam como "não mapeável" na prévia.

## Achados da simulação (só contagem e totais)
- Sem ajuste de datas, pagamentos acima do saldo eram descartados e o saldo novo ficava longe do antigo; com ajuste, a diferença restante são créditos reais de pessoas que pagaram a mais.
- Devoluções soltas passam a abater empréstimos migrados pela regra FIFO (vínculo editável depois no app).
- 1 objetivo sem lançamentos não migra.

## Revisões
- Opus (adversarial, ciclo 1): 0 achados altos; 3 médios. Corrigido: assinatura passa a cobrir `ajustar`. Aceitos e registrados: aplicar não é atômico com o log (se o log falhar, o desfazer fica travado em 409, que é o lado seguro); duas aplicações simultâneas com `ajustar` diferentes (exige duplo toque); backend aceita `revisar` por ação explícita por empréstimo (a tela deixa de fora do lote).
- code-review high --fix: 2 bugs corrigidos (rota exata, `hash_outros` em lote).
- Simplificação: 2 passadas + karpathy-coder.

## Retro
-
