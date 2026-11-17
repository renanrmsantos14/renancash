import 'dart:math' show max;

import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart' show getBudgetDate;
import 'package:budget/struct/currencyFunctions.dart'
    show budgetAmountToPrimaryCurrency, categoryBudgetLimitToPrimaryCurrency;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:flutter/material.dart' show DateTimeRange;

// Sugestão de limites por categoria (Orçamentos › "Sugerir limites por categoria").
//
// Média dos últimos [mbCiclosDaSugestao] ciclos completos do orçamento, com a mesma consulta e os mesmos filtros do
// gasto do orçamento (carteiras, sem renda/empréstimo/ajuste). Reembolsos do "rachar conta" entram na categoria do
// gasto como valor positivo, então a média já é só a minha parte. Subcategorias (Almoço Betinhos, Uber, Combustível,
// Mercado...) têm linha própria. Nada é gravado sem o usuário marcar e salvar; os limites ficam em
// `category_budget_limits` do orçamento, em valor (não em %), e aparecem na tela dele com a barra.
// Limitação: o Meu Banco não sincroniza limites por categoria (só nome, valor e categorias do orçamento).

const int mbCiclosDaSugestao = 3;

class MbSugestaoLimite {
  final TransactionCategory categoria;

  /// Nome da categoria principal quando [categoria] é subcategoria.
  final String? principal;

  /// Gasto médio por ciclo (positivo), já com reembolsos abatidos.
  final double media;

  /// Lançamentos por ciclo, em média.
  final double vezes;

  /// Média arredondada para cima em R$ 10.
  final double sugerido;

  /// Limite que o orçamento já tem para a categoria (em valor), se houver.
  final double? atual;

  const MbSugestaoLimite(this.categoria, this.principal, this.media, this.vezes,
      this.sugerido, this.atual);

  String get nome =>
      principal == null ? categoria.name : '$principal › ${categoria.name}';
}

double mbArredondarLimite(double v) => v <= 0 ? 0 : (v / 10).ceil() * 10.0;

/// [porCiclo]: gasto por categoria de cada ciclo (com subcategorias), total negativo = gasto. A média divide pelo
/// número de ciclos (ciclo sem gasto conta 0). Fica só quem gastou em média pelo menos [minimo]; maior média primeiro.
List<MbSugestaoLimite> mbSugerirLimites(List<List<CategoryWithTotal>> porCiclo,
    {double minimo = 20, Map<String, double> atuais = const {}}) {
  final n = porCiclo.length;
  if (n == 0) return const [];
  final soma = <String, double>{};
  final conta = <String, int>{};
  final cats = <String, TransactionCategory>{};
  for (final ciclo in porCiclo) {
    for (final c in ciclo) {
      final pk = c.category.categoryPk;
      cats[pk] = c.category;
      soma[pk] = (soma[pk] ?? 0) - c.total;
      conta[pk] = (conta[pk] ?? 0) + max(c.transactionCount, 0);
    }
  }
  final out = [
    for (final pk in soma.keys)
      if (soma[pk]! / n >= minimo)
        MbSugestaoLimite(
          cats[pk]!,
          cats[cats[pk]!.mainCategoryPk]?.name,
          soma[pk]! / n,
          conta[pk]! / n,
          mbArredondarLimite(soma[pk]! / n),
          atuais[pk],
        )
  ];
  out.sort((a, b) => b.media.compareTo(a.media));
  return out;
}

/// Os [n] ciclos completos antes do atual, do mais recente ao mais antigo. [periodoDe] dá o ciclo que contém a data
/// (no app, `getBudgetDate`: ciclo do salário do Meu Banco ou o período do orçamento).
List<DateTimeRange> mbCiclosAnteriores(
    DateTimeRange Function(DateTime ref) periodoDe, DateTime agora,
    {int n = mbCiclosDaSugestao}) {
  final out = <DateTimeRange>[];
  var inicio = periodoDe(agora).start;
  for (var i = 0; i < n; i++) {
    final p = periodoDe(inicio.subtract(const Duration(days: 1)));
    out.add(p);
    inicio = p.start;
  }
  return out;
}

/// Lê o gasto por categoria dos últimos ciclos do orçamento [b] e monta as sugestões.
Future<List<MbSugestaoLimite>> mbCalcularSugestaoLimites(
    Budget b, AllWallets carteiras,
    {DateTime? agora}) async {
  final porCiclo = <List<CategoryWithTotal>>[];
  for (final p in mbCiclosAnteriores((d) => getBudgetDate(b, d), agora ?? DateTime.now())) {
    porCiclo.add(await database
        .watchTotalSpentInEachCategoryInTimeRangeFromCategories(
          allWallets: carteiras,
          start: p.start,
          end: p.end,
          categoryFks: b.categoryFks,
          categoryFksExclude: b.categoryFksExclude,
          budgetTransactionFilters: b.budgetTransactionFilters,
          memberTransactionFilters: b.memberTransactionFilters,
          onlyShowTransactionsBelongingToBudgetPk:
              b.sharedKey != null || b.addedTransactionsOnly ? b.budgetPk : null,
          budget: b,
          includeAllSubCategories: true,
          countUnassignedTransactions: true,
        )
        .first);
  }
  final atuais = !b.isAbsoluteSpendingLimit
      ? const <String, double>{}
      : {
          for (final l in await _limites(b.budgetPk))
            l.categoryFk: categoryBudgetLimitToPrimaryCurrency(carteiras, l)
        };
  return mbSugerirLimites(porCiclo, atuais: atuais);
}

Future<List<CategoryBudgetLimit>> _limites(String budgetPk) =>
    (database.select(database.categoryBudgetLimits)
          ..where((l) => l.budgetFk.equals(budgetPk)))
        .get();

/// Grava os limites escolhidos ([valores]: categoria -> R$) no orçamento. Orçamento em % passa para valor antes
/// (converte os limites que já existem, como a tela "Limites por categoria" faz ao trocar o tipo).
Future<void> mbSalvarLimites(
    Budget b, Map<String, double> valores, AllWallets carteiras) async {
  if (valores.isEmpty) return;
  if (!b.isAbsoluteSpendingLimit) {
    await database.toggleAbsolutePercentSpendingCategoryBudgetLimits(
        carteiras, b.budgetPk, budgetAmountToPrimaryCurrency(carteiras, b), false);
    await database.createOrUpdateBudget(b.copyWith(isAbsoluteSpendingLimit: true));
  }
  final existentes = {for (final l in await _limites(b.budgetPk)) l.categoryFk: l};
  for (final e in valores.entries) {
    final atual = existentes[e.key];
    await database.createOrUpdateCategoryLimit(
      atual?.copyWith(amount: e.value) ??
          CategoryBudgetLimit(
            categoryLimitPk: '-1',
            categoryFk: e.key,
            budgetFk: b.budgetPk,
            amount: e.value,
            walletFk: b.walletFk,
          ),
      insert: atual == null,
    );
  }
}
