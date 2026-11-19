/// Quais configurações ficam só neste aparelho (o resto vai para o espelho).
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
