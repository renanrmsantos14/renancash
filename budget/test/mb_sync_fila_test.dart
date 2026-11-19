// Sincronização do Meu Banco: chamadas simultâneas coalescem em uma rodada extra (ROB-01).
import 'dart:async';
import 'dart:ffi';

import 'package:budget/database/tables.dart' show FinanceDatabase;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

String _hoje() => DateTime.now().toIso8601String().substring(0, 10);

class _Cliente extends MbCliente {
  _Cliente() : super(base: 'https://teste');
  List<Map<String, dynamic>> transacoes = [];
  int pulls = 0, pullsCompletos = 0;
  // Segura o primeiro pull até o teste liberar (simula um sync demorado).
  Completer<void>? portao;
  // Falha só nos pulls em que isto devolve true (número do pull, começando em 1).
  bool Function(int pull)? falhaEm;

  @override
  Future<Map<String, dynamic>> puxar(String? desde) async {
    final n = ++pulls;
    if (desde == null) pullsCompletos++;
    final p = portao;
    if (p != null && n == 1) await p.future;
    if (falhaEm?.call(n) ?? false) throw MbErroHttp(500, 'falha de teste');
    return {
      'agora': DateTime.now().toUtc().toIso8601String(),
      'contas': [{'id': 'cc', 'type': 'BANK', 'name': 'Conta Inter'}],
      // Como o Worker: o incremental não repete transações antigas.
      'transacoes': desde == null ? transacoes : [],
      'pendentes': [],
      'ciclo': {'inicio': _hoje()},
    };
  }
}

void main() {
  late _Cliente cliente;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    database = FinanceDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({'mbNotifCursor': 'x'});
    cliente = _Cliente();
    meuBancoSincronizando.value = false;
  });

  tearDown(() => database.close());

  Future<void> esperarPull(int n) async {
    while (cliente.pulls < n) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('fila de sincronização (ROB-01)', () {
    test('duas chamadas simultâneas resultam em exatamente duas rodadas', () async {
      cliente.portao = Completer<void>();
      final a = sincronizarMeuBanco(clienteParaTeste: cliente);
      await esperarPull(1);
      expect(meuBancoSincronizando.value, true);
      final b = sincronizarMeuBanco(clienteParaTeste: cliente);
      cliente.portao!.complete();

      expect(await a, true, reason: meuBancoUltimoErro.value);
      expect(await b, true, reason: meuBancoUltimoErro.value);
      expect(cliente.pulls, 2);
      expect(meuBancoSincronizando.value, false);
    });

    test('três chamadas durante um sync resultam em uma rodada extra só', () async {
      cliente.portao = Completer<void>();
      final a = sincronizarMeuBanco(clienteParaTeste: cliente);
      await esperarPull(1);
      final b = sincronizarMeuBanco(clienteParaTeste: cliente);
      final c = sincronizarMeuBanco(clienteParaTeste: cliente);
      final d = sincronizarMeuBanco(clienteParaTeste: cliente);
      cliente.portao!.complete();

      expect(await Future.wait([a, b, c, d]), [true, true, true, true]);
      expect(cliente.pulls, 2);
      expect(meuBancoSincronizando.value, false);
    });

    test('a flag fica ligada entre a rodada e a extra', () async {
      cliente.portao = Completer<void>();
      final estados = <bool>[];
      void ouvir() => estados.add(meuBancoSincronizando.value);
      meuBancoSincronizando.addListener(ouvir);
      addTearDown(() => meuBancoSincronizando.removeListener(ouvir));

      final a = sincronizarMeuBanco(clienteParaTeste: cliente);
      await esperarPull(1);
      final b = sincronizarMeuBanco(clienteParaTeste: cliente);
      cliente.portao!.complete();
      await Future.wait([a, b]);
      expect(estados, [true, false]); // ligou uma vez e desligou uma vez
    });

    test('sem chamada durante o sync não há rodada extra, e uma nova chamada depois roda normalmente', () async {
      expect(await sincronizarMeuBanco(clienteParaTeste: cliente), true);
      expect(cliente.pulls, 1);
      expect(await sincronizarMeuBanco(clienteParaTeste: cliente), true);
      expect(cliente.pulls, 2);
    });

    test('erro numa rodada não trava a flag nem a próxima', () async {
      cliente.falhaEm = (n) => n == 1;
      expect(await sincronizarMeuBanco(clienteParaTeste: cliente), false);
      expect(meuBancoSincronizando.value, false);
      expect(meuBancoUltimoErro.value, isNotNull);

      expect(await sincronizarMeuBanco(clienteParaTeste: cliente), true);
      expect(meuBancoUltimoErro.value, isNull);
    });

    test('erro na primeira rodada não perde a rodada extra', () async {
      cliente.portao = Completer<void>();
      cliente.falhaEm = (n) => n == 1;
      final a = sincronizarMeuBanco(clienteParaTeste: cliente);
      await esperarPull(1);
      final b = sincronizarMeuBanco(clienteParaTeste: cliente);
      cliente.portao!.complete();

      expect(await a, false);
      expect(await b, true, reason: meuBancoUltimoErro.value);
      expect(cliente.pulls, 2);
      expect(meuBancoSincronizando.value, false);
    });
  });
}
