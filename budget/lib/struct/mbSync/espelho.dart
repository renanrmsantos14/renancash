import 'dart:async';
import 'dart:convert';

import 'package:budget/main.dart' show appStateKey;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart' show mbLerEstado, mbMigrarRevisoes;
import 'package:budget/struct/mbSync/agendador.dart' show mbAgendador;
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/configuracoes.dart' show mbConfigLocal;
import 'package:budget/struct/mbSync/espelhoTriggers.dart';
import 'package:budget/struct/mbSync/registro.dart' show isoMs;
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

const int _lotePush = 500; // o Worker aceita até 500 linhas por POST
const int _lotePull = 2000;

/// Marcações de Classificar (`ia_revisados`, `ia_padroes`) e de Arrumar (`arrumar_juntados`) vivem em `mb_estado`
/// e viajam na entidade `_config` com pk `estado:<chave>`; as demais chaves de `mb_estado` são derivadas.
const Set<String> mbEstadoEspelhado = {'ia_revisados', 'ia_padroes', 'arrumar_juntados'};
const String _prefixoEstado = 'estado:';

/// Fase do espelho neste aparelho; a tela de confirmação e a de espera reagem a ela.
///
/// `confirmar` e `confirmarTroca` são só do Android (o usuário decide); `erro` guarda a falha do semeio ou da troca
/// em [mbErroEspelho] até a próxima tentativa.
enum MbFaseEspelho {
  desconhecida,
  indisponivel,
  aguardando,
  confirmar,
  confirmarTroca,
  semeando,
  trocando,
  erro,
  pronto,
}

final ValueNotifier<MbFaseEspelho> mbFaseEspelho = ValueNotifier(MbFaseEspelho.desconhecida);

/// Texto de andamento do semeio ou da troca ("Enviando 1500 de 4000").
final ValueNotifier<String> mbProgressoEspelho = ValueNotifier('');

/// Mensagem da última falha do semeio ou da troca (fase `erro`).
final ValueNotifier<String> mbErroEspelho = ValueNotifier('');

/// Por que o espelho está como está ("sem pareamento", "HTTP 401: ...", "adiado pelo usuário"). Atualizado a cada
/// decisão do agendador e mostrado em Configurações > Meu Banco, para não depender de adivinhar em produção.
final ValueNotifier<String> mbDiagnosticoEspelho = ValueNotifier('o agendador ainda não rodou');

/// Alterações do Meu Banco ainda não enviadas (`mb_registros.pendente`) que a troca pela nuvem descartaria.
final ValueNotifier<int> mbPendentesAntesDaTroca = ValueNotifier(0);

/// Este aparelho já semeou ou trocou os dados pela nuvem (`mb_estado.espelho_pronto`). Carregado por
/// `mbEspelhoReavaliar`; sem isso o espelho fica desligado, mesmo com o Worker respondendo.
final ValueNotifier<bool> mbEspelhoPronto = ValueNotifier(false);

const String mbChaveProntoEspelho = 'espelho_pronto';
const String mbChaveSemeioEspelho = 'espelho_semeio';
const String _chaveSemeio = mbChaveSemeioEspelho;

/// Gravada antes de enviar o último lote do semeio e apagada quando o aparelho fica pronto. Se a resposta desse lote
/// se perder, o servidor já está semeado por este aparelho: a próxima rodada conclui o semeio em vez de trocar os
/// dados locais pelos da nuvem (o que descartaria a fila e o que o servidor rejeitou).
const String _chaveSemeioFim = 'espelho_semeio_fim';
const int _loteSemeio = 500;

/// `mbEspelho` nas configurações é só o desligamento de emergência (`false`); `true` força (desenvolvimento e
/// testes). Ausente, o espelho liga sozinho quando `GET /api/espelho` responde e o aparelho está pronto.
bool mbEspelhoLigado() {
  return mbEspelhoPermitido() && (appStateSettings['mbEspelho'] == true || mbEspelhoPronto.value);
}

/// O desligamento de emergência (`mbEspelho = false`) não está ativo: o agendador e o WebSocket do espelho podem rodar.
bool mbEspelhoPermitido() => appStateSettings['mbEspelho'] != false;

bool _estadoCarregado = false;

@visibleForTesting
void mbEspelhoDescarregarEstado() => _estadoCarregado = false;

/// Carrega `espelho_pronto` de `mb_estado` para [mbEspelhoPronto] (uma vez). Quem decide pelo espelho antes de o
/// agendador ter rodado (o sync antigo no boot) chama isto primeiro, senão `mbEspelhoLigado()` ainda diria "desligado".
Future<void> mbEspelhoCarregarEstado({bool forcar = false}) async {
  if (_estadoCarregado && !forcar) return;
  mbEspelhoPronto.value = await mbLerEstado(mbChaveProntoEspelho) == '1';
  _estadoCarregado = true;
}

/// Enfileira uma entrada de `_config` (configuração ou marcação). Só entra se o espelho está ativo e o pull não está
/// aplicando; é a mesma regra dos triggers.
Future<void> mbEspelhoEnfileirarConfig(String pk) async {
  await database.customStatement(
      "INSERT INTO mb_saida (tabela, pk, em) SELECT '$mbEntidadeConfig', ?, $mbAgoraSql WHERE $mbEspelhoLigadoSql "
      'ON CONFLICT (tabela, pk) DO UPDATE SET em = excluded.em',
      [pk]);
  // SQL cru não avisa os streams: o agendador do espelho escuta `mb_saida` para enviar depois do debounce.
  database.notifyUpdates({TableUpdate(mbTabelaSaida)});
}

/// Configuração mudou por ação do usuário: sincroniza se não for de aparência.
Future<void> mbEspelhoConfigMudou(String chave) async {
  if (mbEspelhoLigado() && !mbConfigLocal(chave)) await mbEspelhoEnfileirarConfig(chave);
}

/// Marcação de Classificar/Arrumar gravada em `mb_estado`.
Future<void> mbEspelhoEstadoMudou(Iterable<String> chaves) async {
  if (!mbEspelhoLigado()) return;
  for (final c in chaves.where(mbEstadoEspelhado.contains)) {
    await mbEspelhoEnfileirarConfig('$_prefixoEstado$c');
  }
}

/// pks que foram apagadas (aqui ou em outro aparelho): o mapeador do Meu Banco não as recria. Vazio com o espelho
/// desligado, para o comportamento antigo seguir igual.
Future<Set<String>> mbEspelhoApagadas(String tabela) async {
  if (!mbEspelhoLigado()) return {};
  final l = await database.customSelect('SELECT pk FROM mb_apagados WHERE tabela = ?',
      variables: [Variable<String>(tabela)]).get();
  return {for (final x in l) x.read<String>('pk')};
}

/// UUID deste aparelho no espelho; o servidor o usa no desempate e no aviso `mudou`.
Future<String> mbEspelhoAparelhoId(GeneratedDatabase db) async {
  var id = await mbLerEstado('espelho_aparelho', db);
  if (id == null) {
    id = const Uuid().v4();
    await db.customStatement(
        'INSERT OR REPLACE INTO mb_estado (chave, valor) VALUES (?, ?)', ['espelho_aparelho', id]);
  }
  return id;
}

/// Cliente do espelho completo: envia a fila `mb_saida`, puxa e aplica o que veio dos outros aparelhos.
/// Um banco e um servidor por instância, para os testes simularem dois aparelhos.
class MbEspelho {
  MbEspelho({
    required this.db,
    required this.cliente,
    required this.configuracoes,
    required this.aplicarConfig,
    this.aoAplicarConfigs,
    this.aoNotificar,
  });

  final GeneratedDatabase db;
  final MbCliente cliente;

  /// Configurações do app (`appStateSettings`); só as chaves enfileiradas são lidas daqui.
  final Map<String, dynamic> Function() configuracoes;

  /// Aplica uma configuração vinda do servidor sem reenfileirá-la.
  final Future<void> Function(String chave, Object? valor) aplicarConfig;

  /// Uma vez, no fim do pull que trouxe configurações (a tela se refaz uma vez só, não por chave).
  final void Function()? aoAplicarConfigs;

  /// Logo antes de avisar os streams do que o pull gravou, para o sync antigo não tratar como edição do usuário.
  final void Function()? aoNotificar;

  final Map<String, MbEstruturaTabela?> _estruturas = {};

  /// Um só trabalho por vez neste banco: enviar, puxar, semear e trocar pela nuvem nunca se intercalam (a troca
  /// apaga o que um pull em andamento estaria aplicando e regravaria o cursor).
  static final Expando<Future<void>> _travas = Expando('espelho');

  Future<T> _exclusivo<T>(Future<T> Function() acao) async {
    final anterior = _travas[db];
    final liberar = Completer<void>();
    _travas[db] = liberar.future;
    try {
      if (anterior != null) await anterior;
      return await acao();
    } finally {
      liberar.complete();
    }
  }

  Future<MbEstruturaTabela?> _estrutura(String tabela) async => _estruturas.containsKey(tabela)
      ? _estruturas[tabela]
      : _estruturas[tabela] = await mbEstruturaTabela(db, tabela);

  Future<void> _gravarEstado(String chave, String valor) => db.customStatement(
      'INSERT OR REPLACE INTO mb_estado (chave, valor) VALUES (?, ?)', [chave, valor]);

  /// Envia e depois puxa. Nunca lança: falha vira `false` e o agendador tenta de novo.
  Future<bool> sincronizar() => _exclusivo(() async {
        try {
          await _enviar();
          await _puxar();
          return true;
        } catch (e) {
          if (kDebugMode) debugPrint('Espelho: falha ao sincronizar: $e');
          return false;
        }
      });

  // --- envio ---

  Future<void> enviar() => _exclusivo(_enviar);

  Future<void> _enviar() async {
    final id = await mbEspelhoAparelhoId(db);
    while (true) {
      final fila = await db
          .customSelect('SELECT tabela, pk, em FROM mb_saida ORDER BY em, tabela, pk LIMIT ?',
              variables: [Variable<int>(_lotePush)])
          .get();
      if (fila.isEmpty) return;
      final linhas = <Map<String, dynamic>>[];
      for (final f in fila) {
        final l = await _montar(f.read<String>('tabela'), f.read<String>('pk'), f.read<String>('em'));
        if (l != null) linhas.add(l);
      }
      if (linhas.isNotEmpty) await _tratarResposta(await cliente.espelhoEnviar(id, linhas));
      // `em` na condição: edição feita durante o envio troca o `em` e continua na fila.
      for (final f in fila) {
        await db.customStatement('DELETE FROM mb_saida WHERE tabela = ? AND pk = ? AND em = ?',
            [f.read<String>('tabela'), f.read<String>('pk'), f.read<String>('em')]);
      }
      if (fila.length < _lotePush) return;
    }
  }

  /// Perdeu a disputa (`mais_antiga`): aplica a versão vencedora que o servidor mandou. Outros motivos (tamanho,
  /// tabela desconhecida) saem da fila, mas ficam em `mb_estado.espelho_rejeitados` para diagnóstico.
  Future<void> _tratarResposta(Map<String, dynamic> r) async {
    await _guardarAparelhoServidor(r);
    final perdidas = <Map<String, dynamic>>[];
    final outras = <Map<String, dynamic>>[];
    for (final x in (r['rejeitados'] as List? ?? const [])) {
      final m = (x as Map).cast<String, dynamic>();
      (m['motivo'] == 'mais_antiga' && m['atual'] is Map ? perdidas : outras).add(m);
    }
    if (perdidas.isNotEmpty) {
      await _aplicarLote([
        for (final m in perdidas)
          {
            'tabela': m['tabela'],
            'pk': m['pk'],
            ...(m['atual'] as Map).cast<String, dynamic>(),
          }
      ], null);
    }
    if (outras.isNotEmpty) await _registrarRejeitadas(outras);
  }

  Future<void> _registrarRejeitadas(List<Map<String, dynamic>> novas) async {
    final antigas = json.decode(await mbLerEstado('espelho_rejeitados', db) ?? '[]') as List;
    final todas = [
      ...antigas,
      for (final m in novas) {'tabela': m['tabela'], 'pk': m['pk'], 'motivo': m['motivo']}
    ];
    await _gravarEstado(
        'espelho_rejeitados', json.encode(todas.sublist(todas.length > 50 ? todas.length - 50 : 0)));
    if (kDebugMode) debugPrint('Espelho: ${novas.length} linha(s) rejeitada(s) pelo servidor');
  }

  /// O servidor devolve o id com que autenticou este aparelho; o aviso `mudou` do WebSocket usa esse id.
  Future<void> _guardarAparelhoServidor(Map<String, dynamic> r) async {
    final id = r['aparelho'];
    if (id is String && id.isNotEmpty && id != await mbLerEstado(mbChaveAparelhoServidor, db)) {
      await _gravarEstado(mbChaveAparelhoServidor, id);
    }
  }

  /// A linha como o servidor a recebe; null quando não há o que enviar (configuração sem valor local).
  Future<Map<String, dynamic>?> _montar(String tabela, String pk, String em) async {
    Map<String, dynamic>? dados;
    if (tabela == mbEntidadeConfig) {
      dados = await _dadosConfig(pk);
      if (dados == null) return null;
    } else {
      final t = await _estrutura(tabela);
      if (t == null) return null;
      final (onde, args) = t.ondePk(pk);
      final l = await db
          .customSelect('SELECT * FROM $tabela WHERE $onde',
              variables: [for (final a in args) Variable<Object>(a)])
          .getSingleOrNull();
      if (l != null) {
        dados = {
          for (final e in l.data.entries)
            if (!mbColunasSemEspelho.contains(e.key)) e.key: e.value
        };
      }
    }
    return {
      'tabela': tabela,
      'pk': pk,
      'dados': dados,
      'updated_at': em,
      'deleted_at': dados == null ? em : null,
    };
  }

  Future<Map<String, dynamic>?> _dadosConfig(String pk) async {
    if (pk.startsWith(_prefixoEstado)) {
      final v = await mbLerEstado(pk.substring(_prefixoEstado.length), db);
      return v == null ? null : {'v': v};
    }
    final c = configuracoes();
    return c.containsKey(pk) ? {'v': c[pk]} : null;
  }

  // --- pull ---

  Future<void> puxar() => _exclusivo(_puxar);

  Future<void> _puxar() async {
    var cursor = await mbLerEstado('espelho_cursor', db);
    var primeira = true;
    configsAplicadas = false;
    await _reaplicarFalhas();
    while (true) {
      // Primeira página recua 30 s no `server_at`: linha gravada pelo servidor com relógio atrasado não se perde.
      final r = await cliente.espelhoPuxar(primeira ? _recuar(cursor) : cursor, limite: _lotePull);
      primeira = false;
      await _guardarAparelhoServidor(r);
      // Antes do semeio o servidor não tem dados: não há o que aplicar.
      if (r['semeado'] != true) break;
      final linhas = [for (final l in (r['linhas'] as List? ?? const [])) (l as Map).cast<String, dynamic>()];
      final novo = r['cursor'] as String?;
      // Cursor só anda para a frente (a primeira página recuada devolve linhas antigas).
      final adotar = linhas.isNotEmpty && novo != null && (cursor == null || novo.compareTo(cursor) > 0);
      await _aplicarLote(linhas, adotar ? novo : null);
      if (adotar) cursor = novo;
      if (r['mais'] != true || linhas.isEmpty) break;
    }
    if (configsAplicadas) aoAplicarConfigs?.call();
  }

  /// Só o `server_at` do cursor, 30 s antes; `|tabela|pk` segue junto porque o Worker exige o cursor completo
  /// (as páginas seguintes usam o cursor exato).
  String? _recuar(String? cursor) {
    if (cursor == null) return null;
    final i = cursor.indexOf('|');
    final t = DateTime.tryParse(i < 0 ? cursor : cursor.substring(0, i));
    if (t == null) return cursor;
    return t.subtract(const Duration(seconds: 30)).toUtc().toIso8601String() + (i < 0 ? '' : cursor.substring(i));
  }

  bool configsAplicadas = false;

  Future<void> _aplicarLote(List<Map<String, dynamic>> linhas, String? cursor) async {
    final tocadas = <String>{};
    final configs = <(String, Object?)>[];
    await db.transaction(() async {
      await db.customStatement('UPDATE mb_espelho_ctl SET aplicando = 1 WHERE id = 0');
      for (final l in linhas) {
        if (await _aplicarLinha(l, configs)) tocadas.add(l['tabela'] as String);
      }
      // Uma falha antiga pode ter sido resolvida por esta página: mantém o contador em dia.
      if (linhas.isNotEmpty && await mbLerEstado('espelho_falhas', db) != await _contarFalhas()) {
        await _gravarEstado('espelho_falhas', await _contarFalhas());
      }
      // Na mesma transação: o cursor nunca passa de dados que não foram gravados.
      if (cursor != null) await _gravarEstado('espelho_cursor', cursor);
      await db.customStatement('UPDATE mb_espelho_ctl SET aplicando = 0 WHERE id = 0');
    });
    // Configurações vão para o SharedPreferences, fora da transação do banco.
    for (final (chave, valor) in configs) {
      await aplicarConfig(chave, valor);
      configsAplicadas = true;
    }
    // SQL cru não avisa os streams do Drift: sem isto as telas não veem o que chegou.
    if (tocadas.isNotEmpty) {
      aoNotificar?.call();
      db.notifyUpdates({for (final t in tocadas) TableUpdate(t)});
    }
  }

  /// true se mexeu em tabela. Configurações remotas entram em [configs] e são aplicadas depois da transação.
  Future<bool> _aplicarLinha(Map<String, dynamic> l, List<(String, Object?)> configs) async {
    final tabela = l['tabela'] as String;
    final pk = l['pk'] as String;
    final em = l['updated_at'] as String;
    if (tabela != mbEntidadeConfig && !mbTabelasEspelhadas.contains(tabela)) return false;
    final pendente = await db.customSelect('SELECT em FROM mb_saida WHERE tabela = ? AND pk = ?',
        variables: [Variable<String>(tabela), Variable<String>(pk)]).getSingleOrNull();
    // Edição local mais nova que a remota: vence a local, que ainda vai subir.
    if (pendente != null && pendente.read<String>('em').compareTo(em) > 0) return false;
    await db.customStatement('DELETE FROM mb_saida WHERE tabela = ? AND pk = ?', [tabela, pk]);
    final dados = l['dados'];
    final apagada = dados is! Map || l['deleted_at'] != null;
    if (tabela == mbEntidadeConfig) {
      if (!apagada) await _aplicarConfigRemota(pk, dados['v'], configs);
      return false;
    }
    final t = await _estrutura(tabela);
    if (t == null) return false;
    await _limparFalha(tabela, pk);
    if (apagada) {
      final (onde, args) = t.ondePk(pk);
      await db.customStatement('DELETE FROM $tabela WHERE $onde', args);
      await db.customStatement(
          'INSERT OR REPLACE INTO mb_apagados (tabela, pk, em) VALUES (?, ?, ?)', [tabela, pk, em]);
      return true;
    }
    await db.customStatement('DELETE FROM mb_apagados WHERE tabela = ? AND pk = ?', [tabela, pk]);
    return _upsert(t, pk, dados.cast<String, dynamic>());
  }

  Future<bool> _upsert(MbEstruturaTabela t, String pk, Map<String, dynamic> dados) async {
    // Só colunas que este aparelho conhece: coluna de versão mais nova do app fica de fora.
    final cols = [
      for (final c in t.enviadas)
        if (dados.containsKey(c)) c
    ];
    if (!t.pk.every(cols.contains)) return false;
    final demais = [for (final c in cols) if (!t.pk.contains(c)) c];
    final q = mbAspas;
    final sql = 'INSERT INTO ${t.nome} (${cols.map(q).join(', ')}) VALUES (${List.filled(cols.length, '?').join(', ')}) '
        'ON CONFLICT (${t.pk.map(q).join(', ')}) DO ${demais.isEmpty ? 'NOTHING' : 'UPDATE SET ${[for (final c in demais) '${q(c)} = excluded.${q(c)}'].join(', ')}'}';
    try {
      await db.customStatement(sql, [for (final c in cols) dados[c]]);
      return true;
    } catch (e) {
      // Não trava o cursor: a linha fica em mb_espelho_falhas e o próximo pull tenta de novo.
      if (kDebugMode) debugPrint('Espelho: linha com falha em ${t.nome}: $e');
      await db.customStatement(
          'INSERT OR REPLACE INTO mb_espelho_falhas (tabela, pk, dados, erro) VALUES (?, ?, ?, ?)',
          [t.nome, pk, json.encode(dados), '$e']);
      await _gravarEstado('espelho_falhas', await _contarFalhas());
      return false;
    }
  }

  Future<String> _contarFalhas() async =>
      '${(await db.customSelect('SELECT COUNT(*) n FROM mb_espelho_falhas').getSingle()).read<int>('n')}';

  Future<void> _limparFalha(String tabela, String pk) =>
      db.customStatement('DELETE FROM mb_espelho_falhas WHERE tabela = ? AND pk = ?', [tabela, pk]);

  Future<void> _reaplicarFalhas() async {
    final falhas = await db.customSelect('SELECT tabela, pk, dados FROM mb_espelho_falhas').get();
    if (falhas.isEmpty) return;
    await db.transaction(() async {
      await db.customStatement('UPDATE mb_espelho_ctl SET aplicando = 1 WHERE id = 0');
      for (final f in falhas) {
        final tabela = f.read<String>('tabela');
        final pk = f.read<String>('pk');
        final t = await _estrutura(tabela);
        if (t == null) continue;
        await _limparFalha(tabela, pk);
        await _upsert(t, pk, (json.decode(f.read<String>('dados')) as Map).cast<String, dynamic>());
      }
      await _gravarEstado('espelho_falhas', await _contarFalhas());
      await db.customStatement('UPDATE mb_espelho_ctl SET aplicando = 0 WHERE id = 0');
    });
    db.notifyUpdates({for (final f in falhas) TableUpdate(f.read<String>('tabela'))});
  }

  Future<void> _aplicarConfigRemota(String pk, Object? valor, List<(String, Object?)> configs) async {
    if (pk.startsWith(_prefixoEstado)) {
      final chave = pk.substring(_prefixoEstado.length);
      if (mbEstadoEspelhado.contains(chave) && valor is String) await _gravarEstado(chave, valor);
    } else if (!mbConfigLocal(pk)) {
      configs.add((pk, valor));
    }
  }

  // --- semeio (Android) e troca pela nuvem (os outros aparelhos) ---

  Future<bool> estaPronto() async => await mbLerEstado(mbChaveProntoEspelho, db) == '1';

  /// Decide o que este aparelho faz com o espelho e executa. Pronto: nada. Servidor sem espelho (404): nada.
  /// Servidor semeado: troca os dados locais pelos da nuvem (a web troca sozinha; o Android pede `confirmado`
  /// porque a troca descarta o que só existe nele). Não semeado: a web espera; o Android pede confirmação e então
  /// semeia, retomando um semeio interrompido sem perguntar de novo.
  /// `protegido` envolve as operações longas (o sync antigo não pode rodar no meio delas).
  Future<MbFaseEspelho> avaliar({
    required bool podeSemear,
    bool confirmado = false,
    void Function(MbFaseEspelho fase)? aoFase,
    Future<void> Function(Future<void> Function() acao)? protegido,
  }) async {
    MbFaseEspelho fase(MbFaseEspelho f) {
      aoFase?.call(f);
      return f;
    }

    final proteger = protegido ?? (a) => a();
    if (await estaPronto()) return fase(MbFaseEspelho.pronto);
    final Map<String, dynamic> r;
    try {
      r = await cliente.espelhoPuxar(null, limite: 1);
    } on MbErroHttp catch (e) {
      if (e.status == 404) return fase(MbFaseEspelho.indisponivel);
      rethrow;
    }
    await _guardarAparelhoServidor(r);
    Future<MbFaseEspelho> trocar() async {
      fase(MbFaseEspelho.trocando);
      await proteger(substituirPelaNuvem);
      return fase(MbFaseEspelho.pronto);
    }

    Future<MbFaseEspelho> trocarOuConfirmar() async {
      if (!podeSemear || confirmado) return trocar();
      mbPendentesAntesDaTroca.value = await _pendentesAntigos();
      return fase(MbFaseEspelho.confirmarTroca);
    }

    if (r['semeado'] == true) {
      final quem = r['semeado_por'];
      if (podeSemear && quem is String && quem.isNotEmpty && quem == r['aparelho'] &&
          await mbLerEstado(_chaveSemeioFim, db) != null) {
        // Sem cursor: o primeiro pull relê tudo (LWW, idempotente) e a fila sobe normalmente.
        await _marcarPronto(null);
        return fase(MbFaseEspelho.pronto);
      }
      return trocarOuConfirmar();
    }
    if (!podeSemear) return fase(MbFaseEspelho.aguardando);
    final emAndamento = await mbLerEstado(_chaveSemeio, db) != null;
    if (!confirmado && !emAndamento) return fase(MbFaseEspelho.confirmar);
    fase(MbFaseEspelho.semeando);
    try {
      await proteger(semearDoCelular);
    } on MbErroHttp catch (e) {
      // Outro aparelho semeou antes: este vira réplica.
      if (e.status == 409 && e.mensagem.contains('ja_semeado')) return trocarOuConfirmar();
      rethrow;
    }
    return fase(MbFaseEspelho.pronto);
  }

  /// Alterações do sync antigo (`mb_registros.pendente`) que ainda não subiram; a troca pela nuvem as descarta.
  Future<int> _pendentesAntigos() async {
    final existe = await db
        .customSelect("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'mb_registros'")
        .get();
    if (existe.isEmpty) return 0;
    return (await db.customSelect('SELECT COUNT(*) n FROM mb_registros WHERE pendente = 1').getSingle())
        .read<int>('n');
  }

  /// Envia tudo o que o espelho cobre, em lotes numerados de 0 (o servidor guarda o andamento). O progresso fica em
  /// `mb_estado.espelho_semeio` e uma falha retoma do último lote confirmado. Só no fim, depois do `fim` aceito,
  /// o cursor e `espelho_pronto` são gravados.
  ///
  /// Durante o semeio a fila (`mb_saida`) já está ligada: o que o usuário editar entre tentativas (ou depois da
  /// leitura das linhas) fica na fila e sobe com a primeira sincronização, em vez de se perder.
  Future<void> semearDoCelular({int tamanho = _loteSemeio}) => _exclusivo(() => _semear(tamanho));

  Future<void> _semear(int tamanho) async {
    await mbMigrarRevisoes(db);
    final salvo = await mbLerEstado(_chaveSemeio, db);
    final retomada = salvo == null ? null : (json.decode(salvo) as Map).cast<String, dynamic>();
    if (retomada == null) await db.customStatement('DELETE FROM mb_saida');
    await db.customStatement('UPDATE mb_espelho_ctl SET ativo = 1 WHERE id = 0');
    // `em` fixo no semeio inteiro: uma retomada reenvia as mesmas linhas com a mesma data.
    final em = (retomada?['em'] as String?) ?? isoMs(DateTime.now());
    var lote = (retomada?['lote'] as num?)?.toInt() ?? 0;
    final ultima = retomada?['ultima'] as String?;
    final todas = await _linhasSemeio(em);
    final pendentes = [for (final l in todas) if (ultima == null || l.chave.compareTo(ultima) > 0) l];
    var enviadas = todas.length - pendentes.length;
    Map<String, dynamic> resposta;
    var i = 0;
    try {
      do {
        final fatia = pendentes.skip(i).take(tamanho).toList();
        i += fatia.length;
        final fim = i >= pendentes.length;
        mbProgressoEspelho.value = 'Enviando ${enviadas + fatia.length} de ${todas.length}';
        if (fim) await _gravarEstado(_chaveSemeioFim, em);
        resposta = await cliente.espelhoSemear(lote, [for (final l in fatia) l.linha], fim: fim);
        enviadas += fatia.length;
        lote++;
        if (!fim) {
          await _gravarEstado(_chaveSemeio, json.encode({'lote': lote, 'ultima': fatia.last.chave, 'em': em}));
        }
      } while (i < pendentes.length);
    } on MbErroHttp catch (e) {
      // O servidor perdeu o semeio em andamento: o andamento guardado aqui não vale mais, recomeça do lote 0.
      if (retomada != null && e.status == 409 && e.mensagem.contains('semeio_nao_iniciado')) {
        await db.customStatement('DELETE FROM mb_estado WHERE chave = ?', [_chaveSemeio]);
        return _semear(tamanho);
      }
      rethrow;
    }
    await _guardarAparelhoServidor(resposta);
    await _marcarPronto(resposta['cursor'] as String?);
  }

  /// Linhas do semeio em ordem estável (tabela na ordem do espelho, depois pk): a chave serve para retomar.
  Future<List<({String chave, Map<String, dynamic> linha})>> _linhasSemeio(String em) async {
    final saida = <({String chave, Map<String, dynamic> linha})>[];
    void somar(int ordem, String tabela, String pk, Map<String, dynamic> dados) => saida.add((
          chave: '${ordem.toString().padLeft(3, '0')}|$pk',
          linha: {'tabela': tabela, 'pk': pk, 'dados': dados, 'updated_at': em, 'deleted_at': null},
        ));
    for (var i = 0; i < mbTabelasEspelhadas.length; i++) {
      final t = await _estrutura(mbTabelasEspelhadas[i]);
      if (t == null) continue;
      final linhas = await db.customSelect('SELECT x.*, ${t.pkSql('x')} AS _pk FROM ${t.nome} x').get();
      for (final l in linhas) {
        somar(i, t.nome, l.read<String>('_pk'), {
          for (final c in t.enviadas) c: l.data[c],
        });
      }
    }
    final ordemConfig = mbTabelasEspelhadas.length;
    for (final e in configuracoes().entries) {
      if (e.value == null || mbConfigLocal(e.key)) continue;
      final txt = json.encode(e.value);
      if (txt.length > 4000) continue; // limite do valor no Worker
      somar(ordemConfig, mbEntidadeConfig, e.key, {'v': e.value});
    }
    for (final c in mbEstadoEspelhado) {
      final v = await mbLerEstado(c, db);
      if (v != null) somar(ordemConfig, mbEntidadeConfig, '$_prefixoEstado$c', {'v': v});
    }
    saida.sort((a, b) => a.chave.compareTo(b.chave));
    return saida;
  }

  Future<void> _marcarPronto(String? cursor) => db.transaction(() async {
        if (cursor != null) await _gravarEstado('espelho_cursor', cursor);
        await _gravarEstado(mbChaveProntoEspelho, '1');
        await db.customStatement('DELETE FROM mb_estado WHERE chave IN (?, ?)', [_chaveSemeio, _chaveSemeioFim]);
        await db.customStatement('UPDATE mb_espelho_ctl SET ativo = 1 WHERE id = 0');
      }).then((_) {
        mbEspelhoPronto.value = true;
        _estadoCarregado = true;
      });

  /// Apaga os dados espelhados deste aparelho, baixa tudo da nuvem e marca o aparelho como pronto. A aparência
  /// (`mbConfigLocal`) e o pareamento ficam. Se o download cair no meio, o aparelho continua não pronto e a
  /// próxima rodada refaz a troca do zero.
  Future<void> substituirPelaNuvem() => _exclusivo(_substituir);

  Future<void> _substituir() async {
    mbProgressoEspelho.value = 'Baixando os dados da nuvem';
    await db.transaction(() async {
      await db.customStatement('UPDATE mb_espelho_ctl SET aplicando = 1 WHERE id = 0');
      for (final t in mbTabelasEspelhadas) {
        // A carteira e a categoria '0' existem em todo aparelho.
        final resto = switch (t) {
          'wallets' => " WHERE wallet_pk <> '0'",
          'categories' => " WHERE category_pk <> '0'",
          _ => '',
        };
        await db.customStatement('DELETE FROM $t$resto');
      }
      for (final t in const ['mb_apagados', 'mb_saida', 'mb_espelho_falhas']) {
        await db.customStatement('DELETE FROM $t');
      }
      // Sync antigo (F5 remove): o que ele guardou descreve dados que acabaram de sair.
      final antigas = await db.customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('mb_registros', 'mb_aplicado')").get();
      for (final a in antigas) {
        await db.customStatement('DELETE FROM ${a.read<String>('name')}');
      }
      await db.customStatement(
          "DELETE FROM mb_estado WHERE chave NOT LIKE 'espelho\\_%' ESCAPE '\\' OR chave IN ('espelho_cursor', 'espelho_semeio', 'espelho_semeio_fim', 'espelho_falhas', 'espelho_rejeitados', ?)",
          [mbChaveProntoEspelho]);
      await db.customStatement('UPDATE mb_espelho_ctl SET aplicando = 0 WHERE id = 0');
    });
    db.notifyUpdates({for (final t in mbTabelasEspelhadas) TableUpdate(t)});
    await aplicarConfig('selectedWalletPk', '0');
    await _puxar();
    await _marcarPronto(null);
  }
}

/// Chave de `mb_estado` com o id que o servidor deu a este aparelho (usado para ignorar o próprio `mudou`).
const String mbChaveAparelhoServidor = 'espelho_aparelho_servidor';

/// O espelho deste aparelho: banco global, configurações e cliente HTTP do pareamento.
MbEspelho mbEspelhoDoApp(MbCliente cliente) => MbEspelho(
      db: database,
      cliente: cliente,
      configuracoes: () => appStateSettings,
      aplicarConfig: (chave, valor) {
        // Igual ao que já está: não refaz nada por isso.
        if (json.encode(appStateSettings[chave]) == json.encode(valor)) return Future.value();
        return updateSettings(chave, valor, updateGlobalState: false, sincronizar: false);
      },
      aoAplicarConfigs: () => appStateKey.currentState?.refreshAppState(),
      aoNotificar: mbAgendador.fimDeRodada,
    );

/// Envia e puxa (aparelho pronto).
Future<bool> mbEspelhoSincronizar() async {
  final cliente = await mbClienteConfigurado();
  return cliente != null && await mbEspelhoDoApp(cliente).sincronizar();
}
