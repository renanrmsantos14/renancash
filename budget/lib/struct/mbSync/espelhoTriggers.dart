import 'dart:convert';

import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/linha.dart';
import 'package:drift/drift.dart';

/// Tabelas espelhadas, no mesmo formato do servidor (`ALLOWLIST` do Worker). Único lugar do app com esta lista.
const List<String> mbTabelasEspelhadas = [
  'wallets',
  'transactions',
  'categories',
  'category_budget_limits',
  'associated_titles',
  'budgets',
  'scanner_templates',
  'objectives',
  'mb_orcamento_tx',
  'mb_meta_aplicacao',
  'mb_revisoes',
];

/// Entidade virtual do espelho: configurações (pk = chave) e marcações de Classificar/Arrumar (pk = `estado:<chave>`).
const String mbEntidadeConfig = '_config';

const String mbTabelaSaida = 'mb_saida';

// Fila coalescida: uma linha por (tabela, pk); `em` é a hora da última edição local.
const String mbDdlSaida = 'CREATE TABLE IF NOT EXISTS mb_saida ('
    'tabela TEXT NOT NULL, pk TEXT NOT NULL, em TEXT NOT NULL, PRIMARY KEY (tabela, pk))';

// Uma linha só (id 0). `aplicando`: o pull está gravando dados remotos (os triggers não enfileiram).
// `ativo`: espelho ligado; desligado, a fila não cresce. Fica em `main` porque trigger não enxerga `temp`.
const String mbDdlEspelhoCtl = 'CREATE TABLE IF NOT EXISTS mb_espelho_ctl ('
    'id INTEGER PRIMARY KEY CHECK (id = 0), aplicando INTEGER NOT NULL DEFAULT 0, ativo INTEGER NOT NULL DEFAULT 0)';

// O que veio apagado do servidor: o mapeador do Meu Banco não recria essas linhas.
const String mbDdlApagados = 'CREATE TABLE IF NOT EXISTS mb_apagados ('
    'tabela TEXT NOT NULL, pk TEXT NOT NULL, em TEXT NOT NULL, PRIMARY KEY (tabela, pk))';

// Linha que não pôde ser aplicada neste aparelho (coluna obrigatória faltando etc.): o pull tenta de novo.
const String mbDdlFalhas = 'CREATE TABLE IF NOT EXISTS mb_espelho_falhas ('
    'tabela TEXT NOT NULL, pk TEXT NOT NULL, dados TEXT NOT NULL, erro TEXT, PRIMARY KEY (tabela, pk))';

// Decisões de revisão (`tx:<id>`, `dest:<nome>`); a migração das revisões de mb_registros é da F3.
const String mbDdlRevisoes = 'CREATE TABLE IF NOT EXISTS mb_revisoes ('
    'pk TEXT PRIMARY KEY, dados TEXT)';

const String mbAgoraSql = "strftime('%Y-%m-%dT%H:%M:%fZ','now')";
const String mbEspelhoLigadoSql = '(SELECT aplicando = 0 AND ativo = 1 FROM mb_espelho_ctl WHERE id = 0)';

const String _colunaModificado = 'date_time_modified';

/// Colunas que não viajam, com o nome do SQLite (`methodAdded` -> `method_added`). `date_time_modified` viaja (o
/// outro aparelho precisa saber que a transação `mb:` foi editada), mas não conta como mudança nos triggers.
final Set<String> mbColunasSemEspelho = {
  for (final c in mbLinhaSem)
    c.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}')
}..remove(_colunaModificado);

/// Nome de coluna entre aspas: `order` e outras palavras reservadas são colunas do Drift.
String mbAspas(String coluna) => '"$coluna"';

class MbEstruturaTabela {
  final String nome;
  final List<String> colunas; // todas, na ordem do SQLite
  final List<String> pk; // na ordem da chave
  const MbEstruturaTabela(this.nome, this.colunas, this.pk);

  /// Colunas que entram no envio.
  List<String> get enviadas =>
      [for (final c in colunas) if (!mbColunasSemEspelho.contains(c)) c];

  /// Colunas cuja mudança enfileira a linha.
  List<String> get comparadas => [for (final c in enviadas) if (c != _colunaModificado) c];

  /// Valor da pk como texto: a própria coluna, ou um array JSON quando a chave é composta.
  String pkSql(String linha) => pk.length == 1
      ? '$linha.${mbAspas(pk.first)}'
      : 'json_array(${[for (final c in pk) '$linha.${mbAspas(c)}'].join(', ')})';

  /// Condição SQL (placeholders `?`) e argumentos que localizam a linha pelo texto da pk.
  (String, List<Object?>) ondePk(String pkTexto) {
    if (pk.length == 1) return ('${mbAspas(pk.first)} = ?', [pkTexto]);
    return ([for (final c in pk) '${mbAspas(c)} = ?'].join(' AND '), jsonDecode(pkTexto) as List);
  }
}

Future<MbEstruturaTabela?> mbEstruturaTabela(
    GeneratedDatabase db, String tabela) async {
  final linhas = await db.customSelect('PRAGMA table_info($tabela)').get();
  if (linhas.isEmpty) return null;
  final pk = [
    for (final l in linhas)
      if (l.read<int>('pk') > 0) (l.read<int>('pk'), l.read<String>('name'))
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return MbEstruturaTabela(tabela, [for (final l in linhas) l.read<String>('name')],
      [for (final p in pk) p.$2]);
}

// FNV-1a de 32 bits: estável entre execuções (String.hashCode não é).
String _hash(String texto) {
  var h = 0x811c9dc5;
  for (final b in texto.codeUnits) {
    h = ((h ^ (b & 0xff)) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

String _enfileirar(String tabela, String pkExpr) =>
    "INSERT INTO mb_saida (tabela, pk, em) VALUES ('$tabela', $pkExpr, $mbAgoraSql) "
    'ON CONFLICT (tabela, pk) DO UPDATE SET em = excluded.em;';

/// Os três triggers (nome -> SQL) de uma tabela. O hash do SQL inteiro vai no nome: qualquer mudança de coluna, pk ou
/// regra gera outro nome, e `mbEspelhoPrepararBanco` apaga os antigos.
Map<String, String> mbTriggersDaTabela(MbEstruturaTabela t) {
  final base = 'mb_esp_${t.nome}';
  final mudou = [for (final c in t.comparadas) 'OLD.${mbAspas(c)} IS NOT NEW.${mbAspas(c)}'].join(' OR ');
  final apagou = "INSERT OR REPLACE INTO mb_apagados (tabela, pk, em) VALUES ('${t.nome}', %PK%, $mbAgoraSql);";
  final voltou = "DELETE FROM mb_apagados WHERE tabela = '${t.nome}' AND pk = %PK%;";
  // `%N%` vira o nome com o hash depois de calculado.
  final modelos = {
    'ins': 'CREATE TRIGGER IF NOT EXISTS %N% AFTER INSERT ON ${t.nome} WHEN $mbEspelhoLigadoSql BEGIN '
        '${_enfileirar(t.nome, t.pkSql('NEW'))} ${voltou.replaceAll('%PK%', t.pkSql('NEW'))} END',
    // Mudar a pk apaga a linha antiga no servidor: enfileira as duas.
    'upd': 'CREATE TRIGGER IF NOT EXISTS %N% AFTER UPDATE ON ${t.nome} '
        'WHEN $mbEspelhoLigadoSql AND ($mudou) BEGIN ${_enfileirar(t.nome, t.pkSql('NEW'))} '
        "INSERT INTO mb_saida (tabela, pk, em) SELECT '${t.nome}', ${t.pkSql('OLD')}, $mbAgoraSql "
        'WHERE ${t.pkSql('OLD')} IS NOT ${t.pkSql('NEW')} '
        'ON CONFLICT (tabela, pk) DO UPDATE SET em = excluded.em; '
        'INSERT OR REPLACE INTO mb_apagados (tabela, pk, em) SELECT \'${t.nome}\', ${t.pkSql('OLD')}, $mbAgoraSql '
        'WHERE ${t.pkSql('OLD')} IS NOT ${t.pkSql('NEW')}; END',
    // Exclusão local também vale como "apagado": o mapeador do Meu Banco não recria a linha.
    'del': 'CREATE TRIGGER IF NOT EXISTS %N% AFTER DELETE ON ${t.nome} WHEN $mbEspelhoLigadoSql BEGIN '
        '${_enfileirar(t.nome, t.pkSql('OLD'))} ${apagou.replaceAll('%PK%', t.pkSql('OLD'))} END',
  };
  final h = _hash(modelos.values.join('\n'));
  return {
    for (final e in modelos.entries)
      '${base}_${e.key}_$h': e.value.replaceAll('%N%', '${base}_${e.key}_$h'),
  };
}

Future<Set<String>> _nomesNoBanco(GeneratedDatabase db, String tipo,
        [String? padrao]) async =>
    {
      for (final l in await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type = ?1 AND (?2 IS NULL OR name LIKE ?2 ESCAPE '\\')",
              variables: [Variable<String>(tipo), Variable<String>(padrao)])
          .get())
        l.read<String>('name')
    };

/// Cria as tabelas do espelho e os triggers que faltam; apaga os de colunas antigas. Roda em todo `beforeOpen`
/// (barato: só toca no que falta) e é segura com triggers já existentes.
Future<void> mbEspelhoPrepararBanco(GeneratedDatabase db) async {
  for (final ddl in [
    mbDdlOrcamentoTx,
    mbDdlMetaAplicacao,
    mbDdlEstado,
    mbDdlSaida,
    mbDdlEspelhoCtl,
    mbDdlApagados,
    mbDdlRevisoes,
    mbDdlFalhas,
    'INSERT OR IGNORE INTO mb_espelho_ctl (id) VALUES (0)',
  ]) {
    await db.customStatement(ddl);
  }
  final desejados = <String, String>{};
  for (final tabela in mbTabelasEspelhadas) {
    final t = await mbEstruturaTabela(db, tabela);
    if (t != null) desejados.addAll(mbTriggersDaTabela(t));
  }
  final existentes = await _nomesNoBanco(db, 'trigger', r'mb\_esp\_%');
  for (final nome in existentes.difference(desejados.keys.toSet())) {
    await db.customStatement('DROP TRIGGER IF EXISTS $nome');
  }
  for (final e in desejados.entries) {
    if (!existentes.contains(e.key)) await db.customStatement(e.value);
  }
}

/// Migrações do Drift recriam tabelas (`TableMigration`); trigger apontando para a tabela antiga as quebraria.
/// `mbEspelhoPrepararBanco` os recria no `beforeOpen`.
Future<void> mbEspelhoDerrubarTriggers(GeneratedDatabase db) async {
  for (final nome in await _nomesNoBanco(db, 'trigger', r'mb\_esp\_%')) {
    await db.customStatement('DROP TRIGGER IF EXISTS $nome');
  }
}

/// Liga ou desliga a fila (o que o trigger consulta). Desligar também esvazia a fila: sem o espelho ativo ela
/// ficaria velha, e quem ligar de novo semeia ou baixa tudo.
Future<void> mbEspelhoDefinirAtivo(GeneratedDatabase db, bool ativo) async {
  await db.customStatement('UPDATE mb_espelho_ctl SET ativo = ? WHERE id = 0', [ativo ? 1 : 0]);
  if (!ativo) await db.customStatement('DELETE FROM mb_saida');
}
