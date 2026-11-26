import 'dart:convert';

import 'package:budget/pages/feitoPelaIaPage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/iaAplicadas.dart';
import 'package:budget/struct/mbSync/notificacoes.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart' show snackbarKey;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _item(String id, String status, {String origem = 'memoria', bool antes = true}) => {
      'tx_id': id,
      'origem': origem,
      'status': status,
      'antes': antes ? {'name': 'PIX MERCADO X', 'category_fk': null, 'sub_category_fk': null} : null,
      'depois': {'name': 'Mercado X', 'category_fk': 'c1', 'sub_category_fk': 's1'},
      'criado_em': '2026-11-25T12:00:00Z',
      'aplicado_em': '2026-11-25T12:00:05Z',
    };

MbCliente _cliente(Future<http.Response> Function(http.Request) f) =>
    MbCliente(base: 'https://x.test', token: 't', cliente: MockClient(f));

Future<void> _monta(WidgetTester t, MbCliente c) async {
  appStateSettings = {
    ...await getDefaultPreferences(),
    'materialYou': false,
    'accentSystemColor': false,
    'batterySaver': false,
    'increaseTextContrast': false,
    'forceFullDarkBackground': false,
    'locale': 'pt',
  };
  await t.pumpWidget(MaterialApp(
    theme: temaFlutter(temaPorId('padrao-claro')),
    home: Stack(children: [
      FeitoPelaIaPage(clienteParaTeste: c, nomesParaTeste: const {'c1': 'Mercado', 's1': 'Compras'}),
      GlobalSnackbar(key: snackbarKey),
    ]),
  ));
  await t.pumpAndSettle();
}

void main() {
  test('lê a resposta do Worker e ignora item malformado', () {
    final l = MbIaAplicada.lista({
      'itens': [_item('a', 'aplicada'), _item('b', 'desfeita', antes: false), {'tx_id': 1}, 'x']
    });
    expect(l.map((i) => i.txId), ['a', 'b']);
    expect(l[0].pk, 'mb:a');
    expect(l[0].antes?.nome, 'PIX MERCADO X');
    expect(l[1].antes, isNull);
    expect(l[1].desfeita, isTrue);
    expect(l[0].rotuloOrigem, 'Memória');
  });

  test('cliente chama os três endpoints com o contrato combinado', () async {
    final reqs = <http.Request>[];
    final c = _cliente((r) async {
      reqs.add(r);
      return http.Response('{"ok":true,"itens":[]}', 200);
    });
    await c.iaAplicadas();
    await c.iaAplicadas(desde: '2026-11-01T00:00:00Z');
    await c.iaDesfazer('t1');
    await c.iaMemoria([{'chave': 'k'}]);
    expect(reqs[0].url.toString(), 'https://x.test/api/ia/aplicadas');
    expect(reqs[1].url.queryParameters['desde'], '2026-11-01T00:00:00Z');
    expect([reqs[2].method, reqs[2].url.path, jsonDecode(reqs[2].body)], ['POST', '/api/ia/desfazer', {'tx_id': 't1'}]);
    expect([reqs[3].url.path, jsonDecode(reqs[3].body)], [
      '/api/ia/memoria',
      {'padroes': [{'chave': 'k'}]}
    ]);
    expect(reqs[2].headers['Authorization'], 'Bearer t');
  });

  test('payload de notificação com chave ia: abre Feito pela IA; outras não', () {
    expect(mbPayloadEhIa(mbPayloadAlerta({'chave': 'ia:lote:1', 'item': {'tipo': 'ia_aplicadas', 'desde': 'lote:1'}})), isTrue);
    expect(mbPayloadEhIa(mbPayloadAlerta({'chave': 'emp:1'})), isFalse);
    expect(mbPayloadEhIa('addTransaction'), isFalse);
    expect(mbPayloadEhIa(null), isFalse);
  });

  group('tela', () {
    testWidgets('lista, desfaz e marca como desfeita', (t) async {
      final reqs = <String>[];
      await _monta(t, _cliente((r) async {
        reqs.add('${r.method} ${r.url.path}');
        if (r.url.path == '/api/ia/aplicadas') {
          return http.Response(jsonEncode({'itens': [_item('a', 'aplicada'), _item('b', 'desfeita')]}), 200);
        }
        return http.Response('{"ok":true}', 200);
      }));
      expect(find.text('Mercado X'), findsNWidgets(2));
      expect(find.text('PIX MERCADO X'), findsNWidgets(2));
      expect(find.text('Desfazer'), findsOneWidget); // a desfeita não tem o botão
      expect(find.text('Corrigir'), findsNWidgets(2));
      await t.tap(find.text('Desfazer'));
      await t.pumpAndSettle();
      expect(reqs, contains('POST /api/ia/desfazer'));
      expect(find.text('Desfazer'), findsNothing);
      await t.pump(const Duration(seconds: 10)); // fecha o aviso
      await t.pumpAndSettle(const Duration(seconds: 1));
    });

    testWidgets('vazio', (t) async {
      await _monta(t, _cliente((r) async => http.Response('{"itens":[]}', 200)));
      expect(find.text('Nada classificado pela IA nos últimos 14 dias.'), findsOneWidget);
    });

    testWidgets('erro com tentar de novo e depois sucesso', (t) async {
      var n = 0;
      await _monta(t, _cliente((r) async {
        n++;
        return n == 1 ? http.Response('{}', 500) : http.Response(jsonEncode({'itens': [_item('a', 'aplicada')]}), 200);
      }));
      expect(find.text('Tentar de novo'), findsOneWidget);
      await t.tap(find.text('Tentar de novo'));
      await t.pumpAndSettle();
      expect(find.text('Mercado X'), findsOneWidget);
    });

    testWidgets('offline', (t) async {
      await _monta(t, _cliente((r) async => throw http.ClientException('sem rede')));
      expect(find.text('Sem conexão com o Meu Banco.'), findsOneWidget);
      expect(find.text('Tentar de novo'), findsOneWidget);
    });
  });
}
