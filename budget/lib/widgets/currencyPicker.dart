import 'package:budget/colors.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/exchangeRatesPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/editorial.dart' show cores;
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/noResults.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/viewAllTransactionsButton.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:sliver_tools/sliver_tools.dart';

const _paisesPt = <String, String>{
  'Brazil': 'Brasil',
  'United States': 'Estados Unidos',
  'Euro Member': 'Zona do Euro',
  'Japan': 'Japão',
  'United Kingdom': 'Reino Unido',
  'Australia': 'Austrália',
  'Canada': 'Canadá',
  'Switzerland': 'Suíça',
  'China': 'China',
  'Sweden': 'Suécia',
  'New Zealand': 'Nova Zelândia',
  'Mexico': 'México',
  'India': 'Índia',
  'Norway': 'Noruega',
  'Korea (South)': 'Coreia do Sul',
  'Argentina': 'Argentina',
  'Chile': 'Chile',
  'Colombia': 'Colômbia',
  'Peru': 'Peru',
  'Uruguay': 'Uruguai',
  'Paraguay': 'Paraguai',
  'South Africa': 'África do Sul',
  'Russia': 'Rússia',
  'Turkey': 'Turquia',
  'Poland': 'Polônia',
  'Denmark': 'Dinamarca',
  'Singapore': 'Singapura',
  'Hong Kong': 'Hong Kong',
  'Taiwan': 'Taiwan',
  'Thailand': 'Tailândia',
  'Indonesia': 'Indonésia',
  'Malaysia': 'Malásia',
  'Philippines': 'Filipinas',
  'Israel': 'Israel',
  'United Arab Emirates': 'Emirados Árabes',
  'Saudi Arabia': 'Arábia Saudita',
  'Egypt': 'Egito',
};

String _nomePaisMoeda(dynamic currency) {
  if (currency is! Map) return '';
  final raw =
      (currency['CountryName'] ?? currency['Currency'] ?? '').toString();
  if (raw.isEmpty) return '';
  if (appStateSettings['locale'] == 'pt') {
    return _paisesPt[raw] ?? raw.capitalizeFirst;
  }
  return currency['CountryName']?.toString() ?? raw.capitalizeFirst;
}

String _simboloMoeda(dynamic currency, String currencyKey) {
  if (currency is! Map) return currencyKey.toUpperCase();
  final sym = (currency['Symbol'] ?? '').toString();
  if (sym.isEmpty) {
    return (currency['Code'] ?? currencyKey).toString().allCaps;
  }
  // '₣' (U+20A3) não existe na fonte Geist e renderiza glifo ausente (⌧).
  if (sym == '₣') return 'Fr';
  return sym;
}

class CurrencyPicker extends StatefulWidget {
  const CurrencyPicker({
    super.key,
    required this.onSelected,
    this.onHasFocus,
    this.initialCurrency,
    this.unSelectedColor,
    required this.showExchangeRateInfoNotice,
  });
  final Function(String) onSelected;
  final Function? onHasFocus;
  final String? initialCurrency;
  final Color? unSelectedColor;
  final bool showExchangeRateInfoNotice;

  @override
  State<CurrencyPicker> createState() => _CurrencyPickerState();
}

class _CurrencyPickerState extends State<CurrencyPicker> {
  bool viewAll = false;
  String? selectedCurrency = null;
  String? searchText = "";
  Map<String, dynamic> currencies = {};
  late String? initialCurrency = widget.initialCurrency;
  List<String> popularCurrenciesLocal = popularCurrencies;

  @override
  void initState() {
    super.initState();
    if (widget.initialCurrency == null) {
      setState(() {
        selectedCurrency = getDevicesDefaultCurrencyCode();
      });
    } else {
      setState(() {
        selectedCurrency = widget.initialCurrency;
        if (!popularCurrencies.contains(widget.initialCurrency) &&
            selectedCurrency != "") {
          popularCurrenciesLocal =
              popularCurrencies.sublist(0, popularCurrencies.length - 1);
          // Don't add again if selected and custom currency
          if (currenciesJSON[widget.initialCurrency] != null)
            popularCurrenciesLocal.insert(0, widget.initialCurrency!);
        }
      });
    }

    populateCurrencies();
  }

  void populateCurrencies() {
    Future.delayed(Duration(milliseconds: 0), () async {
      setState(() {
        currencies = currenciesJSON;
        searchText = "";
      });
    });
  }

  void searchCurrencies(String searchTerm) async {
    if (searchTerm == "") {
      populateCurrencies();
    } else {
      Map<String, dynamic> outCurrencies = {};
      final termo = searchTerm.toLowerCase();
      for (String key in currenciesJSON.keys) {
        dynamic currency = currenciesJSON[key];
        final nomePt = _nomePaisMoeda(currency).toLowerCase();
        if ((currency["CountryName"] != null &&
                currency["CountryName"].toLowerCase().contains(termo)) ||
            (currency["Currency"] != null &&
                currency["Currency"].toLowerCase().contains(termo)) ||
            (currency["Code"] != null &&
                currency["Code"].toLowerCase().contains(termo)) ||
            nomePt.contains(termo)) {
          outCurrencies[key] = currency;
        }
      }
      setState(() {
        currencies = outCurrencies;
        searchText = searchTerm;
      });
    }
  }

  void onSelected(currency) {
    setState(() {
      selectedCurrency = currency;
    });
    if (!popularCurrencies.contains(currency) && selectedCurrency != "") {
      setState(() {
        popularCurrenciesLocal =
            popularCurrencies.sublist(0, popularCurrencies.length - 1);
        // Don't add again if selected and custom currency
        if (currenciesJSON[currency] != null)
          popularCurrenciesLocal.insert(0, currency);
      });
    }
    widget.onSelected(currency);
  }

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: EdgeInsetsDirectional.symmetric(horizontal: 24),
      sliver: MultiSliver(
        children: [
          SliverToBoxAdapter(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Focus(
                        onFocusChange: (hasFocus) {
                          if (hasFocus && widget.onHasFocus != null)
                            widget.onHasFocus!();
                        },
                        child: TextInput(
                          labelText: "search-currencies-placeholder".tr(),
                          icon: appStateSettings["outlinedIcons"]
                              ? Icons.search_outlined
                              : Icons.search_rounded,
                          onChanged: (text) {
                            searchCurrencies(text);
                          },
                          padding: EdgeInsetsDirectional.zero,
                        ),
                      ),
                    ),
                    if (widget.showExchangeRateInfoNotice)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 7),
                        child: ButtonIcon(
                          onTap: () {
                            openPopup(
                              context,
                              title: "exchange-rate-notice".tr(),
                              description:
                                  "exchange-rate-notice-description".tr(),
                              icon: appStateSettings["outlinedIcons"]
                                  ? Icons.info_outlined
                                  : Icons.info_outline_rounded,
                              onCancel: () {
                                popRoute(context);
                              },
                              onCancelLabel: "ok".tr(),
                              onSubmit: () async {
                                checkIfExchangeRateChangeBefore();
                                popRoute(context);
                                await pushRoute(context, ExchangeRates());
                                checkIfExchangeRateChangeAfter();
                              },
                              onSubmitLabel: "exchange-rates".tr(),
                            );
                          },
                          icon: appStateSettings["outlinedIcons"]
                              ? Icons.info_outlined
                              : Icons.info_outline_rounded,
                        ),
                      ),
                  ],
                ),
                SizedBox(height: 12),
              ],
            ),
          ),
          SliverGrid(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 125,
              crossAxisSpacing: 7,
              mainAxisSpacing: 7,
            ),
            delegate: SliverChildListDelegate(
              (searchText != "" || viewAll == true)
                  ? [
                      for (String currencyKey in currencies.keys)
                        CurrencyItem(
                          currencyKey: currencyKey,
                          selected: selectedCurrency == currencyKey,
                          onSelected: onSelected,
                          unSelectedColor: widget.unSelectedColor,
                        )
                    ]
                  : [
                      for (dynamic currencyKey
                          in appStateSettings["customCurrencies"])
                        CurrencyItem(
                          customCurrency: true,
                          currencyKey: currencyKey.toString(),
                          selected: selectedCurrency == currencyKey,
                          onSelected: onSelected,
                          unSelectedColor: widget.unSelectedColor,
                        ),
                      for (String currencyKey in popularCurrenciesLocal)
                        CurrencyItem(
                          currencyKey: currencyKey.toString(),
                          selected: selectedCurrency == currencyKey,
                          onSelected: onSelected,
                          unSelectedColor: widget.unSelectedColor,
                        )
                    ],
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              children: [
                searchText != "" || viewAll == true
                    ? SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsetsDirectional.only(top: 15),
                        child: LowKeyButton(
                          color: widget.unSelectedColor,
                          onTap: () {
                            setState(() {
                              viewAll = true;
                            });
                          },
                          text: "view-all-currencies".tr(),
                        ),
                      ),
                currencies.length <= 0
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(bottom: 15),
                        child: NoResults(
                          message: "no-currencies-found".tr(),
                        ),
                      )
                    : SizedBox.shrink(),
                currencies.length < 9 && currencies.length > 0
                    ? SizedBox(
                        height: 180,
                      )
                    : SizedBox(
                        height: 20,
                      )
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CurrencyItem extends StatelessWidget {
  const CurrencyItem({
    super.key,
    required this.currencyKey,
    required this.selected,
    required this.onSelected,
    this.customCurrency = false,
    this.unSelectedColor,
  });
  final String currencyKey;
  final bool selected;
  final Function(String) onSelected;
  final bool customCurrency;
  final Color? unSelectedColor;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final extraName = _nomePaisMoeda(currenciesJSON[currencyKey]);
    return AnimatedSwitcher(
      duration: Duration(milliseconds: 500),
      child: Tappable(
        key: ValueKey(selected),
        onTap: () {
          onSelected(currencyKey);
        },
        borderRadius: 12,
        color: selected
            ? Theme.of(context).colorScheme.secondaryContainer
            : unSelectedColor ?? e.surf,
        child: AnimatedContainer(
          decoration: BoxDecoration(
            borderRadius: BorderRadiusDirectional.circular(12),
            border: Border.all(
              width: selected ? 1.5 : 1,
              color: selected ? e.acc : e.line,
            ),
          ),
          duration: Duration(milliseconds: 450),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: 500, minHeight: 500),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 13, vertical: 5),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (customCurrency == false &&
                      currenciesJSON[currencyKey]?["NotKnown"] != true)
                    TextFont(
                      key: ValueKey("currencyKey"),
                      text: currencyKey.toUpperCase(),
                      fontSize: 18,
                      textAlign: TextAlign.center,
                    ),
                  TextFont(
                    key: ValueKey("symbol"),
                    text: customCurrency
                        ? currencyKey.toUpperCase()
                        : _simboloMoeda(
                            currenciesJSON[currencyKey], currencyKey),
                    autoSizeText: true,
                    maxFontSize: 50,
                    fontSize: customCurrency ||
                            currenciesJSON[currencyKey]?["NotKnown"] == true
                        ? 20
                        : 25,
                    fontWeight: FontWeight.bold,
                    textAlign: TextAlign.center,
                  ),
                  if (extraName.isNotEmpty)
                    TextFont(
                      key: ValueKey("extraName"),
                      text: extraName,
                      fontSize: 10,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                    ),
                  if (customCurrency)
                    TextFont(
                      key: ValueKey("info"),
                      text: "custom-currency".tr(),
                      fontSize: 10,
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
