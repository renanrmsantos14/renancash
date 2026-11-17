// Prints das telas de Contas (Etapa 3 da revisão de UI) para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_contas_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/contas_*.png (fora do git).
// Sem banco local nos testes: as telas entram pelos widgets puros
// (ResumoConta, TotalContas, LinhaConta, InvestimentosConteudo) e pelas
// linhas herdadas alimentadas por Stream.value.
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/investimentosEvolucaoPage.dart';
import 'package:budget/pages/walletDetailsPage.dart' show AmountSpentEntryRow;
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl;
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/editRowEntry.dart';
import 'package:budget/widgets/editorial/contas.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

final _pular = Platform.environment['PRINTS'] != '1';

Future<void> _fonte(String familia, List<String> arquivos) async {
  final l = FontLoader(familia);
  for (final a in arquivos) {
    l.addFont(Future.value(ByteData.sublistView(File(a).readAsBytesSync())));
  }
  await l.load();
}

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
      'customCurrencyAmounts': <String, dynamic>{},
      'locale': 'pt',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

Widget _app(String modo, String titulo, Widget corpo) {
  appStateSettings = _ajustes(modo);
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  return Provider<AllWallets>.value(
    value: AllWallets(list: const [], indexedByPk: const {}),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(b)),
      home: Builder(
        builder: (context) => Scaffold(
          body: SafeArea(
            child: ListView(children: [
              // Cabeçalho compacto de 56 px, como o PageFramework.
              SizedBox(
                height: 56,
                child: Row(children: [
                  const SizedBox(width: 8),
                  Icon(Icons.arrow_back_rounded, color: cores(context).tx),
                  const SizedBox(width: 16),
                  Text(titulo,
                      style: TextStyle(
                          fontFamily: 'Geist',
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: cores(context).tx)),
                ]),
              ),
              corpo,
            ]),
          ),
        ),
      ),
    ),
  );
}

Future<void> _print(WidgetTester t, String modo, String nome, Widget app,
    {double altura = 844}) async {
  t.view.physicalSize = Size(390 * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(app);
  // Streams emitem no 1º quadro; as linhas expandem e os valores contam depois.
  for (var i = 0; i < 25; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../.verificacao/prints/contas_${nome}_$modo.png'));
}

Stream<TotalWithCount?> _total(double v, int n) =>
    Stream.value(TotalWithCount(total: v, count: n));

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

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print detalhe da conta $modo', skip: _pular, (t) async {
      await _print(
          t,
          modo,
          'detalhe',
          _app(
            modo,
            'Conta Nubank',
            Builder(
              builder: (context) => Column(children: [
                ResumoConta(
                  saldo: 3102.90,
                  entradas: 6500,
                  saidas: 2871.15,
                  formatar: brl,
                  periodo: '5 nov – 4 dez',
                  onPeriodo: () {},
                  onEntradas: () {},
                  onSaidas: () {},
                ),
                // Linhas que só aparecem com valor (aqui com valor).
                AmountSpentEntryRow(
                  openPage: const SizedBox(),
                  textColor: cores(context).tx,
                  label: 'Emprestou',
                  absolute: false,
                  invertSign: true,
                  totalWithCountStream: _total(-150, 1),
                ),
                AmountSpentEntryRow(
                  openPage: const SizedBox(),
                  textColor: cores(context).tx,
                  label: 'Por vir',
                  absolute: false,
                  totalWithCountStream: _total(-89.9, 2),
                ),
                AmountSpentEntryRow(
                  openPage: const SizedBox(),
                  textColor: cores(context).warn,
                  label: 'Atrasado',
                  absolute: false,
                  totalWithCountStream: _total(-42, 1),
                ),
              ]),
            ),
          ));
    });

    testWidgets('print detalhe da conta negativa $modo', skip: _pular,
        (t) async {
      await _print(
          t,
          modo,
          'detalhe_negativa',
          _app(
            modo,
            'Cartão Inter',
            ResumoConta(
              saldo: -1240.0,
              entradas: 0,
              saidas: 0,
              formatar: brl,
              periodo: 'Este mês',
            ),
          ),
          altura: 420);
    });

    testWidgets('print lista de contas $modo', skip: _pular, (t) async {
      Widget linha(int i, String nome, String detalhe, double saldo,
              {bool principal = false}) =>
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: EditRowEntry(
              index: i,
              canReorder: true,
              canDelete: false,
              currentReorder: false,
              extraIcon: principal ? Icons.star_rounded : Icons.star_outline,
              onExtra: () {},
              openPage: const SizedBox(),
              content: LinhaConta(
                sigla: nome.substring(0, 2).toUpperCase(),
                nome: nome,
                detalhe: detalhe,
                saldo: comSinal(saldo, brl),
              ),
            ),
          );
      await _print(
          t,
          modo,
          'lista',
          _app(
            modo,
            'Contas',
            Column(children: [
              TotalContas(total: 2978.40, formatar: brl, quantidade: 3),
              linha(0, 'Nubank', 'Principal · 128 transações', 3102.90,
                  principal: true),
              linha(1, 'Itaú', '42 transações', 1115.50),
              linha(2, 'Cartão Inter', '1 transação', -1240.0),
            ]),
          ));
    });

    testWidgets('print investimentos $modo', skip: _pular, (t) async {
      final serie = [
        const MbRetratoMes('2026-09', [
          MbAplicacaoMes('a', 'CDB Inter', 'Inter', 8000),
          MbAplicacaoMes('b', 'Tesouro Selic', 'Santander', 4200),
        ]),
        const MbRetratoMes('2026-10', [
          MbAplicacaoMes('a', 'CDB Inter', 'Inter', 8350),
          MbAplicacaoMes('b', 'Tesouro Selic', 'Santander', 4300),
        ]),
        const MbRetratoMes('2026-11', [
          MbAplicacaoMes('a', 'CDB Inter', 'Inter', 8512.4),
          MbAplicacaoMes('b', 'Tesouro Selic', 'Santander', 4180),
        ]),
      ];
      await _print(
          t,
          modo,
          'investimentos',
          _app(
            modo,
            'Investimentos',
            InvestimentosConteudo(
              aplicacoes: const [
                MbAplicacao('a', 'CDB Inter', 'Inter', 8512.4, 'm1'),
                MbAplicacao('b', 'Tesouro Selic', 'Santander', 4180, null),
              ],
              serie: serie,
              nomesDasMetas: const {'m1': 'Viagem'},
              hoje: DateTime(2026, 11, 16),
            ),
          ),
          altura: 1100);
    });

    testWidgets('print investimentos vazio $modo', skip: _pular, (t) async {
      await _print(
          t,
          modo,
          'investimentos_vazio',
          _app(
            modo,
            'Investimentos',
            InvestimentosConteudo(
              aplicacoes: const [],
              serie: const [],
              nomesDasMetas: const {},
              hoje: DateTime(2026, 11, 16),
              onAbrirMeuBanco: () {},
            ),
          ),
          altura: 420);
    });
  }
}
