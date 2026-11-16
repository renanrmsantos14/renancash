import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/analiseOrcamentos.dart';
import 'package:budget/pages/editBudgetPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/budgetContainer.dart';
import 'package:budget/widgets/navigationSidebar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart'
    hide SliverReorderableList, ReorderableDelayedDragStartListener;
import 'package:budget/struct/editorial.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/editorial/movimento.dart';

class BudgetsListPage extends StatefulWidget {
  const BudgetsListPage({required this.enableBackButton, Key? key})
      : super(key: key);
  final bool enableBackButton;

  @override
  State<BudgetsListPage> createState() => BudgetsListPageState();
}

class BudgetsListPageState extends State<BudgetsListPage> {
  GlobalKey<PageFrameworkState> pageState = GlobalKey();
  // Entrada dos cartões só logo após abrir (rolar de volta não reanima).
  final _aberta = DateTime.now();

  void refreshState() {
    setState(() {});
  }

  void scrollToTop() {
    pageState.currentState?.scrollToTop();
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      key: pageState,
      title: "budgets".tr(),
      backButton: widget.enableBackButton,
      dragDownToDismiss: widget.enableBackButton,
      horizontalPaddingConstrained: enableDoubleColumn(context) == false,
      actions: [
        IconButton(
          padding: EdgeInsetsDirectional.all(15),
          tooltip: "edit-budgets".tr(),
          onPressed: () {
            pushRoute(
              context,
              EditBudgetPage(),
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
            tooltip: "add-budget".tr(),
            onPressed: () {
              pushRoute(
                context,
                AddBudgetPage(
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
        // Só na aba; a página empilhada (pelo Mais) mostra só a lista.
        if (!widget.enableBackButton)
          const SliverToBoxAdapter(child: AnaliseOrcamentos()),
        StreamBuilder<List<Budget>>(
          stream: database.watchAllBudgets(hideArchived: true),
          builder: (context, snapshot) {
            final orcamentos = snapshot.data;
            if (orcamentos == null) return const SliverToBoxAdapter();
            if (orcamentos.isEmpty) {
              return const SliverToBoxAdapter(child: SemOrcamentos());
            }
            Widget item(int i) => EntradaSuave(
                  key: ValueKey(orcamentos[i].budgetPk),
                  indice: i,
                  animar: DateTime.now().difference(_aberta) <
                      const Duration(milliseconds: 600),
                  child: BudgetContainer(budget: orcamentos[i]),
                );
            return SliverPadding(
              padding:
                  const EdgeInsetsDirectional.symmetric(vertical: 4, horizontal: 13),
              sliver: enableDoubleColumn(context)
                  ? SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 600,
                        mainAxisExtent: 150,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => item(i),
                        childCount: orcamentos.length,
                      ),
                    )
                  : SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => Padding(
                          padding: const EdgeInsetsDirectional.only(bottom: 12),
                          child: item(i),
                        ),
                        childCount: orcamentos.length,
                      ),
                    ),
            );
          },
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: 50),
        ),
      ],
    );
  }
}

/// Lista vazia: uma frase e uma ação.
class SemOrcamentos extends StatelessWidget {
  const SemOrcamentos({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(13, 24, 13, 0),
      child: Column(
        children: [
          Icon(Icons.donut_large_rounded, size: 32, color: cores(context).mu),
          const SizedBox(height: 12),
          Text('Nenhum orçamento ainda',
              style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text('Defina um limite e acompanhe quanto resta no ciclo.',
              textAlign: TextAlign.center, style: EdTexto.rotulo(context)),
          const SizedBox(height: 16),
          Button(
            label: 'Criar orçamento',
            onTap: () => pushRoute(
              context,
              AddBudgetPage(
                  routesToPopAfterDelete: RoutesToPopAfterDelete.PreventDelete),
            ),
          ),
        ],
      ),
    );
  }
}
