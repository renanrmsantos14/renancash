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
  });

  final double gasto, limite;

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
    final carteiras = Provider.of<AllWallets>(context);
    String dinheiro(double v) => convertToMoney(carteiras, v);
    // Sempre com centavos: o número não muda de formato ao terminar de contar.
    String contando(double v) => convertToMoney(carteiras, v, allDecimals: true);
    final restante = limite - gasto;
    final passou = restante < 0;
    final entrou = renda ? 'Guardado' : 'Gasto';
    final falta = renda
        ? (passou ? 'Acima da meta' : 'Falta guardar')
        : (passou ? 'Acima do limite' : 'Resta');
    // Estouro de gasto em vermelho; poupança acima da meta em verde.
    final cor = passou
        ? (renda ? e.pos : getColor(context, "overspentAmount"))
        : null;
    final base = EdTexto.numeroGrande(context);
    final estilo = (grande
            ? base
            : base.copyWith(fontSize: 28, letterSpacing: -.84))
        .copyWith(color: mostrarGasto ? null : cor);
    final rotulo = EdTexto.rotulo(context);
    final dias = diasRestantes;
    final fracaoHoje = limite > 0 ? hoje : null;
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
        Text(mostrarGasto ? entrou : falta, style: rotulo),
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
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                mostrarGasto
                    ? '${passou ? (renda ? 'Acima' : 'Passou') : 'Resta'} '
                        '${dinheiro(restante.abs())} de ${dinheiro(limite)}'
                    : '$entrou ${dinheiro(gasto)} de ${dinheiro(limite)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: rotulo,
              ),
            ),
            if (dias != null) ...[
              const SizedBox(width: 8),
              Text(dias <= 1 ? 'último dia' : 'faltam $dias dias',
                  style: rotulo),
            ],
          ],
        ),
        if (fracaoHoje != null) ...[
          const SizedBox(height: 4),
          Text(textoIdealHoje(gasto, limite, fracaoHoje, dinheiro, renda: renda),
              maxLines: 2, style: rotulo),
        ],
        if (grande && dias != null && restante > 0) ...[
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

/// Cartão da lista de orçamentos: nome e período, depois o resumo.
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
    this.onTap,
    this.onLongPress,
  });

  final String nome, periodo;
  final Color cor;
  final double gasto, limite, aVencer;
  final double? hoje;
  final bool renda;
  final int? diasRestantes;
  final VoidCallback? onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final cartao = Container(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: e.surf,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: e.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // A cor do orçamento vira um ponto ao lado do nome.
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsetsDirectional.only(end: 8),
                decoration: BoxDecoration(shape: BoxShape.circle, color: cor),
              ),
              Expanded(
                child: Text(nome,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context)
                        .copyWith(fontSize: 15, fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 8),
              Text(periodo, style: EdTexto.rotulo(context)),
            ],
          ),
          const SizedBox(height: 12),
          ResumoOrcamento(
            gasto: gasto,
            limite: limite,
            renda: renda,
            diasRestantes: diasRestantes,
            aVencer: aVencer,
            hoje: hoje,
            mostrarGasto: appStateSettings["showTotalSpentForBudget"] == true,
          ),
        ],
      ),
    );
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
  });

  final Budget budget;
  final bool longPressToEdit;

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
        if (gasto == null) return const SizedBox(height: 164);
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
