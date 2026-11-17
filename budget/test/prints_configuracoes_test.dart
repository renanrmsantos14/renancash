// Prints das Configurações (Etapa 5 da revisão de UI) para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_configuracoes_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/config_*.png (fora do git).
// Sem EasyLocalization os textos .tr() saem como chave; os textos novos
// (grupos, descrições) já são pt-BR literais.
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/aboutPage.dart';
import 'package:budget/pages/addAssociatedTitlePage.dart';
import 'package:budget/pages/settingsPage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/openBottomSheet.dart';
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
      'showExtraInfoText': true,
      'customCurrencyAmounts': <String, dynamic>{},
      'locale': 'pt',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

Widget _app(String modo, Widget home) {
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  return Provider<AllWallets>.value(
    value: AllWallets(list: const [], indexedByPk: const {}),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(b)),
      home: home,
    ),
  );
}

Future<void> _print(WidgetTester t, String modo, String nome, Widget tela,
    {double altura = 844}) async {
  appStateSettings = _ajustes(modo);
  t.view.physicalSize = Size(390 * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(modo, tela));
  await t.pump(const Duration(seconds: 1));
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../.verificacao/prints/config_${nome}_$modo.png'));
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

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print configurações $modo', skip: _pular, (t) async {
      await _print(t, modo, 'lista', const SettingsPageFramework(),
          altura: 1900);
    });

    testWidgets('print mais ajustes $modo', skip: _pular, (t) async {
      await _print(t, modo, 'avancado', const MoreOptionsPagePreferences(),
          altura: 1500);
    });

    testWidgets('print sobre $modo', skip: _pular, (t) async {
      await _print(t, modo, 'sobre', const AboutPage());
    });

    testWidgets('print créditos $modo', skip: _pular, (t) async {
      await _print(t, modo, 'creditos', const CreditosPage(), altura: 1200);
    });

    testWidgets('print novo título $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(
          modo,
          Scaffold(
            body: Builder(
              builder: (c) => Center(
                child: TextButton(
                  onPressed: () => openBottomSheet(
                      c, AddAssociatedTitlePage(),
                      popupWithKeyboard: true),
                  child: const Text('abrir'),
                ),
              ),
            ),
          )));
      await t.tap(find.text('abrir'));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/config_titulo_$modo.png'));
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
    });
  }
}
