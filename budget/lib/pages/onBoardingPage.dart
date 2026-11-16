import 'package:budget/colors.dart';
import 'package:budget/database/generatePreviewData.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/meuBancoPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/languageMap.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/accountAndBackup.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/currencyPicker.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:budget/functions.dart';
import 'package:budget/database/initializeDefaultDatabase.dart';

class OnBoardingPage extends StatelessWidget {
  const OnBoardingPage({
    Key? key,
    this.popNavigationWhenDone = false,
    this.showPreviewDemoButton = true,
  }) : super(key: key);

  final bool popNavigationWhenDone;
  final bool showPreviewDemoButton;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        resizeToAvoidBottomInset: false,
        body: OnBoardingPageBody(
            popNavigationWhenDone: popNavigationWhenDone,
            showPreviewDemoButton: showPreviewDemoButton));
  }
}

class OnBoardingPageBody extends StatefulWidget {
  const OnBoardingPageBody({
    Key? key,
    this.popNavigationWhenDone = false,
    this.showPreviewDemoButton = true,
  }) : super(key: key);
  final bool popNavigationWhenDone;
  final bool showPreviewDemoButton;

  @override
  State<OnBoardingPageBody> createState() => OnBoardingPageBodyState();
}

/// Primeiro uso em uma tela: conectar o banco (Meu Banco) ou usar à mão.
/// A moeda e o login do Google ficam como links discretos abaixo.
class OnBoardingPageBodyState extends State<OnBoardingPageBody> {
  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, () async {
      // Depois da interface (e das traduções): cria a conta padrão.
      await initializeDefaultDatabase();
    });
  }

  Future<void> concluir({bool generatePreview = false, Widget? abrir}) async {
    if (generatePreview) {
      openLoadingPopup(context);
      await generatePreviewData();
      popRoute(context);
    }
    if (widget.popNavigationWhenDone) {
      popRoute(context);
    } else {
      await updateSettings("hasOnboarded", true,
          pagesNeedingRefresh: [], updateGlobalState: true);
    }
    if (abrir == null) return;
    // Depois do rebuild que troca o primeiro uso pelo app; antes disso a rota cairia sob a nova home.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = navigatorKey.currentContext;
      if (c != null) pushRoute(c, abrir);
    });
  }

  Future<void> entrarComGoogle() async {
    loadingIndeterminateKey.currentState?.setVisibility(true);
    openLoadingPopupTryCatch(
      () async {
        await signInGoogle(
          context: context,
          waitForCompletion: false,
          next: () {},
        );
        if (appStateSettings["username"] == "" && googleUser != null) {
          updateSettings("username", googleUser?.displayName ?? "",
              pagesNeedingRefresh: [0], updateGlobalState: false);
        }
        // Liga as funções de nuvem: o backup sincronizado volta sozinho.
        entireAppLoaded = true;
        await runAllCloudFunctions(
          context,
          forceSignIn: true,
        );
        concluir();
        loadingIndeterminateKey.currentState?.setVisibility(false);
      },
      onError: (e) {
        print("Error signing in: " + e.toString());
        loadingIndeterminateKey.currentState?.setVisibility(false);
      },
    );
  }

  void trocarMoeda(TransactionWallet primaryWallet) {
    openBottomSheet(
      context,
      SizedBox.shrink(),
      customBuilder: (context2, scrollController, sheetState) {
        return CustomScrollView(
          controller: scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: PopupFramework(
                title: "select-primary-currency".tr(),
                subtitle: "select-primary-currency-description".tr(),
                child: SizedBox.shrink(),
                bottomSafeAreaExtraPadding: false,
              ),
            ),
            CurrencyPicker(
              showExchangeRateInfoNotice: false,
              onSelected: (selectedCurrency) {
                popRoute(context);
                database.createOrUpdateWallet(
                    primaryWallet.copyWith(currency: Value(selectedCurrency)));
              },
              initialCurrency: primaryWallet.currency,
              unSelectedColor: appStateSettings["materialYou"]
                  ? null
                  : getColor(context, "canvasContainer"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final itens = <Widget>[
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image(
          image: AssetImage("assets/icon/icon-small.png"),
          height: 64,
        ),
      ),
      SizedBox(height: 24),
      Text(globalAppName, style: EdTexto.h1(context)),
      SizedBox(height: 8),
      Text(
        "Conecte seu banco para as transações chegarem sozinhas, ou anote tudo à mão.",
        style: EdTexto.corpo(context).copyWith(color: e.mu, height: 1.4),
      ),
      SizedBox(height: 32),
      Button(
        label: "Conectar banco",
        expandedLayout: true,
        onTap: () => concluir(abrir: const MeuBancoPage()),
      ),
      SizedBox(height: 10),
      Button(
        label: "Usar sem banco",
        expandedLayout: true,
        color: e.chip,
        textColor: e.tx,
        onTap: () => concluir(),
      ),
      SizedBox(height: 20),
      StreamBuilder<AllWallets>(
        stream: database.watchAllWalletsIndexed(),
        builder: (context, snapshot) {
          TransactionWallet? primaryWallet =
              snapshot.data?.indexedByPk[appStateSettings["selectedWalletPk"]];
          if (primaryWallet == null) return SizedBox.shrink();
          return _Link(
            texto: "Moeda: " +
                (primaryWallet.currency ?? "").toUpperCase() +
                " · Trocar",
            onTap: () => trocarMoeda(primaryWallet),
          );
        },
      ),
      if (getPlatform() != PlatformOS.isIOS)
        _Link(texto: "Restaurar backup do Google", onTap: entrarComGoogle),
      if (widget.showPreviewDemoButton)
        PreviewDemoButton(nextNavigation: concluir),
    ];
    return SafeArea(
      child: Stack(
        children: [
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 400),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < itens.length; i++)
                      EntradaSuave(indice: i, child: itens[i]),
                  ],
                ),
              ),
            ),
          ),
          if (widget.popNavigationWhenDone)
            PositionedDirectional(
              top: 4,
              start: 4,
              child: IconButton(
                tooltip: "Fechar",
                icon: Icon(Icons.close_rounded, color: e.tx),
                onPressed: () => popRoute(context),
              ),
            ),
        ],
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({required this.texto, required this.onTap});
  final String texto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: cores(context).mu,
        padding: const EdgeInsetsDirectional.symmetric(vertical: 12),
        minimumSize: const Size(0, 44),
        alignment: AlignmentDirectional.centerStart,
        textStyle: EdTexto.corpo(context),
      ),
      child: Text(texto),
    );
  }
}
