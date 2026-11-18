// Prints da Início, da aba Pendências, do painel e da Aparência para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_visual_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/ (fora do git; a renderização muda por máquina).
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/ajustesInicioPage.dart';
import 'package:budget/pages/settingsPage.dart';
import 'package:budget/widgets/dateDivider.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/transactionEntry/transactionEntry.dart';
import 'package:provider/provider.dart';
import 'package:budget/pages/aparenciaPage.dart';
import 'package:budget/struct/mbSync/avisos.dart' show meuBancoAvisos;
import 'package:budget/pages/homePage/inicioEditorial.dart';
import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/struct/mbSync/revisao.dart' show MbItemRevisao, meuBancoRevisar;
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/classificarDados.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show CatLocal;
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/widgets/editorial/reembolsoConta.dart' show mbEscolherGastoRachado;
import 'package:budget/pages/homePage/painelDesktop.dart';
import 'package:budget/pages/meuBancoConexoes.dart';
import 'package:budget/struct/mbSync/conexoes.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/struct/meuBancoSync.dart' show meuBancoPareadoConferido;
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

final _agora = DateTime(2026, 11, 12, 15, 0);

ModeloInicio _modelo() => montarModeloInicio(
      ciclo: {
        'inicio': '2026-11-05',
        'fim': '2026-12-04',
        'consumido': 2871.15,
        'limite': 4630.0,
        'percentual': 62.0,
        'diasRestantes': 22,
        'por_dia': [
          for (var i = 0; i < 30; i++)
            {
              'data': DateTime(2026, 11, 5 + i).toIso8601String().substring(0, 10),
              'valor': i < 8 ? (i * 37 % 140 + 40).toDouble() : 0.0
            }
        ],
      },
      contas: [
        {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Nubank', 'bank': 'Nubank', 'balance': 3102.90},
        {'id': 'b', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Itaú', 'bank': 'Itaú', 'balance': 1115.50},
        {
          'id': 'd', 'type': 'CREDIT', 'name': 'Ultravioleta ·4412', 'bank': 'Nubank', 'balance': 1240.0,
          'credit_limit': 3000.0, 'closing_date': '2026-10-15', 'due_date': '2026-11-22',
        },
      ],
      faturas: {},
      sincronizadoEm: _agora.subtract(const Duration(minutes: 4)).toUtc().toIso8601String(),
      ultimas: [
        (nome: 'Pão de Açúcar', categoria: 'Mercado', data: DateTime(2026, 11, 12), valor: -182.30, receita: false),
        (nome: 'Uber', categoria: 'Transporte', data: DateTime(2026, 11, 11), valor: -27.90, receita: false),
        (nome: 'Salário', categoria: 'Renda', data: DateTime(2026, 11, 5), valor: 6500.0, receita: true),
      ],
      nome: 'Renan',
      agora: _agora,
    );

final _pular = Platform.environment['PRINTS'] != '1';

// Telas herdadas do Cashew: sem EasyLocalization os textos .tr() saem como
// chaves; o que importa nestes prints é o componente compartilhado.
Map<String, dynamic> _padroes = {};
Map<String, dynamic> _ajustesHerdados(String modo) => {
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
        {bool receita = false, String cat = 'c1'}) =>
    Transaction(
      transactionPk: pk,
      name: nome,
      amount: valor,
      note: '',
      categoryFk: cat,
      walletFk: '0',
      dateCreated: dia,
      income: receita,
      paid: true,
      skipPaid: true,
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

Widget _herdado(String modo, Widget home) {
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

Widget _botao(String rotulo, void Function(BuildContext) abrir) => Scaffold(
      body: Builder(
        builder: (c) => Center(
          child: TextButton(onPressed: () => abrir(c), child: Text(rotulo)),
        ),
      ),
    );

void main() {
  setUpAll(() async {
    _padroes = await getDefaultPreferences();
    const f = 'assets/fonts/';
    await _fonte('Geist', [
      '${f}Geist-Regular.ttf',
      '${f}Geist-Medium.ttf',
      '${f}Geist-SemiBold.ttf',
    ]);
    await _fonte('GeistMono', ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ??
        'C:/Users/mendo/development/flutter-3.24.5';
    await _fonte('MaterialIcons',
        ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  for (final modo in ['claro', 'escuro']) {
    for (final acento in ['verde', 'terracota']) {
      testWidgets('print início $modo $acento', skip: _pular, (t) async {
        appStateSettings = {
          'materialYou': false,
          'accentSystemColor': false,
          'batterySaver': false,
          'increaseTextContrast': false,
          'forceFullDarkBackground': false,
          'acento': acento,
          'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
        };
        t.view.physicalSize = const Size(390 * 2, 844 * 2);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        final b = modo == 'claro' ? Brightness.light : Brightness.dark;
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: temaFlutter(temaAtivo(b)),
          home: Scaffold(body: InicioEditorial.comModelo(_modelo())),
        ));
        await t.pump(const Duration(seconds: 3));
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('../../.verificacao/prints/inicio_${modo}_$acento.png'));
      });
    }
    testWidgets('print atalhos sem banco $modo', skip: _pular, (t) async {
      appStateSettings = {
        'materialYou': false, 'accentSystemColor': false, 'batterySaver': false,
        'increaseTextContrast': false, 'forceFullDarkBackground': false, 'font': 'Geist',
        'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
      };
      meuBancoPareadoConferido.value = true;
      addTearDown(() => meuBancoPareadoConferido.value = false);
      t.view.physicalSize = const Size(390 * 2, 400 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final b = modo == 'claro' ? Brightness.light : Brightness.dark;
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Scaffold(
            body: Builder(
                builder: (c) => ColoredBox(
                    color: cores(c).bg,
                    child: const Padding(
                        padding: EdgeInsets.all(20),
                        child: Column(children: [
                          SemDadosInicio(dica: ''),
                          AtalhosInicio(),
                        ]))))),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/atalhos_sem_banco_$modo.png'));
    });
    for (final vazio in [false, true]) {
      testWidgets('print pendências $modo${vazio ? ' vazio' : ''}', skip: _pular, (t) async {
        appStateSettings = {
          'materialYou': false,
          'accentSystemColor': false,
          'batterySaver': false,
          'increaseTextContrast': false,
          'forceFullDarkBackground': false,
          'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
        };
        meuBancoRevisar.value = vazio
            ? const []
            : const [
                MbItemRevisao('a', 'envio_santander',
                    txId: 'ta', data: '2026-11-03', descricao: 'ENVIO SANTANDER', valor: 500),
                MbItemRevisao('b', 'pix_recebido',
                    txId: 'tb', data: '2026-11-05', descricao: 'PIX RECEBIDO', valor: 120),
              ];
        meuBancoAvisos.value = vazio ? const [] : const [{'banco': 'Inter'}];
        addTearDown(() {
          meuBancoRevisar.value = const [];
          meuBancoAvisos.value = const [];
        });
        t.view.physicalSize = const Size(390 * 2, 844 * 2);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        final b = modo == 'claro' ? Brightness.light : Brightness.dark;
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: temaFlutter(temaAtivo(b)),
          home: const Scaffold(body: PendenciasPage(atualizar: false)),
        ));
        await t.pump(const Duration(seconds: 1));
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('../../.verificacao/prints/pendencias_$modo${vazio ? '_vazio' : ''}.png'));
      });
    }
    testWidgets('print pendências IA $modo', skip: _pular, (t) async {
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'forceFullDarkBackground': false,
        'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
      };
      mbOpcoesClassificar = MbOpcoes.montar(const [
        CatLocal(pk: 'alim', nome: 'Alimentação', receita: false),
        CatLocal(pk: 'deliv', nome: 'Delivery', receita: false, paiPk: 'alim'),
        CatLocal(pk: 'rest', nome: 'Restaurante', receita: false, paiPk: 'alim'),
        CatLocal(pk: 'fam', nome: 'Família', receita: false),
        CatLocal(pk: 'transp', nome: 'Transporte', receita: false),
        CatLocal(pk: 'mor', nome: 'Moradia', receita: false),
      ], const [
        MbVinculoOpcao('mae', 'Mãe', 'emprestimo')
      ]);
      meuBancoClassificar.value = [
        MbLancamentoIa(
            pk: 'mb:1',
            descricao: 'PIX ENVIADO FABIANA SILVA',
            valor: -500,
            data: DateTime(2026, 11, 10, 12),
            conta: 'Inter',
            categoriaNome: 'A classificar'),
        MbLancamentoIa(pk: 'mb:2', descricao: 'IFOOD', valor: -42.9, data: DateTime(2026, 11, 9, 12)),
      ];
      meuBancoSugestoes.value = const {
        'mb:1': MbSugestao('mb:1', 'fam',
            titulo: 'Empréstimo Mãe',
            vinculoPk: 'mae',
            confianca: .45,
            pergunta: 'Esse Pix de R\$ 500 para Fabiana foi empréstimo para a Mãe?',
            fonte: MbFonteSugestao.ia),
      };
      addTearDown(() {
        meuBancoClassificar.value = const [];
        meuBancoSugestoes.value = const {};
      });
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final b = modo == 'claro' ? Brightness.light : Brightness.dark;
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: const Scaffold(body: PendenciasPage(atualizar: false)),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/pendencias_ia_$modo.png'));
    });
    // Rachar conta: Pix recebido com o gasto em destaque (casamento forte) ou só a ação, e a lista de candidatos.
    final rachados = mbSugerirReembolso([
      MbGastoCandidato('mb:g1', 'RESTAURANTE DO ZE', 'Restaurante', DateTime(2026, 11, 8, 12), 12000),
      MbGastoCandidato('mb:g2', 'MERCADO BOM PRECO', 'Mercado', DateTime(2026, 11, 9, 12), 18000, reembolsado: 6000),
      MbGastoCandidato('mb:g3', 'UBER TRIP', 'Transporte', DateTime(2026, 11, 7, 12), 6500),
      MbGastoCandidato('mb:g4', 'POSTO SHELL', 'Transporte', DateTime(2026, 11, 10, 12), 20000),
      MbGastoCandidato('mb:g5', 'PADARIA', 'Alimentação', DateTime(2026, 11, 10, 12), 4000),
    ], valor: 60, data: DateTime(2026, 11, 10), categoriasDoPagador: {'Restaurante'});
    for (final forte in [true, false]) {
      testWidgets('print pendências rachar ${forte ? 'forte' : 'acao'} $modo', skip: _pular, (t) async {
        appStateSettings = _ajustesHerdados(modo);
        mbOpcoesClassificar = MbOpcoes.montar(const [
          CatLocal(pk: 'renda', nome: 'Renda', receita: true),
          CatLocal(pk: 'outros', nome: 'Outras entradas', receita: true),
        ]);
        meuBancoClassificar.value = [
          MbLancamentoIa(
              pk: 'mb:r1',
              descricao: 'PIX RECEBIDO JUNIOR SILVA',
              valor: 60,
              data: DateTime(2026, 11, 10, 12),
              conta: 'Inter',
              categoriaNome: 'Transferências'),
        ];
        meuBancoReembolsos.value = const [MbVinculoReembolso('mb:r0', 'mb:g0', 'JUNIOR SILVA', 5000)];
        final original = mbBuscarCandidatosReembolso;
        mbBuscarCandidatosReembolso = (_, __, ___, ____) async => forte
            ? rachados
            : [for (final s in rachados) if (s.pontos < 40) s]; // sem parte exata: só a ação
        addTearDown(() {
          meuBancoClassificar.value = const [];
          meuBancoReembolsos.value = const [];
          mbBuscarCandidatosReembolso = original;
        });
        t.view.physicalSize = const Size(390 * 2, 844 * 2);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        await t.pumpWidget(_herdado(modo, const Scaffold(body: PendenciasPage(atualizar: false))));
        await t.pump(const Duration(seconds: 1));
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('../../.verificacao/prints/pendencias_rachar_${forte ? 'forte' : 'acao'}_$modo.png'));
      });
    }
    testWidgets('print lista de gastos rachados $modo', skip: _pular, (t) async {
      appStateSettings = _ajustesHerdados(modo);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_herdado(
          modo,
          _botao('abrir',
              (c) => mbEscolherGastoRachado(c, sugestoes: rachados, valor: 60, data: DateTime(2026, 11, 10)))));
      await t.tap(find.text('abrir'));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/pendencias_rachar_lista_$modo.png'));
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
    });
    for (final pagina in ['inicio', 'pendencias', 'analise']) {
      testWidgets('print ajustes $pagina $modo', skip: _pular, (t) async {
        appStateSettings = {
          ...appStateSettings,
          'materialYou': false,
          'accentSystemColor': false,
          'batterySaver': false,
          'increaseTextContrast': false,
          'forceFullDarkBackground': false,
          'outlinedIcons': true,
          'font': 'Geist',
          'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
        };
        t.view.physicalSize = const Size(390 * 2, 700 * 2);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        final b = modo == 'claro' ? Brightness.light : Brightness.dark;
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: temaFlutter(temaAtivo(b)),
          home: switch (pagina) {
            'inicio' => const AjustesInicioPage(),
            'pendencias' => const AjustesPendenciasPage(),
            _ => const AjustesAnalisePage(),
          },
        ));
        await t.pump(const Duration(seconds: 1));
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('../../.verificacao/prints/ajustes_${pagina}_$modo.png'));
      });
    }
    testWidgets('print aparência $modo', skip: _pular, (t) async {
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'acento': 'verde',
        'temaPronto': 'sistema',
      };
      t.view.physicalSize = const Size(390 * 2, 420 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final b = modo == 'claro' ? Brightness.light : Brightness.dark;
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Builder(
          builder: (context) => Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Modo', style: EdTexto.h2(context)),
                const SizedBox(height: 12),
                GradeTemas(selecionado: 'sistema', aoEscolher: (_) {}),
                const SizedBox(height: 24),
                Text('Cor de destaque', style: EdTexto.h2(context)),
                const SizedBox(height: 12),
                SeletorAcento(selecionado: 'verde', aoEscolher: (_) {}),
              ]),
            ),
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/aparencia_$modo.png'));
    });
  }

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print desktop $modo', skip: _pular, (t) async {
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'forceFullDarkBackground': false,
        'acento': 'verde',
        'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
      };
      t.view.physicalSize = const Size(1100, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final b = modo == 'claro' ? Brightness.light : Brightness.dark;
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Scaffold(body: PainelDesktop.comDados(_modelo())),
      ));
      await t.pump(const Duration(seconds: 3));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/desktop_$modo.png'));
    });
  }

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print contas conectadas $modo', skip: _pular, (t) async {
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'acento': 'verde',
        'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
      };
      t.view.physicalSize = const Size(390 * 2, 760 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final b = modo == 'claro' ? Brightness.light : Brightness.dark;
      MbConexao con(String id, String banco, String? status, List<Map<String, dynamic>> contas) =>
          MbConexao.deJson({'id': id, 'banco': banco, 'status': status, 'precisaReconectar': status == 'LOGIN_ERROR', 'atualizado': DateTime.now().subtract(const Duration(minutes: 7)).toIso8601String(), 'contas': contas});
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaFlutter(temaAtivo(b)),
        home: Builder(
          builder: (context) => Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Contas conectadas', style: EdTexto.h2(context)),
                const SizedBox(height: 10),
                ContasConectadas(
                  carregar: () async => [
                    con('a', 'Nubank', 'UPDATED', [
                      {'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Nubank', 'balance': 3102.9},
                      {'type': 'CREDIT', 'name': 'Ultravioleta', 'balance': 1240},
                    ]),
                    con('b', 'Banco Inter', 'LOGIN_ERROR', [
                      {'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Inter', 'balance': 1115.5},
                    ]),
                    con('c', 'Itaú', null, []),
                  ],
                  remover: (_) async {},
                  conectar: (c, {itemId}) async {},
                  avisar: (_) {},
                ),
              ]),
            ),
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/contas_conectadas_$modo.png'));
    });
  }

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print mais $modo', skip: _pular, (t) async {
      appStateSettings = _ajustesHerdados(modo);
      t.view.physicalSize = const Size(390 * 2, 900 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_herdado(
          modo, const Scaffold(body: SingleChildScrollView(child: MorePages()))));
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/mais_$modo.png'));
    });

    testWidgets('print folha e popup $modo', skip: _pular, (t) async {
      appStateSettings = _ajustesHerdados(modo);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_herdado(
          modo,
          _botao(
              'abrir',
              (c) => openBottomSheet(
                    c,
                    PopupFramework(
                      title: 'Ordenar por',
                      subtitle: 'Escolha como a lista aparece',
                      child: Column(children: [
                        SettingsContainer(
                            title: 'Data', icon: Icons.event_outlined, onTap: () {}),
                        SettingsContainer(
                            title: 'Valor', icon: Icons.payments_outlined, onTap: () {}),
                        SettingsContainerSwitch(
                            title: 'Agrupar por dia',
                            icon: Icons.view_day_outlined,
                            initialValue: true,
                            onSwitched: (_) {}),
                      ]),
                    ),
                  ))));
      await t.tap(find.text('abrir'));
      // A folha (sliding_sheet) anima em vários quadros.
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/folha_$modo.png'));
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('print popup $modo', skip: _pular, (t) async {
      appStateSettings = _ajustesHerdados(modo);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_herdado(
          modo,
          _botao(
              'popup',
              (c) => openPopup(c,
                  icon: Icons.delete_outlined,
                  title: 'Excluir transação?',
                  description: 'Essa ação não pode ser desfeita.',
                  onCancelLabel: 'Cancelar',
                  onCancel: () {},
                  onSubmitLabel: 'Excluir',
                  onSubmit: () {}))));
      await t.tap(find.text('popup'));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/popup_$modo.png'));
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('print lista de transações $modo', skip: _pular, (t) async {
      appStateSettings = _ajustesHerdados(modo);
      t.view.physicalSize = const Size(390 * 2, 520 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final cats = {
        'c1': _cat('c1', 'Mercado', '0xff4caf50', 'groceries.png'),
        'c2': _cat('c2', 'Transporte', '0xff2196f3', 'car.png'),
        'c3': _cat('c3', 'Renda', '0xff9c27b0', 'coin.png'),
      };
      final hoje = DateTime(2026, 11, 12);
      final ontem = DateTime(2026, 11, 11);
      final dias = [
        (hoje, '−R\$ 210,20', [
          _tx('a', 'Pão de Açúcar', -182.3, hoje),
          _tx('b', 'Uber', -27.9, hoje, cat: 'c2'),
        ]),
        (ontem, '', [_tx('c', 'Salário', 6500, ontem, receita: true, cat: 'c3')]),
      ];
      await t.pumpWidget(_herdado(
          modo,
          Scaffold(
            body: ListView(children: [
              for (final (dia, total, txs) in dias) ...[
                DateDivider(date: dia, info: total),
                for (final tx in txs)
                  TransactionEntry(
                    openPage: const SizedBox(),
                    transaction: tx,
                    category: cats[tx.categoryFk],
                    listID: 'print',
                  ),
              ],
            ]),
          )));
      // Ícones das categorias são PNG: decodificar fora do relógio falso.
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
      await t.pump(const Duration(seconds: 2));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/transacoes_$modo.png'));
    });
  }
}
