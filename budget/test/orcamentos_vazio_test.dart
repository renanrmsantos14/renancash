// Orçamentos sem nenhum orçamento: "Criar orçamento" fica na tela do celular (412x915) e abre a criação.
import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:budget/database/initializeDefaultDatabase.dart' show defaultWallet;
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/budgetsListPage.dart';
import 'package:budget/struct/currencyFunctions.dart' show currenciesJSON;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/armazem.dart' show mbCriarTabelas;
import 'package:budget/struct/mbSync/orcamentos.dart' show mbCicloCache;
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

final _carteira = TransactionWallet(
  walletPk: '0',
  name: 'Principal',
  dateCreated: DateTime(2026, 1, 1),
  order: 0,
  currency: 'brl',
  decimals: 2,
  homePageWidgetDisplay: defaultWalletHomePageWidgetDisplay,
);

void main() {
  setUpAll(() async {
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    currenciesJSON =
        json.decode(File('assets/static/generated/currencies.json').readAsStringSync());
  });

  for (final aba in [true, false]) {
    testWidgets(
        aba
            ? 'sem orçamentos, na aba (com Análise): botão dentro da tela e o toque abre a criação'
            : 'sem orçamentos, página empilhada: botão dentro da tela e o toque abre a criação',
        (t) async {
      appStateSettings = {
        ...await getDefaultPreferences(),
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'outlinedIcons': true,
        'selectedWalletPk': '0',
        'locale': 'pt',
        'temaPronto': 'padrao-claro',
      };
      t.view.physicalSize = const Size(412 * 2, 915 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      mbCicloCache = null;
      database = FinanceDatabase(NativeDatabase.memory());
      await t.runAsync(() async {
        await mbCriarTabelas();
        await database.createOrUpdateWallet(defaultWallet().copyWith(
            walletPk: '0', name: 'Principal', currency: const Value('brl'), decimals: 2));
      });
      await t.pumpWidget(MultiProvider(
        providers: [
          Provider<AllWallets>.value(
              value: AllWallets(list: [_carteira], indexedByPk: {'0': _carteira})),
          ChangeNotifierProvider<SelectedWalletPk>.value(
              value: SelectedWalletPk(selectedWalletPk: '0')),
        ],
        child: MaterialApp(
          theme: temaFlutter(temaAtivo(Brightness.light)),
          home: BudgetsListPage(enableBackButton: !aba),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 200));
        await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      }

      final botao = find.text('Criar orçamento');
      expect(botao, findsOneWidget);
      // Dentro da área visível, sem rolar (bem antes do fim da tela de 915 px).
      final r = t.getRect(botao);
      expect(r.top, greaterThan(0));
      expect(r.bottom, lessThan(915 - 80));
      // Na aba, a Análise (patrimônio e gráficos, altos com dados) vem depois: com 3 contas e
      // lançamentos ela empurrava o botão para y≈968, fora da tela.
      if (aba) expect(r.top, lessThan(t.getRect(find.text('Análise')).top));

      await t.tap(botao);
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(AddBudgetPage), findsOneWidget);

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
      // Sem await: o close() do Drift espera timers do relógio falso e travava o teste.
      unawaited(database.close());
    });
  }
}
