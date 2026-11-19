import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:budget/struct/mbSync/espelhoTriggers.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

import 'espelho_servidor_falso.dart';

void main() {
  late ServidorEspelho servidor;
  late ClienteEspelhoFalso cliente;
  late MbEspelho espelho;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    database = FinanceDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    appStateSettings = {'mbEspelho': true, 'font': 'Geist', 'username': 'Renan'};
    await mbEspelhoDefinirAtivo(database, true);
    servidor = ServidorEspelho();
    cliente = ClienteEspelhoFalso(servidor);
    espelho = MbEspelho(
      db: database,
      cliente: cliente,
      configuracoes: () => appStateSettings,
      aplicarConfig: (chave, valor) =>
          updateSettings(chave, valor, updateGlobalState: false, sincronizar: false),
    );
  });

  tearDown(() => database.close());

  test('chave de aparência não sai; chave nova sai', () async {
    await updateSettings('font', 'Outra', updateGlobalState: false);
    await updateSettings('widgetOrder', 'x', updateGlobalState: false);
    await updateSettings('username', 'Novo', updateGlobalState: false);
    await updateSettings('algumaChaveNova', 1, updateGlobalState: false);
    expect(await fila(database), ['_config|algumaChaveNova', '_config|username']);
    await espelho.enviar();
    expect(servidor.linhas.keys.toSet(), {'_config|algumaChaveNova', '_config|username'});
    expect(servidor.linhas['_config|username']!.dados, {'v': 'Novo'});
  });

  test('valor igual não enfileira', () async {
    await updateSettings('username', 'Renan', updateGlobalState: false);
    expect(await fila(database), isEmpty);
  });

  test('aplicar o remoto grava a configuração e não reenvia', () async {
    servidor.linhas['_config|username'] =
        LinhaServidor({'v': 'Do outro'}, '2026-11-18T10:00:00.000Z', null, '2026-11-18T10:00:00.000001Z', 'z');
    servidor.linhas['_config|font'] =
        LinhaServidor({'v': 'Remota'}, '2026-11-18T10:00:00.000Z', null, '2026-11-18T10:00:00.000002Z', 'z');
    await espelho.puxar();
    expect(appStateSettings['username'], 'Do outro');
    expect(appStateSettings['font'], 'Geist', reason: 'aparência é local');
    expect(await fila(database), isEmpty);
  });

  test('marcação de Classificar/Arrumar vai e volta pela entidade _config', () async {
    await database.customStatement("INSERT OR REPLACE INTO mb_estado (chave, valor) VALUES ('ia_revisados', '[\"a\"]')");
    await mbEspelhoEstadoMudou(['ia_revisados', 'cursor_qualquer']);
    expect(await fila(database), ['_config|estado:ia_revisados']);
    await espelho.enviar();
    expect(servidor.linhas['_config|estado:ia_revisados']!.dados, {'v': '["a"]'});
    servidor.linhas['_config|estado:arrumar_juntados'] =
        LinhaServidor({'v': '["x"]'}, '2026-11-18T10:00:00.000Z', null, '2026-11-18T10:00:00.000009Z', 'z');
    await espelho.puxar();
    final v = (await database.customSelect("SELECT valor FROM mb_estado WHERE chave = 'arrumar_juntados'").getSingle())
        .read<String>('valor');
    expect(v, '["x"]');
    expect(await fila(database), isEmpty);
  });

  test('com a flag desligada nada entra na fila', () async {
    appStateSettings['mbEspelho'] = false;
    await mbEspelhoDefinirAtivo(database, false);
    await updateSettings('algumaChaveNova', 1, updateGlobalState: false);
    await categoria(database, 'c1', 'X');
    expect(await fila(database), isEmpty);
  });
}
