import 'package:budget/pages/homePage/homePageFaturaPatrimonio.dart';
import 'package:budget/pages/homePage/homePageHeatmap.dart';
import 'package:budget/pages/homePage/homePageLineGraph.dart';
import 'package:budget/pages/homePage/homePagePieChart.dart';
import 'package:budget/struct/ajustesInicio.dart';
import 'package:budget/struct/editorial.dart';
import 'package:flutter/material.dart';

/// Gráficos e patrimônio no topo de Orçamentos (a Início é fixa e não os mostra).
class AnaliseOrcamentos extends StatelessWidget {
  const AnaliseOrcamentos({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: mbAjustesMudaram,
      builder: (context, _, __) => _secao(context));

  Widget _secao(BuildContext context) => Align(
      alignment: AlignmentDirectional.topStart,
      child: ConstrainedBox(
          // Computador: os gráficos foram feitos para a largura do celular.
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(13, 4, 13, 10),
                child: Text('Análise', style: EdTexto.h2(context)),
              ),
              // Configurações › Análise: cada gráfico pode ser desligado.
              if (AjustesInicio.grafico('patrimonio') ||
                  AjustesInicio.grafico('linha'))
                CarregaPatrimonio(
                  semDados: _linha(null),
                  construir: (context, d) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (AjustesInicio.grafico('patrimonio'))
                        HomePagePatrimonio(d),
                      _linha(d.patrimonio.total),
                    ],
                  ),
                ),
              if (AjustesInicio.grafico('pizza')) const HomePagePieChart(),
              if (AjustesInicio.grafico('mapa')) const HomePageHeatMap(),
              const SizedBox(height: 8),
            ],
          )));

  // 1 = tudo, 2 = só gastos, 3 = só receitas. "Tudo" é a evolução do patrimônio: termina no
  // total do cartão acima, senão a soma local das carteiras contradiz o Patrimônio.
  Widget _linha(double? patrimonio) => AjustesInicio.grafico('linha')
      ? HomePageLineGraph(
          selectedSlidingSelector: AjustesInicio.linhaTipo,
          ancoraFinal: AjustesInicio.linhaTipo == 1 ? patrimonio : null)
      : const SizedBox.shrink();
}
