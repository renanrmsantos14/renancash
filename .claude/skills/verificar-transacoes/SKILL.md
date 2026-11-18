---
name: verificar-transacoes
description: "Verifica as telas de transações no padrão editorial: lista do mês com resumo (entradas, saídas, saldo), busca, filtros e chips de filtro, nova/editar transação (valor no topo, tipo, categoria, Salvar), Agendadas, Assinaturas e Empréstimos. Use após mudar budget/lib/pages/transactionsListPage.dart, transactionsSearchPage.dart, transactionFilters.dart, addTransactionPage.dart, upcomingOverdueTransactionsPage.dart, subscriptionsPage.dart, creditDebtTransactionsPage.dart, budget/lib/widgets/editorial/resumoTransacoes.dart, o resumo/saldo em transactionEntries.dart ou as traduções pt dessas telas."
---
# Verificar Transações

## Cobre
- `pages/transactionsListPage.dart`: lista do mês (PageView por mês), resumo no topo, chips de filtro aplicados, vazio com ação.
- `pages/transactionsSearchPage.dart` (+ `AppliedFilterChip`), `pages/transactionFilters.dart` (folha de filtros e `AppliedFilterChips`; também usados no detalhe da conta).
- `pages/addTransactionPage.dart` (página completa do celular; o formulário do computador é `widgets/editorial/painelTransacao.dart`, coberto pela `verificar-editorial-web`).
- `pages/upcomingOverdueTransactionsPage.dart` (Agendadas), `pages/subscriptionsPage.dart` (Assinaturas), `pages/creditDebtTransactionsPage.dart` (Empréstimos).
- `widgets/editorial/resumoTransacoes.dart`: `ResumoPeriodo`, `TotalDestaque`, `AcaoVazio`, `contagemTransacoes`.
- Textos pt em `assets/translations/generated/pt.json` e na coluna `pt` de `translations.csv` (as duas mudam juntas).

## Preparar ambiente
- Windows local: `export PATH=/c/Users/mendo/development/flutter-3.24.5/bin:$PATH`; nuvem/Linux: `export PATH=$HOME/dev/flutter/bin:$PATH`. Depois `cd budget`.
- Se a máquina local não puder rodar Flutter (pedido do Renan: o PC fica pesado), rode tudo no GitHub Actions do PR e confira os artefatos.

## Roteiro
1. `flutter analyze` → 0 linhas `error -`; nos arquivos acima, sem aviso novo (os `notifyListeners`, `paid` sem uso e `dead_null_aware` em transactionEntries já existiam).
2. `PRINTS=1 flutter test test/prints_transacoes_test.dart --update-goldens` → PNGs `.verificacao/prints/transacoes_<tela>_<claro|escuro>.png` com banco em memória: lista, agendadas, vazio, AddTransactionPage (nova, edição, validação), busca (com/sem resultado), folha de filtros, Assinaturas, Empréstimos, lançamento rápido (390x844, claro e escuro) e, no computador (1440x900, claro), TransacoesDesktop, FormularioTransacao (novo, validação, edição), AddTransactionPage, busca, Assinaturas e Empréstimos. No CI o step roda um arquivo por vez com `timeout 300`; localmente use `_pular` (variável `PRINTS=1`). Abra cada PNG e confira: inglês/mistura de idioma, moeda `R$ 1.234,56` com `−`, data pt-BR, corte ou sobreposição, contraste, alvos de toque abaixo de 44 px, estados vazio/erro e o padrão editorial.
3. `flutter test test/editorial_test.dart test/desktop_fluxos_test.dart` (componentes compartilhados e formulário do computador continuam passando).
4. Web sem pareamento: `MSYS_NO_PATHCONV=1 flutter build web --base-href /app/` (confira a linha "Built build\web": se o build cair, `build/web` fica com a versão anterior e os prints enganam) e `node .claude/skills/verificar-editorial-web/shot.mjs budget/build/web .verificacao/<pasta> <roteiro>.json`. Roteiro útil: `goto` (12 s) → `clicar` "Transações" → print → `clicar` "Filtros" → print → `tecla` Escape → `clicar` "Buscar transações" → print → `goto` → `clicar` "Mais" → `clicarTexto` "Agendadas" / "Assinaturas" / "Empréstimos" → print; repetir com `{"acao":"contexto","escuro":true}`. Os rótulos acessíveis saem em pt (ex.: "Buscar transações", "Nova transação"); use `rotulos` para conferir.
5. Nova transação (celular): toque no "+" da barra; confira de cima para baixo valor grande centralizado (cinza "R$ 0,00" sem valor), Despesa/Renda (e Transferir com 2+ contas), linha "Categoria / Selecione a categoria" com ›, depois Nome, data, contas, tipo, orçamentos/metas, notas e "Mais opções"; um só botão "Salvar" no rodapé.

## Casos de borda
- Ajuste de saldo (categoria `"0"` paga, ex.: "CDB - BANCO INTER S.A" da carteira Investimentos): fica fora do total do dia e do resumo de propósito (é o valor do investimento, não dinheiro que entrou). Na lista aparece sem sinal, com "ajuste · fora do total" sob o valor (`ehAjusteDeSaldo` em `transactionEntryAmount.dart`). Caso real: "Ontem" = −R$ 0,01 com +550,03/+28,01/+430,21 em verde.
- "Salvar" sem categoria abre a escolha de categoria (que encadeia o valor e grava); com categoria e sem valor abre o valor; com os dois grava e fecha. Edição também mostra "Salvar"; transações especiais (agendada, assinatura, empréstimo) mantêm o segundo botão de ação (Pagar, Pular etc.).
- Valor em outra moeda: aparece o nome da moeda no número grande e o valor convertido em `rotulo` logo abaixo (só com 2+ contas e conta diferente da principal com moeda diferente).
- Lançamento do Meu Banco com conta rachada (`VinculoReembolso`, `widgets/editorial/reembolsoConta.dart`, abaixo de Orçamentos): o gasto mostra "Parte de <Nome> · −R$ X de R$ Y" por reembolso e "Sua parte" (aviso se os reembolsos passam do gasto); o Pix ligado mostra "Reembolso de <gasto> dd/mm"; ambos com Desligar. Entrada sem vínculo: "É a parte de uma conta que eu paguei". Lançamento manual ou gasto sem reembolso: nada. Roteiro em `verificar-pendencias`.
- Toque longo no valor: copiar/colar; toque longo na categoria (só com categoria escolhida) abre a edição da categoria.
- No computador largo (`enableDoubleColumn`) a coluna esquerda mantém cabeçalho + nome + notas; no celular o nome sobe para logo depois da categoria e as notas descem para antes de "Mais opções".
- Resumo do mês: segue a opção "Resumo do mês" (`showTransactionsMonthlySpendingSummary`, ligada por padrão); toque abre o detalhe do período, toque longo abre a opção para desligar. Com o resumo ligado, a lista do mês não repete o "Saldo … · N transações" no fim; com ele desligado, o total volta ao fim da lista (inclui correções de saldo, que o resumo não soma). A busca sempre mostra esse total, em `rotulo`. O sinal − do valor animado acompanha o número durante a contagem (troca de sinal não mostra − errado).
- Mês vazio: "Nenhuma transação em novembro." + "Nova transação" (`abrirTransacao`). Agendadas vazia: "Nenhuma transação agendada." + "Agendar transação"; aba Atrasado vazia: "Nada atrasado." sem ação; busca sem resultado: "Nenhum resultado." sem ação. Assinaturas: "Nenhuma assinatura." + "Adicionar assinatura". Empréstimos: "Nenhum empréstimo." + "Adicionar empréstimo" (some quando há empréstimos de longo prazo, que já têm "Ver empréstimos de longo prazo").
- Assinaturas e Agendadas: período Mensal/Anual/Total é controle segmentado (`SlidingSelectorIncomeExpense`) e grava `selectedSubscriptionType`; valor por item "−55,90 / mês" em `mu` (sinal como antes).
- Empréstimos: rótulo "A receber"/"A pagar" (ou "Total" quando zero), valor absoluto com a cor de crédito/dívida de antes.
- Folha de filtros: seções "Categorias", "Valor", "Tipo", "Situação", "Contas"; chips sem borda colorida; botões "Limpar" (`chip`) e "Aplicar" (principal).
- Textos do banco na lista (`transactionLabel.dart`): título com espaços repetidos sai com um só (`nomeSemEspacosRepetidos`, só exibição; o dado sincronizado não muda); a categoria de ajuste ("0", onde caem os investimentos `mb:inv:`) gravada com nome padrão ("Balance Correction"/"Correção de saldo") sai "Ajuste de saldo" (`nomeDaCategoria`); nome personalizado fica. Ícone de nota ao lado do valor: 16 px, cinza (`textLight` 60%), rótulo de acessibilidade "Tem nota"; toque mostra a nota. Teste: `test/textos_layout_test.dart`.
- Editar transação: chips de conta de mesmo nome (corrente e poupança do mesmo banco) ganham o tipo ("BANCO INTER ·69-6 · Poupança") via `mbTiposDasCarteiras` + `mbRotulosPorPk`; o chip selecionado aparece inteiro ao abrir (com o botão fixo de "mais contas", >3 contas, o índice não ganha +1; alinhamento 0,06). Abas "Despesa / Receita" (chave `income` = "Receita" em pt, também nos filtros e na lista de categorias).
- Sinal negativo: `convertToMoney` e `brl` usam "−" (U+2212) colado ao símbolo ("−R$ 0,01"), igual ao total do dia e às linhas.
- Fim da lista do mês: `mbFolgaFab` (88) para o "+" não cobrir o valor da última linha; o mesmo no PageFramework quando a página tem `floatingActionButton`.
- Entrada de lista (`EntradaSuave`) em Agendadas, Assinaturas e Empréstimos só nos 600 ms após abrir a página; com "reduzir movimento" nada anima (`ContagemValor` mostra o valor final).
- Assinaturas e Agendadas: legenda "2 assinaturas" / "2 agendadas" (singular e plural). Assinatura sem título com subcategoria mostra a subcategoria ("Spotify") e a categoria vai para a etiqueta (`categoriaDoTitulo`). "R$ 20,90 / mês" some quando repete o valor da linha (recorrência de 1 mês na visão mensal).
- Seletor de categoria da transação abre só com as categorias do tipo escolhido (Despesa/Receita); "Mostrar todas as categorias" segue no menu do seletor e não vira padrão.
- Chip de carteira na busca: o desempate de nome olha todas as carteiras do app (`mbRotulosPorPk`), então a poupança "BANCO INTER ·69-6" filtrada sozinha mostra "· Poupança".
- Valor com centavos menores (ex.: 0,05 em outra moeda ou sem nome de moeda): `ContagemValor` reduz os centavos; `currencyName` vazio vira nulo para não deixar espaço final que quebrava a regex (A3).
- Formulário do computador (`painelTransacao.dart`): Subcategoria só aparece quando a categoria tem subs ("Nenhuma" por padrão); categorias e subs de mesmo nome ganham " (2)"; contas arquivadas ficam fora (exceto a da transação editada) e contas de mesmo nome ganham o tipo (A6).
- Lançamento rápido (`lancamentoRapido.dart`): com 2+ contas aparecem chips para escolher a conta (começa na conta selecionada); o lançamento grava nela (M7).
- Versão no desktop (`VersaoCanto`): fica no canto inferior esquerdo e só aparece com página empilhada; não pode cobrir o "Salvar" do canto direito (B3).

## Evidência obrigatória
- Tail do analyze e dos testes, os 6 PNGs do passo 2 e os prints do navegador (claro e escuro) em `.verificacao/<data>-<branch>/`.

## Limites
- Os prints usam `FinanceDatabase(NativeDatabase.memory())` (`_prepararBanco`, com limite de 25 s) e `use24HourFormat` fixo em 24 h (sem EasyLocalization o formato do sistema quebra o `TimeDigits`). Confira também o navegador (web usa o banco local) ou o celular pareado para o fluxo completo.
