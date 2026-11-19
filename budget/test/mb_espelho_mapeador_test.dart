import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:budget/struct/mbSync/espelhoTriggers.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

import 'espelho_servidor_falso.dart';

class ClienteBanco extends MbCliente {
  ClienteBanco() : super(base: 'https://teste');
  double valor = -10.0;

  @override
  Future<Map<String, dynamic>> puxar(String? desde) async => {
        'agora': DateTime.now().toUtc().toIso8601String(),
        'registros': <Map<String, dynamic>>[],
        'contas': [
          {'id': 'a1', 'type': 'BANK', 'name': 'Conta'}
        ],
        'transacoes': [
          {
            'id': '55',
            'account_id': 'a1',
            'date': '2025-01-10',
            'description': 'Padaria',
            'amount': valor,
            'category': 'Bakeries',
            'status': 'POSTED',
          }
        ],
        'pendentes': [],
      };

  @override
  Future<({int aceitos, List<({int indice, String motivo})> rejeitados})> enviar(List<Registro> lote) async {
    return (aceitos: lote.length, rejeitados: <({int indice, String motivo})>[]);
  }
}

void main() {
  late ServidorEspelho servidor;
  late MbEspelho espelho;
  late ClienteBanco cliente;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    database = FinanceDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({'mbNotifCursor': 'x'});
    sharedPreferences = await SharedPreferences.getInstance();
    appStateSettings = {'mbEspelho': true};
    meuBancoSincronizando.value = false;
    cliente = ClienteBanco();
    await mbEspelhoDefinirAtivo(database, true);
    servidor = ServidorEspelho();
    espelho = MbEspelho(
        db: database,
        cliente: ClienteEspelhoFalso(servidor),
        configuracoes: () => appStateSettings,
        aplicarConfig: (_, __) async {});
  });

  tearDown(() => database.close());

  Future<void> bancoSync() async =>
      expect(await sincronizarMeuBanco(clienteParaTeste: cliente), true, reason: meuBancoUltimoErro.value);

  Future<Transaction?> tx() => (database.select(database.transactions)
        ..where((t) => t.transactionPk.equals('mb:55')))
      .getSingleOrNull();

  test('renomear mb:55 em outro aparelho: o nome sobrevive ao sync do banco', () async {
    await bancoSync();
    expect((await tx())!.name, 'Padaria');
    final editadaEm = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // A linha completa como o outro aparelho a enviaria, já renomeada.
    final linha = (await database
            .customSelect("SELECT * FROM transactions WHERE transaction_pk = 'mb:55'")
            .getSingle())
        .data
      ..removeWhere((k, _) => mbColunasSemEspelho.contains(k));
    servidor.linhas['transactions|mb:55'] = LinhaServidor(
        {...linha, 'name': 'Minha padaria', 'date_time_modified': editadaEm},
        '2999-01-01T00:00:00.000Z',
        null,
        '2026-11-18T10:00:00.000001Z',
        'z');
    await espelho.puxar();
    await bancoSync();
    expect((await tx())!.name, 'Minha padaria');
  });

  test('transação mb: apagada aqui não é recriada pelo sync do banco', () async {
    await bancoSync();
    await database.customStatement("DELETE FROM transactions WHERE transaction_pk = 'mb:55'");
    expect(await mbEspelhoApagadas('transactions'), {'mb:55'});
    cliente.valor = -12.0; // o banco mudou a transação: o mapeador teria motivo para recriá-la
    await bancoSync();
    expect(await tx(), isNull);
  });

  test('transação mb: apagada em outro aparelho não é recriada', () async {
    await bancoSync();
    servidor.linhas['transactions|mb:55'] =
        LinhaServidor(null, '2999-01-01T00:00:00.000Z', '2999-01-01T00:00:00.000Z', '2026-11-18T10:00:00.000001Z', 'z');
    await espelho.puxar();
    cliente.valor = -12.0;
    await bancoSync();
    expect(await tx(), isNull);
  });

  test('com a flag desligada nada vai para mb_apagados e o mapeador não filtra', () async {
    await bancoSync();
    appStateSettings['mbEspelho'] = false;
    await mbEspelhoDefinirAtivo(database, false);
    await database.customStatement("DELETE FROM transactions WHERE transaction_pk = 'mb:55'");
    expect(await mbEspelhoApagadas('transactions'), isEmpty);
    final n = await database
        .customSelect('SELECT COUNT(*) AS n FROM mb_apagados')
        .getSingle();
    expect(n.read<int>('n'), 0);
  });
}
