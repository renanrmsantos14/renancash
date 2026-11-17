import 'package:budget/colors.dart';
import 'package:budget/struct/mbSync/conexoes.dart'
    show mbOrigemCarteira, mbTiposDasCarteiras;
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addWalletPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/animatedExpanded.dart';
import 'package:budget/widgets/dropdownSelect.dart';
import 'package:budget/widgets/fab.dart';
import 'package:budget/widgets/fadeIn.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/noResults.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/radioItems.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/walletEntry.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart' hide SliverReorderableList;
import 'package:flutter/services.dart' hide TextInput;
import 'package:budget/widgets/editRowEntry.dart';
import 'package:budget/modified/reorderable_list.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:provider/provider.dart';
import 'exchangeRatesPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart'
    show mbLerSaldosReais, mbSigla;
import 'package:budget/widgets/editorial/contas.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:sliver_tools/sliver_tools.dart';

class EditWalletsPage extends StatefulWidget {
  EditWalletsPage({Key? key, this.runWhenOpen}) : super(key: key);

  final VoidCallback? runWhenOpen;

  @override
  _EditWalletsPageState createState() => _EditWalletsPageState();
}

class _EditWalletsPageState extends State<EditWalletsPage> {
  bool dragDownToDismissEnabled = true;
  int currentReorder = -1;
  String searchValue = "";
  bool isFocused = false;
  final DateTime _aberta = DateTime.now();
  // Conta do Meu Banco: o saldo real (o da Início), não a soma dos lançamentos.
  Map<String, double> _saldosReais = const {};
  double _saldoDe(WalletWithDetails w) =>
      _saldosReais[w.wallet.walletPk] ?? w.totalSpent ?? 0;

  @override
  void initState() {
    mbLerSaldosReais().then((r) {
      if (mounted) setState(() => _saldosReais = r);
    }, onError: (_) {});
    Future.delayed(Duration.zero, () {
      if (widget.runWhenOpen != null) {
        widget.runWhenOpen!();
      }
      database.fixOrderWallets();
    });
    // Tipo das contas do Meu Banco para o subtítulo (nomes repetidos se distinguem).
    mbTiposDasCarteiras().then((t) {
      if (mounted) setState(() => _tiposMb = t);
    });
    super.initState();
  }

  Map<String, String> _tiposMb = const {};

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (searchValue != "") {
          setState(() {
            searchValue = "";
          });
          return false;
        } else {
          return true;
        }
      },
      child: PageFramework(
        horizontalPaddingConstrained: true,
        dragDownToDismiss: true,
        dragDownToDismissEnabled: dragDownToDismissEnabled,
        scrollToTopButton: true,
        title: "Contas",
        floatingActionButton: AnimateFABDelayed(
          fab: AddFAB(
            tooltip: "add-account".tr(),
            openPage: AddWalletPage(
              routesToPopAfterDelete: RoutesToPopAfterDelete.None,
            ),
          ),
        ),
        actions: [
          CustomPopupMenuButton(
            showButtons: true,
            keepOutFirst: true,
            items: [
              DropdownItemMenu(
                id: "add-account",
                label: "add-account".tr(),
                icon: appStateSettings["outlinedIcons"]
                    ? Icons.add_outlined
                    : Icons.add_rounded,
                action: () {
                  pushRoute(
                    context,
                    AddWalletPage(
                      routesToPopAfterDelete: RoutesToPopAfterDelete.None,
                    ),
                  );
                },
              ),
              DropdownItemMenu(
                id: "settings",
                label: "settings".tr(),
                icon: appStateSettings["outlinedIcons"]
                    ? Icons.more_vert_outlined
                    : Icons.more_vert_rounded,
                action: () => openBottomSheet(
                  context,
                  PopupFramework(
                    hasPadding: false,
                    child: WalletsSettings(
                        backgroundColor: getPopupBackgroundColor(context)),
                  ),
                ),
              ),
            ],
          ),
        ],
        slivers: [
          // Busca só quando a lista é longa; com poucas contas ela é ruído.
          if (Provider.of<AllWallets>(context).list.length > 6 ||
              searchValue != "")
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(bottom: 8.0),
                child: Focus(
                  onFocusChange: (value) {
                    setState(() {
                      isFocused = value;
                    });
                  },
                  child: TextInput(
                    labelText: "search-accounts-placeholder".tr(),
                    icon: appStateSettings["outlinedIcons"]
                        ? Icons.search_outlined
                        : Icons.search_rounded,
                    onSubmitted: (value) {
                      setState(() {
                        searchValue = value;
                      });
                    },
                    onChanged: (value) {
                      setState(() {
                        searchValue = value;
                      });
                    },
                    autoFocus: false,
                  ),
                ),
              ),
            ),
          StreamBuilder<List<WalletWithDetails>>(
            stream: database.watchAllWalletsWithDetails(
                searchFor: searchValue == "" ? null : searchValue),
            builder: (context, snapshot) {
              if (snapshot.hasData && (snapshot.data ?? []).length <= 0) {
                return SliverToBoxAdapter(
                  child: NoResults(
                    message: "no-accounts-found".tr(),
                  ),
                );
              }
              if (snapshot.hasData && (snapshot.data ?? []).length > 0) {
                final allWallets = Provider.of<AllWallets>(context);
                final contas = snapshot.data!;
                // Total na moeda principal, como na Início.
                final total = contas.fold<double>(
                    0,
                    (soma, w) =>
                        soma +
                        _saldoDe(w) *
                            amountRatioToPrimaryCurrency(
                                allWallets, w.wallet.currency));
                return MultiSliver(children: [
                  if (searchValue == "")
                    SliverToBoxAdapter(
                      child: TotalContas(
                        total: total,
                        quantidade: contas.length,
                        formatar: (v) => convertToMoney(allWallets, v),
                      ),
                    ),
                  SliverReorderableList(
                    onReorderStart: (index) {
                      HapticFeedback.heavyImpact();
                      setState(() {
                        dragDownToDismissEnabled = false;
                        currentReorder = index;
                      });
                    },
                    onReorderEnd: (_) {
                      setState(() {
                        dragDownToDismissEnabled = true;
                        currentReorder = -1;
                      });
                    },
                    itemBuilder: (context, index) {
                      WalletWithDetails walletWithDetails =
                          snapshot.data![index];
                      TransactionWallet wallet = walletWithDetails.wallet;
                      final principal = Provider.of<SelectedWalletPk>(context)
                              .selectedWalletPk ==
                          wallet.walletPk;
                      final n = walletWithDetails.numberTransactions;
                      return EntradaSuave(
                        key: ValueKey(wallet.walletPk),
                        indice: index,
                        animar: DateTime.now().difference(_aberta) <
                            const Duration(milliseconds: 600),
                        child: EditRowEntry(
                          extraIcon: principal
                              ? appStateSettings["outlinedIcons"]
                                  ? Icons.star_outlined
                                  : Icons.star_rounded
                              : Icons.star_outline,
                          onExtra: () async {
                            setPrimaryWallet(
                              wallet.walletPk,
                              allWallets: Provider.of<AllWallets>(context,
                                  listen: false),
                            );
                          },
                          // Excluir fica no menu da conta (com confirmação):
                          // a linha mantém só principal e reordenar.
                          canDelete: false,
                          canReorder: searchValue == "" &&
                              (snapshot.data ?? []).length != 1,
                          currentReorder:
                              currentReorder != -1 && currentReorder != index,
                          index: index,
                          content: LinhaConta(
                            sigla: mbSigla(wallet.name),
                            nome: wallet.name,
                            detalhe: [
                              if (principal) "Principal",
                              mbOrigemCarteira(wallet.walletPk, _tiposMb),
                              n == 1 ? "1 transação" : "$n transações",
                            ].join(" · "),
                            saldo: comSinal(
                                _saldoDe(walletWithDetails),
                                (v) => convertToMoney(allWallets, v,
                                    currencyKey: wallet.currency,
                                    decimals: wallet.decimals,
                                    addCurrencyName:
                                        !allWallets.allContainSameCurrency())),
                          ),
                          openPage: AddWalletPage(
                              wallet: wallet,
                              routesToPopAfterDelete:
                                  RoutesToPopAfterDelete.One),
                        ),
                      );
                    },
                    itemCount: snapshot.data!.length,
                    onReorder: (_intPrevious, _intNew) async {
                      WalletWithDetails oldWalletWithDetails =
                          snapshot.data![_intPrevious];
                      TransactionWallet oldWallet = oldWalletWithDetails.wallet;

                      if (_intNew > _intPrevious) {
                        await database.moveWallet(
                            oldWallet.walletPk, _intNew - 1, oldWallet.order);
                      } else {
                        await database.moveWallet(
                            oldWallet.walletPk, _intNew, oldWallet.order);
                      }
                      return true;
                    },
                  ),
                ]);
              }
              return SliverToBoxAdapter(
                child: Container(),
              );
            },
          ),
          SliverToBoxAdapter(
            child: SizedBox(height: 85),
          ),
        ],
      ),
    );
  }
}

Future<DeletePopupAction?> deleteWalletPopup(
  BuildContext context, {
  required TransactionWallet wallet,
  required RoutesToPopAfterDelete routesToPopAfterDelete,
}) async {
  DeletePopupAction? action = await openDeletePopup(
    context,
    title: "delete-account-question".tr(),
    subtitle: wallet.name,
    description: "delete-account-question-description".tr(),
  );
  if (action == DeletePopupAction.Delete) {
    int transactionsFromWalletLength =
        (await database.getAllTransactionsFromWallet(wallet.walletPk)).length;
    dynamic result = true;
    if (transactionsFromWalletLength > 0) {
      result = await openPopup(
        context,
        title: "delete-all-transactions-question".tr(),
        description: "delete-account-merge-warning".tr(),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.warning_outlined
            : Icons.warning_rounded,
        onCancel: () {
          popRoute(context, false);
        },
        onCancelLabel: "cancel".tr(),
        onSubmit: () async {
          popRoute(context, true);
        },
        onExtra2: () {
          popRoute(context, false);
          mergeWalletPopup(
            context,
            walletOriginal: wallet,
            routesToPopAfterDelete: routesToPopAfterDelete,
          );
        },
        onExtraLabel2: "move-transactions".tr(),
        onSubmitLabel: "delete".tr(),
      );
    }
    if (result == true) {
      if (routesToPopAfterDelete == RoutesToPopAfterDelete.All) {
        popAllRoutes(context);
      } else if (routesToPopAfterDelete == RoutesToPopAfterDelete.One) {
        popRoute(context);
      }
      openLoadingPopupTryCatch(() async {
        await database.deleteWallet(wallet.walletPk, wallet.order);
        openSnackbar(
          SnackbarMessage(
            title: "deleted-account".tr(),
            icon: Icons.delete,
            description: wallet.name,
          ),
        );
      });
    }
  }
  return action;
}

void mergeWalletPopup(
  BuildContext context, {
  required TransactionWallet walletOriginal,
  required RoutesToPopAfterDelete routesToPopAfterDelete,
}) async {
  var selectedWalletResult = await selectWalletPopup(
    context,
    removeWalletPks: [walletOriginal.walletPk],
    subtitle: "account-to-transfer-all-transactions-to".tr(),
    allowEditWallet: false,
  );
  if (selectedWalletResult != null) {
    final result = await openPopup(
      context,
      title: "merge-into".tr() + " " + selectedWalletResult.name + "?",
      description: "merge-into-description-accounts".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.merge_outlined
          : Icons.merge_rounded,
      onSubmit: () async {
        popRoute(context, true);
      },
      onSubmitLabel: "merge".tr(),
      onCancelLabel: "cancel".tr(),
      onCancel: () {
        popRoute(context);
      },
    );
    if (result == true) {
      if (routesToPopAfterDelete == RoutesToPopAfterDelete.All) {
        popAllRoutes(context);
      } else if (routesToPopAfterDelete == RoutesToPopAfterDelete.One) {
        popRoute(context);
      }
      openLoadingPopupTryCatch(() async {
        await database.moveWalletTransactions(
          Provider.of<AllWallets>(context, listen: false),
          walletOriginal.walletPk,
          selectedWalletResult.walletPk,
        );
        if (walletOriginal.walletPk == "0") {
          await database.convertToPrimaryWallet(selectedWalletResult);
        } else {
          await database.deleteWallet(
              walletOriginal.walletPk, walletOriginal.order);
        }

        openSnackbar(
          SnackbarMessage(
            title: "merged-account".tr(),
            icon: appStateSettings["outlinedIcons"]
                ? Icons.merge_outlined
                : Icons.merge_rounded,
            description:
                walletOriginal.name + " → " + selectedWalletResult.name,
          ),
        );
      });
    }
  }
}

Future<TransactionWallet?> selectWalletPopup(
  BuildContext context, {
  List<String>? removeWalletPks,
  String? subtitle,
  TransactionWallet? selectedWallet,
  required bool allowEditWallet,
  bool allowDeleteWallet = true,
  bool currencyOnly = false,
  String? title,
}) async {
  dynamic wallet = await openBottomSheet(
    context,
    PopupFramework(
      title: title ?? "select-account".tr(),
      subtitle: subtitle,
      child: StreamBuilder<List<WalletWithDetails>>(
        stream: database.watchAllWalletsWithDetails(),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            List<WalletWithDetails> walletsWithoutOneDeleted = snapshot.data!;
            if (removeWalletPks != null)
              walletsWithoutOneDeleted.removeWhere((WalletWithDetails w) =>
                  removeWalletPks.contains(w.wallet.walletPk));
            if (walletsWithoutOneDeleted.isEmpty) {
              return Padding(
                padding: const EdgeInsetsDirectional.only(bottom: 15),
                child: NoResults(message: "no-accounts-found".tr()),
              );
            }
            return RadioItems(
              getSelected: (Object? object) {
                TransactionWallet? wallet;
                if (object is WalletWithDetails) wallet = object.wallet;
                if (wallet?.walletPk == selectedWallet?.walletPk) return true;
                return false;
              },
              items: walletsWithoutOneDeleted,
              colorFilter: (Object? object) {
                TransactionWallet? wallet;
                if (object is WalletWithDetails) wallet = object.wallet;
                if (wallet == null) return null;
                return dynamicPastel(
                  context,
                  lightenPastel(
                    HexColor(
                      wallet.colour,
                      defaultColor: Theme.of(context).colorScheme.primary,
                    ),
                    amount: 0.2,
                  ),
                  amount: 0.1,
                );
              },
              displayFilter: (Object? object) {
                TransactionWallet? wallet;
                if (object is WalletWithDetails) wallet = object.wallet;
                if (currencyOnly) {
                  return (wallet?.currency ?? "").allCaps;
                }
                return wallet?.name ?? "";
              },
              getEndInfo: currencyOnly
                  ? null
                  : (Object? object) {
                      TransactionWallet? wallet;
                      double totalSpent = 0;
                      if (object is WalletWithDetails) {
                        wallet = object.wallet;
                        totalSpent = object.totalSpent ?? 0;
                      }
                      return convertToMoney(
                        Provider.of<AllWallets>(context),
                        totalSpent,
                        finalNumber: totalSpent,
                        currencyKey: wallet?.currency,
                        decimals: wallet?.decimals,
                        addCurrencyName: true,
                      );
                    },
              initial: selectedWallet,
              onChanged: (Object? object) {
                TransactionWallet? wallet;
                if (object is WalletWithDetails) wallet = object.wallet;
                popRoute(context, wallet);
              },
              onLongPress: (Object? object) {
                TransactionWallet? wallet;
                if (object is WalletWithDetails) wallet = object.wallet;
                if (allowEditWallet)
                  pushRoute(
                    context,
                    AddWalletPage(
                      routesToPopAfterDelete: allowDeleteWallet == false
                          ? RoutesToPopAfterDelete.PreventDelete
                          : RoutesToPopAfterDelete.One,
                      wallet: wallet,
                    ),
                  );
              },
            );
          } else {
            return SizedBox.shrink();
          }
        },
      ),
    ),
  );

  if (wallet is TransactionWallet) return wallet;
  return null;
}

class ShowAccountLabelSettingToggle extends StatelessWidget {
  const ShowAccountLabelSettingToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsContainerSwitch(
      title: "account-label".tr(),
      description: "account-label-description".tr(),
      onSwitched: (value) {
        updateSettings("showAccountLabelTagInTransactionEntry", value,
            updateGlobalState: true);
      },
      initialValue: appStateSettings["showAccountLabelTagInTransactionEntry"],
      icon: appStateSettings["outlinedIcons"]
          ? Icons.label_outlined
          : Icons.label_rounded,
    );
  }
}

class ShowCurrencyLabelSettingToggle extends StatelessWidget {
  const ShowCurrencyLabelSettingToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedExpanded(
      expand:
          Provider.of<AllWallets>(context).allContainSameCurrency() == false,
      child: SettingsContainerSwitch(
        title: "currency-label".tr(),
        description: "currency-label-description".tr(),
        onSwitched: (value) {
          updateSettings("showCurrencyLabel", value, updateGlobalState: true);
        },
        initialValue: appStateSettings["showCurrencyLabel"] == true,
        icon: appStateSettings["outlinedIcons"]
            ? Symbols.event_list_sharp
            : Symbols.event_list_rounded,
      ),
    );
  }
}

class ExchangeRateSettingPage extends StatelessWidget {
  const ExchangeRateSettingPage({this.backgroundColor, super.key});
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return SettingsContainerOpenPage(
      backgroundColor: backgroundColor,
      onOpen: () {
        checkIfExchangeRateChangeBefore();
      },
      onClosed: () {
        checkIfExchangeRateChangeAfter();
      },
      openPage: ExchangeRates(),
      title: "exchange-rates".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.account_balance_wallet_outlined
          : Icons.account_balance_wallet_rounded,
    );
  }
}

class PrimaryCurrencySetting extends StatelessWidget {
  const PrimaryCurrencySetting({super.key});

  @override
  Widget build(BuildContext context) {
    VoidCallback changeCurrencyPopup = () => openPopup(
          context,
          title: "change-currency".tr(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.card_membership_outlined
              : Icons.card_membership_rounded,
          description: "change-currency-description".tr(),
          onSubmit: () {
            popRoute(context);
          },
          onSubmitLabel: "ok".tr(),
        );
    return SettingsContainerOpenPage(
      title: "primary-currency".tr().capitalizeFirst,
      icon: appStateSettings["outlinedIcons"]
          ? Icons.card_membership_outlined
          : Icons.card_membership_rounded,
      afterWidget: Tappable(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: 10,
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 16, vertical: 10),
          child: Builder(builder: (context) {
            return TextFont(
              text: (Provider.of<AllWallets>(context)
                      .indexedByPk[appStateSettings["selectedWalletPk"]]
                      ?.currency
                      ?.allCaps) ??
                  "",
              fontSize: 14,
            );
          }),
        ),
      ),
      openPage: Provider.of<AllWallets>(context).indexedByPk.length > 1
          ? EditWalletsPage(
              runWhenOpen: changeCurrencyPopup,
            )
          : AddWalletPage(
              runWhenOpen: changeCurrencyPopup,
              routesToPopAfterDelete: RoutesToPopAfterDelete.PreventDelete,
              wallet: Provider.of<AllWallets>(context)
                  .indexedByPk[appStateSettings["selectedWalletPk"]],
            ),
    );
  }
}

class WalletsSettings extends StatelessWidget {
  const WalletsSettings({this.backgroundColor, super.key});
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ShowAccountLabelSettingToggle(),
        ShowCurrencyLabelSettingToggle(),
        ExchangeRateSettingPage(backgroundColor: backgroundColor),
      ],
    );
  }
}
