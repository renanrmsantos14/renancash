import 'dart:convert';

import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/espelho.dart' show mbEspelhoEstadoMudou;
import 'package:budget/struct/mbSync/registro.dart';
import 'package:drift/drift.dart';

/// Pertencimento N:N de transação a orçamento. Sem linhas = só o Geral (padrão); `orcamento_pk = ''` = nenhum.
/// Tabela crua (sem migração do Drift); também é criada em `beforeOpen`, porque as consultas de orçamento a usam.
const String mbDdlOrcamentoTx = 'CREATE TABLE IF NOT EXISTS mb_orcamento_tx ('
    'tx_pk TEXT NOT NULL, orcamento_pk TEXT NOT NULL, PRIMARY KEY (tx_pk, orcamento_pk))';

/// Aplicação (investimento) -> meta. A chave na aplicação garante "uma aplicação em uma meta só".
const String mbDdlMetaAplicacao = 'CREATE TABLE IF NOT EXISTS mb_meta_aplicacao ('
    'aplicacao_pk TEXT PRIMARY KEY, meta_pk TEXT NOT NULL)';

const String mbDdlEstado = 'CREATE TABLE IF NOT EXISTS mb_estado (chave TEXT PRIMARY KEY, valor TEXT NOT NULL)';

Future<void> mbCriarTabelas() async {
  await database.customStatement(mbDdlOrcamentoTx);
  await database.customStatement(mbDdlMetaAplicacao);
  await database.customStatement(
      'CREATE TABLE IF NOT EXISTS mb_registros ('
      'tabela TEXT NOT NULL, id TEXT NOT NULL, dados TEXT, updated_at TEXT NOT NULL, '
      'deleted_at TEXT, projecao TEXT, pendente INTEGER NOT NULL DEFAULT 0, motivo TEXT, '
      'PRIMARY KEY (tabela, id))');
  await database.customStatement(mbDdlEstado);
  await database.customStatement(
      'CREATE TABLE IF NOT EXISTS mb_aplicado (tx_pk TEXT PRIMARY KEY, categoria_pk TEXT NOT NULL)');
}

Map<String, dynamic>? _json(Object? texto) => texto == null
    ? null
    : (jsonDecode(texto as String) as Map).cast<String, dynamic>();

/// Hora de quem não guarda `updated_at` (mb_revisoes): o espelho do servidor é quem decide a versão.
const String _semHora = '1970-01-01T00:00:00.000Z';

/// Copia as decisões de revisão vivas de `mb_registros` para `mb_revisoes` (o que o espelho completo sincroniza).
/// Não sobrescreve o que já está em `mb_revisoes`.
Future<void> mbMigrarRevisoes(GeneratedDatabase db) async {
  final existe = await db
      .customSelect("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'mb_registros'")
      .get();
  if (existe.isEmpty) return;
  await db.customStatement(
      'INSERT OR IGNORE INTO mb_revisoes (pk, dados) SELECT id, dados FROM mb_registros '
      "WHERE tabela = 'revisoes' AND deleted_at IS NULL AND dados IS NOT NULL");
}

/// As decisões da fila "Para revisar" vivem em `mb_revisoes` (espelhada pelo servidor).
Future<List<Registro>> mbLerRevisoes() async {
  final out = <Registro>[];
  for (final l in await database.customSelect('SELECT pk, dados FROM mb_revisoes').get()) {
    final d = l.readNullable<String>('dados');
    if (d == null) continue;
    out.add(Registro('revisoes', l.read<String>('pk'), _json(d), _semHora, null));
  }
  return out;
}

/// Grava (ou apaga, quando `deletedAt`/`dados` vazios) decisões em `mb_revisoes`; os triggers do espelho enfileiram o envio.
Future<void> mbGravarRevisoes(Iterable<Registro> itens) => database.transaction(() async {
      for (final r in itens) {
        if (r.deletedAt != null || r.dados == null) {
          await database.customStatement('DELETE FROM mb_revisoes WHERE pk = ?', [r.id]);
        } else {
          await database.customStatement(
              'INSERT INTO mb_revisoes (pk, dados) VALUES (?, ?) ON CONFLICT (pk) DO UPDATE SET dados = excluded.dados',
              [r.id, jsonCanonico(r.dados)]);
        }
      }
    });

Future<String?> mbLerEstado(String chave, [GeneratedDatabase? db]) async {
  final l = await (db ?? database).customSelect('SELECT valor FROM mb_estado WHERE chave = ?',
      variables: [Variable.withString(chave)]).getSingleOrNull();
  return l?.read<String>('valor');
}

Future<void> mbGravarEstado(Map<String, String> valores) async {
  await database.transaction(() async {
    for (final e in valores.entries) {
      await database.customStatement(
          'INSERT OR REPLACE INTO mb_estado (chave, valor) VALUES (?, ?)',
          [e.key, e.value]);
    }
  });
  await mbEspelhoEstadoMudou(valores.keys);
}

Future<void> mbRemoverEstado(String chave) =>
    database.customStatement('DELETE FROM mb_estado WHERE chave = ?', [chave]);
