---
name: verificar-contas
description: "Verifica as telas de Contas no padrão editorial: detalhe da conta (walletDetailsPage, também Todos os gastos), lista de contas (editWalletsPage), nova/editar conta (addWalletPage), Investimentos (investimentosEvolucaoPage), backup Google (accountsPage) e os textos de conta em pt-BR. Use após mudar esses arquivos, budget/lib/widgets/editorial/contas.dart ou as chaves de conta em assets/translations."
---
# Verificar Contas

## Cobre
- `budget/lib/pages/walletDetailsPage.dart` (detalhe da conta e "Todos os gastos" com `wallet == null`), `editWalletsPage.dart` (lista "Contas", exclusão/junção de contas), `addWalletPage.dart` (nova/editar conta, Corrigir/Transferir saldo), `investimentosEvolucaoPage.dart`, `accountsPage.dart` (backup Google, só visual).
- Widgets puros em `budget/lib/widgets/editorial/contas.dart`: `ResumoConta`, `SeletorPeriodo`, `TotalContas`, `LinhaConta`, `SiglaConta`, `comSinal`.
- Meu Banco (`meuBancoPage.dart`, `meuBancoParear.dart`) também pela skill `verificar-meu-banco`.
- Chaves pt de conta em `budget/assets/translations/generated/pt.json` e `translations.csv` (coluna `pt`; mude as duas).

## Preparar ambiente
- Windows (Git Bash): `export PATH=/c/Users/mendo/development/flutter-3.24.5/bin:$PATH` e `cd budget`. Nuvem/Linux: `export PATH=$HOME/dev/flutter/bin:$PATH`.
- Sem `sqlite3.dll` aqui: telas que leem o banco (detalhe, lista, formulário) não renderizam em teste de widget. Por isso os prints usam os widgets puros e o navegador usa o build web (banco do navegador).

## Roteiro
1. `flutter analyze lib/pages/walletDetailsPage.dart lib/pages/editWalletsPage.dart lib/pages/addWalletPage.dart lib/pages/investimentosEvolucaoPage.dart lib/pages/accountsPage.dart lib/pages/meuBanco*.dart lib/widgets/editorial/contas.dart` → nenhum `error -` (avisos `notifyListeners` em walletDetailsPage são herdados).
2. `flutter test test/editorial_test.dart test/mb_inicio_test.dart test/mb_conexoes_test.dart test/desktop_test.dart` → passam.
3. Prints: `PRINTS=1 flutter test test/prints_contas_test.dart --update-goldens` → `.verificacao/prints/contas_{detalhe,detalhe_negativa,lista,investimentos,investimentos_vazio}_{claro,escuro}.png`. Abra e confira: saldo grande com centavos menores, entradas em verde com +, saídas em texto com −, linhas de 56 px sem traço pontilhado, cartões planos (`surf` + borda, sem sombra), lista com sigla, nome, detalhe e saldo à direita sem cortar o nome.
4. Navegador: `MSYS_NO_PATHCONV=1 flutter build web --base-href /app/` e `node .claude/skills/verificar-editorial-web/shot.mjs budget/build/web .verificacao/contas-web .claude/skills/verificar-contas/roteiro-contas.json`. O roteiro abre Mais › Contas, a conta padrão, o formulário de nova conta e repete no escuro. Abra os PNGs.

## Casos de borda
- Detalhe da conta: topo = "Saldo da conta" (saldo de sempre, `followCustomPeriodCycle: false`) e "No período" com chip do período (abre a escolha do ciclo) e Entradas/Saídas do período (`onlyIncomeAndExpense`). Tocar no saldo abre as transações da conta; em Entradas/Saídas abre filtrado por tipo e período. O "Total líquido" do período saiu (duplicava entradas − saídas).
- Linhas abaixo do topo (Correção de saldo, Emprestou, Pegou emprestado, Por vir, Atrasado) só aparecem com valor; Atrasado em `warn`. Em "Todos os gastos" (`wallet == null`) Despesa e Renda continuam como linhas fixas (despesa com −, renda verde) e o seletor Atual/Histórico fica como estava.
- Toque numa conta da Início (celular e `painelDesktop.dart`, ambos via `mbAbrirConta`): `ContaInicio.carteiras` guarda os pks (`mbPkConta(id)`, '|'), não nomes, porque corrente e poupança do mesmo banco podem ter o mesmo nome ("BANCO INTER ·69-6"). Uma carteira no aparelho → `WatchedWalletDetailsPage` (detalhe editorial); "Poupanças" agrupada ou várias → `TransactionsSearchPage` filtrada; nenhuma → Meu Banco. Teste: `mb_inicio_test.dart` confere os pks da linha e da linha agrupada.
- Busca aberta com filtros prontos (`initialFilters`) não abre o teclado; só pela lupa. Chips de carteira: um por pk; nomes iguais ganham o tipo do Meu Banco ("· Conta corrente"/"· Poupança") e, sem tipo ou empatando, a posição (`mbRotulosCarteiras`, teste em `mb_conexoes_test.dart`).
- Saldo negativo mostra "−R$" (sinal tipográfico), sem cor de alerta.
- Lista "Contas": total na moeda principal (`amountRatioToPrimaryCurrency`) só sem busca; busca só aparece com mais de 6 contas (ou busca ativa). Linha sem faixa de cor e sem lixeira: excluir fica no menu da conta (com confirmação; a conta "0" só pode ser excluída com 2+ contas, igual à lista antiga); estrela = conta principal; alça = reordenar (chave no `EntradaSuave` da linha).
- Nova conta: nome, "Saldo inicial" em número grande, Cor, Ajustes (precisão decimal), Moeda; botão inferior único ("Definir nome" sem nome, "Adicionar conta" depois). Editar: Ações = Corrigir saldo, Transferir saldo (2+ contas), Juntar com outra conta, Precisão decimal; Excluir conta no menu ⋮. O formulário não tem campo "tipo" (a tabela `wallets` não tem coluna; não mudar o banco).
- Investimentos: vazio = ícone + "Nenhum investimento sincronizado ainda." + "Abrir o Meu Banco"; variação do mês com + verde / − texto; menos de 2 meses mostra o aviso no lugar do gráfico.
- Meu Banco: "Desconectar este aparelho" pede confirmação antes de apagar o token.
- Animações: `ContagemValor` no saldo, entradas/saídas, total e linhas; `ToqueEscala` no saldo, nos cartões e no chip; `EntradaSuave` nas linhas da lista (só nos primeiros 600 ms) e nos blocos de Investimentos. Tudo some com `semMovimento`.

## Evidência obrigatória
- Tail do analyze e dos testes; PNGs em `.verificacao/prints/contas_*` e `.verificacao/contas-web/`.

## Limites
- Contas reais com transações (gráfico e categorias do detalhe) só com dados: no web, adicione transações no próprio roteiro ou confira no celular pareado.
