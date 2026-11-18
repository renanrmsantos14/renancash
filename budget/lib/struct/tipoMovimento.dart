// Tipo de movimento (gasto, receita, investimento, empréstimo, transferência, a classificar) e o código de cores
// único do app: tokens em EditorialCores (tGasto, tReceita, tInvest, tEmpr, tTransf). A cor vem do TIPO, não da categoria.
import 'package:budget/database/tables.dart' show Transaction;
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/meuBancoMapping.dart' show mbPrefixo;
import 'package:flutter/material.dart';

enum TipoMov { gasto, receita, investimento, emprestimo, transferencia, aClassificar }

String _n(String? s) => (s ?? '').toLowerCase().trim();

/// Tipo pelo sinal do valor e pelo nome da categoria (ou pelas marcas explícitas de investimento/empréstimo).
/// Pagamento de fatura e transferência entre contas ficam em transferência (não contam).
TipoMov mbTipoMov({
  required double valor,
  String? categoria,
  bool investimento = false,
  bool emprestimo = false,
}) {
  final c = _n(categoria);
  if (c == 'a classificar') return TipoMov.aClassificar;
  if (investimento || c.contains('investiment') || c.contains('poupança') || c.contains('aplicação')) {
    return TipoMov.investimento;
  }
  if (emprestimo || c.startsWith('empréstimo') || c == 'loans') return TipoMov.emprestimo;
  if (c.startsWith('transferência') || c.contains('fatura')) return TipoMov.transferencia;
  return valor > 0 ? TipoMov.receita : TipoMov.gasto;
}

/// Tipo de uma transação do banco local; o nome da categoria vem de quem já a tem à mão.
TipoMov mbTipoDaTransacao(Transaction t, String? categoria) => mbTipoMov(
      valor: t.income ? 1 : -1,
      categoria: categoria,
      investimento: t.transactionPk.startsWith('${mbPrefixo}inv:'),
      emprestimo: t.objectiveLoanFk != null,
    );

extension TipoMovVisual on TipoMov {
  String get rotulo => switch (this) {
        TipoMov.gasto => 'GASTO',
        TipoMov.receita => 'RECEITA',
        TipoMov.investimento => 'INVESTIMENTO',
        TipoMov.emprestimo => 'EMPRÉSTIMO',
        TipoMov.transferencia => 'TRANSFERÊNCIA',
        TipoMov.aClassificar => 'A CLASSIFICAR',
      };

  IconData get icone => switch (this) {
        TipoMov.gasto => Icons.south_rounded,
        TipoMov.receita => Icons.north_rounded,
        TipoMov.investimento => Icons.trending_up_rounded,
        TipoMov.emprestimo => Icons.swap_horiz_rounded,
        TipoMov.transferencia => Icons.sync_rounded,
        TipoMov.aClassificar => Icons.help_outline_rounded,
      };

  Color cor(BuildContext context) {
    final e = cores(context);
    return switch (this) {
      TipoMov.gasto => e.tGasto,
      TipoMov.receita => e.tReceita,
      TipoMov.investimento => e.tInvest,
      TipoMov.emprestimo => e.tEmpr,
      TipoMov.transferencia || TipoMov.aClassificar => e.tTransf,
    };
  }
}

/// Ícone do tipo num círculo suave, na cor do tipo; "A classificar" com borda tracejada em vez de fundo.
class IconeTipo extends StatelessWidget {
  const IconeTipo(this.tipo, {super.key, this.tamanho = 28});
  final TipoMov tipo;
  final double tamanho;

  @override
  Widget build(BuildContext context) {
    final cor = tipo.cor(context);
    final vazio = tipo == TipoMov.aClassificar;
    return ExcludeSemantics(
      child: Container(
        width: tamanho,
        height: tamanho,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: vazio ? null : cor.withOpacity(.14),
          border: vazio ? Border.all(color: cor.withOpacity(.6)) : null,
        ),
        child: Icon(tipo.icone, size: tamanho * .58, color: cor),
      ),
    );
  }
}

/// Selo "GASTO · Alimentação": rótulo do tipo na cor dele, com a categoria ao lado quando houver.
class SeloTipo extends StatelessWidget {
  const SeloTipo(this.tipo, {super.key, this.categoria});
  final TipoMov tipo;
  final String? categoria;

  @override
  Widget build(BuildContext context) {
    final cor = tipo.cor(context);
    final texto = categoria == null || categoria!.isEmpty ? tipo.rotulo : '${tipo.rotulo} · $categoria';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: cor.withOpacity(.14), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(tipo.icone, size: 14, color: cor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(texto,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: .4, color: cor)),
        ),
      ]),
    );
  }
}
