// Textos e layout vistos no celular: títulos do banco com espaços repetidos, categoria de
// ajuste gravada em inglês, chips de conta de mesmo nome e "faltam N dias" no cartão.
import 'package:budget/database/tables.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/conexoes.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/budgetContainer.dart';
import 'package:budget/widgets/transactionEntry/transactionLabel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

TransactionCategory _cat(String pk, String nome) => TransactionCategory(
    categoryPk: pk,
    name: nome,
    colour: '0xff607d8b',
    iconName: 'charts.png',
    dateCreated: DateTime(2026),
    order: 0,
    income: false,
    methodAdded: null);

void main() {
  test('títulos do banco perdem os espaços repetidos', () {
    expect(nomeSemEspacosRepetidos('Pix enviado  - Auto Prime Locacoes'),
        'Pix enviado - Auto Prime Locacoes');
    expect(
        nomeSemEspacosRepetidos(
            'Compra no débito - Republic Ca           Sao Jose Dos Bra '),
        'Compra no débito - Republic Ca Sao Jose Dos Bra');
    expect(nomeSemEspacosRepetidos('Mercado'), 'Mercado');
  });

  test('categoria de ajuste com nome padrão sai traduzida; nome próprio fica', () {
    // Sem EasyLocalization o .tr() devolve a chave: basta não ser o texto em inglês.
    expect(nomeDaCategoria(_cat('0', 'Balance Correction')),
        'default-category-account-amount-balancing');
    expect(nomeDaCategoria(_cat('0', 'Correção de saldo')),
        'default-category-account-amount-balancing');
    expect(nomeDaCategoria(_cat('0', 'Aplicações')), 'Aplicações');
    expect(nomeDaCategoria(_cat('c1', 'Balance Correction')),
        'Balance Correction');
  });

  test('chips de conta de mesmo nome ganham o tipo, por pk', () {
    expect(
        mbRotulosPorPk({
          'mb:1': 'BANCO INTER ·69-6',
          'mb:2': 'BANCO INTER ·69-6',
          '0': 'Carteira',
        }, {
          'mb:1': 'Conta corrente',
          'mb:2': 'Poupança',
        }),
        {
          'mb:1': 'BANCO INTER ·69-6 · Conta corrente',
          'mb:2': 'BANCO INTER ·69-6 · Poupança',
          '0': 'Carteira',
        });
    expect(mbRotulosPorPk({'a': 'Nubank'}, const {}), {'a': 'Nubank'});
  });

  testWidgets('cartão de orçamento mostra "faltam N dias" inteiro no celular',
      (t) async {
    appStateSettings = {
      ...await getDefaultPreferences(),
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'forceFullDarkBackground': false,
      'selectedWalletPk': '0',
      'showTotalSpentForBudget': false,
      'customCurrencyAmounts': <String, dynamic>{},
      'customNumberFormat': true,
      'numberFormatDelimiter': '.',
      'numberFormatDecimal': ',',
      'temaPronto': 'padrao-claro',
    };
    // 1080 × 2400 a 2,625: 411 px lógicos de largura.
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.625;
    addTearDown(t.view.reset);
    await t.pumpWidget(Provider<AllWallets>.value(
      value: AllWallets(list: const [], indexedByPk: const {}),
      child: MaterialApp(
        theme: temaFlutter(temaAtivo(Brightness.light)),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            children: const [
              CartaoOrcamento(
                nome: 'Geral',
                cor: Color(0xFF4CAF50),
                periodo: '17 de nov. – 5 de dez.',
                gasto: 12345.67,
                limite: 30000,
                diasRestantes: 19,
              ),
            ],
          ),
        ),
      ),
    ));
    await t.pump(const Duration(seconds: 2));
    final dias = find.text('faltam 19 dias');
    expect(dias, findsOneWidget);
    expect(t.getRect(dias).right,
        lessThanOrEqualTo(t.getRect(find.byType(CartaoOrcamento)).right));
    expect(t.takeException(), isNull);
  });
}
