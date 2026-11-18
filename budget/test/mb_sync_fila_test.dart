// Sincronização do Meu Banco: chamadas simultâneas coalescem em uma rodada extra (ROB-01) e ajustes remotos ou
// locais de categoria / "não é gasto" chegam às transações antigas no pull incremental (ROB-02).
import 'dart:async';
import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

String _hoje() => DateTime.now().toIso8601String().substring(0, 10);

Map<String, dynamic> _tx(String id, String desc, double valor, {String? categoria}) => {
      'id': id, 'account_id': 'cc', 'date': _hoje(), 'description': desc,
      'amount': valor, 'status': 'POSTED', 'category': categoria, 'scheduled': 0,
    };

String _futuro() =>
    DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String();

class _Cliente extends MbCliente {
  _Cliente() : super(base: 'https://teste');
  final List<Registro> servidor = [];
  final List<Registro> enviados = [];
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
      'registros': [for (final r in servidor) r.toJson()],
      'contas': [{'id': 'cc', 'type': 'BANK', 'name': 'Conta Inter'}],
      // Como o Worker: o incremental não repete transações antigas.
      'transacoes': desde == null ? transacoes : [],
      'pendentes': [],
      'ciclo': {'inicio': _hoje()},
    };
  }

  @override
  Future<({int aceitos, List<({int indice, String motivo})> rejeitados})> enviar(
      List<Registro> lote) async {
    enviados.addAll(lote);
    return (aceitos: lote.length, rejeitados: <({int indice, String motivo})>[]);
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

  group('ajustes no pull incremental (ROB-02)', () {
    Future<void> sync() async =>
        expect(await sincronizarMeuBanco(clienteParaTeste: cliente), true, reason: meuBancoUltimoErro.value);

    Future<Transaction> tx(String pk) =>
        (database.select(database.transactions)..where((t) => t.transactionPk.equals(pk))).getSingle();

    Future<List<Transaction>> todas(String pk) =>
        (database.select(database.transactions)..where((t) => t.transactionPk.equals(pk))).get();

    Future<void> categoriaLocal(String pk, String nome) =>
        database.into(database.categories).insert(CategoriesCompanion.insert(
            categoryPk: Value(pk), name: nome, order: 0, dateTimeModified: Value(DateTime.now())));

    test('ajuste remoto de categoria numa transação antiga é aplicado', () async {
      cliente.transacoes = [_tx('g1', 'RESTAURANTE', -60, categoria: 'Eating out')];
      await sync(); // carga completa; as seguintes são incrementais
      await categoriaLocal('lazer', 'Lazer');
      final antes = (await tx('mb:g1')).categoryFk;
      expect(antes, isNot('lazer'));

      cliente.servidor.add(Registro('ajustes', 'g1',
          {'categoria_id': 'cashew:lazer', 'category': 'Lazer'}, _futuro(), null));
      cliente.pullsCompletos = 0;
      await sync();

      expect((await tx('mb:g1')).categoryFk, 'lazer');
      expect(cliente.pullsCompletos, 1);
      // A categoria que veio do outro aparelho não volta ao servidor como se fosse edição local.
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes' && r.id == 'g1'), isEmpty);
    });

    test('ajuste remoto "não é gasto" tira a transação antiga e não volta ao servidor', () async {
      cliente.transacoes = [_tx('g1', 'RESTAURANTE', -60, categoria: 'Eating out')];
      await sync();
      expect(await todas('mb:g1'), hasLength(1));

      cliente.servidor.add(Registro('ajustes', 'g1', {'gasto': 0}, _futuro(), null));
      cliente.enviados.clear();
      await sync();
      expect(await todas('mb:g1'), isEmpty);

      await sync(); // a rodada seguinte não recria nem reenvia nada
      expect(await todas('mb:g1'), isEmpty);
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes' && r.id == 'g1'), isEmpty);
    });

    test('ajuste remoto só de orçamentos não força pull completo', () async {
      cliente.transacoes = [_tx('g1', 'RESTAURANTE', -60, categoria: 'Eating out')];
      await sync();
      cliente.servidor.add(Registro('ajustes', 'g1', {'orcamento_ids': <String>[]}, _futuro(), null));
      cliente.pullsCompletos = 0;
      await sync();
      expect(cliente.pullsCompletos, 0);
    });

    test('gasto rachado muda de categoria em outro aparelho e o reembolso acompanha', () async {
      cliente.transacoes = [
        _tx('g1', 'RESTAURANTE', -60, categoria: 'Eating out'),
        _tx('r1', 'Pix recebido: Maria', 60),
      ];
      cliente.servidor.add(Registro('revisoes', 'tx:r1',
          {'tipo': 'decisao', 'tx_id': 'r1', 'resposta': 'reembolso', 'reembolso_de': 'g1'},
          '2026-11-11T00:00:00.000Z', null));
      await sync();
      final original = (await tx('mb:g1')).categoryFk;
      expect((await tx('mb:r1')).categoryFk, original);
      await categoriaLocal('lazer', 'Lazer');

      cliente.servidor.add(Registro('ajustes', 'g1',
          {'categoria_id': 'cashew:lazer', 'category': 'Lazer'}, _futuro(), null));
      await sync();

      expect((await tx('mb:g1')).categoryFk, 'lazer');
      expect((await tx('mb:r1')).categoryFk, 'lazer');
    });

    test('gasto rachado muda de categoria neste aparelho e o reembolso acompanha', () async {
      cliente.transacoes = [
        _tx('g1', 'RESTAURANTE', -60, categoria: 'Eating out'),
        _tx('r1', 'Pix recebido: Maria', 60),
      ];
      cliente.servidor.add(Registro('revisoes', 'tx:r1',
          {'tipo': 'decisao', 'tx_id': 'r1', 'resposta': 'reembolso', 'reembolso_de': 'g1'},
          '2026-11-11T00:00:00.000Z', null));
      await sync();
      await categoriaLocal('lazer', 'Lazer');

      await (database.update(database.transactions)..where((t) => t.transactionPk.equals('mb:g1')))
          .write(TransactionsCompanion(
              categoryFk: const Value('lazer'),
              dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
      cliente.pullsCompletos = 0;
      await sync();

      expect((await tx('mb:g1')).categoryFk, 'lazer');
      expect((await tx('mb:r1')).categoryFk, 'lazer');
      expect(cliente.pullsCompletos, 1);
    });

    test('pull completo que falha deixa a marca e a rodada seguinte refaz', () async {
      cliente.transacoes = [_tx('g1', 'RESTAURANTE', -60, categoria: 'Eating out')];
      await sync();
      await categoriaLocal('lazer', 'Lazer');
      cliente.servidor.add(Registro('ajustes', 'g1',
          {'categoria_id': 'cashew:lazer', 'category': 'Lazer'}, _futuro(), null));
      final base = cliente.pulls;
      cliente.falhaEm = (n) => n == base + 2; // o segundo pull desta rodada (o completo) cai
      expect(await sincronizarMeuBanco(clienteParaTeste: cliente), false);
      expect((await tx('mb:g1')).categoryFk, isNot('lazer'));

      cliente.falhaEm = null;
      await sync();
      expect((await tx('mb:g1')).categoryFk, 'lazer');
    });
  });
}
