import 'package:budget/struct/editorial.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/budgetPage.dart';
import 'package:budget/struct/mbSync/orcamentos.dart'
    show mbWatchAVencerOrcamento, mbWatchGastoOrcamento;
import 'package:budget/struct/ritmoCiclo.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:budget/colors.dart';
import 'package:budget/functions.dart';

/// Dias do período a partir de hoje, contando hoje; nulo fora do período.
int? diasRestantesOrcamento(DateTimeRange periodo, DateTime agora) {
  final hoje = agora.justDay();
  if (hoje.isBefore(periodo.start.justDay()) || hoje.isAfter(periodo.end)) {
    return null;
  }
  return periodo.end.difference(hoje).inDays + 1;
}

/// "5 de nov. – 4 de dez.", sem "Hoje"/"Amanhã" nas pontas.
String textoPeriodoOrcamento(DateTimeRange p, {bool ano = false}) {
  final a = getWordedDateShort(p.start, includeYear: ano, showTodayTomorrow: false);
  final b = getWordedDateShort(p.end, includeYear: ano, showTodayTomorrow: false);
  return a == b ? a : '$a – $b';
}

/// Formata dinheiro fora do Provider de carteiras (a Início e os prints): `inteiro` pede sem centavos.
typedef FormatarDinheiro = String Function(double valor, {bool inteiro});

/// Sem [formatar], usa a moeda da carteira selecionada (precisa do Provider de carteiras).
String _dinheiro(BuildContext context, FormatarDinheiro? formatar, double v,
    {bool inteiro = false, bool todasCasas = false}) {
  if (formatar != null) return formatar(v, inteiro: inteiro);
  return convertToMoney(Provider.of<AllWallets>(context), v,
      decimals: inteiro ? 0 : null, allDecimals: todasCasas ? true : null);
}

/// Barra do orçamento (a mesma na Início, na lista e no detalhe): gasto,
/// faixa das contas a vencer e marca de "hoje", com rótulo de leitor de tela.
class BarraOrcamento extends StatelessWidget {
  const BarraOrcamento({
    super.key,
    required this.gasto,
    required this.limite,
    this.aVencer = 0,
    this.hoje,
    this.renda = false,
    this.alerta = false,
  });

  final double gasto, limite, aVencer;
  final double? hoje;
  final bool renda, alerta;

  @override
  Widget build(BuildContext context) => Semantics(
        label: semanticaBarraCiclo(gasto, limite, hoje, renda: renda),
        child: MedidorEditorial(
          fracao: gasto / limite,
          aVencer: aVencer / limite,
          hoje: hoje,
          alerta: alerta,
          altura: 6,
        ),
      );
}

/// Quanto resta (ou passou) do limite: rótulo, valor grande, medidor e
/// "Gasto X de Y". Recebe os totais prontos (não lê o banco).
class ResumoOrcamento extends StatelessWidget {
  const ResumoOrcamento({
    super.key,
    required this.gasto,
    required this.limite,
    this.renda = false,
    this.diasRestantes,
    this.aVencer = 0,
    this.hoje,
    this.grande = false,
    this.mostrarGasto = false,
    this.onTapValor,
    this.periodo,
    this.formatar,
    this.rotulo,
    this.selo,
    this.rodape,
    this.corEstouro,
  });

  final double gasto, limite;

  /// Formatação sem Provider de carteiras (Início); nulo usa a moeda da carteira.
  final FormatarDinheiro? formatar;

  /// Troca o rótulo acima do valor ("Para gastar no ciclo"); [selo] vai à direita dele.
  final String? rotulo;
  final Widget? selo;

  /// Texto pronto da linha de baixo (ex.: "06 nov – 05 dez · R$ 35,32/dia"): substitui período e limite,
  /// e o ritmo diário da versão grande já vem nele.
  final String? rodape;

  /// Cor do valor quando passa do limite; padrão: a de gasto estourado do tema.
  final Color? corEstouro;

  /// Datas do período, no rodapé ("5 nov – 4 dez · limite R$ 4.630").
  final String? periodo;

  /// Orçamento de poupança: o "gasto" é o que entrou.
  final bool renda;

  /// Dias do período a partir de hoje (contando hoje); nulo fora do período.
  final int? diasRestantes;

  /// Não pago no período (faixa clara da barra).
  final double aVencer;

  /// Fração do período decorrida (marca de "hoje"); nula fora do período.
  final double? hoje;

  /// Tela do orçamento: número de 40 px e ritmo diário.
  final bool grande;

  /// Preferência "mostrar total gasto" no lugar do restante.
  final bool mostrarGasto;
  final VoidCallback? onTapValor;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    String dinheiro(double v) => _dinheiro(context, formatar, v);
    // Sempre com centavos: o número não muda de formato ao terminar de contar.
    String contando(double v) => _dinheiro(context, formatar, v, todasCasas: true);
    final restante = limite - gasto;
    final passou = restante < 0;
    final entrou = renda ? 'Guardado' : 'Gasto';
    final falta = renda
        ? (passou ? 'Acima da meta' : 'Falta guardar')
        : (passou ? 'Acima do limite' : 'Resta');
    // Estouro de gasto em vermelho; poupança acima da meta em verde.
    final cor = passou
        ? (renda ? e.pos : corEstouro ?? getColor(context, "overspentAmount"))
        : null;
    final base = EdTexto.numeroGrande(context);
    final estilo = (grande
            ? base
            : base.copyWith(fontSize: 28, letterSpacing: -.84))
        .copyWith(color: mostrarGasto ? null : cor);
    final rotuloEstilo = EdTexto.rotulo(context);
    final dias = diasRestantes;
    Widget numero = ContagemValor(
      valor: mostrarGasto ? gasto : restante.abs(),
      formatar: contando,
      centavosMenores: true,
      estilo: estilo,
    );
    if (onTapValor != null) {
      numero = Semantics(
        button: true,
        hint: mostrarGasto ? 'Mostrar o restante' : 'Mostrar o gasto',
        child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTapValor,
            child: numero),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selo == null)
          Text(this.rotulo ?? (mostrarGasto ? entrou : falta), style: rotuloEstilo)
        else
          Row(children: [
            Expanded(
                child: Text(this.rotulo ?? (mostrarGasto ? entrou : falta),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: rotuloEstilo)),
            const SizedBox(width: 8),
            selo!,
          ]),
        SizedBox(height: grande ? 8 : 4),
        numero,
        SizedBox(height: grande ? 14 : 12),
        if (limite > 0)
          BarraOrcamento(
              gasto: gasto,
              limite: limite,
              aVencer: aVencer,
              hoje: hoje,
              renda: renda,
              alerta: passou && !renda)
        else
          const MedidorEditorial(fracao: 0),
        if (limite > 0) ...[
          const SizedBox(height: 12),
          _TresBlocos(
              gasto: gasto,
              limite: limite,
              aVencer: aVencer,
              renda: renda,
              formatar: formatar),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                rodape ??
                    [if (periodo != null) periodo!, 'limite ${dinheiro(limite)}']
                        .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: rotuloEstilo,
              ),
            ),
            if (dias != null) ...[
              const SizedBox(width: 8),
              Text(dias <= 1 ? 'último dia' : '$dias dias', style: rotuloEstilo),
            ],
          ],
        ),
        if (grande && rodape == null && dias != null && restante > 0) ...[
          const SizedBox(height: 10),
          Text(
            '${renda ? 'Guarde' : 'Pode gastar'} ${dinheiro(restante / dias)}/dia',
            style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ],
    );
  }
}

/// Selo de ritmo do cabeçalho: quanto o gasto está acima/abaixo do ideal até
/// hoje (limite × fração do ciclo). Sem marca de hoje ou sem limite: nada.
class SeloRitmo extends StatelessWidget {
  const SeloRitmo({
    super.key,
    required this.gasto,
    required this.limite,
    required this.hoje,
    this.renda = false,
    this.formatar,
    this.faixa,
  });

  final double gasto, limite;
  final double? hoje;
  final bool renda;
  final FormatarDinheiro? formatar;

  /// Lista de orçamentos: vira uma faixa da largura do cartão, com este texto depois do ritmo.
  final String? faixa;

  @override
  Widget build(BuildContext context) {
    final fracao = hoje;
    if (fracao == null || limite <= 0) return const SizedBox.shrink();
    final e = cores(context);
    final dif = gasto - idealAteHoje(limite, fracao);
    final noRitmo = dif.abs() < .5;
    final acima = dif > 0;
    final valor = _dinheiro(context, formatar, dif.abs(), inteiro: true);
    final texto = noRitmo
        ? 'No ritmo'
        : '${acima ? '▲' : '▼'} $valor '
            '${acima ? 'acima' : 'abaixo'} ${renda ? 'da meta' : 'do ritmo'}';
    // Despesa acima do ritmo é ruim; poupança acima da meta é boa; poupança
    // abaixo da meta fica neutra (no começo do ciclo é normal).
    final (Color fundo, Color letra) = noRitmo || (renda && !acima)
        ? (e.line, e.mu)
        : acima == renda
            ? (e.pos.withOpacity(.14), e.pos)
            : (e.warnbg, e.warntx);
    final semSeta = texto.replaceAll('▲ ', '').replaceAll('▼ ', '');
    if (faixa != null) {
      return CartaoBento(
        cor: fundo,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text('$semSeta · $faixa',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: EdTexto.rotulo(context).copyWith(
                color: letra, fontWeight: FontWeight.w500, fontSize: 13)),
      );
    }
    return Semantics(
      label: semSeta,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration:
            BoxDecoration(color: fundo, borderRadius: BorderRadius.circular(99)),
        child: Text(texto,
            maxLines: 1,
            style: EdTexto.rotulo(context).copyWith(
                color: letra, fontWeight: FontWeight.w600, fontSize: 11)),
      ),
    );
  }
}

/// Gasto, a vencer e livre do limite, cada um com a cor da sua faixa na barra.
/// "A vencer" some quando é zero.
class _TresBlocos extends StatelessWidget {
  const _TresBlocos({
    required this.gasto,
    required this.limite,
    required this.aVencer,
    required this.renda,
    this.formatar,
    this.plano = false,
  });

  final double gasto, limite, aVencer;
  final bool renda;
  final FormatarDinheiro? formatar;

  /// Lista de orçamentos: só rótulo e valor, sem caixa nem quadradinho de cor.
  final bool plano;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    String dinheiro(double v) => _dinheiro(context, formatar, v);
    final livre = (limite - gasto - aVencer).clamp(0.0, double.infinity);
    final estourou = gasto > limite && !renda;
    final blocos = [
      (renda ? 'Guardado' : 'Gasto', gasto, estourou ? e.warn : e.acc, false),
      if (aVencer > 0)
        (renda ? 'A entrar' : 'A vencer', aVencer, e.acc.withOpacity(.35),
            false),
      (renda ? 'Falta' : 'Livre', livre, e.line, true),
    ];
    final estiloValor = EdTexto.corpo(context)
        .copyWith(fontSize: 14, fontWeight: FontWeight.w700);
    return Row(
      children: [
        for (var i = 0; i < blocos.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              label: '${blocos[i].$1} ${dinheiro(blocos[i].$2)}',
              excludeSemantics: true,
              child: Container(
                padding: plano
                    ? null
                    : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: plano
                    ? null
                    : BoxDecoration(
                        color: e.bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: e.line),
                      ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (!plano)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsetsDirectional.only(end: 6),
                            decoration: BoxDecoration(
                              color: blocos[i].$3,
                              borderRadius: BorderRadius.circular(2),
                              border: blocos[i].$4
                                  ? Border.all(color: e.mu.withOpacity(.4))
                                  : null,
                            ),
                          ),
                        Flexible(
                          child: Text(blocos[i].$1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: EdTexto.rotulo(context)
                                  .copyWith(fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(dinheiro(blocos[i].$2),
                          maxLines: 1, style: estiloValor),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Cartão da lista de orçamentos. O principal ocupa a largura toda (valor grande,
/// barra, gasto/a vencer/livre e a faixa de ritmo); [compacto] cabe em meia largura.
class CartaoOrcamento extends StatelessWidget {
  const CartaoOrcamento({
    super.key,
    required this.nome,
    required this.cor,
    required this.periodo,
    required this.gasto,
    required this.limite,
    this.renda = false,
    this.diasRestantes,
    this.aVencer = 0,
    this.hoje,
    this.compacto = false,
    this.onTap,
    this.onLongPress,
  });

  final String nome, periodo;
  final Color cor;
  final double gasto, limite, aVencer;
  final double? hoje;
  final bool renda, compacto;
  final int? diasRestantes;
  final VoidCallback? onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final rotulo = EdTexto.rotulo(context);
    final restante = limite - gasto;
    final passou = restante < 0;
    final mostrarGasto = appStateSettings["showTotalSpentForBudget"] == true;
    final palavra = mostrarGasto
        ? (renda ? 'guardado' : 'gasto')
        : renda
            ? (passou ? 'acima da meta' : 'falta guardar')
            : (passou ? 'acima do limite' : 'resta');
    // Meia largura: uma palavra só, à direita do limite.
    final curta = mostrarGasto
        ? palavra
        : renda
            ? (passou ? 'acima' : 'falta')
            : (passou ? 'estourou' : 'resta');
    // Estouro de gasto em vermelho; poupança acima da meta em verde.
    final corValor = !passou || mostrarGasto
        ? null
        : (renda ? e.pos : getColor(context, "overspentAmount"));
    final tamanho = compacto ? 22.0 : 40.0;
    final numero = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: ContagemValor(
        valor: mostrarGasto ? gasto : restante.abs(),
        // Sempre com centavos: o número não muda de formato ao terminar de contar.
        formatar: (v) => _dinheiro(context, null, v, todasCasas: true),
        centavosMenores: true,
        estilo: EdTexto.numeroGrande(context).copyWith(
            fontSize: tamanho, letterSpacing: -.03 * tamanho, color: corValor),
      ),
    );
    final barra = limite > 0
        ? BarraOrcamento(
            gasto: gasto,
            limite: limite,
            aVencer: aVencer,
            hoje: hoje,
            renda: renda,
            alerta: passou && !renda)
        : const MedidorEditorial(fracao: 0);
    final ponto = Container(
      width: 8,
      height: 8,
      margin: const EdgeInsetsDirectional.only(end: 8),
      decoration: BoxDecoration(shape: BoxShape.circle, color: cor),
    );
    final dias = diasRestantes;
    final Widget cartao;
    if (compacto) {
      cartao = CartaoBento(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              ponto,
              Expanded(
                child: Text(nome,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context)
                        .copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 10),
            numero,
            const SizedBox(height: 14),
            barra,
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text(
                    'de ${_dinheiro(context, null, limite, inteiro: true)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: rotulo),
              ),
              const SizedBox(width: 8),
              Text(curta, style: rotulo),
            ]),
          ],
        ),
      );
    } else {
      cartao = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          CartaoBento(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  ponto,
                  Expanded(
                    child: Text('$nome · $palavra',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: rotulo.copyWith(fontSize: 14)),
                  ),
                  if (dias != null) ...[
                    const SizedBox(width: 8),
                    Text(dias <= 1 ? 'último dia' : '$dias dias', style: rotulo),
                  ],
                ]),
                const SizedBox(height: 8),
                numero,
                const SizedBox(height: 14),
                barra,
                if (limite > 0) ...[
                  Container(
                      height: 1,
                      color: e.line,
                      margin: const EdgeInsets.symmetric(vertical: 14)),
                  _TresBlocos(
                      gasto: gasto,
                      limite: limite,
                      aVencer: aVencer,
                      renda: renda,
                      plano: true),
                ],
              ],
            ),
          ),
          if (hoje != null && limite > 0) ...[
            const SizedBox(height: 10),
            SeloRitmo(
                gasto: gasto,
                limite: limite,
                hoje: hoje,
                renda: renda,
                faixa: periodo),
          ],
        ],
      );
    }
    return GestureDetector(
      onLongPress: onLongPress,
      child: ToqueEscala(onTap: onTap, child: cartao),
    );
  }
}

/// Liga o cartão ao banco: soma o gasto do período atual do orçamento.
class BudgetContainer extends StatelessWidget {
  const BudgetContainer({
    super.key,
    required this.budget,
    this.longPressToEdit = true,
    this.compacto = false,
  });

  final Budget budget;
  final bool longPressToEdit, compacto;

  @override
  Widget build(BuildContext context) {
    final carteiras = Provider.of<AllWallets>(context);
    final limite = budgetAmountToPrimaryCurrency(carteiras, budget);
    final agora = DateTime.now();
    final periodo = getBudgetDate(budget, agora);
    return StreamBuilder<double>(
      stream: mbWatchGastoOrcamento(budget, carteiras, periodo),
      builder: (context, snapshot) {
        final gasto = snapshot.data;
        // Mesma altura do cartão carregado: sem salto ao chegar o total.
        if (gasto == null) return SizedBox(height: compacto ? 129 : 232);
        return StreamBuilder<double>(
          stream: mbWatchAVencerOrcamento(budget, carteiras, periodo),
          builder: (context, aVencer) => CartaoOrcamento(
            nome: budget.name,
            cor: HexColor(budget.colour,
                defaultColor: Theme.of(context).colorScheme.primary),
            periodo: textoPeriodoOrcamento(periodo,
                ano: budget.reoccurrence == BudgetReoccurence.yearly),
            gasto: gasto,
            limite: limite,
            renda: budget.income,
            diasRestantes: diasRestantesOrcamento(periodo, agora),
            aVencer: aVencer.data ?? 0,
            hoje: fracaoDoCiclo(periodo.start, periodo.end, agora),
            compacto: compacto,
            onTap: () => pushRoute(
                context, BudgetPage(budgetPk: budget.budgetPk, dateForRange: agora)),
            onLongPress: longPressToEdit
                ? () => pushRoute(
                      context,
                      AddBudgetPage(
                        budget: budget,
                        routesToPopAfterDelete: RoutesToPopAfterDelete.One,
                      ),
                    )
                : null,
          ),
        );
      },
    );
  }
}
