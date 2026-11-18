// Prints dos casos comuns (iguais, rendimentos, estorno, mês passado e rachar recorrente) para revisão.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_casos_comuns_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/casos_*.png (fora do git).
import 'dart:io';

import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/casosComuns.dart';
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/classificarDados.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show CatLocal;
import 'package:budget/struct/mbSync/reembolso.dart';
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
final _dia = DateTime(2026, 11, 17, 12);

MbLancamentoIa _l(String pk, String descricao, double valor, {int diasAtras = 0, String conta = 'Inter'}) =>
    MbLancamentoIa(
        pk: pk,
        descricao: descricao,
        valor: valor,
        data: DateTime(_dia.year, _dia.month, _dia.day - diasAtras, 12),
        conta: conta,
        categoriaNome: 'A classificar');

final _opcoes = MbOpcoes.montar(const [
  CatLocal(pk: 'alim', nome: 'Alimentação', receita: false),
  CatLocal(pk: 'normal', nome: 'Normal', receita: false, paiPk: 'alim'),
  CatLocal(pk: 'transp', nome: 'Transporte', receita: false),
  CatLocal(pk: 'uber', nome: 'Uber', receita: false, paiPk: 'transp'),
  CatLocal(pk: 'comb', nome: 'Combustível', receita: false, paiPk: 'transp'),
  CatLocal(pk: 'lazer', nome: 'Lazer', receita: false),
  CatLocal(pk: 'trab', nome: 'Trabalho', receita: true),
  CatLocal(pk: 'salario', nome: 'Salário', receita: true, paiPk: 'trab'),
  CatLocal(pk: 'bonus', nome: 'Bônus', receita: true, paiPk: 'trab'),
  CatLocal(pk: 'inv', nome: 'Investimentos', receita: true),
  CatLocal(pk: 'divida', nome: 'Recebi Dívida', receita: true),
]);

void main() {
  setUpAll(() async {
    const f = 'assets/fonts/';
    await _fonte('Geist', ['${f}Geist-Regular.ttf', '${f}Geist-Medium.ttf', '${f}Geist-SemiBold.ttf']);
    await _fonte('GeistMono', ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? 'C:/Users/mendo/development/flutter-3.24.5';
    await _fonte('MaterialIcons', ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  // Cada caso: a fila, as sugestões e, nas entradas, os gastos candidatos (sem banco).
  final casos = <String, (List<MbLancamentoIa>, Map<String, MbSugestao>, List<MbGastoCandidato>)>{
    'iguais': (
      [
        _l('mb:u1', 'Compra no débito - UBER *TRIP', -10.08),
        for (var i = 1; i < 8; i++) _l('mb:u${i + 1}', 'UBER TRIP', -9.5 - i, diasAtras: i),
      ],
      const {
        'mb:u1': MbSugestao('mb:u1', 'transp',
            subPk: 'uber', titulo: 'Uber', confianca: .9, fonte: MbFonteSugestao.padrao),
      },
      const [],
    ),
    'rendimentos': (
      [
        _l('mb:j1', 'JUROS   TAXA =   0,50   %', .01, conta: 'Poupança'),
        _l('mb:j2', 'JUROS   TAXA =   0,50   %', .01, diasAtras: 31, conta: 'Poupança'),
        _l('mb:j3', 'JUROS   TAXA =   0,50   %', .01, diasAtras: 61, conta: 'Poupança'),
      ],
      const {
        'mb:j1': MbSugestao('mb:j1', 'inv', confianca: .9, fonte: MbFonteSugestao.mesPassado),
      },
      const [],
    ),
    'estorno': (
      [_l('mb:e', 'Estorno - Compra cartão', 16.95, conta: 'Nubank')],
      const {},
      [
        MbGastoCandidato('mb:g1', 'Uber — compra estornada', 'Transporte', DateTime(2026, 11, 14, 12), 1695),
        MbGastoCandidato('mb:g2', 'Combustível — Auto Posto', 'Transporte', DateTime(2026, 11, 15, 12), 5000),
      ],
    ),
    'mes_passado': (
      [_l('mb:s', "Pix recebido - Betinho's Locadora De Automoveis Lt", 2150)],
      const {
        'mb:s': MbSugestao('mb:s', 'trab',
            subPk: 'salario', titulo: 'salario', confianca: .9, fonte: MbFonteSugestao.mesPassado),
      },
      const [],
    ),
    'rachar_recorrente': (
      [_l('mb:r', 'Pix recebido - Junior Silva', 32)],
      const {},
      [
        MbGastoCandidato('mb:g1', 'RESTAURANTE DO ZE', 'Restaurante', DateTime(2026, 11, 15, 12), 9000),
        MbGastoCandidato('mb:g2', 'POSTO SHELL', 'Transporte', DateTime(2026, 11, 16, 12), 20000),
      ],
    ),
  };

  for (final modo in ['claro', 'escuro']) {
    final b = modo == 'claro' ? Brightness.light : Brightness.dark;
    final ajustes = {
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'forceFullDarkBackground': false,
      'font': 'Geist',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
    };
    for (final MapEntry(key: nome, value: (fila, sugestoes, gastos)) in casos.entries) {
      testWidgets('print casos $nome $modo', skip: _pular, (t) async {
        appStateSettings = {...ajustes};
        mbOpcoesClassificar = _opcoes;
        meuBancoClassificar.value = fila;
        meuBancoSugestoes.value = sugestoes;
        meuBancoReembolsos.value = nome == 'rachar_recorrente'
            ? const [
                MbVinculoReembolso('mb:a', 'mb:x1', 'JUNIOR SILVA', 4500),
                MbVinculoReembolso('mb:b', 'mb:x2', 'JUNIOR SILVA', 3000),
              ]
            : const [];
        final original = mbBuscarCandidatosReembolso;
        mbBuscarCandidatosReembolso = (_, valor, data, __) async => mbSugerirReembolso(gastos,
            valor: valor, data: data, categoriasDoPagador: {'Restaurante'});
        addTearDown(() {
          meuBancoClassificar.value = const [];
          meuBancoSugestoes.value = const {};
          meuBancoReembolsos.value = const [];
          mbBuscarCandidatosReembolso = original;
        });
        t.view.physicalSize = const Size(390 * 2, 844 * 2);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: temaFlutter(temaAtivo(b)),
          home: const Scaffold(body: PendenciasPage(atualizar: false)),
        ));
        await t.pump(const Duration(seconds: 1));
        await t.pump(); // o destaque avisa o cartão depois do quadro (esconde "Sem sugestão")
        await expectLater(
            find.byType(MaterialApp), matchesGoldenFile('../../.verificacao/prints/casos_${nome}_$modo.png'));
      });
    }
  }
}
