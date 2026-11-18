// Rachar conta: ranking dos gastos candidatos, minha parte e o efeito do vínculo nos totais reais do Cashew (Drift).
import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart' show getBudgetDate;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

final _hoje = DateTime(2026, 11, 12);

MbGastoCandidato _g(String pk, double v, DateTime d, {String cat = 'Casa', int reembolsado = 0}) =>
    MbGastoCandidato('mb:$pk', pk.toUpperCase(), cat, DateTime(d.year, d.month, d.day, 12), (v * 100).round(),
        reembolsado: reembolsado);

List<String> _pks(List<MbSugestaoReembolso> l) => [for (final s in l) s.gasto.pk];

String _dia(DateTime d) => d.toIso8601String().substring(0, 10);

Map<String, dynamic> _tx(String id, String desc, double valor, {DateTime? data, String? categoria}) => {
      'id': id, 'account_id': 'cc', 'date': _dia(data ?? DateTime.now()), 'description': desc,
      'amount': valor, 'status': 'POSTED', 'category': categoria, 'scheduled': 0,
    };

void main() {
  group('ranking dos gastos candidatos', () {
    test('metade exata vence o valor parecido e o mais recente', () {
      final r = mbSugerirReembolso([
        _g('posto', 200, _hoje),
        _g('padaria', 65, _hoje.subtract(const Duration(days: 1))),
        _g('restaurante', 120, _hoje.subtract(const Duration(days: 2)), cat: 'Restaurante'),
      ], valor: 60, data: _hoje);
      expect(_pks(r), ['mb:restaurante', 'mb:padaria', 'mb:posto']);
      expect(r.first.motivos, ['metade']);
      expect(r[1].motivos, ['valor parecido']);
      expect(mbReembolsoForte(r)?.gasto.pk, 'mb:restaurante');
    });

    test('mesmo pagador anterior sobe: desempata duas metades exatas', () {
      final gastos = [
        _g('casa', 120, _hoje.subtract(const Duration(days: 5)), cat: 'Casa'),
        _g('saude', 120, _hoje.subtract(const Duration(days: 1)), cat: 'Saúde'),
      ];
      final sem = mbSugerirReembolso(gastos, valor: 60, data: _hoje);
      expect(_pks(sem), ['mb:saude', 'mb:casa']); // empate: o mais recente
      expect(mbReembolsoForte(sem), isNull); // empate não vira destaque
      final com = mbSugerirReembolso(gastos, valor: 60, data: _hoje, categoriasDoPagador: {'Casa'});
      expect(_pks(com), ['mb:casa', 'mb:saude']);
      expect(com.first.motivos, ['metade', 'como das outras vezes']);
      expect(mbReembolsoForte(com)?.gasto.pk, 'mb:casa');
    });

    test('1/3, o que falta de um gasto já rachado e categoria típica de rachar', () {
      final r = mbSugerirReembolso([
        _g('mercado', 90, _hoje, cat: 'Mercado'),
        _g('jantar', 120, _hoje.subtract(const Duration(days: 3)), reembolsado: 9000),
        _g('casa', 300, _hoje.subtract(const Duration(days: 1))),
      ], valor: 30, data: _hoje);
      expect(r.firstWhere((s) => s.gasto.pk == 'mb:mercado').motivos, ['1/3']);
      expect(r.firstWhere((s) => s.gasto.pk == 'mb:jantar').motivos, ['o que falta']);
      expect(r.first.gasto.pk, 'mb:mercado'); // 1/3 + mercado (típico) passa o "o que falta" sem categoria típica
      expect(r.last.gasto.pk, 'mb:casa');
    });

    test('janela de 30 dias, nada depois do Pix e gasto já coberto fica de fora', () {
      final r = mbSugerirReembolso([
        _g('dentro', 120, _hoje.subtract(const Duration(days: 30))),
        _g('fora', 120, _hoje.subtract(const Duration(days: 31))),
        _g('depois', 120, _hoje.add(const Duration(days: 1))),
        _g('coberto', 120, _hoje, reembolsado: 12000),
      ], valor: 60, data: _hoje);
      expect(_pks(r), ['mb:dentro']);
    });

    test('Pix maior que o gasto desce e avisa', () {
      final r = mbSugerirReembolso([
        _g('pequeno', 50, _hoje),
        _g('grande', 300, _hoje.subtract(const Duration(days: 1))),
      ], valor: 60, data: _hoje);
      expect(_pks(r), ['mb:grande', 'mb:pequeno']);
      expect(r.last.motivos, contains('maior que o gasto'));
    });
  });

  group('minha parte', () {
    test('um reembolso, dois reembolsos e reembolso maior que o gasto (limita a zero e avisa)', () {
      expect(mbMinhaParte(12000, [6000]), (parte: 6000, excesso: 0));
      expect(mbMinhaParte(12000, [4000, 4000]), (parte: 4000, excesso: 0));
      expect(mbMinhaParte(12000, [15000]), (parte: 0, excesso: 3000));
      expect(mbMinhaParte(12000, const []), (parte: 12000, excesso: 0));
    });

    test('vínculos vêm das decisões "reembolso" com gasto; o pagador é o favorecido normalizado', () {
      final v = mbVinculosReembolso([
        {'tipo': 'decisao', 'tx_id': 'r1', 'resposta': 'reembolso', 'reembolso_de': 'g1', 'valor': 60, 'descricao': 'PIX RECEBIDO - Júnior Silva 123'},
        {'tipo': 'decisao', 'tx_id': 'r2', 'resposta': 'reembolso', 'valor': 10}, // sem gasto: abate em Outros
        {'tipo': 'decisao', 'tx_id': 'r3', 'resposta': 'renda', 'valor': 10},
      ]);
      expect([for (final x in v) [x.reembolsoPk, x.gastoPk, x.pagador, x.centavos]],
          [['mb:r1', 'mb:g1', 'JUNIOR SILVA', 6000]]);
    });

    test('item de uma entrada qualquer vira a mesma decisão da fila', () {
      final i = mbItemDeEntrada('mb:r1', 60, DateTime(2026, 11, 12, 15), 'TED RECEBIDA ANA');
      expect([i.id, i.tipo, i.txId, i.data, i.valor, i.descricao], ['tx:r1', 'pix_recebido', 'r1', '2026-11-12', 60, 'TED RECEBIDA ANA']);
    });
  });

  group('totais com o vínculo (Drift)', () {
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

    Future<void> sync() async =>
        expect(await sincronizarMeuBanco(clienteParaTeste: cliente), true, reason: meuBancoUltimoErro.value);

    Future<Transaction> tx(String pk) =>
        (database.select(database.transactions)..where((t) => t.transactionPk.equals(pk))).getSingle();

    Future<double> gasto(Budget b) async => mbWatchGastoOrcamento(
            b, await database.watchAllWalletsIndexed().first, getBudgetDate(b, DateTime.now()))
        .first;

    Future<double> geral() async => gasto(await database.getBudgetInstance(mbOrcamentoGeralPk));

    Future<Budget> doGasto(String gastoPk) async {
      final cat = (await tx(gastoPk)).categoryFk;
      final c = mbCicloCache!;
      await database.into(database.budgets).insert(BudgetsCompanion.insert(
          budgetPk: const Value('cat'), name: 'Categoria', amount: 1000, startDate: c.start, endDate: c.end,
          periodLength: 1, reoccurrence: const Value(BudgetReoccurence.monthly), order: 3,
          categoryFks: Value([cat]),
          budgetTransactionFilters: const Value([BudgetTransactionFilters.defaultBudgetTransactionFilters]),
          dateTimeModified: Value(DateTime.now())));
      return database.getBudgetInstance('cat');
    }

    Future<double> receitas() async =>
        await database.watchTotalOfWalletNoConversion(mbPkConta('cc'), isIncome: true).first ?? 0;

    Future<void> ligar(String r, String desc, double valor, String g) => mbResponderRevisao(
        mbItemDeEntrada('mb:$r', valor, DateTime.now(), desc), 'reembolso',
        reembolsoDe: g, clienteParaTeste: cliente);

    test('gasto R\$ 120 + Pix R\$ 60 ligado: ciclo, orçamento e categoria contam R\$ 60; não é receita; desligar volta',
        () async {
      cliente.transacoes = [
        _tx('g1', 'RESTAURANTE DO ZE', -120, categoria: 'Eating out'),
        _tx('r1', 'PIX RECEBIDO JUNIOR SILVA', 60),
      ];
      await sync();
      final cat = await doGasto('mb:g1');
      expect([await geral(), await gasto(cat), await receitas()], [120, 120, 60]);
      cliente.enviados.clear();

      await ligar('r1', 'PIX RECEBIDO JUNIOR SILVA', 60, 'g1');
      final r1 = await tx('mb:r1');
      expect([r1.income, r1.amount, r1.categoryFk], [false, 60, (await tx('mb:g1')).categoryFk]);
      expect([await geral(), await gasto(cat), await receitas()], [60, 60, 0]);
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty); // vínculo não é ajuste de categoria
      expect([for (final v in meuBancoReembolsos.value) v.gastoPk], ['mb:g1']);

      await mbDesfazerRevisao('r1', clienteParaTeste: cliente);
      expect(cliente.enviados.lastWhere((r) => r.id == 'tx:r1').deletedAt, isNotNull);
      expect((await tx('mb:r1')).income, true);
      expect([await geral(), await gasto(cat), await receitas()], [120, 120, 60]);
      expect(meuBancoReembolsos.value, isEmpty);
    });

    test('dois reembolsos (R\$ 40 + R\$ 40) num gasto de R\$ 120: conta R\$ 40, mesmo sem "Pix recebido" na descrição',
        () async {
      cliente.transacoes = [
        _tx('g1', 'RESTAURANTE DO ZE', -120, categoria: 'Eating out'),
        _tx('r1', 'TED RECEBIDA ANA LIMA', 40),
        _tx('r2', 'PIX RECEBIDO BIA COSTA', 40),
      ];
      await sync();
      await ligar('r1', 'TED RECEBIDA ANA LIMA', 40, 'g1');
      await ligar('r2', 'PIX RECEBIDO BIA COSTA', 40, 'g1');
      expect(await geral(), 40);
      expect(await receitas(), 0);
    });

    test('aprendizado: o gasto na categoria em que o pagador já rachou sobe na próxima vez', () async {
      final ontem = DateTime.now().subtract(const Duration(days: 1));
      cliente.semCiclo = true;
      cliente.transacoes = [
        _tx('g1', 'RESTAURANTE DO ZE', -120, categoria: 'Eating out', data: ontem),
        _tx('g2', 'RESTAURANTE NOVO', -90, categoria: 'Eating out', data: ontem),
        _tx('g3', 'MERCADO BOM', -90, categoria: 'Groceries'),
        _tx('r1', 'PIX RECEBIDO JUNIOR SILVA', 60),
        _tx('r3', 'PIX RECEBIDO JUNIOR SILVA', 45),
      ];
      await sync();
      final antes = await mbBuscarCandidatosReembolso('mb:r3', 45, DateTime.now(), 'PIX RECEBIDO JUNIOR SILVA');
      expect(antes.first.gasto.pk, 'mb:g3'); // metade de dois gastos: o mais recente
      await ligar('r1', 'PIX RECEBIDO JUNIOR SILVA', 60, 'g1');
      final depois = await mbBuscarCandidatosReembolso('mb:r3', 45, DateTime.now(), 'PIX RECEBIDO JUNIOR SILVA');
      expect(_pks(depois).take(2), ['mb:g2', 'mb:g3']);
      expect(depois.first.motivos, ['metade', 'como das outras vezes']);
      expect(depois.firstWhere((s) => s.gasto.pk == 'mb:g1').gasto.reembolsado, 6000);
    });
  });
}

class _Cliente extends MbCliente {
  _Cliente() : super(base: 'https://teste');
  final List<Registro> enviados = [];
  List<Map<String, dynamic>> transacoes = [];
  // Sem ciclo no Worker, o histórico guarda as categorias de sempre (no ciclo atual tudo espera validação).
  bool semCiclo = false;

  @override
  Future<Map<String, dynamic>> puxar(String? desde) async {
    final hoje = DateTime.now();
    return {
      'agora': hoje.toUtc().toIso8601String(),
      'registros': [],
      'contas': [{'id': 'cc', 'type': 'BANK', 'name': 'Conta Inter'}],
      'transacoes': desde == null ? transacoes : [], // como o Worker: o incremental não repete as antigas
      'pendentes': [],
      'ciclo': semCiclo
          ? <String, dynamic>{}
          : {
              'inicio': _dia(hoje.subtract(const Duration(days: 5))),
              'fim': _dia(hoje.add(const Duration(days: 25))),
            },
    };
  }

  @override
  Future<({int aceitos, List<({int indice, String motivo})> rejeitados})> enviar(List<Registro> lote) async {
    enviados.addAll(lote);
    return (aceitos: lote.length, rejeitados: <({int indice, String motivo})>[]);
  }
}
