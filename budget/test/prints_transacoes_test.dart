// Prints das telas de transações (verificar-transacoes) para auditoria visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_transacoes_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/transacoes_*.png (fora do git).
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/creditDebtTransactionsPage.dart';
import 'package:budget/pages/subscriptionsPage.dart';
import 'package:budget/pages/transacoesDesktop.dart';
import 'package:budget/pages/transactionFilters.dart';
import 'package:budget/pages/transactionsSearchPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/casosComuns.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/dateDivider.dart';
import 'package:budget/widgets/editorial/detalheTransacao.dart';
import 'package:budget/widgets/editorial/lancamentoRapido.dart';
import 'package:budget/widgets/editorial/lateralEditorial.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart';
import 'package:budget/widgets/editorial/painelTransacao.dart';
import 'package:budget/widgets/editorial/resumoTransacoes.dart';
import 'package:budget/widgets/editorial/versaoCanto.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/noResults.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/slidingSelectorIncomeExpense.dart';
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

bool _bancoAberto = false;

// DIAGNOSTICO (remover): o stdout do teste so aparece no fim, entao o progresso vai para arquivo.
void _diag(String m) => File('/tmp/prints_diag.log').writeAsStringSync(
    '${DateTime.now().toIso8601String()} $m\n',
    mode: FileMode.append);

bool _bancoQuebrado = false;

/// Um banco que travou uma vez trava as próximas: falha logo, com o passo no log.
Future<void> _prepararBanco({bool comDados = true}) async {
  if (_bancoQuebrado) throw StateError('banco travou em teste anterior');
  try {
    await _montarBanco(comDados: comDados).timeout(const Duration(seconds: 25));
  } on TimeoutException {
    _bancoQuebrado = true;
    rethrow;
  }
}

Future<void> _montarBanco({bool comDados = true}) async {
  if (_bancoAberto) {
    await database.close();
    _bancoAberto = false;
  }
  database = FinanceDatabase(NativeDatabase.memory());
  _bancoAberto = true;
  print('>>> db: tabelas');
  _diag('db tabelas');
  await mbCriarTabelas();
  print('>>> db: estado');
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
  print('>>> db: carteiras');
  for (final w in _todasCarteiras) {
    await database.into(database.wallets).insert(w);
  }
  for (final c in _cats.values) {
    await database.into(database.categories).insert(c);
  }
  print('>>> db: categorias ok');
  final agora = DateTime.now();
  final hoje = DateTime(agora.year, agora.month, agora.day, 12);
  final ontem = hoje.subtract(const Duration(days: 1));
  print('>>> db: orcamento');
  await mbGarantirOrcamentoGeral(agora: hoje);
  print('>>> db: meta');
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
  print('>>> db: transacoes');
  _diag('db transacoes');
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

Future<void> _fecharBanco(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump();
  await t.runAsync(() async {
    if (_bancoAberto) {
      await database.close();
      _bancoAberto = false;
    }
  });
}

Future<void> _assentar(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    _diag('assentar $i');
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
  _diag('PRINT $nome $modo');
  appStateSettings = _ajustes(modo);
  t.view.physicalSize = Size(largura * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  _diag('pumpWidget');
  await t.pumpWidget(_envolverApp(modo, corpo,
      scaffold: scaffold, versaoCanto: versaoCanto));
  _diag('assentar');
  await _assentar(t);
  _diag('assentado');
  if (aposMontar != null) {
    await aposMontar(t);
    await _assentar(t);
  }
  _diag('golden');
  await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
          '../../.verificacao/prints/transacoes_${nome}_$modo.png'));
  _diag('golden ok');
  await _fecharBanco(t);
}

Future<DetalheModelo?> _detalheFalso(String pk) async => DetalheModelo(
      pk: pk,
      nome: 'Pão de Açúcar',
      conta: 'BANCO INTER ·69-6',
      categoria: 'Mercado',
      data: DateTime(2026, 11, 17, 14, 30),
      valor: -182.30,
      receita: false,
      historico: const [
        (quando: '10 nov', valor: -145.00),
        (quando: '02 nov', valor: -210.50),
      ],
      media: 179.26,
      noCiclo: 3,
      transacao: _tx('t1', 'Pão de Açúcar', -182.30, DateTime(2026, 11, 17)),
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

  final hoje = DateTime(2026, 11, 12);
  final ontem = DateTime(2026, 11, 11);

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print lista com resumo e filtros $modo', skip: _pular,
        (t) async {
      await _print(
        t,
        modo,
        'lista',
        ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 8, 13, 8),
            child:
                ResumoPeriodo(entradas: 6500, saidas: -2871.15, onTap: () {}),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              AppliedFilterChip(
                  label: 'Limpar',
                  icon: Icons.close_rounded,
                  openFiltersSelection: () {}),
              AppliedFilterChip(
                  label: 'Mercado',
                  customBorderColor: const Color(0xff4caf50),
                  openFiltersSelection: () {}),
              AppliedFilterChip(label: 'Despesa', openFiltersSelection: () {}),
            ]),
          ),
          DateDivider(date: hoje, info: '−210,20'),
          for (final tx in [
            _tx('a', 'Pão de Açúcar', -182.3, hoje),
            _tx('b', 'Uber', -27.9, hoje, cat: 'c2'),
          ])
            TransactionEntry(
              openPage: const SizedBox(),
              transaction: tx,
              category: _cats[tx.categoryFk],
              listID: 'print',
            ),
          DateDivider(date: ontem),
          TransactionEntry(
            openPage: const SizedBox(),
            transaction:
                _tx('c', 'Salário', 6500, ontem, receita: true, cat: 'c3'),
            category: _cats['c3'],
            listID: 'print',
          ),
        ]),
      );
    });

    testWidgets('print agendadas $modo', skip: _pular, (t) async {
      final itens = [
        _tx('d', 'Aluguel', -1800, DateTime.now().add(const Duration(days: 3)),
            tipo: TransactionSpecialType.upcoming, pago: false),
        _tx('e', 'Streaming', -55.9,
            DateTime.now().subtract(const Duration(days: 2)),
            cat: 'c2', tipo: TransactionSpecialType.subscription, pago: false),
      ];
      await _print(
        t,
        modo,
        'agendadas',
        ListView(children: [
          const TotalDestaque(
              rotulo: 'Total a vencer',
              valor: -1855.9,
              legenda: '2 transações'),
          SlidingSelectorIncomeExpense(
              onSelected: (_) {},
              options: const ['Todas', 'A vencer', 'Atrasado']),
          const SizedBox(height: 15),
          for (final tx in itens)
            TransactionEntry(
              aboveWidget: UpcomingTransactionDateHeader(
                  transaction: tx,
                  selectedType: SelectedSubscriptionsType.monthly),
              openPage: const SizedBox(),
              transaction: tx,
              category: _cats[tx.categoryFk],
              listID: 'print',
            ),
        ]),
      );
    });

    testWidgets('print vazio $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'vazio',
        Column(children: [
          const NoResults(message: 'Nenhuma transação em novembro.'),
          AcaoVazio(rotulo: 'Nova transação', onTap: () {}),
        ]),
        altura: 360,
      );
    });

    testWidgets('print AddTransactionPage nova $modo', skip: _pular, (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      await _print(
        t,
        modo,
        'add_nova',
        AddTransactionPage(
          startInitialAddTransactionSequence: false,
          routesToPopAfterDelete: RoutesToPopAfterDelete.None,
        ),
        scaffold: false,
      );
    });

    testWidgets('print AddTransactionPage edicao $modo', skip: _pular,
        (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      final txEdicao = _tx('t1', 'Pão de Açúcar', -182.30, hoje,
          cat: 'c1',
          sub: 'sub1',
          carteira: 'mb:poup',
          nota: 'Compras da semana');
      await _print(
        t,
        modo,
        'add_edicao',
        AddTransactionPage(
          transaction: txEdicao,
          routesToPopAfterDelete: RoutesToPopAfterDelete.None,
        ),
        scaffold: false,
      );
    });

    testWidgets('print AddTransactionPage validacao $modo', skip: _pular,
        (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      await _print(
        t,
        modo,
        'add_validacao',
        AddTransactionPage(
          startInitialAddTransactionSequence: false,
          routesToPopAfterDelete: RoutesToPopAfterDelete.None,
        ),
        scaffold: false,
        aposMontar: (tester) async {
          await tester.tap(find.text('Salvar'));
        },
      );
    });

    testWidgets('print TransactionsSearchPage com resultado $modo',
        skip: _pular, (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      await _print(
        t,
        modo,
        'busca_resultados',
        TransactionsSearchPage(
          initialFilters: SearchFilters(
            categoryPks: ['c1', 'c2'],
            walletPks: ['0', 'mb:nu'],
          ),
        ),
        scaffold: false,
      );
    });

    testWidgets('print TransactionsSearchPage sem resultado $modo',
        skip: _pular, (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      await _print(
        t,
        modo,
        'busca_vazio',
        TransactionsSearchPage(
          initialFilters: SearchFilters(searchQuery: 'inexistente_xyz'),
        ),
        scaffold: false,
      );
    });

    testWidgets('print TransactionFilters folha $modo', skip: _pular,
        (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      final filtros = SearchFilters(
        categoryPks: ['c1'],
        subcategoryPks: ['sub1'],
        expenseIncome: [ExpenseIncome.expense],
        paidStatus: [PaidStatus.paid],
        walletPks: ['0'],
      );
      await _print(
        t,
        modo,
        'filtros',
        ListView(
          children: [
            PopupFramework(
              title: 'Filtros',
              hasPadding: false,
              child: TransactionFiltersSelection(
                searchFilters: filtros,
                setSearchFilters: (_) {},
                clearSearchFilters: () {},
              ),
            ),
          ],
        ),
        altura: 1100,
      );
    });

    testWidgets('print SubscriptionsPage com dados $modo', skip: _pular,
        (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      await _print(
        t,
        modo,
        'assinaturas',
        const SubscriptionsPage(),
        scaffold: false,
      );
    });

    testWidgets('print SubscriptionsPage vazio $modo', skip: _pular, (t) async {
      await t.runAsync(() => _prepararBanco(comDados: false));
      await _print(
        t,
        modo,
        'assinaturas_vazio',
        const SubscriptionsPage(),
        scaffold: false,
      );
    });

    testWidgets('print CreditDebtTransactions com dados $modo', skip: _pular,
        (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      await _print(
        t,
        modo,
        'emprestimos',
        const CreditDebtTransactions(isCredit: null),
        scaffold: false,
      );
    });

    testWidgets('print CreditDebtTransactions vazio $modo', skip: _pular,
        (t) async {
      await t.runAsync(() => _prepararBanco(comDados: false));
      await _print(
        t,
        modo,
        'emprestimos_vazio',
        const CreditDebtTransactions(isCredit: null),
        scaffold: false,
      );
    });

    testWidgets('print LancamentoRapido folha $modo', skip: _pular, (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      const atalho = MbAtalhoRapido(
        'almoço executivo',
        'c1',
        'Mercado',
        45.90,
        subPk: 'sub2',
        subNome: 'Padaria',
      );
      await _print(
        t,
        modo,
        'lancar_rapido',
        Builder(
          builder: (c) => Center(
            child: TextButton(
              onPressed: () => mbLancarRapido(c, atalho),
              child: const Text('Abrir rápido'),
            ),
          ),
        ),
        aposMontar: (tester) async {
          await tester.tap(find.text('Abrir rápido'));
        },
      );
    });
  }

  // Prints Desktop (1440x900 claro, e escuro para os fluxos principais de desktop)
  for (final modo in ['claro', 'escuro']) {
    testWidgets('print TransacoesDesktop com detalhe $modo', skip: _pular,
        (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      mbTransacaoSelecionada.value = 't1';
      mbRotaEmpilhada.value = true;
      await _print(
        t,
        modo,
        'desktop_tabela',
        const LayoutDesktop(
          lateral: LateralEditorial.comDados(contas: [
            (id: 'cc', nome: 'BANCO INTER ·69-6'),
            (id: 'nu', nome: 'Nubank'),
          ]),
          carregarDetalhe: _detalheFalso,
          conteudo: TransacoesDesktop(),
        ),
        largura: 1440,
        altura: 900,
        scaffold: false,
        versaoCanto: true,
      );
    });

    testWidgets('print FormularioTransacao desktop edicao $modo', skip: _pular,
        (t) async {
      await t.runAsync(() => _prepararBanco(comDados: true));
      final txEdicao = _tx('t1', 'Pão de Açúcar', -182.30, hoje,
          cat: 'c1',
          sub: 'sub1',
          carteira: 'mb:poup',
          nota: 'Compras da semana');
      mbEdicaoDesktop.value = EdicaoDesktop(txEdicao);
      mbRotaEmpilhada.value = true;
      await _print(
        t,
        modo,
        'desktop_form_edicao',
        const LayoutDesktop(
          lateral: LateralEditorial.comDados(contas: [
            (id: 'cc', nome: 'BANCO INTER ·69-6'),
            (id: 'nu', nome: 'Nubank'),
          ]),
          carregarDetalhe: _detalheFalso,
          conteudo: TransacoesDesktop(),
        ),
        largura: 1440,
        altura: 900,
        scaffold: false,
        versaoCanto: true,
      );
    });
  }

  testWidgets('print FormularioTransacao desktop novo e validacao claro',
      skip: _pular, (t) async {
    await t.runAsync(() => _prepararBanco(comDados: true));
    mbEdicaoDesktop.value = const EdicaoDesktop(null);
    mbRotaEmpilhada.value = true;
    await _print(
      t,
      'claro',
      'desktop_form_erro',
      const LayoutDesktop(
        lateral: LateralEditorial.comDados(contas: [
          (id: 'cc', nome: 'BANCO INTER ·69-6'),
        ]),
        carregarDetalhe: _detalheFalso,
        conteudo: TransacoesDesktop(),
      ),
      largura: 1440,
      altura: 900,
      scaffold: false,
      versaoCanto: true,
      aposMontar: (tester) async {
        await tester.tap(find.text('Salvar'));
      },
    );
  });

  testWidgets('print TransacoesDesktop vazio claro', skip: _pular, (t) async {
    await t.runAsync(() => _prepararBanco(comDados: false));
    await _print(
      t,
      'claro',
      'desktop_vazio',
      const LayoutDesktop(
        lateral: LateralEditorial.comDados(contas: []),
        carregarDetalhe: _detalheFalso,
        conteudo: TransacoesDesktop(),
      ),
      largura: 1440,
      altura: 900,
      scaffold: false,
    );
  });

  testWidgets('print AddTransactionPage desktop claro', skip: _pular,
      (t) async {
    await t.runAsync(() => _prepararBanco(comDados: true));
    final txEdicao = _tx('t1', 'Pão de Açúcar', -182.30, hoje,
        cat: 'c1', sub: 'sub1', carteira: 'mb:poup', nota: 'Compras da semana');
    await _print(
      t,
      'claro',
      'add_desktop',
      AddTransactionPage(
        transaction: txEdicao,
        routesToPopAfterDelete: RoutesToPopAfterDelete.None,
      ),
      largura: 1440,
      altura: 900,
      scaffold: false,
    );
  });

  testWidgets('print TransactionsSearchPage desktop claro', skip: _pular,
      (t) async {
    await t.runAsync(() => _prepararBanco(comDados: true));
    await _print(
      t,
      'claro',
      'busca_desktop',
      TransactionsSearchPage(
        initialFilters: SearchFilters(categoryPks: ['c1', 'c2']),
      ),
      largura: 1440,
      altura: 900,
      scaffold: false,
    );
  });

  testWidgets('print SubscriptionsPage desktop claro', skip: _pular, (t) async {
    await t.runAsync(() => _prepararBanco(comDados: true));
    await _print(
      t,
      'claro',
      'assinaturas_desktop',
      const SubscriptionsPage(),
      largura: 1440,
      altura: 900,
      scaffold: false,
    );
  });

  testWidgets('print CreditDebtTransactions desktop claro', skip: _pular,
      (t) async {
    await t.runAsync(() => _prepararBanco(comDados: true));
    await _print(
      t,
      'claro',
      'emprestimos_desktop',
      const CreditDebtTransactions(isCredit: null),
      largura: 1440,
      altura: 900,
      scaffold: false,
    );
  });
}
