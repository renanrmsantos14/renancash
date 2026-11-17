import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Títulos do banco vêm com espaços repetidos ("Pix enviado  - Auto Prime"): mostra com um só.
/// Só na exibição; o dado sincronizado não muda.
String nomeSemEspacosRepetidos(String nome) =>
    nome.trim().replaceAll(RegExp(r'\s{2,}'), ' ');

/// Nomes padrão da categoria de ajuste ("0") em versões anteriores: o banco local pode
/// tê-la criado em inglês. Um nome personalizado pelo usuário é mantido.
const _nomesPadraoAjuste = {'Balance Correction', 'Correção de saldo'};

/// Nome da categoria para exibir: a de ajuste de saldo com nome padrão sai traduzida.
String nomeDaCategoria(TransactionCategory categoria) =>
    categoria.categoryPk == "0" && _nomesPadraoAjuste.contains(categoria.name)
        ? "default-category-account-amount-balancing".tr()
        : categoria.name;

class TransactionLabel extends StatelessWidget {
  const TransactionLabel({
    required this.transaction,
    this.category,
    required this.fontSize,
    super.key,
  });
  final Transaction transaction;
  final TransactionCategory? category;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return transaction.name != ""
        ? TransactionTitleNameLabel(
            transaction: transaction, fontSize: fontSize)
        : TransactionCategoryNameLabel(
            transaction: transaction, fontSize: fontSize);
  }
}

class TransactionTitleNameLabel extends StatelessWidget {
  const TransactionTitleNameLabel(
      {required this.transaction, required this.fontSize, super.key});
  final Transaction transaction;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return TextFont(
      text: nomeSemEspacosRepetidos(transaction.name),
      fontSize: fontSize,
      maxLines:
          appStateSettings["fadeTransactionNameOverflows"] == false ? null : 1,
      overflow: appStateSettings["fadeTransactionNameOverflows"] == false
          ? null
          : TextOverflow.fade,
      softWrap: appStateSettings["fadeTransactionNameOverflows"] == false
          ? null
          : false,
    );
  }
}

class TransactionCategoryNameLabel extends StatelessWidget {
  const TransactionCategoryNameLabel({
    required this.transaction,
    this.category,
    required this.fontSize,
    super.key,
  });
  final Transaction transaction;
  final TransactionCategory? category;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return category == null
        ? StreamBuilder<TransactionCategory>(
            stream: database.getCategory(transaction.categoryFk).$1,
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                return TextFont(
                  text: nomeDaCategoria(snapshot.data!),
                  fontSize: fontSize,
                  maxLines:
                      appStateSettings["fadeTransactionNameOverflows"] == false
                          ? null
                          : 1,
                  overflow:
                      appStateSettings["fadeTransactionNameOverflows"] == false
                          ? null
                          : TextOverflow.fade,
                  softWrap:
                      appStateSettings["fadeTransactionNameOverflows"] == false
                          ? null
                          : false,
                );
              }
              return SizedBox.shrink();
            },
          )
        : TextFont(
            text: nomeDaCategoria(category!),
            fontSize: fontSize,
            maxLines: appStateSettings["fadeTransactionNameOverflows"] == false
                ? null
                : 1,
            overflow: appStateSettings["fadeTransactionNameOverflows"] == false
                ? null
                : TextOverflow.fade,
            softWrap: appStateSettings["fadeTransactionNameOverflows"] == false
                ? null
                : false,
          );
  }
}

Future<String> getTransactionLabel(Transaction transaction,
    {TransactionCategory? category}) async {
  if (transaction.name.trim() == "") {
    if (category == null) {
      TransactionCategory categorySearch =
          await database.getCategory(transaction.categoryFk).$2;
      return nomeDaCategoria(categorySearch).capitalizeFirst;
    } else {
      return nomeDaCategoria(category).capitalizeFirst;
    }
  } else {
    return nomeSemEspacosRepetidos(transaction.name).capitalizeFirst;
  }
}

String getTransactionLabelSync(
    Transaction transaction, TransactionCategory? category) {
  if (transaction.name.trim() == "") {
    return (category == null ? transaction.name : nomeDaCategoria(category))
        .capitalizeFirst;
  } else {
    return nomeSemEspacosRepetidos(transaction.name).capitalizeFirst;
  }
}
