// Quanto investi e quanto rendeu: detalhes do Pluggy (amountOriginal etc.) vindos do Worker em `investimentos`
// e o rendimento de cada mês separado dos aportes na série `investimentos_mensal`.
import 'package:budget/database/tables.dart';
import 'package:budget/pages/investimentosEvolucaoPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  test('detalhes do Worker: aplicado, rendimento, taxa e datas; campo ausente fica null', () {
    final d = mbDetalhesDeJson([
      {
        'id': 'c1',
        'saldo': 11234.56,
        'aplicado': 10000,
        'rendimento': 1234.56,
        'liquido': 11050.1,
        'impostos': 184.46,
        'taxa': {'valor': 110, 'indexador': 'CDI'},
        'vencimento': '2028-03-01',
        'aplicado_em': '2025-03-01',
        'subtipo': 'CDB',
      },
      {'id': 'p', 'saldo': 50}, // Worker antigo ou poupança: sem detalhes
      {'saldo': 1}, // sem id
      'lixo',
    ]);
    expect(d.keys, ['c1', 'p']);
    final c = d['c1']!;
    expect(c.aplicado, 10000);
    expect(c.rendimento, 1234.56);
    expect(c.percentual, closeTo(12.3456, 1e-9));
    expect(c.vencimento, DateTime(2028, 3, 1));
    expect(mbRotuloTaxa(c.taxa), '110% do CDI');
    expect(d['p']!.aplicado, isNull);
    expect(d['p']!.percentual, isNull);
    expect(mbDetalhesDeJson(null), isEmpty);
  });

  test('rótulo da taxa: pós-fixada, IPCA +, prefixada', () {
    expect(mbRotuloTaxa((valor: 102.5, indexador: 'CDI')), '102,50% do CDI');
    expect(mbRotuloTaxa((valor: 6.5, indexador: 'IPCA')), 'IPCA + 6,50%');
    expect(mbRotuloTaxa((valor: 12, indexador: 'PRE')), '12% a.a.');
    expect(mbRotuloTaxa(null), isNull);
  });

  test('rendimento do mês desconta aportes e resgates; sem aplicado é null', () {
    const serie = [
      MbRetratoMes('2026-09', [MbAplicacaoMes('a', 'CDB', null, 1000)]), // retrato antigo
      MbRetratoMes('2026-10', [MbAplicacaoMes('a', 'CDB', null, 1010, aplicado: 1000)]),
      // Novembro: "a" rendeu 12 e recebeu aporte de 500; "b" é nova (comprada por 300, já rendeu 2).
      MbRetratoMes('2026-11', [
        MbAplicacaoMes('a', 'CDB', null, 1522, aplicado: 1500),
        MbAplicacaoMes('b', 'LCI', null, 302, aplicado: 300),
      ]),
      // Dezembro: "b" foi resgatada inteira; "a" rendeu 15.
      MbRetratoMes('2026-12', [MbAplicacaoMes('a', 'CDB', null, 1537, aplicado: 1500)]),
    ];
    final v = mbSerieComVariacao(serie);
    expect(v[0].rendimento, isNull);
    expect(v[1].rendimento, isNull); // "a" existia em setembro sem `aplicado`
    expect(v[2].variacao, 814);
    expect(v[2].rendimento, closeTo(14, 1e-9));
    expect(v[3].variacao, -287);
    expect(v[3].rendimento, closeTo(15, 1e-9));
  });

  testWidgets('tela mostra quanto está investido, quanto rendeu e a taxa de cada aplicação', (t) async {
    appStateSettings = {
      'theme': 'light',
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
    await t.pumpWidget(Provider<AllWallets>.value(
      value: AllWallets(list: const [], indexedByPk: const {}),
      child: MaterialApp(
        theme: temaEditorial(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: InvestimentosConteudo(
              aplicacoes: const [
                MbAplicacao('a', 'CDB Inter', 'Inter', 11000, null),
                MbAplicacao('p', 'Poupança', 'Santander', 500, null),
              ],
              serie: const [
                MbRetratoMes('2026-10', [MbAplicacaoMes('a', 'CDB Inter', 'Inter', 10900, aplicado: 10000)]),
                MbRetratoMes('2026-11', [MbAplicacaoMes('a', 'CDB Inter', 'Inter', 11000, aplicado: 10000)]),
              ],
              detalhes: {
                'a': MbDetalheInvestimento(
                    aplicado: 10000,
                    rendimento: 1000,
                    taxa: (valor: 110, indexador: 'CDI'),
                    vencimento: DateTime(2028, 3, 1)),
              },
              nomesDasMetas: const {},
              hoje: DateTime(2026, 11, 16),
            ),
          ),
        ),
      ),
    ));
    await t.pump(const Duration(seconds: 2));
    expect(find.text('Total investido'), findsOneWidget);
    expect(find.text('Investido'), findsOneWidget);
    expect(find.text('Rendeu'), findsOneWidget);
    expect(find.text('+10,00%'), findsOneWidget);
    expect(find.text('110% CDI'), findsOneWidget);
    expect(find.text('vence 01/03/2028'), findsOneWidget);
    expect(find.textContaining('Uma aplicação fica de fora'), findsOneWidget);
    expect(find.textContaining('rendeu '), findsOneWidget); // novembro: rendeu +R$ 100
  });
}
