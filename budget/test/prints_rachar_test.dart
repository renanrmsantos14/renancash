// Prints da conta dividida com troco (lista, busca e detalhe do Pizza Hut 76,23 − 50 + 11,88 = 38,11).
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_rachar_test.dart --update-goldens
// O emoji 👥 do chip aparece como quadrado aqui (o teste não tem fonte de emoji); no app vem do sistema.
// Os PNGs vão para .verificacao/2026-11-20-t3-rachar-conta-troco/rachar_*.png (fora do git).
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/dateDivider.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart';
import 'package:budget/widgets/editorial/painelTransacao.dart';
import 'package:budget/widgets/editorial/versaoCanto.dart';
import 'package:budget/struct/mbSync/rachadas.dart';
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/widgets/editorial/reembolsoConta.dart' show VinculoReembolso;
import 'package:budget/widgets/transactionEntry/transactionEntry.dart';
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

final _pular = Platform.environment['PRINTS'] != '1';

Map<String, dynamic> _padroes = {};
Map<String, dynamic> _ajustes(String modo) => {
      ..._padroes,
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'forceFullDarkBackground': false,
      'outlinedIcons': true,
      'font': 'Geist',
      // Sem EasyLocalization o formato do sistema (TimeDigits) quebra: fixa 24 h.
      'use24HourFormat': '24-hour',
      'selectedWalletPk': '0',
      'showExtraInfoText': true,
      'nonCompactTransactions': false,
      'netSpendingDayTotal': false,
      'showTransactionsBalanceTransferTab': true,
      'selectedSubscriptionType': 0,
      'loansLastPage': 0,
      'appAnimations': AppAnimations.minimal.index,
      'carteirasArquivadas': <String>['st'],
      'customCurrencyAmounts': <String, dynamic>{},
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'locale': 'pt',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

Transaction _tx(String pk, String nome, double valor, DateTime dia,
        {bool receita = false,
        String cat = 'c1',
        String? sub,
        String carteira = '0',
        String nota = '',
        TransactionSpecialType? tipo,
        BudgetReoccurence? rec,
        bool pago = true}) =>
    Transaction(
      transactionPk: pk,
      name: nome,
      amount: valor,
      note: nota,
      categoryFk: cat,
      subCategoryFk: sub,
      walletFk: carteira,
      dateCreated: dia,
      income: receita,
      paid: pago,
      skipPaid: pago,
      type: tipo,
      periodLength: tipo == null ? null : 1,
      reoccurrence: rec ?? (tipo == null ? null : BudgetReoccurence.monthly),
    );

TransactionCategory _cat(String pk, String nome, String cor, String icone,
        {bool receita = false, String? pai, int ordem = 0}) =>
    TransactionCategory(
        categoryPk: pk,
        name: nome,
        colour: cor,
        iconName: icone,
        dateCreated: DateTime(2026),
        order: ordem,
        income: receita,
        mainCategoryPk: pai,
        methodAdded: null);

TransactionWallet _carteira(String pk, String nome, int ordem,
        {String cor = '0xff4caf50'}) =>
    TransactionWallet(
      walletPk: pk,
      name: nome,
      colour: cor,
      currency: 'brl',
      dateCreated: DateTime(2026),
      order: ordem,
      decimals: 2,
    );

final _cats = {
  'c1': _cat('c1', 'Mercado', '0xff4caf50', 'groceries.png', ordem: 0),
  'sub1': _cat('sub1', 'Hortifruti', '0xff4caf50', 'groceries.png',
      pai: 'c1', ordem: 1),
  'sub2': _cat('sub2', 'Padaria', '0xff4caf50', 'groceries.png',
      pai: 'c1', ordem: 2),
  'c2': _cat('c2', 'Transporte', '0xff2196f3', 'car.png', ordem: 3),
  'c3': _cat('c3', 'Renda', '0xff9c27b0', 'coin.png', receita: true, ordem: 4),
  'c4': _cat('c4', 'Lazer', '0xffff9800', 'coin.png', ordem: 5),
  'sub_spot': _cat('sub_spot', 'Spotify', '0xffff9800', 'coin.png',
      pai: 'c4', ordem: 6),
};

final _todasCarteiras = [
  _carteira('0', 'BANCO INTER ·69-6', 0),
  _carteira('mb:poup', 'BANCO INTER ·69-6', 1, cor: '0xff2196f3'),
  _carteira('mb:nu', 'Nubank', 2, cor: '0xff9c27b0'),
  _carteira('st', 'Santander Antigo', 3, cor: '0xfff44336'),
];

AllWallets _allWallets({bool incluirArquivadaNaLista = true}) => AllWallets(
      list: incluirArquivadaNaLista
          ? _todasCarteiras
          : _todasCarteiras.where((w) => w.walletPk != 'st').toList(),
      indexedByPk: {for (final w in _todasCarteiras) w.walletPk: w},
    );

/// Banco em memória novo por teste. Não é fechado: o `close()` espera para sempre uma consulta
/// que a AddTransactionPage deixa aberta e travava o `flutter test` no fim do teste.
Future<void> _prepararBanco({bool comDados = true}) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  database = FinanceDatabase(NativeDatabase.memory());
  await mbCriarTabelas();
  await mbGravarEstado({
    'contas': jsonEncode([
      {
        'id': 'cc',
        'type': 'BANK',
        'subtype': 'CHECKING_ACCOUNT',
        'name': 'BANCO INTER ·69-6',
      },
      {
        'id': 'poup',
        'type': 'BANK',
        'subtype': 'SAVINGS_ACCOUNT',
        'name': 'BANCO INTER ·69-6',
      },
    ]),
  });
  for (final w in _todasCarteiras) {
    await database.into(database.wallets).insert(w);
  }
  for (final c in _cats.values) {
    await database.into(database.categories).insert(c);
  }
  final agora = DateTime.now();
  final hoje = DateTime(agora.year, agora.month, agora.day, 12);
  final ontem = hoje.subtract(const Duration(days: 1));
  await mbGarantirOrcamentoGeral(agora: hoje);
  await database.into(database.objectives).insert(ObjectivesCompanion.insert(
        objectivePk: const Value('meta1'),
        name: 'Reserva de Emergência',
        amount: 10000,
        order: 0,
        dateCreated: Value(DateTime(2026, 1, 1)),
        income: const Value(true),
        pinned: const Value(false),
        archived: const Value(false),
        type: const Value(ObjectiveType.goal),
      ));
  if (!comDados) return;
  final lista = [
    _tx('t1', 'Pão de Açúcar', -182.30, hoje,
        cat: 'c1', sub: 'sub1', carteira: '0', nota: 'Compras da semana'),
    _tx('t2', 'Uber Aeroporto', -27.90, hoje,
        cat: 'c2', carteira: 'mb:nu', nota: 'Voo Congonhas'),
    _tx('t3', 'Salário', 6500.00, ontem,
        receita: true, cat: 'c3', carteira: '0'),
    _tx('s1', '', -21.90, hoje.add(const Duration(days: 5)),
        cat: 'c4',
        sub: 'sub_spot',
        carteira: 'mb:nu',
        tipo: TransactionSpecialType.subscription,
        rec: BudgetReoccurence.monthly,
        pago: false),
    _tx('s2', 'Domínio anual', -120.00, hoje.subtract(const Duration(days: 2)),
        cat: 'c2',
        carteira: '0',
        tipo: TransactionSpecialType.subscription,
        rec: BudgetReoccurence.yearly,
        pago: false),
    _tx('l1', 'João — almoço', -85.00, hoje.subtract(const Duration(days: 3)),
        cat: 'c1',
        carteira: '0',
        tipo: TransactionSpecialType.credit,
        receita: false,
        pago: true),
    _tx('l2', 'Carlos — ingresso', 150.00,
        hoje.subtract(const Duration(days: 6)),
        cat: 'c4',
        carteira: 'mb:nu',
        tipo: TransactionSpecialType.debt,
        receita: true,
        pago: true),
  ];
  for (final tx in lista) {
    await database.into(database.transactions).insert(tx);
  }
}

Future<void> _assentar(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 80)));
    await t.pump(const Duration(milliseconds: 100));
  }
  await t.pump(const Duration(seconds: 2));
}

Widget _envolverApp(String modo, Widget home,
    {bool scaffold = true, bool versaoCanto = false}) {
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  return MultiProvider(
    providers: [
      Provider<AllWallets>.value(value: _allWallets()),
      StreamProvider<SelectedWalletPk>.value(
          initialData: SelectedWalletPk(selectedWalletPk: '0'),
          value: const Stream<SelectedWalletPk>.empty()),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(b)),
      navigatorObservers: [ObservadorPaginas()],
      builder: versaoCanto ? (c, child) => VersaoCanto(child: child!) : null,
      home: scaffold ? Scaffold(body: SafeArea(child: home)) : home,
    ),
  );
}

Future<void> _print(WidgetTester t, String modo, String nome, Widget corpo,
    {double largura = 390,
    double altura = 844,
    bool scaffold = true,
    bool versaoCanto = false,
    Future<void> Function(WidgetTester)? aposMontar}) async {
  // ignore: avoid_print
  print('>>> PRINT $nome $modo');
  appStateSettings = _ajustes(modo);
  t.view.physicalSize = Size(largura * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(_envolverApp(modo, corpo,
      scaffold: scaffold, versaoCanto: versaoCanto));
  await _assentar(t);
  if (aposMontar != null) {
    await aposMontar(t);
    await _assentar(t);
  }
  await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
          '../../.verificacao/2026-11-20-t3-rachar-conta-troco/rachar_${nome}_$modo.png'));
  // Desmonta a página e deixa os Future.delayed dela terminarem antes de o teste fechar.
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
    await _fonte('GeistMono',
        ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ??
        'C:/Users/mendo/development/flutter-3.24.5';
    await _fonte('MaterialIcons',
        ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  setUp(() {
    mbEdicaoDesktop.value = null;
    mbTransacaoSelecionada.value = null;
    mbRotaEmpilhada.value = false;
  });


  final dia = DateTime(2026, 11, 18, 12);
  final pizza = _tx('mb:g1', '99food Pizza Hut', -76.23, dia, cat: 'c1');
  final outro = _tx('mb:g2', 'Uber', -27.90, dia, cat: 'c2');

  void rachar() {
    const rec = 'Pix recebido - Valentina De Paula Macedo';
    const dev = 'Pix enviado devolvido - Valentina De Paula Macedo';
    final v = MbVinculoReembolso('mb:r1', 'mb:g1', mbNomeDaPessoa(rec), 5000, data: dia, nome: mbNomeDaPessoa(rec));
    final t = MbTroco('mb:t1', 'mb:r1', 1188, data: dia);
    meuBancoReembolsos.value = [v];
    meuBancoTrocos.value = [t];
    meuBancoRachadas.value = mbCalcularRachadas([v], [t], {'mb:g1'});
    expect(mbNomeDaPessoa(dev), v.nome);
  }

  tearDown(() {
    meuBancoReembolsos.value = const [];
    meuBancoTrocos.value = const [];
    meuBancoRachadas.value = const MbRachadas();
  });

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print lista com a conta dividida $modo', skip: _pular, (t) async {
      rachar();
      await _prepararBanco(comDados: false);
      await _print(
        t,
        modo,
        'lista',
        ListView(children: [
          DateDivider(date: dia, info: '−66,01'),
          for (final tx in [pizza, outro])
            TransactionEntry(
              openPage: const SizedBox(),
              transaction: tx,
              category: _cats[tx.categoryFk],
              listID: 'print',
            ),
        ]),
      );
    });

    testWidgets('print busca por Valentina $modo', skip: _pular, (t) async {
      rachar();
      await _prepararBanco(comDados: false);
      await _print(
        t,
        modo,
        'busca',
        ListView(children: [
          DateDivider(date: dia, info: '−38,11'),
          TransactionEntry(
            openPage: const SizedBox(),
            transaction: pizza,
            category: _cats['c1'],
            listID: 'print',
            busca: 'Valentina',
          ),
        ]),
      );
    });

    testWidgets('print detalhe da conta rachada $modo', skip: _pular, (t) async {
      rachar();
      await _prepararBanco(comDados: false);
      await _print(
        t,
        modo,
        'detalhe',
        ListView(children: [
          TransactionEntry(
            openPage: const SizedBox(),
            transaction: pizza,
            category: _cats['c1'],
            listID: 'print',
          ),
          VinculoReembolso(transacao: pizza),
        ]),
      );
    });
  }
}
