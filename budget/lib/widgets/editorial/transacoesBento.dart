import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/pendenciasPage.dart';
import 'package:budget/pages/transactionFilters.dart';
import 'package:budget/pages/walletDetailsPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/classificarDados.dart'
    show meuBancoClassificar;
import 'package:budget/struct/mbSync/rachadas.dart';
import 'package:budget/struct/mbSync/revisao.dart' show meuBancoRevisar;
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Filtro rápido acima da lista; soma-se ao filtro completo da tela.
enum FiltroRapido { tudo, gastos, entradas, validar }

/// Transações na fila "Para validar" (a mesma do selo e das Pendências).
Set<String> pksParaValidar() => {
      for (final i in meuBancoRevisar.value)
        if (i.txId != null) 'mb:${i.txId}',
      for (final l in meuBancoClassificar.value)
        if (l.revisao == null) l.pk,
    };

final Listenable filaParaValidar =
    Listenable.merge([meuBancoRevisar, meuBancoClassificar]);

/// Topo da tela de Transações em cartões: gasto do mês por categoria,
/// entradas, fila para validar e os filtros rápidos.
class ResumoMesBento extends StatelessWidget {
  const ResumoMesBento({
    super.key,
    required this.inicio,
    required this.fim,
    required this.searchFilters,
    required this.filtro,
    required this.onFiltro,
    this.mostrarResumo = true,
    this.onLongPress,
  });

  final DateTime inicio, fim;
  final SearchFilters searchFilters;
  final FiltroRapido filtro;
  final ValueChanged<FiltroRapido> onFiltro;
  final bool mostrarResumo;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([meuBancoRachadas, filaParaValidar]),
        builder: (context, _) => StreamBuilder<List<TransactionWithCategory>>(
          stream: database.getTransactionCategoryWithDay(
            inicio,
            fim,
            budgetTransactionFilters: null,
            memberTransactionFilters: null,
            searchFilters: searchFilters,
          ),
          builder: (context, snapshot) {
            final rachadas = meuBancoRachadas.value;
            final dados = [
              for (final t in snapshot.data ?? <TransactionWithCategory>[])
                if (!rachadas.ocultos.contains(t.transaction.transactionPk)) t
            ];
            // Mês vazio: sobram só os filtros, e só se houver um para desfazer.
            if (dados.isEmpty && filtro == FiltroRapido.tudo)
              return const SizedBox.shrink();
            final carteiras = Provider.of<AllWallets>(context);
            final e = cores(context);
            final porCategoria = <String, FatiaGasto>{};
            double entradas = 0;
            for (final t in dados) {
              final tx = t.transaction;
              if (!tx.paid || tx.categoryFk == "0") continue;
              final v = rachadas.valorNaLista(tx) *
                  amountRatioToPrimaryCurrencyGivenPk(carteiras, tx.walletFk);
              if (v > 0) {
                entradas += v;
              } else if (v < 0) {
                porCategoria[tx.categoryFk] = (
                  nome: t.category.name,
                  cor: HexColor(t.category.colour, defaultColor: e.acc),
                  v: (porCategoria[tx.categoryFk]?.v ?? 0) - v
                );
              }
            }
            final validar = pksParaValidar();
            return ResumoMesCartoes(
              mes: getMonth(inicio).toLowerCase(),
              transacoes: dados.length,
              categorias: porCategoria.values.toList()
                ..sort((a, b) => b.v.compareTo(a.v)),
              entradas: entradas,
              paraValidar: dados
                  .where((t) => validar.contains(t.transaction.transactionPk))
                  .length,
              brl: (v) => convertToMoney(carteiras, v, allDecimals: true),
              filtro: filtro,
              onFiltro: onFiltro,
              mostrarResumo: mostrarResumo && dados.isNotEmpty,
              onLongPress: onLongPress,
              onAbrirPeriodo: () => pushRoute(
                  context,
                  WalletDetailsPage(
                    wallet: null,
                    initialSearchFilters: SearchFilters(
                        dateTimeRange: DateTimeRange(start: inicio, end: fim)),
                  )),
              onAbrirValidar: () => pushRoute(context, const PendenciasPage()),
            );
          },
        ),
      );
}

/// Gasto de uma categoria no mês.
typedef FatiaGasto = ({String nome, Color cor, double v});

/// Os cartões e os filtros rápidos de [ResumoMesBento], já com os números.
class ResumoMesCartoes extends StatelessWidget {
  const ResumoMesCartoes({
    super.key,
    required this.mes,
    required this.transacoes,
    required this.categorias,
    required this.entradas,
    required this.paraValidar,
    required this.brl,
    required this.filtro,
    required this.onFiltro,
    this.mostrarResumo = true,
    this.onLongPress,
    this.onAbrirPeriodo,
    this.onAbrirValidar,
  });

  final String mes;
  final int transacoes, paraValidar;

  /// Da maior para a menor.
  final List<FatiaGasto> categorias;
  final double entradas;
  final String Function(double) brl;
  final FiltroRapido filtro;
  final ValueChanged<FiltroRapido> onFiltro;
  final bool mostrarResumo;
  final VoidCallback? onLongPress, onAbrirPeriodo, onAbrirValidar;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final entradasCartao = _Mini(
      rotulo: 'Entradas',
      valor: brl(entradas),
      corValor: e.pos,
      onTap: () => onFiltro(FiltroRapido.entradas),
    );
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (mostrarResumo) ...[
            GestureDetector(
              onLongPress: onLongPress,
              child: ToqueEscala(
                onTap: onAbrirPeriodo,
                child: _Gasto(
                  mes: mes,
                  n: transacoes,
                  categorias: categorias,
                  brl: brl,
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (paraValidar == 0)
              entradasCartao
            else
              GradeBento(filhos: [
                entradasCartao,
                _Mini(
                  rotulo: 'Para validar',
                  valor: paraValidar == 1
                      ? '1 transação'
                      : '$paraValidar transações',
                  cor: e.warnbg,
                  corValor: e.warntx,
                  onTap: onAbrirValidar,
                ),
              ]),
            const SizedBox(height: 12),
          ],
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (f, rotulo) in [
                (FiltroRapido.tudo, 'Tudo'),
                (FiltroRapido.gastos, 'Gastos'),
                (FiltroRapido.entradas, 'Entradas'),
                if (paraValidar > 0 || filtro == FiltroRapido.validar)
                  (FiltroRapido.validar, '$paraValidar para validar'),
              ])
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: _Chip(
                    rotulo: rotulo,
                    ativo: f == filtro,
                    onTap: () => onFiltro(f),
                  ),
                ),
            ]),
          ),
        ],
      ),
    );
  }
}

/// As transações de um dia num cartão só.
class CartaoDoDia extends StatelessWidget {
  const CartaoDoDia({super.key, required this.filhos});
  final List<Widget> filhos;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 6),
        child: CartaoBento(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: filhos),
        ),
      );
}

class _Gasto extends StatelessWidget {
  const _Gasto({
    required this.mes,
    required this.n,
    required this.categorias,
    required this.brl,
  });

  final String mes;
  final int n;
  final List<FatiaGasto> categorias;
  final String Function(double) brl;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final total = categorias.fold<double>(0, (s, f) => s + f.v);
    // Quatro maiores categorias; o resto vira "Outros".
    final fatias = [
      ...categorias.take(4),
      if (categorias.length > 4)
        (
          nome: 'Outros',
          cor: e.mu,
          v: categorias.skip(4).fold<double>(0, (s, f) => s + f.v)
        ),
    ];
    return CartaoBento(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text('Gasto em $mes', style: EdTexto.rotulo(context))),
            Text(n == 1 ? '1 transação' : '$n transações',
                style: EdTexto.rotulo(context)),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: ContagemValor(
              valor: total,
              formatar: brl,
              estilo: EdTexto.numeroGrande(context),
            ),
          ),
          if (fatias.isNotEmpty) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  for (final (i, f) in fatias.indexed) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Expanded(
                      flex: (f.v / total * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: f.cor),
                    ),
                  ],
                ]),
              ),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < fatias.length; i += 2)
              Padding(
                padding: EdgeInsets.only(top: i > 0 ? 6 : 0),
                child: Row(children: [
                  for (final f in fatias.skip(i).take(2))
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(end: 10),
                        child: Row(children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: f.cor, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(f.nome,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: EdTexto.corpo(context)
                                    .copyWith(fontSize: 13)),
                          ),
                          const SizedBox(width: 6),
                          Text(brl(f.v),
                              style: EdTexto.corpo(context).copyWith(
                                  fontSize: 13,
                                  color: e.mu,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ])),
                        ]),
                      ),
                    ),
                  if (i + 1 >= fatias.length) const Spacer(),
                ]),
              ),
          ],
        ],
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({
    required this.rotulo,
    required this.valor,
    required this.corValor,
    required this.onTap,
    this.cor,
  });

  final String rotulo, valor;
  final Color corValor;
  final Color? cor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ToqueEscala(
        onTap: onTap,
        child: CartaoBento(
          cor: cor,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rotulo,
                  style: EdTexto.rotulo(context)
                      .copyWith(color: cor == null ? null : corValor)),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(valor,
                    style: EdTexto.corpo(context).copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: corValor)),
              ),
            ],
          ),
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.rotulo, required this.ativo, required this.onTap});

  final String rotulo;
  final bool ativo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Semantics(
      button: true,
      selected: ativo,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: ativo ? e.tx : corCartaoBento(context),
                borderRadius: BorderRadius.circular(100),
              ),
              child: Text(rotulo,
                  style: EdTexto.corpo(context).copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ativo ? e.bg : e.tx)),
            ),
          ),
        ),
      ),
    );
  }
}
