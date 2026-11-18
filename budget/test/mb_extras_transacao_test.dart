import 'package:budget/struct/mbSync/extrasTransacao.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extras do pull: incremental mescla, completo substitui, transação sem extra perde os antigos', () {
    final antigos = {
      'a': {'c': 'Maria'},
      'b': {'f': '2026-11'},
    };
    final novos = [
      {'id': 'b', 'contraparte': null},
      {'id': 'c', 'contraparte': ' João ', 'metodo': 'PIX', 'bill_month': '2026-12'},
      {'id': 'd'},
    ];
    expect(mbMesclarExtras(antigos, novos, completo: false), {
      'a': {'c': 'Maria'},
      'c': {'c': 'João', 'm': 'PIX', 'f': '2026-12'},
    });
    expect(mbMesclarExtras(antigos, novos, completo: true).keys, ['c']);
  });

  test('rótulos: fatura do mês e quem recebeu/pagou', () {
    expect(mbRotuloFaturaMes('2026-12'), 'Dezembro de 2026');
    expect(mbRotuloFaturaMes('2026-13'), isNull);
    expect(mbRotuloFaturaMes(null), isNull);
    final e = mbExtraDe({'x': {'c': 'Maria Souza', 'm': 'PIX'}}, 'x');
    expect(mbRotuloContraparte(e, receita: false), 'Pix para Maria Souza');
    expect(mbRotuloContraparte(e, receita: true), 'Pix de Maria Souza');
    expect(mbRotuloContraparte(mbExtraDe({'x': {'c': 'Loja'}}, 'x'), receita: false), 'Enviado para Loja');
    expect(mbRotuloContraparte(mbExtraDe(const {}, 'x'), receita: false), isNull);
    expect(mbExtrasDeTexto('{"a":{"c":"M"}}'), {'a': {'c': 'M'}});
    expect(mbExtrasDeTexto('lixo'), isEmpty);
  });
}
