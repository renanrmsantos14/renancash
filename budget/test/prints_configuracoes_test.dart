// Prints das Configurações e cadastros (Etapa 5 da revisão de UI) para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_configuracoes_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/config_*.png (fora do git).
// Sem EasyLocalization os textos .tr() saem como chave; os textos novos
// (grupos, descrições) já são pt-BR literais.
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/aboutPage.dart';
import 'package:budget/pages/activityPage.dart';
import 'package:budget/pages/addAssociatedTitlePage.dart';
import 'package:budget/pages/addCategoryPage.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/pages/debugPage.dart';
import 'package:budget/pages/editAssociatedTitlesPage.dart';
import 'package:budget/pages/editCategoriesPage.dart';
import 'package:budget/pages/exchangeRatesPage.dart';
import 'package:budget/pages/notificationsPage.dart';
import 'package:budget/pages/onBoardingPage.dart';
import 'package:budget/pages/settingsPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/languageMap.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide TextInput;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

final _pular = Platform.environment['PRINTS'] != '1';

Future<void> _fonte(String familia, List<String> arquivos) async {
  final l = FontLoader(familia);
  for (final a in arquivos) {
    l.addFont(Future.value(ByteData.sublistView(File(a).readAsBytesSync())));
  }
  await l.load();
}

final _carteiraPadrao = TransactionWallet(
  walletPk: '0',
  name: 'Principal',
  currency: 'brl',
  dateCreated: DateTime(2026, 1, 1),
  order: 0,
  decimals: 2,
);

final _catAlimentacao = TransactionCategory(
  categoryPk: 'c1',
  name: 'Alimentação',
  colour: '0xff4caf50',
  iconName: 'groceries.png',
  dateCreated: DateTime(2026, 1, 1),
  order: 0,
  income: false,
);

final _subDelivery = TransactionCategory(
  categoryPk: 's1',
  name: 'Delivery',
  colour: '0xff4caf50',
  iconName: 'cutlery.png',
  dateCreated: DateTime(2026, 1, 1),
  order: 0,
  income: false,
  mainCategoryPk: 'c1',
);

final _subPadaria = TransactionCategory(
  categoryPk: 's2',
  name: 'Padaria',
  colour: '0xff4caf50',
  iconName: 'coffee.png',
  dateCreated: DateTime(2026, 1, 1),
  order: 1,
  income: false,
  mainCategoryPk: 'c1',
);

final _catTransporte = TransactionCategory(
  categoryPk: 'c2',
  name: 'Transporte',
  colour: '0xff2196f3',
  iconName: 'car.png',
  dateCreated: DateTime(2026, 1, 1),
  order: 1,
  income: false,
);

final _catRenda = TransactionCategory(
  categoryPk: 'c3',
  name: 'Trabalho',
  colour: '0xff9c27b0',
  iconName: 'coin.png',
  dateCreated: DateTime(2026, 1, 1),
  order: 2,
  income: true,
);

final _titulo1 = TransactionAssociatedTitle(
  associatedTitlePk: 't1',
  categoryFk: 'c1',
  isExactMatch: false,
  title: 'iFood',
  dateCreated: DateTime(2026, 1, 1),
  order: 0,
);

final _titulo2 = TransactionAssociatedTitle(
  associatedTitlePk: 't2',
  categoryFk: 'c2',
  isExactMatch: false,
  title: 'Uber',
  dateCreated: DateTime(2026, 1, 2),
  order: 1,
);

Map<String, dynamic> _padroes = {};
Map<String, dynamic> _ajustes(String modo, {Map<String, dynamic>? extras}) => {
      ..._padroes,
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'forceFullDarkBackground': false,
      'outlinedIcons': true,
      'font': 'Geist',
      'selectedWalletPk': '0',
      'showExtraInfoText': true,
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'numberFormatCurrencyFirst': true,
      'customCurrencies': <dynamic>['btc'],
      'customCurrencyAmounts': <String, dynamic>{'eur': 0.95},
      'cachedCurrencyExchange': <String, dynamic>{
        'brl': 5.80,
        'usd': 1.0,
        'eur': 0.92,
        'gbp': 0.79,
        'cad': 1.38,
      },
      'locale': 'pt',
      'temaPronto': modo == 'claro' ? 'padrao-claro' : 'padrao-escuro',
      ...?extras,
    };

Widget _app(String modo, Widget home) {
  final b = modo == 'claro' ? Brightness.light : Brightness.dark;
  return Provider<AllWallets>.value(
    value: AllWallets(
      list: [_carteiraPadrao],
      indexedByPk: {'0': _carteiraPadrao},
    ),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: temaFlutter(temaAtivo(b)),
      home: home,
    ),
  );
}

Future<void> _prepararBanco(WidgetTester t, {bool vazio = false}) async {
  await t.runAsync(() async {
    await database.delete(database.deleteLogs).go();
    await database.delete(database.transactions).go();
    await database.delete(database.associatedTitles).go();
    await database.delete(database.categories).go();
    await database.delete(database.wallets).go();
    recentlyDeletedTransactions.clear();

    await database.into(database.wallets).insert(_carteiraPadrao);
    if (vazio) return;

    for (final c in [
      _catAlimentacao,
      _subDelivery,
      _subPadaria,
      _catTransporte,
      _catRenda,
    ]) {
      await database.into(database.categories).insert(c);
    }

    for (final tt in [_titulo1, _titulo2]) {
      await database.into(database.associatedTitles).insert(tt);
    }

    final agora = DateTime(2026, 11, 17, 14, 30);
    await database.into(database.transactions).insert(
          Transaction(
            transactionPk: 'tx1',
            name: 'Pão de Açúcar',
            amount: -182.30,
            note: 'Compras da semana',
            categoryFk: 'c1',
            subCategoryFk: 's1',
            walletFk: '0',
            dateCreated: DateTime(2026, 11, 16, 10, 0),
            dateTimeModified: agora.subtract(const Duration(hours: 2)),
            income: false,
            paid: true,
            skipPaid: false,
          ),
        );
    await database.into(database.transactions).insert(
          Transaction(
            transactionPk: 'tx2',
            name: 'Internet Fibra',
            amount: -129.90,
            note: '',
            categoryFk: 'c2',
            walletFk: '0',
            dateCreated: DateTime(2026, 11, 25, 9, 0),
            dateTimeModified: agora.subtract(const Duration(days: 1)),
            income: false,
            paid: false,
            skipPaid: false,
            type: TransactionSpecialType.upcoming,
            upcomingTransactionNotification: true,
          ),
        );

    final apagada = Transaction(
      transactionPk: 'del1',
      name: 'Uber',
      amount: -27.90,
      note: '',
      categoryFk: 'c2',
      walletFk: '0',
      dateCreated: DateTime(2026, 11, 15, 18, 0),
      dateTimeModified: agora.subtract(const Duration(hours: 5)),
      income: false,
      paid: true,
      skipPaid: false,
    );
    addTransactionToRecentlyDeleted(apagada, save: false);
    await database.into(database.deleteLogs).insert(
          DeleteLog(
            deleteLogPk: 'dl1',
            entryPk: 'del1',
            type: DeleteLogType.Transaction,
            dateTimeModified: agora.subtract(const Duration(hours: 1)),
          ),
        );
    await database.into(database.deleteLogs).insert(
          DeleteLog(
            deleteLogPk: 'dl2',
            entryPk: 'del_antiga',
            type: DeleteLogType.Transaction,
            dateTimeModified: agora.subtract(const Duration(days: 2)),
          ),
        );
  });
}

Future<void> _precarregarImagens(WidgetTester t) async {
  final encontrados = find.byType(MaterialApp);
  if (encontrados.evaluate().isEmpty) return;
  final ctx = t.element(encontrados.first);
  await t.runAsync(() async {
    await precacheImage(const AssetImage('assets/icon/icon-small.png'), ctx);
    for (final ic in [
      'groceries.png',
      'car.png',
      'coin.png',
      'coffee.png',
      'cutlery.png',
      'price-tag.png',
    ]) {
      await precacheImage(AssetImage('assets/categories/$ic'), ctx);
    }
    await Future.delayed(const Duration(milliseconds: 150));
  });
}

Future<void> _print(
  WidgetTester t,
  String modo,
  String nome,
  Widget tela, {
  double altura = 844,
  bool vazio = false,
  Map<String, dynamic>? extras,
  Future<void> Function(WidgetTester)? aposMontar,
}) async {
  await _prepararBanco(t, vazio: vazio);
  appStateSettings = _ajustes(modo, extras: extras);
  t.view.physicalSize = Size(390 * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(modo, tela));
  await _precarregarImagens(t);
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  if (aposMontar != null) {
    await aposMontar(t);
    for (var i = 0; i < 15; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }
  await expectLater(find.byType(MaterialApp),
      matchesGoldenFile('../../.verificacao/prints/config_${nome}_$modo.png'));
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 2));
}

Future<void> _printDesktop(
  WidgetTester t,
  String nome,
  Widget tela, {
  double altura = 900,
  bool vazio = false,
  Map<String, dynamic>? extras,
}) async {
  await _prepararBanco(t, vazio: vazio);
  appStateSettings = _ajustes('claro', extras: extras);
  t.view.physicalSize = Size(1440, altura);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app('claro', tela));
  await _precarregarImagens(t);
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile(
        '../../.verificacao/prints/config_${nome}_desktop_claro.png'),
  );
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 2));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    database = FinanceDatabase(NativeDatabase.memory());
    _padroes = await getDefaultPreferences();
    await loadCurrencyJSON();
    await loadLanguageNamesJSON();
    const f = 'assets/fonts/';
    await _fonte('Geist', [
      '${f}Geist-Regular.ttf',
      '${f}Geist-Medium.ttf',
      '${f}Geist-SemiBold.ttf',
    ]);
    await _fonte('GeistMono',
        ['${f}GeistMono-Regular.ttf', '${f}GeistMono-SemiBold.ttf']);
    final sdk = Platform.environment['FLUTTER_ROOT'] ??
        'C:/Users/mendo/development/flutter-3.24.5';
    await _fonte('MaterialIcons',
        ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  tearDownAll(() async {
    await database.close();
  });

  for (final modo in ['claro', 'escuro']) {
    testWidgets('print configurações $modo', skip: _pular, (t) async {
      await _print(t, modo, 'lista', const SettingsPageFramework(),
          altura: 1900);
    });

    testWidgets('print mais ajustes $modo', skip: _pular, (t) async {
      await _print(t, modo, 'avancado', const MoreOptionsPagePreferences(),
          altura: 1500);
    });

    testWidgets('print sobre $modo', skip: _pular, (t) async {
      await _print(t, modo, 'sobre', const AboutPage());
    });

    testWidgets('print créditos $modo', skip: _pular, (t) async {
      await _print(t, modo, 'creditos', const CreditosPage(), altura: 1200);
    });

    testWidgets('print onboarding $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'onboarding',
        const OnBoardingPage(
          popNavigationWhenDone: false,
          showPreviewDemoButton: false,
        ),
      );
    });

    testWidgets('print onboarding pelo sobre $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'onboarding_sobre',
        const OnBoardingPage(
          popNavigationWhenDone: true,
          showPreviewDemoButton: false,
        ),
      );
    });

    testWidgets('print categorias com dados $modo', skip: _pular, (t) async {
      await _print(t, modo, 'categorias_dados', EditCategoriesPage());
    });

    testWidgets('print categorias vazio $modo', skip: _pular, (t) async {
      await _print(t, modo, 'categorias_vazio', EditCategoriesPage(),
          vazio: true);
    });

    testWidgets('print categorias busca vazia $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'categorias_busca_vazia',
        EditCategoriesPage(),
        aposMontar: (t) async {
          await t.enterText(find.byType(TextInput).first, 'inexistente');
        },
      );
    });

    testWidgets('print nova categoria validação $modo', skip: _pular,
        (t) async {
      await _print(
        t,
        modo,
        'categoria_nova',
        AddCategoryPage(routesToPopAfterDelete: RoutesToPopAfterDelete.None),
      );
    });

    testWidgets('print editar categoria $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'categoria_editar',
        AddCategoryPage(
          category: _catAlimentacao,
          routesToPopAfterDelete: RoutesToPopAfterDelete.One,
        ),
        altura: 1050,
      );
    });

    testWidgets('print títulos com dados $modo', skip: _pular, (t) async {
      await _print(t, modo, 'titulos_dados', EditAssociatedTitlesPage());
    });

    testWidgets('print títulos vazio $modo', skip: _pular, (t) async {
      await _print(t, modo, 'titulos_vazio', EditAssociatedTitlesPage(),
          vazio: true);
    });

    testWidgets('print títulos busca vazia $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'titulos_busca_vazia',
        EditAssociatedTitlesPage(),
        aposMontar: (t) async {
          await t.enterText(find.byType(TextInput).first, 'inexistente');
        },
      );
    });

    testWidgets('print novo título $modo', skip: _pular, (t) async {
      await _prepararBanco(t);
      appStateSettings = _ajustes(modo);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(
          modo,
          Scaffold(
            body: Builder(
              builder: (c) => Center(
                child: TextButton(
                  onPressed: () => openBottomSheet(
                      c, AddAssociatedTitlePage(),
                      popupWithKeyboard: true),
                  child: const Text('abrir'),
                ),
              ),
            ),
          )));
      await _precarregarImagens(t);
      await t.tap(find.text('abrir'));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../../.verificacao/prints/config_titulo_$modo.png'));
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('print editar título $modo', skip: _pular, (t) async {
      await _prepararBanco(t);
      appStateSettings = _ajustes(modo);
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(
          modo,
          Scaffold(
            body: Builder(
              builder: (c) => Center(
                child: TextButton(
                  onPressed: () => openBottomSheet(
                      c,
                      AddAssociatedTitlePage(associatedTitle: _titulo1),
                      popupWithKeyboard: true),
                  child: const Text('abrir'),
                ),
              ),
            ),
          )));
      await _precarregarImagens(t);
      await t.tap(find.text('abrir'));
      for (var i = 0; i < 25; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
              '../../.verificacao/prints/config_titulo_editar_$modo.png'));
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('print notificações desativadas $modo', skip: _pular,
        (t) async {
      await _print(
        t,
        modo,
        'notificacoes_desativadas',
        const NotificationsPage(),
        extras: {
          'notifications': false,
          'notificationsUpcomingTransactions': false,
        },
      );
    });

    testWidgets('print notificações ativas $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'notificacoes_ativas',
        const NotificationsPage(),
        extras: {
          'notifications': true,
          'notificationsUpcomingTransactions': true,
          'notificationsReminderType': 0,
          'notificationHour': 20,
          'notificationMinute': 0,
        },
      );
    });

    testWidgets('print câmbio com dados $modo', skip: _pular, (t) async {
      await _print(t, modo, 'cambio_dados', const ExchangeRates());
    });

    testWidgets('print câmbio busca vazia $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'cambio_vazio',
        const ExchangeRates(),
        aposMontar: (t) async {
          await t.enterText(find.byType(TextInput).first, 'inexistente');
        },
      );
    });

    testWidgets('print histórico com dados $modo', skip: _pular, (t) async {
      await _print(t, modo, 'historico_dados', const ActivityPage());
    });

    testWidgets('print histórico vazio $modo', skip: _pular, (t) async {
      await _print(t, modo, 'historico_vazio', const ActivityPage(),
          vazio: true);
    });

    testWidgets('print depuração $modo', skip: _pular, (t) async {
      await _print(t, modo, 'depuracao', const DebugPage(), altura: 1800);
    });
  }

  testWidgets('print configurações desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'lista', const MoreActionsPage(), altura: 1400);
  });

  testWidgets('print mais ajustes desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'avancado', const MoreOptionsPagePreferences(),
        altura: 1200);
  });

  testWidgets('print sobre desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'sobre', const AboutPage());
  });

  testWidgets('print créditos desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'creditos', const CreditosPage(), altura: 1000);
  });

  testWidgets('print onboarding desktop claro', skip: _pular, (t) async {
    await _printDesktop(
      t,
      'onboarding',
      const OnBoardingPage(
        popNavigationWhenDone: false,
        showPreviewDemoButton: false,
      ),
    );
  });

  testWidgets('print categorias desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'categorias', EditCategoriesPage());
  });

  testWidgets('print editar categoria desktop claro', skip: _pular, (t) async {
    await _printDesktop(
      t,
      'categoria',
      AddCategoryPage(
        category: _catAlimentacao,
        routesToPopAfterDelete: RoutesToPopAfterDelete.One,
      ),
      altura: 1000,
    );
  });

  testWidgets('print títulos desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'titulos', EditAssociatedTitlesPage());
  });

  testWidgets('print câmbio desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'cambio', const ExchangeRates());
  });

  testWidgets('print histórico desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'historico', const ActivityPage());
  });

  testWidgets('print depuração desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'depuracao', const DebugPage(), altura: 1500);
  });
}
