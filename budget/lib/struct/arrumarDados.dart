// "Arrumar dados": prévia e aplicação da limpeza dos dados antigos.
// 1. Junta o lançamento manual da carteira principal com o mesmo lançamento importado do Meu Banco.
// 2. Leva os lançamentos das categorias `mb:cat:` para as do usuário (mbMapaCategorias).
// 3. Arquiva as carteiras manuais antigas de bancos que hoje vêm do Meu Banco.
// 4. Apaga as categorias vazias e sem uso.
// O cálculo (arrumarPlanejar) é puro, sobre listas; arrumarAplicar recalcula e grava numa transação só.

import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/mapeamento.dart';
import 'package:budget/struct/mbSync/revisao.dart' show mbCategoriaAClassificar;
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart';

// Carteira principal do Cashew: onde estão os lançamentos manuais que o Meu Banco agora importa.
const String arrumarCarteiraPrincipal = "0";
const int arrumarJanelaDias = 4;
// Lançamentos do banco que já receberam um manual (mb_estado): não casam de novo, então rodar outra vez não faz nada.
const String _chaveJuntados = 'arrumar_juntados';

class ArrumarPar {
  final Transaction manual, banco;
  final int dias;
  const ArrumarPar(this.manual, this.banco, this.dias);
}

class ArrumarMigracao {
  final Transaction transacao;
  final MbDestino destino;
  const ArrumarMigracao(this.transacao, this.destino);
}

class ArrumarPlano {
  final List<ArrumarPar> pares;
  final List<ArrumarMigracao> migracoes;
  final List<TransactionWallet> carteiras;
  // Subcategorias antes das principais (ordem de exclusão).
  final List<TransactionCategory> categorias;
  const ArrumarPlano(this.pares, this.migracoes, this.carteiras, this.categorias);
  bool get vazio =>
      pares.isEmpty && migracoes.isEmpty && carteiras.isEmpty && categorias.isEmpty;
}

Set<String> _palavras(String s) =>
    mbNormalizarEstabelecimento(s).split(" ").where((p) => p.isNotEmpty).toSet();

// "Inter" está em "BANCO INTER ·69-6": todas as palavras do nome manual aparecem no nome do banco.
bool _mesmoBanco(String manual, String banco) {
  final m = _palavras(manual);
  return m.isNotEmpty && _palavras(banco).containsAll(m);
}

int _dias(DateTime a, DateTime b) => DateTime.utc(a.year, a.month, a.day)
    .difference(DateTime.utc(b.year, b.month, b.day))
    .inDays
    .abs();

int _parecido(String a, String b) {
  final pa = _palavras(a).where((p) => p.length >= 3).toSet();
  return pa.intersection(_palavras(b)).length;
}

// 1:1 por menor distância de data; no empate, o título mais parecido (depois data e pk, para ser estável).
List<ArrumarPar> arrumarParear(List<Transaction> manuais, List<Transaction> banco) {
  final candidatos = <(ArrumarPar, int)>[];
  for (final m in manuais) {
    final centavos = (m.amount * 100).round();
    for (final b in banco) {
      if ((b.amount * 100).round() != centavos) continue;
      final dias = _dias(m.dateCreated, b.dateCreated);
      if (dias <= arrumarJanelaDias) {
        candidatos.add((ArrumarPar(m, b, dias), _parecido(m.name, b.name)));
      }
    }
  }
  candidatos.sort((x, y) {
    final a = x.$1, b = y.$1;
    var c = a.dias.compareTo(b.dias);
    if (c == 0) c = y.$2.compareTo(x.$2);
    if (c == 0) c = a.manual.dateCreated.compareTo(b.manual.dateCreated);
    if (c == 0) c = a.manual.transactionPk.compareTo(b.manual.transactionPk);
    if (c == 0) c = a.banco.transactionPk.compareTo(b.banco.transactionPk);
    return c;
  });
  final usados = <String>{};
  final pares = <ArrumarPar>[];
  for (final (par, _) in candidatos) {
    final m = par.manual.transactionPk, b = par.banco.transactionPk;
    if (usados.contains(m) || usados.contains(b)) continue;
    usados.addAll([m, b]);
    pares.add(par);
  }
  return pares;
}

String? _texto(String s) => s.trim().isEmpty ? null : s.trim();

// Fica o lançamento do banco com o que o usuário pôs no manual: título, categoria e subcategoria, nota, meta,
// empréstimo e orçamentos excluídos. A data de edição faz a categoria subir como ajuste (LWW) e protege título e nota.
Transaction arrumarMesclar(Transaction manual, Transaction banco, DateTime agora) {
  final excluidos = {...?banco.budgetFksExclude, ...?manual.budgetFksExclude};
  return banco.copyWith(
    name: _texto(manual.name) ?? banco.name,
    note: [_texto(banco.note), _texto(manual.note)].whereType<String>().join("\n"),
    categoryFk: manual.categoryFk,
    subCategoryFk: Value(manual.subCategoryFk),
    objectiveFk: Value(manual.objectiveFk ?? banco.objectiveFk),
    objectiveLoanFk: Value(manual.objectiveLoanFk ?? banco.objectiveLoanFk),
    budgetFksExclude: Value(excluidos.isEmpty ? null : excluidos.toList()),
    dateTimeModified: Value(agora),
  );
}

// `usadas`: categorias citadas fora das transações (orçamentos, limites, títulos associados, registros do Meu Banco).
ArrumarPlano arrumarPlanejar({
  required List<Transaction> transacoes,
  required List<TransactionCategory> categorias,
  required List<TransactionWallet> carteiras,
  Set<String> usadas = const {},
  Set<String> arquivadas = const {},
  Set<String> juntados = const {},
  Map<String, String> mapa = mbMapaCategorias,
}) {
  final doBanco = carteiras.where((w) => w.walletPk.startsWith(mbPrefixo)).toList();
  final principal =
      carteiras.where((w) => w.walletPk == arrumarCarteiraPrincipal).firstOrNull;
  final bancoPks = {
    for (final w in doBanco)
      if (principal != null && _mesmoBanco(principal.name, w.name)) w.walletPk
  };
  final arquivar = [
    for (final w in carteiras)
      if (!w.walletPk.startsWith(mbPrefixo) &&
          w.walletPk != arrumarCarteiraPrincipal &&
          !arquivadas.contains(w.walletPk) &&
          doBanco.any((b) => _mesmoBanco(w.name, b.name)))
        w
  ];

  // Futuras/assinaturas (type), ajuste de saldo e metade de transferência não entram; pendente do banco muda de id.
  final pares = arrumarParear([
    for (final t in transacoes)
      if (t.walletFk == arrumarCarteiraPrincipal &&
          !t.transactionPk.startsWith(mbPrefixo) &&
          t.type == null &&
          t.categoryFk != "0" &&
          t.pairedTransactionFk == null)
        t
  ], [
    for (final t in transacoes)
      if (bancoPks.contains(t.walletFk) &&
          t.transactionPk.startsWith(mbPrefixo) &&
          t.type == null &&
          t.note != "Pendente" &&
          !juntados.contains(t.transactionPk))
        t
  ]);

  // Estado depois da junção, para as etapas seguintes.
  final agora = DateTime.now();
  final depois = {for (final t in transacoes) t.transactionPk: t};
  for (final p in pares) {
    depois.remove(p.manual.transactionPk);
    depois[p.banco.transactionPk] = arrumarMesclar(p.manual, p.banco, agora);
  }

  final destinos = mbResolverDestinos([
    for (final c in categorias)
      CatLocal(pk: c.categoryPk, nome: c.name, receita: c.income, paiPk: c.mainCategoryPk)
  ], mapa: mapa);
  final porCategoria = <String, MbDestino>{
    for (final c in categorias)
      if (c.categoryPk.startsWith("${mbPrefixo}cat:"))
        if (destinos[mbChaveDestino(c.categoryPk.startsWith("${mbPrefixo}cat:r:"), c.name)]
            case final d? when d.pk != c.categoryPk)
          c.categoryPk: d
  };
  final migracoes = [
    for (final t in depois.values)
      if (porCategoria[t.categoryFk] case final d?) ArrumarMigracao(t, d)
  ];

  final emUso = <String>{
    "0",
    ...usadas,
    for (final t in depois.values) ...[
      porCategoria[t.categoryFk]?.pk ?? t.categoryFk,
      if (t.subCategoryFk ?? porCategoria[t.categoryFk]?.subPk case final s?) s,
    ],
    // O mapa precisa dos destinos para as próximas importações.
    for (final d in destinos.values) ...[d.pk, if (d.subPk != null) d.subPk!],
  };
  // Categorias próprias fora do mapa: o pull as recria pelo nome se sumirem.
  final recriadas = {
    for (final n in [...mbCategoriasProprias, mbCategoriaOutros, mbCategoriaAClassificar])
      if (!destinos.containsKey(mbChaveDestino(false, n))) n.toLowerCase()
  };
  bool livre(TransactionCategory c) =>
      !emUso.contains(c.categoryPk) &&
      !(!c.income && recriadas.contains(c.name.toLowerCase()));
  final subs = [for (final c in categorias) if (c.mainCategoryPk != null && livre(c)) c];
  final principais = [
    for (final c in categorias)
      if (c.mainCategoryPk == null &&
          livre(c) &&
          categorias.every((s) => s.mainCategoryPk != c.categoryPk || livre(s)))
        c
  ];

  return ArrumarPlano(pares, migracoes, arquivar, [...subs, ...principais]);
}

Future<Set<String>> _juntados() async {
  final v = await mbLerEstado(_chaveJuntados);
  return v == null ? {} : {...(jsonDecode(v) as List).cast<String>()};
}

// Categorias citadas fora das transações. Ids do Meu Banco vêm com o prefixo `cashew:`.
Future<Set<String>> _categoriasUsadas() async {
  final usadas = <String>{};
  for (final b in await database.select(database.budgets).get()) {
    usadas.addAll([...?b.categoryFks, ...?b.categoryFksExclude]);
  }
  for (final l in await database.select(database.categoryBudgetLimits).get()) {
    usadas.add(l.categoryFk);
  }
  for (final a in await database.select(database.associatedTitles).get()) {
    usadas.add(a.categoryFk);
  }
  for (final e in (await mbLerEspelho()).values) {
    final d = e.registro.dados;
    if (e.registro.deletedAt != null || d == null) continue;
    for (final v in [d['categoria_id'], ...?(d['categoria_ids'] as List?)]) {
      if (v is String) usadas.add(pkDoId(v));
    }
  }
  return usadas;
}

Future<ArrumarPlano> arrumarCalcular() async {
  await mbCriarTabelas();
  return arrumarPlanejar(
    transacoes: await database.select(database.transactions).get(),
    categorias: await database.select(database.categories).get(),
    carteiras: await database.select(database.wallets).get(),
    usadas: await _categoriasUsadas(),
    arquivadas: carteirasArquivadas(),
    juntados: await _juntados(),
  );
}

// Recalcula na hora (um sync pode ter mudado algo desde a prévia) e aplica numa transação. As mudanças seguem pelo
// sync normal: título/categoria com data de edição viram ajustes, manuais apagados e categorias viram tombstones.
Future<ArrumarPlano> arrumarAplicar() async {
  late ArrumarPlano plano;
  final agora = DateTime.now();
  await database.transaction(() async {
    plano = await arrumarCalcular();
    for (final p in plano.pares) {
      await database.update(database.transactions)
          .replace(arrumarMesclar(p.manual, p.banco, agora));
      // Escolha de orçamentos (mb_orcamento_tx) do manual passa para o lançamento do banco.
      await database.customStatement(
          'INSERT OR IGNORE INTO mb_orcamento_tx (tx_pk, orcamento_pk) '
          'SELECT ?, orcamento_pk FROM mb_orcamento_tx WHERE tx_pk = ?',
          [p.banco.transactionPk, p.manual.transactionPk]);
      await database.customStatement(
          'DELETE FROM mb_orcamento_tx WHERE tx_pk = ?', [p.manual.transactionPk]);
    }
    if (plano.pares.isNotEmpty) {
      // Vão para "apagadas recentemente" (Histórico de alterações), de onde dá para restaurar.
      await database.deleteTransactions(
          [for (final p in plano.pares) p.manual.transactionPk],
          updateSharedEntry: false);
      await mbGravarEstado({
        _chaveJuntados: jsonEncode([
          ...await _juntados(),
          for (final p in plano.pares) p.banco.transactionPk
        ])
      });
    }
    for (final m in plano.migracoes) {
      await (database.update(database.transactions)
            ..where((t) => t.transactionPk.equals(m.transacao.transactionPk)))
          .write(TransactionsCompanion(
        categoryFk: Value(m.destino.pk),
        subCategoryFk: Value(m.transacao.subCategoryFk ?? m.destino.subPk),
        dateTimeModified: Value(agora),
      ));
    }
    for (final c in plano.categorias) {
      // A ordem muda a cada exclusão; a principal leva junto as subcategorias já apagadas.
      final atual = await database.getCategoryInstanceOrNull(c.categoryPk);
      if (atual != null) await database.deleteCategory(atual.categoryPk, atual.order);
    }
  });
  if (plano.carteiras.isNotEmpty) {
    await updateSettings(
        "carteirasArquivadas",
        [...carteirasArquivadas(), for (final w in plano.carteiras) w.walletPk],
        updateGlobalState: true);
    // Mexer na linha faz as listas de carteiras (streams) relerem o filtro.
    await (database.update(database.wallets)
          ..where((w) => w.walletPk.isIn([for (final w in plano.carteiras) w.walletPk])))
        .write(WalletsCompanion(dateTimeModified: Value(agora)));
  }
  return plano;
}

Future<void> arrumarDesarquivar(String walletPk) async {
  await updateSettings(
      "carteirasArquivadas", [...carteirasArquivadas()..remove(walletPk)],
      updateGlobalState: true);
  await (database.update(database.wallets)..where((w) => w.walletPk.equals(walletPk)))
      .write(WalletsCompanion(dateTimeModified: Value(DateTime.now())));
}
