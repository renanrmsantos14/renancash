import 'package:budget/struct/mbSync/avisos.dart';
import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/ajustesInicio.dart' show mbAjustesMudaram;
import 'package:budget/widgets/editorial/seloPendencias.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MbItemRevisao _pix(String id, String quem) => MbItemRevisao(id, 'pix_recebido',
    txId: 'tx$id', data: '2026-11-05', descricao: 'PIX RECEBIDO $quem', valor: 120);

const _itemA = 'Pix recebido';

Future<void> _abrir(WidgetTester t,
    {List<MbItemRevisao> itens = const [],
    List<Map<String, dynamic>> avisos = const [],
    Map<String, dynamic> ajustes = const {}}) async {
  appStateSettings = {
    'materialYou': false,
    'accentSystemColor': false,
    'batterySaver': false,
    'increaseTextContrast': false,
    'forceFullDarkBackground': false,
    ...ajustes,
  };
  meuBancoRevisar.value = itens;
  meuBancoAvisos.value = avisos;
  await t.pumpWidget(MaterialApp(
    theme: temaEditorial(Brightness.light),
    home: const Scaffold(body: PendenciasPage(atualizar: false)),
  ));
  await t.pump();
}

/// Qual item está no cartão: o descritivo não aparece, então usa o txId pela chave do cartão.
bool _noCartao(WidgetTester t, String id) =>
    find.byKey(ValueKey(id)).evaluate().isNotEmpty;

void main() {
  tearDown(() {
    meuBancoRevisar.value = const [];
    meuBancoAvisos.value = const [];
  });

  testWidgets('sem nada: Tudo em dia e total zero', (t) async {
    await _abrir(t);
    expect(find.text('Tudo em dia'), findsOneWidget);
    expect(mbTotalPendencias(), 0);
  });

  testWidgets('carregando: mostra indicador e não pisca Tudo em dia', (t) async {
    appStateSettings = {
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'forceFullDarkBackground': false,
    };
    await t.pumpWidget(MaterialApp(
      theme: temaEditorial(Brightness.light),
      home: const Scaffold(body: PendenciasPage(atualizar: false, carregando: true)),
    ));
    await t.pump();
    expect(find.text('Carregando pendências…'), findsOneWidget);
    expect(find.text('Tudo em dia'), findsNothing);
  });

  testWidgets('Pix recebido mostra o nome do pagador e alvos >= 44 px', (t) async {
    await _abrir(t, itens: [
      _pix('a', 'MARIA SILVA'),
      _pix('b', 'JOAO COSTA'),
    ]);
    expect(find.text('Pix recebido de Maria Silva'), findsOneWidget);
    // TextButton.icon é subclasse de TextButton; widgetWithText compara o tipo exato.
    final pular = find.ancestor(
        of: find.text('Pular'), matching: find.byWidgetPredicate((w) => w is TextButton));
    expect(t.getSize(pular.first).height, greaterThanOrEqualTo(44));
    expect(t.getSize(find.text('Reembolso')).height, greaterThan(0));
  });

  testWidgets('total soma itens e bancos desconectados', (t) async {
    await _abrir(t, itens: [_pix('a', 'X'), _pix('b', 'Y')], avisos: [
      {'banco': 'Inter', 'item_id': 'i1'}
    ]);
    expect(mbTotalPendencias(), 3);
    expect(find.text('Inter desconectado'), findsOneWidget);
    expect(find.text('Reconectar'), findsOneWidget);
    expect(find.text('Tudo em dia'), findsNothing);
  });

  testWidgets('só banco desconectado: faixa e "Nada na fila"', (t) async {
    await _abrir(t, avisos: [
      {'banco': 'Inter'}
    ]);
    expect(find.text('Nada na fila.'), findsOneWidget);
  });

  test('ordem com pulados: posição real avança a cada Pular e volta a 1 na segunda volta', () {
    const itens = ['a', 'b', 'c'];
    final pulados = <String>[];
    int posicao() => itens.indexOf(ordenarPulados(itens, pulados, (i) => i).first) + 1;
    int pularEVer() {
      final atual = ordenarPulados(itens, pulados, (i) => i).first;
      pulados
        ..remove(atual)
        ..add(atual);
      return posicao();
    }

    expect(posicao(), 1);
    final vistas = [for (var i = 0; i < 5; i++) pularEVer()];
    expect(vistas, [2, 3, 1, 2, 3]);
    expect(ordenarPulados(itens, ['b', 'sumiu'], (i) => i), ['a', 'c', 'b']);
  });

  testWidgets('um item por vez; Pular manda para o fim da fila e o contador avança', (t) async {
    await _abrir(t, itens: [_pix('a', 'X'), _pix('b', 'Y')]);
    expect(find.text('1 de 2'), findsOneWidget);
    expect(find.text(_itemA), findsOneWidget);
    expect(_noCartao(t, 'a'), true);
    await t.tap(find.text('Pular'));
    await t.pumpAndSettle();
    expect(_noCartao(t, 'b'), true);
    expect(find.text('2 de 2'), findsOneWidget);
    await t.tap(find.text('Pular'));
    await t.pumpAndSettle();
    expect(_noCartao(t, 'a'), true);
    expect(find.text('1 de 2'), findsOneWidget);
  });

  testWidgets('item único não tem Pular', (t) async {
    await _abrir(t, itens: [_pix('a', 'X')]);
    expect(find.text('Pular'), findsNothing);
  });

  testWidgets('deslizar curto e rápido para a esquerda pula', (t) async {
    await _abrir(t, itens: [_pix('a', 'X'), _pix('b', 'Y')]);
    final g = await t.startGesture(t.getTopLeft(find.byKey(const ValueKey('a'))) + const Offset(40, 24));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(-15, 0), timeStamp: Duration(milliseconds: 10 * (i + 1)));
    }
    await g.up(timeStamp: const Duration(milliseconds: 50));
    await t.pumpAndSettle();
    expect(_noCartao(t, 'b'), true);
  });

  testWidgets('deslizar curto e lento volta para o lugar', (t) async {
    await _abrir(t, itens: [_pix('a', 'X'), _pix('b', 'Y')]);
    final g = await t.startGesture(t.getTopLeft(find.byKey(const ValueKey('a'))) + const Offset(40, 24));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(-10, 0), timeStamp: Duration(milliseconds: 200 * (i + 1)));
    }
    await g.up(timeStamp: const Duration(milliseconds: 1000));
    await t.pumpAndSettle();
    expect(_noCartao(t, 'a'), true);
  });

  testWidgets('segundo dedo durante o arraste é ignorado', (t) async {
    await _abrir(t, itens: [_pix('a', 'X'), _pix('b', 'Y')]);
    // Começa no título (fora dos botões) para o dedo que só encosta não virar toque numa resposta.
    final centro = t.getTopLeft(find.byKey(const ValueKey('a'))) + const Offset(40, 24);
    final g1 = await t.startGesture(centro, pointer: 1);
    await g1.moveBy(const Offset(-10, 0), timeStamp: const Duration(milliseconds: 500));
    final g2 = await t.startGesture(centro + const Offset(0, 10), pointer: 2);
    await g2.moveBy(const Offset(-300, 0), timeStamp: const Duration(milliseconds: 520));
    await g2.up(timeStamp: const Duration(milliseconds: 530));
    await t.pump();
    expect(_noCartao(t, 'a'), true);
    await g1.up(timeStamp: const Duration(milliseconds: 1500));
    await t.pumpAndSettle();
    expect(_noCartao(t, 'a'), true);
  });

  group('Configurações › Pendências', () {
    testWidgets('bancos desconectados desligado: sem faixa e fora do total', (t) async {
      await _abrir(t,
          itens: [_pix('a', 'X')],
          avisos: [
            {'banco': 'Inter'}
          ],
          ajustes: {'pendenciasBancos': false});
      expect(find.text('Inter desconectado'), findsNothing);
      expect(mbTotalPendencias(), 1);
    });

    testWidgets('deslizar desligado: o gesto não pula, o botão sim', (t) async {
      await _abrir(t,
          itens: [_pix('a', 'X'), _pix('b', 'Y')],
          ajustes: {'pendenciasDeslizar': false});
      final g = await t.startGesture(
          t.getTopLeft(find.byKey(const ValueKey('a'))) + const Offset(40, 24));
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(-15, 0),
            timeStamp: Duration(milliseconds: 10 * (i + 1)));
      }
      await g.up(timeStamp: const Duration(milliseconds: 50));
      await t.pumpAndSettle();
      expect(_noCartao(t, 'a'), true);
      await t.tap(find.text('Pular'));
      await t.pumpAndSettle();
      expect(_noCartao(t, 'b'), true);
    });

    testWidgets('selo desligado: sem bolinha mesmo com pendências', (t) async {
      await _abrir(t, itens: [_pix('a', 'X')]);
      await t.pumpWidget(MaterialApp(
          theme: temaEditorial(Brightness.light),
          home: const Scaffold(
              body: Center(child: SeloPendencias(child: Icon(Icons.inbox))))));
      expect(find.text('1'), findsOneWidget);
      // Mudou nas configurações: o selo some sem reabrir a tela.
      appStateSettings['pendenciasSelo'] = false;
      mbAjustesMudaram.value++;
      await t.pump();
      expect(find.text('1'), findsNothing);
      appStateSettings['pendenciasSelo'] = true;
      mbAjustesMudaram.value++;
      await t.pump();
      expect(find.text('1'), findsOneWidget);
    });
  });
}
