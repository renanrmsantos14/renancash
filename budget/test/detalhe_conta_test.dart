// Detalhe da conta visto no celular (v5.4.32): saldo igual ao da Início, abas da pizza,
// ícone padrão de categoria e "R$ " com espaço no formato numérico personalizado.
import 'dart:convert';
import 'dart:io';

import 'package:budget/functions.dart' show formatOutputWithNewDelimiterAndDecimal;
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/meuBancoMapping.dart' show mbPkConta;
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/categoryIcon.dart'
    show arquivoIconeCategoria, iconePadraoCategoria;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saldo real por carteira: só contas BANK, pelo id da conta', () {
    final saldos = mbSaldosReais([
      {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'balance': 927.28},
      {'id': 'b', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'balance': 50},
      {'id': 'c', 'type': 'CREDIT', 'balance': 607.65},
      {'id': 'd', 'type': 'BANK'},
    ]);
    expect(saldos, {
      mbPkConta('a'): 927.28,
      mbPkConta('b'): 50.0,
      mbPkConta('d'): 0.0,
    });
  });

  test('o saldo do detalhe é o mesmo da linha da Início', () {
    final contas = [
      {'id': 'x', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'BANCO INTER ·69-6', 'balance': 927.28},
    ];
    final m = montarModeloInicio(
      ciclo: const {},
      contas: contas,
      faturas: const {},
      sincronizadoEm: null,
      ultimas: const [],
      nome: '',
      agora: DateTime(2026, 11, 17),
    );
    final linha = m.contas.single;
    expect(mbSaldosReais(contas)[linha.carteiras], linha.saldo);
    // Subtítulo do ciclo sem o final do número da conta, para caber no celular.
    expect(m.origemDisponivel, 'BANCO INTER');
  });

  test('abas da pizza do detalhe: Saídas / Entradas', () {
    final pt = jsonDecode(
            File('assets/translations/generated/pt.json').readAsStringSync())
        as Map<String, dynamic>;
    expect(pt['outgoing'], 'Saídas');
    expect(pt['incoming'], 'Entradas');
  });

  test('categoria sem ícone (image.png ou vazio) mostra a etiqueta', () {
    expect(arquivoIconeCategoria('image.png'), iconePadraoCategoria);
    expect(arquivoIconeCategoria(''), iconePadraoCategoria);
    expect(arquivoIconeCategoria('cutlery.png'), 'cutlery.png');
    expect(File('assets/categories/$iconePadraoCategoria').existsSync(), isTrue);
  });

  test('formato personalizado: R\$ com espaço, outras moedas coladas', () {
    appStateSettings['numberFormatCurrencyFirst'] = true;
    String fmt(double v, String simbolo, String entrada) =>
        formatOutputWithNewDelimiterAndDecimal(
            amount: v,
            input: entrada,
            delimiter: '.',
            decimal: ',',
            symbol: simbolo,
            currencyName: null);
    expect(fmt(4253.79, 'R\$', '4,253.79'), 'R\$ 4.253,79');
    // Menos tipográfico (−) colado ao símbolo, como nas linhas de transação.
    expect(fmt(-4253.79, 'R\$', '-4,253.79'), '−R\$ 4.253,79');
    expect(fmt(4253.79, '\$', '4,253.79'), '\$4.253,79');
    expect(brl(927.28), 'R\$ 927,28');
  });
}
