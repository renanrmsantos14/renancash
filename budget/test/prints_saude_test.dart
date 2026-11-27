// Prints da tela Saúde e do aviso da Início para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_saude_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/ (fora do git). Dados de exemplo, nunca reais.
import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/homePage/inicioEditorial.dart' show AlertasBento;
import 'package:budget/pages/saudePage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/saude.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'locale': 'pt',
      'acento': 'verde',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

Widget _app(String modo, Widget tela) {
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  return Provider<AllWallets>.value(
    value: AllWallets(list: const [], indexedByPk: const {}),
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: temaFlutter(temaAtivo(b)), home: tela),
  );
}

Future<void> _print(WidgetTester t, String modo, String nome, Widget tela,
    {double largura = 390, double altura = 844, double dpr = 2}) async {
  appStateSettings = _ajustes(modo);
  t.view.physicalSize = Size(largura * dpr, altura * dpr);
  t.view.devicePixelRatio = dpr;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(modo, tela));
  await t.pump(const Duration(seconds: 1));
  await t.pump(const Duration(seconds: 1));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('../../.verificacao/prints/${nome}_$modo.png'));
}

Map<String, dynamic> _item(String id, String nome, String status, String resumo,
        {String? acao, List<Map<String, dynamic>> det = const []}) =>
    {'id': id, 'nome': nome, 'status': status, 'resumo': resumo, 'acao': acao, 'detalhes': det};

final _agora = DateTime(2026, 11, 27, 8, 20);
String _iso(Duration atras) => _agora.subtract(atras).toUtc().toIso8601String();

Map<String, dynamic> get _tudoCerto => {
      'verificado_em': _iso(const Duration(minutes: 20)),
      'status': 'ok',
      'atrasado': false,
      'itens': [
        _item('pluggy', 'Bancos (Pluggy)', 'ok', 'Inter em dia'),
        _item('ia', 'Inteligência artificial', 'ok', 'O modelo existe e responde'),
        _item('espelho', 'Espelho', 'ok', 'Durable Object e tabelas em dia'),
        _item('cron', 'Cron e check diário', 'ok', 'Rodou há 3 h; check diário em dia'),
      ],
    };

Map<String, dynamic> get _comProblema => {
      'verificado_em': _iso(const Duration(minutes: 20)),
      'status': 'erro',
      'atrasado': false,
      'itens': [
        _item('pluggy', 'Bancos (Pluggy)', 'atencao', '1 conexão precisa de atenção',
            acao: 'Reconecte o banco em Meu Banco > Conexões; se estiver tudo certo, toque em Atualizar agora.',
            det: [
              {'nome': 'Inter', 'status': 'atencao', 'texto': 'Inter sem atualizar há 3 dias'}
            ]),
        _item('ia', 'Inteligência artificial', 'erro', 'O modelo da IA não responde',
            acao: 'Confira a constante MODELO em ia.js contra o catálogo do Workers AI e publique de novo.',
            det: [
              {'nome': 'Modelo', 'status': 'erro', 'texto': 'O modelo da IA não responde (model not found)'}
            ]),
        _item('espelho', 'Espelho', 'ok', 'Durable Object e tabelas em dia'),
        _item('cron', 'Cron e check diário', 'ok', 'Rodou há 3 h; check diário em dia'),
      ],
    };

MbCliente _cliente(Map<String, dynamic> corpo) => MbCliente(
    base: 'https://x.test',
    token: 't',
    cliente: MockClient((r) async =>
        http.Response(jsonEncode(corpo), 200, headers: {'content-type': 'application/json; charset=utf-8'})));

void main() {
  setUpAll(() async {
    _padroes = await getDefaultPreferences();
    const f = 'assets/fonts/';
    await _fonte('Geist', ['${f}Geist-Regular.ttf', '${f}Geist-Medium.ttf', '${f}Geist-SemiBold.ttf']);
    await _fonte('GeistMono', ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? 'C:/Users/mendo/development/flutter-3.24.5';
    await _fonte('MaterialIcons', ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  tearDown(() => meuBancoSaudeAviso.value = null);

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print saúde tudo certo $modo', skip: _pular, (t) async {
      await _print(t, modo, 'saude_ok', SaudePage(clienteParaTeste: _cliente(_tudoCerto), agoraParaTeste: _agora));
    });

    testWidgets('print saúde com problema $modo', skip: _pular, (t) async {
      await _print(
          t, modo, 'saude_problema', SaudePage(clienteParaTeste: _cliente(_comProblema), agoraParaTeste: _agora));
    });

    testWidgets('print aviso da Início $modo', skip: _pular, (t) async {
      meuBancoSaudeAviso.value = MbSaude.deJson(_comProblema);
      await _print(
          t,
          modo,
          'saude_aviso_inicio',
          Scaffold(
              body: SafeArea(
                  child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const SizedBox(height: 24), const AlertasBento()])))),
          altura: 360);
    });
  }
}
