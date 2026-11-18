// Prints da área Pendências (aba Pendências, Para validar, cartão Para revisar e folha de rachar conta).
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_pendencias_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/pendencias_*.png (fora do git).
import 'dart:io';

import 'package:budget/database/tables.dart' show AllWallets;
import 'package:budget/pages/homePage/homePageParaRevisar.dart' show HomePageParaRevisar;
import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/avisos.dart' show meuBancoAvisos;
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/classificarDados.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show CatLocal;
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/struct/mbSync/revisao.dart' show MbCandidatoSalario, MbItemRevisao, meuBancoRevisar;
import 'package:budget/struct/meuBancoSync.dart' show meuBancoPareado;
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/editorial/lateralEditorial.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart';
import 'package:budget/widgets/editorial/reembolsoConta.dart' show mbEscolherGastoRachado;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<void> _fonte(String familia, List<String> arquivos) async {
  final l = FontLoader(familia);
  for (final a in arquivos) {
    l.addFont(Future.value(ByteData.sublistView(File(a).readAsBytesSync())));
  }
  await l.load();
}

final _pular = Platform.environment['PRINTS'] != '1';
final _dia = DateTime(2026, 11, 17, 12);

final _opcoes = MbOpcoes.montar(const [
  CatLocal(pk: 'alim', nome: 'Alimentação', receita: false),
  CatLocal(pk: 'normal', nome: 'Normal', receita: false, paiPk: 'alim'),
  CatLocal(pk: 'rest', nome: 'Restaurante', receita: false, paiPk: 'alim'),
  CatLocal(pk: 'deliv', nome: 'Delivery', receita: false, paiPk: 'alim'),
  CatLocal(pk: 'transp', nome: 'Transporte', receita: false),
  CatLocal(pk: 'uber', nome: 'Uber', receita: false, paiPk: 'transp'),
  CatLocal(pk: 'comb', nome: 'Combustível', receita: false, paiPk: 'transp'),
  CatLocal(pk: 'fam', nome: 'Família', receita: false),
  CatLocal(pk: 'lazer', nome: 'Lazer', receita: false),
  CatLocal(pk: 'renda', nome: 'Renda', receita: true),
  CatLocal(pk: 'outros', nome: 'Outras entradas', receita: true),
], const [
  MbVinculoOpcao('mae', 'Mãe', 'emprestimo'),
  MbVinculoOpcao('reserva', 'Reserva de emergência', 'meta'),
]);

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

void _limparEstado() {
  meuBancoAvisos.value = const [];
  meuBancoRevisar.value = const [];
  meuBancoClassificar.value = const [];
  meuBancoSugestoes.value = const {};
  meuBancoIaOk.value = null;
  meuBancoIaEstado.value = const {};
  meuBancoReembolsos.value = const [];
}

void main() {
  setUpAll(() async {
    _padroes = await getDefaultPreferences();
    const f = 'assets/fonts/';
    await _fonte('Geist', ['${f}Geist-Regular.ttf', '${f}Geist-Medium.ttf', '${f}Geist-SemiBold.ttf']);
    await _fonte('GeistMono', ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? 'C:/Users/mendo/development/flutter-3.24.5';
    await _fonte('MaterialIcons', ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  tearDown(_limparEstado);

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print pendências vazia com aviso $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoAvisos.value = const [
        {'banco': 'Banco Inter', 'item_id': 'item-inter'}
      ];
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(modo, const Scaffold(body: PendenciasPage(atualizar: false))));
      await t.pump(const Duration(seconds: 1));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('../../.verificacao/prints/pendencias_vazia_aviso_$modo.png'));
    });

    testWidgets('print pendências tudo validado $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(modo, const Scaffold(body: PendenciasPage(atualizar: false))));
      await t.pump(const Duration(seconds: 1));
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('../../.verificacao/prints/pendencias_tudo_validado_$modo.png'));
    });

    testWidgets('print pendências carregando $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
          _app(modo, const Scaffold(body: PendenciasPage(atualizar: false, carregando: true))));
      await t.pump();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('../../.verificacao/prints/pendencias_carregando_$modo.png'));
    });

    testWidgets('print item classificar com sugestão e subs $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      mbOpcoesClassificar = _opcoes;
      meuBancoClassificar.value = [
        MbLancamentoIa(
          pk: 'mb:c1',
          descricao: 'Republic CA',
          valor: -68.90,
          data: _dia,
          conta: 'Inter',
          categoriaNome: 'A classificar',
        ),
        MbLancamentoIa(
          pk: 'mb:c2',
          descricao: 'UBER *TRIP',
          valor: -14.50,
          data: _dia.subtract(const Duration(days: 1)),
          conta: 'Nubank',
        ),
      ];
      meuBancoSugestoes.value = const {
        'mb:c1': MbSugestao(
          'mb:c1',
          'alim',
          confianca: 0.92,
          fonte: MbFonteSugestao.ia,
        ),
      };
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(modo, const Scaffold(body: PendenciasPage(atualizar: false))));
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/pendencias_classificar_sugestao_$modo.png'));
    });

    testWidgets('print item classificar sem sugestão $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      mbOpcoesClassificar = _opcoes;
      meuBancoIaOk.value = false;
      meuBancoClassificar.value = [
        MbLancamentoIa(
          pk: 'mb:s1',
          descricao: 'PAGAMENTO   BOLETO   CONDOMINIO   EDIFICIO   SOLAR',
          valor: -420.00,
          data: _dia,
          conta: 'Inter',
          categoriaNome: 'Outros',
        ),
      ];
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(modo, const Scaffold(body: PendenciasPage(atualizar: false))));
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/pendencias_classificar_sem_sugestao_$modo.png'));
    });

    testWidgets('print item classificar pagador longo $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      mbOpcoesClassificar = _opcoes;
      final original = mbBuscarCandidatosReembolso;
      mbBuscarCandidatosReembolso = (_, valor, data, __) async => mbSugerirReembolso([
            MbGastoCandidato(
                'mb:g1',
                'CHURRASCARIA E RESTAURANTE RECANTO GAUCHO DA SERRA LTDA',
                'Restaurante',
                _dia.subtract(const Duration(days: 2)),
                18000),
          ], valor: valor, data: data, categoriasDoPagador: {'Restaurante'});
      addTearDown(() => mbBuscarCandidatosReembolso = original);
      meuBancoReembolsos.value = const [
        MbVinculoReembolso(
            'mb:r0', 'mb:g0', 'CARLOS EDUARDO DE ALMEIDA', 5000),
        MbVinculoReembolso(
            'mb:r1', 'mb:g2', 'CARLOS EDUARDO DE ALMEIDA', 4000),
      ];
      meuBancoClassificar.value = [
        MbLancamentoIa(
          pk: 'mb:pl1',
          descricao:
              'Pix recebido  -  Carlos Eduardo   de Almeida Monteiro Filho   04928192800',
          valor: 90.00,
          data: _dia,
          conta: 'Conta corrente · Inter',
          categoriaNome: 'Transferências',
        ),
        MbLancamentoIa(
          pk: 'mb:pl2',
          descricao: 'UBER *TRIP',
          valor: -18.00,
          data: _dia,
          conta: 'Inter',
        ),
      ];
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(modo, const Scaffold(body: PendenciasPage(atualizar: false))));
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/pendencias_classificar_pagador_longo_$modo.png'));
    });

    testWidgets('print pendências revisar pix recebido com pagador $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoRevisar.value = const [
        MbItemRevisao(
          'rev1',
          'pix_recebido',
          txId: 'tx_rev1',
          data: '2026-11-15',
          descricao: 'PIX RECEBIDO   MARIA FERNANDA   OLIVEIRA SANTOS',
          destinatario: 'MARIA FERNANDA OLIVEIRA SANTOS',
          valor: 135.50,
        ),
        MbItemRevisao(
          'rev2',
          'envio_santander',
          txId: 'tx_rev2',
          data: '2026-11-14',
          descricao: 'TED ENVIADA BANCO SANTANDER',
          valor: 800.00,
        ),
      ];
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(modo, const Scaffold(body: PendenciasPage(atualizar: false))));
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/pendencias_revisar_pix_recebido_$modo.png'));
    });

    testWidgets('print cartão HomePageParaRevisar $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      meuBancoRevisar.value = const [
        MbItemRevisao(
          'h1',
          'pix_recebido',
          txId: 'tx_h1',
          data: '2026-11-15',
          descricao: 'PIX RECEBIDO   MARIA FERNANDA   OLIVEIRA SANTOS',
          destinatario: 'MARIA FERNANDA OLIVEIRA SANTOS',
          valor: 135.50,
        ),
        MbItemRevisao(
          'h2',
          'pix_enviado',
          txId: 'tx_h2',
          data: '2026-11-14',
          descricao: 'PIX ENVIADO JOAO PEDRO COSTA',
          destinatario: 'JOAO PEDRO COSTA',
          valor: -85.00,
        ),
        MbItemRevisao(
          'h3',
          'salario_nao_detectado',
          dias: 35,
          candidatos: [
            MbCandidatoSalario('tx_sal', '2026-11-05', 'CREDITO SALARIO BETINHOS', 2150.00),
          ],
        ),
        MbItemRevisao(
          'h4',
          'envio_santander',
          txId: 'tx_h4',
          data: '2026-11-10',
          descricao: 'ENVIO SANTANDER',
          valor: -500.00,
        ),
      ];
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(
        modo,
        Scaffold(
          body: Builder(
            builder: (c) => ColoredBox(
              color: cores(c).bg,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 20),
                children: const [HomePageParaRevisar(atualizar: false)],
              ),
            ),
          ),
        ),
      ));
      await t.pump(const Duration(seconds: 1));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/pendencias_cartao_revisar_$modo.png'));
    });

    testWidgets('print folha gastos rachados vazia com nenhum $modo', skip: _pular, (t) async {
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
                onPressed: () => mbEscolherGastoRachado(
                  c,
                  sugestoes: const [],
                  valor: 60,
                  data: _dia,
                  comNenhum: true,
                ),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('abrir'));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/pendencias_rachar_folha_vazia_$modo.png'));
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
    });
  }

  testWidgets('print pendências desktop claro', skip: _pular, (t) async {
    appStateSettings = _ajustes('claro');
    mbOpcoesClassificar = _opcoes;
    meuBancoPareado.value = true;
    mbPaginaAtual.value = 18;
    addTearDown(() {
      meuBancoPareado.value = false;
      mbPaginaAtual.value = 0;
    });
    meuBancoAvisos.value = const [
      {'banco': 'Banco Inter', 'item_id': 'item-inter'}
    ];
    meuBancoClassificar.value = [
      MbLancamentoIa(
        pk: 'mb:d1',
        descricao: 'PIX ENVIADO FABIANA SILVA',
        valor: -500.00,
        data: _dia,
        conta: 'Inter',
        categoriaNome: 'A classificar',
      ),
      MbLancamentoIa(
        pk: 'mb:d2',
        descricao: 'UBER *TRIP',
        valor: -24.90,
        data: _dia.subtract(const Duration(days: 1)),
        conta: 'Nubank',
      ),
    ];
    meuBancoSugestoes.value = const {
      'mb:d1': MbSugestao(
        'mb:d1',
        'fam',
        titulo: 'Empréstimo Mãe',
        vinculoPk: 'mae',
        confianca: 0.45,
        pergunta: 'Esse Pix de R\$ 500 para Fabiana foi empréstimo para a Mãe?',
        fonte: MbFonteSugestao.ia,
      ),
    };
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(
      'claro',
      Scaffold(
        body: LayoutDesktop(
          lateral: LateralEditorial.comDados(
            contas: const [
              (id: 'a', nome: 'Nubank'),
              (id: 'b', nome: 'Banco Inter'),
            ],
            sincronizadoEm: _dia.subtract(const Duration(minutes: 5)),
          ),
          conteudo: const PendenciasPage(atualizar: false),
        ),
      ),
    ));
    await t.pump(const Duration(seconds: 1));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../../.verificacao/prints/pendencias_desktop_claro.png'));
  });
}
