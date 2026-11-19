import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/mbSync/armazem.dart' show mbLerEstado;
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

import 'espelho_servidor_falso.dart';

class Disp {
  Disp(this.servidor, {this.configs = const {}});
  final ServidorEspelho servidor;
  final Map<String, dynamic> configs;
  final Map<String, Object?> aplicadas = {};
  late FinanceDatabase db;
  late ClienteEspelhoFalso cliente;
  late MbEspelho espelho;

  Future<void> abrir() async {
    db = FinanceDatabase(NativeDatabase.memory());
    cliente = ClienteEspelhoFalso(servidor);
    espelho = MbEspelho(
        db: db,
        cliente: cliente,
        configuracoes: () => configs,
        aplicarConfig: (c, v) async => aplicadas[c] = v);
  }

  Future<int> contar(String tabela) async =>
      (await db.customSelect('SELECT COUNT(*) n FROM $tabela').getSingle()).read<int>('n');
}

void main() {
  late ServidorEspelho servidor;
  late Disp celular, outro;

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    mbEspelhoPronto.value = false;
    servidor = ServidorEspelho()..semeado = false;
    celular = Disp(servidor, configs: {'currency': 'brl', 'locale': 'pt', 'numberFormatDecimal': ',', 'selectedWalletPk': '7'});
    outro = Disp(servidor);
    await celular.abrir();
    await outro.abrir();
  });

  tearDown(() async {
    await celular.db.close();
    await outro.db.close();
  });

  Future<void> popular(int n) async {
    for (var i = 0; i < n; i++) {
      await categoria(celular.db, 'c${i.toString().padLeft(3, '0')}', 'Cat $i');
    }
  }

  test('sem semear: Android pede confirmação e não envia nada antes dela', () async {
    await popular(3);
    final fases = <MbFaseEspelho>[];
    final f = await celular.espelho.avaliar(podeSemear: true, aoFase: fases.add);
    expect(f, MbFaseEspelho.confirmar);
    expect(celular.cliente.lotesEnviados, isEmpty);
    expect(servidor.semeado, false);
  });

  test('semeia em lotes numerados de 0, liga a fila e marca pronto', () async {
    await popular(5);
    await categoria(celular.db, 'zz', 'Última');
    await celular.db.customStatement("INSERT INTO mb_estado (chave, valor) VALUES ('ia_revisados', '[1]')");
    final f = await celular.espelho.avaliar(podeSemear: true, confirmado: true);
    expect(f, MbFaseEspelho.pronto);
    // 6 categorias e 3 configurações + a marcação: tamanho 500 cabe tudo em 1 lote.
    expect(servidor.semeado, true);
    expect(servidor.lotesDeSemeio, [0]);
    expect(servidor.linhas.keys, containsAll(['categories|c000', 'categories|zz', '_config|currency', '_config|estado:ia_revisados']));
    expect(servidor.linhas.containsKey('_config|selectedWalletPk'), false, reason: 'seleção de carteira é local');
    expect(await mbLerEstado(mbChaveProntoEspelho, celular.db), '1');
    expect(await mbLerEstado('espelho_cursor', celular.db), isNotNull);
    expect(await mbLerEstado('espelho_semeio', celular.db), isNull);
    final ctl = await celular.db.customSelect('SELECT ativo FROM mb_espelho_ctl').getSingle();
    expect(ctl.read<int>('ativo'), 1);
    // Depois de pronto, a edição local entra na fila.
    await categoria(celular.db, 'nova', 'Nova');
    expect(await fila(celular.db), ['categories|nova']);
  });

  test('semeia em vários lotes e retoma do último confirmado depois de uma falha', () async {
    await popular(12);
    celular.cliente.cairNoLote = 2;
    await expectLater(celular.espelho.semearDoCelular(tamanho: 5), throwsA(isA<Exception>()));
    expect(celular.cliente.lotesEnviados, [0, 1]);
    expect(servidor.semeado, false);
    expect(await mbLerEstado(mbChaveProntoEspelho, celular.db), isNull);
    final andamento = json.decode((await mbLerEstado('espelho_semeio', celular.db))!) as Map;
    expect(andamento['lote'], 2);

    // O app volta: o semeio em andamento retoma sem pedir confirmação de novo.
    final f = await celular.espelho.avaliar(podeSemear: true);
    expect(f, MbFaseEspelho.pronto);
    expect(celular.cliente.lotesEnviados, [0, 1, 2]);
    final cats = servidor.linhas.keys.where((k) => k.startsWith('categories|')).toList();
    expect(cats, hasLength(12));
    expect(servidor.semeado, true);
  });

  test('web com semeado:false espera e não escreve nada', () async {
    await categoria(outro.db, 'local', 'Local');
    final fases = <MbFaseEspelho>[];
    final f = await outro.espelho.avaliar(podeSemear: false, confirmado: true, aoFase: fases.add);
    expect(f, MbFaseEspelho.aguardando);
    expect(outro.cliente.lotesEnviados, isEmpty);
    expect(servidor.linhas, isEmpty);
    expect(await mbLerEstado(mbChaveProntoEspelho, outro.db), isNull);
    expect(await fila(outro.db), isEmpty);
  });

  test('servidor sem espelho (404) deixa tudo como estava', () async {
    final c = _Cliente404(servidor);
    final e = MbEspelho(db: outro.db, cliente: c, configuracoes: () => {}, aplicarConfig: (_, __) async {});
    expect(await e.avaliar(podeSemear: true, confirmado: true), MbFaseEspelho.indisponivel);
    expect(await mbLerEstado(mbChaveProntoEspelho, outro.db), isNull);
  });

  test('semeado: o outro aparelho apaga o que tinha, baixa tudo e a aparência fica', () async {
    await popular(4);
    await celular.espelho.avaliar(podeSemear: true, confirmado: true);

    await categoria(outro.db, 'so-aqui', 'Só aqui');
    await outro.db.customStatement("INSERT INTO mb_estado (chave, valor) VALUES ('cursor', 'velho')");
    await outro.db.customStatement("INSERT INTO mb_estado (chave, valor) VALUES ('espelho_aparelho', 'meu-id')");
    await outro.db.customStatement("INSERT INTO mb_apagados (tabela, pk, em) VALUES ('categories', 'x', 'y')");
    // Aparência não passa pelo banco: a troca nem a conhece, e `selectedWalletPk` volta para a carteira '0'.
    final f = await outro.espelho.avaliar(podeSemear: false);
    expect(f, MbFaseEspelho.pronto);
    expect(await linhaDe(outro.db, 'categories', 'category_pk', 'so-aqui'), isNull);
    expect(await linhaDe(outro.db, 'categories', 'category_pk', 'c000'), isNotNull);
    expect(await outro.contar('categories'), await celular.contar('categories'));
    expect(await mbLerEstado('cursor', outro.db), isNull, reason: 'estado do sync antigo sai');
    expect(await mbLerEstado('espelho_aparelho', outro.db), 'meu-id', reason: 'identidade do aparelho fica');
    expect(await mbLerEstado(mbChaveProntoEspelho, outro.db), '1');
    expect(await mbLerEstado('espelho_cursor', outro.db), isNotNull);
    expect(await outro.contar('mb_apagados'), 0);
    expect(outro.aplicadas['selectedWalletPk'], '0');
    expect(outro.aplicadas.keys, isNot(contains('appLanguage')));
    expect(outro.aplicadas['currency'], 'brl', reason: 'configuração de dados vem da nuvem');
    expect(await fila(outro.db), isEmpty, reason: 'a troca não devolve nada ao servidor');
  });

  test('troca interrompida no download refaz do zero na próxima rodada', () async {
    await popular(3);
    await celular.espelho.avaliar(podeSemear: true, confirmado: true);
    outro.cliente.semRede = false;
    // Primeiro GET (sonda) passa; o do download falha.
    final c = _FalhaNoDownload(servidor);
    final e = MbEspelho(db: outro.db, cliente: c, configuracoes: () => {}, aplicarConfig: (_, __) async {});
    await expectLater(e.avaliar(podeSemear: false), throwsA(anything));
    expect(await mbLerEstado(mbChaveProntoEspelho, outro.db), isNull);
    expect(await outro.espelho.avaliar(podeSemear: false), MbFaseEspelho.pronto);
    expect(await outro.contar('categories'), await celular.contar('categories'));
  });

  test('semeio de aparelho que perdeu a corrida (ja_semeado) vira troca', () async {
    await popular(2);
    await outro.espelho.avaliar(podeSemear: true, confirmado: true);
    celular.cliente.semRede = false;
    // O servidor foi semeado depois da sonda do celular: o POST responde ja_semeado.
    final c = _SemeadoNoMeio(servidor);
    final e = MbEspelho(db: celular.db, cliente: c, configuracoes: () => {}, aplicarConfig: (_, __) async {});
    servidor.semeado = false;
    c.aoSondar = () => servidor.semeado = true; // semeado logo após a sonda (que ainda viu false)
    expect(await e.avaliar(podeSemear: true, confirmado: true), MbFaseEspelho.pronto);
    expect(await mbLerEstado(mbChaveProntoEspelho, celular.db), '1');
  });
  test('Android com servidor já semeado pede confirmação (e conta as pendências) antes de apagar; web troca sozinha', () async {
    await popular(3);
    await celular.espelho.avaliar(podeSemear: true, confirmado: true);
    await categoria(outro.db, 'so-aqui', 'Só aqui');
    await outro.db.customStatement(
        'CREATE TABLE mb_registros (tabela TEXT, id TEXT, dados TEXT, updated_at TEXT, deleted_at TEXT, projecao TEXT, pendente INTEGER, motivo TEXT)');
    await outro.db.customStatement(
        "INSERT INTO mb_registros (tabela, id, pendente) VALUES ('ajustes', '1', 1), ('ajustes', '2', 1), ('ajustes', '3', 0)");

    expect(await outro.espelho.avaliar(podeSemear: true), MbFaseEspelho.confirmarTroca);
    expect(mbPendentesAntesDaTroca.value, 2);
    expect(await linhaDe(outro.db, 'categories', 'category_pk', 'so-aqui'), isNotNull, reason: 'nada foi apagado');
    expect(await mbLerEstado(mbChaveProntoEspelho, outro.db), isNull);

    expect(await outro.espelho.avaliar(podeSemear: true, confirmado: true), MbFaseEspelho.pronto);
    expect(await linhaDe(outro.db, 'categories', 'category_pk', 'so-aqui'), isNull);
  });

  test('enviar/puxar não se intercalam com a troca pela nuvem (trava única)', () async {
    await popular(3);
    await celular.espelho.avaliar(podeSemear: true, confirmado: true);
    await outro.espelho.avaliar(podeSemear: false);
    await categoria(outro.db, 'so-aqui', 'Só aqui');

    final liberar = Completer<void>();
    var primeira = true;
    outro.cliente.duranteGet = () async {
      if (primeira) {
        primeira = false;
        await liberar.future;
      }
    };
    final p = outro.espelho.puxar();
    final t = outro.espelho.substituirPelaNuvem();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await linhaDe(outro.db, 'categories', 'category_pk', 'so-aqui'), isNotNull,
        reason: 'a troca espera o pull em andamento terminar');
    liberar.complete();
    await Future.wait([p, t]);
    expect(await linhaDe(outro.db, 'categories', 'category_pk', 'so-aqui'), isNull);
    expect(await outro.contar('categories'), await celular.contar('categories'));
    expect(await mbLerEstado(mbChaveProntoEspelho, outro.db), '1');
    expect(await mbLerEstado('espelho_cursor', outro.db), isNotNull);
  });

  test('semeio_nao_iniciado na retomada: limpa o andamento e recomeça do lote 0', () async {
    await popular(12);
    celular.cliente.cairNoLote = 2;
    await expectLater(celular.espelho.semearDoCelular(tamanho: 5), throwsA(isA<Exception>()));
    servidor.esquecerSemeio();
    await celular.espelho.semearDoCelular(tamanho: 5);
    expect(celular.cliente.lotesEnviados, [0, 1, 2, 0, 1, 2], reason: 'o lote 2 foi recusado (409) e recomeçou do 0');
    expect(servidor.semeado, true);
    expect(servidor.linhas.keys.where((k) => k.startsWith('categories|')), hasLength(12));
    expect(await mbLerEstado('espelho_semeio', celular.db), isNull);
  });

  test('semear e trocar atualizam mbEspelhoPronto na hora (mbEspelhoLigado deixa de depender do próximo boot)', () async {
    await popular(2);
    expect(mbEspelhoPronto.value, false);
    await celular.espelho.avaliar(podeSemear: true, confirmado: true);
    expect(mbEspelhoPronto.value, true);
    mbEspelhoPronto.value = false;
    await outro.espelho.avaliar(podeSemear: false);
    expect(mbEspelhoPronto.value, true);
  });

  test('edições entre as tentativas do semeio não se perdem: ficam na fila e sobem depois do semeio', () async {
    await popular(12);
    celular.cliente.cairNoLote = 2;
    await expectLater(celular.espelho.semearDoCelular(tamanho: 5), throwsA(isA<Exception>()));
    // c000 já foi enviada no lote 0; c001 mudou e uma nova nasceu enquanto o semeio estava parado.
    await celular.db.customStatement(
        "UPDATE categories SET name = 'Renomeada', date_time_modified = ${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 5} WHERE category_pk = 'c000'");
    await categoria(celular.db, 'nova', 'Nova');
    expect(await fila(celular.db), containsAll(['categories|c000', 'categories|nova']));

    await celular.espelho.semearDoCelular(tamanho: 5);
    expect(await fila(celular.db), containsAll(['categories|c000', 'categories|nova']), reason: 'pronto não apaga a fila');
    expect(await celular.espelho.sincronizar(), true);
    expect(servidor.linhas['categories|c000']!.dados!['name'], 'Renomeada');
    expect(servidor.linhas.containsKey('categories|nova'), true);
    expect(await fila(celular.db), isEmpty);
  });
}


class _Cliente404 extends ClienteEspelhoFalso {
  _Cliente404(super.servidor);
  @override
  Future<Map<String, dynamic>> espelhoPuxar(String? desde, {int limite = 2000}) async =>
      throw MbErroHttp(404, 'não encontrado');
}

class _FalhaNoDownload extends ClienteEspelhoFalso {
  _FalhaNoDownload(super.servidor);
  int _n = 0;
  @override
  Future<Map<String, dynamic>> espelhoPuxar(String? desde, {int limite = 2000}) async {
    if (++_n == 2) throw MbErroHttp(500, 'caiu');
    return super.espelhoPuxar(desde, limite: limite);
  }
}

class _SemeadoNoMeio extends ClienteEspelhoFalso {
  _SemeadoNoMeio(super.servidor);
  void Function()? aoSondar;
  bool _sondou = false;
  @override
  Future<Map<String, dynamic>> espelhoPuxar(String? desde, {int limite = 2000}) async {
    if (!_sondou) {
      _sondou = true;
      final r = await super.espelhoPuxar(desde, limite: limite);
      aoSondar?.call();
      return r;
    }
    return super.espelhoPuxar(desde, limite: limite);
  }
}
