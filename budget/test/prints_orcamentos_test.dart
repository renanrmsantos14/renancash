// Prints de Orçamentos e Metas (Etapa 4 da revisão de UI) para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_orcamentos_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/ (fora do git).
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:budget/database/initializeDefaultDatabase.dart' show defaultWallet;
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/addObjectivePage.dart';
import 'package:budget/pages/addTransactionPage.dart' show RoutesToPopAfterDelete;
import 'package:budget/pages/analiseOrcamentos.dart';
import 'package:budget/pages/budgetPage.dart';
import 'package:budget/pages/budgetsListPage.dart';
import 'package:budget/pages/editBudgetLimitsPage.dart';
import 'package:budget/pages/editBudgetPage.dart';
import 'package:budget/pages/editObjectivesPage.dart';
import 'package:budget/pages/objectivePage.dart';
import 'package:budget/pages/objectivesListPage.dart';
import 'package:budget/pages/pastBudgetsPage.dart';
import 'package:budget/struct/currencyFunctions.dart' show currenciesJSON;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/armazem.dart' show mbCriarTabelas, mbGravarEstado;
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/mbSync/orcamentos.dart' show mbCicloCache, mbOrcamentoGeralPk;
import 'package:budget/struct/mbSync/sugestaoLimites.dart';
import 'package:budget/struct/meuBancoMapping.dart' show mbCarteiraInvestimentos;
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/budgetContainer.dart';
import 'package:budget/widgets/mbAplicacoesDaMeta.dart';
import 'package:budget/widgets/sugestaoLimites.dart';
import 'package:drift/drift.dart' show Value;
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
      'selectedWalletPk': '0',
      'showTotalSpentForBudget': false,
      'showTotalSpentForObjective': false,
      'customCurrencyAmounts': <String, dynamic>{},
      // Números como no pt-BR (1.758,85) sem depender do locale da máquina.
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'locale': 'pt',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

final _carteiraPadrao = TransactionWallet(
  walletPk: '0',
  name: 'Principal',
  dateCreated: DateTime(2026, 1, 1),
  order: 0,
  currency: 'brl',
  decimals: 2,
  homePageWidgetDisplay: defaultWalletHomePageWidgetDisplay,
);

final _carteirasProvider = AllWallets(
  list: [_carteiraPadrao],
  indexedByPk: {'0': _carteiraPadrao},
);

Widget _app(String modo, Widget corpo, {bool usarScaffold = true}) {
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  return MultiProvider(
    providers: [
      Provider<AllWallets>.value(value: _carteirasProvider),
      Provider<SelectedWalletPk>.value(
          value: SelectedWalletPk(selectedWalletPk: '0')),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(b)),
      home: usarScaffold ? Scaffold(body: SafeArea(child: corpo)) : corpo,
    ),
  );
}

Widget _titulo(BuildContext c, String t) => Padding(
      padding: const EdgeInsets.fromLTRB(13, 14, 13, 12),
      child: Text(t,
          style: const TextStyle(
              fontFamily: 'Geist', fontSize: 20, fontWeight: FontWeight.w600)),
    );

Future<void> _print(WidgetTester t, String nome) async {
  await t.pump(const Duration(seconds: 2));
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../.verificacao/prints/$nome.png'));
}

void _tela(WidgetTester t, {double largura = 390, double altura = 844}) {
  t.view.physicalSize = Size(largura * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
}

Objective _meta(String pk, String nome, double alvo,
        {String? icone = 'coconut-tree.png',
        String cor = '0xff4caf50',
        ObjectiveType tipo = ObjectiveType.goal,
        bool receita = true,
        DateTime? fim}) =>
    Objective(
      objectivePk: pk,
      name: nome,
      amount: alvo,
      order: 0,
      dateCreated: DateTime(2026, 6, 1),
      endDate: fim,
      income: receita,
      pinned: false,
      iconName: icone,
      colour: cor,
      walletFk: '0',
      archived: false,
      type: tipo,
    );

// Ícones das metas são PNG: decodificar fora do relógio falso.
Future<void> _printComIcones(WidgetTester t, String nome) async {
  await t.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
  await _print(t, nome);
}

/// Prepara banco em memória para exercitar páginas completas que consultam o Drift.
Future<Budget> _prepararBanco({
  bool vazio = false,
  bool semLancamentos = false,
  bool limitesEstourados = false,
  bool semLimites = false,
}) async {
  mbCicloCache = null;
  database = FinanceDatabase(NativeDatabase.memory());
  await mbCriarTabelas();
  await database.createOrUpdateWallet(
    defaultWallet().copyWith(
      walletPk: '0',
      name: 'Principal',
      currency: const Value('brl'),
      decimals: 2,
    ),
  );
  await database.createOrUpdateWallet(
    defaultWallet().copyWith(
      walletPk: 'mb:inter',
      name: 'Banco Inter',
      currency: const Value('brl'),
      decimals: 2,
      order: 1,
    ),
  );
  await database.createOrUpdateWallet(
    defaultWallet().copyWith(
      walletPk: mbCarteiraInvestimentos,
      name: 'Investimentos',
      currency: const Value('brl'),
      decimals: 2,
      order: 2,
    ),
  );

  for (final (pk, nome, cor, icone, receita, pai, ordem) in [
    ('ali', 'Alimentação', '0xff4caf50', 'groceries.png', false, null, 0),
    ('alm', 'Almoço Betinhos', '0xff4caf50', 'cutlery.png', false, 'ali', 1),
    ('mer', 'Mercado', '0xff4caf50', 'groceries.png', false, 'ali', 2),
    ('tra', 'Transporte', '0xff2196f3', 'car(1).png', false, null, 3),
    ('ube', 'Uber', '0xff2196f3', 'car(1).png', false, 'tra', 4),
    ('ren', 'Salário', '0xff9c27b0', 'coin.png', true, null, 5),
  ]) {
    await database.into(database.categories).insert(
          CategoriesCompanion.insert(
            categoryPk: Value(pk),
            name: nome,
            colour: Value(cor),
            iconName: Value(icone),
            income: Value(receita),
            mainCategoryPk: Value(pai),
            order: ordem,
            dateCreated: Value(DateTime(2026, 1, 1)),
            dateTimeModified: Value(DateTime(2026, 1, 1)),
          ),
        );
  }

  final agora = DateTime.now();
  final inicioMes = DateTime(agora.year, agora.month, 1);
  final fimMes = DateTime(agora.year, agora.month + 1, 0, 23, 59, 59);

  final orcamentoGeral = Budget(
    budgetPk: mbOrcamentoGeralPk,
    name: 'Ciclo do salário',
    amount: 4630,
    colour: '0xff4caf50',
    startDate: inicioMes,
    endDate: fimMes,
    addedTransactionsOnly: false,
    periodLength: 1,
    reoccurrence: BudgetReoccurence.monthly,
    dateCreated: DateTime(2026, 1, 1),
    pinned: true,
    order: 0,
    walletFk: '0',
    budgetTransactionFilters: const [
      BudgetTransactionFilters.defaultBudgetTransactionFilters
    ],
    isAbsoluteSpendingLimit: true,
    income: false,
    archived: false,
  );

  if (vazio) return orcamentoGeral;

  await database.into(database.budgets).insert(
        BudgetsCompanion.insert(
          budgetPk: const Value(mbOrcamentoGeralPk),
          name: orcamentoGeral.name,
          amount: orcamentoGeral.amount,
          colour: Value(orcamentoGeral.colour),
          startDate: orcamentoGeral.startDate,
          endDate: orcamentoGeral.endDate,
          addedTransactionsOnly: const Value(false),
          periodLength: 1,
          reoccurrence: const Value(BudgetReoccurence.monthly),
          order: 0,
          walletFk: const Value('0'),
          pinned: const Value(true),
          isAbsoluteSpendingLimit: const Value(true),
          income: const Value(false),
          archived: const Value(false),
          budgetTransactionFilters: const Value([
            BudgetTransactionFilters.defaultBudgetTransactionFilters
          ]),
          dateTimeModified: Value(agora),
        ),
      );

  await database.into(database.budgets).insert(
        BudgetsCompanion.insert(
          budgetPk: const Value('mercado'),
          name: 'Mercado e feira',
          amount: 1200,
          colour: const Value('0xffff9800'),
          startDate: inicioMes,
          endDate: fimMes,
          addedTransactionsOnly: const Value(false),
          periodLength: 1,
          reoccurrence: const Value(BudgetReoccurence.monthly),
          order: 1,
          walletFk: const Value('0'),
          categoryFks: const Value(['ali']),
          pinned: const Value(false),
          isAbsoluteSpendingLimit: const Value(true),
          income: const Value(false),
          archived: const Value(false),
          budgetTransactionFilters: const Value([
            BudgetTransactionFilters.defaultBudgetTransactionFilters
          ]),
          dateTimeModified: Value(agora),
        ),
      );

  await database.into(database.budgets).insert(
        BudgetsCompanion.insert(
          budgetPk: const Value('arquivado'),
          name: 'Viagem antiga',
          amount: 2000,
          colour: const Value('0xff607d8b'),
          startDate: DateTime(2026, 5, 1),
          endDate: DateTime(2026, 5, 31),
          addedTransactionsOnly: const Value(true),
          periodLength: 1,
          reoccurrence: const Value(BudgetReoccurence.custom),
          order: 2,
          walletFk: const Value('0'),
          pinned: const Value(false),
          isAbsoluteSpendingLimit: const Value(true),
          income: const Value(false),
          archived: const Value(true),
          dateTimeModified: Value(agora),
        ),
      );

  if (!semLimites) {
    final limites = limitesEstourados
        ? [
            ('l1', 'ali', 3200.0),
            ('l2', 'alm', 2000.0),
            ('l3', 'mer', 1800.0),
            ('l4', 'tra', 2100.0),
          ]
        : [
            ('l1', 'ali', 1200.0),
            ('l2', 'alm', 450.0),
            ('l3', 'mer', 600.0),
            ('l4', 'tra', 600.0),
          ];
    for (final (pk, cat, valor) in limites) {
      await database.into(database.categoryBudgetLimits).insert(
            CategoryBudgetLimitsCompanion.insert(
              categoryLimitPk: Value(pk),
              categoryFk: cat,
              budgetFk: mbOrcamentoGeralPk,
              amount: valor,
              walletFk: const Value('0'),
              dateTimeModified: Value(agora),
            ),
          );
    }
  }

  for (final (pk, nome, alvo, icone, cor, receita, arquivada, fim, ordem) in [
    (
      mbMetaReservaPk,
      'Reserva de emergência',
      5000.0,
      null,
      '0xff2196f3',
      true,
      false,
      DateTime(2027, 4, 14),
      0
    ),
    (
      'meta-chile',
      'Viagem para o Chile',
      12000.0,
      'coconut-tree.png',
      '0xff4caf50',
      true,
      false,
      DateTime(2027, 6, 30),
      1
    ),
    (
      'meta-reforma',
      'Reforma do escritório',
      3000.0,
      'cutlery.png',
      '0xffff9800',
      false,
      false,
      DateTime(2027, 3, 15),
      2
    ),
    (
      'meta-arq',
      'Meta arquivada',
      1500.0,
      'coin.png',
      '0xff607d8b',
      true,
      true,
      null,
      3
    ),
  ]) {
    await database.into(database.objectives).insert(
          ObjectivesCompanion.insert(
            objectivePk: Value(pk),
            name: nome,
            amount: alvo,
            order: ordem,
            dateCreated: Value(DateTime(2026, 6, 1)),
            endDate: Value(fim),
            income: Value(receita),
            pinned: Value(ordem == 0),
            iconName: Value(icone),
            colour: Value(cor),
            walletFk: const Value('0'),
            archived: Value(arquivada),
            type: const Value(ObjectiveType.goal),
            dateTimeModified: Value(agora),
          ),
        );
  }

  if (!semLancamentos) {
    final txs = [
      ('t1', 'Pão de Açúcar', -480.50, 'ali', 'mer', false, agora.subtract(const Duration(days: 2)), null),
      ('t2', 'Restaurante Betinhos', -290.65, 'ali', 'alm', false, agora.subtract(const Duration(days: 5)), null),
      ('t3', 'Uber Aeroporto', -185.40, 'tra', 'ube', false, agora.subtract(const Duration(days: 3)), null),
      ('t4', 'Salário mensal', 6500.0, 'ren', null, true, agora.subtract(const Duration(days: 8)), null),
      ('t5', 'Depósito Chile', 1200.0, 'ren', null, true, agora.subtract(const Duration(days: 4)), 'meta-chile'),
      ('t6', 'Mercado mês passado', -920.0, 'ali', 'mer', false, DateTime(agora.year, agora.month - 1, 15), null),
      ('t7', 'Uber mês passado', -310.0, 'tra', 'ube', false, DateTime(agora.year, agora.month - 1, 18), null),
    ];
    for (final (pk, nome, valor, cat, sub, receita, data, metaFk) in txs) {
      await database.into(database.transactions).insert(
            TransactionsCompanion.insert(
              transactionPk: Value(pk),
              name: nome,
              amount: valor,
              note: '',
              categoryFk: cat,
              subCategoryFk: Value(sub),
              walletFk: const Value('0'),
              dateCreated: Value(data),
              income: Value(receita),
              paid: const Value(true),
              skipPaid: const Value(false),
              objectiveFk: Value(metaFk),
              dateTimeModified: Value(data),
            ),
          );
    }

    // Aplicações do Meu Banco na carteira Investimentos.
    for (final (id, nome, banco, saldo) in [
      ('a', 'CDB - BANCO INTER S.A', 'BANCO INTER', 550.03),
      ('b', 'CDB - BANCO INTER S.A', 'BANCO INTER', 430.21),
      ('c', 'CDB - BANCO INTER S.A', 'BANCO INTER', 107.87),
      ('d', 'CDB - BANCO SANTANDER (BRASIL) S.A.', 'BANCO SANTANDER', 133.69),
      ('e', 'Tesouro Prefixado 2029', 'BANCO INTER', 7.37),
    ]) {
      await database.into(database.transactions).insert(
            TransactionsCompanion.insert(
              transactionPk: Value(mbPkAplicacao(id)),
              name: nome,
              amount: saldo,
              note: banco,
              categoryFk: 'ren',
              walletFk: const Value(mbCarteiraInvestimentos),
              dateCreated: Value(agora),
              income: const Value(true),
              paid: const Value(true),
              skipPaid: const Value(false),
              dateTimeModified: Value(agora),
            ),
          );
    }
    await mbDefinirAplicacoesDaMeta(mbMetaReservaPk, [
      mbPkAplicacao('a'),
      mbPkAplicacao('b'),
      mbPkAplicacao('c'),
      mbPkAplicacao('d'),
    ]);

    await mbGravarEstado({
      'contas': jsonEncode([
        {
          'id': 'c1',
          'type': 'BANK',
          'subtype': 'CHECKING_ACCOUNT',
          'name': 'Banco Inter',
          'bank': 'Inter',
          'balance': 3102.90,
        },
        {
          'id': 'c2',
          'type': 'BANK',
          'subtype': 'SAVINGS_ACCOUNT',
          'name': 'Poupança Inter',
          'bank': 'Inter',
          'balance': 850.00,
        },
        {
          'id': 'c3',
          'type': 'CREDIT',
          'name': 'Cartão Inter',
          'bank': 'Inter',
          'balance': 569.25,
          'credit_limit': 4000.0,
          'closing_date': '2026-11-10',
          'due_date': '2026-11-17',
        },
      ]),
      'faturas': jsonEncode({}),
    });
  }

  return orcamentoGeral;
}

Future<void> _printPaginaComBanco(
  WidgetTester t,
  String modo,
  String nome,
  Widget Function(Budget orcamentoGeral) construir, {
  double largura = 390,
  double altura = 844,
  bool vazio = false,
  bool semLancamentos = false,
  bool limitesEstourados = false,
  bool semLimites = false,
  bool usarScaffold = false,
}) async {
  appStateSettings = _ajustes(modo);
  _tela(t, largura: largura, altura: altura);
  late Budget orc;
  await t.runAsync(() async {
    orc = await _prepararBanco(
      vazio: vazio,
      semLancamentos: semLancamentos,
      limitesEstourados: limitesEstourados,
      semLimites: semLimites,
    );
  });
  await t.pumpWidget(_app(modo, construir(orc), usarScaffold: usarScaffold));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 200));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
  }
  for (var i = 0; i < 35; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../.verificacao/prints/$nome.png'));
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 3));
  await t.runAsync(() => database.close());
}

void main() {
  setUpAll(() async {
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    _padroes = await getDefaultPreferences();
    currenciesJSON = json.decode(
        File('assets/static/generated/currencies.json').readAsStringSync());
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

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print orçamentos lista $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t);
      await t.pumpWidget(_app(
        modo,
        Builder(
          builder: (c) => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            children: [
              _titulo(c, 'Orçamentos'),
              const CartaoOrcamento(
                nome: 'Ciclo do salário',
                cor: Color(0xFF4CAF50),
                periodo: '5 de nov. – 4 de dez.',
                gasto: 2871.15,
                limite: 4630,
                diasRestantes: 22,
                aVencer: 420,
                hoje: 9 / 30,
              ),
              const SizedBox(height: 12),
              const CartaoOrcamento(
                nome: 'Mercado',
                cor: Color(0xFFFF9800),
                periodo: '1 de nov. – 30 de nov.',
                gasto: 1312.4,
                limite: 1200,
                diasRestantes: 18,
                hoje: 13 / 30,
              ),
              const SizedBox(height: 12),
              const CartaoOrcamento(
                nome: 'Reserva do mês',
                cor: Color(0xFF2196F3),
                periodo: '1 de nov. – 30 de nov.',
                gasto: 650,
                limite: 1000,
                renda: true,
                diasRestantes: 18,
                hoje: 13 / 30,
              ),
            ],
          ),
        ),
      ));
      await _print(t, 'orcamentos_lista_$modo');
    });

    testWidgets('print orçamentos vazio $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 420);
      await t.pumpWidget(_app(
          modo,
          Builder(
              builder: (c) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [_titulo(c, 'Orçamentos'), const SemOrcamentos()],
                  ))));
      await _print(t, 'orcamentos_vazio_$modo');
    });

    for (final (nome, gasto, mostrarGasto) in [
      ('detalhe', 2871.15, false),
      ('estourado', 4980.0, false),
      ('gasto', 2871.15, true),
    ]) {
      testWidgets('print orçamento $nome $modo', skip: _pular, (t) async {
        appStateSettings = _ajustes(modo);
        _tela(t, altura: 420);
        await t.pumpWidget(_app(
          modo,
          Builder(
            builder: (c) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _titulo(c, 'Ciclo do salário'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(13, 4, 13, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('5 de nov. – 4 de dez.',
                          style: EdTexto.rotulo(c)),
                      const SizedBox(height: 8),
                      ResumoOrcamento(
                        gasto: gasto,
                        limite: 4630,
                        grande: true,
                        mostrarGasto: mostrarGasto,
                        diasRestantes: 22,
                        aVencer: 420,
                        hoje: 9 / 30,
                        onTapValor: () {},
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(13, 4, 13, 16),
                  child: Text('Gasto por categoria', style: EdTexto.h2(c)),
                ),
              ],
            ),
          ),
        ));
        await _print(t, 'orcamentos_${nome}_$modo');
      });
    }

    testWidgets('print orçamentos histórico $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 520);
      await t.pumpWidget(_app(
        modo,
        Builder(
          builder: (c) => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            children: [
              _titulo(c, 'Histórico'),
              for (final (titulo, gasto) in [
                ('Ciclo atual', 2871.15),
                ('5 de out. – 4 de nov.', 4980.0),
                ('5 de set. – 4 de out.', 4102.3),
              ]) ...[
                LinhaCicloOrcamento(titulo: titulo, gasto: gasto, limite: 4630),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ));
      await _print(t, 'orcamentos_historico_$modo');
    });

    testWidgets('print metas lista $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t);
      await t.pumpWidget(_app(
        modo,
        Builder(
          builder: (c) => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            children: [
              _titulo(c, 'Metas'),
              CartaoMeta(
                  objective: _meta('a', 'Viagem para o Chile', 12000,
                      fim: DateTime(2027, 6, 30)),
                  alvo: 12000,
                  total: 4350.5,
                  fracao: 4350.5 / 12000,
                  transacoes: 7),
              const SizedBox(height: 12),
              CartaoMeta(
                  objective: _meta('b', 'Carro novo', 5000,
                      icone: 'car(1).png', cor: '0xffff9800'),
                  alvo: 5000,
                  total: 5000,
                  fracao: 1,
                  mostrarTotal: true,
                  transacoes: 12),
              const SizedBox(height: 12),
              CartaoMeta(
                  objective: _meta('c', 'Reserva de emergência', 0,
                      icone: 'coin.png', cor: '0xff2196f3'),
                  alvo: 0,
                  total: 8120,
                  fracao: 0,
                  onDefinirValor: () {}),
              const SizedBox(height: 12),
              LinhaEmprestimoDiferenca(
                  objective: _meta('d', 'Pai', -1,
                      icone: 'coin.png',
                      cor: '0xff9c27b0',
                      tipo: ObjectiveType.loan),
                  diferenca: 850,
                  quitado: false,
                  transacoes: 3),
            ],
          ),
        ),
      ));
      await _printComIcones(t, 'metas_lista_$modo');
    });

    testWidgets('print metas vazio $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 420);
      await t.pumpWidget(_app(
          modo,
          Builder(
              builder: (c) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _titulo(c, 'Metas'),
                      VazioMetas(emprestimo: false, onCriar: () {}),
                    ],
                  ))));
      await _print(t, 'metas_vazio_$modo');
    });

    testWidgets('print meta detalhe $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 460);
      await t.pumpWidget(_app(
        modo,
        Builder(
          builder: (c) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _titulo(c, 'Viagem para o Chile'),
              ResumoMeta(
                objective: _meta('a', 'Viagem para o Chile', 12000,
                    fim: DateTime(2027, 6, 30)),
                alvo: 12000,
                total: 4350.5,
                fracao: 4350.5 / 12000,
                mostrarTotal: false,
                transacoes: 7,
                onTrocar: () {},
                onIcone: () {},
              ),
            ],
          ),
        ),
      ));
      await _printComIcones(t, 'metas_detalhe_$modo');
    });

    // Reserva de emergência real: R$ 5.000 até 14/04/2027, sem ícone, nada ligado e 10 aplicações livres.
    for (final (nome, ligadas) in [('vazia', false), ('aplicacoes', true)]) {
      testWidgets('print meta reserva $nome $modo', skip: _pular, (t) async {
        appStateSettings = _ajustes(modo);
        _tela(t, altura: ligadas ? 760 : 560);
        final aplicacoes = [
          for (final (id, n, v) in [
            ('a', 'CDB - BANCO INTER S.A', 550.03),
            ('b', 'CDB - BANCO INTER S.A', 430.21),
            ('c', 'CDB - BANCO INTER S.A', 107.87),
            ('d', 'CDB - BANCO SANTANDER (BRASIL) S.A.', 133.69),
            ('e', 'Tesouro Prefixado 2029', 7.37),
          ])
            MbAplicacao(mbPkAplicacao(id), n, 'BANCO INTER', v,
                ligadas ? mbMetaReservaPk : null)
        ];
        final total = ligadas ? mbSaldoAplicacoes(aplicacoes) : 0.0;
        final meta = Objective(
          objectivePk: mbMetaReservaPk,
          name: 'Reserva de emergência',
          amount: 5000,
          order: 0,
          dateCreated: DateTime(2026, 11, 12),
          endDate: DateTime(2027, 4, 14),
          income: true,
          pinned: true,
          walletFk: '0',
          archived: false,
          type: ObjectiveType.goal,
        );
        await t.pumpWidget(_app(
          modo,
          Builder(
            builder: (c) => ListView(
              children: [
                _titulo(c, 'Reserva de emergência'),
                ResumoMeta(
                  objective: meta,
                  alvo: 5000,
                  total: total,
                  fracao: total / 5000,
                  mostrarTotal: true,
                  transacoes: ligadas ? aplicacoes.length : 0,
                  onTrocar: () {},
                  onIcone: () {},
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: PainelAplicacoesMeta(
                    ligadas: ligadas ? aplicacoes : const [],
                    livres: ligadas ? const [] : aplicacoes,
                    onEscolher: () {},
                    onDepositar: () {},
                  ),
                ),
              ],
            ),
          ),
        ));
        await _printComIcones(t, 'metas_reserva_${nome}_$modo');
      });
    }

    testWidgets('print sugestão de limites $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 720);
      TransactionCategory cat(String pk, String nome, [String? pai]) =>
          TransactionCategory(
              categoryPk: pk,
              name: nome,
              dateCreated: DateTime(2026),
              order: 0,
              income: false,
              mainCategoryPk: pai);
      final ali = cat('ali', 'Alimentação'), tra = cat('tra', 'Transporte');
      // Médias reais dos ciclos 6/ago–5/nov (Geral).
      final sugestoes = mbSugerirLimites([
        [
          CategoryWithTotal(category: ali, total: -767.27, transactionCount: 33),
          CategoryWithTotal(category: tra, total: -592.54, transactionCount: 21),
          CategoryWithTotal(category: cat('ube', 'Uber', 'tra'), total: -198.06, transactionCount: 11),
          CategoryWithTotal(category: cat('alm', 'Almoço Betinhos', 'ali'), total: -192.89, transactionCount: 10),
          CategoryWithTotal(category: cat('com', 'Combustível', 'tra'), total: -158.34, transactionCount: 5),
          CategoryWithTotal(category: cat('mer', 'Mercado', 'ali'), total: -96.17, transactionCount: 3),
          CategoryWithTotal(category: cat('doc', 'Doces & Besteiras', 'ali'), total: -67.01, transactionCount: 4),
        ],
      ]);
      await t.pumpWidget(_app(
        modo,
        Builder(
          builder: (c) => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _titulo(c, 'Limites por categoria'),
              SugestaoLimites(sugestoes: sugestoes, onSalvar: (_) async {}),
            ],
          ),
        ),
      ));
      await _print(t, 'orcamentos_sugestao_limites_$modo');
    });

    testWidgets('print atalho sugerir limites $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 200);
      await t.pumpWidget(_app(
          modo,
          Padding(
            padding: const EdgeInsets.all(13),
            child: AtalhoSugerirLimites(onTap: () {}),
          )));
      await _print(t, 'orcamentos_atalho_limites_$modo');
    });

    // --- Novas telas cobertas (AddBudgetPage, EditBudgetPage, EditBudgetLimitsPage,
    // AddObjectivePage, EditObjectivesPage, ObjectivePage, AnaliseOrcamentos) ---

    testWidgets('print AddBudgetPage vazio/validação $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_adicionar_vazio_$modo',
        (_) => AddBudgetPage(
          isAddedOnlyBudget: true,
          routesToPopAfterDelete: RoutesToPopAfterDelete.None,
        ),
      );
    });

    testWidgets('print AddBudgetPage com dados $modo', skip: _pular, (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_adicionar_dados_$modo',
        (orc) => AddBudgetPage(
          budget: orc,
          routesToPopAfterDelete: RoutesToPopAfterDelete.One,
        ),
        altura: 1100,
      );
    });

    testWidgets('print EditBudgetPage com dados $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_editar_lista_$modo',
        (_) => EditBudgetPage(),
      );
    });

    testWidgets('print EditBudgetPage vazio $modo', skip: _pular, (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_editar_vazio_$modo',
        (_) => EditBudgetPage(),
        vazio: true,
      );
    });

    testWidgets('print EditBudgetLimitsPage com dados $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_limites_dados_$modo',
        (orc) => EditBudgetLimitsPage(
          budget: orc,
          currentIsAbsoluteSpendingLimit: true,
        ),
      );
    });

    testWidgets('print EditBudgetLimitsPage estourado/erro $modo',
        skip: _pular, (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_limites_estourado_$modo',
        (orc) => EditBudgetLimitsPage(
          budget: orc,
          currentIsAbsoluteSpendingLimit: true,
        ),
        limitesEstourados: true,
      );
    });

    testWidgets('print EditBudgetLimitsPage vazio $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_limites_vazio_$modo',
        (orc) => EditBudgetLimitsPage(
          budget: orc,
          currentIsAbsoluteSpendingLimit: true,
        ),
        semLimites: true,
      );
    });

    testWidgets('print AddObjectivePage vazio/validação $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'metas_adicionar_vazio_$modo',
        (_) => AddObjectivePage(
          objective: _meta('nova', '', 0, icone: null),
          routesToPopAfterDelete: RoutesToPopAfterDelete.PreventDelete,
        ),
        vazio: true,
      );
    });

    testWidgets('print AddObjectivePage com dados e aplicações $modo',
        skip: _pular, (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'metas_adicionar_dados_$modo',
        (_) => AddObjectivePage(
          objective: Objective(
            objectivePk: mbMetaReservaPk,
            name: 'Reserva de emergência para imprevistos',
            amount: 5000,
            order: 0,
            dateCreated: DateTime(2026, 11, 12),
            endDate: DateTime(2027, 4, 14),
            income: true,
            pinned: true,
            walletFk: '0',
            archived: false,
            type: ObjectiveType.goal,
          ),
          routesToPopAfterDelete: RoutesToPopAfterDelete.One,
        ),
        altura: 1050,
      );
    });

    testWidgets('print EditObjectivesPage com dados $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'metas_editar_lista_$modo',
        (_) => EditObjectivesPage(objectiveType: ObjectiveType.goal),
      );
    });

    testWidgets('print EditObjectivesPage vazio $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'metas_editar_vazio_$modo',
        (_) => EditObjectivesPage(objectiveType: ObjectiveType.goal),
        vazio: true,
      );
    });

    testWidgets('print ObjectivePage completa com dados $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'metas_pagina_dados_$modo',
        (_) => const ObjectivePage(objectivePk: mbMetaReservaPk),
        altura: 920,
      );
    });

    testWidgets('print ObjectivePage vazia $modo', skip: _pular, (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'metas_pagina_vazia_$modo',
        (_) => const ObjectivePage(objectivePk: 'meta-reforma'),
        semLancamentos: true,
      );
    });

    testWidgets('print AnaliseOrcamentos com dados $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_analise_dados_$modo',
        (_) => ListView(children: const [AnaliseOrcamentos()]),
        altura: 1180,
        usarScaffold: true,
      );
    });

    testWidgets('print AnaliseOrcamentos vazia $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_analise_vazio_$modo',
        (_) => ListView(children: const [AnaliseOrcamentos()]),
        altura: 560,
        semLancamentos: true,
        usarScaffold: true,
      );
    });

    testWidgets('print BudgetPage completa com dados $modo', skip: _pular,
        (t) async {
      await _printPaginaComBanco(
        t,
        modo,
        'orcamentos_pagina_dados_$modo',
        (_) => const BudgetPage(budgetPk: mbOrcamentoGeralPk),
        altura: 1100,
      );
    });
  }

  // --- Layouts Desktop (1440x900 claro) ---
  testWidgets('print BudgetsListPage + AnaliseOrcamentos desktop claro',
      skip: _pular, (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'orcamentos_lista_desktop_claro',
      (_) => const BudgetsListPage(enableBackButton: false),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print BudgetPage desktop claro', skip: _pular, (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'orcamentos_pagina_desktop_claro',
      (_) => const BudgetPage(budgetPk: mbOrcamentoGeralPk),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print PastBudgetsPage desktop claro', skip: _pular, (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'orcamentos_historico_desktop_claro',
      (_) => const PastBudgetsPage(budgetPk: mbOrcamentoGeralPk),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print AddBudgetPage desktop claro', skip: _pular, (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'orcamentos_adicionar_desktop_claro',
      (orc) => AddBudgetPage(
        budget: orc,
        routesToPopAfterDelete: RoutesToPopAfterDelete.One,
      ),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print EditBudgetPage desktop claro', skip: _pular, (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'orcamentos_editar_desktop_claro',
      (_) => EditBudgetPage(),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print EditBudgetLimitsPage desktop claro', skip: _pular,
      (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'orcamentos_limites_desktop_claro',
      (orc) => EditBudgetLimitsPage(
        budget: orc,
        currentIsAbsoluteSpendingLimit: true,
      ),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print ObjectivesListPage desktop claro', skip: _pular,
      (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'metas_lista_desktop_claro',
      (_) => const ObjectivesListPage(backButton: true),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print EditObjectivesPage desktop claro', skip: _pular,
      (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'metas_editar_desktop_claro',
      (_) => EditObjectivesPage(objectiveType: ObjectiveType.goal),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print ObjectivePage desktop claro', skip: _pular, (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'metas_pagina_desktop_claro',
      (_) => const ObjectivePage(objectivePk: mbMetaReservaPk),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print AddObjectivePage desktop claro', skip: _pular, (t) async {
    await _printPaginaComBanco(
      t,
      'claro',
      'metas_adicionar_desktop_claro',
      (_) => AddObjectivePage(
        objective: Objective(
          objectivePk: mbMetaReservaPk,
          name: 'Reserva de emergência',
          amount: 5000,
          order: 0,
          dateCreated: DateTime(2026, 11, 12),
          endDate: DateTime(2027, 4, 14),
          income: true,
          pinned: true,
          walletFk: '0',
          archived: false,
          type: ObjectiveType.goal,
        ),
        routesToPopAfterDelete: RoutesToPopAfterDelete.One,
      ),
      largura: 1440,
      altura: 900,
    );
  });
}
