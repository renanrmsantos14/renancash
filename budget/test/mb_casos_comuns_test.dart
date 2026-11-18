// Casos mais comuns com menos toques: iguais na fila, rendimentos de poupança, estornos, "como no mês passado",
// rachar recorrente.
import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/casosComuns.dart';
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/classificarDados.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show CatLocal;
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _hoje = DateTime(2026, 11, 17, 12);

MbLancamentoIa _l(String pk, String descricao, double valor, {DateTime? data, String conta = 'Inter'}) =>
    MbLancamentoIa(
        pk: pk,
        descricao: descricao,
        valor: valor,
        data: data ?? _hoje,
        conta: conta,
        categoriaNome: 'A classificar');

MbHistorico _h(String pk, String nome, double valor, DateTime data,
        {String cat = 'alim', String? sub, String catNome = 'Alimentação', String? subNome}) =>
    (
      pk: pk,
      nome: nome,
      valor: valor,
      data: data,
      categoriaPk: cat,
      subPk: sub,
      categoriaNome: catNome,
      subNome: subNome,
    );

DateTime _diasAtras(int d) => DateTime(_hoje.year, _hoje.month, _hoje.day - d, 12);

final _opcoes = MbOpcoes.montar(const [
  CatLocal(pk: 'alim', nome: 'Alimentação', receita: false),
  CatLocal(pk: 'normal', nome: 'Normal', receita: false, paiPk: 'alim'),
  CatLocal(pk: 'almoco', nome: 'Almoço Betinhos', receita: false, paiPk: 'alim'),
  CatLocal(pk: 'transp', nome: 'Transporte', receita: false),
  CatLocal(pk: 'uber', nome: 'Uber', receita: false, paiPk: 'transp'),
  CatLocal(pk: 'assin', nome: 'Assinaturas', receita: false),
  CatLocal(pk: 'pix', nome: 'Pix', receita: false),
  CatLocal(pk: 'trab', nome: 'Trabalho', receita: true),
  CatLocal(pk: 'salario', nome: 'Salário', receita: true, paiPk: 'trab'),
  CatLocal(pk: 'inv', nome: 'Investimentos', receita: true),
  CatLocal(pk: '0', nome: 'Ajuste de saldo', receita: false),
]);

void main() {
  group('iguais na fila', () {
    test('mesmo favorecido normalizado e mesmo sinal, ele primeiro', () {
      final fila = [
        _l('mb:1', 'Compra no débito - UBER *TRIP', -9.96),
        _l('mb:2', 'UBER TRIP', -12.4),
        _l('mb:3', 'Estorno Uber', 16.95),
        _l('mb:4', 'IFOOD', -30),
        _l('mb:5', 'COMPRA UBER TRIP 123', -7.58),
      ];
      expect([for (final x in mbIguaisNaFila(fila, fila[1])) x.pk], ['mb:2', 'mb:1', 'mb:5']);
      expect([for (final x in mbIguaisNaFila(fila, fila[3])) x.pk], ['mb:4']);
    });

    test('descrição sem favorecido não junta nada', () {
      final fila = [_l('mb:1', 'PIX ENVIADO', -5), _l('mb:2', 'PIX ENVIADO', -5)];
      expect(mbIguaisNaFila(fila, fila.first).length, 1);
    });
  });

  group('ruído', () {
    test('juros de poupança: entrada de centavos com JUROS ou RENDIMENTO', () {
      expect(mbEhJurosPoupanca(_l('a', 'JUROS   TAXA =   0,50   %', .01)), true);
      expect(mbEhJurosPoupanca(_l('b', 'Rendimento poupança', .37)), true);
      expect(mbEhJurosPoupanca(_l('c', 'JUROS   TAXA =   0,50   %', 1.2)), false); // R$ 1 ou mais
      expect(mbEhJurosPoupanca(_l('d', 'JUROS CHEQUE ESPECIAL', -.5)), false); // saída
      expect(mbEhJurosPoupanca(_l('e', 'PIX RECEBIDO JOAO', .5)), false);
    });

    test('rendimentos viram um cartão só a partir de 2', () {
      final um = [_l('a', 'JUROS TAXA', .01), _l('b', 'UBER', -9)];
      expect(mbRendimentosJuntos(um), isEmpty);
      final dois = [...um, _l('c', 'JUROS TAXA', .02)];
      expect([for (final x in mbRendimentosJuntos(dois)) x.pk], ['a', 'c']);
    });

    test('estorno casa com a compra de mesmo valor, pelo estabelecimento e depois a mais recente', () {
      final gastos = [
        MbGastoCandidato('mb:posto', 'POSTO SETE ESTRELAS', 'Transporte', _diasAtras(2), 1695),
        MbGastoCandidato('mb:uber', 'Uber — compra estornada', 'Transporte', _diasAtras(5), 1695),
        MbGastoCandidato('mb:outro', 'MERCADO', 'Mercado', _diasAtras(1), 2000),
      ];
      expect(mbEhEstorno(_l('e', 'Estorno Uber', 16.95)), true);
      expect(mbEhEstorno(_l('e', 'Uber — compra estornada', -16.95)), false); // é a compra, não o estorno
      expect(mbCompraDoEstorno(gastos, _l('e', 'Estorno Uber', 16.95))?.pk, 'mb:uber');
      expect(mbCompraDoEstorno(gastos, _l('e', 'Estorno - Compra cartão', 16.95))?.pk, 'mb:posto'); // mais recente
      expect(mbCompraDoEstorno(gastos, _l('e', 'Estorno - Compra cartão', 5)), isNull);
      final abatida = [MbGastoCandidato('mb:x', 'UBER', 'Transporte', _diasAtras(1), 1695, reembolsado: 500)];
      expect(mbCompraDoEstorno(abatida, _l('e', 'Estorno Uber', 16.95)), isNull);
    });
  });

  group('como no mês passado', () {
    test('Pix para a mesma pessoa com o mesmo valor: a categoria e a sub da última vez', () {
      final pix = _l('mb:nov', 'Pix enviado  - Juliana Rodrigues De Paula', -21, data: DateTime(2026, 11, 25, 9));
      final hist = [
        _h('mb:set', 'Pix enviado  - Juliana Rodrigues De Paula', -21, DateTime(2026, 9, 25), cat: 'assin'),
        _h('mb:out', 'Pix enviado - Juliana Rodrigues de Paula', -21, DateTime(2026, 10, 25), cat: 'alim', sub: 'normal'),
      ];
      final s = mbComoMesPassado(pix, hist, _opcoes)!;
      expect((s.categoriaPk, s.subPk, s.titulo, s.fonte), ('alim', 'normal', null, MbFonteSugestao.mesPassado));
    });

    test('Pix com outro valor, de outra pessoa, longe de um mês ou numa categoria sem utilidade: nada', () {
      final pix = _l('mb:nov', 'PIX ENVIADO JULIANA PAULA', -21, data: DateTime(2026, 11, 25, 9));
      for (final h in [
        _h('a', 'PIX ENVIADO JULIANA PAULA', -25, DateTime(2026, 10, 25)),
        _h('b', 'PIX ENVIADO FABIANA SILVA', -21, DateTime(2026, 10, 25)),
        _h('c', 'PIX ENVIADO JULIANA PAULA', -21, DateTime(2026, 11, 15)), // 10 dias
        _h('d', 'PIX ENVIADO JULIANA PAULA', -21, DateTime(2026, 9, 1)), // 85 dias
        _h('e', 'PIX ENVIADO JULIANA PAULA', -21, DateTime(2026, 10, 25), cat: 'pix', catNome: 'Pix'),
      ]) {
        expect(mbComoMesPassado(pix, [h], _opcoes), isNull, reason: h.pk);
      }
    });

    test('salário: mesmo pagador ou categoria Salário, valor ±15%, com o título da última vez', () {
      final sal = _l('mb:nov', "Pix recebido - Betinho's Locadora De Automoveis Lt", 2150, data: DateTime(2026, 11, 6, 9));
      final hist = [
        _h('mb:set', 'salario', 1852, DateTime(2026, 9, 4), cat: 'trab', sub: 'salario', catNome: 'Trabalho', subNome: 'Salário'),
        _h('mb:out', 'salario', 1951, DateTime(2026, 10, 6), cat: 'trab', sub: 'salario', catNome: 'Trabalho', subNome: 'Salário'),
      ];
      final s = mbComoMesPassado(sal, hist, _opcoes)!;
      expect((s.categoriaPk, s.subPk, s.titulo), ('trab', 'salario', 'salario'));
      final bonus = _l('mb:b', 'PIX RECEBIDO EMPRESA', 3000, data: DateTime(2026, 11, 6, 9)); // +54%
      expect(mbComoMesPassado(bonus, hist, _opcoes), isNull);
    });

    test('juros da poupança do mês passado', () {
      final j = _l('mb:nov', 'JUROS   TAXA =   0,50   %', .01, data: DateTime(2026, 11, 12, 9));
      final hist = [_h('mb:out', 'JUROS   TAXA =   0,50   %', .01, DateTime(2026, 10, 10), cat: 'inv', catNome: 'Investimentos')];
      expect(mbComoMesPassado(j, hist, _opcoes)?.categoriaPk, 'inv');
    });
  });

  group('rachar recorrente', () {
    final ranking = mbSugerirReembolso([
      MbGastoCandidato('mb:rest', 'RESTAURANTE', 'Restaurante', _diasAtras(2), 9000),
      MbGastoCandidato('mb:posto', 'POSTO', 'Transporte', _diasAtras(1), 20000),
    ], valor: 32, data: _hoje, categoriasDoPagador: {'Restaurante'}); // R$ 32 não é parte exata de R$ 90

    test('sem parte exata não há destaque; com quem já rachou 2 vezes, a categoria dele basta', () {
      expect(mbReembolsoForte(ranking), isNull);
      expect(mbReembolsoForte(ranking, recorrente: true)?.gasto.pk, 'mb:rest');
    });

    test('vezes que o pagador já rachou', () {
      const v = [
        MbVinculoReembolso('mb:a', 'mb:g1', 'JUNIOR SILVA', 3000),
        MbVinculoReembolso('mb:b', 'mb:g2', 'JUNIOR SILVA', 2000),
        MbVinculoReembolso('mb:c', 'mb:g3', 'ANA', 1000),
      ];
      expect(mbVezesQueRachou(v, 'JUNIOR SILVA'), 2);
      expect(mbVezesQueRachou(v, ''), 0);
    });
  });

  group('telas', () {
    Future<void> abrir(WidgetTester t, List<MbLancamentoIa> fila,
        {Map<String, MbSugestao> sugestoes = const {}}) async {
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'forceFullDarkBackground': false,
      };
      mbOpcoesClassificar = _opcoes;
      meuBancoClassificar.value = fila;
      meuBancoSugestoes.value = sugestoes;
      t.view.physicalSize = const Size(390 * 3, 1400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: temaEditorial(Brightness.light),
        home: const Scaffold(body: PendenciasPage(atualizar: false)),
      ));
      await t.pump();
    }

    tearDown(() {
      meuBancoClassificar.value = const [];
      meuBancoSugestoes.value = const {};
      meuBancoReembolsos.value = const [];
    });

    testWidgets('rendimentos de poupança: um cartão só com Confirmar todos, contado uma vez', (t) async {
      await abrir(t, [
        _l('mb:j1', 'JUROS TAXA', .01, conta: 'Poupança'),
        _l('mb:u', 'UBER TRIP', -9.96),
        _l('mb:j2', 'JUROS TAXA', .02, data: _diasAtras(30), conta: 'Poupança'),
      ], sugestoes: {
        'mb:j1': const MbSugestao('mb:j1', 'inv', confianca: .9, fonte: MbFonteSugestao.mesPassado),
      });
      expect(find.text('1 de 2'), findsOneWidget);
      expect(find.text('R\$ 0,03'), findsOneWidget);
      expect(find.text('2 rendimentos de poupança · Poupança'), findsOneWidget);
      expect(find.text('Como no mês passado'), findsOneWidget);
      expect(find.text('Investimentos'), findsOneWidget);
      expect(find.text('Confirmar todos'), findsOneWidget);
      expect(mbTotalPendencias(), 2);
    });

    testWidgets('salário como no mês passado: sugestão no topo, sem "Rachou uma conta?"', (t) async {
      await abrir(t, [
        _l('mb:s', "PIX RECEBIDO BETINHO'S LOCADORA", 2150),
      ], sugestoes: {
        'mb:s': const MbSugestao('mb:s', 'trab',
            subPk: 'salario', titulo: 'salario', confianca: .9, fonte: MbFonteSugestao.mesPassado),
      });
      expect(find.text('Como no mês passado'), findsOneWidget);
      expect(find.text('RECEITA · Trabalho › Salário'), findsOneWidget);
      expect(find.text('Rachou uma conta?'), findsNothing);
    });

    testWidgets('estorno: a compra de mesmo valor com "Abater da compra"', (t) async {
      final original = mbBuscarCandidatosReembolso;
      mbBuscarCandidatosReembolso = (_, valor, data, __) async => mbSugerirReembolso([
            MbGastoCandidato('mb:uber', 'Uber — compra estornada', 'Transporte', _diasAtras(1), 1695),
            MbGastoCandidato('mb:posto', 'POSTO', 'Transporte', _diasAtras(1), 5000),
          ], valor: valor, data: data);
      addTearDown(() => mbBuscarCandidatosReembolso = original);
      await abrir(t, [_l('mb:e', 'Estorno Uber', 16.95)]);
      await t.pump();
      expect(find.text('Estorno de uma compra'), findsOneWidget);
      expect(find.text('Uber — compra estornada'), findsOneWidget);
      expect(find.text('Abater da compra'), findsOneWidget);
      expect(find.text('É de outra compra'), findsOneWidget);
      // Sem sugestão da IA, o cartão pede a categoria certa em chips; o estorno segue na caixa dele.
      expect(find.textContaining('Sem sugestão para este'), findsOneWidget);
      expect(find.text('Qual é a categoria?'), findsOneWidget);
    });

    testWidgets('rachar recorrente: quem já mandou 2 partes tem o gasto em destaque sem parte exata', (t) async {
      final original = mbBuscarCandidatosReembolso;
      mbBuscarCandidatosReembolso = (_, valor, data, __) async => mbSugerirReembolso([
            MbGastoCandidato('mb:rest', 'RESTAURANTE DO ZE', 'Restaurante', _diasAtras(2), 9000),
          ], valor: valor, data: data, categoriasDoPagador: {'Restaurante'});
      addTearDown(() => mbBuscarCandidatosReembolso = original);
      meuBancoReembolsos.value = const [
        MbVinculoReembolso('mb:a', 'mb:g1', 'JUNIOR SILVA', 3000),
        MbVinculoReembolso('mb:b', 'mb:g2', 'JUNIOR SILVA', 2000),
      ];
      await abrir(t, [_l('mb:r', 'PIX RECEBIDO JUNIOR SILVA', 32)]);
      await t.pump();
      await t.pump();
      expect(find.text('Junior Silva já mandou a parte de 2 contas'), findsOneWidget);
      expect(find.text('RESTAURANTE DO ZE'), findsOneWidget);
      expect(find.text('É de outra conta'), findsOneWidget);
      expect(find.textContaining('Sem sugestão para este'), findsOneWidget);
      expect(find.text('Qual é a categoria?'), findsOneWidget);
    });

    testWidgets('entrada sem gasto em destaque continua com "Sem sugestão para este"', (t) async {
      final original = mbBuscarCandidatosReembolso;
      mbBuscarCandidatosReembolso = (_, valor, data, __) async => mbSugerirReembolso(const [], valor: valor, data: data);
      addTearDown(() => mbBuscarCandidatosReembolso = original);
      await abrir(t, [_l('mb:r', 'PIX RECEBIDO JUNIOR SILVA', 32)]);
      await t.pump();
      expect(find.text('É a parte de uma conta que eu paguei'), findsOneWidget);
      expect(find.textContaining('Sem sugestão para este'), findsOneWidget);
    });
  });
}
