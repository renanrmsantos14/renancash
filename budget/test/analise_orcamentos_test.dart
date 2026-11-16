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
}
