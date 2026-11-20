import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/bancos.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show BancoInicio, brl;
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/widgets/editorial/bancosInicio.dart' show LogoBanco;
import 'package:budget/widgets/editorial/contas.dart' show comSinal;
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/lineGraph.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Blocos da tela de Investimentos: topo, gráfico, bancos com as aplicações, "Mês a mês" e a folha de detalhe.
// Só leem dados já carregados (sem banco local), para a tela, os testes e os prints.

const _meses = [
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
  'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'
];

const _mesesCurtos = [
  'jan', 'fev', 'mar', 'abr', 'mai', 'jun',
  'jul', 'ago', 'set', 'out', 'nov', 'dez'
];

String mbNomeDoMes(String mes) {
  final p = mes.split('-');
  final m = p.length == 2 ? int.tryParse(p[1]) : null;
  return m == null || m < 1 || m > 12 ? mes : '${_meses[m - 1]} de ${p[0]}';
}

String mbRotuloCurtoMes(String mes) {
  final p = mes.split('-');
  final m = p.length == 2 ? int.tryParse(p[1]) : null;
  if (m == null || m < 1 || m > 12) return mes;
  final ano = p[0].length == 4 ? p[0].substring(2) : p[0];
  return '${_mesesCurtos[m - 1]}/$ano';
}

String mbMesDe(DateTime hoje) =>
    '${hoje.year}-${hoje.month.toString().padLeft(2, '0')}';

String _capitalizar(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

String _data(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String _percentual(double p) =>
    '${p < 0 ? '−' : '+'}${p.abs().toStringAsFixed(2).replaceAll('.', ',')}%';

String _sinal(double v) => comSinal(v, brl, mais: true);

/// Verde no ganho, cor de alerta na perda, neutro em zero.
Color _corRendimento(EditorialCores e, double v) =>
    v > 0.004 ? e.pos : (v < -0.004 ? e.warn : e.mu);

/// "110% do CDI" vira "110% CDI" no subtítulo da linha.
String? _taxaCurta(({double valor, String? indexador})? t) =>
    mbRotuloTaxa(t)?.replaceFirst('% do ', '% ');

/// Quanto a aplicação rendeu: saldo menos aplicado; sem aplicado, o rendimento que o banco informa.
double? mbRendimentoAplicacao(MbAplicacao a, MbDetalheInvestimento? d) {
  if (d == null) return null;
  return d.aplicado != null ? a.saldo - d.aplicado! : d.rendimento;
}

/// Aplicações de um banco, com o banco já no formato do logo da Início.
typedef GrupoInvestimento = ({BancoInicio banco, List<MbAplicacao> aplicacoes});

/// Agrupa por banco (mesmo casamento por nome da Início): maior total primeiro, "Outros" por último.
List<GrupoInvestimento> mbAgruparAplicacoes(List<MbAplicacao> aplicacoes) {
  final grupos = <String, ({BancoInicio banco, List<MbAplicacao> lista})>{};
  for (final a in aplicacoes) {
    final texto = a.banco?.trim() ?? '';
    final conhecido = mbBancoConhecido(texto);
    final limpo = texto.isEmpty ? '' : mbNomeDoBancoLimpo(texto);
    final id = conhecido?.id ?? (limpo.isEmpty ? 'outros' : mbNormalizarBanco(limpo));
    grupos
        .putIfAbsent(
            id,
            () => (
                  banco: (
                    id: id,
                    nome: conhecido?.nome ?? (limpo.isEmpty ? 'Outros' : limpo),
                    logo: conhecido?.logo,
                    cor: conhecido?.cor,
                    subtitulo: '',
                    total: 0.0,
                    itens: const []
                  ),
                  lista: <MbAplicacao>[]
                ))
        .lista
        .add(a);
  }
  final out = [
    for (final g in grupos.values)
      (
        banco: (
          id: g.banco.id,
          nome: g.banco.nome,
          logo: g.banco.logo,
          cor: g.banco.cor,
          subtitulo: '',
          total: g.lista.fold<double>(0, (s, a) => s + a.saldo),
          itens: g.banco.itens
        ),
        aplicacoes: (g.lista..sort((x, y) => y.saldo.compareTo(x.saldo)))
      )
  ];
  out.sort((a, b) => a.banco.id == 'outros'
      ? 1
      : b.banco.id == 'outros'
          ? -1
          : b.banco.total.compareTo(a.banco.total));
  return out;
}

// ---------------------------------------------------------------------------------------------
// Topo

class TopoInvestimentos extends StatelessWidget {
  const TopoInvestimentos({
    super.key,
    required this.aplicacoes,
    required this.detalhes,
    required this.serie,
    required this.hoje,
    this.desktop = false,
  });

  final List<MbAplicacao> aplicacoes;
  final Map<String, MbDetalheInvestimento> detalhes;
  final List<MbRetratoMes> serie;
  final DateTime hoje;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final total = aplicacoes.fold(0.0, (s, a) => s + a.saldo);
    final variacoes = mbSerieComVariacao(serie);
    final ultima = variacoes.isEmpty ? null : variacoes.last;
    final comAplicado = [
      for (final a in aplicacoes)
        if (detalhes[a.id]?.aplicado != null) (a, detalhes[a.id]!.aplicado!)
    ];
    final investido = comAplicado.fold(0.0, (s, x) => s + x.$2);
    final rendeu = comAplicado.fold(0.0, (s, x) => s + (x.$1.saldo - x.$2));
    final pct = investido > 0 ? rendeu / investido * 100 : null;
    final faltam = aplicacoes.length - comAplicado.length;
    final e = cores(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Saldo total', style: EdTexto.rotulo(context)),
      const SizedBox(height: 8),
      ContagemValor(
          valor: total,
          formatar: brl,
          centavosMenores: true,
          estilo: EdTexto.numeroGrande(context, desktop: desktop)),
      if (ultima?.variacao != null && ultima!.mes.mes == mbMesDe(hoje))
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              '${_sinal(ultima.variacao!)} sobre ${mbNomeDoMes(variacoes[variacoes.length - 2].mes.mes)}',
              style: EdTexto.rotulo(context)
                  .copyWith(color: _corRendimento(e, ultima.variacao!))),
        ),
      if (comAplicado.isNotEmpty) ...[
        const SizedBox(height: 16),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: _Caixa(
                    rotulo: 'Aplicado',
                    valor: brl(investido),
                    cor: e.tx)),
            const SizedBox(width: 10),
            Expanded(
                child: _Caixa(
                    rotulo: 'Rendeu',
                    valor: _sinal(rendeu),
                    complemento: pct == null ? null : _percentual(pct),
                    cor: _corRendimento(e, rendeu))),
          ]),
        ),
        if (faltam > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
                faltam == 1
                    ? 'Uma aplicação fica de fora: o banco não informa quanto foi aplicado nela.'
                    : '$faltam aplicações ficam de fora: o banco não informa quanto foi aplicado nelas.',
                style: EdTexto.rotulo(context)),
          ),
      ],
    ]);
  }
}

class _Caixa extends StatelessWidget {
  const _Caixa(
      {required this.rotulo, required this.valor, required this.cor, this.complemento});
  final String rotulo, valor;
  final String? complemento;
  final Color cor;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Semantics(
      label: '$rotulo $valor${complemento == null ? '' : ', $complemento'}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: e.surf,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: e.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(rotulo, style: EdTexto.rotulo(context).copyWith(fontSize: 11.5)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(valor,
                maxLines: 1,
                style: EdTexto.corpo(context)
                    .copyWith(fontSize: 18, fontWeight: FontWeight.w600, color: cor)),
          ),
          if (complemento != null)
            Text(complemento!,
                style: EdTexto.rotulo(context)
                    .copyWith(fontWeight: FontWeight.w500, color: cor)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Gráfico e Mês a mês

BoxDecoration _decoracaoCartao(EditorialCores e) => BoxDecoration(
    color: e.surf,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: e.line));

class GraficoInvestimentos extends StatelessWidget {
  const GraficoInvestimentos({super.key, required this.serie, required this.hoje});
  final List<MbRetratoMes> serie;
  final DateTime hoje;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    if (serie.length < 2) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: _decoracaoCartao(e),
        child: Text(
            'O gráfico aparece com pelo menos dois meses de histórico. '
            'O primeiro retrato é de ${mbNomeDoMes(serie.isEmpty ? mbMesDe(hoje) : serie.first.mes)}.',
            style: EdTexto.corpo(context).copyWith(color: e.mu)),
      );
    }
    final parcial = serie.last.mes == mbMesDe(hoje);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: _decoracaoCartao(e),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Evolução mensal', style: EdTexto.h2(context))),
          if (parcial)
            Flexible(
              child: Text('${mbRotuloCurtoMes(serie.last.mes)} · até agora',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.rotulo(context).copyWith(color: e.acc)),
            ),
        ]),
        const SizedBox(height: 6),
        LineChartWrapper(
          points: [
            [
              for (var i = 0; i < serie.length; i++)
                Pair(i.toDouble(), serie[i].total)
            ]
          ],
          isCurved: true,
          // Só o mês no eixo (com o ano os rótulos se sobrepõem no celular).
          rotulosX: [for (final m in serie) mbRotuloCurtoMes(m.mes).split('/').first],
          color: e.acc,
          // Diferente de zero faz o eixo Y partir do menor saldo, não de 0 (senão a curva fica achatada).
          amountBefore: serie.first.total == 0 ? 0 : serie.first.total,
        ),
      ]),
    );
  }
}

class MesAMesInvestimentos extends StatefulWidget {
  const MesAMesInvestimentos({super.key, required this.serie, required this.hoje});
  final List<MbRetratoMes> serie;
  final DateTime hoje;

  static const visiveis = 6;

  @override
  State<MesAMesInvestimentos> createState() => _MesAMesState();
}

class _MesAMesState extends State<MesAMesInvestimentos> {
  bool _todos = false;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final meses = mbSerieComVariacao(widget.serie).reversed.toList();
    if (meses.isEmpty) return const SizedBox.shrink();
    final atual = mbMesDe(widget.hoje);
    final mostrados = _todos ? meses : meses.take(MesAMesInvestimentos.visiveis).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: _decoracaoCartao(e),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Mês a mês', style: EdTexto.h2(context)),
        for (var i = 0; i < mostrados.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: e.line),
          _linha(context, mostrados[i], atual),
        ],
        if (meses.length > MesAMesInvestimentos.visiveis)
          Semantics(
            button: true,
            child: TextButton(
              onPressed: () => setState(() => _todos = !_todos),
              style: TextButton.styleFrom(
                  foregroundColor: e.acc, minimumSize: const Size(64, 44)),
              child: Text(_todos ? 'Ver menos' : 'Ver todos (${meses.length})'),
            ),
          )
        else
          const SizedBox(height: 8),
      ]),
    );
  }

  Widget _linha(BuildContext context,
      ({MbRetratoMes mes, double? variacao, double? rendimento}) m, String atual) {
    final e = cores(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_capitalizar(mbNomeDoMes(m.mes.mes)),
                  style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500)),
              if (m.mes.mes == atual) Text('até agora', style: EdTexto.rotulo(context)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(brl(m.mes.total),
                style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500)),
            if (m.variacao != null)
              Text(_sinal(m.variacao!),
                  style: EdTexto.rotulo(context).copyWith(
                      color: m.variacao! > 0 ? e.pos : (m.variacao! < 0 ? e.tx : e.mu))),
            if (m.rendimento != null)
              Text('rendeu ${_sinal(m.rendimento!)}', style: EdTexto.rotulo(context)),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Bancos e aplicações

/// Bancos com as aplicações. [recolher] (celular): cada banco abre e fecha ao toque e só o primeiro
/// (o de maior total) começa aberto; no desktop ficam todos abertos.
class BancosInvestimentos extends StatelessWidget {
  const BancosInvestimentos({
    super.key,
    required this.grupos,
    required this.detalhes,
    required this.recolher,
    required this.onAbrir,
  });

  final List<GrupoInvestimento> grupos;
  final Map<String, MbDetalheInvestimento> detalhes;
  final bool recolher;
  final void Function(MbAplicacao) onAbrir;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text('Por banco', style: EdTexto.h2(context)),
      ),
      for (var i = 0; i < grupos.length; i++)
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
          child: _BlocoBanco(
              key: ValueKey('banco-${grupos[i].banco.id}'),
              grupo: grupos[i],
              detalhes: detalhes,
              recolher: recolher,
              abertoInicial: i == 0,
              onAbrir: onAbrir),
        ),
    ]);
  }
}

class _BlocoBanco extends StatefulWidget {
  const _BlocoBanco({
    super.key,
    required this.grupo,
    required this.detalhes,
    required this.recolher,
    required this.abertoInicial,
    required this.onAbrir,
  });
  final GrupoInvestimento grupo;
  final Map<String, MbDetalheInvestimento> detalhes;
  final bool recolher, abertoInicial;
  final void Function(MbAplicacao) onAbrir;

  @override
  State<_BlocoBanco> createState() => _BlocoBancoState();
}

class _BlocoBancoState extends State<_BlocoBanco> {
  late bool _aberto = widget.abertoInicial;

  void _alternar() => setState(() => _aberto = !_aberto);

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final banco = widget.grupo.banco, apps = widget.grupo.aplicacoes;
    final aberto = !widget.recolher || _aberto;
    final qtd = apps.length == 1 ? '1 aplicação' : '${apps.length} aplicações';
    final cabecalho = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        LogoBanco(banco: banco),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(banco.nome,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600)),
            Text(qtd, style: EdTexto.rotulo(context)),
          ]),
        ),
        const SizedBox(width: 8),
        Text(brl(banco.total),
            style: EdTexto.corpo(context)
                .copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
        if (widget.recolher) ...[
          const SizedBox(width: 4),
          AnimatedRotation(
              turns: _aberto ? .5 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(Icons.keyboard_arrow_down_rounded, size: 22, color: e.mu)),
        ],
      ]),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
          color: e.surf,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: e.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(
          container: true,
          button: widget.recolher,
          expanded: widget.recolher ? _aberto : null,
          onTap: widget.recolher ? _alternar : null,
          label: '${banco.nome}, $qtd, total ${brl(banco.total)}',
          excludeSemantics: true,
          child: widget.recolher
              ? ToqueEscala(onTap: _alternar, child: cabecalho)
              : cabecalho,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: aberto
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const SizedBox(height: 2),
                  Divider(height: 1, thickness: 1, color: e.line),
                  for (final a in apps)
                    _LinhaAplicacao(
                        aplicacao: a,
                        detalhe: widget.detalhes[a.id],
                        onTap: () => widget.onAbrir(a)),
                ])
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

class _LinhaAplicacao extends StatelessWidget {
  const _LinhaAplicacao(
      {required this.aplicacao, required this.detalhe, required this.onTap});
  final MbAplicacao aplicacao;
  final MbDetalheInvestimento? detalhe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final a = aplicacao, d = detalhe;
    final subtitulo = [
      if (d?.subtipo != null && d!.subtipo!.trim().isNotEmpty) d.subtipo!.trim(),
      if (_taxaCurta(d?.taxa) != null) _taxaCurta(d?.taxa)!,
    ].join(' · ');
    final vence = d?.vencimento == null ? null : 'vence ${_data(d!.vencimento!)}';
    final rend = mbRendimentoAplicacao(a, d);
    return Semantics(
      button: true,
      label: '${a.nome}, saldo ${brl(a.saldo)}'
          '${rend == null ? '' : ', rendeu ${_sinal(rend)}'}',
      excludeSemantics: true,
      child: ToqueEscala(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.nome,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500)),
                if (subtitulo.isNotEmpty)
                  Text(subtitulo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: EdTexto.rotulo(context)),
                if (vence != null) Text(vence, style: EdTexto.rotulo(context)),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(brl(a.saldo),
                  style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600)),
              if (rend != null)
                Text(_sinal(rend),
                    style: EdTexto.rotulo(context).copyWith(
                        fontWeight: FontWeight.w500, color: _corRendimento(e, rend))),
            ]),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 18, color: e.mu),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Folha de detalhe (só leitura)

Future<void> mbAbrirDetalheInvestimento(
  BuildContext context, {
  required MbAplicacao aplicacao,
  required MbDetalheInvestimento? detalhe,
  required List<MbRetratoMes> serie,
  required String? nomeDaMeta,
}) {
  return openBottomSheet(
    context,
    PopupFramework(
      title: aplicacao.nome,
      subtitle: aplicacao.banco == null ? null : mbNomeDoBancoLimpo(aplicacao.banco!),
      showCloseButton: true,
      child: Builder(
        // Esc fecha a folha (clique fora e X já fecham).
        builder: (c) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(c).maybePop(),
          },
          child: Focus(
            autofocus: true,
            child: DetalheInvestimento(
                aplicacao: aplicacao,
                detalhe: detalhe,
                serie: serie,
                nomeDaMeta: nomeDaMeta),
          ),
        ),
      ),
    ),
  );
}

class DetalheInvestimento extends StatelessWidget {
  const DetalheInvestimento({
    super.key,
    required this.aplicacao,
    required this.detalhe,
    required this.serie,
    required this.nomeDaMeta,
  });
  final MbAplicacao aplicacao;
  final MbDetalheInvestimento? detalhe;
  final List<MbRetratoMes> serie;
  final String? nomeDaMeta;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final a = aplicacao, d = detalhe;
    final rend = mbRendimentoAplicacao(a, d);
    final pct = d?.aplicado != null && d!.aplicado! > 0 && rend != null
        ? rend / d.aplicado! * 100
        : d?.percentual;
    final linhas = <(String, String, Color?)>[
      if (d?.aplicado != null) ('Aplicado', brl(d!.aplicado!), null),
      if (rend != null)
        (
          'Rendeu',
          pct == null ? _sinal(rend) : '${_sinal(rend)} (${_percentual(pct)})',
          _corRendimento(e, rend)
        ),
      if (d?.impostos != null) ('Impostos', brl(d!.impostos!), null),
      if (d?.liquido != null) ('Líquido', brl(d!.liquido!), null),
      if (mbRotuloTaxa(d?.taxa) != null) ('Taxa', mbRotuloTaxa(d?.taxa)!, null),
      if (d?.rentabilidadeMes != null)
        ('Rentabilidade no mês', _percentual(d!.rentabilidadeMes!), null),
      if (d?.rentabilidade12m != null)
        ('Rentabilidade em 12 meses', _percentual(d!.rentabilidade12m!), null),
      if (d?.aplicadoEm != null) ('Aplicado em', _data(d!.aplicadoEm!), null),
      if (d?.vencimento != null) ('Vencimento', _data(d!.vencimento!), null),
      if (d?.emissor != null && d!.emissor!.trim().isNotEmpty)
        ('Emissor', d.emissor!.trim(), null),
      if (nomeDaMeta != null) ('Meta', nomeDaMeta!, null),
    ];
    final evolucao = [
      for (final m in serie)
        for (final i in m.itens)
          if (i.id == a.id) (m.mes, i.saldo)
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Saldo', style: EdTexto.rotulo(context)),
        const SizedBox(height: 4),
        Text(brl(a.saldo), style: EdTexto.numeroGrande(context).copyWith(fontSize: 32)),
        const SizedBox(height: 12),
        for (var i = 0; i < linhas.length; i++) ...[
          Divider(height: 1, thickness: 1, color: e.line),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(children: [
              ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 190),
                  child: Text(linhas[i].$1, style: EdTexto.rotulo(context))),
              const SizedBox(width: 12),
              Expanded(
                child: Text(linhas[i].$2,
                    textAlign: TextAlign.end,
                    style: EdTexto.corpo(context).copyWith(
                        fontWeight: FontWeight.w500, color: linhas[i].$3)),
              ),
            ]),
          ),
        ],
        if (evolucao.length >= 2) _MiniEvolucao(pontos: evolucao),
      ]),
    );
  }
}

/// Saldo da aplicação nos últimos meses (até 6); a barra mostra a variação entre o menor e o maior saldo.
class _MiniEvolucao extends StatelessWidget {
  const _MiniEvolucao({required this.pontos});
  final List<(String, double)> pontos;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final ultimos = pontos.length > 6 ? pontos.sublist(pontos.length - 6) : pontos;
    final maior = ultimos.fold(double.negativeInfinity, (m, p) => p.$2 > m ? p.$2 : m);
    final menor = ultimos.fold(double.infinity, (m, p) => p.$2 < m ? p.$2 : m);
    final faixa = maior - menor;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Evolução mensal', style: EdTexto.h2(context)),
        const SizedBox(height: 8),
        for (final p in ultimos)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              SizedBox(
                  width: 52,
                  child: Text(mbRotuloCurtoMes(p.$1), style: EdTexto.rotulo(context))),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: faixa <= 0 ? 1.0 : 0.2 + 0.8 * (p.$2 - menor) / faixa,
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                          color: e.acc.withOpacity(.75),
                          borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(brl(p.$2), style: EdTexto.corpo(context).copyWith(fontSize: 13)),
            ]),
          ),
      ]),
    );
  }
}
