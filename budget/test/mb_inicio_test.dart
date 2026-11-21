import 'package:budget/pages/homePage/inicioEditorial.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/bancos.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/ajustesInicio.dart' show mbAjustesMudaram;
import 'package:budget/struct/meuBancoSync.dart'
    show meuBancoPareado, meuBancoPareadoConferido;
import 'package:budget/struct/meuBancoMapping.dart' show mbPkConta;
import 'package:budget/struct/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _agora = DateTime(2026, 11, 9, 15, 0);

ModeloInicio _montar({List<Map<String, dynamic>>? contas, Map<String, dynamic>? faturas, String nome = 'Renan'}) =>
    montarModeloInicio(
      ciclo: {
        'inicio': '2026-10-26',
        'fim': '2026-11-25',
        'consumido': 1300.0,
        'limite': 5000.0,
        'percentual': 26.0,
        'diasRestantes': 16,
        'por_dia': [
          for (var i = 0; i < 31; i++)
            {'data': DateTime(2026, 10, 26 + i).toIso8601String().substring(0, 10), 'valor': i.toDouble()}
        ],
      },
      contas: contas ??
          [
            {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Inter', 'bank': 'Inter', 'balance': 1000.5},
            {'id': 'b', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Poup 1', 'bank': 'Inter', 'balance': 500.0},
            {'id': 'c', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Poup 2', 'bank': 'Santander', 'balance': 100.0},
            {
              'id': 'd', 'type': 'CREDIT', 'name': 'Cartão Gold ·1950', 'bank': 'Santander', 'balance': 607.65,
              'credit_limit': 600.0, 'closing_date': '2026-10-12', 'due_date': '2026-11-05',
            },
          ],
      faturas: faturas ?? {},
      sincronizadoEm: _agora.subtract(const Duration(minutes: 12)).toUtc().toIso8601String(),
      nome: nome,
      agora: _agora,
    );

void main() {
  salarioPendenteTests();
  test('disponível soma só as contas BANK e agrupa poupanças', () {
    final m = _montar();
    expect(m.disponivel, 1600.5);
    expect(m.contas.map((c) => c.nome), ['Inter', 'Poupanças']);
    expect(m.contas.last.tipo, '2 contas');
    expect(m.contas.last.saldo, 600.0);
    expect(m.origemDisponivel, 'Inter e poupanças · há 12 min');
    // Pelo id da conta, não pelo nome: corrente e poupança do mesmo banco podem ter o mesmo nome.
    expect(m.contas.map((c) => c.carteiras), [mbPkConta('a'), '${mbPkConta('b')}|${mbPkConta('c')}']);
  });

  test('correntes de bancos diferentes: uma linha cada; poupança com o saldo do Meu Banco', () {
    // No aparelho, a carteira da poupança soma só os juros (R$ 0,06); o saldo real é R$ 1,06.
    final contas = [
      {'id': 'i', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'BANCO INTER ·69-6', 'balance': 927.28},
      {'id': 'n', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Nubank ·12-3', 'balance': 50.0},
      {'id': 'p', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Santander ·24-1', 'balance': 1.06},
    ];
    final m = montarModeloInicio(
        ciclo: {},
        contas: contas,
        faturas: {},
        sincronizadoEm: null,
        nome: '',
        agora: _agora);
    expect(m.contas.map((c) => c.nome), ['BANCO INTER ·69-6', 'Nubank ·12-3', 'Santander ·24-1']);
    expect(m.contas.map((c) => c.saldo), [927.28, 50.0, 1.06]);
    expect(m.origemDisponivel, 'BANCO INTER, Nubank e poupanças');
    expect(mbSaldosReais(contas)[mbPkConta('p')], 1.06);
  });

  test('poupanças separadas: uma linha por conta, com o banco no tipo', () {
    final m = montarModeloInicio(
        ciclo: {},
        contas: [
          {'id': 'b', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Poup 1', 'bank': 'Inter', 'balance': 500.0},
          {'id': 'c', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Poup 2', 'bank': 'Santander', 'balance': 100.0},
        ],
        faturas: {},
        sincronizadoEm: null,
        nome: '',
        agora: _agora,
        agruparPoupancas: false);
    expect(m.contas.map((c) => c.nome), ['Poup 1', 'Poup 2']);
    expect(m.contas.map((c) => c.tipo), ['Poupança · Inter', 'Poupança · Santander']);
    expect(m.contas.map((c) => c.carteiras), [mbPkConta('b'), mbPkConta('c')]);
  });

  test('cartão: dias para fechar, vencimento, final e percentual', () {
    final c = _montar().cartoes.single;
    expect(c.nome, 'Cartão Gold');
    expect(c.final4, '1950');
    expect(c.diasFecha, 3);
    expect(c.vence, '05 dez');
    expect(c.pct, closeTo(101.275, .001));
  });

  test('fatura aberta substitui o saldo', () {
    final c = _montar(faturas: {
      'd': {'open_bill': {'total_amount': 300.0, 'due_date': '2026-12-05'}}
    }).cartoes.single;
    expect(c.fatura, 300.0);
    expect(c.pct, 50.0);
  });

  test('ciclo, saudação e índice de hoje', () {
    final m = _montar();
    expect(m.ciclo, 'Ciclo 26 out – 25 nov');
    expect(m.saudacao, 'Olá, Renan');
    expect(m.indiceHoje, 14);
    expect(_montar(nome: '  ').saudacao, 'Olá');
    expect(_montar().periodo, '26 out – 25 nov');
  });

  test('formatadores', () {
    expect(brl(2417.16), 'R\$ 2.417,16');
    // Menos tipográfico colado ao símbolo, como nas linhas de transação.
    expect(brl(-550), '−R\$ 550,00');
    expect(quandoRelativo(DateTime(2026, 11, 9, 1), _agora), 'hoje');
    expect(quandoRelativo(DateTime(2026, 11, 8, 23), _agora), 'ontem');
    expect(quandoRelativo(DateTime(2026, 11, 5), _agora), '05 nov');
    expect(haQuanto(DateTime(2026, 11, 9, 14, 48), _agora), 'há 12 min');
    expect(haQuanto(DateTime(2026, 11, 9, 13), _agora), 'há 2 h');
  });

  Future<void> abrir(WidgetTester t, ModeloInicio m) async {
    appStateSettings = {
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'forceFullDarkBackground': false,
    };
    await t.pumpWidget(MaterialApp(
      theme: temaEditorial(Brightness.light),
      home: Scaffold(body: InicioEditorial.comModelo(m)),
    ));
    await t.pump(const Duration(seconds: 2));
  }

  ModeloInicio comCiclo(Map<String, dynamic> ciclo) => montarModeloInicio(
      ciclo: ciclo, contas: [
        {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Inter', 'bank': 'Inter', 'balance': 1000.0}
      ], faturas: {}, sincronizadoEm: null, nome: 'Renan', agora: _agora);

  testWidgets('Configurações › Início: sem ritmo diário', (t) async {
    await abrir(t, _montar());
    appStateSettings['inicioRitmoDiario'] = false;
    await t.pumpWidget(MaterialApp(
      theme: temaEditorial(Brightness.light),
      home: Scaffold(body: InicioEditorial.comModelo(_montar())),
    ));
    await t.pump(const Duration(seconds: 2));
    expect(find.textContaining('/dia'), findsNothing);
    expect(find.text('Para gastar no ciclo'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('cartão no formato do orçamento: selo, três blocos e rodapé', (t) async {
    await abrir(t, _montar());
    expect(find.text('Para gastar no ciclo'), findsOneWidget);
    // Valor grande e bloco "Livre" mostram o mesmo restante.
    expect(find.text('R\$ 3.700,00'), findsWidgets);
    expect(find.text('Gasto'), findsOneWidget);
    expect(find.text('Livre'), findsOneWidget);
    expect(find.text('R\$ 1.300,00'), findsOneWidget);
    expect(find.text('A vencer'), findsNothing); // sem contas a vencer, o bloco some
    expect(find.textContaining('abaixo do ritmo'), findsOneWidget);
    // Hoje conta: 16 dias depois de hoje + hoje. 3.700 / 17 dias.
    expect(find.text('17 dias'), findsOneWidget);
    expect(find.text('R\$ 217,65/dia'), findsOneWidget);
    // Saiu: "Gasto X de Y", "Ideal até hoje" e "Nas contas" duplicado.
    expect(find.textContaining('Gasto R\$'), findsNothing);
    expect(find.textContaining('Ideal até hoje'), findsNothing);
    expect(find.textContaining('Nas contas'), findsNothing);
    expect(find.text('Ciclo 26 out – 25 nov'), findsNothing);
    expect(find.text('Últimas'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('gasto acima do limite mostra o excedente, sem ritmo diário', (t) async {
    await abrir(t, comCiclo({'consumido': 5320.0, 'limite': 5000.0, 'diasRestantes': 0}));
    expect(find.text('Acima do limite do ciclo'), findsOneWidget);
    expect(find.text('R\$ 320,00'), findsOneWidget);
    expect(find.text('último dia'), findsOneWidget);
    expect(find.textContaining('/dia'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('sem limite mostra o saldo das contas', (t) async {
    await abrir(t, comCiclo({'consumido': 200.0}));
    expect(find.text('Disponível nas contas · Inter'), findsOneWidget);
    expect(find.text('R\$ 1.000,00'), findsWidgets);
    expect(find.text('Para gastar no ciclo'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  group('Início sem Meu Banco', () {
    ModeloInicio semBanco({List<CarteiraInicio> manuais = const []}) => montarModeloInicio(
        ciclo: {}, contas: [], faturas: {}, sincronizadoEm: null, nome: 'Renan', agora: _agora,
        manuais: manuais);
    const manuais = [(nome: 'Principal', saldo: 250.0), (nome: 'Dinheiro', saldo: -40.5)];

    test('semDados só sem Meu Banco e sem conta manual com lançamentos', () {
      expect(semBanco().semDados, true);
      expect(semBanco(manuais: manuais).semDados, false);
      expect(semBanco(manuais: manuais).soManuais, true);
      // Com Meu Banco (regra de sempre): não é "só manuais" e as manuais não mudam o resultado.
      expect(_montar().semDados, false);
      expect(_montar().soManuais, false);
    });

    test('manuais entram na igualdade do modelo (a recarga não ignora conta nova)', () {
      expect(semBanco(manuais: manuais), semBanco(manuais: manuais));
      expect(semBanco(manuais: manuais) == semBanco(), false);
    });

    testWidgets('só manuais: mostra o saldo e as contas, não "sem dados"', (t) async {
      await abrir(t, semBanco(manuais: manuais));
      expect(find.text('Saldo nas 2 contas manuais'), findsOneWidget);
      expect(find.text('R\$ 209,50'), findsOneWidget);
      expect(find.text('Suas contas'), findsOneWidget);
      expect(find.text('Principal'), findsOneWidget);
      expect(find.text('R\$ 250,00'), findsOneWidget);
      expect(find.text('−R\$ 40,50'), findsOneWidget);
      expect(find.textContaining('Ainda sem dados'), findsNothing);
      expect(find.textContaining('Adicione uma conta ou transação'), findsNothing);
      expect(find.text('Para gastar no ciclo'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('vazia: orienta o primeiro uso, com ações', (t) async {
      await abrir(t, semBanco());
      expect(find.textContaining('Adicione uma conta ou transação'), findsOneWidget);
      expect(find.textContaining('Puxe a tela'), findsNothing);
      expect(find.text('Nova transação'), findsOneWidget);
      expect(find.text('Adicionar conta'), findsOneWidget);
      expect(find.text('Conectar banco'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('vazia e pareada: lembra de puxar a tela e ainda oferece adicionar', (t) async {
      meuBancoPareado.value = true;
      addTearDown(() => meuBancoPareado.value = false);
      await abrir(t, semBanco());
      expect(find.textContaining('Puxe a tela para atualizar'), findsOneWidget);
      expect(find.text('Nova transação'), findsOneWidget);
      expect(find.text('Conectar banco'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('com Meu Banco: cartão do ciclo como antes, sem bloco de manuais', (t) async {
      await abrir(t, _montar());
      expect(find.text('Para gastar no ciclo'), findsOneWidget);
      expect(find.text('Suas contas'), findsNothing);
      expect(find.textContaining('Adicione uma conta ou transação'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('InicioEditorial não mostra Contas, Resumo nem Lançar rápido', (t) async {
    await abrir(t, _montar());
    expect(find.text('Contas'), findsNothing);
    expect(find.text('Resumo'), findsNothing);
    expect(find.textContaining('Lançar'), findsNothing);
    expect(find.text('Cartões'), findsNothing);
    expect(find.textContaining('Cartão Gold'), findsNothing);
    expect(find.text('Olá, Renan'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  group('Seu dinheiro', () {
    final contas = <Map<String, dynamic>>[
      {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Inter', 'bank': 'BANCO INTER ·69-6', 'balance': 893.47},
      {'id': 'n', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Nu', 'bank': 'Nu Pagamentos S.A.', 'balance': 50.0},
      {'id': 'c', 'type': 'CREDIT', 'name': 'Inter Black ·1234', 'balance': 569.0, 'due_date': '2026-11-10'},
      {'id': 'z', 'type': 'CREDIT', 'name': 'Zero ·9999', 'bank': 'Banco Zeta', 'balance': 0.0, 'due_date': '2026-11-20'},
      {'id': 'e', 'type': 'BANK', 'subtype': 'SAVINGS_ACCOUNT', 'name': 'Poup Zeta', 'bank': 'Banco Zeta', 'balance': 10.0},
    ];
    const invest = <InvestimentoBanco>[
      (nome: 'CDB - BANCO INTER', banco: 'BANCO INTER', saldo: 1049.0),
      (nome: 'CDB - BANCO INTER', banco: 'BANCO INTER', saldo: 951.0),
      (nome: 'Tesouro Selic', banco: null, saldo: 300.0),
      (nome: 'Fundo DI', banco: 'XP Investimentos', saldo: 7000.0),
    ];
    List<BancoInicio> agrupar() => mbAgruparPorBanco(
        contas: contas,
        faturas: const {},
        investimentos: invest,
        sincronizadoEm: _agora.toUtc().toIso8601String(),
        agora: _agora);

    test('reconhece o banco pelo nome normalizado', () {
      expect(mbBancoConhecido('BANCO INTER ·69-6')?.id, 'inter');
      expect(mbBancoConhecido('Nu Pagamentos S.A.')?.id, 'nubank');
      expect(mbBancoConhecido('Itaú Unibanco')?.id, 'itau');
      expect(mbBancoConhecido('Banco do Brasil')?.id, 'bb');
      expect(mbBancoConhecido('Banco Pan'), isNull);
      expect(mbBancoConhecido('International Bank'), isNull);
      expect(mbBancoConhecido(null), isNull);
    });

    test('agrupa conta, aplicação e fatura no mesmo banco; ordena pelo maior total', () {
      final b = agrupar();
      expect(b.map((x) => x.id), ['xp', 'inter', 'nubank', 'banco zeta', 'outros']);
      final inter = b.firstWhere((x) => x.id == 'inter');
      expect(inter.nome, 'Banco Inter');
      expect(inter.logo, 'inter');
      expect(inter.subtitulo, 'sincronizado agora');
      // Conta + 2 CDBs somados em uma linha − fatura (o cartão sem `bank` cai pelo nome "Inter Black").
      expect(inter.itens.map((i) => i.rotulo),
          ['Conta corrente', 'CDB · 2 aplicações', 'Fatura · vence 10/11']);
      expect(inter.itens.map((i) => i.valor), [893.47, 2000.0, -569.0]);
      expect(inter.total, closeTo(893.47 + 2000 - 569, .001));
      expect(inter.itens.last.fatura, true);
      expect(inter.itens.last.destaque, true); // vence em 1 dia
    });

    test('cartão sem banco entra no banco da mesma conexão e a poupança vem do banco da conta', () {
      final b = mbAgruparPorBanco(
          contas: [
            {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'BANCO INTER ·69-6', 'bank': null, 'balance': 100.0, 'item_id': 'i1'},
            {'id': 'g', 'type': 'CREDIT', 'name': 'GOLD', 'bank': null, 'balance': 40.0, 'due_date': '2026-11-10', 'item_id': 'i1'},
          ],
          faturas: const {},
          investimentos: const [
            (nome: 'Poupança Inter', banco: 'BANCO INTER ·69-6', saldo: 600.33),
            (nome: 'Poupança Santander', banco: 'Banco Santander Pessoa Física ·24-1', saldo: 1.06),
          ],
          sincronizadoEm: _agora.toUtc().toIso8601String(),
          agora: _agora);
      expect(b.map((x) => x.id), ['inter', 'santander']);
      final inter = b.first;
      expect(inter.logo, 'inter');
      expect(inter.itens.map((i) => i.rotulo), ['Conta corrente', 'Poupança Inter', 'Fatura · vence 10/11']);
      expect(inter.total, closeTo(100 + 600.33 - 40, .001));
      expect(b.last.itens.map((i) => i.rotulo), ['Poupança Santander']);
    });

    test('só investimentos, sem banco (Outros) e banco desconhecido sem logo', () {
      final b = agrupar();
      final xp = b.firstWhere((x) => x.id == 'xp');
      expect(xp.subtitulo, 'só investimentos');
      expect(xp.itens.single.rotulo, 'Fundo DI');
      final outros = b.last;
      expect(outros.nome, 'Outros');
      expect(outros.logo, isNull);
      expect(outros.itens.single.rotulo, 'Tesouro Selic');
      final zeta = b.firstWhere((x) => x.id == 'banco zeta');
      expect(zeta.logo, isNull);
      expect(zeta.nome, 'Banco Zeta');
      // Fatura de R$ 0 não vira linha.
      expect(zeta.itens.map((i) => i.rotulo), ['Poupança']);
    });

    test('a soma dos bancos fecha com o patrimônio (contas + aplicações − faturas)', () {
      final total = agrupar().fold<double>(0, (s, b) => s + b.total);
      expect(total, closeTo(893.47 + 50 + 10 + 2000 + 300 + 7000 - 569, .001));
    });

    testWidgets('seção mostra totais, bancos recolhidos (menos o da fatura em destaque) e abre pelo toque', (t) async {
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'forceFullDarkBackground': false,
      };
      t.view.physicalSize = const Size(390 * 2, 3000 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final dados = (
        patrimonio: mbPatrimonio(correntes: 943.47, poupancas: 10, investimentos: 9300, fatura: 569),
        faturas: const <FaturaAberta>[],
        carteiras: const <CarteiraInicio>[],
        bancos: agrupar(),
        semDados: false,
      );
      String? aberto;
      await t.pumpWidget(MaterialApp(
        theme: temaEditorial(Brightness.light),
        home: Scaffold(
            body: SingleChildScrollView(
                child: BancosPorBanco(fixo: dados, onAbrir: (c) => aberto = c))),
      ));
      await t.pump();
      expect(find.text('Seu dinheiro'), findsOneWidget);
      expect(find.text('Nas contas'), findsOneWidget);
      expect(find.text('R\$ 953,47'), findsOneWidget);
      expect(find.text('Investido'), findsOneWidget);
      expect(find.text('R\$ 9.300,00'), findsOneWidget);
      expect(find.text('Banco Inter'), findsOneWidget);
      expect(find.text('Fatura · vence 10/11'), findsOneWidget);
      expect(find.text('−R\$ 569,00'), findsOneWidget);
      await t.tap(find.text('Fatura · vence 10/11'));
      await t.pump();
      expect(aberto, mbPkConta('c'));
      await t.tap(find.text('Conta corrente'));
      await t.pump();
      expect(aberto, mbPkConta('a'));
      // Só o Inter (fatura vence em 1 dia) começa aberto; os outros mostram só o cabeçalho.
      expect(find.text('Fundo DI'), findsNothing);
      expect(find.text('Tesouro Selic'), findsNothing);
      expect(find.text('Poupança'), findsNothing);
      await t.tap(find.text('XP'));
      await t.pumpAndSettle();
      expect(find.text('Fundo DI'), findsOneWidget);
      await t.tap(find.text('XP'));
      await t.pumpAndSettle();
      expect(find.text('Fundo DI'), findsNothing);
      await t.tap(find.text('Banco Inter'));
      await t.pumpAndSettle();
      expect(find.text('Conta corrente'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('sem recolher (desktop) todos os bancos ficam abertos', (t) async {
      appStateSettings = {
        'materialYou': false,
        'accentSystemColor': false,
        'batterySaver': false,
        'increaseTextContrast': false,
        'forceFullDarkBackground': false,
      };
      t.view.physicalSize = const Size(390 * 2, 3000 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final dados = (
        patrimonio: mbPatrimonio(correntes: 943.47, poupancas: 10, investimentos: 9300, fatura: 569),
        faturas: const <FaturaAberta>[],
        carteiras: const <CarteiraInicio>[],
        bancos: agrupar(),
        semDados: false,
      );
      await t.pumpWidget(MaterialApp(
        theme: temaEditorial(Brightness.light),
        home: Scaffold(
            body: SingleChildScrollView(
                child: BancosPorBanco(fixo: dados, recolher: false))),
      ));
      await t.pump();
      expect(find.text('Fundo DI'), findsOneWidget);
      expect(find.text('Tesouro Selic'), findsOneWidget);
      expect(find.text('Poupança'), findsWidgets);
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('sem banco conectado: convite para conectar em vez da Início vazia', (t) async {
    await abrir(t, montarModeloInicio(
        ciclo: {}, contas: [], faturas: {}, sincronizadoEm: null, nome: '', agora: _agora));
    expect(find.text('Conectar banco'), findsOneWidget);
    expect(find.textContaining('Ainda sem dados'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('sem banco: 4 atalhos; pareado: some', (t) async {
    appStateSettings = {'materialYou': false, 'accentSystemColor': false, 'batterySaver': false,
      'increaseTextContrast': false, 'forceFullDarkBackground': false};
    await t.pumpWidget(MaterialApp(
        theme: temaEditorial(Brightness.light),
        home: const Scaffold(body: AtalhosInicio())));
    // Antes de conferir o token, nada (evita piscar num celular pareado).
    expect(find.text('Nova transação'), findsNothing);
    meuBancoPareadoConferido.value = true;
    addTearDown(() => meuBancoPareadoConferido.value = false);
    await t.pump();
    for (final r in ['Nova transação', 'Contas', 'Orçamentos', 'Metas']) {
      expect(find.text(r), findsOneWidget);
    }
    appStateSettings['inicioAtalhos'] = false;
    mbAjustesMudaram.value++;
    await t.pump();
    expect(find.text('Nova transação'), findsNothing);
    appStateSettings['inicioAtalhos'] = true;
    meuBancoPareado.value = true;
    addTearDown(() => meuBancoPareado.value = false);
    await t.pump();
    expect(find.text('Nova transação'), findsNothing);
  });

  testWidgets('sem dados mostra estado vazio em vez de R\$ 0,00', (t) async {
    meuBancoPareado.value = true;
    addTearDown(() => meuBancoPareado.value = false);
    await abrir(t, montarModeloInicio(
        ciclo: {}, contas: [], faturas: {}, sincronizadoEm: null, nome: '', agora: _agora));
    expect(find.textContaining('Ainda sem dados do banco. Puxe a tela para atualizar.'), findsOneWidget);
    expect(find.textContaining('Disponível'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  test('ModeloInicio: mesmo conteúdo é igual, saldo ou nome diferente não', () {
    List<Map<String, dynamic>> conta(double saldo) => [
          {'id': 'a', 'type': 'BANK', 'subtype': 'CHECKING_ACCOUNT', 'name': 'Conta Inter', 'bank': 'Inter', 'balance': saldo}
        ];
    expect(_montar(), _montar());
    expect(_montar().hashCode, _montar().hashCode);
    expect(_montar(), isNot(_montar(nome: 'Outro')));
    expect(_montar(contas: conta(10)), _montar(contas: conta(10)));
    expect(_montar(contas: conta(10)), isNot(_montar(contas: conta(20))));
  });

  test('mbSigla pula o prefixo genérico do nome do banco', () {
    expect(mbSigla('Banco Inter'), 'IN');
    expect(mbSigla('Banco do Brasil'), 'BR');
    expect(mbSigla('Cartão Poup'), 'PO');
    expect(mbSigla('Conta Poupança'), 'PO');
    expect(mbSigla('Nubank'), 'NU');
    expect(mbSigla('Itaú'), 'IT');
    expect(mbSigla('Banco'), 'BA');
    expect(mbSigla('X'), 'X');
    expect(mbSigla('  '), '··');
  });

  test('RecargaColapsada junta a rajada em uma recarga + uma repetição', () async {
    var cargas = 0;
    final r = RecargaColapsada(() async {
      cargas++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await Future.wait([for (var i = 0; i < 20; i++) r.pedir()]);
    expect(cargas, 2);
    await r.pedir();
    expect(cargas, 3);
    r.fechar();
    await r.pedir();
    expect(cargas, 3);
  });
}

void salarioPendenteTests() {
  group('pendência de salário (dado para a fila Para revisar)', () {
    test('Worker novo: lê o estado de 35 dias sem salário', () {
      final p = mbSalarioPendente({
        'salarioNaoDetectado': true,
        'diasSemSalario': 41,
        'ultimoSalario': '2026-09-26',
      });
      expect(p.pendente, true);
      expect(p.dias, 41);
      expect(p.ultimoSalario, DateTime(2026, 9, 26));
    });
    test('salário em dia: sem pendência', () {
      final p = mbSalarioPendente({'salarioNaoDetectado': false, 'diasSemSalario': 12, 'ultimoSalario': '2026-10-26'});
      expect(p.pendente, false);
      expect(p.dias, 12);
    });
    test('Worker antigo (sem os campos) ou sem ciclo: sem pendência e sem quebrar', () {
      for (final c in <Map?>[null, {}, {'inicio': '2026-10-26', 'ultimoSalario': null}]) {
        final p = mbSalarioPendente(c);
        expect(p.pendente, false);
        expect(p.dias, 0);
        expect(p.ultimoSalario, isNull);
      }
    });
  });
}
