import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/agendador.dart';
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

import 'espelho_servidor_falso.dart';

void main() {
  late ServidorEspelho servidor;
  late ClienteEspelhoFalso cliente;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    database = FinanceDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    appStateSettings = {};
    mbEspelhoPronto.value = false;
    mbFaseEspelho.value = MbFaseEspelho.desconhecida;
    mbErroEspelho.value = '';
    mbDiagnosticoEspelho.value = '';
    mbEspelhoReiniciarSessao();
    servidor = ServidorEspelho();
    cliente = ClienteEspelhoFalso(servidor);
    mbClienteEspelhoParaTeste = cliente;
  });

  tearDown(() async {
    mbClienteEspelhoParaTeste = null;
    await database.close();
  });

  test('Worker sem espelho (404): não pergunta de novo a cada rodada, só ao abrir o app', () async {
    cliente.indisponivel = true;
    expect(await mbEspelhoRodarUmaVez(), true);
    expect(mbFaseEspelho.value, MbFaseEspelho.indisponivel);
    expect(cliente.cursoresPedidos, hasLength(1));
    for (var i = 0; i < 5; i++) {
      expect(await mbEspelhoRodarUmaVez(), true);
    }
    expect(cliente.cursoresPedidos, hasLength(1), reason: 'sem GET a cada 60 s');
    mbEspelhoVoltouAoApp();
    await mbEspelhoRodarUmaVez();
    expect(cliente.cursoresPedidos, hasLength(2), reason: 'abrir o app pergunta uma vez');
  });

  test('falha no semeio vira fase erro com mensagem; "Agora não" pausa; "Tentar de novo" retoma', () async {
    servidor.semeado = false;
    await categoria(database, 'c1', 'Uma');
    mbEspelhoConfirmarSemeio();
    cliente.cairNoLote = 0;
    expect(await mbEspelhoRodarUmaVez(), false);
    expect(mbFaseEspelho.value, MbFaseEspelho.erro);
    expect(mbErroEspelho.value, isNotEmpty);

    mbEspelhoAdiar();
    expect(mbFaseEspelho.value, MbFaseEspelho.desconhecida);
    final pedidos = cliente.cursoresPedidos.length;
    expect(await mbEspelhoRodarUmaVez(), true);
    expect(cliente.cursoresPedidos, hasLength(pedidos), reason: 'adiado: não tenta nem consulta');

    mbEspelhoConfirmarSemeio();
    expect(await mbEspelhoRodarUmaVez(), true);
    expect(servidor.semeado, true);
    expect(mbFaseEspelho.value, MbFaseEspelho.pronto);
    expect(mbErroEspelho.value, isEmpty);
  });

  test('sem rede na simples consulta (antes de semear) não mostra erro na tela', () async {
    cliente.semRede = true;
    expect(await mbEspelhoRodarUmaVez(), false);
    expect(mbFaseEspelho.value, MbFaseEspelho.desconhecida);
  });

  test('diagnóstico: guarda o motivo de cada decisão em vez de engolir o erro', () async {
    cliente.erroNoGet = MbErroHttp(401, 'token inválido');
    expect(await mbEspelhoRodarUmaVez(), false);
    expect(mbDiagnosticoEspelho.value, 'HTTP 401: token inválido');
    expect(mbFaseEspelho.value, MbFaseEspelho.desconhecida);

    cliente.erroNoGet = null;
    cliente.semRede = true;
    await mbEspelhoRodarUmaVez();
    expect(mbDiagnosticoEspelho.value, startsWith('sem rede'));

    cliente.semRede = false;
    cliente.indisponivel = true;
    await mbEspelhoRodarUmaVez();
    expect(mbDiagnosticoEspelho.value, 'servidor sem espelho (404)');

    cliente.indisponivel = false;
    mbEspelhoReiniciarSessao();
    servidor.semeado = false;
    await mbEspelhoRodarUmaVez();
    expect(mbFaseEspelho.value, MbFaseEspelho.confirmar);
    expect(mbDiagnosticoEspelho.value, 'esperando a confirmação do usuário');

    mbEspelhoAdiar();
    await mbEspelhoRodarUmaVez();
    expect(mbDiagnosticoEspelho.value, contains('Agora não'));
  });

  test('"Enviar dados para a nuvem" funciona mesmo adiado e devolve o erro com status e mensagem', () async {
    servidor.semeado = false;
    await categoria(database, 'c1', 'Uma');
    mbEspelhoAdiar();
    cliente.erroNoGet = MbErroHttp(403, 'proibido');
    expect(await mbEspelhoEnviarAgora(), 'O servidor respondeu (HTTP 403): proibido.');

    cliente.erroNoGet = null;
    expect(await mbEspelhoEnviarAgora(), startsWith('Pronto'));
    expect(servidor.semeado, true);
    expect(mbFaseEspelho.value, MbFaseEspelho.pronto);
  });
}
