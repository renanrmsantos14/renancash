import 'dart:convert';
import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/mbSync/armazem.dart' show mbLerEstado;
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:budget/struct/mbSync/espelhoTriggers.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

import 'espelho_servidor_falso.dart';

class Aparelho {
  Aparelho(this.id, this.servidor);
  final String id;
  final ServidorEspelho servidor;
  late FinanceDatabase db;
  late ClienteEspelhoFalso cliente;
  late MbEspelho espelho;

  Future<void> abrir() async {
    db = FinanceDatabase(NativeDatabase.memory());
    await mbEspelhoDefinirAtivo(db, true);
    // O id do aparelho vem do banco; fixa para o desempate do servidor ser previsível.
    await db.customStatement("INSERT OR REPLACE INTO mb_estado (chave, valor) VALUES ('espelho_aparelho', '$id')");
    cliente = ClienteEspelhoFalso(servidor);
    espelho = MbEspelho(db: db, cliente: cliente, configuracoes: () => {}, aplicarConfig: (_, __) async {});
  }

  Future<void> sincronizar() => espelho.sincronizar();
  Future<String?> nome(String pk) async => (await linhaDe(db, 'categories', 'category_pk', pk))?['name'] as String?;
}

void main() {
  late ServidorEspelho servidor;
  late Aparelho a, b;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    servidor = ServidorEspelho();
    a = Aparelho('a', servidor);
    b = Aparelho('b', servidor);
    await a.abrir();
    await b.abrir();
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  test('edição em A aparece em B', () async {
    await categoria(a.db, 'c1', 'Mercado');
    await a.sincronizar();
    await b.sincronizar();
    expect(await b.nome('c1'), 'Mercado');
    expect(await fila(b.db), isEmpty, reason: 'o que B recebeu não volta para o servidor');
    await a.db.customStatement("UPDATE categories SET name = 'Feira' WHERE category_pk = 'c1'");
    await a.sincronizar();
    await b.sincronizar();
    expect(await b.nome('c1'), 'Feira');
  });

  test('A offline edita 3 itens e os 3 chegam em B', () async {
    a.cliente.semRede = true;
    for (final i in [1, 2, 3]) {
      await categoria(a.db, 'c$i', 'N$i');
    }
    expect(await a.espelho.sincronizar(), false);
    expect(await fila(a.db), hasLength(3));
    a.cliente.semRede = false;
    await a.sincronizar();
    await b.sincronizar();
    expect([for (final i in [1, 2, 3]) await b.nome('c$i')], ['N1', 'N2', 'N3']);
    expect(await fila(a.db), isEmpty);
  });

  test('conflito: a edição mais recente vence e os dois lados convergem', () async {
    await categoria(a.db, 'c1', 'Original');
    await a.sincronizar();
    await b.sincronizar();
    await a.db.customStatement("UPDATE categories SET name = 'Do A' WHERE category_pk = 'c1'");
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.db.customStatement("UPDATE categories SET name = 'Do B' WHERE category_pk = 'c1'");
    await a.sincronizar();
    await b.sincronizar();
    await a.sincronizar();
    expect(await a.nome('c1'), 'Do B');
    expect(await b.nome('c1'), 'Do B');
    expect(servidor.linhas['categories|c1']!.dados!['name'], 'Do B');
  });

  test('conflito: B envia primeiro uma edição mais antiga e perde', () async {
    await categoria(a.db, 'c1', 'Original');
    await a.sincronizar();
    await b.sincronizar();
    await b.db.customStatement("UPDATE categories SET name = 'Do B' WHERE category_pk = 'c1'");
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.db.customStatement("UPDATE categories SET name = 'Do A' WHERE category_pk = 'c1'");
    await a.sincronizar();
    await b.sincronizar();
    await a.sincronizar();
    expect([await a.nome('c1'), await b.nome('c1')], ['Do A', 'Do A']);
  });

  test('exclusão em A propaga e apaga em B', () async {
    await categoria(a.db, 'c1', 'Mercado');
    await a.sincronizar();
    await b.sincronizar();
    await a.db.customStatement("DELETE FROM categories WHERE category_pk = 'c1'");
    await a.sincronizar();
    await b.sincronizar();
    expect(await b.nome('c1'), isNull);
    expect(servidor.linhas['categories|c1']!.deletedAt, isNotNull);
    expect(await fila(b.db), isEmpty);
  });

  test('edição durante o envio: a entrada da fila fica e sobe na rodada seguinte', () async {
    await categoria(a.db, 'c1', 'Antes');
    a.cliente.duranteEnvio = () async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.db.customStatement("UPDATE categories SET name = 'Durante' WHERE category_pk = 'c1'");
    };
    await a.espelho.enviar();
    a.cliente.duranteEnvio = null;
    expect(await fila(a.db), ['categories|c1']);
    await a.espelho.enviar();
    expect(servidor.linhas['categories|c1']!.dados!['name'], 'Durante');
    expect(await fila(a.db), isEmpty);
  });

  test('exclusão durante o envio de uma edição: a exclusão não se perde', () async {
    await categoria(a.db, 'c1', 'Antes');
    a.cliente.duranteEnvio = () async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.db.customStatement("DELETE FROM categories WHERE category_pk = 'c1'");
    };
    await a.espelho.enviar();
    a.cliente.duranteEnvio = null;
    await a.espelho.enviar();
    expect(servidor.linhas['categories|c1']!.deletedAt, isNotNull);
    expect(await fila(a.db), isEmpty);
  });

  test('pk composta e pk com ":" atravessam de A para B', () async {
    await a.db.customStatement("INSERT INTO mb_orcamento_tx (tx_pk, orcamento_pk) VALUES ('mb:t1', 'o1')");
    await a.sincronizar();
    await b.sincronizar();
    expect(await b.db.customSelect('SELECT tx_pk, orcamento_pk FROM mb_orcamento_tx').get().then((r) => r.map((l) => l.data).toList()),
        [{'tx_pk': 'mb:t1', 'orcamento_pk': 'o1'}]);
    await a.db.customStatement('DELETE FROM mb_orcamento_tx');
    await a.sincronizar();
    await b.sincronizar();
    expect(await b.db.customSelect('SELECT * FROM mb_orcamento_tx').get(), isEmpty);
  });

  test('aparelho novo recebe tudo no primeiro pull', () async {
    for (var i = 0; i < 30; i++) {
      await categoria(a.db, 'c$i', 'N$i');
    }
    await a.sincronizar();
    await b.sincronizar();
    expect((await b.db.customSelect('SELECT COUNT(*) n FROM categories').getSingle()).read<int>('n'), 30);
  });

  test('C2: edição mais antiga rejeitada traz a versão do servidor para B logo após o envio', () async {
    await categoria(a.db, 'c1', 'Original');
    await a.sincronizar();
    await b.sincronizar();
    await b.db.customStatement("UPDATE categories SET name = 'Do B' WHERE category_pk = 'c1'");
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.db.customStatement("UPDATE categories SET name = 'Do A' WHERE category_pk = 'c1'");
    await a.espelho.enviar();
    await b.espelho.enviar(); // só o envio: a versão vencedora vem em `atual`
    expect(await b.nome('c1'), 'Do A');
    expect(await fila(b.db), isEmpty);
  });

  test('C2: tabela desconhecida sai da fila e fica registrada em espelho_rejeitados', () async {
    servidor.tabelasConhecidas.remove('categories');
    await categoria(a.db, 'c1', 'Original');
    await a.espelho.enviar();
    expect(await fila(a.db), isEmpty);
    final r = json.decode(await mbLerEstado('espelho_rejeitados', a.db) ?? '[]') as List;
    expect(r.single['tabela'], 'categories');
    expect(r.single['pk'], 'c1');
    expect(r.single['motivo'], 'tabela_desconhecida');
  });

  test('C3: guarda o id do aparelho autenticado pelo servidor', () async {
    a.cliente.idServidor = 'id-autenticado';
    await categoria(a.db, 'c1', 'Original');
    await a.sincronizar();
    expect(await mbLerEstado(mbChaveAparelhoServidor, a.db), 'id-autenticado');
  });

  test('C4: a primeira página recua 30 s sem o sufixo e o cursor guardado não volta', () async {
    await categoria(a.db, 'c1', 'Original');
    await a.sincronizar();
    await b.sincronizar();
    await b.sincronizar();
    final guardado = (await mbLerEstado('espelho_cursor', b.db))!;
    final pedido = b.cliente.cursoresPedidos.last!;
    expect(pedido.contains('|'), isFalse);
    expect(DateTime.parse(pedido).isBefore(DateTime.parse(guardado.split('|').first)), isTrue);
    expect(await mbLerEstado('espelho_cursor', b.db), guardado);
  });
}
