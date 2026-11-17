import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Valor em reais com o sinal editorial: − para gasto, nada para positivo.
/// O sinal vem do valor animado; [alvo] só fixa as casas decimais.
String _dinheiro(BuildContext c, double v, {double? alvo}) {
  final s = convertToMoney(Provider.of<AllWallets>(c, listen: false), v.abs(),
      finalNumber: (alvo ?? v).abs());
  return v < 0 ? '−$s' : s;
}

/// Resumo do período no topo da lista: entradas, saídas e saldo.
/// Plano (superfície + borda), números tabulares que contam ao mudar.
class ResumoPeriodo extends StatelessWidget {
  const ResumoPeriodo({
    super.key,
    required this.entradas,
    required this.saidas,
    this.onTap,
    this.onLongPress,
  });

  final double entradas;

  /// Negativo (soma dos gastos).
  final double saidas;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    Widget coluna(String rotulo, double valor, Color cor) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rotulo, style: EdTexto.rotulo(context)),
              const SizedBox(height: 4),
              ContagemValor(
                valor: valor,
                formatar: (v) => _dinheiro(context, v, alvo: valor),
                centavosMenores: true,
                estilo: EdTexto.corpo(context).copyWith(
                    fontSize: 17, fontWeight: FontWeight.w600, color: cor),
              ),
            ],
          ),
        );
    return Semantics(
      button: onTap != null,
      child: ToqueEscala(
        onTap: onTap,
        child: GestureDetector(
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: e.surf,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: e.line),
            ),
            child: Row(
              children: [
                coluna('Entradas', entradas, e.pos),
                const SizedBox(width: 12),
                coluna('Saídas', saidas, e.tx),
                const SizedBox(width: 12),
                coluna('Saldo', entradas + saidas, e.tx),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Total em destaque no topo de Agendadas, Assinaturas e Empréstimos:
/// rótulo curto, valor grande com centavos menores e uma legenda.
class TotalDestaque extends StatelessWidget {
  const TotalDestaque({
    super.key,
    required this.rotulo,
    required this.valor,
    this.legenda,
    this.cor,
    this.onLongPress,
  });

  final String rotulo;
  final double valor;
  final String? legenda;
  final Color? cor;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: getHorizontalPaddingConstrained(context) + 18,
          end: getHorizontalPaddingConstrained(context) + 18,
          top: 12,
          bottom: 18,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(rotulo, style: EdTexto.h2(context)),
            const SizedBox(height: 8),
            ContagemValor(
              valor: valor,
              formatar: (v) => _dinheiro(context, v, alvo: valor),
              centavosMenores: true,
              estilo: EdTexto.numeroGrande(context).copyWith(color: cor),
            ),
            if (legenda != null) ...[
              const SizedBox(height: 8),
              Text(legenda!, style: EdTexto.rotulo(context)),
            ],
          ],
        ),
      ),
    );
  }
}

/// "1 transação" / "3 transações".
String contagemTransacoes(int n) => n == 1 ? '1 transação' : '$n transações';

/// Ação única de um estado vazio: botão compacto em `chip`, 44 px de toque.
class AcaoVazio extends StatelessWidget {
  const AcaoVazio({super.key, required this.rotulo, required this.onTap});

  final String rotulo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 16),
      child: Center(
        child: Semantics(
          button: true,
          child: ToqueEscala(
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                color: e.chip,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 18, color: e.tx),
                  const SizedBox(width: 6),
                  Text(rotulo,
                      style: EdTexto.corpo(context)
                          .copyWith(fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
