// Deep links seguros: link de transação nunca grava sem confirmação; decodificação única;
// link de pareamento repetido abre um único popup.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/struct/throttler.dart';
import 'package:budget/widgets/navigationFramework.dart' show navigatorKey;
import 'package:budget/widgets/util/appLinks.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Table;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

final _token = 'mb_${'A' * 43}';

Uri _transacao(Map<String, String> q) =>
    Uri(scheme: 'https', host: 'cashewapp.web.app', path: '/addTransaction', queryParameters: q);

Uri _pareamento() =>
    Uri(scheme: 'meubanco', host: 'parear', queryParameters: {'u': 'https://exemplo.test', 't': _token});

/// Avança tempo real (banco em memória) e tempo falso (animações) até a condição valer.
Future<void> _ate(WidgetTester t, bool Function() ok) async {
  for (var i = 0; i < 300 && !ok(); i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump(const Duration(milliseconds: 50));
  }
}

bool _tem(String texto) => find.text(texto).evaluate().isNotEmpty;

final _carteira = TransactionWallet(
    walletPk: '0', name: 'Inter', dateCreated: DateTime(2026), order: 0, decimals: 2, currency: 'brl');

void main() {
  setUpAll(() {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  group('parseAppLink: decodifica uma vez só', () {
    test('% e acento chegam como o usuário digitou', () {
      final uri = Uri.parse(
          'https://cashewapp.web.app/addTransaction?title=50%25%20%C3%A7%C3%A3o&note=100%25');
      final p = parseAppLink(uri);
      expect(p['title'], '50% ção');
      expect(p['note'], '100%');
    });

    test('valor já codificado dentro do texto não é decodificado de novo', () {
      final uri = Uri.parse('https://cashewapp.web.app/addTransaction?title=a%2520b');
      expect(parseAppLink(uri)['title'], 'a%20b');
    });
  });

  group('transação por link', () {
    late List<TransacaoDeLink> gravadas;

    Future<void> preparar(WidgetTester t) async {
      t.view.physicalSize = const Size(800, 1400); // fonte de teste tem glifos largos
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        TestWidgetsFlutterBinding.ensureInitialized();
        SharedPreferences.setMockInitialValues({});
        sharedPreferences = await SharedPreferences.getInstance();
        database = FinanceDatabase(NativeDatabase.memory());
        await database.into(database.wallets).insert(WalletsCompanion.insert(
            walletPk: const Value('0'), name: 'Inter', order: 0, currency: const Value('brl')));
        await database.into(database.categories).insert(CategoriesCompanion.insert(
            categoryPk: const Value('c1'), name: 'Mercado', order: 0, income: const Value(false)));
      });
      addTearDown(() => database.close());
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'appAnimations': 0,
        'hasOnboarded': true,
        'selectedWalletPk': '0',
        'outlinedIcons': false,
      };
      appLinksThrottler = Throttler(duration: Duration.zero);
      gravadas = [];
      gravadorDeLink = (item) async {
        gravadas.add(item);
        return null;
      };
      addTearDown(() => gravadorDeLink = gravarTransacaoDeLink);
      await t.pumpWidget(Provider<AllWallets>.value(
        value: AllWallets(list: [_carteira], indexedByPk: {'0': _carteira}),
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: temaFlutter(temaPorId('padrao-claro')),
          home: const Scaffold(body: SizedBox()),
        ),
      ));
    }

    testWidgets('transação única abre a confirmação e não grava antes dela', (t) async {
      await preparar(t);
      var terminou = false;
      unawaited(executeAppLink(navigatorKey.currentContext,
              _transacao({'amount': '-12.5', 'categoryPk': 'c1', 'title': 'Pão'}))
          .whenComplete(() => terminou = true));
      await _ate(t, () => _tem('Adicionar'));

      expect(find.text('Adicionar esta transação?'), findsOneWidget);
      expect(find.textContaining('Categoria: Mercado'), findsOneWidget);
      expect(find.textContaining('Conta: Inter'), findsOneWidget);
      expect(find.textContaining('Título: Pão'), findsOneWidget);
      expect(gravadas, isEmpty);

      await t.tap(find.text('Adicionar'));
      await _ate(t, () => terminou);
      expect(gravadas, hasLength(1));
      expect(gravadas.single.amount, -12.5);
      expect(gravadas.single.main.categoryPk, 'c1');
      expect(gravadas.single.title, 'Pão');
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('cancelar não grava nada', (t) async {
      await preparar(t);
      var terminou = false;
      unawaited(executeAppLink(
              navigatorKey.currentContext, _transacao({'amount': '-3', 'categoryPk': 'c1'}))
          .whenComplete(() => terminou = true));
      await _ate(t, () => _tem('Cancelar'));
      await t.tap(find.text('Cancelar'));
      await _ate(t, () => terminou);
      expect(gravadas, isEmpty);
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('% e acento no título chegam inteiros à confirmação e à gravação', (t) async {
      await preparar(t);
      var terminou = false;
      unawaited(executeAppLink(
              navigatorKey.currentContext,
              Uri.parse(
                  'https://cashewapp.web.app/addTransaction?amount=-8&categoryPk=c1&title=50%25%20%C3%A7%C3%A3o'))
          .whenComplete(() => terminou = true));
      await _ate(t, () => _tem('Adicionar'));
      expect(find.textContaining('Título: 50% ção'), findsOneWidget);
      await t.tap(find.text('Adicionar'));
      await _ate(t, () => terminou);
      expect(gravadas.single.title, '50% ção');
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('lote mostra contagem e total numa confirmação só', (t) async {
      await preparar(t);
      final json = jsonEncode({
        'transactions': [
          {'amount': -10, 'categoryPk': 'c1', 'title': 'A'},
          {'amount': -5.5, 'categoryPk': 'c1', 'title': 'B'},
          {'amount': -4.5, 'categoryPk': 'c1', 'title': 'C'},
        ]
      });
      var terminou = false;
      unawaited(executeAppLink(navigatorKey.currentContext, _transacao({'JSON': json}))
          .whenComplete(() => terminou = true));
      await _ate(t, () => _tem('Adicionar'));

      expect(find.text('Adicionar 3 transações?'), findsOneWidget);
      expect(find.textContaining('3 transações. Total:'), findsOneWidget);
      expect(find.textContaining('20'), findsWidgets); // total de 20, qualquer formato de moeda
      expect(gravadas, isEmpty);

      await t.tap(find.text('Adicionar'));
      await _ate(t, () => terminou);
      expect(gravadas.map((g) => g.title), ['A', 'B', 'C']);
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('lote cancelado não grava nenhum item', (t) async {
      await preparar(t);
      final json = jsonEncode({
        'transactions': [
          {'amount': -1, 'categoryPk': 'c1'},
          {'amount': -2, 'categoryPk': 'c1'},
        ]
      });
      var terminou = false;
      unawaited(executeAppLink(navigatorKey.currentContext, _transacao({'JSON': json}))
          .whenComplete(() => terminou = true));
      await _ate(t, () => _tem('Cancelar'));
      await t.tap(find.text('Cancelar'));
      await _ate(t, () => terminou);
      expect(gravadas, isEmpty);
      await t.pump(const Duration(seconds: 1));
    });
  });

  group('pareamento por link', () {
    Future<void> montar(WidgetTester t, Throttler throttler) async {
      t.view.physicalSize = const Size(800, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'appAnimations': 0,
      };
      appLinksThrottler = throttler;
      await t.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        theme: temaFlutter(temaPorId('padrao-claro')),
        home: const Scaffold(body: SizedBox()),
      ));
    }

    testWidgets('o mesmo link duas vezes (cold start) abre um único popup', (t) async {
      // Throttler sem janela: prova que a deduplicação por si só segura o segundo disparo.
      await montar(t, Throttler(duration: Duration.zero));
      final fins = <Future<dynamic>>[];
      fins.add(executeAppLink(navigatorKey.currentContext, _pareamento()));
      fins.add(executeAppLink(navigatorKey.currentContext, _pareamento()));
      await _ate(t, () => _tem('Parear'));
      await t.pump(const Duration(milliseconds: 300));

      expect(find.text('Parear com exemplo.test?'), findsOneWidget);
      await t.tap(find.text('Cancelar'));
      await _ate(t, () => !_tem('Parear com exemplo.test?'));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Parear com exemplo.test?'), findsNothing);
      await Future.wait(fins);
    });

    testWidgets('o throttler também vale para o link de pareamento', (t) async {
      await montar(t, Throttler(duration: const Duration(seconds: 5)));
      final fins = <Future<dynamic>>[];
      fins.add(executeAppLink(navigatorKey.currentContext, _pareamento()));
      // Link diferente dentro da janela do throttler: ignorado.
      fins.add(executeAppLink(
          navigatorKey.currentContext,
          Uri(scheme: 'meubanco', host: 'parear', queryParameters: {
            'u': 'https://outro.test',
            't': 'mb_${'B' * 43}',
          })));
      await _ate(t, () => _tem('Parear'));
      await t.pump(const Duration(milliseconds: 300));

      expect(find.text('Parear com exemplo.test?'), findsOneWidget);
      expect(find.text('Parear com outro.test?'), findsNothing);
      await t.tap(find.text('Cancelar'));
      await _ate(t, () => !_tem('Parear com exemplo.test?'));
      await t.pump(const Duration(seconds: 6));
      await Future.wait(fins);
    });
  });
}
