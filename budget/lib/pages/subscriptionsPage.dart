import 'package:budget/database/tables.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/upcomingOverdueTransactionsPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/initializeNotifications.dart';
import 'package:budget/struct/upcomingTransactionsFunctions.dart';
import 'package:budget/widgets/animatedExpanded.dart';
import 'package:budget/widgets/dropdownSelect.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/editorial/resumoTransacoes.dart';
import 'package:budget/widgets/slidingSelectorIncomeExpense.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/navigationSidebar.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/selectedTransactionsAppBar.dart';
import 'package:budget/widgets/fab.dart';
import 'package:budget/widgets/fadeIn.dart';
import 'package:budget/widgets/noResults.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/transactionEntry/transactionEntry.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';

class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({Key? key}) : super(key: key);

  @override
  State<SubscriptionsPage> createState() => SubscriptionsPageState();
}

enum SelectedSubscriptionsType {
  monthly,
  yearly,
  total,
}

class SubscriptionsPageState extends State<SubscriptionsPage> {
  SelectedSubscriptionsType selectedType = SelectedSubscriptionsType
      .values[appStateSettings["selectedSubscriptionType"]];
  GlobalKey<PageFrameworkState> pageState = GlobalKey();
  // Entrada suave só logo após abrir (não ao trocar o período).
  final DateTime _aberta = DateTime.now();

  void scrollToTop() {
    pageState.currentState?.scrollToTop();
  }

  @override
  Widget build(BuildContext context) {
    String pageId = "Subscriptions";

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
      child: PageFramework(
        key: pageState,
        listID: pageId,
        floatingActionButton: AnimateFABDelayed(
          fab: AddFAB(
            tooltip: "add-subscription".tr(),
            openPage: AddTransactionPage(
              selectedType: TransactionSpecialType.subscription,
              routesToPopAfterDelete: RoutesToPopAfterDelete.None,
            ),
          ),
        ),
        dragDownToDismiss: true,
        title: "subscriptions".tr(),
        actions: [
          CustomPopupMenuButton(
            showButtons: enableDoubleColumn(context),
            keepOutFirst: true,
            items: [
              DropdownItemMenu(
                id: "settings",
                label: "settings".tr(),
                icon: appStateSettings["outlinedIcons"]
                    ? Icons.more_vert_outlined
                    : Icons.more_vert_rounded,
                action: () {
                  openBottomSheet(
                    context,
                    PopupFramework(
                      hasPadding: false,
                      child: SubscriptionSettings(),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
        slivers: [
          SliverToBoxAdapter(
            child: TotalUpcomingHeaderPeriodSwitcher(
              transactionListStream: database.getAllSubscriptions().$1,
              selectedType: selectedType,
              setSelectedType: (chosenType) {
                setState(() {
                  selectedType = chosenType;
                });
              },
              selectedSubtitleTranslation: (selectedType) {
                return selectedType == SelectedSubscriptionsType.yearly
                    ? "yearly-subscriptions".tr()
                    : selectedType == SelectedSubscriptionsType.monthly
                        ? "monthly-subscriptions".tr()
                        : "total-subscriptions".tr();
              },
              contagem: contagemAssinaturas,
            ),
          ),
          StreamBuilder<List<Transaction>>(
            stream: database.getAllSubscriptions().$1,
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                if (snapshot.data!.length <= 0) {
                  return SliverToBoxAdapter(
                    child: Column(
                      children: [
                        NoResults(message: "Nenhuma assinatura."),
                        AcaoVazio(
                          rotulo: "Adicionar assinatura",
                          onTap: () => pushRoute(
                            context,
                            AddTransactionPage(
                              selectedType: TransactionSpecialType.subscription,
                              routesToPopAfterDelete:
                                  RoutesToPopAfterDelete.None,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      Transaction transaction = snapshot.data![index];
                      return EntradaSuave(
                        key: ValueKey(transaction.transactionPk),
                        indice: index,
                        animar: DateTime.now().difference(_aberta) <
                            const Duration(milliseconds: 600),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            HorizontalBreak(
                                padding: EdgeInsetsDirectional.only(
                                    top: 4, bottom: 6)),
                            TransactionEntry(
                              aboveWidget: UpcomingTransactionDateHeader(
                                selectedType: selectedType,
                                transaction: transaction,
                              ),
                              openPage: AddTransactionPage(
                                transaction: transaction,
                                routesToPopAfterDelete:
                                    RoutesToPopAfterDelete.One,
                              ),
                              transaction: transaction,
                              listID: pageId,
                            ),
                            if (index == (snapshot.data?.length ?? 0) - 1)
                              HorizontalBreak(
                                  padding: EdgeInsetsDirectional.only(
                                      top: 4, bottom: 6)),
                          ],
                        ),
                      );
                    },
                    childCount: snapshot.data?.length,
                  ),
                );
              } else {
                return SliverToBoxAdapter();
              }
            },
          ),
          SliverToBoxAdapter(child: SizedBox(height: 55)),
        ],
        selectedTransactionsAppBar: SelectedTransactionsAppBar(
          pageID: pageId,
        ),
      ),
    );
  }
}

class UpcomingTransactionDateHeader extends StatelessWidget {
  const UpcomingTransactionDateHeader({
    Key? key,
    required this.transaction,
    required this.selectedType,
    this.useHorizontalPaddingConstrained = true,
  }) : super(key: key);

  final Transaction transaction;
  final SelectedSubscriptionsType? selectedType;
  final bool useHorizontalPaddingConstrained;

  @override
  Widget build(BuildContext context) {
    int daysDifference =
        DateTime.now().justDay().difference(transaction.dateCreated).inDays;
    // "R$ 20,90 / mês" numa assinatura de 1 mês repete o valor da linha.
    final repeteValor = transaction.periodLength == 1 &&
        ((selectedType == SelectedSubscriptionsType.monthly &&
                transaction.reoccurrence == BudgetReoccurence.monthly) ||
            (selectedType == SelectedSubscriptionsType.yearly &&
                transaction.reoccurrence == BudgetReoccurence.yearly));
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(bottom: 3, end: 5),
            child: Row(
              children: [
                TextFont(
                  text: getWordedDateShortMore(
                    transaction.dateCreated,
                  ),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                daysDifference != 0
                    ? Flexible(
                        child: TextFont(
                          fontSize: 13,
                          textColor: daysDifference > 0
                              ? cores(context).warn
                              : cores(context).mu,
                          text: " · " +
                              (daysDifference > 0 ? "" : "em ") +
                              daysDifference.abs().toString() +
                              " " +
                              (daysDifference.abs() == 1
                                  ? "day".tr()
                                  : "days".tr()) +
                              (daysDifference > 0 ? " de atraso" : ""),
                          fontWeight: FontWeight.w500,
                        ),
                      )
                    : SizedBox(),
              ],
            ),
          ),
        ),
        transaction.type == TransactionSpecialType.repetitive ||
                transaction.type == TransactionSpecialType.subscription
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      Icon(
                        appStateSettings["outlinedIcons"]
                            ? Icons.loop_outlined
                            : Icons.loop_rounded,
                        color: cores(context).mu,
                        size: 14,
                      ),
                      SizedBox(width: 3),
                      TextFont(
                        text: transaction.periodLength.toString() +
                            " " +
                            (transaction.periodLength == 1
                                ? nameRecurrence[transaction.reoccurrence]
                                    .toString()
                                    .toLowerCase()
                                    .tr()
                                    .toLowerCase()
                                : namesRecurrence[transaction.reoccurrence]
                                    .toString()
                                    .toLowerCase()
                                    .tr()
                                    .toLowerCase()),
                        fontSize: 12.5,
                        textColor: cores(context).mu,
                      ),
                    ],
                  ),
                  if (selectedType != null)
                    AnimatedSizeSwitcher(
                      child: selectedType == SelectedSubscriptionsType.total ||
                              repeteValor
                          ? Container(
                              key: ValueKey(selectedType.toString()),
                            )
                          : TextFont(
                              key: ValueKey(selectedType.toString()),
                              text: convertToMoney(
                                    Provider.of<AllWallets>(context),
                                    getTotalSubscriptions(
                                        Provider.of<AllWallets>(context),
                                        selectedType ??
                                            SelectedSubscriptionsType.monthly,
                                        [transaction]),
                                  ) +
                                  " / " +
                                  (selectedType ==
                                              SelectedSubscriptionsType.monthly
                                          ? "month".tr()
                                          : selectedType ==
                                                  SelectedSubscriptionsType
                                                      .yearly
                                              ? "year".tr()
                                              : "")
                                      .toLowerCase(),
                              fontSize: 12.5,
                              textColor: cores(context).mu,
                            ),
                    ),
                ],
              )
            : SizedBox(),
      ],
    );
  }
}

class SubscriptionSettings extends StatelessWidget {
  const SubscriptionSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AutoPaySubscriptionsSetting(),
        AutoPaySettingDescription(),
      ],
    );
  }
}

class AutoPaySubscriptionsSetting extends StatelessWidget {
  const AutoPaySubscriptionsSetting({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsContainerSwitch(
      title: "pay-subscriptions".tr(),
      description: "pay-subscriptions-description".tr(),
      onSwitched: (value) async {
        // Need to change setting first, otherwise the function would not run!
        await updateSettings("automaticallyPaySubscriptions", value,
            updateGlobalState: false);
        await markSubscriptionsAsPaid(context);
        await setUpcomingNotifications(context);
      },
      initialValue: appStateSettings["automaticallyPaySubscriptions"],
      icon: getTransactionTypeIcon(TransactionSpecialType.subscription),
    );
  }
}

class TotalUpcomingHeaderPeriodSwitcher extends StatelessWidget {
  const TotalUpcomingHeaderPeriodSwitcher({
    required this.selectedType,
    required this.setSelectedType,
    required this.transactionListStream,
    required this.selectedSubtitleTranslation,
    required this.contagem,
    super.key,
  });
  final SelectedSubscriptionsType selectedType;
  final Function(SelectedSubscriptionsType) setSelectedType;
  final Stream<List<Transaction>>? transactionListStream;
  final String Function(SelectedSubscriptionsType) selectedSubtitleTranslation;

  /// Legenda da contagem: contagemAssinaturas ou contagemAgendadas.
  final String Function(int) contagem;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        StreamBuilder<List<Transaction>>(
          stream: transactionListStream,
          builder: (context, snapshot) {
            return TotalDestaque(
              rotulo: selectedSubtitleTranslation(selectedType),
              valor: getTotalSubscriptions(Provider.of<AllWallets>(context),
                  selectedType, snapshot.data),
              legenda: snapshot.data == null
                  ? null
                  : contagem(snapshot.data!.length),
            );
          },
        ),
        SlidingSelectorIncomeExpense(
          initialIndex: selectedType.index,
          options: ["monthly", "yearly", "total"],
          onSelected: (int index) {
            final tipo = SelectedSubscriptionsType.values[index - 1];
            setSelectedType(tipo);
            updateSettings("selectedSubscriptionType", tipo.index,
                pagesNeedingRefresh: [], updateGlobalState: false);
          },
        ),
        SizedBox(height: 12),
      ],
    );
  }
}
