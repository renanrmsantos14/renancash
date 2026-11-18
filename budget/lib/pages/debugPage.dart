import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/main.dart';
import 'package:budget/pages/aboutPage.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/logging.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/dropdownSelect.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/notificationsSettings.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/database/generatePreviewData.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/util/appLinks.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' hide TextInput;
import 'package:universal_html/html.dart' as html;
import 'package:budget/struct/randomConstants.dart';
import 'package:budget/widgets/sliderSelector.dart';

class DebugPage extends StatelessWidget {
  const DebugPage({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return PageFramework(
      dragDownToDismiss: true,
      horizontalPaddingConstrained: true,
      title: "Depuração",
      actions: [
        CustomPopupMenuButton(
          showButtons: true,
          keepOutFirst: true,
          items: [
            DropdownItemMenu(
              id: "share-logs",
              label: "logs",
              icon: Icons.list,
              action: () {
                pushRoute(context, LogPage());
              },
            ),
          ],
        ),
      ],
      subtitle: TextFont(
        text: "Opções de teste. Use por sua conta e risco.",
        textColor: getColor(context, "expenseAmount"),
        fontWeight: FontWeight.w500,
        fontSize: 13,
        maxLines: 5,
      ),
      subtitleAlignment: AlignmentDirectional.bottomStart,
      subtitleSize: 10,
      listWidgets: [
        SettingsContainerSwitch(
          title: "Usar gastos acumulados",
          description: "Nos gráficos de linha de despesas",
          onSwitched: (value) {
            updateSettings("showCumulativeSpending", value,
                pagesNeedingRefresh: [0, 3], updateGlobalState: false);
            // if (value == true) {
            //   updateSettings("removeZeroTransactionEntries", false,
            //       pagesNeedingRefresh: [0], updateGlobalState: false);
            // }
          },
          initialValue: appStateSettings["showCumulativeSpending"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.show_chart_outlined
              : Icons.show_chart_rounded,
        ),
        SettingsContainerSwitch(
          title: "Ocultar lançamentos zerados",
          description: "Nos gráficos de linha de despesas",
          onSwitched: (value) {
            updateSettings("removeZeroTransactionEntries", value,
                pagesNeedingRefresh: [0], updateGlobalState: false);
          },
          initialValue:
              appStateSettings["removeZeroTransactionEntries"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.money_off_outlined
              : Icons.money_off_rounded,
        ),
        SettingsContainerSwitch(
          title: "Começar gastos em 0",
          description: "Nos gráficos de linha de despesas",
          onSwitched: (value) {
            updateSettings("ignorePastAmountSpent", value,
                pagesNeedingRefresh: [0, 3], updateGlobalState: false);
            // if (value == true) {
            //   updateSettings("removeZeroTransactionEntries", false,
            //       pagesNeedingRefresh: [0], updateGlobalState: false);
            // }
          },
          initialValue: appStateSettings["ignorePastAmountSpent"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.add_chart_outlined
              : Icons.add_chart_rounded,
        ),
        SettingsContainerSwitch(
          title: "Mostrar trajetória de gastos passados",
          onSwitched: (value) {
            updateSettings("showPastSpendingTrajectory", value,
                pagesNeedingRefresh: [0], updateGlobalState: false);
          },
          initialValue: appStateSettings["showPastSpendingTrajectory"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.blur_circular_outlined
              : Icons.blur_circular_rounded,
        ),
        SettingsContainerSwitch(
          title: "Compensar rotação do gráfico circular",
          description:
              "Alinha o anel circular com o gráfico de pizza por categoria.",
          onSwitched: (value) {
            updateSettings("circularProgressRotation", value,
                updateGlobalState: true);
            // if (value == true) {
            //   updateSettings("removeZeroTransactionEntries", false,
            //       pagesNeedingRefresh: [0], updateGlobalState: false);
            // }
          },
          initialValue: appStateSettings["circularProgressRotation"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.rotate_90_degrees_cw_outlined
              : Icons.rotate_90_degrees_cw_rounded,
        ),
        SettingsContainerSwitch(
          title: "Lançamentos expandidos",
          description: "Mostrar mais informações em cada linha de lançamento",
          onSwitched: (value) {
            updateSettings("nonCompactTransactions", value,
                updateGlobalState: true, pagesNeedingRefresh: [0, 1, 2, 3]);
          },
          initialValue: appStateSettings["nonCompactTransactions"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.web_asset_outlined
              : Icons.web_asset_rounded,
        ),
        SettingsContainerSwitch(
          title: "Limitar quantidade de lançamentos carregados",
          description:
              "Carrega poucos lançamentos inicialmente e exibe um botão para ver todos no final da página.",
          onSwitched: (value) {
            updateSettings("restrictAmountOfInitiallyLoadedTransactions", value,
                updateGlobalState: true);
          },
          initialValue:
              appStateSettings["restrictAmountOfInitiallyLoadedTransactions"] ==
                  true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.sort_outlined
              : Icons.sort_rounded,
        ),
        SettingsContainerSwitch(
          title: "Suavizar corte de títulos longos",
          description:
              "Aplica degradê no texto longo em vez de reticências nos lançamentos",
          onSwitched: (value) {
            updateSettings("fadeTransactionNameOverflows", value,
                updateGlobalState: true);
          },
          initialValue:
              appStateSettings["fadeTransactionNameOverflows"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.more_outlined
              : Icons.more_rounded,
        ),
        SettingsContainerSwitch(
          title: "Mostrar botões de ajuda e perguntas frequentes",
          onSwitched: (value) {
            updateSettings("showFAQAndHelpLink", value,
                updateGlobalState: false, pagesNeedingRefresh: [3]);
          },
          initialValue: appStateSettings["showFAQAndHelpLink"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.live_help_outlined
              : Icons.live_help_rounded,
        ),
        SettingsContainerSwitch(
          title: "Mostrar textos explicativos extras",
          onSwitched: (value) {
            updateSettings("showExtraInfoText", value,
                updateGlobalState: false, pagesNeedingRefresh: [3]);
          },
          initialValue: appStateSettings["showExtraInfoText"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.info_outline
              : Icons.info_rounded,
        ),
        SettingsContainerSwitch(
          title: "battery-saver".tr(),
          description: "battery-saver-description".tr(),
          onSwitched: (value) {
            updateSettings("batterySaver", value,
                updateGlobalState: true, pagesNeedingRefresh: [0, 1, 2, 3]);
          },
          initialValue: appStateSettings["batterySaver"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.battery_charging_full_outlined
              : Icons.battery_charging_full_rounded,
        ),
        SettingsContainerSwitch(
          onSwitched: (value) {
            updateSettings("savingHapticFeedback", value,
                pagesNeedingRefresh: [], updateGlobalState: false);
          },
          initialValue: appStateSettings["savingHapticFeedback"] == true,
          title: "Vibração ao salvar",
          description: "Vibrar ao salvar alterações ou adicionar itens",
          icon: appStateSettings["outlinedIcons"]
              ? Icons.vibration_outlined
              : Icons.vibration_rounded,
        ),
        SettingsContainerSwitch(
          onSwitched: (value) {
            updateSettings("closeNavigationHapticFeedback", value,
                pagesNeedingRefresh: [], updateGlobalState: false);
          },
          initialValue:
              appStateSettings["closeNavigationHapticFeedback"] == true,
          title: "Vibração ao fechar tela",
          description: "Vibrar ao voltar ou fechar uma tela",
          icon: appStateSettings["outlinedIcons"]
              ? Icons.vibration_outlined
              : Icons.vibration_rounded,
        ),
        SettingsContainerSwitch(
          onSwitched: (value) {
            updateSettings("tabNavigationHapticFeedback", value,
                pagesNeedingRefresh: [], updateGlobalState: false);
          },
          initialValue: appStateSettings["tabNavigationHapticFeedback"] == true,
          title: "Vibração ao trocar de aba",
          description: "Vibrar ao navegar entre abas",
          icon: appStateSettings["outlinedIcons"]
              ? Icons.vibration_outlined
              : Icons.vibration_rounded,
        ),
        SettingsContainerSwitch(
          onSwitched: (value) async {
            updateSettings("colorTintCategoryIcon", value,
                updateGlobalState: true);
          },
          title: "Tingir ícones de categoria",
          description:
              "Colorir ícones de categoria conforme a cor do tema (requer Material You)",
          initialValue: appStateSettings["colorTintCategoryIcon"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.category_outlined
              : Icons.category_rounded,
        ),
        SettingsContainerSwitch(
          onSwitched: (value) async {
            updateSettings("accountColorfulAmountsWithArrows", value,
                updateGlobalState: true);
          },
          title: "Totais de conta coloridos com seta",
          description:
              "Usar seta e cor para indicar o sinal do saldo das contas no Início",
          initialValue:
              appStateSettings["accountColorfulAmountsWithArrows"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.swap_vert_outlined
              : Icons.swap_vert_rounded,
        ),
        SettingsContainerSwitch(
          title: "Totais líquidos coloridos",
          description:
              "Totais negativos em vermelho e positivos em verde",
          onSwitched: (value) {
            updateSettings("netTotalsColorful", value, updateGlobalState: true);
          },
          initialValue: appStateSettings["netTotalsColorful"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.format_color_text_outlined
              : Icons.format_color_text_rounded,
        ),
        SettingsContainerSwitch(
          enableBorderRadius: true,
          onSwitched: (value) {
            updateSettings("enableGoogleLoginFlyIn", value,
                pagesNeedingRefresh: [], updateGlobalState: false);
          },
          initialValue: appStateSettings["enableGoogleLoginFlyIn"] == true,
          title: "Aviso de login com Google",
          description:
              "Mostrar aviso de login com Google em tela cheia se desconectado",
          icon: Icons.g_mobiledata,
        ),
        SettingsContainerSwitch(
          onSwitched: (value) async {
            updateSettings("forceAutoLogin", value, updateGlobalState: false);
          },
          title: "Forçar login automático",
          description: "Forçar janela de login na web ou quando a sincronização estiver desativada.",
          initialValue: appStateSettings["forceAutoLogin"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.input_outlined
              : Icons.input_rounded,
        ),
        SettingsContainerSwitch(
          enableBorderRadius: true,
          onSwitched: (value) {
            updateSettings("syncEveryChange", value,
                pagesNeedingRefresh: [], updateGlobalState: false);
          },
          initialValue: appStateSettings["syncEveryChange"] == true,
          title: "sync-every-change".tr(),
          descriptionWithValue: (value) {
            return value
                ? "sync-every-change-description1".tr()
                : "sync-every-change-description2".tr();
          },
          icon: appStateSettings["outlinedIcons"]
              ? Icons.sync_outlined
              : Icons.sync_rounded,
        ),
        SettingsContainerSwitch(
          title: "Emular iOS",
          description: "Ativa comportamento de rolagem e ícones do iOS",
          onSwitched: (value) {
            if (value == true) {
              // Disable iOS font for now... Avenir looks better
              // updateSettings("font", "SFProText", updateGlobalState: false);
            } else {
              updateSettings("font", "Avenir", updateGlobalState: false);
            }
            updateSettings("iOSEmulate", value,
                pagesNeedingRefresh: [], updateGlobalState: true);
          },
          initialValue: appStateSettings["iOSEmulate"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.apple_outlined
              : Icons.apple_rounded,
        ),
        SettingsContainerSwitch(
          onSwitched: (value) async {
            updateSettings("incognitoKeyboard", value,
                updateGlobalState: false);
          },
          title: "Teclado em modo privado",
          description:
              "Usar teclado privado nos campos de texto (se suportado)",
          initialValue: appStateSettings["incognitoKeyboard"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.keyboard_outlined
              : Icons.keyboard_rounded,
        ),
        SettingsContainerSwitch(
          title: "Origem do lançamento",
          description:
              "Mostrar a origem do lançamento na lista e nos filtros",
          onSwitched: (value) {
            updateSettings("showMethodAdded", value, updateGlobalState: false);
          },
          initialValue: appStateSettings["showMethodAdded"] == true,
          icon: Icons.bookmark_add,
        ),
        SettingsContainerSwitch(
          title: "Mostrar ID do lançamento",
          description: "Mostrar o identificador interno de cada lançamento",
          onSwitched: (value) {
            updateSettings("showTransactionPk", value,
                updateGlobalState: false);
          },
          initialValue: appStateSettings["showTransactionPk"] == true,
          icon: Icons.password,
        ),
        SettingsContainerSwitch(
          title: "Diferença em empréstimos de longo prazo",
          description:
              "Exibe opção adicional ao criar um empréstimo de longo prazo.",
          onSwitched: (value) {
            updateSettings("longTermLoansDifferenceFeature", value,
                updateGlobalState: true);
          },
          initialValue:
              appStateSettings["longTermLoansDifferenceFeature"] == true,
          icon: Icons.calculate,
        ),
        Padding(
          padding:
              const EdgeInsetsDirectional.only(top: 8.0, start: 13, end: 13),
          child: TextFont(text: "Escala de animação"),
        ),
        SliderSelector(
          min: 0,
          max: 3,
          initialValue: appStateSettings["animationSpeed"].toDouble(),
          onChange: (value) {},
          divisions: 30,
          onFinished: (value) {
            if (value == 0) value = 0.0000001;
            timeDilation = value;
            updateSettings("animationSpeed", value, updateGlobalState: true);
          },
        ),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 20),
          child: Column(
            children: [
              Button(
                label: "Refazer migração (a partir da versão 37 do banco)",
                onTap: () async {
                  await database.customStatement('PRAGMA user_version = 37');
                  if (kIsWeb) {
                    final html.Storage localStorage = html.window.localStorage;
                    localStorage["moor_db_version_db"] = "37";
                  }
                  restartAppPopup(context);
                },
              ),
              SizedBox(height: 20),
              Button(
                label: "Corrigir sinal dos lançamentos",
                onTap: () async {
                  int result = await database.fixTransactionPolarity();
                  openSnackbar(
                    SnackbarMessage(
                      title: "Concluído",
                      description:
                          "Aplicado a " + result.toString() + " lançamentos",
                      icon: Icons.check,
                    ),
                  );
                },
              ),
              SizedBox(height: 20),
              Button(
                label: "Capitalizar primeira letra de todos os lançamentos",
                onTap: () async {
                  int result = await database.capitalizeFirst();
                  openSnackbar(
                    SnackbarMessage(
                      title: "Concluído",
                      description:
                          "Aplicado a " + result.toString() + " lançamentos",
                      icon: Icons.check,
                    ),
                  );
                },
              ),
              SizedBox(height: 20),
              Button(
                label: "Compactar e limpar banco (VACUUM)",
                onTap: () async {
                  try {
                    await database.customStatement('VACUUM');
                    openSnackbar(
                      SnackbarMessage(
                        title: "Concluído",
                        icon: Icons.check,
                      ),
                    );
                  } catch (e) {
                    openSnackbar(
                      SnackbarMessage(
                        title: e.toString(),
                        icon: Icons.error,
                      ),
                    );
                  }
                },
              ),
              SizedBox(height: 20),
              Button(
                  label: "Forçar sincronização completa",
                  onTap: () async {
                    sharedPreferences.setString(
                        "dateOfLastSyncedWithClient", "{}");
                    runAllCloudFunctions(context);
                  }),
              SizedBox(height: 20),
              Button(
                expandedLayout: true,
                label:
                    "Limpar registros de exclusão do banco (sincronize todos os aparelhos antes)",
                onTap: () async {
                  int result = await database.deleteAllDeleteLogs();
                  openSnackbar(
                    SnackbarMessage(
                      title: "Concluído",
                      description: result.toString() + " registros removidos",
                      icon: Icons.check,
                    ),
                  );
                },
              ),
              SizedBox(height: 20),
              Button(
                  label: "Ver registros de exclusão",
                  onTap: () async {
                    pushRoute(
                      context,
                      PageFramework(
                        title: "Registros de exclusão",
                        slivers: [
                          StreamBuilder<List<DeleteLog>>(
                            stream: database.watchAllDeleteLogs(),
                            builder: (context, snapshot) {
                              if (snapshot.hasData) {
                                return SliverPadding(
                                  padding: EdgeInsetsDirectional.symmetric(
                                      vertical: 7, horizontal: 13),
                                  sliver: SliverList(
                                    delegate: SliverChildBuilderDelegate(
                                      (BuildContext context, int index) {
                                        DeleteLog deletelog =
                                            snapshot.data![index];
                                        return Padding(
                                          padding:
                                              const EdgeInsetsDirectional.only(
                                                  bottom: 4),
                                          child: TextFont(
                                            text: (index + 1).toString() +
                                                ") " +
                                                deletelog.type.toString() +
                                                " " +
                                                deletelog.dateTimeModified
                                                    .toString() +
                                                ": " +
                                                deletelog.deleteLogPk +
                                                " — " +
                                                deletelog.entryPk,
                                            maxLines: 10,
                                            fontSize: 12,
                                          ),
                                        );
                                      },
                                      childCount: snapshot.data?.length,
                                    ),
                                  ),
                                );
                              } else {
                                return SliverToBoxAdapter();
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  }),
              SizedBox(height: 20),
              Button(
                  label: "Enviar notificação de teste",
                  onTap: () async {
                    initializeNotificationsPlatform();
                    scheduleDailyNotification(context, TimeOfDay.now(),
                        scheduleNowDebug: true);
                  }),
              SizedBox(height: 20),
              Button(
                  label: "Forçar backup automático ao abrir",
                  onTap: () async {
                    updateSettings(
                      "lastBackup",
                      DateTime.now().subtract(Duration(days: 50)).toString(),
                      updateGlobalState: false,
                    );
                  }),
              SizedBox(height: 20),
              DangerousDebugFlag(
                child: Button(
                  label: "Criar dados de demonstração",
                  onTap: () async {
                    generatePreviewData();
                  },
                ),
              ),
              SizedBox(height: 10),
              DangerousDebugFlag(
                child: Button(
                  label: "Criar lançamentos aleatórios",
                  onTap: () async {
                    List<TransactionCategory> categories =
                        await database.getAllCategories();
                    for (int i = 0; i < 10; i++) {
                      await database.createOrUpdateTransaction(
                        insert: true,
                        Transaction(
                          transactionPk: "-1",
                          name: "Teste" + randomDouble[i].toString(),
                          amount: randomInt[i].toDouble(),
                          note: "",
                          categoryFk: categories[i].categoryPk,
                          walletFk: "0",
                          dateCreated: DateTime.now(),
                          income: false,
                          paid: true,
                          skipPaid: false,
                          methodAdded: MethodAdded.preview,
                        ),
                      );
                    }
                  },
                ),
              ),
              SizedBox(height: 20),
              Button(
                  label: "Testar aviso (Snackbar)",
                  onTap: () {
                    openSnackbar(
                      SnackbarMessage(
                        title:
                            '${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second}.${DateTime.now().millisecond}',
                        icon: Icons.time_to_leave,
                        timeout: Duration(milliseconds: 1000),
                      ),
                    );
                    openSnackbar(
                      SnackbarMessage(
                        title: "Teste",
                        description:
                            '${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second}.${DateTime.now().millisecond}',
                        icon: Icons.abc,
                        timeout: Duration(milliseconds: 1000),
                        onTap: () {},
                      ),
                    );
                    openSnackbar(
                      SnackbarMessage(
                        title:
                            '${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second}.${DateTime.now().millisecond}',
                        timeout: Duration(milliseconds: 1000),
                      ),
                    );
                    openSnackbar(
                      SnackbarMessage(
                        title:
                            '${DateTime.now().hour}:${DateTime.now().minute}:${DateTime.now().second}.${DateTime.now().millisecond}',
                        description: "Descrição de exemplo",
                        timeout: Duration(milliseconds: 7000),
                      ),
                    );
                    openSnackbar(
                      SnackbarMessage(
                        title:
                            'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation',
                        timeout: Duration(milliseconds: 10000),
                      ),
                    );
                  }),
              SizedBox(height: 10),
              HorizontalBreak(),
              AppLinkTesting(),
              HorizontalBreak(),
              SizedBox(height: 10),
              TextFont(
                  maxLines: 10,
                  text: kIsWeb
                      ? html.window.navigator.userAgent.toString().toLowerCase()
                      : ""),
              SizedBox(height: 20),
              Button(
                label: "Vibração leve",
                onTap: () => HapticFeedback.lightImpact(),
              ),
              Button(
                label: "Vibração média",
                onTap: () => HapticFeedback.mediumImpact(),
              ),
              Button(
                label: "Vibração forte",
                onTap: () => HapticFeedback.heavyImpact(),
              ),
              Button(
                label: "Vibração de seleção",
                onTap: () => HapticFeedback.selectionClick(),
              ),
              Button(
                label: "Vibrar",
                onTap: () => HapticFeedback.vibrate(),
              ),
            ],
          ),
        ),
        ColorBox(color: Theme.of(context).colorScheme.surface, name: "surface"),
        ColorBox(
            color: Theme.of(context).colorScheme.onSurface, name: "onSurface"),
        ColorBox(
            color: Theme.of(context).colorScheme.background,
            name: "background"),
        ColorBox(
            color: Theme.of(context).colorScheme.onBackground,
            name: "onBackground"),
        Container(
          margin: EdgeInsetsDirectional.all(10),
          height: 1,
          color: Colors.grey,
        ),
        ColorBox(color: Theme.of(context).colorScheme.primary, name: "primary"),
        ColorBox(
            color: Theme.of(context).colorScheme.onPrimary, name: "onPrimary"),
        ColorBox(
            color: Theme.of(context).colorScheme.primaryContainer,
            name: "primaryContainer"),
        ColorBox(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            name: "onPrimaryContainer"),
        Container(
          margin: EdgeInsetsDirectional.all(10),
          height: 1,
          color: Colors.grey,
        ),
        ColorBox(
            color: Theme.of(context).colorScheme.secondary, name: "secondary"),
        ColorBox(
            color: Theme.of(context).colorScheme.onSecondary,
            name: "onSecondary"),
        ColorBox(
            color: Theme.of(context).colorScheme.secondaryContainer,
            name: "secondaryContainer"),
        ColorBox(
            color: Theme.of(context).colorScheme.onSecondaryContainer,
            name: "onSecondaryContainer"),
        Container(
          margin: EdgeInsetsDirectional.all(10),
          height: 1,
          color: Colors.grey,
        ),
        ColorBox(
            color: Theme.of(context).colorScheme.tertiary, name: "tertiary"),
        ColorBox(
            color: Theme.of(context).colorScheme.onTertiary,
            name: "onTertiary"),
        ColorBox(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            name: "tertiaryContainer"),
        ColorBox(
            color: Theme.of(context).colorScheme.onTertiaryContainer,
            name: "onTertiaryContainer"),
        Container(
          margin: EdgeInsetsDirectional.all(10),
          height: 1,
          color: Colors.grey,
        ),
        ColorBox(color: Theme.of(context).colorScheme.error, name: "error"),
        ColorBox(color: Theme.of(context).colorScheme.onError, name: "onError"),
        ColorBox(
            color: Theme.of(context).colorScheme.errorContainer,
            name: "errorContainer"),
        ColorBox(
            color: Theme.of(context).colorScheme.onErrorContainer,
            name: "onErrorContainer"),
      ],
    );
  }
}

class AppLinkTesting extends StatefulWidget {
  const AppLinkTesting({super.key});

  @override
  State<AppLinkTesting> createState() => _AppLinkTestingState();
}

class _AppLinkTestingState extends State<AppLinkTesting> {
  @override
  Widget build(BuildContext context) {
    String appLinkString = "";
    return Column(
      children: [
        TextInput(
          labelText: "Testar link do app",
          keyboardType: TextInputType.multiline,
          maxLines: null,
          minLines: 3,
          onChanged: (value) {
            appLinkString = value;
          },
        ),
        SizedBox(height: 10),
        Button(
            label: "Executar link do app",
            onTap: () async {
              Uri uri;
              try {
                uri = Uri.parse(appLinkString);
                List<String> resultOutput = [];
                await executeAppLink(
                  context,
                  uri,
                  onDebug: (dynamic outResult) {
                    resultOutput.add(outResult.toString());
                  },
                );
                openPopup(
                  context,
                  title: "Resultado",
                  descriptionWidget: CodeBlock(
                    text: resultOutput.toString(),
                  ),
                );
              } catch (e) {
                openSnackbar(SnackbarMessage(
                    title: "Erro ao analisar link", description: e.toString()));
              }
            }),
        SizedBox(height: 10),
        AboutDeepLinking(),
      ],
    );
  }
}

class DangerousDebugFlag extends StatelessWidget {
  const DangerousDebugFlag({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (allowDangerousDebugFlags) {
      return Container(
        color: Colors.red.withOpacity(0.3),
        child: child,
      );
    } else {
      return SizedBox.shrink();
    }
  }
}

class ColorBox extends StatelessWidget {
  const ColorBox({Key? key, required this.color, required this.name})
      : super(key: key);

  final Color color;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      child: Row(
        children: [
          Container(width: 20),
          Container(width: 50, height: 50, color: color),
          Container(width: 20),
          TextFont(text: name)
        ],
      ),
    );
  }
}
