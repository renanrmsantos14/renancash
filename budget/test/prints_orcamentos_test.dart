// Prints de Orçamentos e Metas (Etapa 4 da revisão de UI) para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_orcamentos_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/ (fora do git). Sem banco local: os
// widgets presentacionais recebem os totais prontos. Sem EasyLocalization, os
// textos .tr() saem como chave e o valor sai sem R$ (sem moedas no teste);
// o formato numérico pt-BR vem do formato personalizado (1.758,85).
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/budgetsListPage.dart';
import 'package:budget/pages/objectivePage.dart';
import 'package:budget/pages/objectivesListPage.dart';
import 'package:budget/pages/pastBudgetsPage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/budgetContainer.dart';
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
      'showTotalSpentForBudget': false,
      'showTotalSpentForObjective': false,
      'customCurrencyAmounts': <String, dynamic>{},
      // Números como no pt-BR (1.758,85) sem depender do locale da máquina.
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'locale': 'pt',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };

Widget _app(String modo, Widget corpo) {
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  return Provider<AllWallets>.value(
    value: AllWallets(list: const [], indexedByPk: const {}),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(b)),
      home: Scaffold(body: SafeArea(child: corpo)),
    ),
  );
}

Widget _titulo(BuildContext c, String t) => Padding(
      padding: const EdgeInsets.fromLTRB(13, 14, 13, 12),
      child: Text(t,
          style: const TextStyle(
              fontFamily: 'Geist', fontSize: 20, fontWeight: FontWeight.w600)),
    );

Future<void> _print(WidgetTester t, String nome) async {
  await t.pump(const Duration(seconds: 2));
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../.verificacao/prints/$nome.png'));
}

void _tela(WidgetTester t, {double altura = 844}) {
  t.view.physicalSize = Size(390 * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
}

Objective _meta(String pk, String nome, double alvo,
        {String icone = 'coconut-tree.png',
        String cor = '0xff4caf50',
        ObjectiveType tipo = ObjectiveType.goal,
        bool receita = true,
        DateTime? fim}) =>
    Objective(
      objectivePk: pk,
      name: nome,
      amount: alvo,
      order: 0,
      dateCreated: DateTime(2026, 6, 1),
      endDate: fim,
      income: receita,
      pinned: false,
      iconName: icone,
      colour: cor,
      walletFk: '0',
      archived: false,
      type: tipo,
    );

// Ícones das metas são PNG: decodificar fora do relógio falso.
Future<void> _printComIcones(WidgetTester t, String nome) async {
  await t.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
  await _print(t, nome);
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
    testWidgets('print orçamentos lista $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t);
      await t.pumpWidget(_app(
        modo,
        Builder(
          builder: (c) => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            children: [
              _titulo(c, 'Orçamentos'),
              const CartaoOrcamento(
                nome: 'Ciclo do salário',
                cor: Color(0xFF4CAF50),
                periodo: '5 de nov. – 4 de dez.',
                gasto: 2871.15,
                limite: 4630,
                diasRestantes: 22,
                aVencer: 420,
                hoje: 9 / 30,
              ),
              const SizedBox(height: 12),
              const CartaoOrcamento(
                nome: 'Mercado',
                cor: Color(0xFFFF9800),
                periodo: '1 de nov. – 30 de nov.',
                gasto: 1312.4,
                limite: 1200,
                diasRestantes: 18,
                hoje: 13 / 30,
              ),
              const SizedBox(height: 12),
              const CartaoOrcamento(
                nome: 'Reserva do mês',
                cor: Color(0xFF2196F3),
                periodo: '1 de nov. – 30 de nov.',
                gasto: 650,
                limite: 1000,
                renda: true,
                diasRestantes: 18,
                hoje: 13 / 30,
              ),
            ],
          ),
        ),
      ));
      await _print(t, 'orcamentos_lista_$modo');
    });

    testWidgets('print orçamentos vazio $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 420);
      await t.pumpWidget(_app(
          modo,
          Builder(
              builder: (c) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [_titulo(c, 'Orçamentos'), const SemOrcamentos()],
                  ))));
      await _print(t, 'orcamentos_vazio_$modo');
    });

    for (final (nome, gasto, mostrarGasto) in [
      ('detalhe', 2871.15, false),
      ('estourado', 4980.0, false),
      ('gasto', 2871.15, true),
    ]) {
      testWidgets('print orçamento $nome $modo', skip: _pular, (t) async {
        appStateSettings = _ajustes(modo);
        _tela(t, altura: 420);
        await t.pumpWidget(_app(
          modo,
          Builder(
            builder: (c) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _titulo(c, 'Ciclo do salário'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(13, 4, 13, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('5 de nov. – 4 de dez.',
                          style: EdTexto.rotulo(c)),
                      const SizedBox(height: 8),
                      ResumoOrcamento(
                        gasto: gasto,
                        limite: 4630,
                        grande: true,
                        mostrarGasto: mostrarGasto,
                        diasRestantes: 22,
                        aVencer: 420,
                        hoje: 9 / 30,
                        onTapValor: () {},
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(13, 4, 13, 16),
                  child: Text('Gasto por categoria', style: EdTexto.h2(c)),
                ),
              ],
            ),
          ),
        ));
        await _print(t, 'orcamentos_${nome}_$modo');
      });
    }

    testWidgets('print orçamentos histórico $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 520);
      await t.pumpWidget(_app(
        modo,
        Builder(
          builder: (c) => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            children: [
              _titulo(c, 'Histórico'),
              for (final (titulo, gasto) in [
                ('Ciclo atual', 2871.15),
                ('5 de out. – 4 de nov.', 4980.0),
                ('5 de set. – 4 de out.', 4102.3),
              ]) ...[
                LinhaCicloOrcamento(titulo: titulo, gasto: gasto, limite: 4630),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ));
      await _print(t, 'orcamentos_historico_$modo');
    });
    testWidgets('print metas lista $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t);
      await t.pumpWidget(_app(
        modo,
        Builder(
          builder: (c) => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            children: [
              _titulo(c, 'Metas'),
              CartaoMeta(
                  objective: _meta('a', 'Viagem para o Chile', 12000,
                      fim: DateTime(2027, 6, 30)),
                  alvo: 12000,
                  total: 4350.5,
                  fracao: 4350.5 / 12000,
                  transacoes: 7),
              const SizedBox(height: 12),
              CartaoMeta(
                  objective: _meta('b', 'Carro novo', 5000,
                      icone: 'car(1).png', cor: '0xffff9800'),
                  alvo: 5000,
                  total: 5000,
                  fracao: 1,
                  mostrarTotal: true,
                  transacoes: 12),
              const SizedBox(height: 12),
              CartaoMeta(
                  objective: _meta('c', 'Reserva de emergência', 0,
                      icone: 'coin.png', cor: '0xff2196f3'),
                  alvo: 0,
                  total: 8120,
                  fracao: 0,
                  onDefinirValor: () {}),
              const SizedBox(height: 12),
              LinhaEmprestimoDiferenca(
                  objective: _meta('d', 'Pai', -1,
                      icone: 'coin.png',
                      cor: '0xff9c27b0',
                      tipo: ObjectiveType.loan),
                  diferenca: 850,
                  quitado: false,
                  transacoes: 3),
            ],
          ),
        ),
      ));
      await _printComIcones(t, 'metas_lista_$modo');
    });

    testWidgets('print metas vazio $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 420);
      await t.pumpWidget(_app(
          modo,
          Builder(
              builder: (c) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _titulo(c, 'Metas'),
                      VazioMetas(emprestimo: false, onCriar: () {}),
                    ],
                  ))));
      await _print(t, 'metas_vazio_$modo');
    });

    testWidgets('print meta detalhe $modo', skip: _pular, (t) async {
      appStateSettings = _ajustes(modo);
      _tela(t, altura: 460);
      await t.pumpWidget(_app(
        modo,
        Builder(
          builder: (c) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _titulo(c, 'Viagem para o Chile'),
              ResumoMeta(
                objective: _meta('a', 'Viagem para o Chile', 12000,
                    fim: DateTime(2027, 6, 30)),
                alvo: 12000,
                total: 4350.5,
                fracao: 4350.5 / 12000,
                mostrarTotal: false,
                transacoes: 7,
                onTrocar: () {},
                onIcone: () {},
              ),
            ],
          ),
        ),
      ));
      await _printComIcones(t, 'metas_detalhe_$modo');
    });
  }
}
