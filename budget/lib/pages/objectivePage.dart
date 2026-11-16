import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addObjectivePage.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/objectivesListPage.dart';
import 'package:budget/pages/transactionFilters.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/dropdownSelect.dart';
import 'package:budget/widgets/extraInfoBoxes.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/selectCategoryImage.dart';
import 'package:budget/widgets/selectedTransactionsAppBar.dart';
import 'package:budget/widgets/fab.dart';
import 'package:budget/widgets/fadeIn.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/navigationSidebar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/transactionEntries.dart';
import 'package:budget/widgets/transactionEntry/transactionEntry.dart';
import 'package:drift/drift.dart' show Value;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:budget/colors.dart';
import 'package:provider/provider.dart';
import 'package:confetti/confetti.dart';

class ObjectivePage extends StatelessWidget {
  const ObjectivePage({
    super.key,
    required this.objectivePk,
  });
  final String objectivePk;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Objective>(
        stream: database.getObjective(objectivePk),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            Color? accentColor = HexColor(snapshot.data?.colour);
            return CustomColorTheme(
              accentColor: snapshot.data?.colour == null ? null : accentColor,
              child: _ObjectivePageContent(
                objective: snapshot.data!,
              ),
            );
          }
          return SizedBox.shrink();
        });
  }
}

class _ObjectivePageContent extends StatefulWidget {
  const _ObjectivePageContent({
    Key? key,
    required this.objective,
  }) : super(key: key);

  final Objective objective;

  @override
  State<_ObjectivePageContent> createState() => _ObjectivePageContentState();
}

class _ObjectivePageContentState extends State<_ObjectivePageContent> {
  final ConfettiController confettiController = ConfettiController();
  bool hasPlayedConfetti = false;

  bool showTotalSpent = appStateSettings["showTotalSpentForObjective"];

  _swapTotalSpentDisplay() {
    setState(() {
      showTotalSpent = !showTotalSpent;
    });
    updateSettings(
      "showTotalSpentForObjective",
      showTotalSpent,
      updateGlobalState: true,
    );
  }

  @override
  void initState() {
    confettiController.addListener(confettiListener);
    super.initState();
  }

  @override
  void dispose() {
    confettiController.dispose();
    super.dispose();
  }

  confettiListener() {
    if (mounted &&
        confettiController.state == ConfettiControllerState.playing) {
      Future.delayed(Duration(milliseconds: 2000), () {
        if (mounted) confettiController.stop();
      });
    }
  }

  openSelectIconPopup() {
    openBottomSheet(
      context,
      PopupFramework(
        title: "select-icon".tr(),
        child: SelectCategoryImage(
          setSelectedImage: (String? selection) async {
            String? selectedIcon =
                (selection ?? "").replaceFirst("assets/categories/", "");
            Objective newObjective = widget.objective.copyWith(
              iconName: Value(selectedIcon),
              emojiIconName: Value(null),
            );
            await database.createOrUpdateObjective(
              newObjective,
            );
          },
          setSelectedEmoji: (String? selection) async {
            Objective newObjective = widget.objective.copyWith(
              iconName: Value(null),
              emojiIconName: Value(selection),
            );
            await database.createOrUpdateObjective(
              newObjective,
            );
            print(newObjective);
          },
          selectedImage:
              "assets/categories/" + widget.objective.iconName.toString(),
          setSelectedTitle: (String? titleRecommendation) {},
        ),
      ),
      showScrollbar: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    Color? pageBackgroundColor =
        Theme.of(context).brightness == Brightness.dark &&
                appStateSettings["forceFullDarkBackground"]
            ? Colors.black
            : appStateSettings["materialYou"]
                ? dynamicPastel(context, Theme.of(context).colorScheme.primary,
                    amount: 0.92)
                : null;
    String pageId = widget.objective.objectivePk;
    return WillPopScope(
      onWillPop: () async {
        if ((globalSelectedID.value[pageId] ?? []).length > 0) {
          globalSelectedID.value[pageId] = [];
          globalSelectedID.notifyListeners();
          return false;
        } else {
          return true;
        }
      },
      child: Stack(
        children: [
          PageFramework(
            belowAppBarPaddingWhenCenteredTitleSmall: 0,
            subtitleAlignment: AlignmentDirectional.bottomStart,
            backgroundColor: pageBackgroundColor,
            listID: pageId,
            floatingActionButton: AnimateFABDelayed(
              fab: AddFAB(
                tooltip: "add-transaction".tr(),
                openPage: AddTransactionPage(
                  selectedObjective: widget.objective,
                  routesToPopAfterDelete: RoutesToPopAfterDelete.One,
                  selectedIncome: widget.objective.income,
                ),
              ),
            ),
            expandedHeight: 56,
            actions: [
              CustomPopupMenuButton(
                showButtons: enableDoubleColumn(context),
                keepOutFirst: true,
                forceKeepOutFirst: true,
                items: [
                  DropdownItemMenu(
                    id: "edit-goals",
                    label: widget.objective.type == ObjectiveType.loan
                        ? "edit-loan".tr()
                        : "edit-goal".tr(),
                    icon: appStateSettings["outlinedIcons"]
                        ? Icons.edit_outlined
                        : Icons.edit_rounded,
                    action: () {
                      pushRoute(
                        context,
                        AddObjectivePage(
                          objective: widget.objective,
                          routesToPopAfterDelete: RoutesToPopAfterDelete.All,
                        ),
                      );
                    },
                  ),
                  // Only show for loan goal
                  // if (widget.objective.type == ObjectiveType.loan &&
                  //     getIsDifferenceOnlyLoan(widget.objective) == false)
                  //   DropdownItemMenu(
                  //     id: "delete-goal",
                  //     label: widget.objective.type == ObjectiveType.loan
                  //         ? "delete-loan".tr()
                  //         : "delete-goal".tr(),
                  //     icon: appStateSettings["outlinedIcons"]
                  //         ? Icons.delete_outlined
                  //         : Icons.delete_rounded,
                  //     action: () {
                  //       deleteObjectivePopup(
                  //         context,
                  //         objective: widget.objective,
                  //         routesToPopAfterDelete: RoutesToPopAfterDelete.One,
                  //       );
                  //     },
                  //   ),
                ],
              ),
            ],
            title: widget.objective.name,
            capitalizeTitle: false,
            dragDownToDismiss: true,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsetsDirectional.symmetric(
                      horizontal: getHorizontalPaddingConstrained(context)),
                  child: StreamBuilder<int?>(
                    stream: database
                        .getTotalCountOfTransactionsInObjective(
                            widget.objective.objectivePk)
                        .$1,
                    builder: (context, contagem) =>
                        WatchTotalAndAmountOfObjective(
                      objective: widget.objective,
                      builder: (double objectiveAmount, double totalAmount,
                          double percentageTowardsGoal) {
                        // Confete uma vez só, e nunca com "reduzir movimento".
                        if (percentageTowardsGoal >= 1 &&
                            hasPlayedConfetti == false &&
                            !semMovimento(context)) {
                          confettiController.play();
                          hasPlayedConfetti = true;
                        }
                        return ResumoMeta(
                          objective: widget.objective,
                          alvo: objectiveAmount,
                          total: totalAmount,
                          fracao: percentageTowardsGoal,
                          mostrarTotal: showTotalSpent,
                          transacoes: contagem.data,
                          onTrocar: getIsDifferenceOnlyLoan(widget.objective)
                              ? null
                              : _swapTotalSpentDisplay,
                          onIcone: openSelectIconPopup,
                        );
                      },
                    ),
                  ),
                ),
              ),
              TransactionEntries(
                null,
                null,
                initialLoadLimit: 25,
                listID: pageId,
                dateDividerColor: pageBackgroundColor,
                transactionBackgroundColor: pageBackgroundColor,
                categoryTintColor: Theme.of(context).colorScheme.primary,
                searchFilters: widget.objective.type == ObjectiveType.loan
                    ? SearchFilters().copyWith(
                        objectiveLoanPks: [widget.objective.objectivePk])
                    : SearchFilters()
                        .copyWith(objectivePks: [widget.objective.objectivePk]),
                allowOpenIntoObjectiveLoanPage: false,
                showObjectivePercentage: false,
                noResultsMessage: "no-transactions-found".tr() +
                    (widget.objective.type == ObjectiveType.loan
                        ? "\n" + "add-record-using-plus-button".tr()
                        : ""),
                showNoResults: widget.objective.type == ObjectiveType.loan,
                noResultsExtraWidget:
                    widget.objective.type == ObjectiveType.goal
                        ? ExtraInfoButton(
                            onTap: () {
                              startCreatingInstallment(
                                  context: context,
                                  initialObjective: widget.objective);
                            },
                            icon: appStateSettings["outlinedIcons"]
                                ? Icons.punch_clock_outlined
                                : Icons.punch_clock_rounded,
                            text: "setup-installment-payments".tr(),
                            color: cores(context).surf,
                          )
                        : null,
                renderType: appStateSettings["appAnimations"] !=
                        AppAnimations.all.index
                    ? TransactionEntriesRenderType.sliversNotSticky
                    : TransactionEntriesRenderType.implicitlyAnimatedSlivers,
              ),
              // Wipe all remaining pixels off - sometimes graphics artifacts are left behind
              SliverToBoxAdapter(
                child: Container(height: 1, color: pageBackgroundColor),
              ),
              SliverToBoxAdapter(child: SizedBox(height: 45))
            ],
            selectedTransactionsAppBar: SelectedTransactionsAppBar(
              pageID: pageId,
            ),
          ),
          IgnorePointer(
            child: Align(
              alignment: AlignmentDirectional.topCenter,
              child: ConfettiWidget(
                shouldLoop: true,
                confettiController: confettiController,
                gravity: 0.2,
                blastDirectionality: BlastDirectionality.explosive,
                maximumSize: Size(15, 15),
                minimumSize: Size(10, 10),
                numberOfParticles: 15,
                canvas: Size.infinite,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String objectiveRemainingAmountText({
  required double objectiveAmount,
  required double totalAmount,
  required BuildContext context,
}) {
  String result = '';

  if (appStateSettings["showTotalSpentForObjective"] == false) {
    if (totalAmount > objectiveAmount) {
      result = " " + "over".tr() + " ";
    } else {
      result = " " + "remaining".tr() + " / ";
    }
  } else {
    result = " / ";
  }

  result += convertToMoney(Provider.of<AllWallets>(context), objectiveAmount);

  return result;
}

/// Topo da meta sem acesso ao banco: valor em destaque (toque alterna total e
/// restante, segurar copia), medidor, "de R$ X · 45%", datas e ritmo.
class ResumoMeta extends StatelessWidget {
  const ResumoMeta({
    super.key,
    required this.objective,
    required this.alvo,
    required this.total,
    required this.fracao,
    required this.mostrarTotal,
    this.transacoes,
    this.onTrocar,
    this.onIcone,
  });
  final Objective objective;
  final double alvo, total, fracao;
  final bool mostrarTotal;
  final int? transacoes;
  final VoidCallback? onTrocar, onIcone;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    String dinheiro(double v) =>
        convertToMoney(Provider.of<AllWallets>(context), v);
    String data(DateTime d) =>
        getWordedDateShortMore(d, includeYear: d.year != DateTime.now().year);
    final diferenca = getIsDifferenceOnlyLoan(objective);
    final semAlvo = objective.type == ObjectiveType.goal && alvo <= 0;
    final String rotulo;
    final double valor;
    if (diferenca) {
      final d = getDifferenceOfLoan(objective, total, alvo);
      rotulo = fracao == 1 ? 'Tudo quitado' : rotuloDiferenca(d, false);
      valor = d.abs();
    } else {
      final d = destaqueMeta(objective,
          alvo: alvo, total: total, mostrarTotal: mostrarTotal || semAlvo);
      rotulo = d.rotulo;
      valor = d.valor;
    }
    final concluida = objective.type == ObjectiveType.goal &&
        !semAlvo &&
        total >= alvo;
    final fim = objective.endDate;
    final status = fim == null || diferenca
        ? ''
        : getObjectiveStatus(context, objective, total, fracao, alvo,
            addSpendingSavingIndication: true);
    final contagem =
        transacoes == null ? null : textoTransacoes(transacoes!);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Semantics(
              button: onIcone != null,
              label: 'Trocar ícone',
              child: iconeMeta(objective,
                  size: 22, sizePadding: 16, onTap: onIcone),
            ),
            const SizedBox(width: 12),
            if (!diferenca)
              Expanded(
                child: Text(
                    data(objective.dateCreated) +
                        (fim == null ? '' : ' – ${data(fim)}'),
                    maxLines: 2,
                    style: EdTexto.rotulo(context)),
              ),
          ]),
          const SizedBox(height: 18),
          Text(rotulo, style: EdTexto.rotulo(context)),
          const SizedBox(height: 8),
          Semantics(
            button: onTrocar != null,
            hint: onTrocar == null ? null : 'Alterna entre total e restante',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTrocar,
              onLongPress: () => copyToClipboard(dinheiro(valor)),
              child: ContagemValor(
                valor: valor,
                formatar: (v) => convertToMoney(
          Provider.of<AllWallets>(context), v,
          allDecimals: true),
                centavosMenores: true,
                estilo: EdTexto.numeroGrande(context)
                    .copyWith(color: concluida ? e.pos : null),
              ),
            ),
          ),
          if (!diferenca && !semAlvo) ...[
            const SizedBox(height: 14),
            MedidorEditorial(fracao: fracao),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text(
                    detalheMeta(context, objective, alvo: alvo, fracao: fracao),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.rotulo(context)),
              ),
              if (contagem != null) ...[
                const SizedBox(width: 8),
                Text(contagem, style: EdTexto.rotulo(context)),
              ],
            ]),
          ] else if (contagem != null) ...[
            const SizedBox(height: 10),
            Text(contagem, style: EdTexto.rotulo(context)),
          ],
          if (status != '') ...[
            const SizedBox(height: 12),
            Text(status,
                maxLines: 3,
                style: EdTexto.corpo(context)
                    .copyWith(fontWeight: FontWeight.w500)),
          ],
        ],
      ),
    );
  }
}
