import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/pareamento.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cliente falso: só o pull do banco (`GET /api/sync`); o espelho tem os próprios testes.
class ClienteFalso extends MbCliente {
  ClienteFalso() : super(base: 'https://teste');
  Map<String, dynamic> extra = {};

  @override
  Future<Map<String, dynamic>> puxar(String? desde) async => {
        'agora': DateTime.now().toUtc().toIso8601String(),
        'contas': [],
        'transacoes': [],
        'pendentes': [],
        ...extra,
      };
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
  });

  tearDown(() => database.close());

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
}
