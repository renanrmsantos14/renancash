// Detalhe da conta visto no celular (v5.4.32): saldo igual ao da Início, abas da pizza,
// ícone padrão de categoria e "R$ " com espaço no formato numérico personalizado.
import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart' show formatOutputWithNewDelimiterAndDecimal;
import 'package:budget/pages/investimentosEvolucaoPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/meuBancoMapping.dart' show mbPkConta;
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/categoryIcon.dart'
    show arquivoIconeCategoria, iconePadraoCategoria;
import 'package:budget/widgets/editorial/contas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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

  testWidgets(
      'InvestimentosConteudo usa meses em pt-BR no gráfico e inicial maiúscula em Mês a mês',
      (t) async {
    appStateSettings = {
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'forceFullDarkBackground': false,
      'appAnimations': 0,
      'removeZeroTransactionEntries': false,
      'showCumulativeSpending': false,
      'selectedWalletPk': '0',
      'customCurrencyAmounts': <String, dynamic>{},
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'numberFormatCurrencyFirst': true,
      'locale': 'pt',
    };
    const serie = [
      MbRetratoMes('2026-09', [MbAplicacaoMes('a', 'CDB Inter', 'Inter', 8000)]),
      MbRetratoMes('2026-10', [MbAplicacaoMes('a', 'CDB Inter', 'Inter', 8350)]),
      MbRetratoMes('2026-11', [MbAplicacaoMes('a', 'CDB Inter', 'Inter', 8512.4)]),
    ];
    await t.pumpWidget(Provider<AllWallets>.value(
      value: AllWallets(list: const [], indexedByPk: const {}),
      child: MaterialApp(
        theme: temaEditorial(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: InvestimentosConteudo(
              aplicacoes: const [
                MbAplicacao('a', 'CDB Inter', 'Inter', 8512.4, null),
              ],
              serie: serie,
              nomesDasMetas: const {},
              hoje: DateTime(2026, 11, 16),
            ),
          ),
        ),
      ),
    ));
    await t.pump(const Duration(seconds: 2));
    expect(find.text('Novembro de 2026'), findsOneWidget);
    expect(find.text('Outubro de 2026'), findsOneWidget);
    expect(find.text('Setembro de 2026'), findsOneWidget);
    expect(find.text(' sobre outubro de 2026'), findsOneWidget);
    expect(find.text('set/26'), findsOneWidget);
    expect(find.text('out/26'), findsOneWidget);
    expect(find.text('nov/26'), findsOneWidget);
  });

  testWidgets('InvestimentosConteudo vazio tem botão com alvo de toque >= 44 px',
      (t) async {
    appStateSettings = {
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'forceFullDarkBackground': false,
      'appAnimations': 0,
    };
    await t.pumpWidget(MaterialApp(
      theme: temaEditorial(Brightness.light),
      home: Scaffold(
        body: InvestimentosConteudo(
          aplicacoes: const [],
          serie: const [],
          nomesDasMetas: const {},
          hoje: DateTime(2026, 11, 16),
          onAbrirMeuBanco: () {},
        ),
      ),
    ));
    await t.pump();
    final btn = find.widgetWithText(TextButton, 'Abrir o Meu Banco');
    expect(t.getSize(btn).height, greaterThanOrEqualTo(44));
  });

  testWidgets('LinhaConta posiciona detalhe abaixo do nome e saldo para caber sem cortar',
      (t) async {
    await t.pumpWidget(MaterialApp(
      theme: temaEditorial(Brightness.light),
      home: const Scaffold(
        body: SizedBox(
          width: 260,
          child: LinhaConta(
            sigla: 'NU',
            nome: 'Nubank',
            detalhe: 'Principal · 128 transações',
            saldo: 'R\$ 3.102,90',
          ),
        ),
      ),
    ));
    await t.pump();
    final rectSaldo = t.getRect(find.text('R\$ 3.102,90'));
    final rectDetalhe = t.getRect(find.text('Principal · 128 transações'));
    expect(rectDetalhe.top, greaterThanOrEqualTo(rectSaldo.bottom));
  });
}
