// Prints das Configurações e cadastros (Etapa 5 da revisão de UI) para revisão visual.
// Só roda com PRINTS=1:
//   PRINTS=1 flutter test test/prints_configuracoes_test.dart --update-goldens
// Os PNGs vão para .verificacao/prints/config_*.png (fora do git).
// Sem EasyLocalization os textos .tr() saem como chave; os textos novos
// (grupos, descrições) já são pt-BR literais.
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/aboutPage.dart';
import 'package:budget/pages/activityPage.dart';
import 'package:budget/pages/addAssociatedTitlePage.dart';
import 'package:budget/pages/addCategoryPage.dart';
import 'package:budget/pages/debugPage.dart';
import 'package:budget/pages/editAssociatedTitlesPage.dart';
import 'package:budget/pages/editCategoriesPage.dart';
import 'package:budget/pages/exchangeRatesPage.dart';
import 'package:budget/pages/notificationsPage.dart';
import 'package:budget/pages/onBoardingPage.dart';
import 'package:budget/pages/settingsPage.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/languageMap.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/textInput.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide TextInput;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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

final _categoriasPrincipais = [
  CategoryWithDetails(category: _catAlimentacao, numberTransactions: 28),
  CategoryWithDetails(category: _catTransporte, numberTransactions: 14),
  CategoryWithDetails(category: _catRenda, numberTransactions: 2),
];

final _subcategoriasPorPai = {
  'c1': [_subDelivery, _subPadaria],
};

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

final _titulosComCategoria = [
  TransactionAssociatedTitleWithCategory(
    title: _titulo1,
    category: _catAlimentacao,
  ),
  TransactionAssociatedTitleWithCategory(
    title: _titulo2,
    category: _catTransporte,
  ),
];

final _txEditada = Transaction(
  transactionPk: 'tx1',
  name: 'Pão de Açúcar',
  amount: -182.30,
  note: 'Compras da semana',
  categoryFk: 'c1',
  subCategoryFk: 's1',
  walletFk: '0',
  dateCreated: DateTime(2026, 11, 16, 10, 0),
  dateTimeModified: DateTime.now().subtract(const Duration(hours: 2)),
  income: false,
  paid: true,
  skipPaid: false,
);

final _txApagada = Transaction(
  transactionPk: 'del1',
  name: 'Uber',
  amount: -27.90,
  note: '',
  categoryFk: 'c2',
  walletFk: '0',
  dateCreated: DateTime(2026, 11, 15, 18, 0),
  dateTimeModified: DateTime.now().subtract(const Duration(hours: 5)),
  income: false,
  paid: true,
  skipPaid: false,
);

final _txAgendada = Transaction(
  transactionPk: 'tx2',
  name: 'Internet Fibra',
  amount: -129.90,
  note: '',
  categoryFk: 'c2',
  walletFk: '0',
  dateCreated: DateTime(2026, 11, 25, 9, 0),
  dateTimeModified: DateTime.now().subtract(const Duration(days: 1)),
  income: false,
  paid: false,
  skipPaid: false,
  type: TransactionSpecialType.upcoming,
  upcomingTransactionNotification: true,
);

List<TransactionActivityLog> _logsHistorico() {
  final agora = DateTime.now();
  return [
    TransactionActivityLog(
      dateTime: agora.subtract(const Duration(hours: 1)),
      deleteLog: DeleteLog(
        deleteLogPk: 'dl1',
        entryPk: 'del1',
        type: DeleteLogType.Transaction,
        dateTimeModified: agora.subtract(const Duration(hours: 1)),
      ),
      transaction: _txApagada,
      transactionWithCategory: TransactionWithCategory(
        category: _catTransporte,
        transaction: _txApagada,
      ),
    ),
    TransactionActivityLog(
      dateTime: agora.subtract(const Duration(hours: 2)),
      transaction: _txEditada,
      transactionWithCategory: TransactionWithCategory(
        category: _catAlimentacao,
        subCategory: _subDelivery,
        transaction: _txEditada,
      ),
    ),
    TransactionActivityLog(
      dateTime: agora.subtract(const Duration(days: 2)),
      deleteLog: DeleteLog(
        deleteLogPk: 'dl2',
        entryPk: 'del_antiga',
        type: DeleteLogType.Transaction,
        dateTimeModified: agora.subtract(const Duration(days: 2)),
      ),
      transaction: null,
    ),
  ];
}

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

Future<void> _decodificarImagens(WidgetTester t) async {
  final encontrados = find.byType(MaterialApp);
  if (encontrados.evaluate().isNotEmpty) {
    final ctx = t.element(encontrados.first);
    precacheImage(const AssetImage('assets/icon/icon-small.png'), ctx);
    for (final ic in [
      'groceries.png',
      'car.png',
      'coin.png',
      'coffee.png',
      'cutlery.png',
      'price-tag.png',
    ]) {
      precacheImage(AssetImage('assets/categories/$ic'), ctx);
    }
  }
  await t.runAsync(() => Future.delayed(const Duration(milliseconds: 350)));
}

Future<void> _print(
  WidgetTester t,
  String modo,
  String nome,
  Widget tela, {
  double altura = 844,
  Map<String, dynamic>? extras,
  Future<void> Function(WidgetTester)? aposMontar,
}) async {
  appStateSettings = _ajustes(modo, extras: extras);
  t.view.physicalSize = Size(390 * 2, altura * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(modo, tela));
  await _decodificarImagens(t);
  for (var i = 0; i < 15; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  if (aposMontar != null) {
    await aposMontar(t);
    for (var i = 0; i < 10; i++) {
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
  Map<String, dynamic>? extras,
}) async {
  appStateSettings = _ajustes('claro', extras: extras);
  t.view.physicalSize = Size(1440, altura);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app('claro', tela));
  await _decodificarImagens(t);
  for (var i = 0; i < 15; i++) {
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
          initializeDb: false,
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
          initializeDb: false,
        ),
      );
    });

    testWidgets('print categorias com dados $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'categorias_dados',
        EditCategoriesPage(
          categoriesForTest: _categoriasPrincipais,
          subCategoriesForTest: _subcategoriasPorPai,
        ),
      );
    });

    testWidgets('print categorias vazio $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'categorias_vazio',
        EditCategoriesPage(
          categoriesForTest: const [],
          subCategoriesForTest: const {},
        ),
      );
    });

    testWidgets('print categorias busca vazia $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'categorias_busca_vazia',
        EditCategoriesPage(
          categoriesForTest: _categoriasPrincipais,
          subCategoriesForTest: _subcategoriasPorPai,
        ),
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
        AddCategoryPage(
          routesToPopAfterDelete: RoutesToPopAfterDelete.None,
          mainCategoriesForTest: [
            _catAlimentacao,
            _catTransporte,
            _catRenda,
          ],
          testMode: true,
        ),
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
          subCategoriesForTest: [_subDelivery, _subPadaria],
          subCategoryCountsForTest: const {'s1': 18, 's2': 10},
          titlesForTest: [_titulo1],
          testMode: true,
        ),
        altura: 1050,
      );
    });

    testWidgets('print títulos com dados $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'titulos_dados',
        EditAssociatedTitlesPage(titlesForTest: _titulosComCategoria),
      );
    });

    testWidgets('print títulos vazio $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'titulos_vazio',
        EditAssociatedTitlesPage(titlesForTest: const []),
      );
    });

    testWidgets('print títulos busca vazia $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'titulos_busca_vazia',
        EditAssociatedTitlesPage(titlesForTest: _titulosComCategoria),
        aposMontar: (t) async {
          await t.enterText(find.byType(TextInput).first, 'inexistente');
        },
      );
    });

    testWidgets('print novo título $modo', skip: _pular, (t) async {
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
                      AddAssociatedTitlePage(
                        associatedTitle: _titulo1,
                        initialCategory: _catAlimentacao,
                      ),
                      popupWithKeyboard: true),
                  child: const Text('abrir'),
                ),
              ),
            ),
          )));
      await _decodificarImagens(t);
      await t.tap(find.text('abrir'));
      for (var i = 0; i < 20; i++) {
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
        const NotificationsPage(
          notificationsEnabledForTest: false,
          upcomingForTest: [],
        ),
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
        NotificationsPage(
          notificationsEnabledForTest: true,
          upcomingForTest: [(_txAgendada, _catTransporte)],
        ),
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
      await _print(
        t,
        modo,
        'historico_dados',
        ActivityPage(logsForTest: _logsHistorico()),
      );
    });

    testWidgets('print histórico vazio $modo', skip: _pular, (t) async {
      await _print(
        t,
        modo,
        'historico_vazio',
        const ActivityPage(logsForTest: []),
      );
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
        initializeDb: false,
      ),
    );
  });

  testWidgets('print categorias desktop claro', skip: _pular, (t) async {
    await _printDesktop(
      t,
      'categorias',
      EditCategoriesPage(
        categoriesForTest: _categoriasPrincipais,
        subCategoriesForTest: _subcategoriasPorPai,
      ),
    );
  });

  testWidgets('print editar categoria desktop claro', skip: _pular, (t) async {
    await _printDesktop(
      t,
      'categoria',
      AddCategoryPage(
        category: _catAlimentacao,
        routesToPopAfterDelete: RoutesToPopAfterDelete.One,
        subCategoriesForTest: [_subDelivery, _subPadaria],
        subCategoryCountsForTest: const {'s1': 18, 's2': 10},
        titlesForTest: [_titulo1],
        testMode: true,
      ),
      altura: 1000,
    );
  });

  testWidgets('print títulos desktop claro', skip: _pular, (t) async {
    await _printDesktop(
      t,
      'titulos',
      EditAssociatedTitlesPage(titlesForTest: _titulosComCategoria),
    );
  });

  testWidgets('print câmbio desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'cambio', const ExchangeRates());
  });

  testWidgets('print histórico desktop claro', skip: _pular, (t) async {
    await _printDesktop(
      t,
      'historico',
      ActivityPage(logsForTest: _logsHistorico()),
    );
  });

  testWidgets('print depuração desktop claro', skip: _pular, (t) async {
    await _printDesktop(t, 'depuracao', const DebugPage(), altura: 1500);
  });
}
