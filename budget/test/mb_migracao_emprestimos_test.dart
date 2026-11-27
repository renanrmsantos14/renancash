// Migração dos empréstimos antigos: modelos da resposta do Worker e a tela de prévia (dados sintéticos).
import 'dart:convert';

import 'package:budget/pages/migracaoEmprestimosPage.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/migracaoEmprestimos.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _item(String o, String nome, {String status = 'pronto', int original = 10000, int pago = 0, int antigo = 10000, int novo = 10000, List<Map<String, dynamic>> dif = const [], Map<String, dynamic>? alt, List<String> motivos = const []}) => {
      'objetivo': o, 'nome': nome, 'pessoa': nome, 'status': status, 'motivos': motivos, 'avisos': [], 'lancamentos': 3,
      'originalCentavos': original, 'pagoCentavos': pago, 'saldoAntigoCentavos': antigo, 'saldoNovoCentavos': novo, 'diferencas': dif,
      if (alt != null) 'alternativa': alt,
    };

Map<String, dynamic> _previa(List<Map<String, dynamic>> itens, {String assinatura = 'abc', int antes = 0, int depois = 15000}) => {
      'assinatura': assinatura, 'itens': itens,
      'totais': {'antesCentavos': antes, 'depoisCentavos': depois, 'saldoAntigoCentavos': 12000, 'saldoNovoCentavos': 15000, 'diferencaCentavos': -3000, 'efeitosSobreOutros': []},
      'contagem': {},
    };

final _itens = [
  _item('o1', 'Ana', original: 10000, pago: 3000, antigo: 7000, novo: 10000, dif: [
    {'tx': 'l3', 'data': '2026-01-10', 'tipo': 'devolucao', 'centavos': -3000, 'motivo': 'Pago a mais: acima do saldo no dia'}
  ], alt: {'ajustar': true, 'saldoNovoCentavos': 7000, 'diferencaCentavos': 0}),
  _item('o2', 'Bia', original: 5000, antigo: 5000, novo: 5000),
  _item('o3', 'Caio', status: 'nao_mapeavel', motivos: ['Sem lançamentos ligados']),
  _item('o4', 'Dani', status: 'migrado', antigo: 2000, novo: 2000),
];

// utf-8 de verdade, como o Worker responde (o padrão do http.Response é latin1).
http.Response _json(String corpo, int status) => http.Response.bytes(utf8.encode(corpo), status, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('modelos: lê a prévia do Worker em centavos e separa por status', () {
    final p = MbMigPrevia.tentar(_previa(_itens, antes: 100, depois: 15100))!;
    expect([p.migraveis.length, p.migrados.length, p.naoMapeaveis.length], [2, 1, 1]);
    expect(p.itens.first.diferencaCentavos, -3000); // saldo antigo − novo = Σ diferenças
    expect(p.itens.first.ajusteRecomendado, isTrue); // o ajuste zera a diferença
    expect(p.itens[1].ajusteRecomendado, isFalse);
    expect([p.antesCentavos, p.depoisCentavos], [100, 15100]);
    expect(MbMigPrevia.tentar({'itens': 1}), isNull);
  });

  group('tela', () {
    late List<http.Request> pedidos;
    late MbCliente cliente;
    var respostaAplicar = (http.Request r) => _json(jsonEncode({'ok': true, 'aplicados': [{'objetivo': 'o2'}], 'antesCentavos': 0, 'depoisCentavos': 5000}), 200);

    setUp(() async {
      appStateSettings = {...await getDefaultPreferences(), 'outlinedIcons': true, 'locale': 'pt'};
      pedidos = [];
      respostaAplicar = (r) => _json(jsonEncode({'ok': true, 'aplicados': [{'objetivo': 'o2'}], 'antesCentavos': 0, 'depoisCentavos': 5000}), 200);
      cliente = MbCliente(
        base: 'https://x.test',
        token: 't',
        cliente: MockClient((r) async {
          pedidos.add(r);
          if (r.url.path.endsWith('/aplicar')) return respostaAplicar(r);
          if (r.url.path.endsWith('/desfazer')) return _json(jsonEncode({'ok': true, 'removidas': 2, 'antesCentavos': 2000, 'depoisCentavos': 0}), 200);
          final aj = r.url.queryParameters['ajustar']?.split(',') ?? [];
          return _json(jsonEncode(_previa([
            for (final i in _itens)
              if (i['objetivo'] == 'o1' && aj.contains('o1'))
                _item('o1', 'Ana', original: 10000, pago: 3000, antigo: 7000, novo: 7000, alt: {'ajustar': false, 'saldoNovoCentavos': 10000, 'diferencaCentavos': -3000})
              else
                i
          ])), 200);
        }),
      );
    });

    Future<void> abrir(WidgetTester t) async {
      t.view.physicalSize = const Size(900, 3200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: MigracaoEmprestimosPage(cliente: cliente)));
      await t.pumpAndSettle();
    }

    testWidgets('liga o ajuste onde ele aproxima o saldo e mostra os dois números', (t) async {
      await abrir(t);
      // 1ª chamada sem ajuste, 2ª já com o ajuste recomendado
      expect(pedidos.where((r) => r.method == 'GET').map((r) => r.url.queryParameters['ajustar']).toList(), [null, 'o1']);
      expect(t.widget<SwitchListTile>(find.byKey(const Key('ajustar_o1'))).value, isTrue);
      expect(find.textContaining('Sem ajuste: R\$ 100,00'), findsOneWidget);
      expect(find.byKey(const Key('item_o2')), findsOneWidget);
      expect(find.byKey(const Key('migrado_o4')), findsOneWidget);
    });

    testWidgets('migrar um: confirma, envia assinatura e ajuste, e recarrega a prévia', (t) async {
      await abrir(t);
      await t.tap(find.byKey(const Key('migrar_o2')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('confirmar_migracao')), findsOneWidget);
      expect(pedidos.where((r) => r.method == 'POST'), isEmpty); // nada grava antes da confirmação
      await t.tap(find.byKey(const Key('confirmar')));
      await t.pumpAndSettle();
      final post = pedidos.singleWhere((r) => r.method == 'POST');
      expect(post.url.path, '/api/emprestimos/migracao/aplicar');
      final corpo = jsonDecode(post.body) as Map;
      expect([corpo['objetivos'], corpo['assinatura'], corpo['ajustar']], [['o2'], 'abc', ['o1']]);
      expect(pedidos.last.method, 'GET'); // recarregou
    });

    testWidgets('em lote: seleciona todos e migra os selecionados', (t) async {
      await abrir(t);
      await t.tap(find.byKey(const Key('escolher_todos')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('migrar_selecionados')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirmar')));
      await t.pumpAndSettle();
      final corpo = jsonDecode(pedidos.singleWhere((r) => r.method == 'POST').body) as Map;
      expect(corpo['objetivos'], ['o1', 'o2']);
    });

    testWidgets('pessoa corrigida vai no corpo da aplicação', (t) async {
      await abrir(t);
      await t.tap(find.text('Bia'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('campo_pessoa')), 'Beatriz');
      await t.tap(find.text('Salvar'));
      await t.pumpAndSettle();
      expect(find.text('Beatriz'), findsOneWidget);
      await t.tap(find.byKey(const Key('migrar_o2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirmar')));
      await t.pumpAndSettle();
      expect((jsonDecode(pedidos.singleWhere((r) => r.method == 'POST').body) as Map)['pessoas'], {'o2': 'Beatriz'});
    });

    testWidgets('dados mudaram (409): mostra o erro e recarrega', (t) async {
      respostaAplicar = (r) => _json(jsonEncode({'erro': 'Os dados mudaram desde a prévia.'}), 409);
      await abrir(t);
      await t.tap(find.byKey(const Key('migrar_o2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirmar')));
      await t.pumpAndSettle();
      expect(find.textContaining('Os dados mudaram desde a prévia'), findsOneWidget);
      expect(pedidos.last.method, 'GET');
    });

    testWidgets('desfazer pede confirmação e chama o Worker', (t) async {
      await abrir(t);
      await t.tap(find.byKey(const Key('desfazer_o4')));
      await t.pumpAndSettle();
      expect(pedidos.where((r) => r.url.path.endsWith('/desfazer')), isEmpty);
      await t.tap(find.widgetWithText(FilledButton, 'Desfazer'));
      await t.pumpAndSettle();
      final post = pedidos.singleWhere((r) => r.url.path.endsWith('/desfazer'));
      expect(jsonDecode(post.body), {'objetivo': 'o4'});
    });

    testWidgets('lista o que não migra, com o motivo', (t) async {
      await abrir(t);
      await t.tap(find.byKey(const Key('nao_mapeados')));
      await t.pumpAndSettle();
      expect(find.text('Sem lançamentos ligados'), findsOneWidget);
    });
  });
}
