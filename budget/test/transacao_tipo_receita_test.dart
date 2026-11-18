// Receita não vira despesa em silêncio ao escolher categoria (verificar-transacoes).
// Roda com o banco em memória; PRINTS=1 também gera o print do seletor em modo Receita:
//   PRINTS=1 flutter test test/transacao_tipo_receita_test.dart --update-goldens
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultCategories.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart';
import 'package:budget/widgets/categoryIcon.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart' show snackbarKey;
import 'package:budget/widgets/openPopup.dart';
import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

Future<void> _fonte(String familia, List<String> arquivos) async {
  final l = FontLoader(familia);
  for (final a in arquivos) {
    l.addFont(Future.value(ByteData.sublistView(File(a).readAsBytesSync())));
  }
  await l.load();
}

final _prints = Platform.environment['PRINTS'] == '1';
Map<String, dynamic> _padroes = {};

TransactionCategory _cat(String pk, String nome, {bool receita = false}) =>
    TransactionCategory(
        categoryPk: pk,
        name: nome,
        colour: '0xff4caf50',
        iconName: 'coin.png',
        dateCreated: DateTime(2026),
        order: int.parse(pk.replaceAll(RegExp(r'\D'), '')),
        income: receita,
        methodAdded: null);

final _carteira = TransactionWallet(
  walletPk: '0',
  name: 'BANCO INTER',
  colour: '0xff4caf50',
  currency: 'brl',
  dateCreated: DateTime(2026),
  order: 0,
  decimals: 2,
);

Transaction _tx(String pk, double valor, bool receita, String cat,
        {TransactionSpecialType? tipo}) =>
    Transaction(
      transactionPk: pk,
      name: 'Existente $pk',
      amount: valor,
      note: '',
      categoryFk: cat,
      walletFk: '0',
      dateCreated: DateTime(2026, 11, 10, 12),
      income: receita,
      paid: true,
      skipPaid: true,
      type: tipo,
      periodLength: tipo == null ? null : 1,
      reoccurrence: tipo == null ? null : BudgetReoccurence.monthly,
    );

Future<void> _banco() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  database = FinanceDatabase(NativeDatabase.memory());
  await mbCriarTabelas();
  await mbGravarEstado({});
  await database.into(database.wallets).insert(_carteira);
  for (final c in [
    _cat('c1', 'Mercado'),
    _cat('c2', 'Trabalho'),
    _cat('c3', 'Renda', receita: true),
    _cat('c4', 'Salário', receita: true),
  ]) {
    await database.into(database.categories).insert(c);
  }
  await mbGarantirOrcamentoGeral(agora: DateTime(2026, 11, 10, 12));
  await database.into(database.transactions).insert(_tx('e1', -50, false, 'c1'));
  await database.into(database.transactions).insert(_tx('e2', 80, true, 'c3'));
  await database.into(database.transactions).insert(
      _tx('l1', -85, false, 'c1', tipo: TransactionSpecialType.credit));
}

Future<void> _assentar(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
    await t.pump(const Duration(milliseconds: 100));
  }
  await t.pump(const Duration(seconds: 1));
}

Future<void> _abrir(WidgetTester t, AddTransactionPage pagina) async {
  appStateSettings = {
    ..._padroes,
    'materialYou': false,
    'accentSystemColor': false,
    'batterySaver': false,
    'increaseTextContrast': false,
    'forceFullDarkBackground': false,
    'outlinedIcons': true,
    'font': 'Geist',
    'use24HourFormat': '24-hour',
    'selectedWalletPk': '0',
    'appAnimations': AppAnimations.minimal.index,
    'customCurrencyAmounts': <String, dynamic>{},
    'customNumberFormat': true,
    'numberFormatDelimiter': '.',
    'numberFormatDecimal': ',',
    'locale': 'pt',
    'temaPronto': 'padrao-claro',
  };
  t.view.physicalSize = const Size(780, 1688);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      Provider<AllWallets>.value(
          value: AllWallets(list: [_carteira], indexedByPk: {'0': _carteira})),
      StreamProvider<SelectedWalletPk>.value(
          initialData: SelectedWalletPk(selectedWalletPk: '0'),
          value: const Stream<SelectedWalletPk>.empty()),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(Brightness.light)),
      navigatorObservers: [ObservadorPaginas()],
      builder: (c, child) => Stack(children: [
        child!,
        GlobalSnackbar(key: snackbarKey),
      ]),
      home: pagina,
    ),
  ));
  await _assentar(t);
}

AddTransactionPage _nova({TransactionSpecialType? tipo, double? valor = 3400}) =>
    AddTransactionPage(
      startInitialAddTransactionSequence: false,
      selectedAmount: valor,
      selectedIncome: false,
      selectedTitle: 'Salário de novembro',
      selectedType: tipo,
      routesToPopAfterDelete: RoutesToPopAfterDelete.None,
    );

Future<List<Transaction>> _gravadas() => database.select(database.transactions).get();

Future<Transaction> _gravada(String nome) async {
  final todas = await _gravadas();
  // ignore: avoid_print
  return todas.firstWhere((t) => t.name == nome);
}

Future<void> _tocar(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f, warnIfMissed: false);
  await _assentar(t);
}

/// O toque de escolha fica no ícone da categoria, não no nome embaixo.
Finder _icone(String pk) => find
    .byWidgetPredicate((w) => w is CategoryIcon && w.categoryPk == pk)
    .last;

Future<void> _salvar(WidgetTester t) async {
  // ignore: avoid_print
  await _tocar(t, find.text('Salvar'));
  await t.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
  await t.pump(const Duration(seconds: 3));
}

Future<void> _desmontar(WidgetTester t) async {
  // O aviso (snackbar) se fecha sozinho; desmontar antes deixa o ticker ativo.
  await t.pump(const Duration(seconds: 15));
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(seconds: 5));
  await t.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
  await t.pump();
}

void main() {
  setUpAll(() async {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    _padroes = await getDefaultPreferences();
    await loadCurrencyJSON();
    const f = 'assets/fonts/';
    await _fonte('Geist', [
      '${f}Geist-Regular.ttf',
      '${f}Geist-Medium.ttf',
      '${f}Geist-SemiBold.ttf',
    ]);
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '/home/renan/flutter';
    await _fonte('MaterialIcons',
        ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  testWidgets('Receita: o seletor lista só categorias de receita e salva positivo',
      (t) async {
    await t.runAsync(_banco);
    await _abrir(t, _nova());
    await _tocar(t, find.text('income'));
    await _tocar(t, find.text('Selecione a categoria'));
    expect(find.text('Renda'), findsWidgets);
    expect(find.text('Salário'), findsWidgets);
    expect(find.text('Mercado'), findsNothing);
    expect(find.text('Trabalho'), findsNothing);
    if (_prints) {
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/receita_seletor.png'));
    }
    await _tocar(t, _icone('c4'));
    await _salvar(t);
    final tx = await t.runAsync(() => _gravada('Salário de novembro'));
    expect(tx!.income, true);
    expect(tx.amount, 3400);
    expect(tx.categoryFk, 'c4');
    await _desmontar(t);
  });

  testWidgets('Receita + categoria de despesa (mostrar todas) não vira despesa',
      (t) async {
    await t.runAsync(_banco);
    await _abrir(t, _nova());
    await _tocar(t, find.text('income'));
    await _tocar(t, find.text('Selecione a categoria'));
    await _tocar(t, find.byIcon(Icons.more_vert_outlined));
    await _tocar(t, find.text('show-all-categories'));
    expect(find.text('Trabalho'), findsWidgets);
    await _tocar(t, _icone('c2'));
    // O aviso explica que o tipo foi mantido.
    expect(find.textContaining('é categoria de despesa'), findsOneWidget);
    expect(find.text('A transação continua como Receita.'), findsOneWidget);
    await _salvar(t);
    final tx = await t.runAsync(() => _gravada('Salário de novembro'));
    expect(tx!.income, true);
    expect(tx.amount, 3400);
    expect(tx.categoryFk, 'c2');
    await _desmontar(t);
  });

  testWidgets('Despesa continua igual: categoria de despesa grava negativo',
      (t) async {
    await t.runAsync(_banco);
    await _abrir(t, _nova());
    await _tocar(t, find.text('Selecione a categoria'));
    expect(find.text('Mercado'), findsWidgets);
    expect(find.text('Renda'), findsNothing);
    await _tocar(t, _icone('c2'));
    expect(find.textContaining('é categoria de'), findsNothing);
    await _salvar(t);
    final tx = await t.runAsync(() => _gravada('Salário de novembro'));
    expect(tx!.income, false);
    expect(tx.amount, -3400);
    await _desmontar(t);
  });

  testWidgets('Editar mantém o tipo salvo mesmo trocando para categoria do outro tipo',
      (t) async {
    await t.runAsync(_banco);
    final receita = _tx('e2', 80, true, 'c3');
    await _abrir(
        t,
        AddTransactionPage(
            transaction: receita,
            routesToPopAfterDelete: RoutesToPopAfterDelete.None));
    await _tocar(t, find.text('Renda').first);
    await _tocar(t, find.byIcon(Icons.more_vert_outlined));
    await _tocar(t, find.text('show-all-categories'));
    await _tocar(t, _icone('c1'));
    await _salvar(t);
    final tx = await t.runAsync(() => _gravada('Existente e2'));
    expect(tx!.income, true);
    expect(tx.amount, 80);
    expect(tx.categoryFk, 'c1');
    await _desmontar(t);
  });

  test('Empréstimo, meta de empréstimo e ajuste de saldo mantêm o tipo sem avisar',
      () {
    AcaoTipoCategoria acao(
            {bool receita = false,
            bool catReceita = true,
            String pk = 'c3',
            bool adotar = false,
            bool meta = false,
            TransactionSpecialType? tipo}) =>
        acaoTipoAoEscolherCategoria(
          selectedIncome: receita,
          category: _cat(pk, 'X', receita: catReceita),
          adotarTipoDaCategoria: adotar,
          isAddedToLoanObjective: meta,
          selectedType: tipo,
        );
    for (final tipo in [
      TransactionSpecialType.credit,
      TransactionSpecialType.debt
    ]) {
      expect(acao(tipo: tipo), AcaoTipoCategoria.manter);
      expect(acao(tipo: tipo, adotar: true), AcaoTipoCategoria.manter);
    }
    expect(acao(meta: true), AcaoTipoCategoria.manter);
    expect(acao(pk: '0'), AcaoTipoCategoria.manter);
    // Mesmo tipo: nada a fazer.
    expect(acao(receita: true), AcaoTipoCategoria.manter);
    expect(acao(catReceita: false), AcaoTipoCategoria.manter);
    // Tipos diferentes: avisa (tipo escolhido) ou adota (só no fluxo rápido sem tipo).
    expect(acao(receita: true, catReceita: false), AcaoTipoCategoria.avisar);
    expect(acao(), AcaoTipoCategoria.avisar);
    expect(acao(adotar: true), AcaoTipoCategoria.adotar);
  });

  test('Bancos novos ganham Salário e Rendimentos como receita; as demais ficam', () {
    final cats = defaultCategories();
    final receitas = cats.where((c) => c.income).map((c) => c.name).toList();
    expect(receitas, containsAll(['Salário', 'Rendimentos']));
    expect(cats.where((c) => c.income).length, 3);
    expect(cats.map((c) => c.categoryPk).toSet().length, cats.length);
    expect(cats.where((c) => c.categoryPk == '11').single.income, true);
  });
}
