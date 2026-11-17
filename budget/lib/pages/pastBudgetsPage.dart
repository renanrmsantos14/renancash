import 'dart:async';

import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/addCategoryPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/budgetHistoryLineGraph.dart';
import 'package:budget/pages/budgetPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/budgetContainer.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/categoryIcon.dart';
import 'package:budget/widgets/editRowEntry.dart';
import 'package:budget/widgets/fadeIn.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/selectCategory.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/util/debouncer.dart';
import 'package:budget/widgets/viewAllTransactionsButton.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:budget/colors.dart';
import 'package:async/async.dart' show StreamZip;
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import 'package:provider/provider.dart';
import 'package:budget/widgets/countNumber.dart';
import 'package:budget/widgets/animatedExpanded.dart';
import 'package:sliver_tools/sliver_tools.dart';

class PastBudgetsPage extends StatelessWidget {
  const PastBudgetsPage({super.key, required String this.budgetPk});
  final String budgetPk;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Budget>(
        stream: database.getBudget(budgetPk),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            Color? accentColor = HexColor(snapshot.data?.colour);
            return CustomColorTheme(
              accentColor: snapshot.data?.colour == null ? null : accentColor,
              child: _PastBudgetsPageContent(
                budget: snapshot.data!,
              ),
            );
          }
          return SizedBox.shrink();
        });
  }
}

class _PastBudgetsPageContent extends StatefulWidget {
  const _PastBudgetsPageContent({Key? key, required Budget this.budget})
      : super(key: key);
  final Budget budget;

  @override
  State<_PastBudgetsPageContent> createState() =>
      __PastBudgetsPageContentState();
}

class __PastBudgetsPageContentState extends State<_PastBudgetsPageContent> {
  Stream<List<double?>>? mergedStreamsBudgetTotal;
  Stream<List<double?>>? mergedStreamsCategoriesTotal;
  List<DateTimeRange> dateTimeRanges = [];
  int amountLoaded = 8;
  bool amountLoadedPressedOnce = false;
  late List<String> selectedCategoryFks =
      getSelectedCategoryFksConsideringBudget();
  GlobalKey<_PastBudgetContainerListState>
      _pastBudgetContainerListStateStateKey = GlobalKey();
  GlobalKey<PageFrameworkState> budgetHistoryKey = GlobalKey();

  initState() {
    Future.delayed(Duration.zero, () async {
      loadLines(amountLoaded);
    });
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _PastBudgetsPageContent oldWidget) {
    if (oldWidget.budget != widget.budget) loadLines(amountLoaded);
    super.didUpdateWidget(oldWidget);
  }

  List<String> getSelectedCategoryFksConsideringBudget() {
    List<String> selectedCategoryFks =
        (appStateSettings["watchedCategoriesOnBudget"]
                    [widget.budget.budgetPk.toString()] ??
                [])
            .map<String>((value) => value.toString())
            .toList();
    selectedCategoryFks.removeWhere((categoryFk) =>
        (widget.budget.categoryFksExclude ?? []).contains(categoryFk));
    if (widget.budget.categoryFks != null ||
        widget.budget.categoryFks?.isNotEmpty == true) {
      selectedCategoryFks.retainWhere((categoryFk) =>
          (widget.budget.categoryFks ?? []).contains(categoryFk));
    }
    return selectedCategoryFks;
  }

  void loadLines(amountLoaded) async {
    dateTimeRanges = [];
    List<Stream<double?>> watchedBudgetTotals = [];
    List<Stream<double?>> watchedCategoryTotals = [];
    for (int index = 0; index < amountLoaded; index++) {
      DateTime datePast =
          getDatePastToDetermineBudgetDate(index, widget.budget);
      DateTimeRange budgetRange = getBudgetDate(widget.budget, datePast);
      dateTimeRanges.add(budgetRange);
      watchedBudgetTotals.add(database.watchTotalSpentInTimeRangeFromCategories(
        allWallets: Provider.of<AllWallets>(context, listen: false),
        start: budgetRange.start,
        end: budgetRange.end,
        categoryFks: widget.budget.categoryFks,
        categoryFksExclude: widget.budget.categoryFksExclude,
        budgetTransactionFilters: widget.budget.budgetTransactionFilters,
        memberTransactionFilters: widget.budget.memberTransactionFilters,
        onlyShowTransactionsBelongingToBudgetPk:
            widget.budget.sharedKey != null ||
                    widget.budget.addedTransactionsOnly == true
                ? widget.budget.budgetPk
                : null,
        budget: widget.budget,
      ));
      for (String categoryFk in [...(selectedCategoryFks)]) {
        try {
          await database.getCategory(categoryFk).$2;
        } catch (e) {
          // print("Category No Longer Exists!");
          (selectedCategoryFks).remove(categoryFk);
          updateSetting(selectedCategoryFks);
          continue;
        }
        watchedCategoryTotals
            .add(database.watchTotalSpentInTimeRangeFromCategories(
          allWallets: Provider.of<AllWallets>(context, listen: false),
          start: budgetRange.start,
          end: budgetRange.end,
          categoryFks: [categoryFk],
          categoryFksExclude: null,
          budgetTransactionFilters: widget.budget.budgetTransactionFilters,
          memberTransactionFilters: widget.budget.memberTransactionFilters,
          onlyShowTransactionsBelongingToBudgetPk:
              widget.budget.sharedKey != null ||
                      widget.budget.addedTransactionsOnly == true
                  ? widget.budget.budgetPk
                  : null,
          budget: widget.budget,
        ));
      }
    }

    setState(() {
      mergedStreamsBudgetTotal = StreamZip(watchedBudgetTotals);
      mergedStreamsCategoriesTotal = StreamZip(watchedCategoryTotals);
    });
    // mergedStreams.listen(
    //   (event) {
    //     print("EVENT");
    //     print(event.length);
    //   },
    // );
  }

  void updateSetting(List<String> selectedCategoryFks) {
    if (appStateSettings["watchedCategoriesOnBudget"]
            [widget.budget.budgetPk.toString()] ==
        null) {
      appStateSettings["watchedCategoriesOnBudget"]
          [widget.budget.budgetPk.toString()] = {};
    }
    Map<dynamic, dynamic> newSetting =
        appStateSettings["watchedCategoriesOnBudget"];
    Map<String, dynamic> convertedMap = {};
    newSetting.forEach((key, value) {
      convertedMap[key.toString()] = value;
    });
    convertedMap[widget.budget.budgetPk.toString()] = selectedCategoryFks;
    updateSettings("watchedCategoriesOnBudget", convertedMap,
        pagesNeedingRefresh: [], updateGlobalState: false);
  }

  void openWatchCategoriesBottomSheet() {
    openBottomSheet(
      context,
      PopupFramework(
        title: "select-categories-to-watch".tr(),
        child: Column(
          children: [
            SelectCategory(
              labelIcon: true,
              addButton: false,
              selectedCategories: selectedCategoryFks,
              setSelectedCategories: (List<String>? selectedCategoryFks) {
                setState(() {
                  this.selectedCategoryFks = selectedCategoryFks ?? [];
                  updateSetting(selectedCategoryFks ?? []);
                });
                loadLines(amountLoaded);
              },
              scaleWhenSelected: false,
              categoryFks: widget.budget.categoryFks,
              hideCategoryFks: widget.budget.categoryFksExclude,
              allowRearrange: false,
            ),
            Row(
              children: [
                Expanded(
                  child: Button(
                    expandedLayout: true,
                    label: "clear".tr(),
                    onTap: () {
                      setState(() {
                        selectedCategoryFks = [];
                        updateSetting([]);
                      });
                      popRoute(context);
                    },
                    color: Theme.of(context).colorScheme.tertiaryContainer,
                    textColor:
                        Theme.of(context).colorScheme.onTertiaryContainer,
                  ),
                ),
                SizedBox(width: 13),
                Expanded(
                  child: Button(
                    expandedLayout: true,
                    label: "done".tr(),
                    onTap: () {
                      popRoute(context);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color pageBackgroundColor =
        Theme.of(context).brightness == Brightness.dark &&
                appStateSettings["forceFullDarkBackground"]
            ? Colors.black
            : appStateSettings["materialYou"]
                ? dynamicPastel(context, Theme.of(context).colorScheme.primary,
                    amount: 0.92)
                : Theme.of(context).colorScheme.background;
    double budgetAmount = budgetAmountToPrimaryCurrency(
        Provider.of<AllWallets>(context, listen: true), widget.budget);

    return PageFramework(
      backgroundColor: pageBackgroundColor,
      key: budgetHistoryKey,
      title: "history".tr(),
      subtitle: Text(
        widget.budget.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: EdTexto.corpo(context)
            .copyWith(fontSize: 15, color: cores(context).mu),
      ),
      actions: [
        IconButton(
          tooltip: "watch-categories".tr(),
          onPressed: () {
            openWatchCategoriesBottomSheet();
          },
          padding: EdgeInsetsDirectional.all(15 - 8),
          icon: SelectedIconForIconButton(
            iconData: appStateSettings["outlinedIcons"]
                ? Icons.category_outlined
                : Icons.category_rounded,
            isSelected: selectedCategoryFks.length > 0,
          ),
        ),
        IconButton(
          padding: EdgeInsetsDirectional.all(15),
          tooltip: "edit-budget".tr(),
          onPressed: () {
            pushRoute(
              context,
              AddBudgetPage(
                budget: widget.budget,
                routesToPopAfterDelete: RoutesToPopAfterDelete.All,
              ),
            );
          },
          icon: Icon(
            appStateSettings["outlinedIcons"]
                ? Icons.edit_outlined
                : Icons.edit_rounded,
          ),
        ),
      ],
      subtitleSize: 10,
      subtitleAlignment: AlignmentDirectional.bottomStart,
      dragDownToDismiss: true,
      slivers: [
        SliverStickyHeader(
          header: Transform.translate(
            offset: Offset(0, -1),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  children: [
                    Container(
                      padding: const EdgeInsetsDirectional.symmetric(
                          vertical: 7, horizontal: 0),
                      color: pageBackgroundColor,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(end: 5),
                        child: StreamBuilder<Map<String, TransactionCategory>>(
                            stream: database.watchAllCategoriesMapped(),
                            builder: (context, snapshotCategoriesMapped) {
                              if (snapshotCategoriesMapped.hasData) {
                                return StreamBuilder<List<double?>>(
                                  stream: mergedStreamsBudgetTotal,
                                  builder: (context, snapshot) {
                                    if (snapshot.hasData) {
                                      double maxY = 0.1;
                                      double minY = -0.00000000000001;
                                      List<FlSpot> spots = [];

                                      for (int i = snapshot.data!.length - 1;
                                          i >= 0;
                                          i--) {
                                        if ((snapshot.data![i] ?? 0) *
                                                determineBudgetPolarity(
                                                    widget.budget) <
                                            minY) {
                                          minY = (snapshot.data![i] ?? 0) *
                                              determineBudgetPolarity(
                                                  widget.budget);
                                        }
                                        if ((snapshot.data![i] ?? 0) *
                                                determineBudgetPolarity(
                                                    widget.budget) >
                                            maxY) {
                                          maxY = (snapshot.data![i] ?? 0) *
                                              determineBudgetPolarity(
                                                  widget.budget);
                                        }
                                        spots.add(FlSpot(
                                          snapshot.data!.length -
                                              1 -
                                              i.toDouble(),
                                          (snapshot.data![i] ?? 0).abs() == 0
                                              ? 0.00000000001
                                              : (snapshot.data![i] ?? 0) *
                                                  determineBudgetPolarity(
                                                      widget.budget),
                                        ));
                                      }
                                      // print(minY);
                                      // print(maxY);
                                      return StreamBuilder<List<double?>>(
                                        stream: mergedStreamsCategoriesTotal,
                                        builder: (context,
                                            snapshotMergedStreamsCategoriesTotal) {
                                          Map<String, List<FlSpot>>
                                              categorySpentPoints = {};
                                          if (snapshotMergedStreamsCategoriesTotal
                                                  .hasData &&
                                              (selectedCategoryFks).length >
                                                  0) {
                                            maxY = 0.1;
                                            // separate each into a map of their own
                                            int i =
                                                snapshotMergedStreamsCategoriesTotal
                                                        .data!.length -
                                                    1;
                                            for (int day = 0;
                                                day <
                                                    snapshotMergedStreamsCategoriesTotal
                                                            .data!.length /
                                                        selectedCategoryFks
                                                            .length;
                                                day++) {
                                              for (String categoryFk
                                                  in selectedCategoryFks
                                                      .reversed) {
                                                if (categorySpentPoints[
                                                        categoryFk] ==
                                                    null) {
                                                  categorySpentPoints[
                                                      categoryFk] = [];
                                                }
                                                if (i <
                                                        snapshotMergedStreamsCategoriesTotal
                                                            .data!.length &&
                                                    i >= 0) {
                                                  categorySpentPoints[
                                                          categoryFk]!
                                                      .add(
                                                    FlSpot(
                                                      (snapshotMergedStreamsCategoriesTotal
                                                                  .data!
                                                                  .length -
                                                              day.toDouble() -
                                                              snapshotMergedStreamsCategoriesTotal
                                                                  .data!.length)
                                                          .abs(),
                                                      (snapshotMergedStreamsCategoriesTotal
                                                                              .data?[
                                                                          i] ??
                                                                      0)
                                                                  .abs() ==
                                                              0
                                                          ? 0.00000000001
                                                          : (snapshotMergedStreamsCategoriesTotal
                                                                          .data![
                                                                      i] ??
                                                                  0)
                                                              .abs(),
                                                    ),
                                                  );
                                                  if ((snapshotMergedStreamsCategoriesTotal
                                                                  .data?[i] ??
                                                              0)
                                                          .abs() >
                                                      maxY) {
                                                    maxY =
                                                        (snapshotMergedStreamsCategoriesTotal
                                                                    .data?[i] ??
                                                                0)
                                                            .abs();
                                                  }
                                                }
                                                i--;
                                              }
                                            }
                                          }
                                          // print(categorySpentPoints);
                                          Widget graph = BudgetHistoryLineGraph(
                                            onTouchedIndex: (index) {
                                              // debounce to avoid duplicate key on AnimatedSwitcher
                                              _pastBudgetContainerListStateStateKey
                                                  .currentState
                                                  ?.setTouchedBudgetIndex(
                                                      index);
                                            },
                                            color: cores(context).acc,
                                            dateRanges: dateTimeRanges,
                                            spots: [spots],
                                            horizontalLineAt: budgetAmount,
                                            budget: widget.budget,
                                            extraCategorySpots:
                                                categorySpentPoints,
                                            categoriesMapped:
                                                snapshotCategoriesMapped.data!,
                                            loadAllEvenIfZero:
                                                amountLoadedPressedOnce,
                                            setNoPastRegionsAreZero:
                                                (bool value) {
                                              amountLoadedPressedOnce = true;
                                            },
                                            forceMaxY: maxY,
                                            forceMinYIfPositive: 0,
                                          );
                                          if (getCenteredTitle(
                                              context: context,
                                              backButtonEnabled: true)) {
                                            return ClipRRect(
                                              child: graph,
                                            );
                                          }
                                          return graph;
                                        },
                                      );
                                    } else {
                                      return SizedBox.shrink();
                                    }
                                  },
                                );
                              }
                              return SizedBox.shrink();
                            }),
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(0, -1),
                      child: Container(
                        height: 12,
                        foregroundDecoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              pageBackgroundColor,
                              pageBackgroundColor.withOpacity(0.0),
                            ],
                            begin: AlignmentDirectional.topCenter,
                            end: AlignmentDirectional.bottomCenter,
                            stops: [0.1, 1],
                          ),
                        ),
                      ),
                    ),
                    LoadMorePeriodsButton(
                      onPressed: () {
                        if (amountLoadedPressedOnce == false) {
                          setState(() {
                            amountLoadedPressedOnce = true;
                          });
                        } else {
                          int amountMoreToLoad =
                              getIsFullScreen(context) == false ? 3 : 5;
                          loadLines(amountLoaded + amountMoreToLoad);
                          setState(() {
                            amountLoaded = amountLoaded + amountMoreToLoad;
                          });
                        }
                      },
                    ),
                  ],
                ),
                Transform.translate(
                  offset: Offset(0, -1),
                  child: Container(
                    height: 12,
                    foregroundDecoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          pageBackgroundColor,
                          pageBackgroundColor.withOpacity(0.0),
                        ],
                        begin: AlignmentDirectional.topCenter,
                        end: AlignmentDirectional.bottomCenter,
                        stops: [0.1, 1],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          sliver: MultiSliver(
            children: [
              selectedCategoryFks.length > 0
                  ? SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(bottom: 10),
                        child: StreamBuilder<List<double?>>(
                            stream: mergedStreamsBudgetTotal,
                            builder:
                                (context, snapshotMergedStreamsBudgetTotal) {
                              int totalNonZeroPeriods = 0;
                              for (double? periodTotal
                                  in (snapshotMergedStreamsBudgetTotal.data ??
                                      [])) {
                                if (periodTotal != null && periodTotal != 0) {
                                  totalNonZeroPeriods++;
                                }
                              }

                              return StreamBuilder<
                                  Map<String, TransactionCategory>>(
                                stream: database.watchAllCategoriesMapped(),
                                builder: (context, snapshotCategoriesMapped) {
                                  if (snapshotCategoriesMapped.hasData) {
                                    return StreamBuilder<List<double?>>(
                                      stream: mergedStreamsCategoriesTotal,
                                      builder:
                                          (context, snapshotCategoriesTotal) {
                                        if (snapshotCategoriesTotal.hasData) {
                                          List<Widget> children = [];
                                          Map<String, double> categoryTotals =
                                              {};
                                          for (int period = 0;
                                              period <
                                                  amountLoaded *
                                                      selectedCategoryFks
                                                          .length;
                                              period++) {
                                            int categoryIndex = period %
                                                (selectedCategoryFks).length;
                                            TransactionCategory? category =
                                                snapshotCategoriesMapped.data![
                                                    selectedCategoryFks[
                                                        categoryIndex]];
                                            if (category != null &&
                                                period <
                                                    snapshotCategoriesTotal
                                                        .data!.length) {
                                              categoryTotals[
                                                      category.categoryPk] =
                                                  (categoryTotals[category
                                                              .categoryPk] ??
                                                          0) +
                                                      (snapshotCategoriesTotal
                                                              .data?[period] ??
                                                          0);
                                            }
                                          }
                                          for (String categoryPk
                                              in categoryTotals.keys) {
                                            TransactionCategory? category =
                                                snapshotCategoriesMapped
                                                    .data![categoryPk];
                                            if (category != null) {
                                              children.add(
                                                CategoryAverageSpent(
                                                  category: category,
                                                  amountPeriods:
                                                      totalNonZeroPeriods,
                                                  amountSpent: categoryTotals[
                                                          categoryPk] ??
                                                      0,
                                                  onTap: () {
                                                    openWatchCategoriesBottomSheet();
                                                  },
                                                  isSavingsBudget:
                                                      widget.budget.income,
                                                ),
                                              );
                                            }
                                          }

                                          return Column(
                                            children: children,
                                          );
                                        } else {
                                          return SizedBox.shrink();
                                        }
                                      },
                                    );
                                  } else {
                                    return SizedBox.shrink();
                                  }
                                },
                              );
                            }),
                      ),
                    )
                  : SliverToBoxAdapter(child: SizedBox.shrink()),
              PastBudgetContainerList(
                key: _pastBudgetContainerListStateStateKey,
                budget: widget.budget,
                amountLoaded: amountLoaded,
                setAmountLoaded: (int amountLoaded) {
                  if (amountLoadedPressedOnce == false) {
                    setState(() {
                      amountLoadedPressedOnce = true;
                    });
                  } else {
                    setState(() {
                      this.amountLoaded = amountLoaded;
                    });
                  }
                },
                loadLines: (amountLoaded) {
                  if (amountLoadedPressedOnce == false) {
                    // This is set insetAmountLoaded
                  } else {
                    loadLines(amountLoaded);
                    Future.delayed(Duration(milliseconds: 150), () {
                      budgetHistoryKey.currentState!
                          .scrollToBottom(duration: 4000);
                    });
                  }
                },
                backgroundColor: pageBackgroundColor,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class LoadMorePeriodsButton extends StatelessWidget {
  const LoadMorePeriodsButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return PositionedDirectional(
      end: 0,
      top: 0,
      child: Transform.translate(
        offset: Offset(2, -2),
        child: Tooltip(
          message: "view-more".tr(),
          child: IconButton(
            icon: Icon(
              appStateSettings["outlinedIcons"]
                  ? Icons.history_outlined
                  : Icons.history_rounded,
              size: 22,
              color: cores(context).mu,
            ),
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }
}

class PastBudgetContainerList extends StatefulWidget {
  const PastBudgetContainerList({
    required this.budget,
    required this.amountLoaded,
    required this.setAmountLoaded,
    required this.loadLines,
    required this.backgroundColor,
    super.key,
  });

  final Budget budget;
  final int amountLoaded;
  final Function(int) setAmountLoaded;
  final Function(int amountLoaded) loadLines;
  final Color backgroundColor;

  @override
  State<PastBudgetContainerList> createState() =>
      _PastBudgetContainerListState();
}

class _PastBudgetContainerListState extends State<PastBudgetContainerList> {
  int? touchedBudgetIndex = null;

  final _debouncer = Debouncer(milliseconds: 50);

  setTouchedBudgetIndex(int? touchedBudgetIndexPassed) {
    _debouncer.run(() {
      setState(() {
        touchedBudgetIndex = touchedBudgetIndexPassed;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MultiSliver(
      children: [
        getIsFullScreen(context) == false
            ? SliverPadding(
                padding: EdgeInsetsDirectional.only(
                  bottom: 15,
                  start: getPlatform() == PlatformOS.isIOS ? 0 : 13,
                  end: getPlatform() == PlatformOS.isIOS ? 0 : 13,
                ),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      DateTime datePast = getDatePastToDetermineBudgetDate(
                          index, widget.budget);
                      return FadeIn(
                        duration: Duration(milliseconds: 400),
                        child: AnimatedContainer(
                          duration: Duration(milliseconds: 200),
                          padding: getPlatform() == PlatformOS.isIOS
                              ? EdgeInsetsDirectional.zero
                              : EdgeInsetsDirectional.only(
                                  bottom: touchedBudgetIndex != null ||
                                          index == widget.amountLoaded - 1
                                      ? 0
                                      : 10,
                                ),
                          child: AnimatedExpanded(
                            expand: touchedBudgetIndex == null ||
                                widget.amountLoaded - touchedBudgetIndex! - 1 ==
                                    index,
                            child: AddTopAndBottomBorderIfIOS(
                              enabled: getPlatform() == PlatformOS.isIOS,
                              child: PastBudgetContainer(
                                budget: widget.budget,
                                smallBudgetContainer: true,
                                showTodayForSmallBudget:
                                    (index == 0 ? true : false),
                                dateForRange: datePast,
                                backgroundColor: widget.backgroundColor,
                                dateForRangeIndex: index,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    childCount: widget.amountLoaded, //snapshot.data?.length
                  ),
                ),
              )
            : SliverPadding(
                padding: getPlatform() == PlatformOS.isIOS
                    ? EdgeInsetsDirectional.zero
                    : EdgeInsetsDirectional.only(
                        bottom: 15, start: 13, end: 13),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 600,
                    mainAxisExtent: 96,
                    crossAxisSpacing:
                        getPlatform() == PlatformOS.isIOS ? 0 : 10,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      DateTime datePast = getDatePastToDetermineBudgetDate(
                          index, widget.budget);
                      return FadeIn(
                        duration: Duration(milliseconds: 400),
                        child: AnimatedOpacity(
                          duration: Duration(milliseconds: 200),
                          opacity: touchedBudgetIndex == null ||
                                  widget.amountLoaded -
                                          touchedBudgetIndex! -
                                          1 ==
                                      index
                              ? 1
                              : 0.5,
                          child: Container(
                            child: AddTopAndBottomBorderIfIOS(
                              enabled: getPlatform() == PlatformOS.isIOS,
                              child: Padding(
                                padding: getPlatform() == PlatformOS.isIOS
                                    ? EdgeInsetsDirectional.symmetric(
                                        vertical: 13.0 / 2)
                                    : EdgeInsetsDirectional.only(bottom: 13.0),
                                child: PastBudgetContainer(
                                  budget: widget.budget,
                                  smallBudgetContainer: true,
                                  showTodayForSmallBudget:
                                      (index == 0 ? true : false),
                                  dateForRange: datePast,
                                  backgroundColor: widget.backgroundColor,
                                  dateForRangeIndex: index,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    childCount: widget.amountLoaded,
                  ),
                ),
              ),
        SliverToBoxAdapter(
          child: Center(
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                bottom: 30,
                top: getIsFullScreen(context) == true &&
                        getPlatform() == PlatformOS.isIOS
                    ? 10
                    : 0,
              ),
              child: LowKeyButton(
                onTap: () {
                  int amountMoreToLoad =
                      getIsFullScreen(context) == false ? 3 : 5;
                  widget.loadLines(widget.amountLoaded + amountMoreToLoad);
                  widget
                      .setAmountLoaded(widget.amountLoaded + amountMoreToLoad);
                },
                text: "view-more".tr(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class PastBudgetContainer extends StatelessWidget {
  PastBudgetContainer({
    Key? key,
    required this.budget,
    this.smallBudgetContainer = false,
    this.showTodayForSmallBudget = true,
    this.dateForRange,
    required this.backgroundColor,
    required this.dateForRangeIndex,
  }) : super(key: key);

  final Budget budget;
  final bool smallBudgetContainer;
  final bool showTodayForSmallBudget;
  final DateTime? dateForRange;
  final Color backgroundColor;
  final int dateForRangeIndex;

  @override
  Widget build(BuildContext context) {
    final carteiras = Provider.of<AllWallets>(context, listen: true);
    final limite = budgetAmountToPrimaryCurrency(carteiras, budget);
    final data = dateForRange ?? DateTime.now();
    final periodo = getBudgetDate(budget, data);
    return StreamBuilder<List<CategoryWithTotal>>(
      stream: database.watchTotalSpentInEachCategoryInTimeRangeFromCategories(
        allWallets: carteiras,
        start: periodo.start,
        end: periodo.end,
        categoryFks: budget.categoryFks,
        categoryFksExclude: budget.categoryFksExclude,
        budgetTransactionFilters: budget.budgetTransactionFilters,
        memberTransactionFilters: budget.memberTransactionFilters,
        onlyShowTransactionsBelongingToBudgetPk:
            budget.sharedKey != null || budget.addedTransactionsOnly == true
                ? budget.budgetPk
                : null,
        budget: budget,
      ),
      builder: (context, snapshot) {
        final dados = snapshot.data;
        if (dados == null) return const SizedBox(height: 83);
        final gasto = absoluteZero(dados.fold<double>(0, (s, c) => s + c.total) *
            determineBudgetPolarity(budget));
        return LinhaCicloOrcamento(
          titulo: getPercentBetweenDates(periodo, DateTime.now()) <= 100
              ? "current-period".tr()
              : textoPeriodoOrcamento(periodo,
                  ano: periodo.start.year != DateTime.now().year),
          gasto: gasto,
          limite: limite,
          renda: budget.income,
          onTap: () => pushRoute(
            context,
            BudgetPage(
              budgetPk: budget.budgetPk,
              dateForRange: data,
              dateForRangeIndex: dateForRangeIndex,
              openedFromHistory: true,
            ),
          ),
          onLongPress: () => pushRoute(
            context,
            AddBudgetPage(
              budget: budget,
              routesToPopAfterDelete: RoutesToPopAfterDelete.All,
            ),
          ),
        );
      },
    );
  }
}

/// Um ciclo do histórico: período, percentual, medidor e "Gasto X de Y".
/// Recebe os totais prontos (não lê o banco).
class LinhaCicloOrcamento extends StatelessWidget {
  const LinhaCicloOrcamento({
    super.key,
    required this.titulo,
    required this.gasto,
    required this.limite,
    this.renda = false,
    this.onTap,
    this.onLongPress,
  });

  final String titulo;
  final double gasto, limite;
  final bool renda;
  final VoidCallback? onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final carteiras = Provider.of<AllWallets>(context);
    final fracao = limite <= 0 ? 0.0 : gasto / limite;
    final passou = !renda && fracao > 1;
    final rotulo = EdTexto.rotulo(context);
    final cartao = Container(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 14),
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
              Expanded(
                child: Text(titulo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context)
                        .copyWith(fontSize: 15, fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 8),
              Text(
                convertToPercent(fracao * 100,
                    numberDecimals: 0, useLessThanZero: true),
                style: EdTexto.corpo(context).copyWith(
                    fontWeight: FontWeight.w600,
                    color: passou ? getColor(context, "overspentAmount") : null),
              ),
            ],
          ),
          const SizedBox(height: 10),
          MedidorEditorial(fracao: fracao, alerta: passou),
          const SizedBox(height: 8),
          Text(
            '${renda ? 'Guardado' : 'Gasto'} ${convertToMoney(carteiras, gasto)} '
            'de ${convertToMoney(carteiras, limite)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: rotulo,
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

class CategoryAverageSpent extends StatelessWidget {
  const CategoryAverageSpent({
    required this.category,
    required this.amountPeriods,
    required this.amountSpent,
    required this.onTap,
    required this.isSavingsBudget,
    super.key,
  });
  final TransactionCategory category;
  final int amountPeriods;
  final double amountSpent;
  final VoidCallback onTap;
  final bool isSavingsBudget;

  @override
  Widget build(BuildContext context) {
    return Tappable(
      onLongPress: () {
        pushRoute(
          context,
          AddCategoryPage(
            category: category,
            routesToPopAfterDelete: RoutesToPopAfterDelete.One,
          ),
        );
      },
      onTap: onTap,
      color: Colors.transparent,
      child: Padding(
        padding: EdgeInsetsDirectional.symmetric(
          horizontal: getHorizontalPaddingConstrained(context),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 16, vertical: 4),
          child: Row(
            children: [
              CategoryIcon(
                category: category,
                size: 30,
                margin: EdgeInsetsDirectional.zero,
                borderRadius: 1000,
              ),
              SizedBox(
                width: 12,
              ),
              Expanded(
                child: Container(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextFont(
                        text: category.name,
                        fontSize: 15,
                        maxLines: 1,
                      ),
                      SizedBox(
                        height: 1,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: CountNumber(
                              count: amountPeriods == 0
                                  ? 0
                                  : (amountSpent / amountPeriods).abs(),
                              duration: Duration(milliseconds: 400),
                              initialCount: amountPeriods == 0
                                  ? 0
                                  : (amountSpent / amountPeriods).abs(),
                              textBuilder: (number) {
                                return TextFont(
                                  text: convertToMoney(
                                          Provider.of<AllWallets>(context),
                                          number,
                                          finalNumber: amountPeriods == 0
                                              ? 0
                                              : (amountSpent / amountPeriods)
                                                  .abs()) +
                                      " " +
                                      (isSavingsBudget
                                          ? "average-saved".tr().toLowerCase()
                                          : "average-spent".tr().toLowerCase()),
                                  fontSize: 14,
                                  textColor: getColor(context, "textLight"),
                                );
                              },
                            ),
                          ),
                          // TextFont(
                          //   text: transactionCount.toString() +
                          //       " " +
                          //       (transactionCount == 1
                          //           ? "transaction".tr().toLowerCase()
                          //           : "transactions".tr().toLowerCase()),
                          //   fontSize: 13,
                          //   textColor: selected
                          //       ? getColor(context, "black").withOpacity(0.4)
                          //       : getColor(context, "textLight"),
                          // ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(width: 10),
              CountNumber(
                count: amountSpent.abs(),
                duration: Duration(milliseconds: 400),
                initialCount: amountSpent.abs(),
                textBuilder: (number) {
                  return TextFont(
                    fontWeight: FontWeight.w600,
                    text: convertToMoney(
                        Provider.of<AllWallets>(context), number,
                        finalNumber: amountSpent.abs()),
                    fontSize: 16,
                    textColor: getColor(context, "black"),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
