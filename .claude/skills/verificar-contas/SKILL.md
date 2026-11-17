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
2. `flutter test test/editorial_test.dart test/mb_inicio_test.dart test/mb_conexoes_test.dart test/desktop_test.dart test/detalhe_conta_test.dart` → passam.
3. Prints: `PRINTS=1 flutter test test/prints_contas_test.dart --update-goldens` → `.verificacao/prints/contas_{detalhe,detalhe_negativa,lista,investimentos,investimentos_vazio}_{claro,escuro}.png`. Abra e confira: saldo grande com centavos menores, entradas em verde com +, saídas em texto com −, linhas de 56 px sem traço pontilhado, cartões planos (`surf` + borda, sem sombra), lista com sigla, nome, detalhe e saldo à direita sem cortar o nome.
4. Navegador: `MSYS_NO_PATHCONV=1 flutter build web --base-href /app/` e `node .claude/skills/verificar-editorial-web/shot.mjs budget/build/web .verificacao/contas-web .claude/skills/verificar-contas/roteiro-contas.json`. O roteiro abre Mais › Contas, a conta padrão, o formulário de nova conta e repete no escuro. Abra os PNGs.

## Casos de borda
- Detalhe da conta: topo = "Saldo da conta" (saldo de sempre, `followCustomPeriodCycle: false`) e "No período" com chip do período (abre a escolha do ciclo) e Entradas/Saídas do período (`onlyIncomeAndExpense`). Tocar no saldo abre as transações da conta; em Entradas/Saídas abre filtrado por tipo e período. O "Total líquido" do período saiu (duplicava entradas − saídas).
- Linhas abaixo do topo (Correção de saldo, Emprestou, Pegou emprestado, Por vir, Atrasado) só aparecem com valor; Atrasado em `warn`. Em "Todos os gastos" (`wallet == null`) Despesa e Renda continuam como linhas fixas (despesa com −, renda verde) e o seletor Atual/Histórico fica como estava.
- Toque numa conta da Início (celular e `painelDesktop.dart`, ambos via `mbAbrirConta`): `ContaInicio.carteiras` guarda os pks (`mbPkConta(id)`, '|'), não nomes, porque corrente e poupança do mesmo banco podem ter o mesmo nome ("BANCO INTER ·69-6"). Uma carteira no aparelho → `WatchedWalletDetailsPage` (detalhe editorial); "Poupanças" agrupada ou várias → `TransactionsSearchPage` filtrada; nenhuma → Meu Banco. Teste: `mb_inicio_test.dart` confere os pks da linha e da linha agrupada.
- Busca aberta com filtros prontos (`initialFilters`) não abre o teclado; só pela lupa. Chips de carteira: um por pk; nomes iguais ganham o tipo do Meu Banco ("· Conta corrente"/"· Poupança") e, sem tipo ou empatando, a posição (`mbRotulosCarteiras`, teste em `mb_conexoes_test.dart`).
- Saldo negativo mostra "−R$" (sinal tipográfico), sem cor de alerta.
- Saldo de conta do Meu Banco (`mb:<id>`, tipo BANK): detalhe, lista "Contas" (linha e total) e Patrimônio mostram o saldo real salvo em `mb_estado.contas` (`mbSaldosReais`/`mbLerSaldosReais`), o mesmo da linha da Início. A soma dos lançamentos não é saldo: transferências, pagamento de fatura, aplicações/resgates, poupança/porquinho e envios ao Santander não viram lançamento (`mbNaoEhGasto`) e não há saldo inicial. Caso real (v5.4.32): Início R$ 927,28 × detalhe R$ 4.253,79 antes da correção. Cartão (CREDIT) e contas manuais seguem com a soma local. Teste: `detalhe_conta_test.dart`.
- Patrimônio (Orçamentos › Análise, `mbCarregarPatrimonioInicio` + `HomePagePatrimonio`): total = Contas correntes + Poupanças (linha só com saldo ≠ 0) + Investimentos − Fatura atual, todos saldos reais do Meu Banco. A seção "Carteiras manuais · fora do total" lista só carteiras fora do Meu Banco (pk sem `mb:`, ex.: `'0'` renomeada "Inter"), com a soma local; as `mb:` (BANCO INTER ·69-6, cartão GOLD) não aparecem ali. Caso real (v5.4.32): R$ 1.890,26 sem os R$ 1,39 das poupanças e com BANCO INTER R$ 4.253,79 / GOLD −R$ 550,00 na lista. Teste: `mb_orcamentos_test.dart` grupo 'fatura e patrimônio'.
- Assinaturas (Spotify, Netflix) ficam na carteira padrão `'0'` (o registro de assinatura não traz conta; `_assinatura` em `aplicarLocal.dart` usa `existente?.walletFk ?? '0'`). Não há carteira duplicada criada pelo sync; "Inter" é a `'0'` renomeada.
- Pizza do detalhe: abas "Saídas" / "Entradas" (chaves `outgoing`/`incoming`). Categoria com ícone `image.png` (o "sem ícone" do Cashew e das categorias do Meu Banco) ou vazio mostra `price-tag.png` (`arquivoIconeCategoria` em `categoryIcon.dart`); nome de asset inexistente cai no mesmo ícone (`errorBuilder`).
- Moeda: no formato numérico personalizado com símbolo antes, "R$" ganha espaço ("R$ 4.253,79", "+R$ 21.198,70", eixo "R$ 3,5K"), igual à Início (`brl`); outras moedas seguem coladas ("$4.253,79").
- Início: o "+" flutuante tem rótulo "Nova transação" (`Semantics` no `FAB`; no uiautomator aparece como content-desc). O subtítulo "Disponível nas contas · …" usa até 2 linhas e tira o final do número da conta ("BANCO INTER ·69-6" → "BANCO INTER").
- Lista "Contas": total na moeda principal (`amountRatioToPrimaryCurrency`) só sem busca; busca só aparece com mais de 6 contas (ou busca ativa). Linha sem faixa de cor e sem lixeira: excluir fica no menu da conta (com confirmação; a conta "0" só pode ser excluída com 2+ contas, igual à lista antiga); estrela = conta principal; alça = reordenar (chave no `EntradaSuave` da linha).
- Nova conta: nome, "Saldo inicial" em número grande, Cor, Ajustes (precisão decimal), Moeda; botão inferior único ("Definir nome" sem nome, "Adicionar conta" depois). Editar: Ações = Corrigir saldo, Transferir saldo (2+ contas), Juntar com outra conta, Precisão decimal; Excluir conta no menu ⋮. O formulário não tem campo "tipo" (a tabela `wallets` não tem coluna; não mudar o banco).
- Investimentos: vazio = ícone + "Nenhum investimento sincronizado ainda." + "Abrir o Meu Banco"; variação do mês com + verde / − texto; menos de 2 meses mostra o aviso no lugar do gráfico.
- Meu Banco: "Desconectar este aparelho" pede confirmação antes de apagar o token.
- Animações: `ContagemValor` no saldo, entradas/saídas, total e linhas; `ToqueEscala` no saldo, nos cartões e no chip; `EntradaSuave` nas linhas da lista (só nos primeiros 600 ms) e nos blocos de Investimentos. Tudo some com `semMovimento`.
- Mais > Contas: subtítulo com a origem (`mbOrigemCarteira`): "Conta corrente · Meu Banco", "Poupança · Meu Banco", "Meu Banco" (Investimentos) ou "Manual". Duas "BANCO INTER ·69-6" (corrente e poupança) ficam distinguíveis.
- Código da moeda ("BRL") só aparece com mais de uma moeda nas carteiras (`allContainSameCurrency`): linhas de Contas e "Total líquido" de Todos os gastos > Agora.
- Todos os gastos > Histórico: ciclo passado com o intervalo ("6 out – 5 nov", `intervaloDoCiclo`); o número em negrito vem rotulado "Saldo" (ou "Saldo acumulado") e é entradas − saídas, conferível com o par à direita (antes era o net com ajustes de saldo). Legenda do gráfico: "Saídas" / "Entradas" (ou "Saldo acumulado").

## Evidência obrigatória
- Tail do analyze e dos testes; PNGs em `.verificacao/prints/contas_*` e `.verificacao/contas-web/`.

## Limites
- Contas reais com transações (gráfico e categorias do detalhe) só com dados: no web, adicione transações no próprio roteiro ou confira no celular pareado.
