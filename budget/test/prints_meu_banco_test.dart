// Prints das telas da área Meu Banco (MeuBancoPage, MeuBancoParearPage,
// MeuBancoConectarPage e ArrumarDadosPage) para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_meu_banco_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/ (fora do git).
// Nunca usa tokens nem URLs reais.
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/arrumarDadosPage.dart';
import 'package:budget/pages/meuBancoConectar.dart';
import 'package:budget/pages/meuBancoConexoes.dart';
import 'package:budget/pages/meuBancoPage.dart';
import 'package:budget/pages/meuBancoParear.dart';
import 'package:budget/struct/arrumarDados.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/armazem.dart' show MbFila;
import 'package:budget/struct/mbSync/conexoes.dart';
import 'package:budget/struct/meuBancoMapping.dart' show MbDestino;
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

final _pular = Platform.environment['PRINTS'] != '1';
const _urlFalsa = 'https://meu-banco.exemplo.test';
final _linkFalso =
    'meubanco://parear?u=https://meu-banco.exemplo.test&t=mb_${'X' * 43}';

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
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(b)),
      home: tela,
    ),
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
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../.verificacao/prints/${nome}_$modo.png'));
}

void _limparEstadoSync() {
  meuBancoUltimoErro.value = null;
  meuBancoUltimaSync.value = null;
  meuBancoSincronizando.value = false;
  meuBancoFila.value = const MbFila(0, []);
}

MbConexao _con(String id, String banco, String? status,
        List<Map<String, dynamic>> contas) =>
    MbConexao.deJson({
      'id': id,
      'banco': banco,
      'status': status,
      'precisaReconectar': status == 'LOGIN_ERROR',
      'atualizado':
          DateTime.now().subtract(const Duration(minutes: 7)).toIso8601String(),
      'contas': contas,
    });

Transaction _tx(String pk, String nome, double valor, DateTime dia,
        {String carteira = '0', String cat = 'c1'}) =>
    Transaction(
      transactionPk: pk,
      name: nome,
      amount: valor,
      note: '',
      categoryFk: cat,
      walletFk: carteira,
      dateCreated: dia,
      income: valor > 0,
      paid: true,
      skipPaid: false,
    );

TransactionWallet _carteira(String pk, String nome) => TransactionWallet(
    walletPk: pk,
    name: nome,
    dateCreated: DateTime(2026),
    order: 0,
    decimals: 2);

TransactionCategory _categoria(String pk, String nome) => TransactionCategory(
    categoryPk: pk,
    name: nome,
    dateCreated: DateTime(2026),
    order: 0,
    income: false);

const _planoVazio = ArrumarPlano([], [], [], []);

ArrumarPlano _planoExemplo() {
  final m1 = _tx('m1', 'Uber trabalho', -28.90, DateTime(2026, 11, 10));
  final b1 = _tx(
      'mb:b1', 'UBER *TRIP', -28.90, DateTime(2026, 11, 11),
      carteira: 'mb:inter', cat: 'mb:cat:d:Táxi e aplicativos');
  final m2 = _tx('m2', '', -14.50, DateTime(2026, 11, 12));
  final b2 = _tx(
      'mb:b2', 'PADARIA CENTRAL', -14.50, DateTime(2026, 11, 12),
      carteira: 'mb:inter', cat: 'mb:cat:d:Padaria');
  return ArrumarPlano(
    [
      ArrumarPar(m1, b1, 1),
      ArrumarPar(m2, b2, 0),
    ],
    [
      ArrumarMigracao(
          b1, const MbDestino('transp', 'Transporte', 'uber', 'Uber')),
    ],
    [_carteira('st', 'Santander')],
    [
      _categoria('c_bel', 'Beleza'),
      _categoria('c_via', 'Viagem'),
    ],
  );
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

  tearDown(_limparEstadoSync);

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print meu banco pareado $modo', skip: _pular, (t) async {
      _limparEstadoSync();
      meuBancoUltimaSync.value =
          DateTime.now().subtract(const Duration(minutes: 4));
      await _print(
        t,
        modo,
        'meu_banco_pareado',
        MeuBancoPage(
          urlInicial: _urlFalsa,
          pareadoInicial: true,
          contasConectadas: ContasConectadas(
            carregar: () async => [
              _con('a', 'Nubank', 'UPDATED', [
                {
                  'type': 'BANK',
                  'subtype': 'CHECKING_ACCOUNT',
                  'name': 'Conta Nubank',
                  'balance': 3102.90,
                },
                {
                  'type': 'CREDIT',
                  'name': 'Ultravioleta',
                  'balance': 1240.0,
                },
              ]),
              _con('b', 'Banco Inter', 'LOGIN_ERROR', [
                {
                  'type': 'BANK',
                  'subtype': 'CHECKING_ACCOUNT',
                  'name': 'Conta Inter',
                  'balance': 1115.50,
                },
              ]),
              _con('s', 'Banco Santander', 'UPDATED', [
                {
                  'type': 'BANK',
                  'subtype': 'SAVINGS_ACCOUNT',
                  'name': 'Poupança ·24-1',
                  'balance': 420.0,
                },
                {
                  'type': 'BANK',
                  'subtype': 'CHECKING_ACCOUNT',
                  'name': 'Conta ·57',
                  'balance': 92.49,
                },
              ]),
            ],
            remover: (_) async {},
            conectar: (c, {itemId}) async {},
            avisar: (_) {},
          ),
        ),
        altura: 1220,
      );
    });

    testWidgets('print meu banco pareado vazio $modo', skip: _pular, (t) async {
      _limparEstadoSync();
      await _print(
        t,
        modo,
        'meu_banco_pareado_vazio',
        MeuBancoPage(
          urlInicial: _urlFalsa,
          pareadoInicial: true,
          contasConectadas: ContasConectadas(
            carregar: () async => const [],
            remover: (_) async {},
            conectar: (c, {itemId}) async {},
            avisar: (_) {},
          ),
        ),
      );
    });

    testWidgets('print meu banco sincronizando $modo', skip: _pular,
        (t) async {
      _limparEstadoSync();
      meuBancoSincronizando.value = true;
      meuBancoUltimaSync.value =
          DateTime.now().subtract(const Duration(minutes: 1));
      meuBancoFila.value = const MbFila(2, []);
      await _print(
        t,
        modo,
        'meu_banco_sincronizando',
        MeuBancoPage(
          urlInicial: _urlFalsa,
          pareadoInicial: true,
          contasConectadas: ContasConectadas(
            carregar: () async => [
              _con('a', 'Nubank', 'UPDATING', [
                {
                  'type': 'BANK',
                  'subtype': 'CHECKING_ACCOUNT',
                  'name': 'Conta Nubank',
                  'balance': 3102.90,
                },
              ]),
            ],
            remover: (_) async {},
            conectar: (c, {itemId}) async {},
            avisar: (_) {},
          ),
        ),
      );
    });

    testWidgets('print meu banco erro $modo', skip: _pular, (t) async {
      _limparEstadoSync();
      meuBancoUltimoErro.value =
          'Não foi possível falar com o Meu Banco. Confira a internet.';
      meuBancoFila.value =
          const MbFila(1, ['assinaturas · Sem nome: dados inválidos']);
      await _print(
        t,
        modo,
        'meu_banco_erro',
        MeuBancoPage(
          urlInicial: _urlFalsa,
          pareadoInicial: true,
          contasConectadas: ContasConectadas(
            carregar: () async => throw 'Sem internet',
            remover: (_) async {},
            conectar: (c, {itemId}) async {},
            avisar: (_) {},
          ),
        ),
      );
    });

    testWidgets('print meu banco nao pareado $modo', skip: _pular, (t) async {
      _limparEstadoSync();
      await _print(
        t,
        modo,
        'meu_banco_nao_pareado',
        const MeuBancoPage(
          urlInicial: _urlFalsa,
          pareadoInicial: false,
        ),
      );
    });

    testWidgets('print parear com qr $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'meu_banco_parear',
        MeuBancoParearPage(
          linkInicial: _linkFalso,
          visorParaTeste: Builder(
            builder: (context) => ColoredBox(
              color: cores(context).surf,
              child: Center(
                child: Icon(Icons.qr_code_2_rounded,
                    size: 96, color: cores(context).mu),
              ),
            ),
          ),
        ),
      );
    });

    testWidgets('print parear erro de camera $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'meu_banco_parear_erro',
        const MeuBancoParearPage(erroCameraParaTeste: true),
      );
    });

    testWidgets('print conectar banco $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'meu_banco_conectar',
        MeuBancoConectarPage(
          connectToken: 'token-de-teste',
          onSuccess: (_) {},
          onError: (_) {},
          webViewParaTeste: Builder(
            builder: (context) => Center(
              child: Text('Pluggy Connect (simulado)',
                  style: EdTexto.corpo(context).copyWith(color: cores(context).mu)),
            ),
          ),
        ),
      );
    });

    testWidgets('print arrumar dados previa $modo', skip: _pular, (t) async {
      final plano = _planoExemplo();
      await _print(
        t,
        modo,
        'arrumar_dados_previa',
        ArrumarDadosPage(
          conteudo: ArrumarDados(
            calcular: () async => plano,
            aplicar: () async => plano,
            backup: (_) async => true,
            arquivadas: () async => [_carteira('antiga', 'Itaú antigo')],
            desarquivar: (_) async {},
          ),
        ),
      );
    });

    testWidgets('print arrumar dados vazio $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'arrumar_dados_vazio',
        ArrumarDadosPage(
          conteudo: ArrumarDados(
            calcular: () async => _planoVazio,
            aplicar: () async => _planoVazio,
            backup: (_) async => true,
            arquivadas: () async => const [],
            desarquivar: (_) async {},
          ),
        ),
      );
    });

    testWidgets('print arrumar dados erro $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'arrumar_dados_erro',
        ArrumarDadosPage(
          conteudo: ArrumarDados(
            calcular: () async => throw 'banco ocupado',
            aplicar: () async => _planoVazio,
            backup: (_) async => true,
            arquivadas: () async => const [],
            desarquivar: (_) async {},
          ),
        ),
      );
    });

    testWidgets('print arrumar dados aplicado $modo', skip: _pular, (t) async {
      final plano = _planoExemplo();
      await _print(
        t,
        modo,
        'arrumar_dados_aplicado',
        ArrumarDadosPage(
          conteudo: ArrumarDados(
            calcular: () async => plano,
            aplicar: () async => plano,
            aplicadoInicial: plano,
            backup: (_) async => true,
            arquivadas: () async => [_carteira('st', 'Santander')],
            desarquivar: (_) async {},
          ),
        ),
      );
    });
  }

  testWidgets('print meu banco desktop claro', skip: _pular, (t) async {
    _limparEstadoSync();
    meuBancoUltimaSync.value =
        DateTime.now().subtract(const Duration(minutes: 4));
    await _print(
      t,
      'claro',
      'meu_banco_desktop',
      MeuBancoPage(
        urlInicial: _urlFalsa,
        pareadoInicial: true,
        contasConectadas: ContasConectadas(
          carregar: () async => [
            _con('a', 'Nubank', 'UPDATED', [
              {
                'type': 'BANK',
                'subtype': 'CHECKING_ACCOUNT',
                'name': 'Conta Nubank',
                'balance': 3102.90,
              },
            ]),
            _con('b', 'Banco Inter', 'LOGIN_ERROR', [
              {
                'type': 'BANK',
                'subtype': 'CHECKING_ACCOUNT',
                'name': 'Conta Inter',
                'balance': 1115.50,
              },
            ]),
          ],
          remover: (_) async {},
          conectar: (c, {itemId}) async {},
          avisar: (_) {},
        ),
      ),
      largura: 1440,
      altura: 900,
      dpr: 1,
    );
  });

  testWidgets('print arrumar dados desktop claro', skip: _pular, (t) async {
    final plano = _planoExemplo();
    await _print(
      t,
      'claro',
      'arrumar_dados_desktop',
      ArrumarDadosPage(
        conteudo: ArrumarDados(
          calcular: () async => plano,
          aplicar: () async => plano,
          backup: (_) async => true,
          arquivadas: () async => [_carteira('antiga', 'Itaú antigo')],
          desarquivar: (_) async {},
        ),
      ),
      largura: 1440,
      altura: 900,
      dpr: 1,
    );
  });
}
