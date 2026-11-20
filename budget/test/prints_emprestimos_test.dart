// Prints do PR de empréstimos: barra nova, aba Empréstimos e a fila com "Me pagou um empréstimo" (nomes e valores sintéticos).
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_emprestimos_test.dart --update-goldens
// O fim da Início com o botão Configurações é gerado por test/prints_inicio_test.dart.
// Os PNGs vão para .verificacao/2026-11-20-t3-emprestimos-vinculo/ (fora do git).
import 'dart:io';

import 'package:budget/pages/emprestimosPage.dart';
import 'package:budget/pages/homePage/homePageParaRevisar.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/meuBancoSync.dart' show meuBancoPareado;
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/bottomNavBar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
      'acento': 'verde',
      'locale': 'pt',
      'appAnimations': AppAnimations.minimal.index,
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

final _exemplo = mbCalcularEmprestimos([
  {'tipo': 'decisao', 'tx_id': 'a1', 'resposta': 'emprestimo', 'valor': 800.0, 'data': '2026-10-18', 'pessoa': 'Ana'},
  {'tipo': 'decisao', 'tx_id': 'a2', 'resposta': 'emprestimo', 'valor': 200.0, 'data': '2026-11-03', 'pessoa': 'ana '},
  {'tipo': 'decisao', 'tx_id': 'b1', 'resposta': 'emprestimo', 'valor': 500.0, 'data': '2026-11-05', 'pessoa': 'Bruno'},
  {'tipo': 'decisao', 'tx_id': 'c1', 'resposta': 'emprestimo', 'valor': 120.0, 'data': '2026-09-02', 'pessoa': 'Carla'},
  {'tipo': 'decisao', 'tx_id': 'p1', 'resposta': 'devolucao', 'valor': 450.0, 'data': '2026-11-01', 'emprestimo_id': 'a1'},
  {'tipo': 'decisao', 'tx_id': 'p2', 'resposta': 'devolucao', 'valor': 120.0, 'data': '2026-09-20', 'emprestimo_id': 'c1'},
], perdoes: const []);

Future<void> _tela(WidgetTester t, String modo, String nome, Widget home, {double altura = 844}) async {
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  appStateSettings = _ajustes(modo);
  t.view.physicalSize = Size(390 * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: temaFlutter(temaAtivo(b)),
    home: home,
  ));
  await t.pump(const Duration(seconds: 3));
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../.verificacao/2026-11-20-t3-emprestimos-vinculo/${nome}_$modo.png'));
}

void main() {
  setUpAll(() async {
    _padroes = await getDefaultPreferences();
    const f = 'assets/fonts/';
    await _fonte('Geist', ['${f}Geist-Regular.ttf', '${f}Geist-Medium.ttf', '${f}Geist-SemiBold.ttf']);
    await _fonte('GeistMono', ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/flutter';
    await _fonte('MaterialIcons', ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  tearDown(() {
    meuBancoEmprestimos.value = const MbEmprestimos();
    meuBancoPareado.value = false;
  });

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print barra nova $modo', skip: _pular, (t) async {
      meuBancoPareado.value = true;
      await _tela(
        t,
        modo,
        'barra',
        Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: BottomNavBar(onChanged: (_) {}, currentNavigationStackedIndex: 0),
        ),
        altura: 300,
      );
    });

    testWidgets('print aba Empréstimos $modo', skip: _pular, (t) async {
      await _tela(t, modo, 'aba_emprestimos', Scaffold(body: EmprestimosPage(emprestimos: _exemplo)), altura: 1000);
    });

    testWidgets('print fila Me pagou um empréstimo $modo', skip: _pular, (t) async {
      meuBancoEmprestimos.value = _exemplo;
      final item = MbItemRevisao('tx:d1', 'pix_recebido',
          txId: 'd1', data: '2026-11-12', valor: 300, descricao: 'Pix recebido: Ana Souza');
      await _tela(
        t,
        modo,
        'fila_me_pagou',
        Scaffold(body: SafeArea(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(18), child: ItemParaRevisar(item: item))))),
        altura: 420,
      );
    });
  }
}
