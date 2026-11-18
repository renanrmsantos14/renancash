import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/tipoMovimento.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Contraste WCAG entre duas cores opacas.
double _contraste(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

void main() {
  group('tipo de movimento', () {
    test('gasto e receita pelo sinal; categoria define os demais tipos', () {
      expect(mbTipoMov(valor: -50, categoria: 'Alimentação fora'), TipoMov.gasto);
      expect(mbTipoMov(valor: -800, categoria: 'Família'), TipoMov.gasto); // ajuda ao pai
      expect(mbTipoMov(valor: 5000, categoria: 'Salário'), TipoMov.receita);
      expect(mbTipoMov(valor: 60, categoria: 'Alimentação fora'), TipoMov.receita);
      expect(mbTipoMov(valor: -300, categoria: 'Investimentos'), TipoMov.investimento);
      expect(mbTipoMov(valor: 2, categoria: 'Poupança'), TipoMov.investimento);
      expect(mbTipoMov(valor: -100, investimento: true), TipoMov.investimento);
      expect(mbTipoMov(valor: -800, categoria: 'Empréstimo'), TipoMov.emprestimo);
      expect(mbTipoMov(valor: -800, emprestimo: true), TipoMov.emprestimo);
      expect(mbTipoMov(valor: -1200, categoria: 'Pagamento de fatura'), TipoMov.transferencia);
      expect(mbTipoMov(valor: -90, categoria: 'Transferências'), TipoMov.transferencia);
      expect(mbTipoMov(valor: -68.9, categoria: 'A classificar'), TipoMov.aClassificar);
      expect(mbTipoMov(valor: -68.9), TipoMov.gasto);
    });

    test('cada tipo tem ícone e cor própria, e o texto passa de 4,5:1 nos dois temas', () {
      for (final (tema, fundo) in [(EditorialCores.claro, EditorialCores.claro.bg), (EditorialCores.escuro, EditorialCores.escuro.bg)]) {
        final cs = [tema.tGasto, tema.tReceita, tema.tInvest, tema.tEmpr, tema.tTransf];
        expect(cs.toSet().length, 5);
        for (final c in cs) {
          expect(_contraste(c, fundo), greaterThanOrEqualTo(4.5), reason: '$c');
        }
      }
      expect({for (final t in TipoMov.values) t.icone}.length, TipoMov.values.length);
    });
  });
}
