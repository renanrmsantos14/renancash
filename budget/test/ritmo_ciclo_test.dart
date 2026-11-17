import 'package:budget/struct/ritmoCiclo.dart';
import 'package:flutter_test/flutter_test.dart';

String _brl(double v) => 'R\$ ${v.toStringAsFixed(2).replaceAll('.', ',')}';

void main() {
  // Ciclo do pedido: 6 nov – 5 dez = 30 dias.
  final ini = DateTime(2026, 11, 6), fim = DateTime(2026, 12, 5);

  group('fracaoDoCiclo (marca de hoje)', () {
    test('conta hoje: 17 nov é o 12º de 30 dias', () {
      expect(fracaoDoCiclo(ini, fim, DateTime(2026, 11, 17, 9)), closeTo(12 / 30, 1e-12));
    });

    test('primeiro dia = 1/n; último dia = 1 (a qualquer hora)', () {
      expect(fracaoDoCiclo(ini, fim, DateTime(2026, 11, 6)), closeTo(1 / 30, 1e-12));
      expect(fracaoDoCiclo(ini, fim, DateTime(2026, 12, 5, 23, 59)), 1.0);
    });

    test('ciclo de 31 dias', () {
      final a = DateTime(2026, 12, 6), b = DateTime(2027, 1, 5);
      expect(fracaoDoCiclo(a, b, DateTime(2026, 12, 21)), closeTo(16 / 31, 1e-12));
      expect(fracaoDoCiclo(a, b, DateTime(2027, 1, 5)), 1.0);
    });

    test('fora do ciclo não há marca', () {
      expect(fracaoDoCiclo(ini, fim, DateTime(2026, 11, 5, 23, 59)), isNull);
      expect(fracaoDoCiclo(ini, fim, DateTime(2026, 12, 6)), isNull);
    });

    test('fuso America/Sao_Paulo: 01:30 UTC de 18 nov ainda é 17 nov', () {
      expect(fracaoDoCiclo(ini, fim, DateTime.utc(2026, 11, 18, 1, 30)), closeTo(12 / 30, 1e-12));
      expect(fracaoDoCiclo(ini, fim, DateTime.utc(2026, 11, 18, 3)), closeTo(13 / 30, 1e-12));
      // 02:59 UTC de 6 nov = 23:59 de 5 nov em SP: antes do ciclo.
      expect(fracaoDoCiclo(ini, fim, DateTime.utc(2026, 11, 6, 2, 59)), isNull);
      expect(diaSaoPaulo(DateTime.utc(2026, 12, 6, 2)), DateTime.utc(2026, 12, 5));
    });
  });

  group('ideal até hoje', () {
    test('limite × fração', () {
      expect(idealAteHoje(1300, 12 / 30), closeTo(520, 1e-9));
      expect(idealAteHoje(1300, 1), 1300);
    });

    test('texto: acima, abaixo e no ritmo', () {
      expect(textoIdealHoje(668.96, 1300, 12 / 30, _brl),
          'Ideal até hoje R\$ 520,00 · R\$ 148,96 acima');
      expect(textoIdealHoje(400, 1300, 12 / 30, _brl),
          'Ideal até hoje R\$ 520,00 · R\$ 120,00 abaixo');
      expect(textoIdealHoje(520.2, 1300, 12 / 30, _brl),
          'Ideal até hoje R\$ 520,00 · no ritmo');
      expect(textoIdealHoje(100, 1000, .5, _brl, renda: true),
          'Meta até hoje R\$ 500,00 · R\$ 400,00 abaixo');
    });

    test('rótulo de leitor de tela', () {
      expect(semanticaBarraCiclo(668.96, 1300, 12 / 30),
          'Gasto 51% do limite; o ideal até hoje é 40%');
      expect(semanticaBarraCiclo(668.96, 1300, null), 'Gasto 51% do limite');
      expect(semanticaBarraCiclo(650, 1000, .5, renda: true),
          'Guardado 65% da meta; o ideal até hoje é 50%');
    });
  });
}
