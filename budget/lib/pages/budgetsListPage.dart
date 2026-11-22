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
import 'package:budget/widgets/sugestaoLimites.dart';
import 'package:budget/struct/mbSync/orcamentos.dart' show mbOrcamentoGeralPk;
import 'package:sliver_tools/sliver_tools.dart';

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
      backgroundColor: fundoBento(context),
      appBarBackgroundColor: fundoBento(context),
      appBarBackgroundColorStart: fundoBento(context),
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
        StreamBuilder<List<Budget>>(
          stream: database.watchAllBudgets(hideArchived: true),
          builder: (context, snapshot) {
            final orcamentos = snapshot.data;
            // Só na aba; a página empilhada (pelo Mais) mostra só a lista.
            final analise = widget.enableBackButton
                ? null
                : const SliverToBoxAdapter(
                key: ValueKey('analise-orcamentos'), child: AnaliseOrcamentos());
            if (orcamentos == null) {
              return MultiSliver(children: [if (analise != null) analise]);
            }
            if (orcamentos.isEmpty) {
              // "Criar orçamento" vem antes da análise: abaixo dela ficava fora da tela no celular.
              return MultiSliver(children: [
                const SliverToBoxAdapter(child: SemOrcamentos()),
                if (analise != null) analise,
              ]);
            }
            // O Geral abre a tela; sem ele, o primeiro da ordem do usuário.
            final principal = orcamentos
                    .where((b) => b.budgetPk == mbOrcamentoGeralPk)
                    .firstOrNull ??
                orcamentos.first;
            final outros = orcamentos.where((b) => b != principal).toList();
            Widget item(Budget b, {bool compacto = true}) => EntradaSuave(
                  key: ValueKey(b.budgetPk),
                  indice: orcamentos.indexOf(b),
                  animar: DateTime.now().difference(_aberta) <
                      const Duration(milliseconds: 600),
                  child: BudgetContainer(budget: b, compacto: compacto),
                );
            List<Widget> grade(String titulo, bool renda) {
              final filhos = [
                for (final b in outros)
                  if (b.income == renda) item(b)
              ];
              return filhos.isEmpty
                  ? const []
                  : [TituloBento(titulo), GradeBento(filhos: filhos)];
            }

            final paraLimites = orcamentoParaSugerirLimites(orcamentos);
            return MultiSliver(children: [
              SliverToBoxAdapter(
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  child: ConstrainedBox(
                    // Computador: mesma largura máxima da análise.
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(13, 4, 13, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          item(principal, compacto: false),
                          ...grade('Limites', false),
                          ...grade('Para guardar', true),
                          if (paraLimites != null) ...[
                            const SizedBox(height: 10),
                            AtalhoSugerirLimites(
                                onTap: () =>
                                    abrirSugestaoLimites(context, paraLimites)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (analise != null) analise,
            ]);
          },
        ),
        // O "+" da barra fica sobre o fim da lista.
        SliverToBoxAdapter(
          child: SizedBox(height: mbFolgaFab),
        ),
      ],
    );
  }
}

/// Orçamento que recebe os limites sugeridos: o Geral; sem ele, o primeiro de gasto com "todas as transações".
Budget? orcamentoParaSugerirLimites(List<Budget> orcamentos) {
  final aptos = orcamentos
      .where((b) => !b.income && !b.addedTransactionsOnly && b.sharedKey == null)
      .toList();
  return aptos.where((b) => b.budgetPk == mbOrcamentoGeralPk).firstOrNull ??
      aptos.firstOrNull;
}

/// Atalho do fim da lista: abre a sugestão de limites por categoria.
class AtalhoSugerirLimites extends StatelessWidget {
  const AtalhoSugerirLimites({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Semantics(
      button: true,
      child: ToqueEscala(
        onTap: onTap,
        child: CartaoBento(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 14),
          child: Row(children: [
            Icon(Icons.tune_rounded, size: 20, color: e.acc),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Sugerir limites por categoria',
                      style: EdTexto.corpo(context)
                          .copyWith(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text('Média dos últimos 3 ciclos; você revisa antes de salvar.',
                      style: EdTexto.rotulo(context)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: e.mu),
          ]),
        ),
      ),
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
