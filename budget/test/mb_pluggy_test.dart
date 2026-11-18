import 'package:budget/pages/meuBancoConectar.dart';
import 'package:budget/struct/mbSync/pluggy.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = '0b3e2f4a-1c2d-4e5f-8a9b-0c1d2e3f4a5b';
  test('aceita os três formatos', () {
    expect(mbItemIdDoSucesso({'item': {'id': id}}), id);
    expect(mbItemIdDoSucesso({'itemId': id}), id);
    expect(mbItemIdDoSucesso({'data': {'item': {'id': id}}}), id);
  });
  test('recusa inválido e null', () {
    expect(mbItemIdDoSucesso({'item': {'id': 'abc'}}), isNull);
    expect(mbItemIdDoSucesso({'itemId': 123}), isNull);
    expect(mbItemIdDoSucesso('texto'), isNull);
    expect(mbItemIdDoSucesso(null), isNull);
  });
  test('cai para o próximo formato quando o primeiro é inválido', () {
    expect(mbItemIdDoSucesso({'item': {'id': 'x'}, 'itemId': id}), id);
  });

  testWidgets('MeuBancoConectarPage mostra barra Editorial e estado de erro',
      (t) async {
    appStateSettings = {
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'appAnimations': 0,
    };
    await t.pumpWidget(MaterialApp(
      theme: temaFlutter(temaPorId('padrao-claro')),
      home: MeuBancoConectarPage(
        connectToken: 'tok',
        itemId: id,
        erroInicial: 'Falha ao carregar WebView',
        onSuccess: (_) {},
        onError: (_) {},
        webViewParaTeste: const Text('WebView ok'),
      ),
    ));
    await t.pump();
    expect(find.text('Reconectar banco'), findsOneWidget);
    expect(find.byTooltip('Voltar'), findsOneWidget);
    expect(find.text('Não foi possível conectar o banco'), findsOneWidget);
    expect(find.text('Falha ao carregar WebView'), findsOneWidget);

    await t.tap(find.text('Tentar de novo'));
    await t.pump();
    expect(find.text('WebView ok'), findsOneWidget);
  });
}
