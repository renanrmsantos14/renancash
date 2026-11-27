import 'dart:convert';

import 'package:budget/pages/saudePage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/notificacoes.dart';
import 'package:budget/struct/mbSync/saude.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _item(String id, String nome, String status, String resumo, {String? acao, List<Map<String, dynamic>> det = const []}) =>
    {'id': id, 'nome': nome, 'status': status, 'resumo': resumo, 'acao': acao, 'detalhes': det};

Map<String, dynamic> _saude({String status = 'ok', bool atrasado = false, List<Map<String, dynamic>>? itens}) => {
      'verificado_em': '2026-11-27T11:00:05Z',
      'status': status,
      'atrasado': atrasado,
      'itens': itens ??
          [
            _item('pluggy', 'Bancos (Pluggy)', 'ok', 'Tudo em dia'),
            _item('ia', 'Inteligência artificial', 'ok', 'O modelo responde'),
            _item('espelho', 'Espelho', 'ok', 'Espelho em dia'),
            _item('cron', 'Cron e check diário', 'ok', 'Rodando'),
          ],
    };

final _comProblema = _saude(status: 'erro', itens: [
  _item('pluggy', 'Bancos (Pluggy)', 'ok', 'Tudo em dia'),
  _item('ia', 'Inteligência artificial', 'erro', 'O modelo da IA não responde',
      acao: 'Confira a constante MODELO em ia.js contra o catálogo do Workers AI e publique de novo.',
      det: [
        {'nome': 'Modelo', 'status': 'erro', 'texto': 'O modelo da IA não responde (model not found)'}
      ]),
]);

MbCliente _cliente(Future<http.Response> Function(http.Request) f) =>
    MbCliente(base: 'https://x.test', token: 't', cliente: MockClient(f));

http.Response _json(Object o, [int status = 200]) =>
    http.Response(jsonEncode(o), status, headers: {'content-type': 'application/json; charset=utf-8'});

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
    home: SaudePage(clienteParaTeste: c, agoraParaTeste: DateTime.utc(2026, 11, 27, 11, 30, 5)),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => meuBancoSaudeAviso.value = null);

  group('modelo', () {
    test('lê a resposta do Worker e ignora item malformado', () {
      final s = MbSaude.deJson({
        ..._comProblema,
        'itens': [..._comProblema['itens'] as List, 'lixo', {'id': 1}]
      });
      expect(s.status, MbSaudeStatus.erro);
      expect(s.itens.map((i) => i.id), ['pluggy', 'ia']);
      expect(s.itens[1].acao, startsWith('Confira a constante MODELO'));
      expect(s.itens[1].detalhes.single.status, MbSaudeStatus.erro);
      expect(s.comProblema, isTrue);
      expect(mbSaudeResumoAviso(s), 'O modelo da IA não responde');
    });

    test('nunca rodou: sem resultado e sem problema', () {
      final s = MbSaude.deJson({'verificado_em': null, 'status': 'desconhecido', 'itens': [], 'atrasado': false});
      expect(s.semResultado, isTrue);
      expect(s.status, MbSaudeStatus.desconhecido);
    });

    test('atrasado conta como problema mesmo com tudo ok', () {
      final s = MbSaude.deJson(_saude(atrasado: true));
      expect(s.comProblema, isTrue);
      expect(mbSaudeResumoAviso(s), 'O check diário atrasou');
    });
  });

  group('aviso da Início', () {
    test('problema acende o aviso e voltar ao normal apaga', () async {
      var corpo = _comProblema;
      final c = _cliente((r) async => _json(corpo));
      await mbChecarSaude(clienteParaTeste: c);
      expect(meuBancoSaudeAviso.value?.status, MbSaudeStatus.erro);
      corpo = _saude();
      await mbChecarSaude(clienteParaTeste: c);
      expect(meuBancoSaudeAviso.value, isNull);
    });

    test('check atrasado acende o aviso', () async {
      await mbChecarSaude(clienteParaTeste: _cliente((r) async => _json(_saude(atrasado: true))));
      expect(meuBancoSaudeAviso.value?.atrasado, isTrue);
    });

    test('Worker novo sem resultado não avisa', () async {
      await mbChecarSaude(
          clienteParaTeste: _cliente((r) async =>
              _json({'verificado_em': null, 'status': 'desconhecido', 'itens': [], 'atrasado': false})));
      expect(meuBancoSaudeAviso.value, isNull);
    });

    test('offline e Worker antigo (405) não lançam nem avisam', () async {
      expect(await mbChecarSaude(clienteParaTeste: _cliente((r) async => throw http.ClientException('x'))), isNull);
      expect(await mbChecarSaude(clienteParaTeste: _cliente((r) async => _json({}, 405))), isNull);
      expect(meuBancoSaudeAviso.value, isNull);
    });
  });

  test('toque no push de saúde: payload com item.tipo saude', () {
    final p = mbPayloadAlerta({'chave': 'saude:2026-11-27:x', 'item': {'tipo': 'saude'}});
    expect(mbPayloadEhSaude(p), isTrue);
    expect(mbPayloadEhSaude(mbPayloadAlerta({'chave': 'a', 'item': {'tipo': 'ia_aplicadas'}})), isFalse);
    expect(mbPayloadEhSaude(null), isFalse);
  });

  group('tela Saúde', () {
    testWidgets('tudo certo: resumo e os quatro itens', (t) async {
      await _monta(t, _cliente((r) async => _json(_saude())));
      expect(find.text('Tudo certo'), findsWidgets);
      expect(find.text('Bancos (Pluggy)'), findsOneWidget);
      expect(find.text('Cron e check diário'), findsOneWidget);
      expect(find.text('Verificado há 30 min'), findsOneWidget);
      expect(find.textContaining('O que fazer'), findsNothing);
    });

    testWidgets('problema: mostra o detalhe e o que fazer', (t) async {
      await _monta(t, _cliente((r) async => _json(_comProblema)));
      expect(find.text('Com problema'), findsWidgets);
      expect(find.textContaining('model not found'), findsOneWidget);
      expect(find.textContaining('O que fazer: Confira a constante MODELO'), findsOneWidget);
    });

    testWidgets('Verificar agora chama o POST e atualiza', (t) async {
      final chamadas = <String>[];
      await _monta(t, _cliente((r) async {
        chamadas.add('${r.method} ${r.url.path}');
        return _json(r.method == 'POST' ? _saude() : _comProblema);
      }));
      expect(find.text('Com problema'), findsWidgets);
      await t.tap(find.text('Verificar agora'));
      await t.pumpAndSettle();
      expect(chamadas, ['GET /api/saude', 'POST /api/saude/verificar']);
      expect(find.text('Tudo certo'), findsWidgets);
      expect(meuBancoSaudeAviso.value, isNull);
    });

    testWidgets('offline e erro oferecem tentar de novo', (t) async {
      var cai = true;
      await _monta(t, _cliente((r) async {
        if (cai) throw http.ClientException('sem rede');
        return _json(_saude());
      }));
      expect(find.text('Sem conexão com o Meu Banco.'), findsOneWidget);
      cai = false;
      await t.tap(find.text('Tentar de novo'));
      await t.pumpAndSettle();
      expect(find.text('Tudo certo'), findsWidgets);
    });

    testWidgets('Worker sem a rota mostra mensagem clara', (t) async {
      await _monta(t, _cliente((r) async => _json({}, 405)));
      expect(find.textContaining('ainda não tem esse recurso'), findsOneWidget);
    });
  });
}
