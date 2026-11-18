import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/transactionEntry/transactionEntryAmount.dart' show ehAjusteDeSaldo;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

/// Criar conta com saldo: transação "Saldo inicial" (ajuste de saldo, categoria "0") que conta no
/// saldo da conta e fica fora de Entradas/Saídas; saldo 0 não cria nada; ajuste posterior segue igual.
void main() {
  setUpAll(() {
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    database = FinanceDatabase(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  Future<TransactionWallet> criarConta(String nome) async {
    final rowId = await database.createOrUpdateWallet(
        insert: true,
        TransactionWallet(
          walletPk: "-1",
          name: nome,
          dateCreated: DateTime.now(),
          dateTimeModified: null,
          order: 0,
          currency: "BRL",
          decimals: 2,
          homePageWidgetDisplay: null,
        ));
    return database.getWalletFromRowId(rowId);
  }

  Future<AllWallets> todas() async {
    final lista = await database.getAllWallets();
    return AllWallets(list: lista, indexedByPk: {for (final w in lista) w.walletPk: w});
  }

  Future<double> total(TransactionWallet w, {bool? isIncome, bool onlyIncomeAndExpense = false}) async {
    final r = await database
        .watchTotalWithCountOfWallet(
          isIncome: isIncome,
          allWallets: await todas(),
          onlyIncomeAndExpense: onlyIncomeAndExpense,
          includeBalanceCorrection: isIncome == null,
        )
        .first;
    return r?.total ?? 0;
  }

  test('aviso de conta criada não diz "Saldo corrigido"', () {
    final aviso = avisoContaCriada('Inter', 'R\$ 10.000,00');
    expect(aviso.titulo, 'Conta criada');
    expect(aviso.descricao, 'Inter · saldo inicial R\$ 10.000,00');
    expect(aviso.titulo, isNot(contains('corrigido')));
  });

  test('conta com R\$ 1.000: transação "Saldo inicial", saldo 1.000, fora de Entradas/Saídas', () async {
    final conta = await criarConta('Inter');
    final pk = await criarSaldoInicialDaConta(conta, 1000, note: 'Saldo inicial');
    expect(pk, isNotNull);

    final t = (await database.select(database.transactions).get()).single;
    expect(t.name, 'Saldo inicial');
    expect(t.categoryFk, '0');
    expect(t.amount, 1000);
    expect(t.walletFk, conta.walletPk);
    expect(ehAjusteDeSaldo(t), true);

    // Saldo da conta (líquido, com ajuste): 1.000.
    expect(await total(conta), 1000);
    // Resumo do mês: nem entrada nem saída.
    expect(await total(conta, isIncome: true), 0);
    expect(await total(conta, isIncome: false), 0);
    expect(await total(conta, onlyIncomeAndExpense: true), 0);
  });

  test('saldo 0 não cria transação', () async {
    final conta = await criarConta('Inter');
    expect(await criarSaldoInicialDaConta(conta, 0), isNull);
    expect(await database.select(database.transactions).get(), isEmpty);
  });

  test('ajuste de saldo posterior mantém o nome e também fica fora de Entradas/Saídas', () async {
    final conta = await criarConta('Inter');
    await criarSaldoInicialDaConta(conta, 1000);
    await createCorrectionTransaction(250, conta,
        title: 'Ajuste de saldo', note: 'x');

    final nomes = (await database.select(database.transactions).get())
        .map((t) => t.name)
        .toSet();
    expect(nomes, {'Saldo inicial', 'Ajuste de saldo'});
    expect(await total(conta), 1250);
    expect(await total(conta, isIncome: true), 0);
    expect(await total(conta, isIncome: false), 0);
  });

  test('gasto comum continua nas saídas ao lado do saldo inicial', () async {
    final conta = await criarConta('Inter');
    await database.into(database.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('1'),
        name: 'Mercado',
        order: 0,
        income: const Value(false),
        dateTimeModified: Value(DateTime.now())));
    await criarSaldoInicialDaConta(conta, 1000);
    await database.createOrUpdateTransaction(
      insert: true,
      updateSharedEntry: false,
      Transaction(
        transactionPk: "-1",
        name: 'Mercado',
        amount: -40,
        note: '',
        categoryFk: '1',
        walletFk: conta.walletPk,
        dateCreated: DateTime.now(),
        income: false,
        paid: true,
        skipPaid: false,
      ),
    );
    expect(await total(conta), 960);
    expect(await total(conta, isIncome: false), -40);
    expect(await total(conta, isIncome: true), 0);
  });
}
