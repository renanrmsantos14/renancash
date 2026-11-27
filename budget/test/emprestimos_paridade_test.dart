import 'dart:convert';
import 'dart:io';

import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:flutter_test/flutter_test.dart';

// Mesma fixture do Worker (apps/worker/test/emprestimos-calculo.test.mjs): o cálculo do app e o da migração têm de dar o mesmo.
void main() {
  final arquivo = File('../apps/worker/test/fixtures/emprestimos-paridade.json');
  final casos = (jsonDecode(arquivo.readAsStringSync())['casos'] as List).cast<Map<String, dynamic>>();

  Map<String, dynamic> resumo(MbEmprestimo e) => {
        'id': e.txId,
        'original': e.originalCentavos,
        'restante': e.restanteCentavos,
        'pessoa': e.pessoa,
        'pagamentos': e.pagamentos.length,
        if (e.perdoadoCentavos != 0) 'perdoado': e.perdoadoCentavos,
      };

  for (final c in casos) {
    test('cálculo igual ao Worker: ${c['nome']}', () {
      final r = mbCalcularEmprestimos([for (final d in c['decisoes'] as List) Map<String, dynamic>.from(d)],
          perdoes: [for (final p in c['perdoes'] as List) Map<String, dynamic>.from(p)]);
      final esperado = c['esperado'] as Map<String, dynamic>;
      expect(r.abertos.fold<int>(0, (s, e) => s + e.restanteCentavos), esperado['devido']);
      expect([for (final e in r.abertos) resumo(e)], esperado['abertos']);
      expect([for (final e in r.quitados) resumo(e)], esperado['quitados']);
    });
  }
}
