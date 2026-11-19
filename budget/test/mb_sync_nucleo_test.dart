import 'package:budget/struct/mbSync/registro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isoMs trunca microssegundos para milissegundos', () {
    expect(isoMs(DateTime.utc(2026, 1, 2, 3, 4, 5, 123, 456)),
        '2026-01-02T03:04:05.123Z');
  });

  test('jsonCanonico independe da ordem das chaves', () {
    expect(jsonCanonico({'b': 1, 'a': {'d': 1, 'c': 2}}),
        jsonCanonico({'a': {'c': 2, 'd': 1}, 'b': 1}));
  });

  test('vence: maior vence, igual não, null vence', () {
    final r = Registro('metas', '1', {}, '2026-01-02T00:00:00.000Z', null);
    expect(vence(r, '2026-01-01T00:00:00.000Z'), isTrue);
    expect(vence(r, '2026-01-02T00:00:00.000Z'), isFalse);
    expect(vence(r, null), isTrue);
  });

}
