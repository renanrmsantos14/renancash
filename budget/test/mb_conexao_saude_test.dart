import 'package:budget/struct/mbSync/conexoes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final agora = DateTime(2026, 11, 18, 10);
  MbConexao c(Map<String, dynamic> extra) =>
      MbConexao.deJson({'id': 'i', 'banco': 'Inter', 'status': 'UPDATED', 'contas': const [], ...extra});

  test('rodapé: próxima atualização e consentimento perto de vencer', () {
    final r = c({
      'proximoSync': DateTime(2026, 11, 18, 22, 5).toUtc().toIso8601String(),
      'consentimentoExpira': DateTime(2026, 11, 21).toUtc().toIso8601String(),
    }).rodape(agora);
    expect(r.map((x) => x.texto), ['O banco atualiza de novo às 22:05', 'A autorização do Open Finance vence em 3 dias. Renove no Meu Pluggy.']);
    expect(r.map((x) => x.alerta), [false, true]);
  });

  test('rodapé: consentimento longe não aparece; vencido avisa; sem dados fica vazio', () {
    expect(c({'consentimentoExpira': '2027-05-01T00:00:00Z'}).rodape(agora), isEmpty);
    expect(c({'consentimentoExpira': DateTime(2026, 11, 10).toUtc().toIso8601String()}).rodape(agora).single.texto,
        startsWith('A autorização do Open Finance venceu em 10/11'));
    expect(c({}).rodape(agora), isEmpty);
    expect(c({'proximoSync': DateTime(2026, 11, 19, 8).toUtc().toIso8601String()}).rodape(agora).single.texto,
        'O banco atualiza de novo em 19/11 às 08:00');
  });
}
