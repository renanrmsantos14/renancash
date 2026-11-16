import 'package:budget/struct/ajustesInicio.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/pendenciasVencidas.dart';
import 'package:budget/struct/mbSync/avisos.dart' show meuBancoAvisos;
import 'package:budget/struct/mbSync/revisao.dart'
    show meuBancoRevisar, mbTotalPendencias;
import 'package:flutter/material.dart';

/// Ícone com a bolinha do total de pendências (`mbTotalPendencias`).
/// A bolinha some em zero ou com o selo desligado. Usado na barra do celular e na lateral do computador.
class SeloPendencias extends StatelessWidget {
  const SeloPendencias({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        meuBancoRevisar,
        meuBancoAvisos,
        meuBancoVencidas,
        mbAjustesMudaram
      ]),
      builder: (context, _) {
        final total = AjustesInicio.selo ? mbTotalPendencias() : 0;
        return Stack(clipBehavior: Clip.none, children: [
          child,
          if (total > 0)
            Positioned(
              top: -5,
              right: -9,
              child: Container(
                constraints: const BoxConstraints(minWidth: 16),
                height: 16,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: e.acc, borderRadius: BorderRadius.circular(8)),
                child: Text(total > 99 ? '99+' : '$total',
                    style: TextStyle(
                        fontFamily: 'Geist',
                        fontSize: 10,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: e.bg)),
              ),
            ),
        ]);
      },
    );
  }
}
