import 'package:budget/pages/homePage/homePageFaturaPatrimonio.dart';
import 'package:budget/pages/homePage/homePageHeatmap.dart';
import 'package:budget/pages/homePage/homePageLineGraph.dart';
import 'package:budget/pages/homePage/homePagePieChart.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/meuBancoSync.dart' show meuBancoPareado;
import 'package:budget/widgets/editorial/layoutDesktop.dart'
    show inicioNovaAtiva;
import 'package:flutter/material.dart';

/// Gráficos e patrimônio no topo de Orçamentos, no celular pareado (a Início nova não os mostra mais).
/// Computador e app não pareado continuam com eles na Início antiga.
class AnaliseOrcamentos extends StatelessWidget {
  const AnaliseOrcamentos({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: meuBancoPareado,
        builder: (context, _, __) {
          if (!inicioNovaAtiva()) return const SizedBox.shrink();
          return Align(
              alignment: AlignmentDirectional.topStart,
              child: ConstrainedBox(
                  // Computador: os gráficos foram feitos para a largura do celular.
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding:
                            const EdgeInsetsDirectional.fromSTEB(13, 4, 13, 10),
                        child: Text('Análise', style: EdTexto.h2(context)),
                      ),
                      const HomePagePatrimonio(),
                      // 1 = tudo (gastos e receitas), o padrão da Início antiga.
                      const HomePageLineGraph(selectedSlidingSelector: 1),
                      const HomePagePieChart(),
                      const HomePageHeatMap(),
                      const SizedBox(height: 8),
                    ],
                  )));
        },
      );
}
