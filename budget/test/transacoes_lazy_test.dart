// A lista de Transações em cartões monta só os dias visíveis (não o mês inteiro).
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/transactionEntries.dart';
import 'package:budget/widgets/transactionEntry/transactionEntry.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

void main() {
  testWidgets('mês com 90 transações monta só os dias visíveis', (t) async {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    final carteira = TransactionWallet(
        walletPk: '0',
        name: 'Conta',
        colour: '0xff4caf50',
        currency: 'brl',
        dateCreated: DateTime(2020),
        order: 0,
        decimals: 2);
    await t.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    await loadCurrencyJSON();
    appStateSettings = {
      ...await getDefaultPreferences(),
      'materialYou': false,
      'accentSystemColor': false,
      'use24HourFormat': '24-hour',
      'selectedWalletPk': '0',
      'netSpendingDayTotal': false,
      'appAnimations': AppAnimations.all.index,
    };
    database = FinanceDatabase(NativeDatabase.memory());
    await database.into(database.wallets).insert(carteira);
    await database.into(database.categories).insert(TransactionCategory(
        categoryPk: 'c1',
        name: 'Mercado',
        colour: '0xff4caf50',
        iconName: 'groceries.png',
        dateCreated: DateTime(2020),
        order: 0,
        income: false,
        methodAdded: null));
    for (var dia = 1; dia <= 30; dia++) {
      for (var n = 0; n < 3; n++) {
        await database.into(database.transactions).insert(Transaction(
            transactionPk: 't$dia-$n',
            name: 'Compra $dia-$n',
            amount: -10,
            note: '',
            categoryFk: 'c1',
            walletFk: '0',
            dateCreated: DateTime(2020, 6, dia, 12),
            income: false,
            paid: true,
            skipPaid: true));
      }
    }
    });

    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MultiProvider(
      providers: [
        Provider<AllWallets>.value(
            value: AllWallets(list: [carteira], indexedByPk: {'0': carteira})),
        StreamProvider<SelectedWalletPk>.value(
            initialData: SelectedWalletPk(selectedWalletPk: '0'),
            value: const Stream<SelectedWalletPk>.empty()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CustomScrollView(slivers: [
            TransactionEntries(DateTime(2020, 6, 1), DateTime(2020, 6, 30),
                listID: 'teste', emCartoes: true),
          ]),
        ),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }

    final montadas = find.byType(TransactionEntry).evaluate().length;
    expect(montadas, greaterThan(0));
    expect(montadas, lessThan(60), reason: 'o mês tem 90; montou $montadas');

    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 5));
  });
}
