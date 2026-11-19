import 'package:drift/drift.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/categoriaEfetiva.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show idDoPk;
import 'package:budget/struct/meuBancoMapping.dart' show mbPrefixo;

/// Monta o contexto de categoria só com o que já está no banco local (que o espelho sincroniza):
/// - regras: `associated_titles` ("contém" vira `*título*`; título vazio ou com `*` não vale);
/// - categorias por nome: `categories`;
/// - ajustes: as próprias transações `mb:` editadas (dateTimeModified depois de 2000). Editada fixa a categoria atual
///   e o título/nota escritos pelo usuário; sem edição, o mapeador decide (regra, nome, banco).
/// Exclusão não é ajuste: vem de `mb_apagados`.
Future<MbContextoCategoria> mbContextoLocal() async {
  final regras = <MbRegraCtx>[
    for (final a in await database.select(database.associatedTitles).get())
      if (a.title.trim().isNotEmpty && !a.title.contains('*'))
        MbRegraCtx(idDoPk(a.associatedTitlePk), a.isExactMatch ? a.title : '*${a.title}*',
            idDoPk(a.categoryFk), null, 0)
  ];
  final porNome = {
    for (final c in await database.select(database.categories).get())
      '${c.income ? 'receita' : 'despesa'}:${c.name.toLowerCase()}': idDoPk(c.categoryPk)
  };
  final ajustes = <String, Map<String, dynamic>>{};
  final editadas = database.select(database.transactions)
    ..where((t) =>
        t.transactionPk.like('$mbPrefixo%') & t.dateTimeModified.isBiggerOrEqualValue(DateTime.utc(2001)));
  for (final t in await editadas.get()) {
    final nome = t.name.trim();
    final nota = t.note.trim();
    ajustes[t.transactionPk.substring(mbPrefixo.length)] = {
      if (t.categoryFk.isNotEmpty) 'categoria_id': idDoPk(t.categoryFk),
      if (nome.isNotEmpty) 'nome': nome,
      if (nota.isNotEmpty && t.note != 'Pendente') 'nota': nota,
    };
  }
  return MbContextoCategoria(ajustes, regras, porNome);
}
