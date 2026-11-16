import 'package:budget/database/tables.dart' show schemaVersionGlobal;
import 'package:budget/functions.dart';
import 'package:budget/main.dart';
import 'package:budget/pages/accountsPage.dart';
import 'package:budget/pages/debugPage.dart';
import 'package:budget/pages/onBoardingPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/languageMap.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/moreIcons.dart';
import 'package:budget/widgets/navigationSidebar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    bool contorno = appStateSettings["outlinedIcons"] == true;
    final e = cores(context);
    return PageFramework(
      dragDownToDismiss: true,
      title: "about".tr(),
      horizontalPaddingConstrained: true,
      listWidgets: [
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 18, vertical: 12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image(
                  image: AssetImage("assets/icon/icon-small.png"),
                  height: 48,
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: GestureDetector(
                  onLongPress: allowDebugFlags
                      ? () => pushRoute(context, DebugPage())
                      : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(globalAppName,
                          style: EdTexto.h1(context).copyWith(fontSize: 20)),
                      SizedBox(height: 2),
                      Text(getVersionString(), style: EdTexto.rotulo(context)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        SettingsHeader(title: "App"),
        SettingsContainer(
          title: "Ver a introdução",
          icon: contorno
              ? Icons.door_front_door_outlined
              : Icons.door_front_door_rounded,
          onTap: () => openOnBoarding(context),
        ),
        SettingsContainerOpenPage(
          openPage: CreditosPage(),
          title: "Créditos",
          description: "Equipe do Cashew, ícones, ferramentas e tradutores",
          icon: contorno ? Icons.favorite_outline : Icons.favorite_rounded,
        ),
        SettingsContainer(
          title: "Baseado no Cashew",
          description: "Código aberto no GitHub",
          icon: MoreIcons.github,
          afterWidget: Icon(Icons.open_in_new_rounded, size: 18, color: e.mu),
          onTap: () => openUrl("https://github.com/jameskokoska/Cashew"),
        ),
        SettingsContainer(
          title: "view-licenses-and-legalese".tr(),
          icon: contorno ? Icons.gavel_outlined : Icons.gavel_rounded,
          onTap: () => openLicensesPage(context),
        ),
        if (getPlatform(ignoreEmulation: true) == PlatformOS.isAndroid ||
            kIsWeb)
          SettingsContainer(
            title: "deep-linking".tr(),
            description: "deep-linking-description".tr(),
            icon: contorno ? Icons.link_outlined : Icons.link_rounded,
            afterWidget: Icon(Icons.open_in_new_rounded, size: 18, color: e.mu),
            onTap: () => openUrl(linkDocumentacaoDeepLinks),
          ),
        SettingsHeader(title: "Dados"),
        SettingsContainer(
          title: "delete-all-data".tr(),
          description: "Transações, contas e ajustes deste aparelho",
          descriptionColor: e.warn,
          icon: contorno
              ? Icons.delete_sweep_outlined
              : Icons.delete_sweep_rounded,
          onTap: () => deleteAllDataFlow(context),
        ),
      ],
    );
  }
}

const linkDocumentacaoDeepLinks =
    "https://github.com/jameskokoska/Cashew?tab=readme-ov-file#app-links";

/// Créditos herdados do Cashew: equipe, gráficos, ferramentas e tradutores.
class CreditosPage extends StatelessWidget {
  const CreditosPage({super.key});

  @override
  Widget build(BuildContext context) {
    bool fullScreenLayout = enableDoubleColumn(context);

    List<Widget> developmentTeam = [
      AboutInfoBox(
        title: "James · " + "lead-developer".tr(),
        link: "mailto:dapperappdeveloper@gmail.com",
        showLink: false,
        list: ["dapperappdeveloper@gmail.com"],
      ),
      AboutInfoBox(title: "YuYing · " + "database-designer".tr()),
      Padding(
        padding:
            const EdgeInsetsDirectional.symmetric(horizontal: 18, vertical: 6),
        child: Text("made-in-canada".tr() + " 🍁",
            style: EdTexto.rotulo(context)),
      ),
    ];

    List<Widget> graphics = [
      AboutInfoBox(
        title: "freepik-credit".tr(),
        link: "https://www.flaticon.com/authors/freepik",
      ),
      AboutInfoBox(
        title: "font-awesome-credit".tr(),
        link: "https://fontawesome.com/",
      ),
      AboutInfoBox(
        title: "pch-vector-credit".tr(),
        link: "https://www.freepik.com/author/pch-vector",
      ),
    ];

    List<Widget> majorTools = [
      AboutInfoBox(
        title: "Flutter",
        link: "https://flutter.dev/",
      ),
      AboutInfoBox(
        title: "Google Cloud APIs",
        link: "https://cloud.google.com/",
      ),
      AboutInfoBox(
        title: "Drift SQL Database",
        link: "https://drift.simonbinder.eu/",
      ),
      AboutInfoBox(
        title: "FL Charts",
        link: "https://github.com/imaNNeoFighT/fl_chart",
      ),
      AboutInfoBox(
        title: "exchange-rates-api".tr(),
        link: "https://github.com/fawazahmed0/exchange-api",
      ),
    ];

    List<Widget> translators = [
      TranslationInfoBox(
        title: "Italian",
        list: [
          "Thomas B.",
          "Mattia A.",
        ],
      ),
      TranslationInfoBox(
        title: "Polish",
        list: [
          "Michał S.",
          "Michał P.",
          "Kaczusia",
        ],
      ),
      TranslationInfoBox(
        title: "Serbian",
        list: [
          "Jovan P.",
        ],
      ),
      TranslationInfoBox(
        title: "Swahili",
        list: [
          "Anthony K.",
        ],
      ),
      TranslationInfoBox(
        title: "German",
        list: [
          "Fabian S.",
          "Christian R.",
          "Samuel R.",
          "Bettina S.",
        ],
      ),
      TranslationInfoBox(
        title: "Arabic",
        list: [
          "Dorra Y.",
          "Ammar N.",
          "Hussain A.",
          "Mahmoud E.",
        ],
      ),
      TranslationInfoBox(
        title: "Portuguese",
        list: [
          "Alexander G.",
          "Jean J.",
          "João P.",
          "Junior M.",
          "Leandro",
          "Xavier B.",
        ],
      ),
      TranslationInfoBox(
        title: "Bulgarian",
        list: [
          "Денислав C.",
        ],
      ),
      TranslationInfoBox(
        title: "Chinese (Simplified)",
        list: [
          "Clyde",
        ],
      ),
      TranslationInfoBox(
        title: "Chinese (Traditional)",
        list: [
          "qazlll456",
        ],
      ),
      TranslationInfoBox(
        title: "Hindi",
        list: [
          "Dikshant S.",
          "Nikunj K.",
          "Darshan L.",
        ],
      ),
      TranslationInfoBox(
        title: "Vietnamese",
        list: [
          "Ng. Anh",
        ],
      ),
      TranslationInfoBox(
        title: "French",
        list: [
          "Antoine C.",
          "Fabien H.",
          "Samuel S.",
        ],
      ),
      TranslationInfoBox(
        title: "Indonesian",
        list: [
          "Gusairi P.",
        ],
      ),
      TranslationInfoBox(
        title: "Ukrainian",
        list: [
          "Chris M.",
          "Yurii S.",
          "Mariia",
        ],
      ),
      TranslationInfoBox(
        title: "Russian",
        list: [
          "Ilya A.",
          "Konstantin B.",
          "Dennis Q",
          "Innokentii B.",
        ],
      ),
      TranslationInfoBox(
        title: "Romanian",
        list: [
          "Valentin G.",
          "Tarciziu",
        ],
      ),
      TranslationInfoBox(
        title: "Spanish",
        list: [
          "Pablo S.",
          "Gonzalo R.",
          "Ramon M.",
        ],
      ),
      TranslationInfoBox(
        title: "Swedish",
        list: [
          "Anna M.",
        ],
      ),
      TranslationInfoBox(
        title: "Danish",
        list: [
          "Mittheo",
        ],
      ),
      TranslationInfoBox(
        title: "Turkish",
        list: [
          "Serdar A.",
        ],
      ),
      TranslationInfoBox(
        title: "Slovak",
        list: [
          "Igor V.",
        ],
      ),
      TranslationInfoBox(
        title: "Macedonian",
        list: [
          "Andrej A.",
        ],
      ),
      TranslationInfoBox(
        title: "Czech",
        list: [
          "Kamil T.",
          "Hana B.",
        ],
      ),
      TranslationInfoBox(
        title: "Hebrew",
        list: [
          "Happy Bear",
        ],
      ),
      TranslationInfoBox(
        title: "Afrikaans",
        list: [
          "Andrè B.",
        ],
      ),
      TranslationInfoBox(
        title: "Filipino",
        list: [
          "Waren G.",
        ],
      ),
      TranslationInfoBox(
        title: "Tamil",
        list: [
          "Mohamed A.",
        ],
      ),
      TranslationInfoBox(
        title: "Japanese",
        list: [
          "Tetta N.",
        ],
      ),
      TranslationInfoBox(
        title: "Hungarian",
        list: [
          "Döbröntei S.",
          "Myra S.",
        ],
      ),
      TranslationInfoBox(
        title: "Thai",
        list: [
          "Jateniphat U.",
        ],
      ),
      TranslationInfoBox(
        title: "Gujarati",
        list: [
          "Darshan L.",
          "Harsh S.",
        ],
      ),
      TranslationInfoBox(
        title: "Finnish",
        list: [
          "Mirko J.",
        ],
      ),
      TranslationInfoBox(
        title: "Dutch",
        list: [
          "Niels S.",
        ],
      ),
      TranslationInfoBox(
        title: "Malay",
        list: [
          "アリフ",
        ],
      ),
      TranslationInfoBox(
        title: "Sinhala",
        list: [
          "Bhagya S.",
        ],
      ),
    ];

    return PageFramework(
      dragDownToDismiss: true,
      title: "Créditos",
      horizontalPaddingConstrained: true,
      sliversBefore: false,
      listWidgets: [
        SettingsHeader(title: "Equipe do Cashew"),
        ...developmentTeam,
        SettingsHeader(title: "Ícones e ilustrações"),
        ...graphics,
        SettingsHeader(title: "Ferramentas"),
        ...majorTools,
        SettingsHeader(title: "Tradutores do Cashew"),
      ],
      slivers: [
        SliverPadding(
          padding: EdgeInsetsDirectional.symmetric(horizontal: 7.5),
          sliver: SliverMasonryGrid(
            gridDelegate: SliverSimpleGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: fullScreenLayout ? 4 : 2,
            ),
            mainAxisSpacing: 0,
            crossAxisSpacing: 0,
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) {
                return translators[index];
              },
              childCount: translators.length,
            ),
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );
  }
}

String getVersionString() {
  String version = packageInfoGlobal?.version ?? "";
  String buildNumber = packageInfoGlobal?.buildNumber ?? "";
  return "v" +
      version +
      "+" +
      buildNumber +
      ", db-v" +
      schemaVersionGlobal.toString();
}

void openOnBoarding(BuildContext context) {
  pushRoute(
    context,
    OnBoardingPage(
      popNavigationWhenDone: true,
      showPreviewDemoButton: false,
    ),
  );
}

void openLicensesPage(BuildContext context) {
  showLicensePage(
      context: context,
      applicationVersion: getVersionString(),
      applicationLegalese:
          "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE." +
              "\n\n" +
              "exchange-rate-notice-description".tr());
}

void deleteAllDataFlow(BuildContext context) {
  openPopup(
    context,
    title: "erase-everything".tr(),
    description: "erase-everything-description".tr(),
    icon: appStateSettings["outlinedIcons"]
        ? Icons.warning_outlined
        : Icons.warning_rounded,
    onExtraLabel2: "erase-synced-data-and-cloud-backups".tr(),
    onExtra2: () {
      popRoute(context);
      openBottomSheet(
        context,
        PopupFramework(
          title: "erase-cloud-data".tr(),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  bottom: 18,
                  start: 5,
                  end: 5,
                ),
                child: TextFont(
                  text: "erase-cloud-data-description".tr(),
                  fontSize: 16.5,
                  textAlign: TextAlign.center,
                  maxLines: 10,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: SyncCloudBackupButton(
                      onTap: () async {
                        popRoute(context);
                        pushRoute(context, AccountsPage());
                      },
                    ),
                  ),
                  SizedBox(width: 18),
                  Expanded(
                    child: BackupsCloudBackupButton(
                      onTap: () async {
                        popRoute(context);
                        pushRoute(context, AccountsPage());
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
    onSubmit: () async {
      popRoute(context);
      openPopup(
        context,
        title: "erase-everything-warning".tr(),
        description: "erase-everything-warning-description".tr(),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.warning_amber_outlined
            : Icons.warning_amber_rounded,
        onSubmit: () async {
          popRoute(context);
          clearDatabase(context);
        },
        onSubmitLabel: "erase".tr(),
        onCancelLabel: "cancel".tr(),
        onCancel: () {
          popRoute(context);
        },
      );
    },
    onSubmitLabel: "erase".tr(),
    onCancelLabel: "cancel".tr(),
    onCancel: () {
      popRoute(context);
    },
  );
}

class AboutDeepLinking extends StatelessWidget {
  const AboutDeepLinking({super.key});

  @override
  Widget build(BuildContext context) {
    return AboutInfoBox(
      title: "deep-linking".tr(),
      showLink: false,
      link:
          "https://github.com/jameskokoska/Cashew?tab=readme-ov-file#app-links",
      list: [
        "deep-linking-description".tr(),
      ],
    );
  }
}

// Note that this is different than forceDeleteDB()
Future clearDatabase(BuildContext context) async {
  openLoadingPopup(context);
  await Future.wait([database.deleteEverything(), sharedPreferences.clear()]);
  await database.close();
  popRoute(context);
  restartAppPopup(context);
}

class TranslationInfoBox extends StatelessWidget {
  const TranslationInfoBox({
    Key? key,
    required this.title,
    this.list,
  }) : super(key: key);

  final String title;
  final List<String>? list;

  @override
  Widget build(BuildContext context) {
    return AboutInfoBox(
      title: title,
      list: list,
      padding: EdgeInsetsDirectional.symmetric(horizontal: 7.5, vertical: 4),
    );
  }
}

class AboutInfoBox extends StatelessWidget {
  const AboutInfoBox({
    Key? key,
    required this.title,
    this.link,
    this.list,
    this.color,
    this.listTextColor,
    this.padding,
    this.showLink = true,
  }) : super(key: key);

  final String title;
  final String? link;
  final List<String>? list;
  final Color? color;
  final Color? listTextColor;
  final EdgeInsetsGeometry? padding;
  final bool showLink;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    // Cartão plano: superfície e borda, texto à esquerda.
    return Padding(
      padding: padding ??
          EdgeInsetsDirectional.symmetric(horizontal: 15, vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: e.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Tappable(
          onTap: link == null ? null : () => openUrl(link!),
          onLongPress: link == null ? null : () => copyToClipboard(link!),
          color: color ?? e.surf,
          borderRadius: 12,
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFont(
                        text: title,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        maxLines: 5,
                      ),
                      if (link != null && showLink)
                        TextFont(
                          text: link!,
                          fontSize: 12.5,
                          textColor: e.mu,
                          maxLines: 1,
                        ),
                      for (String item in list ?? [])
                        TextFont(
                          text: item,
                          fontSize: 12.5,
                          textColor: listTextColor ?? e.mu,
                          maxLines: 10,
                        ),
                    ],
                  ),
                ),
                if (link != null)
                  Icon(Icons.open_in_new_rounded, size: 16, color: e.mu),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
