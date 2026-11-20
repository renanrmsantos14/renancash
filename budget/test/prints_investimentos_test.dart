// Prints da tela de Investimentos: celular 390 (página inteira), folha de detalhe e desktop 1440.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_investimentos_test.dart --update-goldens
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/investimentosEvolucaoPage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

final _pular = Platform.environment['PRINTS'] != '1';
final _hoje = DateTime(2026, 11, 20);

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
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'numberFormatCurrencyFirst': true,
      'locale': 'pt',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

// 3 bancos, 7 aplicações; o Fundo Multimercado do Santander rende negativo.
const _aplicacoes = [
  MbAplicacao('cdb', 'CDB Banco Inter 2028', 'BANCO INTER', 18400, 'm1'),
  MbAplicacao('lci', 'LCI Inter Pós', 'BANCO INTER', 9200, null),
  MbAplicacao('pp', 'Poupança Inter', 'BANCO INTER ·69-6', 1200, null),
  MbAplicacao('san', 'CDB Santander Liquidez Diária', 'Banco Santander Pessoa Física ·24-1', 7800, null),
  MbAplicacao('mm', 'Fundo Multimercado Santander', 'Banco Santander Pessoa Física ·24-1', 3600, null),
  MbAplicacao('tes', 'Tesouro Selic 2029', 'XP Investimentos', 6300, null),
  MbAplicacao('deb', 'Debênture Incentivada Rumo', 'XP Investimentos', 2100, null),
];

final _detalhes = {
  'cdb': MbDetalheInvestimento(
      aplicado: 16000,
      rendimento: 2400,
      impostos: 310.5,
      liquido: 18089.5,
      taxa: (valor: 110, indexador: 'CDI'),
      rentabilidadeMes: 0.92,
      rentabilidade12m: 11.4,
      subtipo: 'CDB',
      emissor: 'Banco Inter S.A.',
      aplicadoEm: DateTime(2025, 3, 10),
      vencimento: DateTime(2028, 3, 10)),
  'lci': MbDetalheInvestimento(
      aplicado: 9000,
      taxa: (valor: 95, indexador: 'CDI'),
      subtipo: 'LCI',
      vencimento: DateTime(2027, 8, 15)),
  'san': MbDetalheInvestimento(
      aplicado: 7500,
      taxa: (valor: 100, indexador: 'CDI'),
      subtipo: 'CDB',
      vencimento: DateTime(2026, 12, 1)),
  'mm': const MbDetalheInvestimento(aplicado: 3900, subtipo: 'Fundo'),
  'tes': MbDetalheInvestimento(
      aplicado: 6000,
      taxa: (valor: 0.1, indexador: 'SELIC'),
      subtipo: 'Tesouro',
      vencimento: DateTime(2029, 3, 1)),
  'deb': MbDetalheInvestimento(
      aplicado: 2000,
      taxa: (valor: 6.8, indexador: 'IPCA'),
      subtipo: 'Debênture',
      vencimento: DateTime(2031, 6, 15)),
};

// Oito meses (abr a nov/26); novembro é parcial.
List<MbRetratoMes> _serie() {
  const base = {'cdb': 16900.0, 'lci': 8700.0, 'pp': 1100.0, 'san': 7300.0, 'mm': 3900.0, 'tes': 5200.0, 'deb': 1900.0};
  const fim = {'cdb': 18400.0, 'lci': 9200.0, 'pp': 1200.0, 'san': 7800.0, 'mm': 3600.0, 'tes': 6300.0, 'deb': 2100.0};
  final nomes = {for (final a in _aplicacoes) a.id: a};
  return [
    for (var m = 0; m < 8; m++)
      MbRetratoMes('2026-${(4 + m).toString().padLeft(2, '0')}', [
        for (final k in base.keys)
          MbAplicacaoMes(
              nomes[k]!.id.toString(),
              nomes[k]!.nome,
              nomes[k]!.banco,
              base[k]! + (fim[k]! - base[k]!) * (m / 7 + (m.isOdd ? -.06 : .05) * (m == 7 ? 0 : 1)),
              aplicado: _detalhes[k]?.aplicado)
      ]),
  ];
}

Widget _app(String modo, {double largura = 390}) {
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
              SizedBox(
                height: 56,
                child: Row(children: [
                  const SizedBox(width: 8),
                  Icon(Icons.arrow_back_rounded, color: cores(context).tx),
                  const SizedBox(width: 16),
                  Text('Investimentos',
                      style: TextStyle(
                          fontFamily: 'Geist',
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: cores(context).tx)),
                ]),
              ),
              InvestimentosConteudo(
                aplicacoes: _aplicacoes,
                serie: _serie(),
                detalhes: _detalhes,
                nomesDasMetas: const {'m1': 'Reserva de emergência'},
                hoje: _hoje,
                onAbrirMeuBanco: () {},
              ),
              const SizedBox(height: 40),
            ]),
          ),
        ),
      ),
    ),
  );
}

/// Imagens de `assets/` só carregam fora do relógio falso do teste: decodifica antes do print.
Future<void> _logos(WidgetTester t) async {
  await t.runAsync(() async {
    final contexto = t.element(find.byType(MaterialApp));
    for (final img in t.widgetList<Image>(find.byType(Image))) {
      await precacheImage(img.image, contexto);
    }
  });
  await t.pump(const Duration(milliseconds: 100));
}

Future<void> _montar(WidgetTester t, String modo, double largura, double altura) async {
  t.view.physicalSize = Size(largura * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(modo, largura: largura));
  for (var i = 0; i < 25; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  await _logos(t);
}

void main() {
  setUpAll(() async {
    _padroes = await getDefaultPreferences();
    const f = 'assets/fonts/';
    await _fonte('Geist', ['${f}Geist-Regular.ttf', '${f}Geist-Medium.ttf', '${f}Geist-SemiBold.ttf']);
    await _fonte('GeistMono', ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/dev/flutter';
    await _fonte('MaterialIcons', ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print investimentos celular $modo', skip: _pular, (t) async {
      await _montar(t, modo, 390, 1500);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/investimentos_celular_$modo.png'));
    });

    testWidgets('print investimentos folha $modo', skip: _pular, (t) async {
      await _montar(t, modo, 390, 1450);
      await t.tap(find.text('CDB Banco Inter 2028'));
      for (var i = 0; i < 25; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/investimentos_folha_$modo.png'));
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('print investimentos desktop 1440 $modo', skip: _pular, (t) async {
      await _montar(t, modo, 1440, 1250);
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/investimentos_desktop_1440_$modo.png'));
    });
  }
}
