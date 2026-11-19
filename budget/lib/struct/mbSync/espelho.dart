import 'dart:async';
import 'dart:convert';

import 'package:budget/main.dart' show appStateKey;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart' show mbLerEstado;
import 'package:budget/struct/mbSync/agendador.dart' show mbAgendador;
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/configuracoes.dart' show mbConfigLocal;
import 'package:budget/struct/mbSync/espelhoTriggers.dart';
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

bool mbEspelhoLigado() => appStateSettings['mbEspelho'] == true;

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

  Future<MbEstruturaTabela?> _estrutura(String tabela) async => _estruturas.containsKey(tabela)
      ? _estruturas[tabela]
      : _estruturas[tabela] = await mbEstruturaTabela(db, tabela);

  Future<void> _gravarEstado(String chave, String valor) => db.customStatement(
      'INSERT OR REPLACE INTO mb_estado (chave, valor) VALUES (?, ?)', [chave, valor]);

  /// Envia e depois puxa. Nunca lança: falha vira `false` e o agendador tenta de novo.
  Future<bool> sincronizar() async {
    try {
      await enviar();
      await puxar();
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('Espelho: falha ao sincronizar: $e');
      return false;
    }
  }

  // --- envio ---

  Future<void> enviar() async {
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

  Future<void> puxar() async {
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

  /// Só o `server_at` do cursor, 30 s antes (as páginas seguintes usam o cursor exato).
  String? _recuar(String? cursor) {
    if (cursor == null) return null;
    final t = DateTime.tryParse(cursor.split('|').first);
    return t == null ? cursor : t.subtract(const Duration(seconds: 30)).toUtc().toIso8601String();
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
}

/// Chave de `mb_estado` com o id que o servidor deu a este aparelho (usado para ignorar o próprio `mudou`).
const String mbChaveAparelhoServidor = 'espelho_aparelho_servidor';

/// Liga o espelho a este aparelho: banco global, configurações e cliente HTTP do pareamento.
Future<bool> mbEspelhoSincronizar() async {
  final cliente = await mbClienteConfigurado();
  if (cliente == null) return false;
  return MbEspelho(
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
  ).sincronizar();
}
