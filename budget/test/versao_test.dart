import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart' show mbRotaEmpilhada;
import 'package:budget/widgets/editorial/versaoCanto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    appStateSettings = {
      "materialYou": false,
      "accentSystemColor": false,
      "batterySaver": false,
      "increaseTextContrast": false,
      "forceFullDarkBackground": false,
    };
  });

  test('textoVersao', () {
    expect(
        textoVersao('5.4.4', '09/11/2026 14:20'), 'v5.4.4 · 09/11/2026 14:20');
  });

  testWidgets('celular com página empilhada: versão numa faixa abaixo do conteúdo',
      (tester) async {
    // Abaixo de 1100 px a versão fica na barra inferior; com página empilhada ganha faixa
    // própria, que encolhe o app em vez de ficar sobre a última linha.
    mbRotaEmpilhada.value = true;
    addTearDown(() => mbRotaEmpilhada.value = false);
    const conteudo = Key('conteudo');
    await tester.pumpWidget(MaterialApp(
      theme: temaEditorial(Brightness.light),
      home: VersaoCanto(
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: Container(key: conteudo, width: 300, height: 60),
          ),
        ),
      ),
    ));
    final texto = find.textContaining('· dev');
    expect(texto, findsOneWidget);
    expect(tester.getRect(find.byKey(conteudo)).bottom,
        lessThanOrEqualTo(tester.getRect(texto).top));
  });

  testWidgets('desktop: versão no canto não bloqueia toques', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    mbRotaEmpilhada.value = true;
    addTearDown(() => mbRotaEmpilhada.value = false);
    var toques = 0;
    await tester.pumpWidget(MaterialApp(
      theme: temaEditorial(Brightness.light),
      home: VersaoCanto(
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => toques++,
              child: const SizedBox(width: 300, height: 60),
            ),
          ),
        ),
      ),
    ));
    final texto = find.textContaining('· dev');
    expect(texto, findsOneWidget);
    await tester.tap(texto, warnIfMissed: false);
    expect(toques, 1);
  });
}
