import 'dart:math';

import 'package:budget/struct/defaultPreferences.dart' show AppAnimations;
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {bool reduzir = false}) => MaterialApp(
      theme: temaEditorial(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduzir),
        child: Scaffold(body: child),
      ),
    );

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

  test('tokens iguais aos do spec (22 valores)', () {
    const c = EditorialCores.claro;
    expect([
      c.bg,
      c.surf,
      c.tx,
      c.mu,
      c.line,
      c.acc,
      c.warn,
      c.warnbg,
      c.warntx,
      c.pos,
      c.chip
    ], [
      const Color(0xFFFFFFFF),
      const Color(0xFFF6F6F5),
      const Color(0xFF111111),
      const Color(0xFF6E6E73),
      const Color(0xFFEDEDED),
      const Color(0xFF1F7A4C),
      const Color(0xFFB42318),
      const Color(0xFFFDEBEC),
      const Color(0xFF9F2F2D),
      const Color(0xFF2F7A4A),
      const Color(0xFFF2F2F1),
    ]);
    const d = EditorialCores.escuro;
    expect([
      d.bg,
      d.surf,
      d.tx,
      d.mu,
      d.line,
      d.acc,
      d.warn,
      d.warnbg,
      d.warntx,
      d.pos,
      d.chip
    ], [
      const Color(0xFF0B0B0C),
      const Color(0xFF151516),
      const Color(0xFFF2F2F2),
      const Color(0xFF8E8E93),
      const Color.fromRGBO(255, 255, 255, .07),
      const Color(0xFF5CC783),
      const Color(0xFFF0726B),
      const Color.fromRGBO(240, 114, 107, .12),
      const Color(0xFFF59A94),
      const Color(0xFF6FD394),
      const Color(0xFF1C1C1E),
    ]);
  });

  test('temaEditorial carrega a extensão e o fundo certos', () {
    final escuro = temaEditorial(Brightness.dark);
    expect(escuro.extension<EditorialCores>()!.acc, const Color(0xFF5CC783));
    expect(escuro.scaffoldBackgroundColor, const Color(0xFF0B0B0C));
    expect(temaEditorial(Brightness.light).scaffoldBackgroundColor,
        const Color(0xFFFFFFFF));
  });

  testWidgets('ContagemValor chega ao texto final após 900ms', (t) async {
    await t.pumpWidget(
        _app(ContagemValor(valor: 100, formatar: (v) => 'R\$ ${v.round()}')));
    expect(find.text('R\$ 0'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 900));
    expect(find.text('R\$ 100'), findsOneWidget);
  });

  group('EntradaSuave', () {
    Finder fade() => find.descendant(
        of: find.byType(EntradaSuave), matching: find.byType(FadeTransition));
    setUp(() => appStateSettings["appAnimations"] = AppAnimations.all.index);

    testWidgets('entra com fade e termina opaco', (t) async {
      await t.pumpWidget(_app(const EntradaSuave(child: Text('a'))));
      expect(t.widget<FadeTransition>(fade()).opacity.value, 0);
      await t.pump(const Duration(milliseconds: 250));
      expect(t.widget<FadeTransition>(fade()).opacity.value, 1);
    });

    testWidgets('cascata só nos 8 primeiros', (t) async {
      await t.pumpWidget(_app(const EntradaSuave(indice: 8, child: Text('a'))));
      expect(fade(), findsNothing);
    });

    testWidgets('fora da janela de entrada aparece direto', (t) async {
      await t.pumpWidget(
          _app(const EntradaSuave(animar: false, child: Text('a'))));
      expect(fade(), findsNothing);
    });

    testWidgets('nada com reduzir movimento ou animações desligadas',
        (t) async {
      await t.pumpWidget(
          _app(const EntradaSuave(child: Text('a')), reduzir: true));
      expect(fade(), findsNothing);
      appStateSettings["appAnimations"] = AppAnimations.disabled.index;
      await t.pumpWidget(
          _app(const EntradaSuave(key: Key('b'), child: Text('b'))));
      expect(fade(), findsNothing);
    });
  });

  testWidgets('MedidorEditorial limita a fração em 1', (t) async {
    await t.pumpWidget(_app(const MedidorEditorial(fracao: 1.4)));
    await t.pump(const Duration(milliseconds: 900));
    final m = t
        .widgetList<FractionallySizedBox>(find.descendant(
            of: find.byType(MedidorEditorial),
            matching: find.byType(FractionallySizedBox)))
        .single;
    expect(m.widthFactor, 1.0);
    expect(find.byKey(const Key('marca-hoje')), findsNothing);
  });

  testWidgets('MedidorEditorial: faixa a vencer após o gasto e marca de hoje no tempo', (t) async {
    await t.pumpWidget(_app(const Center(
        child: SizedBox(
            width: 300,
            child: MedidorEditorial(
                fracao: .5, aVencer: .2, hoje: .4, altura: 6)))));
    await t.pump(const Duration(milliseconds: 900));
    final faixas = t
        .widgetList<FractionallySizedBox>(find.descendant(
            of: find.byType(MedidorEditorial),
            matching: find.byType(FractionallySizedBox)))
        .map((f) => f.widthFactor)
        .toList();
    expect(faixas, [closeTo(.7, 1e-9), closeTo(.5, 1e-9)]);
    final marca = t.getRect(find.byKey(const Key('marca-hoje')));
    final barra = t.getRect(find.byType(MedidorEditorial));
    expect(marca.center.dx - barra.left, closeTo(120, .01));
    expect(marca.height, 6 + 8);
  });

  test('tema editorial dá contraste legível nos papéis de container usados pelo RenanCash', () {
    double contraste(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
    }

    for (final b in Brightness.values) {
      final c = temaEditorial(b).colorScheme;
      final pares = {
        'onPrimaryContainer/surface': (c.onPrimaryContainer, c.surface),
        'onPrimaryContainer/primaryContainer': (c.onPrimaryContainer, c.primaryContainer),
        'onSecondaryContainer/secondaryContainer': (c.onSecondaryContainer, c.secondaryContainer),
        'onSurface/surface': (c.onSurface, c.surface),
      };
      pares.forEach((nome, par) {
        expect(contraste(par.$1, par.$2), greaterThanOrEqualTo(4.5), reason: '$b $nome');
      });
    }
  });
}
