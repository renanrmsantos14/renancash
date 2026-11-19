import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/classificarDados.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

// Confirmar na fila "Para classificar" (lib/struct/mbSync/classificarDados.dart): vínculo com empréstimo/meta e
// várias confirmações de uma vez.
void main() {
  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    database = FinanceDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({'mbNotifCursor': 'x'});
    meuBancoSincronizando.value = false;
    await mbCriarTabelas();
    await database.into(database.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('c1'), name: 'Família', order: 0, dateTimeModified: Value(DateTime.now())));
    for (final (pk, tipo) in [('A', ObjectiveType.loan), ('B', ObjectiveType.loan), ('M', ObjectiveType.goal)]) {
      await database.into(database.objectives).insert(ObjectivesCompanion.insert(
          objectivePk: Value(pk),
          name: 'Objetivo $pk',
          amount: 1000,
          order: 5,
          type: Value(tipo),
          dateTimeModified: Value(DateTime.now())));
    }
    mbOpcoesClassificar = const MbOpcoes([], [
      MbVinculoOpcao('A', 'Pai', 'emprestimo'),
      MbVinculoOpcao('B', 'Mãe', 'emprestimo'),
      MbVinculoOpcao('M', 'Viagem', 'meta'),
    ]);
    mbPadroesClassificar = const [];
  });

  tearDown(() async {
    // O sync solto no fim de mbConfirmarVarios (sem pareamento, termina na hora) precisa acabar antes de fechar o banco.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await database.close();
  });

  Future<void> inserir(String pk, {String? emprestimo, String? meta}) =>
      database.into(database.transactions).insert(TransactionsCompanion.insert(
          transactionPk: Value(pk),
          name: 'Pix',
          amount: -50,
          note: '',
          categoryFk: 'c1',
          walletFk: const Value('0'),
          objectiveLoanFk: Value(emprestimo),
          objectiveFk: Value(meta),
          dateCreated: Value(DateTime(2026, 11, 10)),
          dateTimeModified: Value(DateTime.utc(2000))));

  Future<Transaction> ler(String pk) =>
      (database.select(database.transactions)..where((t) => t.transactionPk.equals(pk))).getSingle();

  MbLancamentoIa lanc(String pk, {MbItemRevisao? revisao}) =>
      MbLancamentoIa(pk: pk, descricao: 'Pix enviado', valor: -50, data: DateTime(2026, 11, 10), revisao: revisao);

  MbSugestao escolha(String pk, {String? vinculo}) =>
      MbSugestao(pk, 'c1', vinculoPk: vinculo, confianca: 1);

  test('trocar o empréstimo A pelo B grava B', () async {
    await inserir('mb:x1', emprestimo: 'A');
    await mbConfirmarClassificacao(lanc('mb:x1'), escolha('mb:x1', vinculo: 'B'), sincronizar: false);
    final t = await ler('mb:x1');
    expect(t.objectiveLoanFk, 'B');
    expect(t.objectiveFk, isNull);
  });

  test('sem vínculo limpa o empréstimo antigo', () async {
    await inserir('mb:x1', emprestimo: 'A');
    await mbConfirmarClassificacao(lanc('mb:x1'), escolha('mb:x1'), sincronizar: false);
    expect((await ler('mb:x1')).objectiveLoanFk, isNull);
  });

  test('trocar de empréstimo para meta (e de meta para empréstimo) zera o outro vínculo', () async {
    await inserir('mb:x1', emprestimo: 'A');
    await mbConfirmarClassificacao(lanc('mb:x1'), escolha('mb:x1', vinculo: 'M'), sincronizar: false);
    var t = await ler('mb:x1');
    expect([t.objectiveFk, t.objectiveLoanFk], ['M', null]);
    await mbConfirmarClassificacao(lanc('mb:x1'), escolha('mb:x1', vinculo: 'A'), sincronizar: false);
    t = await ler('mb:x1');
    expect([t.objectiveFk, t.objectiveLoanFk], [null, 'A']);
  });

  test('confirmar vários grava cada decisão antes de voltar, sem respostas soltas em paralelo', () async {
    for (final id in ['p1', 'p2', 'p3']) {
      await inserir('mb:$id');
    }
    final itens = [
      for (final id in ['p1', 'p2', 'p3'])
        lanc('mb:$id',
            revisao: MbItemRevisao('tx:$id', 'pix_enviado',
                txId: id, data: '2026-11-10', descricao: 'Pix enviado: Pai', valor: 50, destinatario: 'PAI'))
    ];
    await mbConfirmarVarios(itens, escolha('', vinculo: 'A'));
    final espelho = {for (final r in await mbLerRevisoes()) 'revisoes/${r.id}': r};
    for (final id in ['p1', 'p2', 'p3']) {
      expect(espelho['revisoes/tx:$id']?.dados?['categoria_id'], 'cashew:c1', reason: id);
      expect((await ler('mb:$id')).objectiveLoanFk, 'A', reason: id);
    }
  });
}
