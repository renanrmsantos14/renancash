import 'dart:async';
import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/configuracoes.dart';
import 'package:budget/struct/mbSync/detectar.dart';
import 'package:budget/struct/mbSync/linha.dart';
import 'package:budget/struct/mbSync/oficial.dart';
import 'package:budget/struct/mbSync/mapeamento.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/mbSync/pareamento.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/open.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ClienteFalso extends MbCliente {
  ClienteFalso() : super(base: 'https://teste');
  final List<Registro> servidor = [];
  final List<Registro> enviados = [];
  Map<String, dynamic> extra = {};
  bool semRede = false;
  final Set<String> rejeitarTabelas = {};

  @override
  Future<Map<String, dynamic>> puxar(String? desde) async => {
        'agora': DateTime.now().toUtc().toIso8601String(),
        'registros': [for (final r in servidor) r.toJson()],
        'contas': [],
        'transacoes': [],
        'pendentes': [],
        ...extra,
      };

  @override
  Future<({int aceitos, List<({int indice, String motivo})> rejeitados})> enviar(
      List<Registro> lote) async {
    if (semRede) throw http.ClientException('sem rede');
    final rej = [
      for (var i = 0; i < lote.length; i++)
        if (rejeitarTabelas.contains(lote[i].tabela)) (indice: i, motivo: 'dados inválidos')
    ];
    enviados.addAll([
      for (var i = 0; i < lote.length; i++)
        if (!rej.any((x) => x.indice == i)) lote[i]
    ]);
    return (aceitos: lote.length - rej.length, rejeitados: rej);
  }
}

String _futuro() =>
    DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String();

Future<void> _categoria(String pk, String nome, {bool receita = false}) =>
    database.into(database.categories).insert(CategoriesCompanion.insert(
        categoryPk: Value(pk),
        name: nome,
        order: 0,
        income: Value(receita),
        dateTimeModified: Value(DateTime.now())));

// Categorias próprias criadas pelo sync (mb:cat:) também sobem ao servidor; os testes olham só o resto.
Iterable<Registro> _semCatsMb(Iterable<Registro> l) =>
    l.where((r) =>
        !r.id.startsWith('cashew:mb:cat:') &&
        r.id != 'cashew:mb:orc:geral' &&
        r.id != 'cashew:mb:meta:reserva');

// `linha` (linha Drift completa) tem testes próprios; aqui só os campos mapeados.
Map<String, dynamic> _semLinha(Map<String, dynamic>? d) => {...?d}..remove('linha');

Future<List<Transaction>> _txs() => database.select(database.transactions).get();

void main() {
  late ClienteFalso cliente;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    database = FinanceDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({'mbNotifCursor': 'x'});
    cliente = ClienteFalso();
    meuBancoSincronizando.value = false;
  });

  tearDown(() => database.close());

  Future<void> sync() async {
    final ok = await sincronizarMeuBanco(clienteParaTeste: cliente);
    expect(ok, true, reason: meuBancoUltimoErro.value);
  }

  test('categoria criada no RenanCash vai no push com id cashew:<pk>', () async {
    await _categoria('c1', 'Mercado');
    await sync();
    final r = _semCatsMb(cliente.enviados).singleWhere((r) => r.tabela == 'categorias');
    expect(r.id, 'cashew:c1');
    expect(r.dados!['nome'], 'Mercado');
    expect(r.dados!['tipo'], 'despesa');
  });

  test('categoria remota mais nova é aplicada e não é reenviada', () async {
    await _categoria('c1', 'Mercado');
    cliente.servidor.add(Registro('categorias', 'cashew:c1',
        {'nome': 'Supermercado', 'tipo': 'despesa'}, _futuro(), null));
    await sync();
    expect((await database.getCategoryInstanceOrNull('c1'))!.name, 'Supermercado');
    cliente.enviados.clear();
    await sync();
    expect(_semCatsMb(cliente.enviados).where((r) => r.tabela == 'categorias'), isEmpty);
    expect((await database.getCategoryInstanceOrNull('c1'))!.name, 'Supermercado');
  });

  test('edição offline continua pendente e sai na rodada seguinte', () async {
    await _categoria('c1', 'Mercado');
    await sync();
    cliente.enviados.clear();
    await (database.update(database.categories)
          ..where((c) => c.categoryPk.equals('c1')))
        .write(CategoriesCompanion(
            name: const Value('Feira'),
            dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
    cliente.semRede = true;
    await sync();
    expect(_semCatsMb(cliente.enviados), isEmpty);
    expect((await mbLerFila()).pendentes, greaterThan(0));
    cliente.semRede = false;
    await sync();
    expect(_semCatsMb(cliente.enviados).single.dados!['nome'], 'Feira');
    expect((await mbLerFila()).pendentes, 0);
  });

  test('tombstone remoto apaga o orçamento local', () async {
    await database.into(database.budgets).insert(BudgetsCompanion.insert(
        budgetPk: const Value('b1'),
        name: 'Casa',
        amount: 500,
        startDate: DateTime(2025, 1, 1),
        endDate: DateTime(2025, 1, 31),
        periodLength: 1,
        order: 0,
        dateTimeModified: Value(DateTime.now())));
    await sync();
    expect(cliente.enviados.any((r) => r.tabela == 'orcamentos'), true);
    final t = _futuro();
    cliente.servidor
        .add(Registro('orcamentos', 'cashew:b1', null, t, t));
    await sync();
    expect(
        (await database.select(database.budgets).get())
            .where((b) => b.budgetPk != 'mb:orc:geral'),
        isEmpty);
  });

  Map<String, dynamic> banco() => {
        'contas': [
          {'id': 'a1', 'type': 'BANK', 'name': 'Conta'}
        ],
        'transacoes': [
          {
            'id': 't1',
            'account_id': 'a1',
            'date': '2025-01-10',
            'description': 'Padaria',
            'amount': -10.0,
            'category': 'Bakeries',
            'status': 'POSTED',
          }
        ],
      };

  test('mudar categoria de transação mb: gera ajuste e não gera tombstone',
      () async {
    await _categoria('c1', 'Mercado');
    cliente.extra = banco();
    await sync();
    expect((await _txs()).single.transactionPk, 'mb:t1');
    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('mb:t1')))
        .write(TransactionsCompanion(
            categoryFk: const Value('c1'),
            dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
    cliente.enviados.clear();
    await sync();
    final aj = cliente.enviados.singleWhere((r) => r.tabela == 'ajustes');
    expect(aj.id, 't1');
    expect(aj.dados!['categoria_id'], 'cashew:c1');
    expect((await _txs()).single.categoryFk, 'c1');
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados, isEmpty);
    expect((await mbLerEspelho())['ajustes/t1']!.registro.deletedAt, isNull);
    expect((await _txs()).single.categoryFk, 'c1');
  });

  test('ajuste de categoria vindo de outro aparelho é aplicado e não volta como edição local', () async {
    await _categoria('c1', 'Mercado');
    cliente.extra = banco();
    await sync();
    cliente.servidor.add(Registro('ajustes', 't1',
        {'categoria_id': 'cashew:c1', 'category': 'Mercado'}, _futuro(), null));
    cliente.enviados.clear();
    await sync();
    expect((await _txs()).single.categoryFk, 'c1');
    final espelho = (await mbLerEspelho())['ajustes/t1']!;
    // A transação editada (categoria) passa a carregar o título que tem hoje.
    expect(espelho.projecao, {'categoria_id': 'cashew:c1', 'category': 'Mercado', 'nome': 'Padaria'});
    // Sem pendência local: nada sobe e a data do ajuste remoto não é trocada por uma nova (ping-pong entre aparelhos).
    for (var i = 0; i < 2; i++) {
      cliente.enviados.clear();
      await sync();
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
    }
    expect((await mbLerEspelho())['ajustes/t1']!.registro.updatedAt, espelho.registro.updatedAt);
    expect((await mbLerFila()).pendentes, 0);
  });

  test('categoria apagada remotamente com transações fica e não ressuscita',
      () async {
    await _categoria('c1', 'Mercado');
    await database.into(database.transactions).insert(
        TransactionsCompanion.insert(
            transactionPk: const Value('t1'),
            name: 'Feira',
            amount: -20,
            note: '',
            categoryFk: 'c1',
            walletFk: const Value('0'),
            dateCreated: Value(DateTime(2025, 1, 10)),
            dateTimeModified: Value(DateTime.now())));
    await sync();
    final t = _futuro();
    cliente.servidor.add(Registro('categorias', 'cashew:c1', null, t, t));
    await sync();
    expect(await database.getCategoryInstanceOrNull('c1'), isNotNull);
    final e = (await mbLerEspelho())['categorias/cashew:c1']!;
    expect(e.registro.deletedAt, isNotNull);
    expect(e.projecao, isNull);
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados.where((r) => r.tabela == 'categorias'), isEmpty);
  });

  test('orçamento arquivado vai com arquivado 1 e sem tombstone', () async {
    await database.into(database.budgets).insert(BudgetsCompanion.insert(
        budgetPk: const Value('b1'),
        name: 'Casa',
        amount: 500,
        startDate: DateTime(2025, 1, 1),
        endDate: DateTime(2025, 1, 31),
        periodLength: 1,
        order: 0,
        dateTimeModified: Value(DateTime.now())));
    await sync();
    await (database.update(database.budgets)
          ..where((b) => b.budgetPk.equals('b1')))
        .write(BudgetsCompanion(
            archived: const Value(true),
            dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
    cliente.enviados.clear();
    await sync();
    // Arquivado agora sincroniza (arquivado: 1), sem tombstone.
    final r = _semCatsMb(cliente.enviados).singleWhere((r) => r.tabela == 'orcamentos');
    expect([r.deletedAt, r.dados!['arquivado']], [null, 1]);
    expect((await mbLerEspelho())['orcamentos/cashew:b1']!.registro.deletedAt,
        isNull);
  });

  test('reverter categoria A->B->A emite ajuste com A', () async {
    await _categoria('c1', 'Mercado');
    cliente.extra = banco();
    await sync();
    final a = (await _txs()).single.categoryFk;
    Future<void> muda(String cat, int s) =>
        (database.update(database.transactions)
              ..where((t) => t.transactionPk.equals('mb:t1')))
            .write(TransactionsCompanion(
                categoryFk: Value(cat),
                dateTimeModified:
                    Value(DateTime.now().add(Duration(seconds: s)))));
    await muda('c1', 5);
    await sync();
    cliente.enviados.clear();
    await muda(a, 10);
    await sync();
    final aj = cliente.enviados.singleWhere((r) => r.tabela == 'ajustes');
    expect(aj.dados!['categoria_id'], idDoPk(a));
  });

  test('apagar transação mb: gera gasto 0 e ela não volta no pull', () async {
    cliente.extra = banco();
    await sync();
    await database.delete(database.transactions).go();
    cliente.enviados.clear();
    await sync();
    final aj = cliente.enviados.singleWhere((r) => r.tabela == 'ajustes');
    expect(aj.dados, {'gasto': 0});
    expect(await _txs(), isEmpty);
    await sync();
    expect(await _txs(), isEmpty);
  });

  test('entidades remotas aplicadas não voltam como mudança local', () async {
    final t = DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String();
    cliente.servidor.addAll([
      Registro('categorias', 'c9', {'nome': 'Lazer', 'tipo': 'despesa'}, t, null),
      Registro('regras', 'r1', {'padrao': 'CINE*', 'categoria_id': 'c9'}, t, null),
      Registro('orcamentos', 'o1',
          {'nome': 'Lazer', 'valor': 300, 'categoria_ids': ['c9']}, t, null),
      Registro('metas', 'm1', {'nome': 'Viagem', 'valor_alvo': 1000, 'prazo': '2026-12-31'}, t, null),
      Registro('dividas', 'd1',
          {'tipo': 'emprestimo', 'nome': 'Carro', 'sentido': 'devo', 'valor_total': 900}, t, null),
      Registro('lancamentos', 'l1',
          {'data': '2025-03-05', 'descricao': 'Cinema', 'valor': -40, 'categoria_id': 'c9', 'meta_id': 'm1'},
          t, null),
      Registro('assinaturas', 's1',
          {'nome': 'Netflix', 'valor': 39.9, 'dia': 12, 'padrao': 'NETFLIX*', 'status': 'confirmada', 'categoria_id': 'c9'},
          t, null),
    ]);
    await sync();
    expect((await _txs()).map((x) => x.transactionPk).toSet(), {'l1', 's1'});
    expect((await _txs()).firstWhere((x) => x.transactionPk == 'l1').objectiveFk, 'm1');
    // Meta, dívida e a Reserva de emergência criada no primeiro sync.
    expect(await database.select(database.objectives).get(), hasLength(3));
    cliente.enviados.clear();
    await sync();
    expect(_semCatsMb(cliente.enviados), isEmpty);
  });

  group('metas ligadas a aplicações', () {
    Map<String, dynamic> inv(Map<String, double> saldos) => {
          'investimentos': [
            for (final e in saldos.entries)
              {'id': e.key, 'nome': 'Aplicação ${e.key}', 'saldo': e.value, 'banco': 'Inter'}
          ]
        };

    Future<double> progresso(String metaPk) async => (await database
            .customSelect(
                'SELECT COALESCE(SUM(amount), 0) AS s FROM transactions '
                'WHERE objective_fk = ? AND paid = 1',
                variables: [Variable<String>(metaPk)])
            .getSingle())
        .read<double>('s');

    Iterable<Registro> metasEnviadas() => cliente.enviados.where((r) => r.tabela == 'metas');

    test('Reserva de emergência é criada uma vez, sem valor alvo, e vai ao servidor', () async {
      await sync();
      await sync();
      final metas = await database.select(database.objectives).get();
      expect(metas.map((o) => [o.objectivePk, o.name, o.amount, o.endDate, o.pinned]), [
        ['mb:meta:reserva', 'Reserva de emergência', 0.0, null, true]
      ]);
      expect(metas.single.income, isTrue);
      final enviadas = metasEnviadas().toList();
      expect(enviadas, hasLength(1));
      expect(enviadas.single.id, 'cashew:mb:meta:reserva');
      expect(_semLinha(enviadas.single.dados), {'nome': 'Reserva de emergência', 'valor_alvo': 0.0, 'aplicacao_ids': <String>[]});
    });

    test('Reserva já existente no servidor não é recriada; apagada, não volta', () async {
      cliente.servidor.add(Registro('metas', 'cashew:mb:meta:reserva',
          {'nome': 'Reserva de emergência', 'valor_alvo': 30000, 'aplicacao_ids': ['i1']},
          DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(), null));
      cliente.extra = inv({'i1': 100});
      await sync();
      final o = (await database.select(database.objectives).get()).single;
      expect([o.name, o.amount], ['Reserva de emergência', 30000.0]);
      expect(metasEnviadas(), isEmpty);

      await (database.delete(database.objectives)).go();
      await sync();
      expect(await database.select(database.objectives).get(), isEmpty);
    });

    test('aplicações da meta somam o progresso e não geram ajuste', () async {
      cliente.servidor.add(Registro('metas', 'cashew:m1',
          {'nome': 'Viagem', 'valor_alvo': 5000, 'aplicacao_ids': ['i1', 'i2']},
          DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(), null));
      cliente.extra = inv({'i1': 1500.5, 'i2': 200, 'i3': 900});
      await sync();
      expect(await progresso('m1'), 1700.5);
      final porPk = {for (final t in await _txs()) t.transactionPk: t.objectiveFk};
      // i3 não tinha meta: o vínculo inicial a leva para a Reserva de emergência (uma vez).
      expect(porPk['mb:inv:i3'], 'mb:meta:reserva');
      expect(porPk['mb:inv:i1'], 'm1');
      // Meta de poupança (income): o tile do RenanCash mostra o progresso positivo.
      expect((await (database.select(database.objectives)..where((o) => o.objectivePk.equals('m1'))).getSingle()).income, isTrue);
      expect(await mbLerAplicado(), isEmpty);
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);

      // Saldo muda no sync seguinte: o progresso acompanha.
      cliente.extra = inv({'i1': 1600, 'i2': 200, 'i3': 900});
      await sync();
      expect(await progresso('m1'), 1800.0);
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
    });

    test('vínculo chega antes da aplicação e vale quando ela aparece', () async {
      cliente.servidor.add(Registro('metas', 'cashew:m1',
          {'nome': 'Casa', 'valor_alvo': 10000, 'aplicacao_ids': ['i9']},
          DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(), null));
      await sync();
      expect(await progresso('m1'), 0);
      cliente.extra = inv({'i9': 777});
      await sync();
      expect(await progresso('m1'), 777);
    });

    test('cada aplicação fica em uma meta só', () async {
      cliente.extra = inv({'i1': 100, 'i2': 50});
      await sync();
      for (final pk in ['m1', 'm2']) {
        await database.into(database.objectives).insert(ObjectivesCompanion.insert(
            objectivePk: Value(pk), name: pk, amount: 1000, order: 5,
            dateTimeModified: Value(DateTime.now())));
      }
      await mbDefinirAplicacoesDaMeta('m1', ['mb:inv:i1']);
      await mbDefinirAplicacoesDaMeta('m2', ['mb:inv:i1', 'mb:inv:i2']);
      expect(await mbVinculosMetas(), {'mb:inv:i1': 'm2', 'mb:inv:i2': 'm2'});
      expect(await progresso('m1'), 0);
      expect(await progresso('m2'), 150);
      final lista = await mbAplicacoes();
      expect({for (final a in lista) a.id: a.metaPk}, {'i1': 'm2', 'i2': 'm2'});
      await mbDefinirAplicacoesDaMeta('m2', ['mb:inv:i2']);
      expect(await progresso('m2'), 50);
      expect((await _txs()).singleWhere((t) => t.transactionPk == 'mb:inv:i1').objectiveFk, isNull);
    });

    test('vínculo escolhido no app sobe ordenado e não volta como mudança', () async {
      cliente.extra = inv({'i1': 100, 'i2': 50});
      await sync();
      await database.into(database.objectives).insert(ObjectivesCompanion.insert(
          objectivePk: const Value('m1'), name: 'Viagem', amount: 2000, order: 5,
          endDate: Value(DateTime(2027, 1, 31, 12)),
          dateTimeModified: Value(DateTime.now())));
      await mbDefinirAplicacoesDaMeta('m1', ['mb:inv:i2', 'mb:inv:i1']);
      cliente.enviados.clear();
      await sync();
      expect(_semLinha(metasEnviadas().singleWhere((r) => r.id == 'cashew:m1').dados),
          {'nome': 'Viagem', 'valor_alvo': 2000.0, 'prazo': '2027-01-31', 'aplicacao_ids': ['i1', 'i2']});
      cliente.enviados.clear();
      await sync();
      expect(_semCatsMb(cliente.enviados), isEmpty);
    });

    test('meta de app antigo (sem aplicacao_ids, sem valor) não apaga vínculos nem o alvo locais', () async {
      cliente.extra = inv({'i1': 100});
      await sync();
      await database.into(database.objectives).insert(ObjectivesCompanion.insert(
          objectivePk: const Value('m1'), name: 'Viagem', amount: 2000, order: 5,
          dateTimeModified: Value(DateTime.now())));
      await mbDefinirAplicacoesDaMeta('m1', ['mb:inv:i1']);
      cliente.servidor.add(Registro('metas', 'cashew:m1', {'nome': 'Viagem 2'}, _futuro(), null));
      await sync();
      final o = await (database.select(database.objectives)..where((x) => x.objectivePk.equals('m1'))).getSingle();
      expect([o.name, o.amount, o.endDate, o.income], ['Viagem 2', 2000.0, null, isTrue]);
      expect(await mbVinculosMetas(), {'mb:inv:i1': 'm1'});
      expect(await progresso('m1'), 100);
    });

    test('meta apagada no servidor solta as aplicações', () async {
      cliente.extra = inv({'i1': 100});
      cliente.servidor.add(Registro('metas', 'cashew:m1',
          {'nome': 'Viagem', 'valor_alvo': 100, 'aplicacao_ids': ['i1']},
          DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(), null));
      await sync();
      expect(await progresso('m1'), 100);
      final t = _futuro();
      cliente.servidor
        ..clear()
        ..add(Registro('metas', 'cashew:m1', null, t, t));
      await sync();
      expect(await mbVinculosMetas(), isEmpty);
      expect((await _txs()).singleWhere((x) => x.transactionPk == 'mb:inv:i1').objectiveFk, isNull);
    });

    test('série mensal do Worker é guardada; Worker antigo não apaga a série', () async {
      final serie = [
        {'mes': '2026-11', 'itens': [{'id': 'i1', 'nome': 'CDB', 'banco': 'Inter', 'saldo': 1700.5}]},
        {'mes': '2026-10', 'itens': [{'id': 'i1', 'nome': 'CDB', 'banco': 'Inter', 'saldo': 1500}, {'id': 'i2', 'nome': 'Fundo', 'saldo': 200}]},
      ];
      cliente.extra = {...inv({'i1': 1700.5}), 'investimentos_mensal': serie};
      await sync();
      var lida = await mbLerSerieMensal();
      expect(lida.map((m) => m.mes), ['2026-10', '2026-11']);
      expect(lida.map((m) => m.total), [1700.0, 1700.5]);
      cliente.extra = inv({'i1': 1700.5});
      await sync();
      lida = await mbLerSerieMensal();
      expect(lida, hasLength(2));
      expect(mbSerieDeJson('lixo'), isEmpty);
    });
  });

  test('trocar de conta apaga o espelho e o importado, e reenvia o que é do RenanCash', () async {
    await _categoria('c1', 'Mercado');
    cliente.extra = banco();
    await sync();
    expect((await _txs()).map((t) => t.transactionPk), contains('mb:t1'));
    expect(cliente.enviados.where((r) => r.id == 'cashew:c1'), isNotEmpty);
    expect((await database.select(database.categories).get())
        .where((c) => c.categoryPk.startsWith('mb:cat:')), isNotEmpty);
    expect((await database.select(database.wallets).get())
        .where((w) => w.walletPk.startsWith('mb:')), isNotEmpty);

    await mbTrocarConta();
    expect((await _txs()).where((t) => t.transactionPk.startsWith('mb:')), isEmpty);
    expect(await mbLerEspelho(), isEmpty);
    expect(await mbLerAplicado(), isEmpty);
    expect(await mbLerEstado('cursor'), isNull);
    expect(await database.getCategoryInstanceOrNull('c1'), isNotNull);
    final cats = await database.select(database.categories).get();
    expect(cats.where((c) => c.categoryPk.startsWith('mb:cat:')), isEmpty);
    expect((await database.select(database.wallets).get())
        .where((w) => w.walletPk.startsWith('mb:')), isEmpty);

    cliente.enviados.clear();
    cliente.extra = {};
    await sync();
    expect(cliente.enviados.where((r) => r.id == 'cashew:c1'), isNotEmpty);
    expect((await SharedPreferences.getInstance()).getString('mbNotifCursor'), isNull);
  });

  test('conta corrente Santander importada antes é apagada sem mandar ajuste', () async {
    final st = {'id': 'st', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta', 'bank': 'Santander'};
    final tx = {'id': 'st-1', 'account_id': 'st', 'date': '2025-01-10', 'description': 'Pix', 'amount': -10.0, 'category': 'Transfers', 'status': 'POSTED'};
    // Simula o import antigo: carteira e transação mb: já aplicadas.
    cliente.extra = {
      'contas': [{...st, 'bank': 'Inter'}],
      'transacoes': [tx],
    };
    await sync();
    expect((await _txs()).map((t) => t.transactionPk), ['mb:st-1']);
    cliente.enviados.clear();
    cliente.extra = {'contas': [st], 'transacoes': [tx]};
    await sync();
    expect(await database.getWalletInstanceOrNull('mb:st'), isNull);
    expect(await _txs(), isEmpty);
    expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
    expect(await mbLerEstado('contas'), '[]');
  });

  test('investimentos viram ajuste de saldo na carteira Investimentos', () async {
    cliente.extra = {
      'investimentos': [
        {'id': 'i1', 'nome': 'CDB ', 'saldo': 1500.5, 'banco': 'Santander'},
        {'id': 'i2', 'nome': 'Fundo', 'saldo': 200.0},
      ]
    };
    await sync();
    expect(await database.getWalletInstanceOrNull('mb:investimentos'), isNotNull);
    final cdb = (await _txs()).singleWhere((t) => t.transactionPk == 'mb:inv:i1');
    expect([cdb.name, cdb.amount, cdb.note, cdb.categoryFk, cdb.income], ['CDB', 1500.5, 'Santander', '0', true]);
    cliente.enviados.clear();
    cliente.extra = {
      'investimentos': [
        {'id': 'i1', 'nome': 'CDB', 'saldo': 1600.0, 'banco': 'Santander'},
      ]
    };
    await sync();
    final txs = await _txs();
    expect(txs.map((t) => t.transactionPk), ['mb:inv:i1']);
    expect(txs.single.amount, 1600.0);
    expect(txs.single.dateCreated, cdb.dateCreated);
    expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
  });

  test('histórico: primeira carga completa converte as categorias sem mandar ajuste', () async {
    await _categoria('c1', 'Mercado');
    cliente.extra = banco();
    await sync();
    await mbRemoverEstado('conv_categorias_v1');
    // Estado antigo: categoria pela tradução do banco, já aplicada.
    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('mb:t1')))
        .write(const TransactionsCompanion(categoryFk: Value('mb:cat:d:Padaria')));
    await mbGravarAplicado({'mb:t1': 'mb:cat:d:Padaria'}, const []);
    cliente.enviados.clear();
    await sync();
    expect((await _txs()).single.categoryFk, 'mb:cat:d:Outros');
    expect((await mbLerAplicado())['mb:t1'], 'mb:cat:d:Outros');
    expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
    expect(await mbLerEstado('conv_categorias_v1'), isNotNull);
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
  });

  test('histórico: categoria escolhida pelo usuário sobrevive à conversão', () async {
    await _categoria('c1', 'Mercado');
    cliente.extra = banco();
    await sync();
    await mbRemoverEstado('conv_categorias_v1');
    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('mb:t1')))
        .write(TransactionsCompanion(
            categoryFk: const Value('c1'),
            dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
    await sync();
    expect((await _txs()).single.categoryFk, 'c1');
    expect(cliente.enviados.singleWhere((r) => r.tabela == 'ajustes').dados!['categoria_id'], 'cashew:c1');
  });

  test('histórico: transação que passou a ser transferência sai sem ajuste', () async {
    cliente.extra = {
      'contas': [{'id': 'a1', 'type': 'BANK', 'name': 'Conta', 'bank': 'Inter'}],
      'transacoes': [
        {'id': 'r1', 'account_id': 'a1', 'date': '2025-01-10', 'description': 'Pix SANTANDER', 'amount': 900.0, 'status': 'POSTED'}
      ],
    };
    await mbCriarTabelas();
    await sync();
    expect(await _txs(), isEmpty);
    await database.into(database.transactions).insert(TransactionsCompanion.insert(
        transactionPk: const Value('mb:r1'),
        name: 'Pix SANTANDER',
        amount: 900.0,
        note: '',
        categoryFk: 'mb:cat:r:Transferências',
        walletFk: const Value('mb:a1'),
        dateCreated: Value(DateTime(2025, 1, 10, 12)),
        income: const Value(true),
        paid: const Value(true),
        dateTimeModified: Value(DateTime.utc(2000))));
    await mbGravarAplicado({'mb:r1': 'mb:cat:r:Transferências'}, const []);
    await mbRemoverEstado('conv_categorias_v1');
    cliente.enviados.clear();
    await sync();
    expect(await _txs(), isEmpty);
    expect(await mbLerAplicado(), isEmpty);
    expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
  });

  group('orçamentos', () {
    Future<void> orcamento(String pk) =>
        database.into(database.budgets).insert(BudgetsCompanion.insert(
            budgetPk: Value(pk),
            name: pk,
            amount: 500,
            startDate: DateTime(2025, 1, 1),
            endDate: DateTime(2025, 1, 31),
            periodLength: 1,
            order: 5,
            budgetTransactionFilters: const Value(
                [BudgetTransactionFilters.defaultBudgetTransactionFilters]),
            dateTimeModified: Value(DateTime.now())));

    Future<void> depois(String pk, Set<String>? escolha) =>
        mbDefinirOrcamentosDaTransacao(pk, escolha,
            agora: DateTime.now().add(const Duration(seconds: 5)));

    test('o Geral é criado na sincronização com valor 0 e sobe ao servidor', () async {
      await sync();
      final g = await database.getBudgetInstance(mbOrcamentoGeralPk);
      expect(g.name, 'Geral');
      expect(g.amount, 0);
      await sync();
      final env = cliente.enviados.singleWhere((r) => r.id == 'cashew:mb:orc:geral');
      expect(env.tabela, 'orcamentos');
      expect(env.dados!['valor'], 0);
      expect(env.dados!['periodo'], 'ciclo');
    });

    test('escolha em transação mb: sai em ajustes uma vez e não repete', () async {
      cliente.extra = banco();
      await sync();
      await orcamento('b1');
      await depois('mb:t1', {'b1', mbOrcamentoGeralPk});
      cliente.enviados.clear();
      await sync();
      final aj = cliente.enviados.singleWhere((r) => r.tabela == 'ajustes');
      expect(aj.id, 't1');
      expect(aj.dados!['orcamento_ids'], ['cashew:b1', 'cashew:mb:orc:geral']);
      expect(aj.dados!.containsKey('gasto'), false);
      cliente.enviados.clear();
      await sync();
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
    });

    test('voltar ao Geral apaga a escolha no servidor', () async {
      cliente.extra = banco();
      await sync();
      await orcamento('b1');
      await depois('mb:t1', {'b1'});
      await sync();
      expect(await mbOrcamentosDaTransacao('mb:t1'), {'b1'});
      await mbDefinirOrcamentosDaTransacao('mb:t1', {mbOrcamentoGeralPk},
          agora: DateTime.now().add(const Duration(seconds: 10)));
      cliente.enviados.clear();
      await sync();
      final aj = cliente.enviados.where((r) => r.tabela == 'ajustes');
      expect(aj.every((r) => r.dados?.containsKey('orcamento_ids') != true), true);
      expect(await mbOrcamentosDaTransacao('mb:t1'), isNull);
      expect((await mbLerEspelho())['ajustes/t1']!.projecao?['orcamento_ids'], isNull);
    });

    test('transação mb: sem escolha não gera ajuste nem gasto 0', () async {
      cliente.extra = banco();
      await sync();
      cliente.enviados.clear();
      await sync();
      await sync();
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
    });

    test('ajuste vindo do servidor grava a escolha e não volta como mudança', () async {
      cliente.extra = banco();
      await sync();
      await orcamento('b1');
      cliente.servidor.add(Registro('ajustes', 't1',
          {'orcamento_ids': ['cashew:b1']}, _futuro(), null));
      cliente.enviados.clear();
      await sync();
      expect(await mbOrcamentosDaTransacao('mb:t1'), {'b1'});
      cliente.enviados.clear();
      await sync();
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
    });

    test('lançamento manual: escolha sobe e a recebida de outro aparelho é aplicada', () async {
      await _categoria('c1', 'Mercado');
      await orcamento('b1');
      await database.into(database.transactions).insert(
          TransactionsCompanion.insert(
              transactionPk: const Value('m1'),
              name: 'Feira',
              amount: -20,
              note: '',
              categoryFk: 'c1',
              walletFk: const Value('0'),
              dateCreated: Value(DateTime(2025, 1, 10)),
              dateTimeModified: Value(DateTime.now())));
      await mbDefinirOrcamentosDaTransacao('m1', {'b1'});
      await sync();
      final l = cliente.enviados.singleWhere((r) => r.tabela == 'lancamentos');
      expect(l.dados!['orcamento_ids'], ['cashew:b1']);
      cliente.servidor.add(Registro(
          'lancamentos',
          'l9',
          {'data': '2025-01-11', 'descricao': 'Cinema', 'valor': -40, 'orcamento_ids': ['cashew:b1']},
          _futuro(),
          null));
      cliente.servidor.add(Registro('lancamentos', 'l8',
          {'data': '2025-01-11', 'descricao': 'Padaria', 'valor': -10}, _futuro(), null));
      await sync();
      expect(await mbOrcamentosDaTransacao('l9'), {'b1'});
      expect(await mbOrcamentosDaTransacao('l8'), isNull);
    });
  });

  test('mapa de categorias: importação vai para Pai › Sub e o pull não desfaz título nem escolha local', () async {
    await _categoria('4', 'Transporte');
    await database.into(database.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('uber'),
        name: 'Uber',
        order: 0,
        mainCategoryPk: const Value('4')));
    await _categoria('c1', 'Trabalho');
    cliente.extra = {
      'contas': [
        {'id': 'a1', 'type': 'BANK', 'name': 'Conta'}
      ],
      'transacoes': [
        {'id': 't1', 'account_id': 'a1', 'date': '2025-01-10', 'description': 'UBER TRIP', 'amount': -18.0, 'category': 'Taxi and ride-hailing', 'status': 'POSTED'}
      ],
    };
    await sync();
    var t = (await _txs()).single;
    expect([t.categoryFk, t.subCategoryFk, t.name], ['4', 'uber', 'UBER TRIP']);

    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('mb:t1')))
        .write(TransactionsCompanion(
            name: const Value('Uber para o cliente'),
            categoryFk: const Value('c1'),
            subCategoryFk: const Value(null),
            dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados.singleWhere((r) => r.tabela == 'ajustes').dados!['categoria_id'], 'cashew:c1');
    await sync();
    t = (await _txs()).single;
    expect([t.categoryFk, t.subCategoryFk, t.name], ['c1', null, 'Uber para o cliente']);
  });

  Future<void> carteira(String pk, String nome) =>
      database.createOrUpdateWallet(TransactionWallet(
          walletPk: pk,
          name: nome,
          dateCreated: DateTime.now(),
          dateTimeModified: null,
          order: 5,
          currency: 'brl',
          decimals: 2,
          homePageWidgetDisplay: null));

  test('carteira manual vai no push; padrão 0 e mb:* ficam de fora', () async {
    await carteira('w1', 'Nubank');
    await carteira('mb:conta:x', 'Banco');
    await sync();
    final l = cliente.enviados.where((r) => r.tabela == 'carteiras').toList();
    expect(l.map((r) => r.id), ['cashew:w1']);
    expect(l.single.dados!['nome'], 'Nubank');
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados.where((r) => r.tabela == 'carteiras'), isEmpty);
  });

  test('carteira remota é criada e não volta ao servidor', () async {
    cliente.servidor.add(Registro('carteiras', 'cashew:w2',
        {'nome': 'Inter', 'cor': 'FF0000', 'ordem': 9}, _futuro(), null));
    await sync();
    final w = (await database.getWalletInstanceOrNull('w2'))!;
    expect(w.name, 'Inter');
    expect(w.colour, 'FF0000');
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados.where((r) => r.tabela == 'carteiras'), isEmpty);
  });

  test('lançamento que chegou antes da carteira é religado quando ela chega', () async {
    await _categoria('c1', 'Mercado');
    cliente.servidor.add(Registro(
        'lancamentos',
        'cashew:t1',
        {'data': '2026-11-01', 'descricao': 'Saldo inicial', 'valor': 100, 'categoria_id': 'cashew:c1', 'carteira': 'Inter'},
        '2026-11-01T10:00:00.000Z',
        null));
    await sync();
    expect((await _txs()).singleWhere((t) => t.transactionPk == 't1').walletFk, '0');
    cliente.servidor.add(Registro('carteiras', 'cashew:w2', {'nome': 'Inter'},
        '2026-11-01T11:00:00.000Z', null));
    await sync();
    expect((await _txs()).singleWhere((t) => t.transactionPk == 't1').walletFk, 'w2');
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados.where((r) => r.tabela == 'lancamentos'), isEmpty);
  });

  test('tombstone remoto não apaga carteira com transações', () async {
    await carteira('w3', 'Caixa');
    await sync();
    await database.into(database.transactions).insert(TransactionsCompanion.insert(
        transactionPk: const Value('t9'),
        name: 'x',
        amount: -1,
        note: '',
        categoryFk: 'c1',
        walletFk: const Value('w3'),
        dateCreated: Value(DateTime(2026, 11, 2)),
        income: const Value(false),
        paid: const Value(true)));
    cliente.servidor.add(Registro('carteiras', 'cashew:w3', null, _futuro(), _futuro()));
    await sync();
    expect(await database.getWalletInstanceOrNull('w3'), isNotNull);
  });

  Future<void> agendada(String pk, TransactionSpecialType tipo,
          {bool paga = false, bool criouProxima = false}) =>
      database.into(database.transactions).insert(TransactionsCompanion.insert(
          transactionPk: Value(pk),
          name: 'Aluguel',
          amount: -1500,
          note: '',
          categoryFk: 'c1',
          dateCreated: Value(DateTime(2026, 12, 5, 12)),
          originalDateDue: Value(DateTime(2026, 12, 5, 12)),
          income: const Value(false),
          paid: Value(paga),
          type: Value(tipo),
          reoccurrence: const Value(BudgetReoccurence.monthly),
          periodLength: const Value(1),
          endDate: Value(DateTime(2027, 6, 5, 12)),
          createdAnotherFutureTransaction: Value(criouProxima),
          dateTimeModified: Value(DateTime.now())));

  test('recorrente local vai no push com tipo, repetição e fim; ida e volta sem reenvio', () async {
    await _categoria('c1', 'Casa');
    await agendada('r1', TransactionSpecialType.repetitive);
    await agendada('u1', TransactionSpecialType.upcoming);
    await sync();
    final l = {
      for (final r in cliente.enviados.where((r) => r.tabela == 'lancamentos')) r.id: r.dados!
    };
    expect(l['cashew:r1']!['tipo'], 'recorrente');
    expect(l['cashew:u1']!['tipo'], 'agendada');
    expect(l['cashew:r1']!['repeticao'], 'mensal');
    expect(l['cashew:r1']!['periodo'], 1);
    expect(l['cashew:r1']!['fim'], '2027-06-05');
    expect(l['cashew:r1']!['vencimento'], '2026-12-05');
    expect(l['cashew:r1']!['pago'], 0);
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados.where((r) => r.tabela == 'lancamentos'), isEmpty);
  });

  test('recorrente remota é criada com o estado completo e não volta ao servidor', () async {
    await _categoria('c1', 'Casa');
    cliente.servidor.add(Registro(
        'lancamentos',
        'cashew:r2',
        {
          'data': '2026-12-05',
          'descricao': 'Academia',
          'valor': -120,
          'categoria_id': 'cashew:c1',
          'tipo': 'recorrente',
          'pago': 0,
          'pulado': 0,
          'proxima_criada': 0,
          'repeticao': 'semanal',
          'periodo': 2,
          'fim': '2027-01-05',
          'vencimento': '2026-12-05',
        },
        _futuro(),
        null));
    await sync();
    final t = (await _txs()).singleWhere((t) => t.transactionPk == 'r2');
    expect(t.type, TransactionSpecialType.repetitive);
    expect([t.paid, t.skipPaid, t.createdAnotherFutureTransaction], [false, false, false]);
    expect([t.reoccurrence, t.periodLength], [BudgetReoccurence.weekly, 2]);
    expect(t.endDate, DateTime(2027, 1, 5, 12));
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados.where((r) => r.tabela == 'lancamentos'), isEmpty);
  });

  test('pagamento feito em outro aparelho chega com a próxima ocorrência, sem duplicar', () async {
    await _categoria('c1', 'Casa');
    await agendada('r3', TransactionSpecialType.repetitive);
    await sync();
    cliente.enviados.clear();
    Map<String, dynamic> d(String data, bool paga, bool criou) => {
          'data': data,
          'descricao': 'Aluguel',
          'valor': -1500,
          'categoria_id': 'cashew:c1',
          'tipo': 'recorrente',
          'pago': paga ? 1 : 0,
          'pulado': 0,
          'proxima_criada': criou ? 1 : 0,
          'repeticao': 'mensal',
          'periodo': 1,
          'vencimento': data,
        };
    final quando = _futuro();
    cliente.servidor.addAll([
      Registro('lancamentos', 'cashew:r3', d('2026-12-05', true, true), quando, null),
      Registro('lancamentos', 'cashew:r3::predict::1', d('2027-01-05', false, false), quando, null),
    ]);
    await sync();
    final todas = await _txs();
    expect(todas.where((t) => t.transactionPk == 'r3::predict::1'), hasLength(1));
    final r3 = todas.singleWhere((t) => t.transactionPk == 'r3');
    expect([r3.paid, r3.createdAnotherFutureTransaction], [true, true]);
    cliente.enviados.clear();
    await sync();
    expect(cliente.enviados.where((r) => r.tabela == 'lancamentos'), isEmpty);
  });

  Map<String, dynamic> dadosRec(bool paga, {bool despago = false}) => {
        'data': '2026-12-05',
        'descricao': 'Aluguel',
        'valor': -1500,
        'categoria_id': 'cashew:c1',
        'tipo': 'recorrente',
        'pago': paga ? 1 : 0,
        'pulado': 0,
        'proxima_criada': 0,
        'repeticao': 'mensal',
        'periodo': 1,
        'vencimento': '2026-12-05',
        if (despago) 'despago': 1,
      };
  Iterable<Registro> lancs() => cliente.enviados.where((r) => r.tabela == 'lancamentos');

  test('paga no aparelho A e edição não paga mais nova do B: continua paga e a versão paga volta ao servidor', () async {
    await _categoria('c1', 'Casa');
    await agendada('r6', TransactionSpecialType.repetitive, paga: true);
    await sync();
    expect(lancs().single.dados!['pago'], 1);
    // B editou sem saber do pagamento: versão não paga mais nova, sem marcador de despagar.
    cliente.servidor.add(Registro('lancamentos', 'cashew:r6', dadosRec(false), _futuro(), null));
    cliente.enviados.clear();
    await sync();
    expect((await _txs()).singleWhere((t) => t.transactionPk == 'r6').paid, true);
    cliente.enviados.clear();
    await sync();
    expect(lancs().single.dados!['pago'], 1);
    expect(lancs().single.dados!.containsKey('despago'), false);
    // O servidor passa a guardar a versão paga (a mais nova); o outro aparelho a aplica e nada mais sobe.
    cliente.servidor
      ..clear()
      ..add(Registro('lancamentos', 'cashew:r6', lancs().single.dados, _futuro(), null));
    await sync(); // a rodada ainda reenviava o espelho antigo (pull anterior); depois disso estabiliza
    cliente.enviados.clear();
    await sync();
    expect(lancs(), isEmpty);
  });

  test('despagar de propósito propaga: vai com despago e o outro aparelho aceita', () async {
    await _categoria('c1', 'Casa');
    await agendada('r7', TransactionSpecialType.repetitive, paga: true);
    await sync();
    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('r7')))
        .write(TransactionsCompanion(
            paid: const Value(false),
            dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
    cliente.enviados.clear();
    await sync();
    expect(lancs().single.dados!['pago'], 0);
    expect(lancs().single.dados!['despago'], 1);
    // Aparelho B (paga localmente) recebe o despagar explícito e obedece, sem reenviar a versão paga.
    final b = await _txs();
    expect(b.singleWhere((t) => t.transactionPk == 'r7').paid, false);
    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('r7')))
        .write(const TransactionsCompanion(paid: Value(true)));
    cliente.servidor.add(Registro('lancamentos', 'cashew:r7', dadosRec(false, despago: true), _futuro(), null));
    cliente.enviados.clear();
    await sync();
    expect((await _txs()).singleWhere((t) => t.transactionPk == 'r7').paid, false);
    for (var i = 0; i < 2; i++) {
      cliente.enviados.clear();
      await sync();
      expect(lancs().where((r) => r.dados!['pago'] == 1), isEmpty);
    }
  });

  test('despagar no A com o B offline por várias rodadas: B fica não paga e não reenvia', () async {
    await _categoria('c1', 'Casa');
    await agendada('r8', TransactionSpecialType.repetitive, paga: true);
    await sync();
    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('r8')))
        .write(TransactionsCompanion(
            paid: const Value(false),
            dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
    // Várias rodadas do A: o marcador continua no registro.
    Map<String, dynamic>? noServidor;
    for (var i = 0; i < 3; i++) {
      cliente.enviados.clear();
      await sync();
      if (lancs().isNotEmpty) noServidor = lancs().last.dados;
    }
    expect(noServidor!['pago'], 0);
    expect(noServidor['despago'], 1);
    // Aparelho B: paga localmente, nunca viu o despagar; ao abrir recebe o registro e obedece.
    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('r8')))
        .write(const TransactionsCompanion(paid: Value(true)));
    cliente.servidor.add(Registro('lancamentos', 'cashew:r8', noServidor, _futuro(), null));
    await sync();
    expect((await _txs()).singleWhere((t) => t.transactionPk == 'r8').paid, false);
    for (var i = 0; i < 2; i++) {
      cliente.enviados.clear();
      await sync();
      expect(lancs().where((r) => r.dados!['pago'] == 1), isEmpty);
    }
    // Pagar de novo: sai pago 1 sem despago.
    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('r8')))
        .write(TransactionsCompanion(
            paid: const Value(true),
            dateTimeModified: Value(DateTime.now().add(const Duration(minutes: 5)))));
    cliente.enviados.clear();
    await sync();
    expect(lancs().last.dados!['pago'], 1);
    expect(lancs().last.dados!.containsKey('despago'), false);
  });

  test('agendada que virou lançamento comum em outro aparelho perde o tipo', () async {
    await _categoria('c1', 'Casa');
    await agendada('u2', TransactionSpecialType.upcoming);
    await sync();
    cliente.servidor.add(Registro(
        'lancamentos',
        'cashew:u2',
        {'data': '2026-12-05', 'descricao': 'Aluguel', 'valor': -1500, 'categoria_id': 'cashew:c1'},
        _futuro(),
        null));
    await sync();
    final t = (await _txs()).singleWhere((t) => t.transactionPk == 'u2');
    expect([t.type, t.paid], [null, true]);
  });

  Future<void> orcamento(String pk, String nome,
          {bool arquivado = false, bool absoluto = false}) =>
      database.into(database.budgets).insert(BudgetsCompanion.insert(
          budgetPk: Value(pk),
          name: nome,
          amount: 500,
          startDate: DateTime(2026, 11, 1),
          endDate: DateTime(2026, 11, 30),
          periodLength: 1,
          order: 0,
          archived: Value(arquivado),
          isAbsoluteSpendingLimit: Value(absoluto),
          dateTimeModified: Value(DateTime.now())));

  Future<void> limite(String pk, String orc, String cat, double valor) =>
      database.into(database.categoryBudgetLimits).insert(
          CategoryBudgetLimitsCompanion.insert(
              categoryLimitPk: Value(pk),
              categoryFk: cat,
              budgetFk: orc,
              amount: valor,
              dateTimeModified: Value(DateTime.now())));

  Iterable<Registro> _de(String tabela) =>
      _semCatsMb(cliente.enviados).where((r) => r.tabela == tabela);

  Future<Budget> _orc(String pk) => (database.select(database.budgets)
        ..where((b) => b.budgetPk.equals(pk)))
      .getSingle();

  test('limite por categoria vai no push com ids prefixados e não é reenviado', () async {
    await _categoria('c1', 'Mercado');
    await orcamento('b1', 'Casa');
    await limite('l1', 'b1', 'c1', 30);
    await limite('l2', 'sumiu', 'c1', 10); // orçamento inexistente: fica fora
    await sync();
    final l = _de('limites').single;
    expect(l.id, 'cashew:l1');
    expect(_semLinha(l.dados), {'orcamento_id': 'cashew:b1', 'categoria_id': 'cashew:c1', 'valor': 30});
    cliente.enviados.clear();
    await sync();
    expect(_de('limites'), isEmpty);
    expect(cliente.enviados.where((r) => r.deletedAt != null && r.tabela == 'limites'), isEmpty);
  });

  test('limite remoto chega junto com o orçamento, é aplicado e não volta', () async {
    await _categoria('c1', 'Mercado');
    final q = _futuro();
    cliente.servidor.addAll([
      Registro('limites', 'cashew:l3',
          {'orcamento_id': 'cashew:b2', 'categoria_id': 'cashew:c1', 'valor': 25}, q, null),
      Registro('orcamentos', 'cashew:b2',
          {'nome': 'Viagem', 'valor': 900, 'categoria_ids': [], 'periodo': 'ciclo'}, q, null),
    ]);
    await sync();
    final l = (await database.select(database.categoryBudgetLimits).get()).single;
    expect([l.categoryLimitPk, l.budgetFk, l.categoryFk, l.amount], ['l3', 'b2', 'c1', 25.0]);
    cliente.enviados.clear();
    await sync();
    expect(_de('limites'), isEmpty);
  });

  test('exclusão do limite vai como tombstone e a remota apaga o local', () async {
    await _categoria('c1', 'Mercado');
    await orcamento('b1', 'Casa');
    await limite('l1', 'b1', 'c1', 30);
    await limite('l4', 'b1', 'c1', 5);
    await sync();
    cliente.enviados.clear();
    await (database.delete(database.categoryBudgetLimits)
          ..where((x) => x.categoryLimitPk.equals('l1')))
        .go();
    cliente.servidor.add(Registro('limites', 'cashew:l4', null, _futuro(), _futuro()));
    await sync();
    expect(_de('limites').map((r) => [r.id, r.deletedAt != null]), [['cashew:l1', true]]);
    expect(await database.select(database.categoryBudgetLimits).get(), isEmpty);
  });

  test('orçamento arquivado e limite absoluto sincronizam em vez de ficarem de fora', () async {
    await orcamento('b3', 'Antigo', arquivado: true, absoluto: true);
    await orcamento('b4', 'Atual');
    await sync();
    final o = {for (final r in _de('orcamentos')) r.id: r.dados!};
    expect(o['cashew:b3']!['arquivado'], 1);
    expect(o['cashew:b3']!['limite_absoluto'], 1);
    expect(o['cashew:b4']!.containsKey('arquivado'), false);
    cliente.enviados.clear();
    await sync();
    expect(_de('orcamentos'), isEmpty);
    expect(_semCatsMb(cliente.enviados).where((r) => r.deletedAt != null), isEmpty);
  });

  test('desarquivar localmente envia arquivado 0 porque o servidor tinha 1', () async {
    await orcamento('b3', 'Antigo', arquivado: true);
    await sync();
    cliente.enviados.clear();
    await (database.update(database.budgets)..where((b) => b.budgetPk.equals('b3')))
        .write(BudgetsCompanion(
            archived: const Value(false),
            dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
    await sync();
    expect(_de('orcamentos').single.dados!['arquivado'], 0);
  });

  test('orçamento remoto arquivado é aplicado e desarquivado pelo registro seguinte', () async {
    cliente.servidor.add(Registro('orcamentos', 'cashew:b5',
        {'nome': 'Velho', 'valor': 100, 'categoria_ids': [], 'periodo': 'ciclo', 'arquivado': 1, 'limite_absoluto': 1},
        '2026-11-01T10:00:00.000Z', null));
    await sync();
    var b = await _orc('b5');
    expect([b.archived, b.isAbsoluteSpendingLimit], [true, true]);
    cliente.enviados.clear();
    await sync();
    expect(_de('orcamentos'), isEmpty);
    cliente.servidor
      ..clear()
      ..add(Registro('orcamentos', 'cashew:b5',
          {'nome': 'Velho', 'valor': 100, 'categoria_ids': [], 'periodo': 'ciclo', 'arquivado': 0, 'limite_absoluto': 1},
          '2026-11-02T10:00:00.000Z', null));
    await sync();
    b = await _orc('b5');
    expect(b.archived, false);
    cliente.enviados.clear();
    await sync();
    expect(_de('orcamentos'), isEmpty);
  });

  test('registro de orçamento sem os campos novos não muda o estado local', () async {
    await orcamento('b6', 'Casa', arquivado: true);
    cliente.servidor.add(Registro('orcamentos', 'cashew:b6',
        {'nome': 'Casa 2', 'valor': 700, 'categoria_ids': [], 'periodo': 'ciclo'}, _futuro(), null));
    await sync();
    final b = await _orc('b6');
    expect([b.name, b.archived], ['Casa 2', true]);
  });

  group('título e nota de transação mb:', () {
    Future<void> editar({String? nome, String? nota}) async {
      await (database.update(database.transactions)
            ..where((t) => t.transactionPk.equals('mb:t1')))
          .write(TransactionsCompanion(
              name: nome == null ? const Value.absent() : Value(nome),
              note: nota == null ? const Value.absent() : Value(nota),
              dateTimeModified:
                  Value(DateTime.now().add(const Duration(seconds: 5)))));
    }

    test('título e nota editados sobem em ajustes uma vez só', () async {
      cliente.extra = banco();
      await sync();
      // Sem edição, o texto do banco não viaja.
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
      await editar(nome: 'Padaria da esquina', nota: 'pão do café');
      cliente.enviados.clear();
      await sync();
      final aj = cliente.enviados.singleWhere((r) => r.tabela == 'ajustes');
      expect(aj.dados!['nome'], 'Padaria da esquina');
      expect(aj.dados!['nota'], 'pão do café');
      cliente.enviados.clear();
      await sync();
      expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
    });

    test('título editado em outro aparelho é aplicado, sobrevive ao pull e não volta', () async {
      cliente.extra = banco();
      await sync();
      cliente.servidor.add(Registro('ajustes', 't1',
          {'nome': 'Padaria 2', 'nota': 'nota remota'}, _futuro(), null));
      cliente.enviados.clear();
      await sync();
      var t = (await _txs()).single;
      expect([t.name, t.note], ['Padaria 2', 'nota remota']);
      for (var i = 0; i < 2; i++) {
        cliente.enviados.clear();
        await sync();
        expect(cliente.enviados.where((r) => r.tabela == 'ajustes'), isEmpty);
      }
      t = (await _txs()).single;
      expect([t.name, t.note], ['Padaria 2', 'nota remota']);
    });

    test('instalação nova: transação do banco já nasce com o título do ajuste', () async {
      cliente.servidor.add(Registro('ajustes', 't1',
          {'nome': 'Padaria 3', 'nota': 'minha nota'}, _futuro(), null));
      cliente.extra = banco();
      await sync();
      final t = (await _txs()).singleWhere((t) => t.transactionPk == 'mb:t1');
      expect([t.name, t.note], ['Padaria 3', 'minha nota']);
    });
  });

  group('configurações', () {
    List<Registro> configs() =>
        cliente.enviados.where((r) => r.tabela == 'configuracoes').toList();

    setUp(() async {
      sharedPreferences = await SharedPreferences.getInstance();
      appStateSettings = {
        'cyclePeriodLength': 1,
        'showNetWorth': false,
        'homePageOrder': ['a', 'b'],
        'font': 'Geist',
      };
    });

    test('só o que difere do padrão sobe; fora da lista nunca sobe; segunda rodada não reenvia', () async {
      appStateSettings['cyclePeriodLength'] = 3;
      appStateSettings['font'] = 'Outra';
      await sync();
      final ids = configs().map((r) => r.id).toSet();
      expect(ids, containsAll(['cyclePeriodLength', 'homePageOrder']));
      expect(ids, isNot(contains('font')));
      expect(ids, isNot(contains('showNetWorth')));
      expect(configs().singleWhere((r) => r.id == 'cyclePeriodLength').dados!['valor'], '3');
      cliente.enviados.clear();
      await sync();
      expect(configs(), isEmpty);
    });

    test('mudar localmente sobe de novo e voltar ao padrão propaga o padrão', () async {
      appStateSettings['cyclePeriodLength'] = 3;
      await sync();
      appStateSettings['cyclePeriodLength'] = 1;
      cliente.enviados.clear();
      await sync();
      expect(configs().single.dados!['valor'], '1');
      cliente.enviados.clear();
      await sync();
      expect(configs(), isEmpty);
    });

    test('configuração remota é aplicada, não volta e chave fora da lista é ignorada', () async {
      cliente.servidor.addAll([
        Registro('configuracoes', 'showNetWorth', {'valor': 'true'}, _futuro(), null),
        Registro('configuracoes', 'homePageOrder', {'valor': '["x","y","z"]'}, _futuro(), null),
        Registro('configuracoes', 'font', {'valor': '"Remota"'}, _futuro(), null),
      ]);
      await sync();
      expect(appStateSettings['showNetWorth'], true);
      expect(appStateSettings['homePageOrder'], ['x', 'y', 'z']);
      expect(appStateSettings['font'], 'Geist');
      cliente.enviados.clear();
      await sync();
      expect(configs(), isEmpty);
    });
  });

  group('linha (linha Drift completa)', () {
    // Passa o que este aparelho enviou para um aparelho novo (banco vazio), como se viesse do servidor.
    Future<void> outroAparelho() async {
      final vindos = [
        for (final r in cliente.enviados)
          Registro(r.tabela, r.id, r.dados, _futuro(), r.deletedAt == null ? null : _futuro())
      ];
      await database.close();
      database = FinanceDatabase(NativeDatabase.memory());
      cliente.enviados.clear();
      cliente.servidor
        ..clear()
        ..addAll(vindos);
    }

    const manuais = {
      'carteiras', 'categorias', 'orcamentos', 'limites', 'metas', 'dividas', 'lancamentos', 'regras'
    };
    Iterable<Registro> manuaisEnviados() =>
        _semCatsMb(cliente.enviados).where((r) => manuais.contains(r.tabela));

    test('ida e volta preserva as colunas e não gera reenvio', () async {
      final modificado = DateTime.now();
      await database.into(database.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('w1'),
          name: 'Inter',
          order: 3,
          colour: const Value('0xff112233'),
          dateTimeModified: Value(modificado)));
      await _categoria('c1', 'Mercado');
      await _categoria('c2', 'Feira');
      await database.into(database.budgets).insert(BudgetsCompanion.insert(
          budgetPk: const Value('b1'),
          name: 'Casa',
          amount: 500,
          startDate: DateTime(2026, 3, 2, 12),
          endDate: DateTime(2026, 3, 15, 12),
          periodLength: 2,
          order: 4,
          colour: const Value('0xffaa0000'),
          reoccurrence: const Value(BudgetReoccurence.weekly),
          pinned: const Value(true),
          walletFks: const Value(['w1']),
          categoryFks: const Value(['c1']),
          budgetTransactionFilters:
              const Value([BudgetTransactionFilters.includeIncome]),
          dateTimeModified: Value(modificado)));
      for (final (pk, par, valor) in [('t1', 't2', -50.0), ('t2', 't1', 50.0)]) {
        await database.into(database.transactions).insert(
            TransactionsCompanion.insert(
                transactionPk: Value(pk),
                name: 'Transferência',
                amount: valor,
                note: '',
                categoryFk: 'c1',
                subCategoryFk: Value(pk == 't1' ? 'c2' : null),
                pairedTransactionFk: Value(par),
                walletFk: const Value('w1'),
                income: Value(valor > 0),
                dateCreated: Value(DateTime(2026, 3, 5, 9)),
                dateTimeModified: Value(modificado)));
      }
      await database.into(database.objectives).insert(ObjectivesCompanion.insert(
          objectivePk: const Value('m1'),
          name: 'Viagem',
          amount: 2000,
          order: 7,
          archived: const Value(true),
          pinned: const Value(true),
          emojiIconName: const Value('🏖️'),
          colour: const Value('0xff00aa00'),
          dateTimeModified: Value(modificado)));
      await sync();
      expect(manuaisEnviados().every((r) => r.dados!['linha'] != null), true);
      await outroAparelho();
      await sync();

      final w = (await database.getWalletInstanceOrNull('w1'))!;
      expect((w.colour, w.order), ('0xff112233', 3));
      final b = await (database.select(database.budgets)
            ..where((x) => x.budgetPk.equals('b1')))
          .getSingle();
      expect(b.colour, '0xffaa0000');
      expect(b.startDate, DateTime(2026, 3, 2, 12));
      expect(b.endDate, DateTime(2026, 3, 15, 12));
      expect((b.periodLength, b.reoccurrence, b.pinned, b.order),
          (2, BudgetReoccurence.weekly, true, 4));
      expect(b.walletFks, ['w1']);
      expect(b.categoryFks, ['c1']);
      expect(b.budgetTransactionFilters, [BudgetTransactionFilters.includeIncome]);
      final t1 = (await _txs()).singleWhere((t) => t.transactionPk == 't1');
      expect((t1.subCategoryFk, t1.pairedTransactionFk, t1.walletFk),
          ('c2', 't2', 'w1'));
      final m = await (database.select(database.objectives)
            ..where((x) => x.objectivePk.equals('m1')))
          .getSingle();
      expect((m.archived, m.pinned, m.emojiIconName, m.colour, m.order),
          (true, true, '🏖️', '0xff00aa00', 7));

      // Sem eco nem reenvio infinito nas rodadas seguintes.
      expect(manuaisEnviados(), isEmpty);
      for (var i = 0; i < 2; i++) {
        cliente.enviados.clear();
        await sync();
        expect(manuaisEnviados(), isEmpty);
      }
    });

    test('registro sem linha (app antigo ou painel) continua sendo aplicado', () async {
      await _categoria('c1', 'Mercado');
      cliente.servidor.add(Registro('categorias', 'cashew:c1',
          {'nome': 'Supermercado', 'tipo': 'despesa', 'linha': 'lixo'}, _futuro(), null));
      await sync();
      expect((await database.getCategoryInstanceOrNull('c1'))!.name, 'Supermercado');
    });

    test('lançamento usa a carteira da linha; sem a carteira cai na 0 e é religado depois', () async {
      await _categoria('c1', 'Mercado');
      Map<String, dynamic> linhaTx(String carteira) => {
            'transactionPk': 't1',
            'pairedTransactionFk': null,
            'name': 'Feira',
            'amount': -20.0,
            'note': '',
            'categoryFk': 'c1',
            'subCategoryFk': null,
            'walletFk': carteira,
            'dateCreated': DateTime(2026, 3, 5, 9).millisecondsSinceEpoch,
            'originalDateDue': DateTime(2026, 3, 5, 9).millisecondsSinceEpoch,
            'income': false,
            'periodLength': null,
            'reoccurrence': null,
            'endDate': null,
            'upcomingTransactionNotification': null,
            'type': null,
            'paid': true,
            'createdAnotherFutureTransaction': null,
            'skipPaid': false,
            'objectiveFk': null,
            'objectiveLoanFk': null,
            'budgetFksExclude': null,
          };
      cliente.servidor.add(Registro(
          'lancamentos',
          'cashew:t1',
          {
            'data': '2026-03-05',
            'descricao': 'Feira',
            'valor': -20,
            'categoria_id': 'cashew:c1',
            'carteira': 'Nome que não bate',
            'linha': linhaTx('w1')
          },
          _futuro(),
          null));
      await sync();
      expect((await _txs()).single.walletFk, '0');
      cliente.servidor.add(Registro('carteiras', 'cashew:w1', {'nome': 'Outro nome'}, _futuro(), null));
      await sync();
      // A carteira chegou com nome diferente do `carteira` do lançamento: valeria a religação por nome;
      // com a linha, uma nova versão do lançamento aponta direto para a carteira pelo pk.
      cliente.servidor
        ..removeWhere((r) => r.tabela == 'lancamentos')
        ..add(Registro(
            'lancamentos',
            'cashew:t1',
            {
              'data': '2026-03-05',
              'descricao': 'Feira',
              'valor': -20,
              'categoria_id': 'cashew:c1',
              'carteira': 'Outro nome',
              'linha': linhaTx('w1')
            },
            DateTime.now().add(const Duration(hours: 2)).toUtc().toIso8601String(),
            null));
      await sync();
      expect((await _txs()).single.walletFk, 'w1');
    });

    test('assinatura com linha: ocorrência paga continua paga e título vazio continua vazio', () async {
      await _categoria('c1', 'Streaming');
      final pago = DateTime(2026, 8, 20, 9).millisecondsSinceEpoch;
      cliente.servidor.add(Registro(
          'assinaturas',
          'cashew:s1',
          {
            'nome': 'Sem nome',
            'valor': 20.9,
            'dia': 20,
            'categoria_id': 'cashew:c1',
            'linha': {
              'transactionPk': 's1',
              'name': '',
              'amount': -20.9,
              'note': '',
              'categoryFk': 'c1',
              'walletFk': '0',
              'dateCreated': pago,
              'originalDateDue': pago,
              'income': false,
              'periodLength': 1,
              'reoccurrence': 3,
              'type': 1,
              'paid': true,
              'createdAnotherFutureTransaction': true,
              'skipPaid': false,
            }
          },
          _futuro(),
          null));
      await sync();
      final t = (await _txs()).single;
      expect(t.paid, true);
      expect(t.name, '');
      expect(t.dateCreated, DateTime.fromMillisecondsSinceEpoch(pago));
      cliente.enviados.clear();
      await sync();
      expect(_semCatsMb(cliente.enviados), isEmpty);
    });

    test('acima de 7500 bytes a linha não vai; abaixo vai sem as colunas de aparelho', () {
      final pequeno = mbComLinha({'nome': 'x'},
          {'name': 'x', 'dateTimeModified': 1, 'sharedKey': 'k', 'methodAdded': 1});
      expect(pequeno['linha'], {'name': 'x'});
      final grande = mbComLinha({'nome': 'x'}, {'categoryFks': 'y' * 8000});
      expect(grande, {'nome': 'x'});
    });

    test('só a linha difere (primeira rodada após atualizar): regrava o espelho sem enviar', () {
      final antigo = {'nome': 'Casa', 'valor': 5};
      final atual = Projetado('orcamentos', 'cashew:b1', {...antigo, 'linha': {'name': 'Casa'}}, null);
      final reg = Registro('orcamentos', 'cashew:b1', antigo, '2026-01-01T00:00:00.000Z', null);
      final soLinha = <Espelho>[];
      final m = detectarMudancasLocais(
          espelho: {atual.chave: Espelho(reg, antigo, false, null)},
          atuais: {atual.chave: atual},
          agora: '2026-11-18T12:00:00.000Z',
          soLinha: soLinha);
      expect(m, isEmpty);
      expect(soLinha.single.pendente, false);
      expect(soLinha.single.projecao!.containsKey('linha'), true);
      // Edição real de coluna fora do mapeado (linha mudou e o espelho já tinha linha) continua sendo enviada.
      final comLinha = {...antigo, 'linha': {'name': 'Casa', 'colour': 'a'}};
      final editado = Projetado('orcamentos', 'cashew:b1', {...antigo, 'linha': {'name': 'Casa', 'colour': 'b'}}, null);
      final m2 = detectarMudancasLocais(
          espelho: {editado.chave: Espelho(reg, comLinha, false, null)},
          atuais: {editado.chave: editado},
          agora: '2026-11-18T12:00:00.000Z');
      expect(m2, hasLength(1));
    });

    test('linha antiga do painel não sobrescreve campo mapeado editado', () async {
      await database.into(database.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('w1'),
          name: 'Inter',
          order: 3,
          colour: const Value('0xff112233'),
          dateTimeModified: Value(DateTime.now())));
      await sync();
      await outroAparelho();
      final r = cliente.servidor.singleWhere((x) => x.tabela == 'carteiras');
      cliente.servidor
        ..clear()
        ..add(Registro('carteiras', r.id, {...r.dados!, 'cor': '0xff999999'}, _futuro(), null));
      await sync();
      expect((await database.getWalletInstanceOrNull('w1'))!.colour, '0xff999999');
    });

    test('tamanho final acima de 8000 bytes tira a linha mesmo com campos da base', () {
      final p = Projetado('orcamentos', 'cashew:b1', {'nome': 'x', 'linha': {'name': 'x'}}, null);
      final d = dadosParaEnvio(p, {'extra': 'y' * 8100});
      expect(d.containsKey('linha'), false);
      expect(dadosParaEnvio(p, {'extra': 'y'}).containsKey('linha'), true);
    });

    test('projeção sem linha não herda a linha antiga do servidor', () {
      final p = Projetado('orcamentos', 'cashew:b1', {'nome': 'Casa'}, null);
      final dados = dadosParaEnvio(p, {'nome': 'Velho', 'linha': {'name': 'Velho'}});
      expect(dados.containsKey('linha'), false);
      expect(dados['nome'], 'Casa');
    });
  });

  group('configurações ampliadas', () {
    test('todas as chaves da lista existem nas preferências padrão', () async {
      final padrao = await getDefaultPreferences();
      // carteirasArquivadas já existia na lista e é criada só quando há carteira arquivada.
      expect(mbConfigsSincronizadas.where((k) => !padrao.containsKey(k)),
          {'carteirasArquivadas'});
      expect(
          mbConfigsSincronizadas,
          containsAll([
            'selectedPeriodCycleTypePieChart',
            'customPeriodPastDaysNetWorth',
            'cycleStartDateCreditDebts',
            'customCurrencies',
            'percentagePrecision',
            'customNavBarShortcut2',
            'username'
          ]));
      expect(mbConfigsSincronizadas.contains('theme'), false);
      expect(mbConfigsSincronizadas.contains('selectedWalletPk'), false);
    });

    test('chave nova sobe quando difere do padrão e a remota é aplicada', () async {
      sharedPreferences = await SharedPreferences.getInstance();
      appStateSettings = {
        'percentagePrecision': 7,
        'cyclePeriodLengthNetWorth': 4,
        'username': '',
      };
      cliente.servidor.add(Registro(
          'configuracoes', 'username', {'valor': '"Renan"'}, _futuro(), null));
      await sync();
      final ids = cliente.enviados
          .where((r) => r.tabela == 'configuracoes')
          .map((r) => r.id)
          .toSet();
      expect(ids, containsAll(['percentagePrecision', 'cyclePeriodLengthNetWorth']));
      expect(appStateSettings['username'], 'Renan');
    });
  });

  group('cópia única', () {
    final servidorAntigo = '2026-01-01T00:00:00.000Z';
    Registro viv(String tabela, String id) =>
        Registro(tabela, id, {'nome': id}, servidorAntigo, null);

    test('planejamento: envia tudo com updated_at agora e apaga só tabela manual ausente', () {
      const agora = '2026-11-18T12:00:00.000Z';
      final atuais = {
        for (final p in [
          Projetado('categorias', 'cashew:c1', {'nome': 'Mercado'}, null),
          Projetado('ajustes', 'a1', {'nome': 'x'}, null),
          Projetado('lancamentos', 'cashew:t1', {'valor': 1}, '2026-02-01T00:00:00.000Z'),
        ])
          p.chave: p
      };
      final plano = mbPlanejarOficial(
        atuais: atuais,
        servidor: [
          viv('categorias', 'cashew:c1'),
          viv('categorias', 'cashew:c9'),
          viv('lancamentos', 'cashew:t9'),
          viv('assinaturas', 'cashew:s1'),
          viv('revisoes', 'x'),
          viv('ajustes', 'y'),
          viv('configuracoes', 'font'),
          viv('limites', 'cashew:l1'),
          Registro('carteiras', 'cashew:w1', null, servidorAntigo, servidorAntigo),
        ],
        existentes: {'limites/cashew:l1'},
        agora: agora,
      );
      // Ajustes não entram no "oficial".
      expect(plano.registros.any((r) => r.tabela == 'ajustes'), false);
      expect(plano.enviados, 2);
      expect(plano.apagados, 3);
      expect(plano.registros.every((r) => r.updatedAt == agora), true);
      final apagados = plano.registros.where((r) => r.deletedAt != null);
      expect({for (final r in apagados) r.chave},
          {'categorias/cashew:c9', 'lancamentos/cashew:t9', 'assinaturas/cashew:s1'});
      expect(apagados.every((r) => r.dados == null && r.deletedAt == agora), true);
      // O que o servidor já guardava e este aparelho não projeta é preservado (como no envio normal).
      expect(plano.registros.firstWhere((r) => r.chave == 'categorias/cashew:c1').dados,
          {'nome': 'Mercado'});
    });

    test('tornar oficial envia tudo (inclusive configuração padrão), apaga o que falta e não reenvia', () async {
      sharedPreferences = await SharedPreferences.getInstance();
      appStateSettings = {'showNetWorth': false};
      await _categoria('c1', 'Mercado');
      await database.into(database.transactions).insert(TransactionsCompanion.insert(
          transactionPk: const Value('t1'),
          name: 'x',
          amount: -1,
          note: '',
          categoryFk: 'c1',
          dateTimeModified: Value(DateTime.now())));
      cliente.servidor.addAll([viv('categorias', 'cashew:c9'), viv('revisoes', 'r1')]);
      final antes = DateTime.now().toUtc().toIso8601String();
      final r = await mbTornarOficial(cliente);
      expect(r.apagados, 1);
      expect(r.enviados, greaterThan(1));
      expect(r.rejeitados, isEmpty);
      final c1 = cliente.enviados.singleWhere((x) => x.id == 'cashew:c1');
      expect(c1.updatedAt.compareTo(antes) >= 0, true);
      expect(cliente.enviados.singleWhere((x) => x.id == 'cashew:c9').deletedAt, isNotNull);
      expect(cliente.enviados.any((x) => x.tabela == 'revisoes'), false);
      expect(cliente.enviados.any((x) => x.tabela == 'configuracoes' && x.id == 'showNetWorth'), true);
      expect((await mbLerFila()).pendentes, 0);
      // Sincronizar depois não reenvia nem traz de volta a categoria apagada.
      cliente.enviados.clear();
      await sync();
      expect(_semCatsMb(cliente.enviados).where((x) => x.tabela != 'configuracoes'), isEmpty);
      expect(await database.getCategoryInstanceOrNull('c9'), isNull);
    });

    test('recomeçar pela nuvem apaga o local, limpa espelho e cursor e baixa do servidor', () async {
      await _categoria('c1', 'Mercado');
      await _categoria('c-local', 'Só aqui');
      await database.into(database.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('w-local'), name: 'Local', order: 2));
      await database.into(database.transactions).insert(TransactionsCompanion.insert(
          transactionPk: const Value('t-local'),
          name: 'x',
          amount: -1,
          note: '',
          categoryFk: 'c1',
          dateTimeModified: Value(DateTime.now())));
      await sync();
      await mbGravarEstado({'cursor': 'antigo'});
      cliente.servidor
        ..clear()
        ..addAll([
          Registro('categorias', 'cashew:c1',
              {'nome': 'Mercado', 'tipo': 'despesa'}, servidorAntigo, null),
          Registro('lancamentos', 'cashew:t1', {
            'data': '2026-03-05',
            'descricao': 'Feira',
            'valor': -20,
            'categoria_id': 'cashew:c1'
          }, servidorAntigo, null)
        ]);
      final erro = await mbRecomecarPelaNuvem(cliente);
      expect(erro, isNull);
      expect(await database.getCategoryInstanceOrNull('c-local'), isNull);
      expect(await database.getWalletInstanceOrNull('w-local'), isNull);
      expect((await _txs()).where((t) => t.transactionPk == 't-local'), isEmpty);
      expect(await database.getCategoryInstanceOrNull('c1'), isNotNull);
      final espelho = await mbLerEspelho();
      expect(espelho.keys.where((k) => k.contains('c-local') || k.contains('t-local')), isEmpty);
      expect(await mbLerEstado('cursor'), isNot('antigo'));
    });

    test('recomeçar recusa se o servidor só tem categorias (sem lançamentos)', () async {
      await _categoria('c1', 'Mercado');
      cliente.servidor.add(viv('categorias', 'cashew:c9'));
      final erro = await mbRecomecarPelaNuvem(cliente);
      expect(erro, contains('lançamentos e categorias'));
      expect(await database.getCategoryInstanceOrNull('c1'), isNotNull);
      expect(await database.getCategoryInstanceOrNull('c9'), isNull);
    });

    test('tornar oficial recusa aparelho sem lançamentos e não envia nada', () async {
      await _categoria('c1', 'Mercado');
      cliente.servidor.add(viv('lancamentos', 'cashew:t9'));
      await expectLater(mbPrepararOficial(cliente), throwsA(isA<MbRecusado>()));
      expect(cliente.enviados, isEmpty);
    });

    test('rejeitado no oficial continua pendente e é informado', () async {
      await _categoria('c1', 'Mercado');
      await database.into(database.transactions).insert(TransactionsCompanion.insert(
          transactionPk: const Value('t1'),
          name: 'x',
          amount: -1,
          note: '',
          categoryFk: 'c1',
          dateTimeModified: Value(DateTime.now())));
      cliente.rejeitarTabelas.add('lancamentos');
      final r = await mbTornarOficial(cliente);
      expect(r.rejeitados, hasLength(1));
      expect(r.rejeitados.single, contains('lancamentos'));
      final fila = await mbPendentes();
      expect(fila.map((e) => e.registro.tabela), ['lancamentos']);
    });

    test('regra com título vazio não vira tombstone no oficial', () async {
      await _categoria('c1', 'Mercado');
      await database.into(database.transactions).insert(TransactionsCompanion.insert(
          transactionPk: const Value('t1'),
          name: 'x',
          amount: -1,
          note: '',
          categoryFk: 'c1',
          dateTimeModified: Value(DateTime.now())));
      await database.into(database.associatedTitles).insert(
          AssociatedTitlesCompanion.insert(
              associatedTitlePk: const Value('r1'),
              categoryFk: 'c1',
              title: '',
              order: 0));
      cliente.servidor.add(viv('regras', 'cashew:r1'));
      final r = await mbTornarOficial(cliente);
      expect(r.apagados, 0);
      expect(cliente.enviados.where((x) => x.tabela == 'regras'), isEmpty);
    });

    test('operação de rodada espera a rodada em curso e bloqueia o sync periódico', () async {
      final ordem = <String>[];
      final liberar = Completer<void>();
      final longa = mbEmRodada(() async {
        ordem.add('inicio');
        await liberar.future;
        ordem.add('fim');
      });
      await Future<void>.delayed(Duration.zero);
      final periodico = sincronizarMeuBanco(clienteParaTeste: cliente)
          .then((_) => ordem.add('sync'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ordem, ['inicio']);
      liberar.complete();
      await longa;
      await periodico;
      expect(ordem, ['inicio', 'fim', 'sync']);
    });

    test('recomeçar pela nuvem recusa e não apaga nada se o servidor está vazio', () async {
      await _categoria('c1', 'Mercado');
      final erro = await mbRecomecarPelaNuvem(cliente);
      expect(erro, contains('Enviar tudo como oficial'));
      expect(await database.getCategoryInstanceOrNull('c1'), isNotNull);
    });
  });
}
