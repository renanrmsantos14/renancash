// Orçamentos e metas com os dados do celular (backup de 17/11/2026): carteiras do Geral, sugestão de limites por
// categoria (média dos 3 ciclos 6→5, com reembolso de conta rachada), meta Reserva com as aplicações do Meu Banco e
// o painel da meta de poupança. Funções puras e widgets sem banco.
import 'package:budget/database/tables.dart';
import 'package:budget/pages/budgetsListPage.dart' show orcamentoParaSugerirLimites;
import 'package:budget/pages/objectivesListPage.dart' show iconeMetaPadrao;
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/mbSync/sugestaoLimites.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:budget/widgets/mbAplicacoesDaMeta.dart';
import 'package:budget/widgets/sugestaoLimites.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

TransactionCategory _cat(String pk, String nome, {String? pai}) => TransactionCategory(
    categoryPk: pk,
    name: nome,
    dateCreated: DateTime(2026),
    order: 0,
    income: false,
    mainCategoryPk: pai);

final _alimentacao = _cat('ali', 'Alimentação');
final _almoco = _cat('alm', 'Almoço Betinhos', pai: 'ali');
final _restaurante = _cat('res', 'Restaurante', pai: 'ali');
final _transporte = _cat('tra', 'Transporte');
final _uber = _cat('ube', 'Uber', pai: 'tra');
final _pedagio = _cat('ped', 'Pedágio', pai: 'tra');

CategoryWithTotal _g(TransactionCategory c, double total, int n) =>
    CategoryWithTotal(category: c, total: total, transactionCount: n);

Budget _orc(String pk, {bool renda = false, bool soAdicionadas = false}) => Budget(
      budgetPk: pk,
      name: pk,
      amount: 1300,
      startDate: DateTime(2026, 11, 6),
      endDate: DateTime(2026, 12, 5),
      addedTransactionsOnly: soAdicionadas,
      periodLength: 1,
      dateCreated: DateTime(2026, 11, 6),
      pinned: true,
      order: 0,
      walletFk: '0',
      income: renda,
      archived: false,
      isAbsoluteSpendingLimit: false,
    );

// Aplicações reais da carteira Investimentos (nomes repetidos: maior saldo primeiro).
const _cdbs = [
  ('3c929991', 'CDB - BANCO INTER S.A', 550.03),
  ('d9add3aa', 'CDB - BANCO INTER S.A', 430.21),
  ('232a689a', 'CDB - BANCO INTER S.A', 107.87),
  ('9caa2533', 'CDB - BANCO INTER S.A', 107.11),
  ('5873d1c5', 'CDB - BANCO INTER S.A', 106.37),
  ('bcfc819f', 'CDB - BANCO INTER S.A', 60.38),
  ('be9cb440', 'CDB - BANCO INTER S.A', 28.01),
  ('8db42302', 'CDB - BANCO INTER S.A', 1.19),
  ('c16bdf75', 'CDB - BANCO SANTANDER (BRASIL) S.A.', 133.69),
  ('6114919c', 'Tesouro Prefixado 2029', 7.37),
];
List<MbAplicacao> _aplicacoes({String? meta}) => [
      for (final (id, nome, saldo) in _cdbs)
        MbAplicacao(mbPkAplicacao(id), nome, 'BANCO INTER', saldo, meta)
    ];

void main() {
  group('carteiras do Geral', () {
    const geral = ['0', 'mb:29dc', 'mb:618b']; // Inter manual (principal) + Inter corrente + poupança
    const arquivadasReais = {'c6c27733', '40e28854'}; // Santander e Investimentos manuais (Arrumar dados)

    test('a carteira principal "0" continua: nunca é arquivada e guarda assinaturas e empréstimos', () {
      expect(mbCarteirasDoOrcamento(geral, arquivadasReais), geral);
    });

    test('carteira arquivada escolhida no orçamento deixa de contar', () {
      expect(mbCarteirasDoOrcamento([...geral, 'c6c27733'], arquivadasReais), geral);
    });

    test('só arquivadas: mantém a escolha (lista vazia viraria "todas")', () {
      expect(mbCarteirasDoOrcamento(['c6c27733'], arquivadasReais), ['c6c27733']);
    });

    test('sem escolha continua sem escolha (todas as não arquivadas)', () {
      expect(mbCarteirasDoOrcamento(null, arquivadasReais), isNull);
      expect(mbCarteirasDoOrcamento(const [], arquivadasReais), isEmpty);
    });

    test('filtro [5] do Geral = padrão: sem renda, sem empréstimo/dívida, sem ajuste de saldo', () {
      const padrao = [BudgetTransactionFilters.defaultBudgetTransactionFilters];
      expect(isFilterSelectedWithDefaults(padrao, BudgetTransactionFilters.includeIncome), isFalse);
      expect(isFilterSelectedWithDefaults(padrao, BudgetTransactionFilters.includeDebtAndCredit), isFalse);
      expect(isFilterSelectedWithDefaults(padrao, BudgetTransactionFilters.includeBalanceCorrection), isFalse);
      // Gasto ligado a meta continua contando no ciclo (como no Cashew).
      expect(isFilterSelectedWithDefaults(padrao, BudgetTransactionFilters.addedToObjective), isTrue);
    });
  });

  group('sugestão de limites por categoria', () {
    // Três ciclos (6/ago–5/set, 6/set–5/out, 6/out–5/nov). Linhas como a consulta do orçamento devolve com
    // subcategorias: a principal soma tudo; a subcategoria tem linha própria. Total negativo = gasto.
    final porCiclo = [
      [_g(_alimentacao, -1020.83, 40), _g(_almoco, -529.02, 25), _g(_restaurante, -69, 2)],
      // Ciclo sem Almoço Betinhos: conta 0 na média. Restaurante com reembolso de conta rachada (+80 já abatido).
      [_g(_alimentacao, -651.13, 30), _g(_restaurante, -88.9, 3), _g(_transporte, -713.09, 25), _g(_uber, -160.65, 12)],
      [
        _g(_alimentacao, -629.84, 30),
        _g(_almoco, -49.64, 3),
        _g(_restaurante, -151.48, 4),
        _g(_transporte, -658.73, 20),
        _g(_uber, -80.56, 6),
        _g(_pedagio, -16.4, 1),
      ],
    ];

    test('média dos 3 ciclos (ciclo sem gasto conta 0), maior primeiro, nome com a principal', () {
      final s = mbSugerirLimites(porCiclo);
      expect([for (final x in s) x.nome], [
        'Alimentação',
        'Transporte',
        'Alimentação › Almoço Betinhos', // 192,89
        'Alimentação › Restaurante', // 103,13
        'Transporte › Uber', // 80,40
      ]);
      final almoco = s.firstWhere((x) => x.categoria.categoryPk == 'alm');
      expect(almoco.media, closeTo((529.02 + 49.64) / 3, 0.001));
      expect(almoco.vezes, closeTo(28 / 3, 0.001));
      expect(almoco.sugerido, 200); // 192,89 arredonda para cima em R$ 10
      expect(almoco.atual, isNull);
    });

    test('pedágio (5,47/ciclo) fica de fora: abaixo de R\$ 20 por ciclo', () {
      expect(mbSugerirLimites(porCiclo).any((x) => x.categoria.categoryPk == 'ped'), isFalse);
    });

    test('reembolso de conta rachada (valor positivo na categoria) baixa a média', () {
      final comReembolso = mbSugerirLimites([
        [_g(_restaurante, -120, 2)],
        [_g(_restaurante, -120 + 60, 3)], // paguei 120, recebi 60 de volta
        [_g(_restaurante, -30, 1)],
      ]);
      expect(comReembolso.single.media, closeTo(70, 0.001));
      expect(comReembolso.single.sugerido, 70);
    });

    test('limite que já existe aparece junto', () {
      final s = mbSugerirLimites(porCiclo, atuais: {'tra': 600});
      expect(s.firstWhere((x) => x.categoria.categoryPk == 'tra').atual, 600);
    });

    test('sem ciclos não sugere nada', () {
      expect(mbSugerirLimites(const []), isEmpty);
    });

    test('arredondamento em R\$ 10 para cima', () {
      expect(mbArredondarLimite(0), 0);
      expect(mbArredondarLimite(20.9), 30);
      expect(mbArredondarLimite(767.27), 770);
      expect(mbArredondarLimite(770), 770);
    });

    test('ciclos anteriores seguem o ciclo do salário 6→5', () {
      final ciclo = DateTimeRange(start: DateTime(2026, 11, 6), end: DateTime(2026, 12, 5));
      final c = mbCiclosAnteriores((d) => mbPeriodoDoCiclo(ciclo, d), DateTime(2026, 11, 17));
      expect([for (final p in c) [p.start, p.end]], [
        [DateTime(2026, 10, 6), DateTime(2026, 11, 5)],
        [DateTime(2026, 9, 6), DateTime(2026, 10, 5)],
        [DateTime(2026, 8, 6), DateTime(2026, 9, 5)],
      ]);
    });

    test('valor digitado em pt-BR', () {
      expect(lerValorLimite('1.234,56'), 1234.56);
      expect(lerValorLimite('200'), 200);
      expect(lerValorLimite('R\$ 210,5'), 210.5);
      expect(lerValorLimite('12.5'), 12.5);
      expect(lerValorLimite(''), isNull);
    });

    test('vai para o Geral; sem ele, o primeiro orçamento de gasto com todas as transações', () {
      expect(orcamentoParaSugerirLimites([_orc('outro'), _orc(mbOrcamentoGeralPk)])?.budgetPk,
          mbOrcamentoGeralPk);
      expect(orcamentoParaSugerirLimites([_orc('poupanca', renda: true), _orc('mercado')])?.budgetPk,
          'mercado');
      expect(orcamentoParaSugerirLimites([_orc('so', soAdicionadas: true)]), isNull);
    });
  });

  group('meta Reserva de emergência com as aplicações do Meu Banco', () {
    test('sem aplicação ligada: guardado 0 e as 10 aplicações livres somam R\$ 1.532,23', () {
      final s = mbSepararAplicacoes(_aplicacoes(), mbMetaReservaPk);
      expect(s.ligadas, isEmpty);
      expect(s.livres, hasLength(10));
      expect(mbSaldoAplicacoes(s.livres), closeTo(1532.23, 0.001));
    });

    test('com todas ligadas: progresso 30% de R\$ 5.000 (meta com data de fim)', () {
      final aplicacoes = _aplicacoes(meta: mbMetaReservaPk);
      final s = mbSepararAplicacoes(aplicacoes, mbMetaReservaPk);
      expect(s.ligadas, hasLength(10));
      expect(s.livres, isEmpty);
      final r = mbResumoMetas(
        metas: [
          MbMetaDados(
              pk: mbMetaReservaPk,
              nome: mbMetaReservaNome,
              alvo: 5000,
              prazo: DateTime(2027, 4, 14),
              aplicacaoPks: [for (final a in s.ligadas) a.pk])
        ],
        saldoPorAplicacao: {for (final a in aplicacoes) a.pk: a.saldo},
        hoje: DateTime(2026, 11, 17),
      ).single;
      expect(r.saldo, closeTo(1532.23, 0.001));
      expect(r.progresso, closeTo(1532.23 / 5000, 0.0001));
      expect(r.diasRestantes, 148);
      expect(r.texto, contains('(30%)'));
    });

    test('aplicação de outra meta não é livre nem desta meta', () {
      final l = [..._aplicacoes().take(2), MbAplicacao(mbPkAplicacao('x'), 'CDB', null, 10, 'outra')];
      final s = mbSepararAplicacoes(l, mbMetaReservaPk);
      expect(s.ligadas, isEmpty);
      expect(s.livres, hasLength(2));
    });

    test('meta sem ícone ganha um padrão (o quadrado não fica vazio)', () {
      expect(iconeMetaPadrao(ObjectiveType.goal), 'piggy-bank.png');
      expect(iconeMetaPadrao(ObjectiveType.loan), 'image.png');
    });
  });

  group('telas', () {
    Future<void> montar(WidgetTester t, Widget corpo) async {
      appStateSettings = {
        ...await getDefaultPreferences(),
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'selectedWalletPk': '0',
        'customCurrencyAmounts': <String, dynamic>{},
        'temaPronto': 'padrao-claro',
      };
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      await t.pumpWidget(Provider<AllWallets>.value(
        value: AllWallets(list: const [], indexedByPk: const {}),
        child: MaterialApp(
          theme: temaFlutter(temaAtivo(Brightness.light)),
          home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: corpo)),
        ),
      ));
      await t.pump(const Duration(milliseconds: 500));
    }

    testWidgets('meta sem aplicação: vazio explica e leva a escolher ou depositar', (t) async {
      var escolheu = 0, depositou = 0;
      final livres = _aplicacoes();
      await montar(
          t,
          PainelAplicacoesMeta(
              ligadas: const [],
              livres: livres,
              onEscolher: () => escolheu++,
              onDepositar: () => depositou++));
      expect(find.text('Nenhuma aplicação ligada a esta meta'), findsOneWidget);
      expect(find.textContaining('Há 10 aplicações sem meta'), findsOneWidget);
      await t.tap(find.text('Escolher aplicações'));
      await t.tap(find.text('Registrar depósito'));
      await t.pump(const Duration(seconds: 1));
      expect((escolheu, depositou), (1, 1));
      expect(t.takeException(), isNull);
    });

    testWidgets('sem Meu Banco (nenhuma aplicação): só depósito', (t) async {
      await montar(
          t,
          PainelAplicacoesMeta(
              ligadas: const [], livres: const [], onEscolher: null, onDepositar: () {}));
      expect(find.text('Nenhum depósito ainda'), findsOneWidget);
      expect(find.text('Escolher aplicações'), findsNothing);
      expect(find.text('Registrar depósito'), findsOneWidget);
    });

    testWidgets('com aplicações: lista com "1 de 8" nos nomes repetidos', (t) async {
      await montar(
          t,
          PainelAplicacoesMeta(
              ligadas: _aplicacoes(meta: mbMetaReservaPk),
              livres: const [],
              onEscolher: () {},
              onDepositar: () {}));
      expect(find.text('10 aplicações nesta meta'), findsOneWidget);
      expect(find.textContaining('1 de 8'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('sugestão: marca as 5 primeiras, salva só as marcadas com o valor ajustado', (t) async {
      Map<String, double>? salvo;
      final sugestoes = mbSugerirLimites([
        [_g(_alimentacao, -900, 30), _g(_almoco, -546, 26), _g(_transporte, -600, 20), _g(_uber, -320, 16)],
      ]);
      await montar(
          t,
          SugestaoLimites(
            sugestoes: sugestoes,
            preMarcadas: 2,
            onSalvar: (v) async => salvo = v,
          ));
      expect(find.text('Salvar 2 limites'), findsOneWidget);
      await t.enterText(find.byType(TextField).at(2), '500'); // Almoço Betinhos: ajusta e marca
      await t.pump();
      await t.tap(find.text('Salvar 3 limites'));
      await t.pump(const Duration(seconds: 1));
      expect(salvo, {'ali': 900.0, 'tra': 600.0, 'alm': 500.0});
      expect(t.takeException(), isNull);
    });
  });
}
