---
name: verificar-orcamentos-metas
description: "Verifica as telas de Orçamentos e Metas no padrão editorial (Etapa 4 da revisão de UI): lista e detalhe de orçamento, histórico de ciclos, novo/editar orçamento e limites, lista e detalhe de metas, empréstimos por diferença e os textos pt-BR delas. Use após mudar budget/lib/widgets/budgetContainer.dart, budget/lib/pages/{budgetsListPage,budgetPage,addBudgetPage,editBudgetPage,editBudgetLimitsPage,pastBudgetsPage,objectivesListPage,objectivePage,addObjectivePage,editObjectivesPage}.dart ou chaves de orçamento/meta em budget/assets/translations."
---
# Verificar Orçamentos e Metas

## Cobre
- `widgets/budgetContainer.dart`: `ResumoOrcamento` (rótulo, valor grande, `MedidorEditorial`, "Gasto X de Y", "faltam N dias", ritmo diário só com `grande`), `CartaoOrcamento` (cartão da lista), `BudgetContainer` (liga ao banco), `diasRestantesOrcamento`, `textoPeriodoOrcamento`.
- `pages/budgetsListPage.dart` (lista + `SemOrcamentos`), `budgetPage.dart` (herói `ResumoOrcamento` + categorias + gráfico + transações), `pastBudgetsPage.dart` (`LinhaCicloOrcamento`), `addBudgetPage.dart`, `editBudgetPage.dart`, `editBudgetLimitsPage.dart`.
- `pages/objectivesListPage.dart` (`CartaoMeta`, `LinhaEmprestimoDiferenca`, `VazioMetas`, `destaqueMeta`, `detalheMeta`), `objectivePage.dart` (`ResumoMeta`), `addObjectivePage.dart`, `editObjectivesPage.dart`. A lista de empréstimos (`creditDebtTransactionsPage`) reaproveita `ObjectiveList`/`CartaoMeta`.

## Preparar ambiente
- Windows local: `export PATH=/c/Users/mendo/development/flutter-3.24.5/bin:$PATH`; nuvem: `export PATH=$HOME/dev/flutter/bin:$PATH`. Depois `cd budget`.
- Se o Renan pediu para não rodar Flutter na máquina dele, rode tudo no GitHub Actions do PR (ou numa sessão cloud) e só leia o código localmente.

## Roteiro
1. `flutter analyze` → 0 linhas `error -`; nos arquivos acima só os avisos herdados (`notifyListeners` em budgetPage/objectivePage, `must_call_super` do `BudgetLineGraph`, `result`/`result2` em addBudgetPage).
2. `flutter test test/mb_metas_test.dart test/mb_emprestimos_test.dart test/mb_inicio_test.dart test/editorial_test.dart` → passam. `mb_orcamentos_test` depende do `sqlite3.dll` (falha ambiental no Windows).
3. Prints sem banco: `PRINTS=1 flutter test test/prints_orcamentos_test.dart --update-goldens` → `.verificacao/prints/orcamentos_{lista,vazio,detalhe,estourado,gasto,historico}_{claro,escuro}.png` e `metas_{lista,vazio,detalhe}_{claro,escuro}.png`. O teste liga `customNumberFormat` (`.` milhar, `,` decimal) para o número sair como no pt-BR; R$ não aparece (sem moedas) e textos `.tr()` saem como chave (ex.: "/day for 227 days"). Abra os PNGs e confira: valor grande com centavos menores, medidor de 2 px, estouro em vermelho (`overspentAmount`), meta concluída em verde (`pos`), cartões planos (`surf` + borda `line`, raio 12, sem sombra).
4. Web: `MSYS_NO_PATHCONV=1 flutter build web --base-href /app/` e `node .claude/skills/verificar-editorial-web/shot.mjs budget/build/web .verificacao/<pasta> <roteiro.json>` abrindo a aba Orçamentos (sem dados: "Nenhum orçamento ainda" + "Criar orçamento") e Mais › Metas (sem dados: "Nenhuma meta ainda" + "Criar meta"), claro e escuro.
5. Com dados (app pareado ou modo demonstração do onboarding): abrir um orçamento, tocar no valor (alterna Resta ↔ Gasto e salva `showTotalSpentForBudget`), menu ⋮ › "Histórico do orçamento", tocar num ciclo (abre com seletor ‹ período › no topo e sem o item de histórico no menu).

## Casos de borda
- Orçamento de despesa: "Resta" → passou do limite vira "Acima do limite" com valor em `overspentAmount` e medidor em alerta. Poupança (`income`): "Falta guardar" → "Acima da meta" em verde, sem alerta.
- "faltam N dias" conta hoje; no último dia mostra "último dia". Fora do período (ciclo passado do histórico) não mostra dias nem ritmo. Ritmo "Pode gastar R$ X/dia" (ou "Guarde") só no detalhe e só com saldo positivo.
- O valor que conta (`ContagemValor`) usa `allDecimals: true` para não trocar de formato ao terminar ("1.500,00" e não "1.500"). Linhas secundárias seguem o `convertToMoney` normal.
- Toque no cartão abre o detalhe com `ToqueEscala`; segurar abre a edição. Entrada da lista (`EntradaSuave`) só nos primeiros 600 ms da página; tudo some com "reduzir movimento". Confete da meta não toca com `semMovimento`.
- Histórico: o item "Histórico do orçamento" do menu e o "Ver ciclos anteriores" do vazio aparecem para orçamentos recorrentes que não vieram do histórico (a condição antiga nunca era verdadeira).
- Meta sem valor alvo (ex.: Reserva de emergência): mostra o guardado e "Definir valor" (abre a edição), sem medidor.
- Orçamento compartilhado foi cortado: sem chip "Shared Group Budget", sem filtro de membros, sem resumo por membro, sem popup de excluir compartilhado. Colunas (`sharedKey`, `memberTransactionFilters`...) e `struct/shareBudget.dart` continuam; o filtro de membros salvo é preservado ao editar.
- Cabeçalho compacto (56 px) no detalhe do orçamento e da meta; o histórico usa título + subtítulo (nome do orçamento), 110 px.

## Evidência obrigatória
- Tail do analyze e dos testes, PNGs em `.verificacao/prints/` conferidos claro e escuro.

## Limites
- Sem banco local nos testes: a tela inteira do orçamento (pizza, gráfico de linha, transações) só se confere no app com dados.
