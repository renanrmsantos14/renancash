import 'package:budget/struct/editorial.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:flutter/material.dart';

/// Valor com sinal tipográfico: − para negativo, + só quando pedido.
String comSinal(double v, String Function(double) formatar,
        {bool mais = false}) =>
    (v < 0 ? '−' : (mais && v > 0 ? '+' : '')) + formatar(v.abs());

/// Topo do detalhe da conta: saldo como protagonista (centavos menores) e,
/// abaixo, entradas e saídas do período escolhido.
class ResumoConta extends StatelessWidget {
  const ResumoConta({
    super.key,
    required this.saldo,
    required this.entradas,
    required this.saidas,
    required this.formatar,
    required this.periodo,
    this.onPeriodo,
    this.onSaldo,
    this.onEntradas,
    this.onSaidas,
  });

  final double saldo, entradas, saidas;
  final String Function(double) formatar;
  final String periodo;
  final VoidCallback? onPeriodo, onSaldo, onEntradas, onSaidas;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Saldo da conta', style: EdTexto.rotulo(context)),
          const SizedBox(height: 8),
          ToqueEscala(
            onTap: onSaldo,
            child: Semantics(
              label: 'Saldo da conta ${comSinal(saldo, formatar)}',
              excludeSemantics: true,
              child: ContagemValor(
                valor: saldo,
                formatar: (v) => comSinal(v, formatar),
                centavosMenores: true,
                estilo: EdTexto.numeroGrande(context),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: Text('No período', style: EdTexto.h2(context))),
            SeletorPeriodo(texto: periodo, onTap: onPeriodo),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: _Fluxo(
                  rotulo: 'Entradas',
                  valor: entradas,
                  formatar: (v) => comSinal(v, formatar, mais: true),
                  positivo: true,
                  onTap: onEntradas),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Fluxo(
                  rotulo: 'Saídas',
                  valor: -saidas,
                  formatar: (v) => comSinal(v, formatar),
                  onTap: onSaidas),
            ),
          ]),
        ],
      ),
    );
  }
}

class _Fluxo extends StatelessWidget {
  const _Fluxo(
      {required this.rotulo,
      required this.valor,
      required this.formatar,
      this.positivo = false,
      this.onTap});
  final String rotulo;
  final double valor;
  final String Function(double) formatar;
  final bool positivo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return ToqueEscala(
      onTap: onTap,
      child: Semantics(
        button: onTap != null,
        label: '$rotulo ${formatar(valor)}',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: e.surf,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: e.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rotulo, style: EdTexto.rotulo(context)),
              const SizedBox(height: 4),
              ContagemValor(
                valor: valor,
                formatar: formatar,
                estilo: EdTexto.corpo(context).copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: positivo && valor > 0 ? e.pos : e.tx),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chip do período (abre a escolha do período). Toque mínimo de 44 px.
class SeletorPeriodo extends StatelessWidget {
  const SeletorPeriodo({super.key, required this.texto, this.onTap});
  final String texto;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return ToqueEscala(
      onTap: onTap,
      child: Semantics(
        button: true,
        label: 'Período: $texto',
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Center(
            widthFactor: 1,
            child: Container(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 7, 8, 7),
              decoration: BoxDecoration(
                  color: e.chip, borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.calendar_today_outlined, size: 14, color: e.mu),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(texto,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: EdTexto.corpo(context).copyWith(
                          fontSize: 13, fontWeight: FontWeight.w500)),
                ),
                Icon(Icons.expand_more_rounded, size: 18, color: e.mu),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Total de todas as contas no topo da lista de contas.
class TotalContas extends StatelessWidget {
  const TotalContas(
      {super.key,
      required this.total,
      required this.formatar,
      required this.quantidade});
  final double total;
  final String Function(double) formatar;
  final int quantidade;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Total nas contas', style: EdTexto.rotulo(context)),
          const SizedBox(height: 8),
          Semantics(
            label: 'Total nas contas ${comSinal(total, formatar)}',
            excludeSemantics: true,
            child: ContagemValor(
              valor: total,
              formatar: (v) => comSinal(v, formatar),
              centavosMenores: true,
              estilo: EdTexto.numeroGrande(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(quantidade == 1 ? '1 conta' : '$quantidade contas',
              style: EdTexto.rotulo(context)),
        ],
      ),
    );
  }
}

/// Sigla do banco/conta num quadrado de 36 px, como na Início.
class SiglaConta extends StatelessWidget {
  const SiglaConta({super.key, required this.sigla});
  final String sigla;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: e.chip, borderRadius: BorderRadius.circular(10)),
      child: Text(sigla,
          style: TextStyle(
              fontFamily: 'GeistMono',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: e.tx)),
    );
  }
}

/// Conteúdo de uma linha da lista de contas: sigla, nome, detalhe e saldo à direita.
class LinhaConta extends StatelessWidget {
  const LinhaConta(
      {super.key,
      required this.sigla,
      required this.nome,
      required this.detalhe,
      required this.saldo});
  final String sigla, nome, detalhe, saldo;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          SiglaConta(sigla: sigla),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nome,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context)
                        .copyWith(fontSize: 15, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(detalhe,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.rotulo(context)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(saldo,
              style: EdTexto.corpo(context)
                  .copyWith(fontSize: 15, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
