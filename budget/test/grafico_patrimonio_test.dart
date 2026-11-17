import 'package:budget/pages/homePage/homePageLineGraph.dart' show ancorarNoFim;
import 'package:budget/widgets/lineGraph.dart' show Pair;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('gráfico do patrimônio ancorado no total real', () {
    test('o ponto mais recente vira o patrimônio e o formato da curva é mantido', () {
      // Soma local das carteiras (~R$ 5,9 mil) contra o Patrimônio real de R$ 1.890,26.
      final r = ancorarNoFim(
          [Pair(0, 5000), Pair(15, 5600), Pair(30, 5898.99)], 1890.26);
      expect(r.delta, closeTo(1890.26 - 5898.99, 1e-9));
      expect(r.pontos.last.y, closeTo(1890.26, 1e-9));
      expect(r.pontos.first.y - r.pontos.last.y, closeTo(5000 - 5898.99, 1e-9));
      expect(r.pontos.map((p) => p.x), [0, 15, 30]);
    });

    test('usa o maior x mesmo fora de ordem; sem pontos não desloca', () {
      final r = ancorarNoFim([Pair(30, 100), Pair(0, 40)], 70);
      expect(r.pontos.first.y, 70);
      expect(r.pontos.last.y, 10);
      expect(ancorarNoFim([], 10).delta, 0);
    });
  });
}
