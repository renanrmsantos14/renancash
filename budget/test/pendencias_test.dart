import 'package:budget/struct/mbSync/avisos.dart';
import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/settings.dart';
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

  testWidgets('um item por vez; Pular manda para o fim da fila', (t) async {
    await _abrir(t, itens: [_pix('a', 'X'), _pix('b', 'Y')]);
    expect(find.text('1 de 2'), findsOneWidget);
    expect(find.text(_itemA), findsOneWidget);
    expect(_noCartao(t, 'a'), true);
    await t.tap(find.text('Pular'));
    await t.pumpAndSettle();
    expect(_noCartao(t, 'b'), true);
    await t.tap(find.text('Pular'));
    await t.pumpAndSettle();
    expect(_noCartao(t, 'a'), true);
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
      appStateSettings['pendenciasSelo'] = false;
      await t.pumpWidget(MaterialApp(
          theme: temaEditorial(Brightness.light),
          home: const Scaffold(
              body: Center(child: SeloPendencias(child: Icon(Icons.inbox))))));
      expect(find.text('1'), findsNothing);
      appStateSettings['pendenciasSelo'] = true;
      await t.pumpWidget(MaterialApp(
          theme: temaEditorial(Brightness.light),
          home: const Scaffold(
              body: Center(child: SeloPendencias(child: Icon(Icons.inbox))))));
      expect(find.text('1'), findsOneWidget);
    });
  });
}
