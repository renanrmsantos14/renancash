// Prints do PR da migração dos empréstimos antigos (nomes e valores sintéticos).
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_migracao_emprestimos_test.dart --update-goldens
// Os PNGs vão para .verificacao/2026-11-27-t3-emprestimos-migracao/ (fora do git).
import 'dart:io';

import 'package:budget/pages/migracaoEmprestimosPage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/migracaoEmprestimos.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
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

MbMigItem _item(String o, String pessoa, String status,
        {int lanc = 4, int original = 0, int pago = 0, int antigo = 0, int novo = 0, List<MbMigDiferenca> dif = const [], List<String> motivos = const [], MbMigAlternativa? alt}) =>
    MbMigItem(
      objetivo: o, nome: pessoa, status: status, pessoa: pessoa, motivos: motivos, avisos: const [], lancamentos: lanc,
      originalCentavos: original, pagoCentavos: pago, saldoAntigoCentavos: antigo, saldoNovoCentavos: novo, diferencas: dif, alternativa: alt,
    );

final _previa = MbMigPrevia(
  assinatura: 'x',
  itens: [
    _item('1', 'Ana', 'pronto', original: 80000, pago: 45000, antigo: 35000, novo: 35000),
    _item('2', 'Bruno', 'pronto', lanc: 5, original: 50000, pago: 30000, antigo: 20000, novo: 20000),
    _item('3', 'Carla', 'pronto', lanc: 3, original: 12000, pago: 14000, antigo: -2000, novo: 0,
        dif: const [MbMigDiferenca('2026-09-20', -2000, 'Pago a mais: acima do saldo no dia')],
        alt: const MbMigAlternativa(true, -2000, 0)),
    _item('4', 'Davi', 'migrado', original: 30000, antigo: 30000, novo: 30000),
    _item('5', 'Sem lançamentos', 'nao_mapeavel', lanc: 0, motivos: const ['Sem lançamentos ligados']),
  ],
  antesCentavos: 45000,
  depoisCentavos: 130000,
  saldoAntigoCentavos: 83000,
  saldoNovoCentavos: 85000,
  diferencaCentavos: -2000,
  efeitosCentavos: 0,
  efeitosQtd: 0,
);

Future<void> _tela(WidgetTester t, String modo, String nome, {Future<void> Function()? depois}) async {
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  appStateSettings = _ajustes(modo);
  t.view.physicalSize = const Size(390 * 2, 1500 * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: temaFlutter(temaAtivo(b)),
    home: MigracaoEmprestimosPage(previaInicial: _previa),
  ));
  await t.pump(const Duration(seconds: 3));
  if (depois != null) await depois();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../../.verificacao/2026-11-27-t3-emprestimos-migracao/${nome}_$modo.png'));
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

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print prévia $modo', skip: _pular, (t) => _tela(t, modo, 'previa'));
    testWidgets('print confirmação $modo', skip: _pular, (t) async {
      await _tela(t, modo, 'confirmacao', depois: () async {
        await t.tap(find.byKey(const Key('migrar_3')));
        await t.pump(const Duration(seconds: 1));
      });
    });
  }
}
