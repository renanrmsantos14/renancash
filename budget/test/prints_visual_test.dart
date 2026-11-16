// Prints da Início, da aba Pendências, do painel e da Aparência para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_visual_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/ (fora do git; a renderização muda por máquina).
import 'dart:io';

import 'package:budget/pages/ajustesInicioPage.dart';
import 'package:budget/pages/aparenciaPage.dart';
import 'package:budget/struct/mbSync/avisos.dart' show meuBancoAvisos;
import 'package:budget/pages/homePage/inicioEditorial.dart';
import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/struct/mbSync/revisao.dart' show MbItemRevisao, meuBancoRevisar;
import 'package:budget/pages/homePage/painelDesktop.dart';
import 'package:budget/pages/meuBancoConexoes.dart';
import 'package:budget/struct/mbSync/conexoes.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
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

void main() {
  setUpAll(() async {
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
}
