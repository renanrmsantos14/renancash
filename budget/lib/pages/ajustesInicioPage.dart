import 'package:budget/pages/homePage/homePageHeatmap.dart'
    show HomePageHeatMapSettings;
import 'package:budget/pages/homePage/homePagePieChart.dart'
    show openPieChartHomePageBottomSheetSettings;
import 'package:budget/struct/ajustesInicio.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:flutter/material.dart';

/// Configurações › Início e pendências: três páginas (Início, Pendências, Análise).
/// Cada opção grava em appStateSettings e redesenha o app; os padrões estão em AjustesInicio.
List<Widget> ajustesInicioEntradas() => const [
      SettingsHeader(title: 'Início e pendências'),
      SettingsContainerOpenPage(
        openPage: AjustesInicioPage(),
        title: 'Início',
        description: 'Atalhos, lançar rápido, cartão de saldo, metas e contas',
        icon: Icons.home_outlined,
      ),
      SettingsContainerOpenPage(
        openPage: AjustesPendenciasPage(),
        title: 'Pendências',
        description: 'O que entra na fila e no contador',
        icon: Icons.inbox_outlined,
      ),
      SettingsContainerOpenPage(
        openPage: AjustesAnalisePage(),
        title: 'Análise',
        description: 'Gráficos do topo de Orçamentos',
        icon: Icons.insights_outlined,
      ),
    ];

Future<void> _gravar(String chave, Object valor) =>
    mbGravarAjuste(chave, valor);

Widget _chave(String chave, bool atual,
        {required String titulo, String? descricao}) =>
    SettingsContainerSwitch(
      title: titulo,
      description: descricao,
      initialValue: atual,
      onSwitched: (v) => _gravar(chave, v),
    );

class AjustesInicioPage extends StatelessWidget {
  const AjustesInicioPage({super.key});

  @override
  Widget build(BuildContext context) => PageFramework(
        title: 'Início',
        dragDownToDismiss: true,
        listWidgets: [
          const SettingsHeader(title: 'Sem banco conectado'),
          _chave('inicioAtalhos', AjustesInicio.atalhos,
              titulo: 'Mostrar atalhos sem banco',
              descricao:
                  'Nova transação, Contas, Orçamentos e Metas enquanto o banco não estiver conectado'),
          const SettingsHeader(title: 'Lançar rápido'),
          _chave('inicioLancamentoRapido', AjustesInicio.lancamentoRapido,
              titulo: 'Mostrar lançamento rápido',
              descricao:
                  'Os gastos que você mais repete (últimos 90 dias) para lançar com um toque'),
          const SettingsHeader(title: 'Cartão de saldo'),
          _chave('inicioRitmoDiario', AjustesInicio.ritmoDiario,
              titulo: 'Mostrar ritmo diário',
              descricao: '"Pode gastar R\$ X/dia" abaixo da barra'),
          _chave('inicioSaldoContas', AjustesInicio.saldoContas,
              titulo: 'Mostrar saldo nas contas',
              descricao: '"Nas contas R\$ X" no fim do cartão'),
          const SettingsHeader(title: 'Metas e contas'),
          SettingsContainerDropdown(
            title: 'Linhas de metas e de empréstimos',
            description:
                'Quantas aparecem em cada grupo; o resto fica em "Ver todas"',
            initial: '${AjustesInicio.linhasMetas}',
            items: const ['1', '2', '3', '4'],
            onChanged: (v) => _gravar('inicioLinhasMetas', int.parse(v)),
          ),
          _chave('inicioPoupancasJuntas', AjustesInicio.poupancasJuntas,
              titulo: 'Juntar as poupanças',
              descricao: 'Uma linha "Poupanças" em vez de uma por conta'),
        ],
      );
}

class AjustesPendenciasPage extends StatelessWidget {
  const AjustesPendenciasPage({super.key});

  @override
  Widget build(BuildContext context) => PageFramework(
        title: 'Pendências',
        dragDownToDismiss: true,
        listWidgets: [
          const SettingsHeader(title: 'O que entra'),
          _chave('pendenciasBancos', AjustesInicio.bancos,
              titulo: 'Bancos desconectados',
              descricao: 'Faixa com "Reconectar" no topo da aba'),
          _chave('pendenciasVencidas', AjustesInicio.vencidas,
              titulo: 'Contas a pagar vencidas',
              descricao:
                  'Entram na fila com "Marcar como paga", depois de Para revisar'),
          const SettingsHeader(title: 'Comportamento'),
          _chave('pendenciasSelo', AjustesInicio.selo,
              titulo: 'Mostrar o contador',
              descricao: 'Bolinha com o total na barra e na lateral'),
          _chave('pendenciasDeslizar', AjustesInicio.deslizar,
              titulo: 'Deslizar para pular',
              descricao: 'Desligado, só o botão "Pular" passa ao próximo'),
        ],
      );
}

class AjustesAnalisePage extends StatelessWidget {
  const AjustesAnalisePage({super.key});

  static const _graficos = {
    'patrimonio': 'Patrimônio',
    'linha': 'Gráfico de linha',
    'pizza': 'Pizza por categoria',
    'mapa': 'Mapa de calor',
  };
  static const _tipos = {'1': 'Tudo', '2': 'Só gastos', '3': 'Só receitas'};

  @override
  Widget build(BuildContext context) => PageFramework(
        title: 'Análise',
        dragDownToDismiss: true,
        listWidgets: [
          const SettingsHeader(title: 'Gráficos'),
          for (final g in _graficos.entries)
            _chave('analise_${g.key}', AjustesInicio.grafico(g.key),
                titulo: g.value),
          const SettingsHeader(title: 'Detalhes'),
          SettingsContainerDropdown(
            title: 'Gráfico de linha mostra',
            initial: '${AjustesInicio.linhaTipo}',
            items: _tipos.keys.toList(),
            getLabel: (v) => _tipos[v],
            onChanged: (v) => _gravar('analiseLinhaTipo', int.parse(v)),
          ),
          SettingsContainer(
            title: 'Ajustes da pizza',
            description: 'Carteiras, período e só receitas/gastos',
            icon: Icons.pie_chart_outline,
            onTap: () => openPieChartHomePageBottomSheetSettings(context),
          ),
          SettingsContainer(
            title: 'Ajustes do mapa de calor',
            description: 'Carteiras e período',
            icon: Icons.calendar_view_month_outlined,
            onTap: () => openBottomSheet(context, HomePageHeatMapSettings()),
          ),
        ],
      );
}
