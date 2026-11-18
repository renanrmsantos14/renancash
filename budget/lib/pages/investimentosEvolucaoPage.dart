import 'package:budget/functions.dart' show pushRoute;
import 'package:budget/pages/meuBancoPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl;
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/meuBancoSync.dart' show meuBancoUltimaSync;
import 'package:budget/widgets/editorial/contas.dart' show comSinal;
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/lineGraph.dart';
import 'package:flutter/material.dart';

const _meses = [
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
  'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'
];

const _mesesCurtos = [
  'jan', 'fev', 'mar', 'abr', 'mai', 'jun',
  'jul', 'ago', 'set', 'out', 'nov', 'dez'
];

String _nomeDoMes(String mes) {
  final p = mes.split('-');
  final m = p.length == 2 ? int.tryParse(p[1]) : null;
  return m == null || m < 1 || m > 12 ? mes : '${_meses[m - 1]} de ${p[0]}';
}

String _rotuloCurtoMes(String mes) {
  final p = mes.split('-');
  final m = p.length == 2 ? int.tryParse(p[1]) : null;
  if (m == null || m < 1 || m > 12) return mes;
  final ano = p[0].length == 4 ? p[0].substring(2) : p[0];
  return '${_mesesCurtos[m - 1]}/$ano';
}

String _capitalizar(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

String _mesAtual(DateTime hoje) =>
    '${hoje.year}-${hoje.month.toString().padLeft(2, '0')}';

/// Saldo atual dos investimentos (Inter e Santander juntos) e a evolução mês a mês.
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
    final blocos = [_saldoAtual(context), _grafico(context), _lista(context)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocos.length; i++)
          EntradaSuave(indice: i, child: blocos[i]),
      ],
    );
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

  Widget _cartao(BuildContext context, Widget child) {
    final e = cores(context);
    return Container(
      margin: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 12),
      padding: const EdgeInsetsDirectional.all(16),
      decoration: BoxDecoration(
        color: e.surf,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: e.line),
      ),
      child: child,
    );
  }

  Widget _variacao(BuildContext context, double? v, {double fontSize = 13}) {
    if (v == null) return const SizedBox.shrink();
    final e = cores(context);
    return Text(comSinal(v, brl, mais: true),
        style: EdTexto.corpo(context).copyWith(
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
            color: v > 0 ? e.pos : (v < 0 ? e.tx : e.mu)));
  }

  Widget _saldoAtual(BuildContext context) {
    final total = aplicacoes.fold(0.0, (s, a) => s + a.saldo);
    final variacoes = mbSerieComVariacao(serie);
    final ultima = variacoes.isEmpty ? null : variacoes.last;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Saldo atual', style: EdTexto.rotulo(context)),
        const SizedBox(height: 8),
        ContagemValor(
            valor: total,
            formatar: brl,
            centavosMenores: true,
            estilo: EdTexto.numeroGrande(context)),
        if (ultima?.variacao != null && ultima!.mes.mes == _mesAtual(hoje))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              _variacao(context, ultima.variacao),
              Flexible(
                child: Text(
                    ' sobre ${_nomeDoMes(variacoes[variacoes.length - 2].mes.mes)}',
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.rotulo(context)),
              ),
            ]),
          ),
        _investidoERendeu(context),
        if (aplicacoes.isNotEmpty) const SizedBox(height: 12),
        for (final a in aplicacoes) _linhaAplicacao(context, a),
      ]),
    );
  }

  /// "Você investiu" e "Rendeu" somando as aplicações em que o banco informa o valor aplicado.
  Widget _investidoERendeu(BuildContext context) {
    final comAplicado = [
      for (final a in aplicacoes)
        if (detalhes[a.id]?.aplicado != null) (a, detalhes[a.id]!)
    ];
    if (comAplicado.isEmpty) return const SizedBox.shrink();
    final investido = comAplicado.fold(0.0, (s, x) => s + x.$2.aplicado!);
    final rendeu = comAplicado.fold(0.0, (s, x) => s + (x.$1.saldo - x.$2.aplicado!));
    final faltam = aplicacoes.length - comAplicado.length;
    final e = cores(context);
    Widget coluna(String rotulo, Widget valor) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(rotulo, style: EdTexto.rotulo(context)),
            const SizedBox(height: 2),
            valor,
          ]),
        );
    final pct = investido > 0 ? rendeu / investido * 100 : null;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          coluna(
              'Você investiu',
              Text(brl(investido),
                  style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500))),
          coluna(
              'Rendeu',
              Wrap(crossAxisAlignment: WrapCrossAlignment.end, children: [
                _variacao(context, rendeu, fontSize: 15),
                if (pct != null)
                  Text(' (${_percentual(pct)})', style: EdTexto.rotulo(context)),
              ])),
        ]),
        if (faltam > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                faltam == 1
                    ? 'Uma aplicação fica de fora: o banco não informa quanto foi aplicado nela.'
                    : '$faltam aplicações ficam de fora: o banco não informa quanto foi aplicado nelas.',
                style: EdTexto.rotulo(context).copyWith(color: e.mu)),
          ),
      ]),
    );
  }

  Widget _linhaAplicacao(BuildContext context, MbAplicacao a) {
    final d = detalhes[a.id];
    final detalhe = [
      if (a.banco != null) a.banco!,
      if (a.metaPk != null && nomesDasMetas[a.metaPk] != null)
        'Meta ${nomesDasMetas[a.metaPk]}',
    ].join(' · ');
    final contrato = d == null
        ? ''
        : [
            if (mbRotuloTaxa(d.taxa) != null) mbRotuloTaxa(d.taxa)!,
            if (d.vencimento != null) 'vence em ${_data(d.vencimento!)}',
          ].join(' · ');
    final aplicado = d?.aplicado;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Row(children: [
        Expanded(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.nome,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context)
                        .copyWith(fontWeight: FontWeight.w500)),
                if (detalhe.isNotEmpty)
                  Text(detalhe, style: EdTexto.rotulo(context)),
                if (contrato.isNotEmpty)
                  Text(contrato, style: EdTexto.rotulo(context)),
              ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(brl(a.saldo),
              style:
                  EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500)),
          if (aplicado != null) ...[
            Text('aplicou ${brl(aplicado)}', style: EdTexto.rotulo(context)),
            _variacao(context, a.saldo - aplicado, fontSize: 12.5),
          ],
        ]),
      ]),
    );
  }

  static String _data(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _percentual(double p) =>
      '${p >= 0 ? '+' : ''}${p.toStringAsFixed(2).replaceAll('.', ',')}%';

  Widget _grafico(BuildContext context) {
    if (serie.length < 2) {
      return _cartao(
          context,
          Text(
              'O gráfico aparece com pelo menos dois meses de histórico. '
              'O primeiro retrato é de ${_nomeDoMes(serie.isEmpty ? _mesAtual(hoje) : serie.first.mes)}.',
              style: EdTexto.corpo(context).copyWith(color: cores(context).mu)));
    }
    final rotulosX = [for (final m in serie) _rotuloCurtoMes(m.mes)];
    final pontos = [
      for (var i = 0; i < serie.length; i++)
        Pair(i.toDouble(), serie[i].total)
    ];
    return _cartao(
      context,
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Total por mês', style: EdTexto.h2(context)),
        LineChartWrapper(
          points: [pontos],
          isCurved: true,
          rotulosX: rotulosX,
          color: cores(context).acc,
        ),
      ]),
    );
  }

  Widget _lista(BuildContext context) {
    final e = cores(context);
    final atual = _mesAtual(hoje);
    final meses = mbSerieComVariacao(serie).reversed.toList();
    if (meses.isEmpty) return const SizedBox.shrink();
    return _cartao(
      context,
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Mês a mês', style: EdTexto.h2(context)),
        const SizedBox(height: 4),
        for (final m in meses)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: ValueKey('mes-${m.mes.mes}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsetsDirectional.only(bottom: 8),
              iconColor: e.mu,
              collapsedIconColor: e.mu,
              initiallyExpanded: m.mes.mes == atual,
              title: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_capitalizar(_nomeDoMes(m.mes.mes)),
                        style: EdTexto.corpo(context)
                            .copyWith(fontWeight: FontWeight.w500)),
                    if (m.mes.mes == atual)
                      Text('até agora', style: EdTexto.rotulo(context)),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(brl(m.mes.total),
                      style: EdTexto.corpo(context)
                          .copyWith(fontWeight: FontWeight.w500)),
                  _variacao(context, m.variacao, fontSize: 12.5),
                  if (m.rendimento != null)
                    Text('rendeu ${comSinal(m.rendimento!, brl, mais: true)}',
                        style: EdTexto.rotulo(context)),
                ]),
              ]),
              children: [
                for (final i in m.mes.itens)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(bottom: 4),
                    child: Row(children: [
                      Expanded(
                          child: Text(
                              [i.nome, if (i.banco != null) i.banco!].join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: EdTexto.rotulo(context))),
                      Text(brl(i.saldo), style: EdTexto.rotulo(context)),
                    ]),
                  ),
              ],
            ),
          ),
      ]),
    );
  }
}
