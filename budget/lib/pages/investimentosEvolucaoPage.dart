import 'package:budget/functions.dart' show pushRoute;
import 'package:budget/pages/meuBancoPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/meuBancoSync.dart' show meuBancoUltimaSync;
import 'package:budget/widgets/editorial/investimentosBlocos.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

/// Total investido, quanto rendeu, a evolução mensal e as aplicações agrupadas por banco.
/// A série vem do Worker (um retrato por mês: saldo no fim do mês, ou o último até agora no mês corrente).
class InvestimentosEvolucaoPage extends StatefulWidget {
  const InvestimentosEvolucaoPage({super.key});

  @override
  State<InvestimentosEvolucaoPage> createState() => _InvestimentosEvolucaoPageState();
}

class _InvestimentosEvolucaoPageState extends State<InvestimentosEvolucaoPage> {
  List<MbAplicacao> aplicacoes = const [];
  List<MbRetratoMes> serie = const [];
  Map<String, MbDetalheInvestimento> detalhes = const {};
  Map<String, String> nomesDasMetas = {};
  bool carregou = false;

  @override
  void initState() {
    super.initState();
    meuBancoUltimaSync.addListener(_carregar);
    _carregar();
  }

  @override
  void dispose() {
    meuBancoUltimaSync.removeListener(_carregar);
    super.dispose();
  }

  Future<void> _carregar() async {
    final a = await mbAplicacoes();
    final s = await mbLerSerieMensal();
    final d = await mbLerDetalhesInvestimentos();
    final metas = await database.select(database.objectives).get();
    if (!mounted) return;
    setState(() {
      aplicacoes = a;
      serie = s;
      detalhes = d;
      nomesDasMetas = {for (final m in metas) m.objectivePk: m.name};
      carregou = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      dragDownToDismiss: true,
      title: 'Investimentos',
      horizontalPaddingConstrained: true,
      slivers: [
        SliverToBoxAdapter(
          // Nada até a primeira leitura local (é rápida); evita piscar o vazio.
          child: !carregou
              ? const SizedBox.shrink()
              : InvestimentosConteudo(
                  aplicacoes: aplicacoes,
                  serie: serie,
                  detalhes: detalhes,
                  nomesDasMetas: nomesDasMetas,
                  hoje: DateTime.now(),
                  onAbrirMeuBanco: () =>
                      pushRoute(context, const MeuBancoPage()),
                ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 50)),
      ],
    );
  }
}

/// Largura a partir da qual a tela passa a duas colunas (esquerda: topo, gráfico e mês a mês; direita: bancos).
const double _larguraDuasColunas = 900;

/// Conteúdo da tela só com dados (sem banco local), para teste e print.
class InvestimentosConteudo extends StatelessWidget {
  const InvestimentosConteudo({
    super.key,
    required this.aplicacoes,
    required this.serie,
    required this.nomesDasMetas,
    required this.hoje,
    this.detalhes = const {},
    this.onAbrirMeuBanco,
  });

  final List<MbAplicacao> aplicacoes;
  final List<MbRetratoMes> serie;
  /// Por id da aplicação: aplicado, rendimento, taxa, vencimento (o que o banco informar).
  final Map<String, MbDetalheInvestimento> detalhes;
  final Map<String, String> nomesDasMetas;
  final DateTime hoje;
  final VoidCallback? onAbrirMeuBanco;

  @override
  Widget build(BuildContext context) {
    if (aplicacoes.isEmpty && serie.isEmpty) return _vazio(context);
    return LayoutBuilder(builder: (context, caixa) {
      final desktop = caixa.maxWidth >= _larguraDuasColunas;
      final topo = TopoInvestimentos(
          aplicacoes: aplicacoes,
          detalhes: detalhes,
          serie: serie,
          hoje: hoje,
          desktop: desktop);
      final grafico = GraficoInvestimentos(serie: serie, hoje: hoje);
      final mesAMes = MesAMesInvestimentos(serie: serie, hoje: hoje);
      final bancos = aplicacoes.isEmpty
          ? const SizedBox.shrink()
          : BancosInvestimentos(
              grupos: mbAgruparAplicacoes(aplicacoes),
              detalhes: detalhes,
              recolher: !desktop,
              onAbrir: (a) => mbAbrirDetalheInvestimento(context,
                  aplicacao: a,
                  detalhe: detalhes[a.id],
                  serie: serie,
                  nomeDaMeta: a.metaPk == null ? null : nomesDasMetas[a.metaPk]));
      Widget espaco(List<Widget> filhos) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < filhos.length; i++)
                Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 16),
                    child: filhos[i]),
            ],
          );
      if (desktop) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 5, child: espaco([topo, grafico, mesAMes])),
            const SizedBox(width: 24),
            Expanded(flex: 6, child: bancos),
          ]),
        );
      }
      final blocos = [topo, grafico, bancos, mesAMes];
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: espaco([
          for (var i = 0; i < blocos.length; i++)
            EntradaSuave(indice: i, child: blocos[i]),
        ]),
      );
    });
  }

  Widget _vazio(BuildContext context) {
    final e = cores(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 48, 30, 0),
      child: Column(children: [
        Icon(Icons.show_chart_rounded, size: 32, color: e.mu),
        const SizedBox(height: 12),
        Text('Nenhum investimento sincronizado ainda.',
            textAlign: TextAlign.center,
            style: EdTexto.corpo(context).copyWith(color: e.mu)),
        if (onAbrirMeuBanco != null)
          TextButton(
            onPressed: onAbrirMeuBanco,
            style: TextButton.styleFrom(
              foregroundColor: e.acc,
              minimumSize: const Size(64, 44),
            ),
            child: const Text('Abrir o Meu Banco'),
          ),
      ]),
    );
  }
}
