// Conta dividida com troco: sugestão do gasto (mesmo dia/véspera), Pix enviado de volta à mesma pessoa, minha parte,
// Pix só dentro do gasto nas listas e os totais reais (Drift) iguais aos do Worker (Pizza Hut 76,23 − 50 + 11,88 = 38,11).
import 'dart:ffi';

import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart' show getBudgetDate;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/classificar.dart' show mbChavePadrao;
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/mbSync/rachadas.dart';
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

final _hoje = DateTime(2026, 11, 18);

MbGastoCandidato _g(String pk, double v, DateTime d, {String cat = 'Eating out', String nome = '99FOOD PIZZA HUT'}) =>
    MbGastoCandidato('mb:$pk', nome, cat, DateTime(d.year, d.month, d.day, 12), (v * 100).round());

String _dia(DateTime d) => d.toIso8601String().substring(0, 10);

Map<String, dynamic> _tx(String id, String desc, double valor, {DateTime? data, String? categoria}) => {
      'id': id, 'account_id': 'cc', 'date': _dia(data ?? DateTime.now()), 'description': desc,
      'amount': valor, 'status': 'POSTED', 'category': categoria, 'scheduled': 0,
    };

const _recebido = 'Pix recebido - Valentina De Paula Macedo';
const _devolvido = 'Pix enviado devolvido - Valentina De Paula Macedo';

MbVinculoReembolso _v(String r, String g, int centavos, DateTime d, {String desc = _recebido}) =>
    MbVinculoReembolso('mb:$r', 'mb:$g', mbChavePadrao(desc), centavos, data: d, nome: mbNomeDaPessoa(desc));

void main() {
  group('sugestão do gasto para Pix recebido maior que a metade', () {
    test('Pizza Hut do mesmo dia (76,23) aparece com o aviso do troco, depois das sugestões exatas', () {
      final r = mbSugerirReembolso([
        _g('pizza', 76.23, _hoje),
        _g('metade', 100, _hoje, cat: 'Casa', nome: 'CONTA'), // 50 = metade exata
      ], valor: 50, data: _hoje);
      expect(r.first.gasto.pk, 'mb:metade');
      final pizza = r.firstWhere((s) => s.gasto.pk == 'mb:pizza');
      expect(pizza.motivos, contains(mbMotivoTroco));
      expect(r.indexOf(pizza), 1);
    });

    test('véspera entra; dois dias antes não ganha o aviso', () {
      final vespera = mbSugerirReembolso([_g('pizza', 76.23, _hoje.subtract(const Duration(days: 1)))],
          valor: 50, data: _hoje);
      expect(vespera.single.motivos, contains(mbMotivoTroco));
      final antes = mbSugerirReembolso([_g('pizza', 76.23, _hoje.subtract(const Duration(days: 2)))],
          valor: 50, data: _hoje);
      expect(antes.single.motivos, isNot(contains(mbMotivoTroco)));
    });

    test('gasto que não é de rachar e Pix maior que o gasto não ganham o aviso', () {
      final luz = mbSugerirReembolso([_g('luz', 76.23, _hoje, cat: 'Casa', nome: 'ENERGIA')], valor: 50, data: _hoje);
      expect(luz.single.motivos, isNot(contains(mbMotivoTroco)));
      final maior = mbSugerirReembolso([_g('pizza', 40, _hoje)], valor: 50, data: _hoje);
      expect(maior.single.motivos, isNot(contains(mbMotivoTroco)));
    });

    test('Pix de exatamente a metade do gasto não pergunta pelo troco', () {
      final r = mbSugerirReembolso([_g('pizza', 100, _hoje)], valor: 50, data: _hoje);
      expect(r.single.motivos, ['metade']);
    });
  });

  group('troco: Pix enviado à mesma pessoa até 3 dias depois do reembolso', () {
    final vinculos = [_v('r1', 'g1', 5000, _hoje)];

    MbVinculoReembolso? sugerir(String desc, double valor, DateTime data,
            {Iterable<MbVinculoReembolso>? v, Iterable<MbTroco> trocos = const []}) =>
        mbSugerirTroco(v ?? vinculos, trocos, descricao: desc, valor: valor, data: data);

    test('o nome com "devolvido" casa com o Pix recebido (a chave de 4 palavras não casaria)', () {
      expect(mbNomeDaPessoa(_recebido), mbNomeDaPessoa(_devolvido));
      expect(sugerir(_devolvido, -11.88, _hoje)?.reembolsoPk, 'mb:r1');
    });

    test('janela de 0 a 3 dias', () {
      expect(sugerir(_devolvido, 11.88, _hoje.add(const Duration(days: 3))), isNotNull);
      expect(sugerir(_devolvido, 11.88, _hoje.add(const Duration(days: 4))), isNull, reason: 'fora da janela');
      expect(sugerir(_devolvido, 11.88, _hoje.subtract(const Duration(days: 1))), isNull, reason: 'antes do Pix recebido');
    });

    test('outra pessoa, outro tipo de lançamento e troco maior que o reembolso não sugerem', () {
      expect(sugerir('Pix enviado - Isabel Souza Lima', 11.88, _hoje), isNull);
      expect(sugerir(_recebido, 11.88, _hoje), isNull);
      expect(sugerir(_devolvido, 50.01, _hoje), isNull);
      expect(sugerir(_devolvido, 50, _hoje), isNotNull);
    });

    test('o que já foi devolvido sai do que sobra do reembolso', () {
      final jaDevolvido = [MbTroco('mb:t0', 'mb:r1', 4000, data: _hoje)];
      expect(sugerir(_devolvido, 11.88, _hoje, trocos: jaDevolvido), isNull);
      expect(sugerir(_devolvido, 10, _hoje, trocos: jaDevolvido), isNotNull);
    });

    test('vários reembolsos da pessoa: o mais recente', () {
      final v = [_v('r0', 'g0', 3000, _hoje.subtract(const Duration(days: 2))), _v('r1', 'g1', 5000, _hoje)];
      expect(sugerir(_devolvido, 10, _hoje, v: v)?.reembolsoPk, 'mb:r1');
    });

    test('trocos das decisões: só de reembolso ligado e nunca além do reembolso', () {
      final decisoes = <Map<String, dynamic>>[
        {'tx_id': 'r1', 'resposta': 'reembolso', 'reembolso_de': 'g1', 'valor': 50, 'data': '2026-11-18', 'descricao': _recebido},
        {'tx_id': 't1', 'resposta': 'troco', 'troco_de': 'r1', 'valor': 11.88, 'data': '2026-11-18'},
        {'tx_id': 't2', 'resposta': 'troco', 'troco_de': 'r1', 'valor': 40, 'data': '2026-11-19'}, // passa do reembolso
        {'tx_id': 't3', 'resposta': 'troco', 'troco_de': 'rX', 'valor': 5, 'data': '2026-11-18'}, // sem reembolso ligado
      ];
      final t = mbTrocosLigados(decisoes, mbVinculosReembolso(decisoes));
      expect([for (final x in t) [x.trocoPk, x.reembolsoPk, x.centavos]], [['mb:t1', 'mb:r1', 1188]]);
    });
  });

  group('minha parte e conta rachada nas listas', () {
    test('76,23 − 50 + 11,88 = 38,11; troco nunca passa do reembolso; reembolso maior que o gasto zera', () {
      expect(mbMinhaParte(7623, [5000], [1188]), (parte: 3811, excesso: 0));
      expect(mbMinhaParte(7623, [5000], [9000]), (parte: 7623, excesso: 0));
      expect(mbMinhaParte(3000, [5000]), (parte: 0, excesso: 2000));
      expect(mbMinhaParte(3000, [5000], [1000]), (parte: 0, excesso: 1000));
    });

    final vinculos = [_v('r1', 'g1', 5000, _hoje)];
    final trocos = [MbTroco('mb:t1', 'mb:r1', 1188, data: _hoje)];

    test('os dois Pix saem da lista e o gasto mostra a minha parte', () {
      final r = mbCalcularRachadas(vinculos, trocos, {'mb:g1'});
      expect(r.ocultos, {'mb:r1', 'mb:t1'});
      expect(r.porGasto['mb:g1']!.liquido(7623), 3811);
      expect(r.porGasto['mb:g1']!.pessoas, 'Valentina');
      expect(r.porGasto['mb:g1']!.indicacao, contains('Pix de Valentina'));
      expect(r.porGasto['mb:g1']!.indicacao, contains('troco'));
    });

    test('sem o gasto no aparelho o Pix continua na lista', () {
      expect(mbCalcularRachadas(vinculos, trocos, {}).ocultos, isEmpty);
    });

    test('troco de reembolso desligado não esconde nada', () {
      expect(mbCalcularRachadas(const [], trocos, {'mb:g1'}).ocultos, isEmpty);
    });

    test('a busca acha o Pizza Hut por "Valentina", "valen", "50", "50,00" e "11,88" (mas não por "5")', () {
      final r = mbCalcularRachadas(vinculos, trocos, {'mb:g1'});
      for (final q in ['Valentina', 'valen', '50', '50,00', '11,88', '11.88']) {
        expect(r.gastosDaBusca(q), ['mb:g1'], reason: q);
      }
      for (final q in ['5', 'isabel', '', '1']) {
        expect(r.gastosDaBusca(q), isEmpty, reason: q);
      }
    });
  });

  group('totais com o troco (Drift)', () {
    late _Cliente cliente;

    setUpAll(() {
      open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    });

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      database = FinanceDatabase(NativeDatabase.memory());
      SharedPreferences.setMockInitialValues({'mbNotifCursor': 'x'});
      cliente = _Cliente();
      meuBancoSincronizando.value = false;
      meuBancoRachadas.value = const MbRachadas();
    });

    tearDown(() => database.close());

    Future<void> sync() async =>
        expect(await sincronizarMeuBanco(clienteParaTeste: cliente), true, reason: meuBancoUltimoErro.value);

    Future<Transaction> tx(String pk) =>
        (database.select(database.transactions)..where((t) => t.transactionPk.equals(pk))).getSingle();

    Future<double> geral() async {
      final b = await database.getBudgetInstance(mbOrcamentoGeralPk);
      final v = await mbWatchGastoOrcamento(
              b, await database.watchAllWalletsIndexed().first, getBudgetDate(b, DateTime.now()))
          .first;
      return (v * 100).round() / 100;
    }

    Future<void> ligar() => mbResponderRevisao(mbItemDeEntrada('mb:r1', 50, DateTime.now(), _recebido), 'reembolso',
        reembolsoDe: 'g1', clienteParaTeste: cliente);

    Future<void> devolver([double valor = 11.88]) => mbResponderRevisao(
        mbItemDeEntrada('mb:t1', valor, DateTime.now(), _devolvido, tipo: 'pix_enviado'), 'troco',
        trocoDe: 'r1', clienteParaTeste: cliente);

    void caso() => cliente.transacoes = [
          _tx('g1', '99food Pizza Hut', -76.23, categoria: 'Eating out'),
          _tx('r1', _recebido, 50),
          _tx('t1', _devolvido, -11.88),
        ];

    test('caso real: Geral 76,23 − 50 + 11,88 = 38,11 (igual ao Worker); troco na categoria do gasto; Pix some da lista',
        () async {
      caso();
      await sync();
      expect(await geral(), 88.11, reason: 'antes: o Pix enviado conta e o recebido é receita');

      await ligar();
      expect(await geral(), 38.11);
      await devolver();
      expect(await geral(), 38.11, reason: 'o troco abate o reembolso, não é gasto novo na lista');

      final g1 = await tx('mb:g1'), r1 = await tx('mb:r1'), t1 = await tx('mb:t1');
      expect([r1.amount, r1.categoryFk, r1.income], [50, g1.categoryFk, false]);
      expect([t1.amount, t1.categoryFk, t1.subCategoryFk, t1.income], [-11.88, g1.categoryFk, g1.subCategoryFk, false]);
      expect(meuBancoTrocos.value.map((t) => t.trocoPk), ['mb:t1']);
      expect(meuBancoRachadas.value.ocultos, {'mb:r1', 'mb:t1'});
      expect(meuBancoRachadas.value.valorNaLista(g1), -38.11);
    });

    test('troco recusado: só o reembolso fica ligado e o gasto mostra 76,23 − 50', () async {
      caso();
      await sync();
      await ligar();
      expect(meuBancoTrocos.value, isEmpty);
      expect(meuBancoRachadas.value.ocultos, {'mb:r1'});
      expect(meuBancoRachadas.value.valorNaLista(await tx('mb:g1')), -26.23);
    });

    test('desligar o reembolso desfaz o troco e os Pix voltam à lista', () async {
      caso();
      await sync();
      await ligar();
      await devolver();

      await mbDesfazerRevisao('r1', clienteParaTeste: cliente);
      expect(meuBancoTrocos.value, isEmpty);
      expect(meuBancoRachadas.value.ocultos, isEmpty);
      expect(await geral(), 88.11);
      expect((await tx('mb:r1')).income, true);
    });

    test('reembolso maior que o gasto: minha parte zera, sem ficar negativa', () async {
      cliente.transacoes = [_tx('g1', 'Pizza Hut', -30, categoria: 'Eating out'), _tx('r1', _recebido, 50)];
      await sync();
      await ligar();
      expect(meuBancoRachadas.value.valorNaLista(await tx('mb:g1')), 0);
    });

    test('troco maior que o reembolso é ignorado: nada fica ligado', () async {
      caso();
      await sync();
      await ligar();
      await devolver(60);
      expect(meuBancoTrocos.value, isEmpty);
      expect(meuBancoRachadas.value.ocultos, {'mb:r1'});
    });

    test('offline: a decisão do troco fica gravada e o Pix some da lista sem rede', () async {
      caso();
      await sync();
      await ligar();
      cliente.offline = true;
      await devolver();
      expect(meuBancoTrocos.value.map((t) => t.trocoPk), ['mb:t1']);
      expect(meuBancoRachadas.value.ocultos, contains('mb:t1'));
    });
  });
}

class _Cliente extends MbCliente {
  _Cliente() : super(base: 'https://teste');
  List<Map<String, dynamic>> transacoes = [];
  bool offline = false;

  @override
  Future<Map<String, dynamic>> puxar(String? desde) async {
    if (offline) throw Exception('sem rede');
    final hoje = DateTime.now();
    return {
      'agora': hoje.toUtc().toIso8601String(),
      'contas': [{'id': 'cc', 'type': 'BANK', 'name': 'Conta Inter'}],
      'transacoes': desde == null ? transacoes : [],
      'pendentes': [],
      'ciclo': {
        'inicio': _dia(hoje.subtract(const Duration(days: 5))),
        'fim': _dia(hoje.add(const Duration(days: 25))),
      },
    };
  }
}
