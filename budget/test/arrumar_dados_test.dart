import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/arrumarDadosPage.dart';
import 'package:budget/struct/arrumarDados.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/categoriaEfetiva.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show CatLocal;
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/temas.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Table;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

final _semEdicao = DateTime.utc(2000);

Transaction _tx(String pk, double valor, int dia,
        {String nome = '',
        String carteira = '0',
        String cat = 'c1',
        String? sub,
        String nota = '',
        TransactionSpecialType? tipo,
        String? emprestimo,
        String? meta,
        List<String>? excluidos,
        String? par}) =>
    Transaction(
      transactionPk: pk,
      name: nome,
      amount: valor,
      note: nota,
      categoryFk: cat,
      subCategoryFk: sub,
      walletFk: carteira,
      dateCreated: DateTime(2026, 7, dia, 12),
      dateTimeModified: _semEdicao,
      income: valor > 0,
      paid: true,
      skipPaid: false,
      type: tipo,
      objectiveLoanFk: emprestimo,
      objectiveFk: meta,
      budgetFksExclude: excluidos,
      pairedTransactionFk: par,
    );

Transaction _banco(String pk, double valor, int dia,
        {String nome = 'Compra no débito', String cat = 'mb:cat:d:Outros', String nota = ''}) =>
    _tx(pk, valor, dia, nome: nome, carteira: 'mb:inter', cat: cat, nota: nota);

TransactionCategory _cat(String pk, String nome, {bool receita = false, String? pai}) =>
    TransactionCategory(
        categoryPk: pk,
        name: nome,
        dateCreated: DateTime(2026),
        order: 0,
        income: receita,
        mainCategoryPk: pai);

TransactionWallet _w(String pk, String nome) => TransactionWallet(
    walletPk: pk, name: nome, dateCreated: DateTime(2026), order: 0, decimals: 2);

final _carteiras = [
  _w('0', 'Inter'),
  _w('mb:inter', 'BANCO INTER ·69-6'),
  _w('mb:gold', 'GOLD'),
];

ArrumarPlano _plano(List<Transaction> txs,
        {List<TransactionCategory> cats = const [],
        List<TransactionWallet>? carteiras,
        Set<String> usadas = const {},
        Set<String> arquivadas = const {},
        Set<String> juntados = const {},
        Map<String, String> mapa = const {}}) =>
    arrumarPlanejar(
        transacoes: txs,
        categorias: cats,
        carteiras: carteiras ?? _carteiras,
        usadas: usadas,
        arquivadas: arquivadas,
        juntados: juntados,
        mapa: mapa);

List<List<String>> _pares(ArrumarPlano p) => [
      for (final x in p.pares) [x.manual.transactionPk, x.banco.transactionPk]
    ];

void main() {
  group('pareamento', () {
    test('1:1 pela menor distância e janela de 4 dias', () {
      final p = _plano([
        _tx('m1', -10, 10),
        _tx('m2', -10, 11),
        _tx('m3', -10, 1), // nenhum lançamento do banco a até 4 dias
        _banco('mb:b1', -10, 10),
        _banco('mb:b2', -10, 15), // 5 dias de m1, 4 de m2
        _banco('mb:b3', -10, 25),
      ]);
      expect(_pares(p), [
        ['m1', 'mb:b1'],
        ['m2', 'mb:b2'],
      ]);
      expect(p.pares.map((x) => x.dias), [0, 4]);
    });

    test('empate de distância fica com o título parecido', () {
      final p = _plano([
        _tx('m1', -32.5, 10, nome: 'Uber trabalho'),
        _banco('mb:b1', -32.5, 9, nome: 'PADARIA'),
        _banco('mb:b2', -32.5, 11, nome: 'UBER *TRIP'),
      ]);
      expect(_pares(p), [
        ['m1', 'mb:b2']
      ]);
    });

    test('valor, sinal e carteira precisam bater', () {
      final p = _plano([
        _tx('m1', 10, 10),
        _tx('m2', -10.01, 10),
        _banco('mb:b1', -10, 10),
        _tx('mb:g1', -10.01, 10, carteira: 'mb:gold'), // cartão não é o mesmo banco
      ]);
      expect(p.pares, isEmpty);
    });

    test('ficam de fora futuras, ajuste de saldo, transferência, pendente e já juntados', () {
      final p = _plano([
        _tx('m1', -10, 10, tipo: TransactionSpecialType.subscription),
        _tx('m2', -20, 10, cat: '0'),
        _tx('m3', -30, 10, par: 'outra'),
        _tx('m4', -40, 10),
        _tx('m5', -50, 10),
        _banco('mb:b1', -10, 10),
        _banco('mb:b2', -20, 10),
        _banco('mb:b3', -30, 10),
        _banco('mb:b4', -40, 10, nota: 'Pendente'),
        _banco('mb:b5', -50, 10),
      ], juntados: {
        'mb:b5'
      });
      expect(p.pares, isEmpty);
    });
  });

  test('mescla copia o que o usuário pôs no manual', () {
    final agora = DateTime(2026, 11, 17, 10);
    final m = _tx('m1', -25, 10,
        nome: ' Pizza ',
        cat: 'alim',
        sub: 'deliv',
        nota: 'com amigos',
        emprestimo: 'div1',
        meta: 'meta1',
        excluidos: ['orc2']);
    final b = _banco('mb:b1', -25, 11, nome: 'IFOOD *PIZZA', nota: 'NSU 1')
        .copyWith(budgetFksExclude: const Value(['orc1']));
    final r = arrumarMesclar(m, b, agora);
    expect(r.transactionPk, 'mb:b1');
    expect(r.walletFk, 'mb:inter');
    expect(r.amount, -25);
    expect(r.dateCreated, b.dateCreated);
    expect([r.name, r.note, r.categoryFk, r.subCategoryFk], ['Pizza', 'NSU 1\ncom amigos', 'alim', 'deliv']);
    expect([r.objectiveLoanFk, r.objectiveFk], ['div1', 'meta1']);
    expect(r.budgetFksExclude, ['orc1', 'orc2']);
    expect(r.dateTimeModified, agora);
    // Manual sem título fica com o do banco.
    expect(arrumarMesclar(_tx('m2', -1, 1), b, agora).name, 'IFOOD *PIZZA');
  });

  group('categorias', () {
    final cats = [
      _cat('0', 'Balance Correction'),
      _cat('4', 'Transporte'),
      _cat('uber', 'Uber', pai: '4'),
      _cat('pedagio', 'Pedágio', pai: '4'),
      _cat('mor', 'Moradia'),
      _cat('energia', 'Energia', pai: 'mor'),
      _cat('mb:cat:d:Táxi e aplicativos', 'Táxi e aplicativos'),
      _cat('mb:cat:d:Pix', 'Pix'),
      _cat('mb:cat:d:Outros', 'Outros'),
      _cat('beleza', 'Beleza'),
      _cat('viagem', 'Viagem'),
      _cat('orc', 'Orçada'),
      _cat('obra', 'Obra'),
      _cat('reforma', 'Reforma', pai: 'obra'),
    ];
    const mapa = {
      'd:Táxi e aplicativos': 'Transporte › Uber',
      'd:Energia': 'Moradia › Energia',
    };

    test('migra pelo mapa e apaga só as vazias sem uso', () {
      final p = _plano([
        _banco('mb:b1', -18, 10, cat: 'mb:cat:d:Táxi e aplicativos'),
        _banco('mb:b2', -5, 10, cat: 'mb:cat:d:Pix'),
        _tx('t1', -9, 10, cat: 'obra', sub: 'reforma'),
      ], cats: cats, usadas: {'orc'}, mapa: mapa);
      expect(p.migracoes.single.transacao.transactionPk, 'mb:b1');
      expect([p.migracoes.single.destino.pk, p.migracoes.single.destino.subPk], ['4', 'uber']);
      expect(p.migracoes.single.destino.rotulo, 'Transporte › Uber');
      // Protegidas: ajuste de saldo, destinos do mapa (Energia), em uso (orçamento, transação, sub com uso) e
      // "Outros", que o pull recria. Subcategorias vêm antes das principais.
      expect(p.categorias.map((c) => c.categoryPk),
          ['pedagio', 'mb:cat:d:Táxi e aplicativos', 'beleza', 'viagem']);
    });

    test('principal com subcategoria em uso fica', () {
      final p = _plano([_tx('t1', -9, 10, cat: 'x', sub: 'reforma')], cats: cats, mapa: mapa);
      expect(p.categorias.map((c) => c.categoryPk), isNot(contains('obra')));
      expect(p.categorias.map((c) => c.categoryPk), contains('mb:cat:d:Pix'));
    });
  });

  test('arquiva carteira manual de banco que já vem do Meu Banco', () {
    final p = _plano(const [], carteiras: [
      ..._carteiras,
      _w('st', 'Santander'),
      _w('inv', 'Investimentos'),
      _w('viagem', 'Viagem'),
      _w('mb:st', 'Banco Santander Pessoa Física ·24-1'),
      _w('mb:investimentos', 'Investimentos'),
    ]);
    expect(p.carteiras.map((w) => w.walletPk), ['st', 'inv']);
    expect(
        _plano(const [], carteiras: [..._carteiras, _w('st', 'Santander'), _w('mb:st', 'Santander')],
                arquivadas: {'st'})
            .carteiras,
        isEmpty);
  });

  test('rodar de novo sobre o resultado não faz nada', () {
    final cats = [_cat('4', 'Transporte'), _cat('uber', 'Uber', pai: '4'), _cat('mb:cat:d:Táxi e aplicativos', 'Táxi e aplicativos'), _cat('beleza', 'Beleza')];
    const mapa = {'d:Táxi e aplicativos': 'Transporte › Uber'};
    final txs = [
      _tx('m1', -10, 10, cat: '4', sub: 'uber'),
      _tx('m2', -10, 11, cat: '4'),
      _banco('mb:b1', -10, 10, cat: 'mb:cat:d:Táxi e aplicativos'),
      _banco('mb:b2', -7, 10, cat: 'mb:cat:d:Táxi e aplicativos'),
    ];
    final carteiras = [..._carteiras, _w('st', 'Santander'), _w('mb:st', 'Santander ·24-1')];
    final p = _plano(txs, cats: cats, carteiras: carteiras, mapa: mapa);
    expect([p.pares.length, p.migracoes.length, p.carteiras.length, p.categorias.length], [1, 1, 1, 2]);

    final depois = {for (final t in txs) t.transactionPk: t};
    for (final x in p.pares) {
      depois.remove(x.manual.transactionPk);
      depois[x.banco.transactionPk] = arrumarMesclar(x.manual, x.banco, DateTime.now());
    }
    for (final m in p.migracoes) {
      depois[m.transacao.transactionPk] = m.transacao
          .copyWith(categoryFk: m.destino.pk, subCategoryFk: Value(m.destino.subPk));
    }
    final apagadas = {for (final c in p.categorias) c.categoryPk};
    final segundo = _plano(depois.values.toList(),
        cats: cats.where((c) => !apagadas.contains(c.categoryPk)).toList(),
        carteiras: carteiras,
        arquivadas: {'st'},
        juntados: {for (final x in p.pares) x.banco.transactionPk},
        mapa: mapa);
    // m2 ficou sem par: o lançamento do banco que casaria já recebeu m1.
    expect(segundo.vazio, isTrue);
  });

  group('mapa no pull', () {
    final destinos = mbResolverDestinos([
      for (final c in [
        _cat('4', 'Transporte'),
        _cat('uber', 'Uber', pai: '4'),
        _cat('mor', 'Moradia'),
        _cat('mb:cat:d:Moradia', 'Moradia'), // a do usuário vence a `mb:` de mesmo nome
      ])
        CatLocal(pk: c.categoryPk, nome: c.name, receita: c.income, paiPk: c.mainCategoryPk)
    ], mapa: const {
      'd:Táxi e aplicativos': 'Transporte › Uber',
      'd:Casa': 'Moradia',
      'd:Sem destino': 'Inexistente',
    });

    Map<String, dynamic> json(String? categoria) => {
          'contas': [
            {'id': 'a1', 'type': 'BANK', 'name': 'Conta'}
          ],
          'transacoes': [
            {'id': 't1', 'account_id': 'a1', 'date': '2026-11-02', 'description': 'UBER TRIP', 'amount': -18.0, 'status': 'POSTED', 'category': categoria},
          ],
        };

    MbResultado mapear(String? categoria, [MbContextoCategoria ctx = const MbContextoCategoria({}, [], {}, {})]) =>
        mbMapearPull(json(categoria), ctx,
            destinos: destinos,
            pkCategoria: (id, nome, receita) => id == null ? mbPkCategoria(nome, receita) : id.replaceFirst('cashew:', ''));

    test('resolve pai e sub pelo nome e ignora destino inexistente', () {
      expect(destinos.keys, ['d:Táxi e aplicativos', 'd:Casa']);
      expect([destinos['d:Casa']!.pk, destinos['d:Casa']!.subPk], ['mor', null]);
    });

    test('importação nova vai para Pai › Sub', () {
      final t = mapear('Taxi and ride-hailing').transacoes.single;
      expect([t.categoriaPk, t.subcategoriaPk, t.categoriaNome], ['4', 'uber', 'Transporte']);
    });

    test('categoria própria mapeada não é recriada como mb:cat', () {
      final r = mapear('Housing'); // Housing -> categoria própria "Casa" -> Moradia
      expect(r.transacoes.single.categoriaPk, 'mor');
      expect(r.categoriasProprias.keys, isNot(contains('Casa')));
      expect(r.categoriasProprias['Outros'], 'mb:cat:d:Outros');
    });

    test('escolha do usuário (ajuste) vale mais que o mapa', () {
      final ctx = MbContextoCategoria({
        't1': {'categoria_id': 'cashew:minha'}
      }, const [], const {}, const {});
      final t = mapear('Taxi and ride-hailing', ctx).transacoes.single;
      expect([t.categoriaPk, t.subcategoriaPk], ['minha', null]);
    });
  });

  testWidgets('tela: prévia, confirmação e resultado', (t) async {
    appStateSettings = {
      'materialYou': false,
      'accentSystemColor': false,
      'batterySaver': false,
      'increaseTextContrast': false,
      'appAnimations': 0,
    };
    final plano = ArrumarPlano(
      [ArrumarPar(_tx('m1', -25, 10, nome: 'Pizza'), _banco('mb:b1', -25, 11, nome: 'IFOOD'), 1)],
      [ArrumarMigracao(_banco('mb:b2', -18, 10, cat: 'mb:cat:d:Táxi e aplicativos'), const MbDestino('4', 'Transporte', 'uber', 'Uber'))],
      [_w('st', 'Santander')],
      [_cat('beleza', 'Beleza'), _cat('viagem', 'Viagem')],
    );
    var backups = 0, aplicados = 0;
    await t.pumpWidget(MaterialApp(
      theme: temaFlutter(temaPorId('padrao-claro')),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ArrumarDados(
            calcular: () async => plano,
            aplicar: () async {
              aplicados++;
              return plano;
            },
            backup: (_) async {
              backups++;
              return true;
            },
            arquivadas: () async => aplicados == 0 ? [] : [_w('st', 'Santander')],
            desarquivar: (_) async {},
          ),
        ),
      ),
    ));
    await t.pump();
    expect(find.text('Juntar 1 lançamentos repetidos'), findsOneWidget);
    expect(find.text('Táxi e aplicativos → Transporte › Uber (1)'), findsOneWidget);
    expect(find.text('Arquivar 1 carteiras'), findsOneWidget);
    expect(find.text('Beleza, Viagem'), findsOneWidget);

    await t.tap(find.text('Aplicar'));
    await t.pumpAndSettle();
    expect(find.text('Aplicar mudanças?'), findsOneWidget);
    await t.tap(find.text('Continuar revisando'));
    await t.pumpAndSettle();
    expect([backups, aplicados], [0, 0]);

    await t.tap(find.text('Aplicar'));
    await t.pumpAndSettle();
    await t.tap(find.text('Aplicar').last);
    await t.pumpAndSettle();
    expect([backups, aplicados], [1, 1]);
    expect(find.textContaining('Pronto. 1 lançamentos juntados'), findsOneWidget);
    expect(find.text('Mostrar de novo'), findsOneWidget);
  });

  group('aplicar no banco local', () {
    setUpAll(() {
      open.overrideFor(OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0'));
    });

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      database = FinanceDatabase(NativeDatabase.memory());
      SharedPreferences.setMockInitialValues({});
      sharedPreferences = await SharedPreferences.getInstance();
      appStateSettings = {};
    });

    tearDown(() => database.close());

    Future<void> carteira(String pk, String nome) => database
        .into(database.wallets)
        .insert(WalletsCompanion.insert(walletPk: Value(pk), name: nome, order: 0));

    Future<void> categoria(String pk, String nome, {String? pai}) =>
        database.into(database.categories).insert(CategoriesCompanion.insert(
            categoryPk: Value(pk), name: nome, order: 0, mainCategoryPk: Value(pai)));

    Future<void> lancamento(Transaction t) =>
        database.into(database.transactions).insert(t);

    test('junta, migra, arquiva, apaga e na segunda vez não faz nada', () async {
      await carteira('0', 'Inter');
      await carteira('mb:inter', 'BANCO INTER ·69-6');
      await carteira('st', 'Santander');
      await carteira('mb:st', 'Banco Santander ·24-1');
      await categoria('1', 'Alimentação');
      await categoria('deliv', 'Delivery', pai: '1');
      await categoria('mb:cat:d:Delivery', 'Delivery');
      await categoria('beleza', 'Beleza');
      await lancamento(_tx('m1', -25, 10, nome: 'Pizza', cat: '1', sub: 'deliv', nota: 'com amigos'));
      await lancamento(_banco('mb:b1', -25, 11, nome: 'IFOOD *PIZZA', cat: 'mb:cat:d:Delivery'));
      await lancamento(_banco('mb:b2', -30, 20, nome: 'IFOOD', cat: 'mb:cat:d:Delivery'));

      final p = await arrumarAplicar();
      expect([p.pares.length, p.migracoes.length, p.carteiras.length], [1, 1, 1]);

      final txs = {for (final t in await database.select(database.transactions).get()) t.transactionPk: t};
      expect(txs.keys.toSet(), {'mb:b1', 'mb:b2'});
      final b1 = txs['mb:b1']!;
      expect([b1.name, b1.note, b1.categoryFk, b1.subCategoryFk], ['Pizza', 'com amigos', '1', 'deliv']);
      expect(b1.dateTimeModified!.year, greaterThan(2001)); // sobe como ajuste e protege o título no pull
      expect([txs['mb:b2']!.categoryFk, txs['mb:b2']!.subCategoryFk], ['1', 'deliv']);
      final cats = {for (final c in await database.select(database.categories).get()) c.categoryPk};
      expect(cats, {'1', 'deliv'});
      expect(carteirasArquivadas(), {'st'});
      final todas = await database.watchAllWalletsIndexed().first;
      expect(todas.list.map((w) => w.walletPk), isNot(contains('st')));
      expect(todas.indexedByPk.keys, contains('st'));

      expect((await arrumarCalcular()).vazio, isTrue);
    });
  });
}
