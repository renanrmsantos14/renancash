# Empréstimos unificados

- Nível: 3 (migra dado financeiro real existente; sem volta fácil se mal feito)
- Etapa: 5 de 7 Construir (spec revisada pelo Opus, ciclo 1)
- Próximo passo: planejador/prévia/aplicar/desfazer no Worker + testes · sozinho
- Branch e PR: feature/emprestimos-unificados · ainda não
- Protótipo: sem protótipo (prévia em texto/cartão; UI mínima dentro de Empréstimos)
- Go: 27/11/2026 via brief da thread e3bee913 (nível 3, sem executar nada em PROD)
- PROD: ainda não (a migração só roda por ação do Renan no app, após merge)
- Atualizado: 27/11/2026 16:20

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
| 1 | Port do cálculo + planejador | - | objetivo sintético → eventos e saldo | node --test (paridade JS: 7 casos ok) | 2 | cálculo ok; planejador pendente |
| 2 | Prévia e reconciliação | 1 | parcial, perdoado, sem pessoa, pago a mais → soma bate/explicada | node --test | 2 | pendente |
| 3 | Aplicar/desfazer + rotas + tabela | 2 | aplicar → decisões no espelho; desfazer → volta; assinatura mudou → 409 | node --test | 3 | pendente |
| 4 | UI Flutter (prévia, confirmar, desfazer) | 3 | cartão em Empréstimos → prévia → confirmar | CI Checks + print | 2 | pendente |
| 5 | Simulação contra o backup | 3 | prévia e aplicar em D1 falso | contagem e diferença total | 3 | pendente |

## Ações críticas (só nível 3)
| # | Ação | Alvo real | Simulação | Backup conferido | Plano de volta | Executada em |
|---|---|---|---|---|---|---|
| 1 | Aplicar migração em PROD | D1 de PROD (`espelho`, `emprestimos_migracao`) | tarefa 5 (backup local) | `backup-d1` do dia, antes do toque | botão Desfazer por empréstimo; restaurar backup | NÃO nesta entrega (só o Renan, no app, após merge) |

## Pendências e fora de escopo
- `devo`, valor fixo e moedas diferentes ficam como "não mapeável" na prévia.

## Retro
-
