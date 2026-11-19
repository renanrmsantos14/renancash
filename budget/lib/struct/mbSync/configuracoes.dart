import 'dart:convert';

import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/mbSync/detectar.dart';
import 'package:budget/struct/settings.dart';

/// Configurações que mudam dados ou cálculos e por isso valem nos dois aparelhos.
/// Fora daqui, por aparelho: tema, fonte, cor, animações, notificações, biometria, tokens, URL do servidor,
/// cursor de sincronização, última página aberta, filtros salvos, formato de número, idioma e carteira selecionada.
final Set<String> mbConfigsSincronizadas = {
  // Período e ciclo principais
  'selectedPeriodCycleType',
  'cyclePeriodLength',
  'cycleReoccurrence',
  'cycleStartDate',
  'customPeriodStartDate',
  'customPeriodEndDate',
  'customPeriodPastDays',
  'firstDayOfWeek',
  // Orçamento de referência e contas/carteiras escondidas ou incluídas nos totais
  'lineGraphReferenceBudgetPk',
  'watchedCategoriesOnBudget',
  'carteirasArquivadas',
  'netWorthAllWallets',
  'pieChartAllWallets',
  'allSpendingSummaryAllWallets',
  // Como os totais são calculados
  'showTotalSpentForBudget',
  'showTotalSpentForObjective',
  'showCumulativeSpending',
  'removeZeroTransactionEntries',
  'ignorePastAmountSpent',
  'automaticallyPayUpcoming',
  'automaticallyPayRepetitive',
  'automaticallyPaySubscriptions',
  'markAsPaidOnOriginalDay',
  'futureTransactionDaysHomePage',
  'homePageTransactionsListIncomeAndExpenseOnly',
  'pieChartIncomeAndExpenseOnly',
  'pieChartTotal',
  'netAllSpendingTotal',
  'netSpendingDayTotal',
  'longTermLoansDifferenceFeature',
  'showPastSpendingTrajectory',
  // Seções da Início (celular e tela grande) e a ordem delas
  'homePageOrder',
  'homePageOrderFullScreen',
  'showWalletSwitcher',
  'showWalletList',
  'showPinnedBudgets',
  'showObjectives',
  'showAllSpendingSummary',
  'showNetWorth',
  'showOverdueUpcoming',
  'showObjectiveLoans',
  'showCreditDebt',
  'showSpendingGraph',
  'showPieChart',
  'showHeatMap',
  'showTransactionsList',
  'showUsernameWelcomeBanner',
  'showWalletSwitcherFullScreen',
  'showWalletListFullScreen',
  'showPinnedBudgetsFullScreen',
  'showObjectivesFullScreen',
  'showAllSpendingSummaryFullScreen',
  'showNetWorthFullScreen',
  'showOverdueUpcomingFullScreen',
  'showObjectiveLoansFullScreen',
  'showCreditDebtFullScreen',
  'showSpendingGraphFullScreen',
  'showPieChartFullScreen',
  'showHeatMapFullScreen',
  'showTransactionsListFullScreen',
  'showUsernameWelcomeBannerFullScreen',
  // Período próprio de cada widget da Início
  for (final w in _widgetsComPeriodo)
    for (final b in _basePeriodo) '$b$w',
  // Moedas, sugestões ao lançar, visual de listas e atalhos que o usuário vê nos dois aparelhos
  'customCurrencies',
  'customCurrencyAmounts',
  'walletsListCurrencyBreakdown',
  'autoAddAssociatedTitles',
  'askForTransactionTitle',
  'askForTransactionNoteWithTitle',
  'selectedSubscriptionType',
  'lineGraphDisplayType',
  'lineGraphStartDate',
  'nonCompactTransactions',
  'showTransactionsMonthlySpendingSummary',
  'showAllSubcategories',
  'showAllCategoriesWhenSelecting',
  'expandAllCategoriesWithSpendingLimits',
  'showCompressedViewBudgetGraph',
  'colorTintCategoryIcon',
  'outlinedIcons',
  'netTotalsColorful',
  'accountColorfulAmountsWithArrows',
  'percentagePrecision',
  'showCurrencyLabel',
  'customNavBarShortcut0',
  'customNavBarShortcut1',
  'customNavBarShortcut2',
  'showBillSplitterShortcut',
  'username',
};

// Configurações de cada aparelho (aparência, formato, avisos, contadores, caches). Todo o resto sincroniza, inclusive
// as chaves novas, para o espelho não depender de lembrar de listá-las. Seções da Início entram sem o sufixo FullScreen.
const Set<String> _configsLocais = {
  // espelho e banco local
  'mbEspelho', 'meuBancoDesde', 'databaseJustImported', 'atualizacaoOfertada',
  // aparência
  'theme', 'temaPronto', 'accentColor', 'acento', 'accentSystemColor', 'materialYou', 'font', 'increaseTextContrast',
  'appAnimations', 'animationSpeed', 'batterySaver', 'forceFullDarkBackground', 'fadeTransactionNameOverflows',
  'circularProgressRotation', 'numberCountUpAnimation', 'iOSEmulate', 'incognitoKeyboard', 'enableGreetingMessage',
  'showFAQAndHelpLink', 'showExtraInfoText', 'showTransactionPk', 'showMethodAdded', 'restrictAmountOfInitiallyLoadedTransactions',
  // organização da Início e navegação
  'homePageOrder', 'showWalletSwitcher', 'showWalletList', 'showPinnedBudgets', 'showObjectives',
  'showAllSpendingSummary', 'showNetWorth', 'showOverdueUpcoming', 'showObjectiveLoans', 'showCreditDebt',
  'showSpendingGraph', 'showPieChart', 'showHeatMap', 'showTransactionsList', 'showUsernameWelcomeBanner',
  'expandedNavigationSidebar',
  // idioma, formato de números e horas, tátil
  'locale', 'use24HourFormat', 'customNumberFormat', 'numberFormatDelimiter', 'numberFormatDecimal',
  'numberFormatCurrencyFirst', 'shortNumberFormat', 'extraZerosButton', 'numberPadFormat',
  'numberPadHapticFeedback', 'savingHapticFeedback', 'closeNavigationHapticFeedback', 'tabNavigationHapticFeedback',
  // notificações, segurança e estado da tela
  'requireAuth', 'selectedWalletPk', 'notifications', 'notificationHour', 'notificationMinute',
  'notificationsUpcomingTransactions', 'notificationsReminderType', 'notificationScanning',
  'notificationScanningDebug', 'emailScanning', 'emailScanningPullToRefresh', 'logging',
  // contadores, dicas, premium, backup, login e caches
  'hasOnboarded', 'numLogins', 'lastLoginVersion', 'appOpenedHour', 'appOpenedMinute', 'openedStoreRating',
  'dismissedStoreRating', 'submittedFeedback', 'canShowBackupReminderPopup', 'canShowTransactionActionButtonTip',
  'autoLoginDisabledOnWebTip', 'allSpendingPageTip', 'premiumPopupAddTransactionCount',
  'premiumPopupAddTransactionLastShown', 'premiumPopupFreeSeen', 'previewDemo', 'purchaseID', 'backupLimit',
  'backupSync', 'autoBackups', 'autoBackupsFrequency', 'lastBackup', 'numBackups', 'showBackupLimit',
  'syncEveryChange', 'devicesHaveBeenSynced', 'lastSynced', 'sendTransactionsToServerQueue', 'sharedBudgets',
  'usersNicknames', 'currentUserEmail', 'hasSignedIn', 'enableGoogleLoginFlyIn', 'forceAutoLogin',
  'cachedCurrencyExchange',
};
const _prefixosLocais = ['widget', 'customNavBarShortcut'];
const _sufixosLocais = ['SetFiltersString', 'LastPage'];

/// Configuração que fica só neste aparelho. Dados, ciclo, totais, moedas, nome e ícones sincronizam.
bool mbConfigLocal(String chave) {
  final base = chave.endsWith('FullScreen') ? chave.substring(0, chave.length - 10) : chave;
  return _configsLocais.contains(base) ||
      _prefixosLocais.any(chave.startsWith) ||
      _sufixosLocais.any(chave.endsWith);
}

const _widgetsComPeriodo = [
  'AllSpendingSummary',
  'CreditDebts',
  'NetWorth',
  'OverdueUpcoming',
  'PieChart',
];
const _basePeriodo = [
  'selectedPeriodCycleType',
  'cyclePeriodLength',
  'cycleReoccurrence',
  'cycleStartDate',
  'customPeriodStartDate',
  'customPeriodEndDate',
  'customPeriodPastDays',
];

// O Worker aceita até 4000 caracteres no valor serializado.
const int _limiteValor = 4000;

/// Uma configuração por chave. Só vai ao servidor a que difere do padrão do app ou que ele já conhece
/// (para propagar a volta ao padrão); assim um aparelho novo não envia ~60 registros com os padrões.
/// `todas`: também as que estão no padrão (usado ao tornar este aparelho a fonte oficial).
Future<List<Projetado>> mbProjConfiguracoes(
    Map<String, Espelho> espelho, Set<String> existentes,
    {bool todas = false}) async {
  final padrao = await getDefaultPreferences();
  final out = <Projetado>[];
  for (final chave in mbConfigsSincronizadas) {
    // Sem valor local ou grande demais: fica fora da projeção, mas o registro do servidor não vira tombstone.
    final valor = json.encode(appStateSettings[chave]);
    if (!appStateSettings.containsKey(chave) || valor.length > _limiteValor) {
      existentes.add('configuracoes/$chave');
      continue;
    }
    final r = espelho['configuracoes/$chave']?.registro;
    final servidorTem = r != null && r.deletedAt == null;
    if (!todas && !servidorTem && valor == json.encode(padrao[chave])) continue;
    out.add(Projetado('configuracoes', chave, {'valor': valor}, null));
  }
  return out;
}

/// Aplica a configuração vinda do outro aparelho; só mexe no estado se o valor mudou.
/// Chave desconhecida (de versão mais nova do app) fica só no espelho.
Future<Projetado?> mbAplicarConfiguracao(
    String chave, Map<String, dynamic> d) async {
  if (!mbConfigsSincronizadas.contains(chave)) return null;
  final bruto = d['valor'];
  if (bruto is! String) return null;
  final valor = json.decode(bruto);
  if (json.encode(appStateSettings[chave]) != json.encode(valor)) {
    await updateSettings(chave, valor, updateGlobalState: true);
  }
  return Projetado('configuracoes', chave, {'valor': json.encode(valor)}, null);
}
