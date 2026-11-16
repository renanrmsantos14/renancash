import 'package:budget/pages/analiseOrcamentos.dart';
import 'package:budget/struct/meuBancoSync.dart' show meuBancoPareado;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app não pareado: Orçamentos fica sem a seção Análise', (t) async {
    meuBancoPareado.value = false;
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: AnaliseOrcamentos())));
    expect(find.text('Análise'), findsNothing);
  });

  testWidgets('computador pareado: Análise fica na Início antiga, não em Orçamentos', (t) async {
    meuBancoPareado.value = true;
    addTearDown(() => meuBancoPareado.value = false);
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: AnaliseOrcamentos())));
    expect(find.text('Análise'), findsNothing);
  });
}
