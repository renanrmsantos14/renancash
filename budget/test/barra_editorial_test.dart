// Barra inferior Editorial: o rótulo acompanha a aba ativa com transição
// (os dois rótulos coexistem no meio do caminho) e some com "reduzir movimento".
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/meuBancoSync.dart' show meuBancoPareado;
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/bottomNavBar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _montar(WidgetTester t, {bool parado = false}) async {
  var pagina = 0;
  await t.pumpWidget(MaterialApp(
    theme: temaFlutter(temaAtivo(Brightness.light)),
    builder: (c, filho) => MediaQuery(
        data: MediaQuery.of(c).copyWith(disableAnimations: parado),
        child: filho!),
    home: StatefulBuilder(
      builder: (c, setState) => Scaffold(
        bottomNavigationBar: BottomNavBar(
          currentNavigationStackedIndex: pagina,
          onChanged: (i) => setState(() => pagina = i),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUp(() async {
    appStateSettings = {
      ...await getDefaultPreferences(),
      'locale': 'pt',
      'temaPronto': 'padrao-claro',
    };
    meuBancoPareado.value = true;
  });
  tearDown(() => meuBancoPareado.value = false);

  testWidgets('rótulo troca de aba com transição', (t) async {
    await _montar(t);
    expect(find.text('Início'), findsOneWidget);
    expect(find.text('Transações'), findsNothing);

    await t.tap(find.bySemanticsLabel('Transações'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 80));
    expect(find.text('Início'), findsOneWidget);
    expect(find.text('Transações'), findsOneWidget);

    await t.pumpAndSettle();
    expect(find.text('Início'), findsNothing);
    expect(find.text('Transações'), findsOneWidget);
  });

  testWidgets('com "reduzir movimento" a troca é direta', (t) async {
    await _montar(t, parado: true);
    await t.tap(find.bySemanticsLabel('Transações'));
    await t.pump();
    await t.pump();
    expect(find.text('Início'), findsNothing);
    expect(find.text('Transações'), findsOneWidget);
  });
}
