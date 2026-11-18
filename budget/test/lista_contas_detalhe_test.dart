// Lista "Contas": tocar numa conta abre o detalhe (saldo e movimentos), não o formulário.
// Editar fica no botão "Editar conta" do detalhe. Páginas reais com banco em memória.
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/pages/editWalletsPage.dart';
import 'package:budget/pages/walletDetailsPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

TransactionWallet _carteira(String pk, String nome, int ordem) =>
    TransactionWallet(
      walletPk: pk,
      name: nome,
      colour: '0xff4caf50',
      currency: 'brl',
      dateCreated: DateTime(2026),
      order: ordem,
      decimals: 2,
    );

final _manual = _carteira('0', 'Carteira manual', 0);
final _mb = _carteira('mb:cc1', 'BANCO INTER ·69-6', 1);
final _todas = AllWallets(
  list: [_manual, _mb],
  indexedByPk: {'0': _manual, 'mb:cc1': _mb},
);

Future<void> _fonte(String familia, List<String> arquivos) async {
  final l = FontLoader(familia);
  for (final a in arquivos) {
    l.addFont(Future.value(ByteData.sublistView(File(a).readAsBytesSync())));
  }
  await l.load();
}

Future<void> _preparar() async {
  database = FinanceDatabase(NativeDatabase.memory());
  await mbCriarTabelas();
  await mbGravarEstado({
    'contas': jsonEncode([
      {
        'id': 'cc1',
        'type': 'BANK',
        'subtype': 'CHECKING_ACCOUNT',
        'name': 'BANCO INTER ·69-6',
        'balance': 927.28,
      },
    ]),
  });
  for (final w in [_manual, _mb]) {
    await database.into(database.wallets).insert(w);
  }
  await database.into(database.categories).insert(TransactionCategory(
      categoryPk: 'c1',
      name: 'Mercado',
      colour: '0xff4caf50',
      iconName: 'groceries.png',
      dateCreated: DateTime(2026),
      order: 0,
      income: false,
      methodAdded: null));
  final hoje = DateTime.now();
  for (final (pk, carteira, nome, valor) in [
    ('t1', '0', 'Padaria manual', -12.5),
    ('t2', 'mb:cc1', 'Mercado do banco', -80.0),
  ]) {
    await database.into(database.transactions).insert(Transaction(
          transactionPk: pk,
          name: nome,
          amount: valor,
          note: '',
          categoryFk: 'c1',
          walletFk: carteira,
          dateCreated: DateTime(hoje.year, hoje.month, hoje.day, 12),
          income: false,
          paid: true,
          skipPaid: true,
        ));
  }
}

Future<void> _assentar(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 80)));
    await t.pump(const Duration(milliseconds: 100));
  }
  await t.pump(const Duration(seconds: 1));
}

Widget _app() => MultiProvider(
      providers: [
        Provider<AllWallets>.value(value: _todas),
        ChangeNotifierProvider<SelectedWalletPk>.value(
            value: SelectedWalletPk(selectedWalletPk: '0')),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(Brightness.light)),
        home: EditWalletsPage(),
      ),
    );

void main() {
  setUpAll(() async {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    final padroes = await getDefaultPreferences();
    appStateSettings = {
      ...padroes,
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'outlinedIcons': true,
      'font': 'Geist',
      'use24HourFormat': '24-hour',
      'selectedWalletPk': '0',
      'customCurrencyAmounts': <String, dynamic>{},
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'locale': 'pt',
      'temaPronto': 'padrao-claro',
      'appAnimations': AppAnimations.minimal.index,
    };
    await loadCurrencyJSON();
    const f = 'assets/fonts/';
    await _fonte('Geist', ['${f}Geist-Regular.ttf', '${f}Geist-Medium.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '';
    await _fonte('MaterialIcons',
        ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  setUp(() async {
    driftRuntimeOptionsSemAviso();
  });

  Future<void> abrirLista(WidgetTester t) async {
    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.runAsync(_preparar);
    await t.pumpWidget(_app());
    await _assentar(t);
  }

  Future<void> encerrar(WidgetTester t) async {
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 5));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await t.pump();
  }

  for (final (rotulo, nome) in [
    ('conta manual', 'Carteira manual'),
    ('conta do Meu Banco (mb:)', 'BANCO INTER ·69-6'),
  ]) {
    testWidgets('tocar na $rotulo abre o detalhe, não o formulário',
        (t) async {
      await abrirLista(t);
      expect(find.text(nome), findsWidgets);
      await t.tap(find.text(nome).first);
      await _assentar(t);
      expect(find.byType(WalletDetailsPage), findsOneWidget);
      expect(find.byType(AddWalletPage), findsNothing);
      // Detalhe da conta tocada, com o nome no título.
      expect(find.text(nome), findsWidgets);
      await encerrar(t);
    });
  }

  testWidgets('detalhe mostra saldo e movimentos da conta', (t) async {
    await abrirLista(t);
    await t.tap(find.text('Carteira manual').first);
    await _assentar(t);
    expect(find.byType(WalletDetailsPage), findsOneWidget);
    final pagina = t.widget<WalletDetailsPage>(find.byType(WalletDetailsPage));
    expect(pagina.wallet?.walletPk, '0');
    // Movimentos da conta: saídas do período e atalho para todas as transações.
    expect(find.text('Saldo da conta'), findsOneWidget);
    expect(find.text('−R\$ 12,50'), findsWidgets);
    expect(find.text('−R\$ 80,00'), findsNothing);
    expect(find.text('Mercado'), findsOneWidget);
    expect(find.text('view-all-transactions'), findsOneWidget);
    await encerrar(t);
  });

  // PRINTS=1 flutter test test/lista_contas_detalhe_test.dart --update-goldens
  testWidgets('print detalhe da conta real aberto pela lista',
      skip: Platform.environment['PRINTS'] != '1', (t) async {
    await abrirLista(t);
    await t.tap(find.text('Carteira manual').first);
    await _assentar(t);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../../.verificacao/prints/contas_detalhe_real_claro.png'));
    await encerrar(t);
  });

  testWidgets('"Editar conta" no detalhe abre o formulário da conta',
      (t) async {
    await abrirLista(t);
    await t.tap(find.text('Carteira manual').first);
    await _assentar(t);
    expect(find.byType(AddWalletPage), findsNothing);
    // Botão de edição visível na barra do detalhe (primeiro item do menu).
    final editar = find.byIcon(Icons.edit_outlined);
    expect(editar, findsOneWidget);
    await t.tap(editar);
    await _assentar(t);
    expect(find.byType(AddWalletPage), findsOneWidget);
    expect(
        t.widget<AddWalletPage>(find.byType(AddWalletPage)).wallet?.walletPk,
        '0');
    await encerrar(t);
  });

  testWidgets('reordenar continua funcionando na lista', (t) async {
    await abrirLista(t);
    expect((await t.runAsync(() => database.getAllWallets()))!.map((w) => w.walletPk),
        ['0', 'mb:cc1']);
    final alcas = find.byIcon(Icons.drag_handle_rounded);
    final alca = alcas.evaluate().isEmpty
        ? find.byIcon(Icons.drag_handle_outlined)
        : alcas;
    expect(alca, findsWidgets);
    final g = await t.startGesture(t.getCenter(alca.first));
    for (var i = 0; i < 12; i++) {
      await g.moveBy(const Offset(0, 14));
      await t.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    await _assentar(t);
    final ordem = (await t.runAsync(() => database.getAllWallets()))!
        .map((w) => w.walletPk)
        .toList();
    expect(ordem, ['mb:cc1', '0']);
    await encerrar(t);
  });
}

void driftRuntimeOptionsSemAviso() {
  // Vários bancos em memória no mesmo processo de teste.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
}
