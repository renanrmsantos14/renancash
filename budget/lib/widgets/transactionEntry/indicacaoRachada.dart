import 'package:budget/database/tables.dart' show Transaction;
import 'package:budget/struct/mbSync/rachadas.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/colors.dart';
import 'package:flutter/material.dart';

/// Numa busca, o gasto rachado mostra por que foi achado: "inclui Pix de Valentina +R$ 50,00 e troco −R$ 11,88".
class IndicacaoRachada extends StatelessWidget {
  const IndicacaoRachada({super.key, required this.transaction, this.busca});
  final Transaction transaction;
  final String? busca;

  @override
  Widget build(BuildContext context) {
    if (busca == null || busca!.trim().isEmpty) return const SizedBox.shrink();
    return ValueListenableBuilder<MbRachadas>(
      valueListenable: meuBancoRachadas,
      builder: (context, rachadas, _) {
        final texto = rachadas.porGasto[transaction.transactionPk]?.indicacao ?? '';
        if (texto.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsetsDirectional.only(start: 3, top: 2, bottom: 2),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextFont(text: texto, fontSize: 12, maxLines: 2, textColor: getColor(context, "textLight")),
          ),
        );
      },
    );
  }
}
