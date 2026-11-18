// Prints das telas de Contas (Etapa 3 da revisão de UI) para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_contas_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/contas_*.png (fora do git).
// Sem banco local nos testes: as telas entram pelos widgets puros
// (ResumoConta, TotalContas, LinhaConta, InvestimentosConteudo), pelas
// linhas herdadas alimentadas por Stream.value e pelas páginas que não
// dependem de leitura SQL síncrona (AddWalletPage, AccountsPage).
import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/accountsPage.dart';
import 'package:budget/pages/addTransactionPage.dart' show RoutesToPopAfterDelete;
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/pages/investimentosEvolucaoPage.dart';
import 'package:budget/pages/walletDetailsPage.dart' show AmountSpentEntryRow;
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/conexoes.dart' show mbOrigemCarteira;
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl, mbSigla;
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/accountAndBackup.dart' show googleUser;
import 'package:budget/widgets/editRowEntry.dart';
import 'package:budget/widgets/editorial/contas.dart';
import 'package:budget/widgets/noResults.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart' as sign_in;
import 'package:provider/provider.dart';

final _pular = Platform.environment['PRINTS'] != '1';

class _FakeGoogleUser implements sign_in.GoogleSignInAccount {
  const _FakeGoogleUser();
  @override
  String? get displayName => 'Renan Santos';
  @override
  String get email => 'renan@betinhos.com.br';
  @override
  String get id => '1';
  @override
  String? get photoUrl => null;
  @override
  String? get serverAuthCode => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _carteira0 = TransactionWallet(
  walletPk: '0',
  name: 'Nubank',
  colour: '0xff1f7a4c',
  dateCreated: DateTime(2026, 1, 1),
  order: 0,
  currency: 'brl',
  decimals: 2,
);

final _carteira1 = TransactionWallet(
  walletPk: '1',
  name: 'Banco Inter',
  colour: '0xffff9800',
  dateCreated: DateTime(2026, 1, 1),
  order: 1,
  currency: 'brl',
  decimals: 2,
);

final _carteirasPadrao = AllWallets(
  list: [_carteira0, _carteira1],
  indexedByPk: {'0': _carteira0, '1': _carteira1},
);

Future<void> _fonte(String familia, List<String> arquivos) async {
  final l = FontLoader(familia);
  for (final a in arquivos) {
    final f = File(a);
    if (f.existsSync()) {
      l.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
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
      'customCurrencies': <dynamic>[],
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'numberFormatCurrencyFirst': true,
      'currentUserEmail': 'renan@betinhos.com.br',
      'locale': 'pt',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

Widget _envolverApp(String modo, Widget tela, {AllWallets? carteiras}) {
  appStateSettings = _ajustes(modo);
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  return MultiProvider(
    providers: [
      Provider<AllWallets>.value(value: carteiras ?? _carteirasPadrao),
      Provider<SelectedWalletPk>.value(
          value: SelectedWalletPk(selectedWalletPk: '0')),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(b)),
      onGenerateInitialRoutes: (_) => [
        MaterialPageRoute<void>(builder: (_) => const SizedBox()),
        MaterialPageRoute<void>(builder: (_) => tela),
      ],
    ),
  );
}

Widget _app(String modo, String titulo, Widget corpo, {AllWallets? carteiras}) {
  return _envolverApp(
    modo,
    Builder(
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
    carteiras: carteiras,
  );
}

Future<void> _print(WidgetTester t, String modo, String nome, Widget app,
    {double largura = 390, double altura = 844}) async {
  t.view.physicalSize = Size(largura * 2, altura * 2);
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

Widget _linhaConta({
  required int index,
  required String nome,
  required String detalhe,
  required double saldo,
  bool principal = false,
  String? sigla,
}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: EditRowEntry(
        index: index,
        canReorder: true,
        canDelete: false,
        currentReorder: false,
        extraIcon: principal ? Icons.star_rounded : Icons.star_outline,
        onExtra: () {},
        openPage: const SizedBox(),
        content: LinhaConta(
          sigla: sigla ?? mbSigla(nome),
          nome: nome,
          detalhe: detalhe,
          saldo: comSinal(saldo, brl),
        ),
      ),
    );

void main() {
  setUpAll(() async {
    _padroes = await getDefaultPreferences();
    currenciesJSON = jsonDecode(
            File('assets/static/generated/currencies.json').readAsStringSync())
        as Map<String, dynamic>;
    if (!_pular) {
      final pt = jsonDecode(
              File('assets/translations/generated/pt.json').readAsStringSync())
          as Map<String, dynamic>;
      Localization.load(
        const Locale('pt'),
        translations: Translations(pt),
      );
    }
    const f = 'assets/fonts/';
    await _fonte('Geist', [
      '${f}Geist-Regular.ttf',
      '${f}Geist-Medium.ttf',
      '${f}Geist-SemiBold.ttf',
    ]);
    await _fonte('GeistMono',
        ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    await _fonte('Icons', ['assets/icons/Icons.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ??
        'C:/Users/mendo/development/flutter-3.24.5';
    await _fonte('MaterialIcons',
        ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  tearDown(() {
    googleUser = null;
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
            const ResumoConta(
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
      await _print(
          t,
          modo,
          'lista',
          _app(
            modo,
            'Contas',
            Column(children: [
              const TotalContas(total: 2978.40, formatar: brl, quantidade: 3),
              _linhaConta(
                index: 0,
                nome: 'Nubank',
                detalhe: 'Principal · 128 transações',
                saldo: 3102.90,
                principal: true,
              ),
              _linhaConta(
                index: 1,
                nome: 'Itaú',
                detalhe: '42 transações',
                saldo: 1115.50,
              ),
              _linhaConta(
                index: 2,
                nome: 'Cartão Inter',
                detalhe: '1 transação',
                saldo: -1240.0,
              ),
            ]),
          ));
    });

    testWidgets('print lista de contas com nomes longos $modo', skip: _pular,
        (t) async {
      final tiposMb = {
        'mb:inter-cc': 'Conta corrente',
        'mb:inter-poup': 'Poupança',
      };
      await _print(
          t,
          modo,
          'lista_longos',
          _app(
            modo,
            'Contas',
            Column(children: [
              const TotalContas(total: 15842.35, formatar: brl, quantidade: 4),
              _linhaConta(
                index: 0,
                nome: 'BANCO INTER ·69-6',
                detalhe: [
                  'Principal',
                  mbOrigemCarteira('mb:inter-cc', tiposMb),
                  '128 transações',
                ].join(' · '),
                saldo: 3102.90,
                principal: true,
              ),
              _linhaConta(
                index: 1,
                nome: 'BANCO INTER ·69-6',
                detalhe: [
                  mbOrigemCarteira('mb:inter-poup', tiposMb),
                  '14 transações',
                ].join(' · '),
                saldo: 500.00,
              ),
              _linhaConta(
                index: 2,
                nome: 'BANCO SANTANDER (BRASIL) S.A. · Conta Executiva',
                detalhe: [
                  mbOrigemCarteira('manual-1', tiposMb),
                  '342 transações',
                ].join(' · '),
                saldo: 13479.45,
              ),
              _linhaConta(
                index: 3,
                nome: 'Cartão Mastercard Black Internacional',
                detalhe: [
                  mbOrigemCarteira('manual-2', tiposMb),
                  '1 transação',
                ].join(' · '),
                saldo: -1240.00,
              ),
            ]),
          ));
    });

    testWidgets('print lista de contas vazia $modo', skip: _pular, (t) async {
      await _print(
          t,
          modo,
          'lista_vazio',
          _app(
            modo,
            'Contas',
            NoResults(message: 'Nenhuma conta encontrada'),
          ),
          altura: 420);
    });

    testWidgets('print nova conta validação (sem nome) $modo', skip: _pular,
        (t) async {
      await _print(
        t,
        modo,
        'nova_validacao',
        _envolverApp(
          modo,
          AddWalletPage(routesToPopAfterDelete: RoutesToPopAfterDelete.None),
        ),
        altura: 960,
      );
    });

    testWidgets('print nova conta preenchida $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'nova',
        _envolverApp(
          modo,
          AddWalletPage(routesToPopAfterDelete: RoutesToPopAfterDelete.None),
        ),
        altura: 960,
      );
      await t.enterText(find.byType(TextFormField).first, 'Reserva Itaú');
      await t.pump(const Duration(milliseconds: 300));
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/contas_nova_$modo.png'));
    });

    testWidgets('print editar conta $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'editar',
        _envolverApp(
          modo,
          AddWalletPage(
            wallet: _carteira0,
            routesToPopAfterDelete: RoutesToPopAfterDelete.One,
          ),
        ),
        altura: 1050,
      );
    });

    testWidgets('print backup google desconectado $modo', skip: _pular,
        (t) async {
      googleUser = null;
      await _print(
        t,
        modo,
        'backup',
        _envolverApp(modo, const AccountsPage()),
      );
    });

    testWidgets('print backup google conectado $modo', skip: _pular,
        (t) async {
      googleUser = const _FakeGoogleUser();
      await _print(
        t,
        modo,
        'backup_conectado',
        _envolverApp(modo, const AccountsPage()),
      );
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

    testWidgets('print investimentos com 1 mês $modo', skip: _pular,
        (t) async {
      await _print(
          t,
          modo,
          'investimentos_um_mes',
          _app(
            modo,
            'Investimentos',
            InvestimentosConteudo(
              aplicacoes: const [
                MbAplicacao('a', 'CDB Inter', 'Inter', 8512.4, 'm1'),
              ],
              serie: const [
                MbRetratoMes('2026-11', [
                  MbAplicacaoMes('a', 'CDB Inter', 'Inter', 8512.4),
                ]),
              ],
              nomesDasMetas: const {'m1': 'Viagem'},
              hoje: DateTime(2026, 11, 16),
            ),
          ),
          altura: 640);
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

  testWidgets('print lista de contas desktop 1440x900 claro',
      skip: _pular, (t) async {
    await _print(
      t,
      'claro',
      'lista_desktop',
      _app(
        'claro',
        'Contas',
        Column(children: [
          const TotalContas(total: 15842.35, formatar: brl, quantidade: 3),
          _linhaConta(
            index: 0,
            nome: 'BANCO INTER ·69-6',
            detalhe: 'Principal · Conta corrente · Meu Banco · 128 transações',
            saldo: 3102.90,
            principal: true,
          ),
          _linhaConta(
            index: 1,
            nome: 'BANCO SANTANDER (BRASIL) S.A.',
            detalhe: 'Manual · 342 transações',
            saldo: 13979.45,
          ),
          _linhaConta(
            index: 2,
            nome: 'Cartão Inter',
            detalhe: 'Meu Banco · 1 transação',
            saldo: -1240.00,
          ),
        ]),
      ),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print editar conta desktop 1440x900 claro',
      skip: _pular, (t) async {
    await _print(
      t,
      'claro',
      'editar_desktop',
      _envolverApp(
        'claro',
        AddWalletPage(
          wallet: _carteira0,
          routesToPopAfterDelete: RoutesToPopAfterDelete.One,
        ),
      ),
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print investimentos desktop 1440x900 claro',
      skip: _pular, (t) async {
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
      'claro',
      'investimentos_desktop',
      _app(
        'claro',
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
      largura: 1440,
      altura: 900,
    );
  });

  testWidgets('print backup desktop 1440x900 claro', skip: _pular, (t) async {
    googleUser = const _FakeGoogleUser();
    await _print(
      t,
      'claro',
      'backup_desktop',
      _envolverApp('claro', const AccountsPage()),
      largura: 1440,
      altura: 900,
    );
  });
}
