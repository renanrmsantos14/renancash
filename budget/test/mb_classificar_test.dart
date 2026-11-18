// Fila "Para validar" da aba Pendências: normalização do favorecido, fila, padrões, fallback sem IA,
// validação da resposta da IA no aparelho e o cartão (sem rede nem banco).
import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/classificarDados.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show CatLocal;
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MbLancamentoIa _l(String pk,
        {String descricao = 'PIX ENVIADO FABIANA SILVA',
        double valor = -500,
        DateTime? data,
        String categoria = 'A classificar',
        String? categoriaPk,
        bool editado = false,
        bool pendente = false,
        MbItemRevisao? revisao}) =>
    MbLancamentoIa(
        pk: pk,
        descricao: descricao,
        valor: valor,
        data: data ?? DateTime(2026, 11, 10, 12),
        conta: 'Inter',
        categoriaNome: categoria,
        categoriaPk: categoriaPk,
        editado: editado,
        pendente: pendente,
        revisao: revisao);

final _opcoes = MbOpcoes.montar(const [
  CatLocal(pk: 'alim', nome: 'Alimentação', receita: false),
  CatLocal(pk: 'deliv', nome: 'Delivery', receita: false, paiPk: 'alim'),
  CatLocal(pk: 'rest', nome: 'Restaurante', receita: false, paiPk: 'alim'),
  CatLocal(pk: 'transp', nome: 'Transporte', receita: false),
  CatLocal(pk: 'uber', nome: 'Uber', receita: false, paiPk: 'transp'),
  CatLocal(pk: 'mb:cat:d:Transporte', nome: 'Transporte', receita: false),
  CatLocal(pk: 'mb:cat:d:A classificar', nome: 'A classificar', receita: false),
  CatLocal(pk: 'sal', nome: 'Salário', receita: true),
  CatLocal(pk: '0', nome: 'Ajuste de saldo', receita: false),
  CatLocal(pk: 'beleza', nome: 'Beleza', receita: false),
], const [
  MbVinculoOpcao('mae', 'Mãe', 'emprestimo')
]);

void main() {
  group('lógica', () {
    test('categoria sem utilidade: lista única e qualquer Transferência', () {
      for (final n in ['A classificar', 'Pix', 'Transferências', 'Transferência - TED', 'outros', '', null]) {
        expect(mbSemCategoriaUtil(n), true, reason: '$n');
      }
      for (final n in ['Alimentação', 'Mercado', 'Transporte']) {
        expect(mbSemCategoriaUtil(n), false, reason: n);
      }
    });

    test('chave do favorecido ignora caixa, acento, número e prefixo do banco', () {
      expect(mbChavePadrao('PIX ENVIADO - Fabiana Silva 123'), 'FABIANA SILVA');
      expect(mbChavePadrao('Pix enviado Fabiana Silva'), 'FABIANA SILVA');
      expect(mbChavePadrao('Compra no débito IFOOD *IFD Agência São Paulo'), 'IFOOD IFD AGENCIA SAO');
      expect(mbChavePadrao('UBER *TRIP'), 'UBER TRIP');
      expect(mbChavePadrao('123 - *'), '');
    });

    test('fila: tudo que o mapeamento deixou em "A classificar", antigo sem categoria útil e Pix do Worker', () {
      final fila = mbFilaClassificar([
        _l('mb:novo', data: DateTime(2026, 11, 3)),
        // Já validado (categoria útil escolhida pelo usuário): fora da fila, editado ou não.
        _l('mb:validado', categoria: 'Transporte', editado: true),
        _l('mb:historico', categoria: 'Transporte', data: DateTime(2026, 9, 1)),
        _l('mb:antigoPix', categoria: 'Pix', data: DateTime(2026, 9, 2), editado: true),
        _l('mb:pendente', pendente: true),
        _l('mb:revisado'),
        _l('mb:worker', categoria: 'Transporte', data: DateTime(2026, 8, 1), editado: true,
            revisao: const MbItemRevisao('w', 'pix_enviado', txId: 'worker')),
        // Ajuste de saldo e investimento (CDB) nunca entram.
        _l('mb:ajuste', categoria: 'Balance Correction', categoriaPk: '0', valor: 28.01),
        _l('mb:inv:cdb1', descricao: 'CDB - BANCO INTER S.A', categoria: 'Ajuste de saldo', valor: 550.03),
      ], revisados: {'mb:revisado'});
      expect(fila.map((l) => l.pk), ['mb:novo', 'mb:antigoPix', 'mb:worker']);
    });

    test('opções: uma categoria por nome (a do usuário), sem as inúteis nem a de ajuste, com subs', () {
      expect(_opcoes.categorias.map((c) => c.pk), ['alim', 'transp', 'sal', 'beleza']);
      expect(_opcoes.categoria('0'), isNull);
      expect(_opcoes.categoria('mb:cat:d:Transporte')!.pk, 'transp'); // repetida de mesmo nome
      expect(_opcoes.categoria('alim')!.subs.map((s) => s.nome), ['Delivery', 'Restaurante']);
      final ctx = _opcoes.contexto([const MbPadrao('FABIANA SILVA', 'alim', vinculoPk: 'mae')]);
      expect((ctx['categorias'] as List).first, {
        'pk': 'alim',
        'nome': 'Alimentação',
        'receita': false,
        'subs': [
          {'pk': 'deliv', 'nome': 'Delivery'},
          {'pk': 'rest', 'nome': 'Restaurante'}
        ],
      });
      expect(ctx['exemplos'], [
        {'descricao': 'FABIANA SILVA', 'categoria': 'alim', 'vinculo': 'mae'}
      ]);
    });

    test('padrões: mesma escolha soma, outra recomeça; mais recente na frente; JSON ida e volta', () {
      var p = mbRegistrarPadrao(const [], const MbPadrao('FABIANA SILVA', 'alim'));
      p = mbRegistrarPadrao(p, const MbPadrao('UBER TRIP', 'transp', subPk: 'uber'));
      p = mbRegistrarPadrao(p, const MbPadrao('FABIANA SILVA', 'alim'));
      expect(p.map((x) => '${x.chave}:${x.vezes}'), ['FABIANA SILVA:2', 'UBER TRIP:1']);
      p = mbRegistrarPadrao(p, const MbPadrao('FABIANA SILVA', 'transp'));
      expect(p.first.vezes, 1);
      expect(mbRegistrarPadrao(p, const MbPadrao('', 'alim')), same(p));
      final volta = mbPadroesDeJson([for (final x in p) x.toJson()]..add({'lixo': 1}));
      expect(volta.map((x) => x.toJson()), p.map((x) => x.toJson()));
    });

    test('sem IA: padrão do favorecido, senão a categoria atual útil, senão nada', () {
      const padroes = [MbPadrao('FABIANA SILVA', 'alim', titulo: 'Empréstimo Mãe', vinculoPk: 'mae', vezes: 2)];
      final s = mbSugestaoLocal(_l('mb:1', descricao: 'Pix enviado Fabiana Silva'), padroes, _opcoes)!;
      expect([s.categoriaPk, s.titulo, s.vinculoPk, s.confianca, s.fonte],
          ['alim', 'Empréstimo Mãe', 'mae', 0.9, MbFonteSugestao.padrao]);
      final atual = mbSugestaoLocal(_l('mb:2', descricao: 'UBER', categoria: 'Transporte', categoriaPk: 'transp'), padroes, _opcoes)!;
      expect([atual.categoriaPk, atual.fonte], ['transp', MbFonteSugestao.atual]);
      expect(mbSugestaoLocal(_l('mb:3', descricao: 'OUTRO'), padroes, _opcoes), isNull);
      // Padrão que aponta para categoria apagada não vira sugestão.
      expect(mbSugestaoLocal(_l('mb:4'), const [MbPadrao('FABIANA SILVA', 'sumiu')], _opcoes), isNull);
    });

    test('resposta da IA conferida no aparelho: pk inexistente, sub de outra categoria e receita em saída caem', () {
      final l = _l('mb:1');
      final ok = MbSugestao.daIa({
        'id': 'mb:1',
        'categoria': 'alim',
        'subcategoria': 'uber',
        'titulo': ' Empréstimo Mãe ',
        'vinculo': 'mae',
        'confianca': 0.4,
        'pergunta': 'Esse Pix de R\$ 500 para Fabiana foi empréstimo para a Mãe?',
      }, _opcoes, l)!;
      expect([ok.categoriaPk, ok.subPk, ok.titulo, ok.vinculoPk, ok.fonte], ['alim', null, 'Empréstimo Mãe', 'mae', MbFonteSugestao.ia]);
      expect(ok.pergunta, contains('Fabiana'));
      expect(MbSugestao.daIa({'id': 'mb:1', 'categoria': 'alim', 'confianca': 0.95, 'pergunta': 'x'}, _opcoes, l)!.pergunta, isNull);
      expect(MbSugestao.daIa({'id': 'mb:1', 'categoria': 'sumiu'}, _opcoes, l), isNull);
      expect(MbSugestao.daIa({'id': 'mb:1', 'categoria': 'sal'}, _opcoes, l), isNull);
      expect(MbSugestao.daIa({'id': 'outro', 'categoria': 'alim'}, _opcoes, l), isNull);
      expect(MbSugestao.daIa('lixo', _opcoes, l), isNull);
    });

    test('alternativas: atual, depois parecidas, depois mais usadas; do tipo certo, sem a sugerida nem ajuste', () {
      final uso = MbUso.de([
        for (var i = 0; i < 5; i++) (descricao: 'UBER TRIP', categoriaPk: 'mb:cat:d:Transporte'),
        for (var i = 0; i < 3; i++) (descricao: 'PADARIA PAO', categoriaPk: 'alim'),
        (descricao: 'Compra no débito - Studio Cabeleireiro Ana', categoriaPk: 'beleza'),
        for (var i = 0; i < 9; i++) (descricao: 'CDB - BANCO INTER', categoriaPk: '0'),
      ]);
      final cabeleireiro = _l('mb:1',
          descricao: 'Compra no débito - Mundo Do Cabeleireiro', categoria: 'Compras', categoriaPk: 'compras');
      // Beleza (descrição parecida) antes das mais usadas; Transporte soma o uso da repetida "mb:"; nunca o ajuste.
      expect(mbAlternativas(cabeleireiro, null, uso, _opcoes).map((c) => c.pk), ['beleza', 'transp', 'alim']);
      expect(mbAlternativas(cabeleireiro, 'beleza', uso, _opcoes, max: 1).map((c) => c.pk), ['transp']);
      // A atual útil vem primeiro; receita só para entrada.
      expect(mbAlternativas(_l('mb:2', categoriaPk: 'alim', categoria: 'Alimentação'), null, uso, _opcoes).first.pk,
          'alim');
      expect(mbAlternativas(_l('mb:3', valor: 100), null, uso, _opcoes).map((c) => c.pk), ['sal']);
      expect(mbAlternativas(_l('mb:4'), null, const MbUso(), _opcoes).map((c) => c.pk),
          ['alim', 'transp', 'beleza']); // sem uso: ordem das opções
    });

    test('exemplos: mesmo favorecido do lote primeiro', () {
      const padroes = [MbPadrao('UBER TRIP', 'transp'), MbPadrao('FABIANA SILVA', 'alim')];
      expect(mbExemplosPara([_l('mb:1')], padroes).map((p) => p.chave), ['FABIANA SILVA', 'UBER TRIP']);
    });
  });

  group('cartão', () {
    Future<void> abrir(WidgetTester t, List<MbLancamentoIa> fila,
        {Map<String, MbSugestao> sugestoes = const {},
        bool? iaOk,
        Map<String, MbEstadoIa> estado = const {},
        List<MbItemRevisao> revisar = const []}) async {
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'forceFullDarkBackground': false,
      };
      mbOpcoesClassificar = _opcoes;
      mbPadroesClassificar = const [];
      meuBancoRevisar.value = revisar;
      meuBancoClassificar.value = fila;
      meuBancoSugestoes.value = sugestoes;
      meuBancoIaOk.value = iaOk;
      meuBancoIaEstado.value = estado;
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
      meuBancoRevisar.value = const [];
      meuBancoClassificar.value = const [];
      meuBancoSugestoes.value = const {};
      meuBancoIaOk.value = null;
      meuBancoIaEstado.value = const {};
    });

    testWidgets('um por vez: estabelecimento, valor grande, "A IA sugere" em chip, Confirmar e as categorias prováveis',
        (t) async {
      await abrir(t, [
        _l('mb:1', descricao: 'Republic CA', valor: -48.9),
        _l('mb:2', descricao: 'Uber Trip', valor: -22),
      ], sugestoes: {
        'mb:1': const MbSugestao('mb:1', 'alim', confianca: 0.9, fonte: MbFonteSugestao.ia),
      });
      expect(find.text('Para validar'), findsOneWidget);
      expect(find.text('1 de 2'), findsOneWidget);
      expect(find.text('Republic CA'), findsOneWidget);
      expect(find.text('Uber Trip'), findsNothing); // só o primeiro
      expect(find.text('−R\$ 48,90'), findsOneWidget);
      expect(find.text('A IA sugere'), findsOneWidget);
      expect(find.text('GASTO · Alimentação'), findsOneWidget);
      expect(find.text('Confirmar'), findsOneWidget);
      expect(find.text('Não é isso? Toque na certa'), findsOneWidget);
      expect(find.text('Transporte'), findsOneWidget); // chip provável
      expect(find.text('Outras'), findsOneWidget);
      expect(find.text('Explicar o que foi'), findsNothing);
      expect(mbTotalPendencias(), 2);
    });

    testWidgets('pergunta da IA aparece junto da sugestão', (t) async {
      await abrir(t, [
        _l('mb:1')
      ], sugestoes: {
        'mb:1': const MbSugestao('mb:1', 'alim',
            confianca: 0.4,
            pergunta: 'Esse Pix de R\$ 500 para Fabiana foi almoço?',
            fonte: MbFonteSugestao.ia),
      });
      expect(find.textContaining('foi almoço?'), findsOneWidget);
      expect(find.text('Confirmar'), findsOneWidget);
    });

    testWidgets('sem sugestão e sem IA: só chips, sem Confirmar, e avisa discretamente', (t) async {
      await abrir(t, [_l('mb:1')], iaOk: false);
      expect(find.textContaining('Sem sugestão para este'), findsOneWidget);
      expect(find.text('Qual é a categoria?'), findsOneWidget);
      expect(find.text('Sem IA agora: sugestões pelos seus padrões.'), findsOneWidget);
      expect(find.text('Confirmar'), findsNothing);
      expect(find.text('Outras'), findsOneWidget);
    });

    testWidgets('estado da IA visível no cartão: pedindo, sem sugestão, falhou', (t) async {
      final atual = {
        'mb:1': const MbSugestao('mb:1', 'transp', confianca: 0.5, fonte: MbFonteSugestao.atual),
      };
      await abrir(t, [_l('mb:1', descricao: 'Compra no débito  -  Mundo Do Cabeleireiro')],
          sugestoes: atual, estado: {'mb:1': MbEstadoIa.pedindo});
      expect(find.text('Categoria do banco'), findsOneWidget);
      expect(find.text('Pedindo sugestão à IA…'), findsOneWidget);
      expect(find.text('Compra no débito - Mundo Do Cabeleireiro'), findsOneWidget);

      meuBancoIaEstado.value = {'mb:1': MbEstadoIa.semSugestao};
      await t.pump();
      expect(find.text('A IA não teve sugestão para este.'), findsOneWidget);

      meuBancoIaEstado.value = {'mb:1': MbEstadoIa.falhou};
      await t.pump();
      expect(find.text('Sem IA agora: sugestões pelos seus padrões.'), findsOneWidget);
    });

    testWidgets('Pix enviado do Worker na fila aparece uma vez só', (t) async {
      const pix = MbItemRevisao('p1', 'pix_enviado',
          txId: '1', data: '2026-11-10', descricao: 'PIX ENVIADO FABIANA', destinatario: 'FABIANA', valor: -500);
      await abrir(t, [_l('mb:1', revisao: pix)], revisar: const [pix]);
      expect(find.text('1 de 1'), findsOneWidget);
      expect(find.text('Para validar'), findsOneWidget);
      expect(mbTotalPendencias(), 1);
    });
  });
}
