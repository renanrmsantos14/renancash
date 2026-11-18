import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final agora = DateTime(2026, 11, 18, 10);

  test('Início mostra o mínimo da fatura e o cheque especial em uso', () {
    final b = mbAgruparPorBanco(
      contas: [
        {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Inter', 'bank': 'Inter', 'balance': -80.0, 'overdraft_used': 80.0},
        {'id': 'g', 'type': 'CREDIT', 'name': 'Cartão Inter', 'bank': 'Inter', 'balance': 900.0},
      ],
      faturas: {
        'g': {
          'open_bill': {'due_date': '2026-12-10', 'total_amount': 900.0, 'minimum_payment': 135.0}
        }
      },
      investimentos: const [],
      sincronizadoEm: null,
      agora: agora,
    ).single;
    final conta = b.itens.firstWhere((i) => !i.fatura);
    expect(conta.rotulo, startsWith('Conta corrente · '));
    expect(conta.rotulo, endsWith(' do cheque especial'));
    expect(conta.destaque, isTrue);
    final auto = mbAgruparPorBanco(
      contas: [
        {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Inter', 'bank': 'Inter', 'balance': 500.0, 'auto_invested': 300.0},
      ],
      faturas: const {},
      investimentos: const [],
      sincronizadoEm: null,
      agora: agora,
    ).single;
    expect(auto.itens.single.rotulo, endsWith(' rendendo automático'));
    expect(auto.itens.single.destaque, isFalse);
    expect(auto.total, 500);
    final fatura = b.itens.firstWhere((i) => i.fatura);
    expect(fatura.rotulo, contains(' · mínimo '));
    expect(fatura.rotulo, contains('135,00'));
  });

  test('sem mínimo nem cheque especial, as linhas ficam como antes', () {
    final f = mbFaturasAbertas(
        contas: [
          {'id': 'g', 'type': 'CREDIT', 'name': 'Cartão', 'balance': 10.0, 'due_date': '2026-11-25'}
        ],
        faturas: const {},
        agora: agora).single;
    expect(f.minimo, isNull);
  });
}
