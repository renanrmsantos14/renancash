// Prints das telas de transações (Etapa 2 da revisão de UI) para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_transacoes_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/transacoes_*.png (fora do git).
// Sem EasyLocalization nem moedas: textos .tr() saem como chave e valores sem
// R$; o que importa é hierarquia, cor e espaçamento dos componentes.
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/subscriptionsPage.dart';
import 'package:budget/pages/transactionsSearchPage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/dateDivider.dart';
import 'package:budget/widgets/editorial/resumoTransacoes.dart';
import 'package:budget/widgets/noResults.dart';
import 'package:budget/widgets/slidingSelectorIncomeExpense.dart';
import 'package:budget/widgets/transactionEntry/transactionEntry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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
      'showExtraInfoText': true,
      'nonCompactTransactions': false,
      'netSpendingDayTotal': false,
      'customCurrencyAmounts': <String, dynamic>{},
      'locale': 'pt',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

Transaction _tx(String pk, String nome, double valor, DateTime dia,
        {bool receita = false,
        String cat = 'c1',
        TransactionSpecialType? tipo,
        bool pago = true}) =>
    Transaction(
      transactionPk: pk,
      name: nome,
      amount: valor,
      note: '',
      categoryFk: cat,
      walletFk: '0',
      dateCreated: dia,
      income: receita,
      paid: pago,
      skipPaid: pago,
      type: tipo,
      periodLength: tipo == null ? null : 1,
      reoccurrence: tipo == null ? null : BudgetReoccurence.monthly,
    );

TransactionCategory _cat(String pk, String nome, String cor, String icone) =>
    TransactionCategory(
        categoryPk: pk,
        name: nome,
        colour: cor,
        iconName: icone,
        dateCreated: DateTime(2026),
        order: 0,
        income: false,
        methodAdded: null);

final _cats = {
  'c1': _cat('c1', 'Mercado', '0xff4caf50', 'groceries.png'),
  'c2': _cat('c2', 'Transporte', '0xff2196f3', 'car.png'),
  'c3': _cat('c3', 'Renda', '0xff9c27b0', 'coin.png'),
};

Future<void> _print(WidgetTester t, String modo, String nome, Widget corpo,
    {double altura = 844}) async {
  appStateSettings = _ajustes(modo);
  t.view.physicalSize = Size(390 * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  await t.pumpWidget(Provider<AllWallets>.value(
    value: AllWallets(list: const [], indexedByPk: const {}),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(b)),
      home: Scaffold(body: SafeArea(child: corpo)),
    ),
  ));
  // Ícones das categorias são PNG: decodificar fora do relógio falso.
  await t.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
  await t.pump(const Duration(seconds: 2));
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../.verificacao/prints/transacoes_${nome}_$modo.png'));
}

void main() {
  setUpAll(() async {
    _padroes = await getDefaultPreferences();
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
            child: ResumoPeriodo(entradas: 6500, saidas: -2871.15, onTap: () {}),
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
              onSelected: (_) {}, options: const ['Todas', 'A vencer', 'Atrasado']),
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
  }
}
