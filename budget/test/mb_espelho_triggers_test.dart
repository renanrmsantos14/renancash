import 'dart:ffi';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/espelhoTriggers.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

Future<List<String>> _fila(FinanceDatabase db) async => [
      for (final l in await db
          .customSelect('SELECT tabela, pk FROM mb_saida ORDER BY tabela, pk')
          .get())
        '${l.read<String>('tabela')}|${l.read<String>('pk')}'
    ];

Future<void> _limpar(FinanceDatabase db) => db.customStatement('DELETE FROM mb_saida');

Future<void> _categoria(FinanceDatabase db, String pk, {String nome = 'Mercado'}) =>
    db.into(db.categories).insert(CategoriesCompanion.insert(
        categoryPk: Value(pk), name: nome, order: 0, dateTimeModified: Value(DateTime.now())));

Future<List<String>> _triggers(FinanceDatabase db, String tabela) async => [
      for (final l in await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'mb\\_esp\\_${tabela}\\_%' ESCAPE '\\'")
          .get())
        l.read<String>('name')
    ];

void main() {
  late FinanceDatabase db;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    database = db = FinanceDatabase(NativeDatabase.memory());
    await mbEspelhoDefinirAtivo(db, true);
  });

  tearDown(() => db.close());

  test('insert, update e delete enfileiram a linha', () async {
    await _categoria(db, 'c1');
    expect(await _fila(db), ['categories|c1']);
    await _limpar(db);
    await (db.update(db.categories)..where((c) => c.categoryPk.equals('c1')))
        .write(const CategoriesCompanion(name: Value('Feira')));
    expect(await _fila(db), ['categories|c1']);
    await _limpar(db);
    await (db.delete(db.categories)..where((c) => c.categoryPk.equals('c1'))).go();
    expect(await _fila(db), ['categories|c1']);
  });

  test('várias edições da mesma linha viram uma entrada, com o `em` mais novo', () async {
    await _categoria(db, 'c1');
    final antes = (await db.customSelect('SELECT em FROM mb_saida').getSingle()).read<String>('em');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await (db.update(db.categories)..where((c) => c.categoryPk.equals('c1')))
        .write(const CategoriesCompanion(name: Value('Feira')));
    final linhas = await db.customSelect('SELECT em FROM mb_saida').get();
    expect(linhas, hasLength(1));
    expect(linhas.single.read<String>('em').compareTo(antes) > 0, true);
  });

  test('update sem mudança, ou só em coluna fora do espelho, não enfileira', () async {
    await _categoria(db, 'c1');
    await _limpar(db);
    await db.customStatement('UPDATE categories SET name = name WHERE category_pk = ?', ['c1']);
    await db.customStatement(
        'UPDATE categories SET date_time_modified = date_time_modified + 5 WHERE category_pk = ?', ['c1']);
    expect(await _fila(db), isEmpty);
  });

  test('com aplicando = 1 nada entra na fila', () async {
    await db.customStatement('UPDATE mb_espelho_ctl SET aplicando = 1');
    await _categoria(db, 'c1');
    await db.customStatement('UPDATE categories SET name = ?', ['X']);
    await db.customStatement('DELETE FROM categories');
    expect(await _fila(db), isEmpty);
  });

  test('espelho desligado não enfileira, e desligar esvazia a fila', () async {
    await _categoria(db, 'c1');
    expect(await _fila(db), isNotEmpty);
    await mbEspelhoDefinirAtivo(db, false);
    expect(await _fila(db), isEmpty);
    await _categoria(db, 'c2');
    expect(await _fila(db), isEmpty);
  });

  test('pk composta vira array JSON e pk com ":" passa inteira', () async {
    await db.customStatement("INSERT INTO mb_orcamento_tx (tx_pk, orcamento_pk) VALUES ('mb:t1', 'o1')");
    await db.customStatement("INSERT INTO mb_meta_aplicacao (aplicacao_pk, meta_pk) VALUES ('mb:inv:1', 'm1')");
    expect(await _fila(db), ['mb_meta_aplicacao|mb:inv:1', 'mb_orcamento_tx|["mb:t1","o1"]']);
  });

  test('mudar a pk enfileira a antiga (vira apagada) e a nova', () async {
    await _categoria(db, 'c1');
    await _limpar(db);
    await db.customStatement("UPDATE categories SET category_pk = 'c2' WHERE category_pk = 'c1'");
    expect(await _fila(db), ['categories|c1', 'categories|c2']);
  });

  test('coluna nova recria os triggers da tabela pelo hash', () async {
    final antes = await _triggers(db, 'mb_revisoes');
    expect(antes, hasLength(3));
    await db.customStatement('ALTER TABLE mb_revisoes ADD COLUMN extra TEXT');
    await mbEspelhoPrepararBanco(db);
    final depois = await _triggers(db, 'mb_revisoes');
    expect(depois, hasLength(3));
    expect(depois.toSet().intersection(antes.toSet()), isEmpty);
    await db.customStatement("INSERT INTO mb_revisoes (pk, dados) VALUES ('tx:1', '{}')");
    await _limpar(db);
    await db.customStatement("UPDATE mb_revisoes SET extra = 'x' WHERE pk = 'tx:1'");
    expect(await _fila(db), ['mb_revisoes|tx:1']);
    // Rodar de novo não muda nada.
    await mbEspelhoPrepararBanco(db);
    expect(await _triggers(db, 'mb_revisoes'), unorderedEquals(depois));
  });

  test('migração onUpgrade com triggers existentes não quebra e os recria', () async {
    final dir = Directory.systemTemp.createTempSync('mb_espelho_upgrade');
    addTearDown(() => dir.deleteSync(recursive: true));
    final arquivo = File('${dir.path}/db.sqlite');
    var d = FinanceDatabase(NativeDatabase(arquivo));
    await mbEspelhoDefinirAtivo(d, true);
    await d.customStatement('PRAGMA user_version = 45');
    expect(await _triggers(d, 'transactions'), hasLength(3));
    await d.close();

    d = FinanceDatabase(NativeDatabase(arquivo));
    addTearDown(d.close);
    // A primeira consulta abre o banco: onUpgrade (45 -> 46) derruba os triggers e o beforeOpen recria.
    expect(await _triggers(d, 'transactions'), hasLength(3));
    expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), schemaVersionGlobal);
    await d.into(d.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('c9'), name: 'X', order: 0, dateTimeModified: Value(DateTime.now())));
    expect(await _fila(d), ['categories|c9']);
  });
}
