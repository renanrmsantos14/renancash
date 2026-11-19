import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:budget/struct/mbSync/espelhoTriggers.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

import 'espelho_servidor_falso.dart';

void main() {
  late FinanceDatabase db;
  late ServidorEspelho servidor;
  late ClienteEspelhoFalso cliente;
  late MbEspelho espelho;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    db = FinanceDatabase(NativeDatabase.memory());
    await mbEspelhoDefinirAtivo(db, true);
    servidor = ServidorEspelho();
    cliente = ClienteEspelhoFalso(servidor);
    espelho = MbEspelho(
        db: db, cliente: cliente, configuracoes: () => {}, aplicarConfig: (_, __) async {});
  });

  tearDown(() => db.close());

  void remota(String tabela, String pk, Map<String, dynamic>? dados, String em, {String aparelho = 'z'}) {
    // Linha nova precisa trazer as colunas NOT NULL, como a linha completa que o app envia.
    final completa = dados == null || tabela != 'categories'
        ? dados
        : {'order': 0, 'date_created': 1700000000, ...dados};
    servidor.linhas['$tabela|$pk'] = LinhaServidor(
        completa, em, dados == null ? em : null, '2026-11-18T00:00:00.${servidor.linhas.length + 1}Z', aparelho);
  }

  test('upsert parcial grava só as colunas enviadas e preserva as locais', () async {
    await categoria(db, 'c1', 'Mercado', cor: 'ff0000');
    await db.customStatement('DELETE FROM mb_saida');
    remota('categories', 'c1', {'category_pk': 'c1', 'name': 'Feira'}, '2026-11-18T10:00:00.000Z');
    await espelho.puxar();
    final l = (await linhaDe(db, 'categories', 'category_pk', 'c1'))!;
    expect(l['name'], 'Feira');
    expect(l['colour'], 'ff0000');
    expect(await fila(db), isEmpty);
  });

  test('linha nova remota é inserida com todas as colunas locais', () async {
    remota('categories', 'c2',
        {'category_pk': 'c2', 'name': 'Casa', 'order': 3, 'income': 1, 'date_created': 1700000000},
        '2026-11-18T10:00:00.000Z');
    await espelho.puxar();
    final l = (await linhaDe(db, 'categories', 'category_pk', 'c2'))!;
    expect([l['name'], l['order'], l['income'], l['date_created']], ['Casa', 3, 1, 1700000000]);
  });

  test('tombstone apaga a linha e registra em mb_apagados', () async {
    await categoria(db, 'c1', 'Mercado');
    await db.customStatement('DELETE FROM mb_saida');
    remota('categories', 'c1', null, '2026-11-18T10:00:00.000Z');
    await espelho.puxar();
    expect(await linhaDe(db, 'categories', 'category_pk', 'c1'), isNull);
    final a = (await linhaDe(db, 'mb_apagados', 'pk', 'c1'))!;
    expect([a['tabela'], a['em']], ['categories', '2026-11-18T10:00:00.000Z']);
    expect(await fila(db), isEmpty);
  });

  test('linha que volta depois de apagada sai de mb_apagados', () async {
    remota('categories', 'c1', null, '2026-11-18T10:00:00.000Z');
    await espelho.puxar();
    remota('categories', 'c1', {'category_pk': 'c1', 'name': 'Volta', 'order': 0}, '2026-11-18T11:00:00.000Z');
    await espelho.puxar();
    expect(await linhaDe(db, 'mb_apagados', 'pk', 'c1'), isNull);
    expect((await linhaDe(db, 'categories', 'category_pk', 'c1'))!['name'], 'Volta');
  });

  test('edição local mais nova que a remota é preservada e continua na fila', () async {
    await categoria(db, 'c1', 'Local');
    remota('categories', 'c1', {'category_pk': 'c1', 'name': 'Remota'}, '2000-01-01T00:00:00.000Z');
    await espelho.puxar();
    expect((await linhaDe(db, 'categories', 'category_pk', 'c1'))!['name'], 'Local');
    expect(await fila(db), ['categories|c1']);
  });

  test('remota mais nova vence a edição local pendente e tira a linha da fila', () async {
    await categoria(db, 'c1', 'Local');
    remota('categories', 'c1', {'category_pk': 'c1', 'name': 'Remota'}, '2999-01-01T00:00:00.000Z');
    await espelho.puxar();
    expect((await linhaDe(db, 'categories', 'category_pk', 'c1'))!['name'], 'Remota');
    expect(await fila(db), isEmpty);
  });

  test('coluna desconhecida é ignorada', () async {
    remota('categories', 'c3',
        {'category_pk': 'c3', 'name': 'X', 'order': 0, 'coluna_do_futuro': 'abc'}, '2026-11-18T10:00:00.000Z');
    await espelho.puxar();
    expect((await linhaDe(db, 'categories', 'category_pk', 'c3'))!['name'], 'X');
  });

  test('tabela fora da lista é ignorada', () async {
    remota('app_settings', '1', {'settings_pk': 1}, '2026-11-18T10:00:00.000Z');
    await espelho.puxar();
    expect(await fila(db), isEmpty);
  });

  test('aplicar não dispara a fila, e depois a fila volta a funcionar', () async {
    for (var i = 0; i < 5; i++) {
      remota('categories', 'c$i', {'category_pk': 'c$i', 'name': 'N$i', 'order': i}, '2026-11-18T10:00:00.000Z');
    }
    remota('categories', 'c0', null, '2026-11-18T11:00:00.000Z');
    await espelho.puxar();
    expect(await fila(db), isEmpty);
    expect((await db.customSelect('SELECT aplicando FROM mb_espelho_ctl').getSingle()).read<int>('aplicando'), 0);
    await categoria(db, 'local', 'Nova');
    expect(await fila(db), ['categories|local']);
  });

  test('pk composta: insere e apaga mb_orcamento_tx pelo array JSON', () async {
    remota('mb_orcamento_tx', '["mb:t1","o1"]', {'tx_pk': 'mb:t1', 'orcamento_pk': 'o1'}, '2026-11-18T10:00:00.000Z');
    await espelho.puxar();
    expect(await db.customSelect('SELECT * FROM mb_orcamento_tx').get(), hasLength(1));
    remota('mb_orcamento_tx', '["mb:t1","o1"]', null, '2026-11-18T11:00:00.000Z');
    await espelho.puxar();
    expect(await db.customSelect('SELECT * FROM mb_orcamento_tx').get(), isEmpty);
    expect(await fila(db), isEmpty);
  });

  test('cursor só avança depois de aplicar, e a segunda puxada não traz nada', () async {
    remota('categories', 'c1', {'category_pk': 'c1', 'name': 'A', 'order': 0}, '2026-11-18T10:00:00.000Z');
    await espelho.puxar();
    final cursor = (await db.customSelect("SELECT valor FROM mb_estado WHERE chave = 'espelho_cursor'").getSingle())
        .read<String>('valor');
    expect(cursor, contains('categories|c1'));
    await db.customStatement("UPDATE categories SET name = 'Editada'");
    await db.customStatement('DELETE FROM mb_saida');
    await espelho.puxar(); // o servidor não tem nada novo: o que foi editado localmente não é sobrescrito
    expect((await linhaDe(db, 'categories', 'category_pk', 'c1'))!['name'], 'Editada');
  });

  test('servidor sem semeio: nada é aplicado e o cursor não anda', () async {
    servidor.semeado = false;
    remota('categories', 'c1', {'category_pk': 'c1', 'name': 'A', 'order': 0}, '2026-11-18T10:00:00.000Z');
    await espelho.puxar();
    expect(await linhaDe(db, 'categories', 'category_pk', 'c1'), isNull);
  });

  test('1.000 linhas remotas em páginas de 400', () async {
    servidor.paginaMax = 400;
    for (var i = 0; i < 1000; i++) {
      remota('categories', 'c$i', {'category_pk': 'c$i', 'name': 'N$i', 'order': i}, '2026-11-18T10:00:00.000Z');
    }
    await espelho.puxar();
    expect((await db.customSelect('SELECT COUNT(*) n FROM categories').getSingle()).read<int>('n'), 1000);
    expect(await fila(db), isEmpty);
  });

  test('envio: fila de 1.000 itens sai em lotes de 500', () async {
    await db.batch((b) => b.insertAll(db.categories, [
          for (var i = 0; i < 1000; i++)
            CategoriesCompanion.insert(categoryPk: Value('c$i'), name: 'N$i', order: i)
        ]));
    expect(await fila(db), hasLength(1000));
    await espelho.enviar();
    expect(servidor.tamanhosDeLote, [500, 500]);
    expect(await fila(db), isEmpty);
    expect(servidor.linhas, hasLength(1000));
  });

  test('envio: linha apagada e recriada antes do envio sobe viva, não como apagada', () async {
    await categoria(db, 'c1', 'Antes');
    await db.customStatement("DELETE FROM categories WHERE category_pk = 'c1'");
    await categoria(db, 'c1', 'Depois');
    await espelho.enviar();
    final l = servidor.linhas['categories|c1']!;
    expect(l.deletedAt, isNull);
    expect(l.dados!['name'], 'Depois');
    expect(l.dados!.containsKey('date_time_modified'), false);
  });

  test('envio: linha apagada sobe como tombstone com a hora da fila', () async {
    await categoria(db, 'c1', 'Antes');
    await db.customStatement("DELETE FROM categories WHERE category_pk = 'c1'");
    await espelho.enviar();
    final l = servidor.linhas['categories|c1']!;
    expect([l.dados, l.deletedAt, l.deletedAt == l.updatedAt], [isNull, isNotNull, true]);
  });
}
