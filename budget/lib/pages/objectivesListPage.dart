import 'package:budget/pages/investimentosEvolucaoPage.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addObjectivePage.dart';
import 'package:budget/pages/editObjectivesPage.dart';
import 'package:budget/pages/objectivePage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/categoryIcon.dart';
import 'package:budget/widgets/navigationSidebar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart'
    hide SliverReorderableList, ReorderableDelayedDragStartListener;
import 'package:provider/provider.dart';
import 'addButton.dart';

// This defines what a difference only loan can be
bool getIsDifferenceOnlyLoan(Objective objective) {
  return objective.amount == -1 &&
      objective.type == ObjectiveType.loan &&
      appStateSettings["longTermLoansDifferenceFeature"] == true;
}

// negative to collect / you are owed
// positive to pay back / you owe
double getDifferenceOfLoan(
    Objective objective, double totalAmount, double objectiveAmount) {
  return objective.income
      ? totalAmount - objectiveAmount
      : objectiveAmount - totalAmount;
}

class ObjectivesListPage extends StatefulWidget {
  const ObjectivesListPage({required this.backButton, Key? key})
      : super(key: key);
  final bool backButton;

  @override
  State<ObjectivesListPage> createState() => ObjectivesListPageState();
}

class ObjectivesListPageState extends State<ObjectivesListPage> {
  GlobalKey<PageFrameworkState> pageState = GlobalKey();

  void scrollToTop() {
    pageState.currentState?.scrollToTop();
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      key: pageState,
      dragDownToDismiss: true,
      title: "goals".tr(),
      backButton: widget.backButton,
      horizontalPaddingConstrained: enableDoubleColumn(context) == false,
      actions: [
        IconButton(
          padding: EdgeInsetsDirectional.all(15),
          tooltip: "Evolução dos investimentos",
          onPressed: () => pushRoute(context, const InvestimentosEvolucaoPage()),
          icon: Icon(
            Icons.show_chart_rounded,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
        IconButton(
          padding: EdgeInsetsDirectional.all(15),
          tooltip: "edit-goals".tr(),
          onPressed: () {
            pushRoute(
              context,
              EditObjectivesPage(objectiveType: ObjectiveType.goal),
            );
          },
          icon: Icon(
            appStateSettings["outlinedIcons"]
                ? Icons.edit_outlined
                : Icons.edit_rounded,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
        if (getIsFullScreen(context))
          IconButton(
            padding: EdgeInsetsDirectional.all(15),
            tooltip: "add-goal".tr(),
            onPressed: () {
              pushRoute(
                context,
                AddObjectivePage(
                    routesToPopAfterDelete: RoutesToPopAfterDelete.None),
              );
            },
            icon: Icon(
              appStateSettings["outlinedIcons"]
                  ? Icons.add_outlined
                  : Icons.add_rounded,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
      ],
      slivers: [
        ObjectiveList(
            showExamplesIfEmpty: true, objectiveType: ObjectiveType.goal),
        // O "+" da barra fica sobre o fim da lista.
        SliverToBoxAdapter(
          child: SizedBox(height: mbFolgaFab),
        ),
      ],
    );
  }
}

class ObjectiveList extends StatefulWidget {
  const ObjectiveList({
    required this.showExamplesIfEmpty,
    required this.objectiveType,
    this.showAddButton = true,
    this.searchFor,
    this.isIncome,
    super.key,
  });

  /// Lista vazia mostra o estado vazio com uma ação (antes: metas de exemplo).
  final bool showExamplesIfEmpty;
  final ObjectiveType objectiveType;
  final bool showAddButton;
  final String? searchFor;
  final bool? isIncome;

  @override
  State<ObjectiveList> createState() => _ObjectiveListState();
}

class _ObjectiveListState extends State<ObjectiveList> {
  // Entrada só ao abrir: itens que voltam à tela ao rolar aparecem direto.
  final DateTime _aberta = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final emprestimo = widget.objectiveType == ObjectiveType.loan;
    final novaPagina = AddObjectivePage(
      routesToPopAfterDelete: RoutesToPopAfterDelete.PreventDelete,
      objectiveType: widget.objectiveType,
      selectedIncome: widget.isIncome,
    );
    final Widget adicionar = widget.showAddButton
        ? AddButton(
            onTap: () {},
            openPage: novaPagina,
            width: null,
            height: 150,
            labelUnder: emprestimo ? "add-loan".tr() : "add-goal".tr(),
          )
        : const SizedBox.shrink();
    return StreamBuilder<List<Objective>>(
      stream: database.watchAllObjectives(
        objectiveType: widget.objectiveType,
        searchFor: widget.searchFor,
        isIncome: widget.isIncome,
        hideArchived: true,
        showDifferenceLoans: false,
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SliverToBoxAdapter();
        final objetivos = snapshot.data!;
        if (objetivos.isEmpty && widget.showExamplesIfEmpty) {
          return SliverToBoxAdapter(
            child: VazioMetas(
              emprestimo: emprestimo,
              onCriar: () => pushRoute(context, novaPagina),
            ),
          );
        }
        final animar = DateTime.now().difference(_aberta) <
            const Duration(milliseconds: 600);
        Widget item(int i) => i == objetivos.length
            ? adicionar
            : EntradaSuave(
                key: ValueKey(objetivos[i].objectivePk),
                indice: i,
                animar: animar,
                child: ObjectiveContainer(
                  index: i,
                  objective: objetivos[i],
                  isGridView: enableDoubleColumn(context),
                ),
              );
        return SliverPadding(
          padding: const EdgeInsetsDirectional.symmetric(
              vertical: 7, horizontal: 13),
          sliver: enableDoubleColumn(context)
              ? SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 500.0,
                    mainAxisExtent: 172,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => item(i),
                    childCount: objetivos.length + 1,
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => Padding(
                      padding: const EdgeInsetsDirectional.only(bottom: 12),
                      child: item(i),
                    ),
                    childCount: objetivos.length + 1,
                  ),
                ),
        );
      },
    );
  }
}

/// Vazio curto: ícone, uma frase e uma ação.
class VazioMetas extends StatelessWidget {
  const VazioMetas(
      {super.key, required this.emprestimo, required this.onCriar});
  final bool emprestimo;
  final VoidCallback onCriar;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(30, 48, 30, 0),
      child: Column(
        children: [
          Icon(
            emprestimo ? Icons.handshake_outlined : Icons.savings_outlined,
            size: 32,
            color: e.mu,
          ),
          const SizedBox(height: 12),
          Text(
            emprestimo ? 'Nenhum empréstimo ainda' : 'Nenhuma meta ainda',
            textAlign: TextAlign.center,
            style: EdTexto.corpo(context).copyWith(color: e.mu),
          ),
          const SizedBox(height: 16),
          Button(
            label: emprestimo ? 'Adicionar empréstimo' : 'Criar meta',
            onTap: onCriar,
          ),
        ],
      ),
    );
  }
}

class ObjectiveListDifferenceLoan extends StatelessWidget {
  const ObjectiveListDifferenceLoan({
    this.searchFor,
    super.key,
  });
  final String? searchFor;
  @override
  Widget build(BuildContext context) {
    if (appStateSettings["longTermLoansDifferenceFeature"] == false)
      return SliverToBoxAdapter(
        child: SizedBox.shrink(),
      );
    return StreamBuilder<List<Objective>>(
      stream: database.watchAllObjectives(
        objectiveType: ObjectiveType.loan,
        searchFor: searchFor,
        isIncome: null,
        hideArchived: true,
        showDifferenceLoans: true,
      ),
      builder: (context, snapshot) {
        List<Objective> objectivesList = snapshot.data ?? [];
        if (objectivesList.length <= 0)
          return SliverToBoxAdapter(
            child: SizedBox.shrink(),
          );
        return SliverPadding(
          padding: const EdgeInsetsDirectional.symmetric(
              vertical: 7, horizontal: 13),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) {
                Objective objective = objectivesList[index];
                return Padding(
                  padding: EdgeInsetsDirectional.only(
                    bottom: index == objectivesList.length - 1 ? 0 : 8,
                  ),
                  child: ObjectiveContainerDifferenceLoan(
                    index: index,
                    objective: objective,
                  ),
                );
              },
              childCount: objectivesList.length,
            ),
          ),
        );
      },
    );
  }
}

class ObjectiveContainer extends StatelessWidget {
  const ObjectiveContainer({
    required this.objective,
    required this.index,
    this.isGridView,
    super.key,
  });
  final Objective objective;
  final int index;
  final bool? isGridView;

  @override
  Widget build(BuildContext context) {
    void editar() => pushRoute(
          context,
          AddObjectivePage(
            routesToPopAfterDelete: RoutesToPopAfterDelete.One,
            objective: objective,
          ),
        );
    return StreamBuilder<int?>(
      stream: database
          .getTotalCountOfTransactionsInObjective(objective.objectivePk)
          .$1,
      builder: (context, contagem) => WatchTotalAndAmountOfObjective(
        objective: objective,
        builder: (alvo, total, fracao) => CartaoMeta(
          objective: objective,
          alvo: alvo,
          total: total,
          fracao: fracao,
          transacoes: contagem.data,
          preencher: isGridView == true,
          onTap: () => pushRoute(
              context, ObjectivePage(objectivePk: objective.objectivePk)),
          onLongPress: editar,
          onDefinirValor: editar,
        ),
      ),
    );
  }
}

/// Rótulo e valor em destaque de uma meta ou empréstimo. Com [mostrarTotal]
/// (opção "total gasto" das metas) mostra o acumulado; senão, o que falta.
({String rotulo, double valor}) destaqueMeta(
  Objective objective, {
  required double alvo,
  required double total,
  required bool mostrarTotal,
}) {
  final emprestimo = objective.type == ObjectiveType.loan;
  final receita = objective.income;
  // Empréstimo sem valor nem transações: pede o valor em vez de "Recebido R$ 0".
  if (emprestimo && alvo <= 0 && total <= 0) {
    return (
      rotulo: receita ? 'Valor emprestado' : 'Valor pego emprestado',
      valor: 0,
    );
  }
  if (!mostrarTotal && total < alvo) {
    return (
      rotulo: emprestimo
          ? (receita ? 'A receber' : 'A pagar')
          : (receita ? 'Falta guardar' : 'Falta pagar'),
      valor: alvo - total,
    );
  }
  final concluida = alvo > 0 && total >= alvo;
  // Quitado fica na mesma coluna dos outros (o saldo), não no valor recebido.
  if (emprestimo && concluida && !mostrarTotal) {
    return (
      rotulo: receita ? 'Quitado · nada a receber' : 'Quitado · nada a pagar',
      valor: 0,
    );
  }
  return (
    rotulo: concluida
        ? (emprestimo ? 'Quitado' : 'Meta alcançada')
        : emprestimo
            ? (receita ? 'Recebido' : 'Pago')
            : (receita ? 'Guardado' : 'Pago'),
    valor: total,
  );
}

/// "de R$ 1.500,00 · 33%" (empréstimo: "Emprestado R$ 1.500,00 · 33% recebido").
String detalheMeta(BuildContext context, Objective objective,
    {required double alvo, required double fracao}) {
  final valor = convertToMoney(Provider.of<AllWallets>(context), alvo);
  final pct = '${(fracao * 100).clamp(0, 999).round()}%';
  if (objective.type != ObjectiveType.loan) return 'de $valor · $pct';
  return objective.income
      ? 'Emprestado $valor · $pct recebido'
      : 'Pego emprestado $valor · $pct pago';
}

String textoTransacoes(int n) => n == 1 ? '1 transação' : '$n transações';

/// Ícone de quem ainda não escolheu um (ex.: Reserva criada pelo Meu Banco): o quadrado nunca fica vazio.
String iconeMetaPadrao(ObjectiveType tipo) =>
    tipo == ObjectiveType.goal ? 'piggy-bank.png' : 'image.png';

Widget iconeMeta(Objective objective,
        {double size = 18, double sizePadding = 14, VoidCallback? onTap}) =>
    CategoryIcon(
      categoryPk: "-1",
      category: TransactionCategory(
        categoryPk: "-1",
        name: "",
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: 0,
        income: false,
        iconName: objective.iconName ??
            (objective.emojiIconName == null
                ? iconeMetaPadrao(objective.type)
                : null),
        colour: objective.colour,
        emojiIconName: objective.emojiIconName,
      ),
      size: size,
      sizePadding: sizePadding,
      borderRadius: 12,
      canEditByLongPress: false,
      margin: EdgeInsetsDirectional.zero,
      onTap: onTap,
    );

BoxDecoration cartaoPlano(EditorialCores e) => BoxDecoration(
      color: e.surf,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: e.line),
    );

/// Cartão de meta/empréstimo sem acesso ao banco: valor em destaque, medidor
/// e uma linha secundária. Tocar abre a meta; segurar edita.
class CartaoMeta extends StatelessWidget {
  const CartaoMeta({
    super.key,
    required this.objective,
    required this.alvo,
    required this.total,
    required this.fracao,
    this.transacoes,
    this.mostrarTotal,
    this.preencher = false,
    this.onTap,
    this.onLongPress,
    this.onDefinirValor,
  });
  final Objective objective;
  final double alvo, total, fracao;
  final int? transacoes;

  /// Nulo: segue appStateSettings["showTotalSpentForObjective"].
  final bool? mostrarTotal;

  /// Grade do computador: ocupa a altura da célula.
  final bool preencher;
  final VoidCallback? onTap, onLongPress, onDefinirValor;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    String dinheiro(double v) =>
        convertToMoney(Provider.of<AllWallets>(context), v);
    // Meta sem valor, ou empréstimo ainda vazio: mostra "Definir valor".
    final semAlvo = alvo <= 0 &&
        (objective.type == ObjectiveType.goal || total <= 0);
    final d = destaqueMeta(objective,
        alvo: alvo,
        total: total,
        mostrarTotal: semAlvo ||
            (mostrarTotal ??
                appStateSettings["showTotalSpentForObjective"] == true));
    final concluida = !semAlvo && total >= alvo;
    final status = objective.endDate == null || semAlvo
        ? ''
        : getObjectiveStatus(context, objective, total, fracao, alvo);
    final valor = ContagemValor(
      valor: d.valor,
      formatar: (v) => convertToMoney(
          Provider.of<AllWallets>(context), v,
          allDecimals: true),
      centavosMenores: true,
      estilo: EdTexto.numeroGrande(context).copyWith(
          fontSize: 26,
          letterSpacing: -.78,
          color: concluida && objective.type == ObjectiveType.goal
              ? e.pos
              : null),
    );
    final cartao = Container(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 14),
      decoration: cartaoPlano(e),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: preencher
            ? MainAxisAlignment.spaceBetween
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            iconeMeta(objective),
            const SizedBox(width: 10),
            Expanded(
              child: Text(objective.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.corpo(context)
                      .copyWith(fontSize: 15, fontWeight: FontWeight.w500)),
            ),
            if (transacoes != null) ...[
              const SizedBox(width: 8),
              Text(textoTransacoes(transacoes!),
                  style: EdTexto.rotulo(context)),
            ],
          ]),
          const SizedBox(height: 12),
          Text(d.rotulo, style: EdTexto.rotulo(context)),
          const SizedBox(height: 4),
          if (semAlvo)
            Row(children: [
              Flexible(child: valor),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onDefinirValor,
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(44, 44),
                    foregroundColor: e.acc),
                child: const Text('Definir valor'),
              ),
            ])
          else ...[
            valor,
            const SizedBox(height: 12),
            MedidorEditorial(fracao: fracao),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Text(
                    detalheMeta(context, objective, alvo: alvo, fracao: fracao),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.rotulo(context)),
              ),
              if (status != '') ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: EdTexto.rotulo(context)),
                ),
              ],
            ]),
          ],
        ],
      ),
    );
    return Semantics(
      button: true,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ToqueEscala(onTap: onTap, child: cartao),
      ),
    );
  }
}

/// Empréstimo por diferença: linha plana com o saldo à direita.
class ObjectiveContainerDifferenceLoan extends StatelessWidget {
  const ObjectiveContainerDifferenceLoan({
    required this.objective,
    required this.index,
    super.key,
  });
  final Objective objective;
  final int index;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int?>(
      stream: database
          .getTotalCountOfTransactionsInObjective(objective.objectivePk)
          .$1,
      builder: (context, contagem) => WatchTotalAndAmountOfObjective(
        objective: objective,
        builder: (alvo, total, fracao) => LinhaEmprestimoDiferenca(
          objective: objective,
          diferenca: getDifferenceOfLoan(objective, total, alvo),
          quitado: fracao == 1,
          transacoes: contagem.data,
          onTap: () => pushRoute(
              context, ObjectivePage(objectivePk: objective.objectivePk)),
          onLongPress: () => pushRoute(
            context,
            AddObjectivePage(
              routesToPopAfterDelete: RoutesToPopAfterDelete.One,
              objective: objective,
            ),
          ),
        ),
      ),
    );
  }
}

/// Positivo: você deve; negativo: devem a você.
String rotuloDiferenca(double diferenca, bool quitado) => quitado
    ? 'Quitado'
    : diferenca > 0
        ? 'A pagar'
        : 'A receber';

class LinhaEmprestimoDiferenca extends StatelessWidget {
  const LinhaEmprestimoDiferenca({
    super.key,
    required this.objective,
    required this.diferenca,
    required this.quitado,
    this.transacoes,
    this.onTap,
    this.onLongPress,
  });
  final Objective objective;

  /// getDifferenceOfLoan: positivo = a pagar, negativo = a receber.
  final double diferenca;
  final bool quitado;
  final int? transacoes;
  final VoidCallback? onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final linha = Container(
      constraints: const BoxConstraints(minHeight: 60),
      padding:
          const EdgeInsetsDirectional.symmetric(horizontal: 14, vertical: 10),
      decoration: cartaoPlano(cores(context)),
      child: Row(children: [
        iconeMeta(objective),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(objective.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.corpo(context)
                      .copyWith(fontSize: 15, fontWeight: FontWeight.w500)),
              if (transacoes != null)
                Text(textoTransacoes(transacoes!),
                    style: EdTexto.rotulo(context)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                convertToMoney(
                    Provider.of<AllWallets>(context), diferenca.abs()),
                style: EdTexto.corpo(context)
                    .copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(rotuloDiferenca(diferenca, quitado),
                style: EdTexto.rotulo(context)),
          ],
        ),
      ]),
    );
    return Semantics(
      button: true,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ToqueEscala(onTap: onTap, child: linha),
      ),
    );
  }
}

String getObjectiveStatus(BuildContext context, Objective objective,
    double totalAmount, double percentageTowardsGoal, double objectiveAmount,
    {bool addSpendingSavingIndication = false}) {
  String content;
  if (objective.endDate == null) return "";
  int remainingDays =
      objective.endDate!.difference(DateTime.now().justDay()).inDays + 1;
  double amount = ((totalAmount - objectiveAmount) / remainingDays) * -1;
  if (percentageTowardsGoal >= 1) {
    content = objective.type == ObjectiveType.loan
        ? "loan-accomplished".tr()
        : "goal-reached".tr();
  } else if (remainingDays <= 0) {
    content = objective.type == ObjectiveType.loan
        ? "loan-overdue".tr()
        : "goal-overdue".tr();
  } else {
    content = (addSpendingSavingIndication
            ? (objective.income
                ? (objective.type == ObjectiveType.loan
                        ? "collect".tr()
                        : "save".tr()) +
                    " "
                : (objective.type == ObjectiveType.loan
                        ? "pay".tr()
                        : "spend".tr()) +
                    " ")
            : "") +
        convertToMoney(Provider.of<AllWallets>(context), amount.abs()) +
        "/" +
        "day".tr() +
        " " +
        "for".tr() +
        " " +
        remainingDays.toString() +
        " " +
        (remainingDays == 1 ? "day".tr() : "days".tr());
  }
  return content;
}

String getObjectiveAmountSpentLabel({
  required BuildContext context,
  required Objective objective,
  required bool showTotalSpent,
  required double objectiveAmount,
  required double totalAmount,
}) {
  double amountSpent =
      showTotalSpent ? totalAmount : (objectiveAmount - totalAmount);
  if (getIsDifferenceOnlyLoan(objective)) {
    amountSpent =
        getDifferenceOfLoan(objective, totalAmount, objectiveAmount).abs();
  } else if (showTotalSpent == false && totalAmount > objectiveAmount) {
    amountSpent = amountSpent.abs();
  }
  String amountSpentLabel = convertToMoney(
    Provider.of<AllWallets>(context),
    amountSpent,
  );
  return amountSpentLabel;
}

class WatchTotalAndAmountOfObjective extends StatelessWidget {
  const WatchTotalAndAmountOfObjective(
      {required this.objective, required this.builder, super.key});
  final Objective objective;
  final Widget Function(double objectiveAmount, double totalAmount,
      double percentageTowardsGoal) builder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double?>(
      stream: database.watchTotalTowardsObjective(
          Provider.of<AllWallets>(context), objective),
      builder: (context, snapshot) {
        if (objective.type == ObjectiveType.loan) {
          return StreamBuilder<double?>(
            stream: database.watchTotalAmountObjectiveLoan(
                Provider.of<AllWallets>(context, listen: true), objective),
            builder: (context, snapshotAmount) {
              double objectiveAmount = (snapshotAmount.data ?? 0);
              if (getIsDifferenceOnlyLoan(objective) == false) {
                double objectiveAmountConverted = objective.amount *
                    amountRatioToPrimaryCurrency(
                      Provider.of<AllWallets>(context),
                      Provider.of<AllWallets>(context)
                          .indexedByPk[objective.walletFk]
                          ?.currency,
                    );
                objectiveAmount = objectiveAmount +
                    (objectiveAmountConverted * (objective.income ? -1 : 1));
              }
              double totalAmount =
                  ((snapshot.data ?? 0) - (snapshotAmount.data ?? 0)) * -1;
              double percentageTowardsGoal =
                  objectiveAmount == 0 ? 0 : totalAmount / objectiveAmount;
              percentageTowardsGoal = absoluteZero(percentageTowardsGoal);
              if (getIsDifferenceOnlyLoan(objective)) {
                int numberDecimals = Provider.of<AllWallets>(context)
                        .indexedByPk[appStateSettings["selectedWalletPk"]]
                        ?.decimals ??
                    2;
                if ((double.tryParse(getDifferenceOfLoan(
                                objective, totalAmount, objectiveAmount)
                            .abs()
                            .toStringAsFixed(numberDecimals)) ==
                        0) &&
                    snapshot.hasData &&
                    snapshotAmount.hasData)
                  percentageTowardsGoal = 1;
                else
                  percentageTowardsGoal = 0;
              }
              return builder(
                  objectiveAmount * (objective.income ? -1 : 1),
                  totalAmount * (objective.income ? -1 : 1),
                  percentageTowardsGoal);
            },
          );
        } else {
          double objectiveAmount = objectiveAmountToPrimaryCurrency(
              Provider.of<AllWallets>(context, listen: true), objective);
          double totalAmount = snapshot.data ?? 0;
          if (objective.income == false) totalAmount = totalAmount * -1;
          double percentageTowardsGoal =
              objectiveAmount == 0 ? 0 : totalAmount / objectiveAmount;
          percentageTowardsGoal = absoluteZero(percentageTowardsGoal);
          return builder(objectiveAmount, totalAmount, percentageTowardsGoal);
        }
      },
    );
  }
}
