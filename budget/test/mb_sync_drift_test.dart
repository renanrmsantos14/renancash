import 'dart:async';
import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/categoriaEfetiva.dart' show MbContextoCategoria;
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/contextoLocal.dart';
import 'package:budget/struct/mbSync/espelho.dart' show mbEspelhoDescarregarEstado;
import 'package:budget/struct/mbSync/espelhoTriggers.dart' show mbEspelhoDefinirAtivo;
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/mbSync/pareamento.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/settings.dart' show appStateSettings;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cliente falso: só o pull do banco (`GET /api/sync`); o espelho tem os próprios testes.
class ClienteFalso extends MbCliente {
  ClienteFalso() : super(base: 'https://teste');
  Map<String, dynamic> extra = {};
  final desdes = <String?>[];

  @override
  Future<Map<String, dynamic>> puxar(String? desde) async {
    desdes.add(desde);
    return {
      'agora': DateTime.now().toUtc().toIso8601String(),
      'contas': [],
      'transacoes': [],
      'pendentes': [],
      ...extra,
    };
  }
}

Future<void> _categoria(String pk, String nome, {bool receita = false}) =>
    database.into(database.categories).insert(CategoriesCompanion.insert(
        categoryPk: Value(pk),
        name: nome,
        order: 0,
        income: Value(receita),
        dateTimeModified: Value(DateTime.now())));

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
    appStateSettings.remove('mbEspelho');
    mbEspelhoDescarregarEstado();
  });

  tearDown(() async {
    appStateSettings.remove('mbEspelho');
    await database.close();
  });

  Future<void> sync() async {
    final ok = await sincronizarMeuBanco(clienteParaTeste: cliente);
    expect(ok, true, reason: meuBancoUltimoErro.value);
  }

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
  test('trocar de conta apaga o espelho e o importado, e preserva o que é do RenanCash', () async {
    await _categoria('c1', 'Mercado');
    cliente.extra = banco();
    await sync();
    expect((await _txs()).map((t) => t.transactionPk), contains('mb:t1'));
    expect((await database.select(database.categories).get())
        .where((c) => c.categoryPk.startsWith('mb:cat:')), isNotEmpty);
    expect((await database.select(database.wallets).get())
        .where((w) => w.walletPk.startsWith('mb:')), isNotEmpty);

    await mbTrocarConta();
    expect((await _txs()).where((t) => t.transactionPk.startsWith('mb:')), isEmpty);
    expect(await mbLerEstado('cursor'), isNull);
    expect(await database.getCategoryInstanceOrNull('c1'), isNotNull);
    final cats = await database.select(database.categories).get();
    expect(cats.where((c) => c.categoryPk.startsWith('mb:cat:')), isEmpty);
    expect((await database.select(database.wallets).get())
        .where((w) => w.walletPk.startsWith('mb:')), isEmpty);
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
    cliente.extra = {'contas': [st], 'transacoes': [tx]};
    await sync();
    expect(await database.getWalletInstanceOrNull('mb:st'), isNull);
    expect(await _txs(), isEmpty);
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
  });

  test('categoria editada numa transação mb: sobrevive a um novo pull do banco', () async {
    await _categoria('c1', 'Mercado');
    cliente.extra = banco();
    await sync();
    expect((await _txs()).single.categoryFk, isNot('c1'));
    await (database.update(database.transactions)
          ..where((t) => t.transactionPk.equals('mb:t1')))
        .write(TransactionsCompanion(
            categoryFk: const Value('c1'),
            dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));
    await mbRemoverEstado('cursor');
    await sync();
    await sync();
    expect((await _txs()).single.categoryFk, 'c1');
  });

  test('regra de título (associated_titles) classifica uma transação nova do banco', () async {
    await _categoria('c1', 'Mercado');
    await database.into(database.associatedTitles).insert(AssociatedTitlesCompanion.insert(
        associatedTitlePk: const Value('r1'),
        categoryFk: 'c1',
        title: 'PADARIA',
        order: 0,
        dateCreated: Value(DateTime.now()),
        dateTimeModified: Value(DateTime.now())));
    cliente.extra = banco()..['ciclo'] = <String, dynamic>{};
    await sync();
    expect((await _txs()).single.categoryFk, 'c1');
  });

  Future<void> editar(String pk, {String? nome, String? nota, String? categoria, bool semSub = false}) =>
      (database.update(database.transactions)..where((t) => t.transactionPk.equals(pk))).write(
          TransactionsCompanion(
              name: nome == null ? const Value.absent() : Value(nome),
              note: nota == null ? const Value.absent() : Value(nota),
              categoryFk: categoria == null ? const Value.absent() : Value(categoria),
              subCategoryFk: semSub ? const Value(null) : const Value.absent(),
              dateTimeModified: Value(DateTime.now().add(const Duration(seconds: 5)))));

  Future<void> novoPull() async {
    await mbRemoverEstado('cursor');
    await sync();
  }

  test('título e nota editados numa transação mb: sobrevivem ao pull', () async {
    cliente.extra = banco();
    await sync();
    await editar('mb:t1', nome: 'Padaria da esquina', nota: 'pão do café');
    await novoPull();
    await novoPull();
    final t = (await _txs()).single;
    expect([t.name, t.note], ['Padaria da esquina', 'pão do café']);
  });

  test('transação apagada com o espelho ligado não volta no pull', () async {
    appStateSettings['mbEspelho'] = true;
    await mbEspelhoDefinirAtivo(database, true);
    cliente.extra = banco();
    await sync();
    await (database.delete(database.transactions)..where((t) => t.transactionPk.equals('mb:t1'))).go();
    final apagados = await database.customSelect("SELECT pk FROM mb_apagados WHERE tabela = 'transactions'").get();
    expect(apagados.map((l) => l.read<String>('pk')), ['mb:t1']);
    await novoPull();
    await novoPull();
    expect(await _txs(), isEmpty);
  });

  test('com o espelho desligado o app só puxa o banco e uma exclusão local de mb: pode voltar', () async {
    cliente.extra = banco();
    await sync();
    await (database.delete(database.transactions)..where((t) => t.transactionPk.equals('mb:t1'))).go();
    await novoPull();
    expect((await _txs()).map((t) => t.transactionPk), ['mb:t1']);
  });

  test('primeira carga completa: sem a marca de conversão o pull ignora o cursor, depois volta a usá-lo', () async {
    cliente.extra = banco();
    await sync();
    await mbRemoverEstado('conv_categorias_v1');
    cliente.desdes.clear();
    await sync();
    await sync();
    expect(cliente.desdes.first, isNull);
    expect(cliente.desdes.last, isNotNull);
    expect(await mbLerEstado('conv_categorias_v1'), isNotNull);
  });

  test('transação que passou a ser transferência sai do app', () async {
    cliente.extra = {
      'contas': [{'id': 'a1', 'type': 'BANK', 'name': 'Conta', 'bank': 'Inter'}],
      'transacoes': [
        {'id': 'r1', 'account_id': 'a1', 'date': '2025-01-10', 'description': 'Pix SANTANDER', 'amount': 900.0, 'status': 'POSTED'}
      ],
    };
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
    await novoPull();
    expect(await _txs(), isEmpty);
  });

  test('Reserva de emergência é criada uma única vez e apagada não volta', () async {
    await sync();
    await sync();
    var metas = await database.select(database.objectives).get();
    expect(metas.map((o) => [o.objectivePk, o.name, o.amount, o.endDate, o.pinned]), [
      [mbMetaReservaPk, 'Reserva de emergência', 0.0, null, true]
    ]);
    await database.delete(database.objectives).go();
    await sync();
    expect(await database.select(database.objectives).get(), isEmpty);
  });

  test('série mensal do Worker é guardada; Worker antigo não apaga a série', () async {
    final serie = [
      {'mes': '2026-11', 'itens': [{'id': 'i1', 'nome': 'CDB', 'banco': 'Inter', 'saldo': 1700.5}]},
      {'mes': '2026-10', 'itens': [{'id': 'i1', 'nome': 'CDB', 'banco': 'Inter', 'saldo': 1500}, {'id': 'i2', 'nome': 'Fundo', 'saldo': 200}]},
    ];
    cliente.extra = {
      'investimentos': [{'id': 'i1', 'nome': 'Aplicação i1', 'saldo': 1700.5, 'banco': 'Inter'}],
      'investimentos_mensal': serie,
    };
    await sync();
    var lida = await mbLerSerieMensal();
    expect(lida.map((m) => m.mes), ['2026-10', '2026-11']);
    expect(lida.map((m) => m.total), [1700.0, 1700.5]);
    cliente.extra = {'investimentos': cliente.extra['investimentos']};
    await sync();
    lida = await mbLerSerieMensal();
    expect(lida, hasLength(2));
    expect(mbSerieDeJson('lixo'), isEmpty);
  });

  test('o Geral é criado na sincronização com valor 0', () async {
    await sync();
    final g = await database.getBudgetInstance(mbOrcamentoGeralPk);
    expect([g.name, g.amount], ['Geral', 0]);
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
    final periodico = sincronizarMeuBanco(clienteParaTeste: cliente).then((_) => ordem.add('sync'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ordem, ['inicio']);
    liberar.complete();
    await longa;
    await periodico;
    expect(ordem, ['inicio', 'fim', 'sync']);
  });

  test('mapa Pai › Sub: o pull não desfaz título nem escolha local', () async {
    await _categoria('4', 'Transporte');
    await database.into(database.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('uber'), name: 'Uber', order: 0, mainCategoryPk: const Value('4')));
    await _categoria('c1', 'Trabalho');
    cliente.extra = {
      'contas': [{'id': 'a1', 'type': 'BANK', 'name': 'Conta'}],
      'transacoes': [
        {'id': 't1', 'account_id': 'a1', 'date': '2025-01-10', 'description': 'UBER TRIP', 'amount': -18.0, 'category': 'Taxi and ride-hailing', 'status': 'POSTED'}
      ],
    };
    await sync();
    var t = (await _txs()).single;
    expect([t.categoryFk, t.subCategoryFk, t.name], ['4', 'uber', 'UBER TRIP']);
    await editar('mb:t1', nome: 'Uber para o cliente', categoria: 'c1', semSub: true);
    await novoPull();
    await novoPull();
    t = (await _txs()).single;
    expect([t.categoryFk, t.subCategoryFk, t.name], ['c1', null, 'Uber para o cliente']);
  });

  test('categoria de transação editada só fica fixa quando difere da que o mapeador escolheria', () {
    final ctx = MbContextoCategoria({
      't1': {'categoria_id': 'cashew:c1', 'nome': 'Só o título'},
      't2': {'categoria_id': 'cashew:c2', 'nome': 'Escolhida'},
    }, const [], const {});
    final fixa = mbSoCategoriaDivergente(ctx, {'t1': 'c1', 't2': 'c9'}).ajustes;
    expect(fixa['t1'], {'nome': 'Só o título'});
    expect(fixa['t2'], {'categoria_id': 'cashew:c2', 'nome': 'Escolhida'});
    expect(mbSemCategoriaEditada(ctx).ajustes['t2'], {'nome': 'Escolhida'});
  });

  test('decisões de revisão de mb_registros (antes da F5) são copiadas para mb_revisoes uma vez', () async {
    await mbCriarTabelas();
    await database.customStatement(
        "INSERT INTO mb_registros (tabela, id, dados, updated_at) VALUES ('revisoes', 'x1', '{\"resposta\":\"ok\"}', '2025-01-01T00:00:00Z')");
    await sync();
    expect((await mbLerRevisoes()).map((r) => r.id), ['x1']);
    await database.customStatement('DELETE FROM mb_revisoes');
    await sync();
    expect(await mbLerRevisoes(), isEmpty);
  });
}
