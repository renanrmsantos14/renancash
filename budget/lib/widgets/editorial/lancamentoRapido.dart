import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart' show popRoute;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/casosComuns.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl;
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/selectAmount.dart';
import 'package:budget/widgets/transactionEntry/transactionLabel.dart' show nomeDaCategoria;
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

// Lançamento rápido da Início (a regra está em struct/mbSync/casosComuns.dart): os gastos que mais se repetem viram
// atalhos; um toque abre o teclado de valor já preenchido e "Lançar" grava a transação.

/// "salgado" → "Salgado" (só para mostrar; o título gravado é o mesmo das outras vezes).
String mbTituloAtalho(String t) => t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);

/// Atalhos a partir das transações dos últimos 90 dias (fora agendadas e assinaturas).
Future<List<MbAtalhoRapido>> mbCarregarAtalhosRapidos() async {
  final agora = DateTime.now();
  final desde = DateTime(agora.year, agora.month, agora.day - mbDiasAtalhos);
  final txs = await (database.select(database.transactions)
        ..where((t) =>
            t.dateCreated.isBiggerOrEqualValue(desde) & t.amount.isSmallerThanValue(0) & t.type.isNull()))
      .get();
  final nomes = {for (final c in await database.select(database.categories).get()) c.categoryPk: nomeDaCategoria(c)};
  return mbAtalhosRapidos([
    for (final t in txs)
      if (t.note != 'Pendente')
        (
          pk: t.transactionPk,
          nome: t.name,
          valor: t.amount,
          data: t.dateCreated,
          categoriaPk: t.categoryFk,
          subPk: t.subCategoryFk,
          categoriaNome: nomes[t.categoryFk] ?? '',
          subNome: nomes[t.subCategoryFk],
        )
  ], agora);
}

String _textoValor(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);

/// Teclado de valor já preenchido com o valor mais comum; "Lançar" grava um gasto de hoje na carteira padrão, com o
/// título, a categoria e a sub do atalho. true: lançou.
Future<bool> mbLancarRapido(BuildContext context, MbAtalhoRapido a) async {
  var valor = a.valor;
  final lancar = await openBottomSheet(
    context,
    fullSnap: true,
    PopupFramework(
      title: mbTituloAtalho(a.titulo),
      subtitle: '${a.categoria} · hoje',
      hasPadding: false,
      underTitleSpace: false,
      child: SelectAmount(
        onlyShowCurrencyIcon: true,
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 18),
        amountPassed: _textoValor(a.valor),
        setSelectedAmount: (v, _) => valor = v.abs(),
        next: () => popRoute(context, true),
        nextLabel: 'Lançar',
      ),
    ),
  );
  if (lancar != true || valor <= 0) return false;
  try {
    await database.createOrUpdateTransaction(
      insert: true,
      Transaction(
        transactionPk: '-1',
        name: a.titulo,
        amount: -valor,
        note: '',
        categoryFk: a.categoriaPk,
        subCategoryFk: a.subPk,
        walletFk: '${appStateSettings['selectedWalletPk'] ?? '0'}',
        dateCreated: DateTime.now(),
        income: false,
        paid: true,
        skipPaid: false,
      ),
    );
  } catch (e) {
    openSnackbar(SnackbarMessage(title: 'Não deu para lançar', description: '$e', icon: Icons.warning_amber_rounded));
    return false;
  }
  openSnackbar(SnackbarMessage(
      title: 'Lançado: ${mbTituloAtalho(a.titulo)} · ${brl(valor)}', icon: Icons.check_rounded));
  return true;
}
