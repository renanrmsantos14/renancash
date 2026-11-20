// Tela de Investimentos: aplicações por banco (ordem, recolher), folha de detalhe, vazio e rendimento negativo.
import 'package:budget/database/tables.dart';
import 'package:budget/pages/investimentosEvolucaoPage.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _apps = [
  MbAplicacao('a', 'CDB Inter 110%', 'BANCO INTER', 5000, null),
  MbAplicacao('b', 'LCI Inter', 'Banco Inter ·69-6', 4000, 'm1'),
  MbAplicacao('c', 'Tesouro Selic', 'Banco Santander Pessoa Física ·24-1', 500, null),
  MbAplicacao('d', 'Fundo DI', 'XP Investimentos', 12000, null),
  MbAplicacao('e', 'Cofrinho sem banco', null, 300, null),
];

final _detalhes = {
  'a': MbDetalheInvestimento(
      aplicado: 4500,
      rendimento: 500,
      impostos: 60,
      liquido: 5440,
      taxa: (valor: 110, indexador: 'CDI'),
      rentabilidadeMes: 0.9,
      rentabilidade12m: 11.2,
      subtipo: 'CDB',
      emissor: 'Banco Inter',
      aplicadoEm: DateTime(2025, 3, 1),
      vencimento: DateTime(2028, 3, 1)),
  'd': const MbDetalheInvestimento(aplicado: 12500), // rendimento negativo (−500)
};

const _serie = [
  MbRetratoMes('2026-10', [MbAplicacaoMes('a', 'CDB Inter 110%', 'BANCO INTER', 4900, aplicado: 4500)]),
  MbRetratoMes('2026-11', [MbAplicacaoMes('a', 'CDB Inter 110%', 'BANCO INTER', 5000, aplicado: 4500)]),
];

Future<void> _abrir(WidgetTester t,
    {List<MbAplicacao> apps = _apps,
    Map<String, MbDetalheInvestimento>? detalhes,
    List<MbRetratoMes> serie = _serie,
    double largura = 390}) async {
  appStateSettings = {
    ...await getDefaultPreferences(),
    'materialYou': false,
    'accentSystemColor': false,
    'batterySaver': false,
    'increaseTextContrast': false,
    'forceFullDarkBackground': false,
    'appAnimations': 0,
    'selectedWalletPk': '0',
    'customCurrencyAmounts': <String, dynamic>{},
    'customNumberFormat': true,
    'numberFormatDelimiter': '.',
    'numberFormatDecimal': ',',
    'numberFormatCurrencyFirst': true,
    'locale': 'pt',
  };
  t.view.physicalSize = Size(largura, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(Provider<AllWallets>.value(
    value: AllWallets(list: const [], indexedByPk: const {}),
    child: MaterialApp(
      theme: temaEditorial(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: InvestimentosConteudo(
            aplicacoes: apps,
            serie: serie,
            detalhes: detalhes ?? _detalhes,
            nomesDasMetas: const {'m1': 'Viagem 2027'},
            hoje: DateTime(2026, 11, 16),
            onAbrirMeuBanco: () {},
          ),
        ),
      ),
    ),
  ));
  await t.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('agrupa por banco: maior total primeiro, Outros por último, quantidade no cabeçalho',
      (t) async {
    await _abrir(t);
    final y = [
      for (final n in ['XP', 'Banco Inter', 'Santander', 'Outros'])
        t.getTopLeft(find.text(n)).dy
    ];
    expect(y, orderedEquals([...y]..sort()));
    expect(find.text('2 aplicações'), findsOneWidget); // Inter: 'BANCO INTER' e 'Banco Inter ·69-6' juntos
    expect(find.text('1 aplicação'), findsNWidgets(3));
  });

  testWidgets('no celular só o maior banco começa aberto e o toque no cabeçalho abre outro', (t) async {
    await _abrir(t);
    expect(find.text('Fundo DI'), findsOneWidget);
    expect(find.text('CDB Inter 110%'), findsNothing);
    await t.tap(find.text('Banco Inter'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('CDB Inter 110%'), findsOneWidget);
    expect(find.text('LCI Inter'), findsOneWidget);
    // Linha com subtítulo compacto, vencimento e rendimento com sinal.
    expect(find.text('CDB · 110% CDI'), findsOneWidget);
    expect(find.text('vence 01/03/2028'), findsOneWidget);
    expect(find.text('+R\$ 500,00'), findsWidgets);
  });

  testWidgets('desktop: duas colunas, todos os bancos abertos', (t) async {
    await _abrir(t, largura: 1440);
    expect(find.text('Fundo DI'), findsOneWidget);
    expect(find.text('CDB Inter 110%'), findsOneWidget);
    expect(find.text('Cofrinho sem banco'), findsOneWidget);
    final topo = t.getTopLeft(find.text('Total investido'));
    final banco = t.getTopLeft(find.text('Por banco'));
    expect(banco.dx, greaterThan(topo.dx + 300));
  });

  testWidgets('toque numa aplicação abre a folha com aplicado, rendeu e o que o banco informa', (t) async {
    await _abrir(t, apps: [_apps[0]]);
    await t.tap(find.text('CDB Inter 110%'));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Aplicado'), findsOneWidget);
    expect(find.text('Rendeu'), findsWidgets);
    expect(find.text('+R\$ 500,00 (+11,11%)'), findsOneWidget);
    expect(find.text('Impostos'), findsOneWidget);
    expect(find.text('Líquido'), findsOneWidget);
    expect(find.text('110% do CDI'), findsOneWidget);
    expect(find.text('Rentabilidade em 12 meses'), findsOneWidget);
    expect(find.text('Emissor'), findsOneWidget);
    expect(find.text('Vencimento'), findsOneWidget);
    expect(find.text('out/26'), findsWidgets); // mini evolução mensal
    // Esc fecha.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Impostos'), findsNothing);
  });

  testWidgets('aplicação sem detalhe mostra só o saldo e a meta ligada', (t) async {
    await _abrir(t, apps: [_apps[1]]);
    await t.tap(find.text('LCI Inter'));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Saldo'), findsOneWidget);
    expect(find.text('Aplicado'), findsNothing);
    expect(find.text('Impostos'), findsNothing);
    expect(find.text('Vencimento'), findsNothing);
    expect(find.text('—'), findsNothing);
    expect(find.text('Meta'), findsOneWidget);
    expect(find.text('Viagem 2027'), findsOneWidget);
  });

  testWidgets('vazio mostra o aviso e "Abrir o Meu Banco"', (t) async {
    await _abrir(t, apps: const [], serie: const []);
    expect(find.text('Nenhum investimento sincronizado ainda.'), findsOneWidget);
    expect(find.text('Abrir o Meu Banco'), findsOneWidget);
  });

  testWidgets('rendimento negativo aparece com − e na cor de alerta', (t) async {
    await _abrir(t, apps: [_apps[3]]);
    final e = temaEditorial(Brightness.light).extension<EditorialCores>()!;
    final txt = find.text('−R\$ 500,00');
    expect(txt, findsWidgets);
    for (final w in t.widgetList<Text>(txt)) {
      expect(w.style?.color, e.warn);
    }
    expect(find.text('−4,00%'), findsOneWidget);
  });

  testWidgets('Mês a mês mostra 6 meses e "Ver todos" expande', (t) async {
    final serie = [
      for (var m = 1; m <= 8; m++)
        MbRetratoMes('2026-${m.toString().padLeft(2, '0')}',
            [MbAplicacaoMes('a', 'CDB', 'Inter', 1000.0 + m * 10)]),
    ];
    await _abrir(t, serie: serie, apps: [_apps[0]], detalhes: const {});
    expect(find.text('Janeiro de 2026'), findsNothing);
    expect(find.text('Ver todos (8)'), findsOneWidget);
    await t.ensureVisible(find.text('Ver todos (8)'));
    await t.tap(find.text('Ver todos (8)'));
    await t.pump();
    expect(find.text('Janeiro de 2026'), findsOneWidget);
  });
}
