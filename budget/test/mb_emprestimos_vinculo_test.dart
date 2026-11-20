// Empréstimos ligados a uma pessoa: pagamentos que abatem o empréstimo escolhido, sobra, perdão, fora do Geral e a barra nova.
// Nomes e valores são sintéticos.
import 'package:budget/struct/mbSync/barra.dart';
import 'package:budget/struct/mbSync/categoriaEfetiva.dart';
import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _emp(String tx, double valor, String data, {String pessoa = 'Ana', String? id}) => {
      'tipo': 'decisao', 'tx_id': tx, 'resposta': 'emprestimo', 'valor': valor, 'data': data, 'pessoa': pessoa,
      if (id != null) 'emprestimo_id': id,
    };

Map<String, dynamic> _pag(String tx, double valor, String data, String alvo,
        {double? sobra, String? sobraPara, String? sobraId}) =>
    {
      'tipo': 'decisao', 'tx_id': tx, 'resposta': 'devolucao', 'valor': valor, 'data': data, 'emprestimo_id': alvo,
      if (sobra != null) 'sobra': sobra,
      if (sobraPara != null) 'sobra_para': sobraPara,
      if (sobraId != null) 'sobra_id': sobraId,
    };

Map<String, dynamic> _perdao(String alvo, double valor, String data) =>
    {'tipo': 'perdao', 'emprestimo_id': alvo, 'valor': valor, 'data': data};

void main() {
  group('pagamento vinculado', () {
    test('abate só o empréstimo escolhido, mesmo o mais novo; o resto fica', () {
      final e = mbCalcularEmprestimos([_emp('a', 500, '2026-11-02'), _emp('b', 300, '2026-11-08'), _pag('p', 100, '2026-11-09', 'b')]);
      expect([for (final x in e.abertos) (x.txId, x.restante)], [('a', 500.0), ('b', 200.0)]);
      expect(e.porId('b')!.pagamentos.single.centavos, 10000);
      expect(e.porId('b')!.parcial, true);
      expect(e.devido, 700);
    });

    test('pagamento total quita e vai para os quitados; pagar de novo não abate nada', () {
      final e = mbCalcularEmprestimos([
        _emp('a', 100, '2026-11-02'),
        _pag('p1', 100, '2026-11-03', 'a'),
        _pag('p2', 50, '2026-11-04', 'a'),
      ]);
      expect(e.abertos, isEmpty);
      expect(e.quitados.single.txId, 'a');
      expect(e.quitados.single.pagamentos.length, 1);
      expect(e.devido, 0);
    });

    test('vínculo com empréstimo que não existe mais (decisão desfeita) não abate outro', () {
      final e = mbCalcularEmprestimos([_emp('a', 100, '2026-11-02'), _pag('p', 100, '2026-11-03', 'fantasma')]);
      expect(e.devido, 100);
    });

    test('pagamento sem vínculo (antigo) continua abatendo o mais antigo', () {
      final e = mbCalcularEmprestimos([
        _emp('a', 100, '2026-11-02'),
        _emp('b', 100, '2026-11-03'),
        {'tipo': 'decisao', 'tx_id': 'p', 'resposta': 'devolucao', 'valor': 150, 'data': '2026-11-04'},
      ]);
      expect([for (final x in e.abertos) (x.txId, x.restante)], [('b', 50.0)]);
    });

    test('Pix maior que o saldo: a sobra para outro empréstimo da pessoa abate o outro', () {
      final e = mbCalcularEmprestimos([
        _emp('a', 100, '2026-11-02'),
        _emp('b', 80, '2026-11-03'),
        _pag('p', 130, '2026-11-04', 'a', sobra: 30, sobraPara: 'emprestimo', sobraId: 'b'),
      ]);
      expect([for (final x in e.abertos) (x.txId, x.restante)], [('b', 50.0)]);
    });

    test('sobra para reembolso ou renda não mexe em empréstimo', () {
      for (final destino in ['reembolso', 'renda']) {
        final e = mbCalcularEmprestimos([_emp('a', 100, '2026-11-02'), _pag('p', 130, '2026-11-04', 'a', sobra: 30, sobraPara: destino)]);
        expect(e.abertos, isEmpty, reason: destino);
        expect(e.quitados.single.pagamentos.single.centavos, 10000);
      }
    });

    test('empréstimo novo somado a um existente (emprestimo_id) soma o valor ao mesmo', () {
      final e = mbCalcularEmprestimos([_emp('a', 100, '2026-11-02'), _emp('c', 40, '2026-11-05', id: 'a')]);
      expect([for (final x in e.abertos) (x.txId, x.original)], [('a', 140.0)]);
    });
  });

  group('perdão', () {
    test('o saldo restante sai do aberto e vai para os quitados, com a data do perdão', () {
      final e = mbCalcularEmprestimos([_emp('a', 100, '2026-11-02'), _pag('p', 30, '2026-11-03', 'a')],
          perdoes: [_perdao('a', 70, '2026-11-10')]);
      expect(e.abertos, isEmpty);
      final q = e.quitados.single;
      expect([q.perdoado, q.perdoadoEm, q.pagoCentavos], [70, '2026-11-10', 3000]);
      expect(e.devido, 0);
    });

    test('perdoar empréstimo sem saldo (já pago) não faz nada', () {
      final e = mbCalcularEmprestimos([_emp('a', 100, '2026-11-02'), _pag('p', 100, '2026-11-03', 'a')],
          perdoes: [_perdao('a', 10, '2026-11-10')]);
      expect(e.quitados.single.perdoadoEm, isNull);
    });
  });

  group('por pessoa', () {
    test('mesmo nome com caixa e acento diferentes agrupa; os da pessoa vêm primeiro no pagamento', () {
      final e = mbCalcularEmprestimos([_emp('a', 100, '2026-11-02', pessoa: 'José'), _emp('b', 50, '2026-11-03', pessoa: 'jose '), _emp('c', 70, '2026-11-01', pessoa: 'Bia')]);
      final g = e.porPessoa;
      expect([for (final p in g) (p.nome, p.restanteCentavos)], [('Bia', 7000), ('José', 15000)]);
      final p = e.paraPagamento('JOSE');
      expect([for (final x in p.daPessoa) x.txId], ['a', 'b']);
      expect([for (final x in p.outros) x.txId], ['c']);
      expect(e.paraPagamento('Desconhecido').daPessoa, isEmpty);
    });
  });

  group('fila: Geral e Pix de empréstimo', () {
    Map<String, dynamic> tx(String id, String desc, double v, {String data = '2026-11-10'}) => {
          'id': id, 'account_id': 'cc', 'date': data, 'description': desc, 'amount': v, 'status': 'POSTED', 'category': null, 'scheduled': 0,
        };
    Registro reg(Map<String, dynamic> d) => Registro('revisoes', d['tipo'] == 'perdao' ? 'perdao:${d['emprestimo_id']}' : 'tx:${d['tx_id']}', d, '2026-11-11T00:00:00.000Z', null);
    MbResultado mapear(List<Map<String, dynamic>> txs, List<Map<String, dynamic>> decisoes) => mbMapearPull({
          'agora': '2026-11-12T10:00:00.000Z',
          'contas': [{'id': 'cc', 'type': 'BANK', 'name': 'Conta Inter'}],
          'transacoes': txs,
          'ciclo': {'inicio': '2026-11-05'},
        }, const MbContextoCategoria({}, [], {}),
            revisoes: MbRevisoes.deLinhas([for (final d in decisoes) reg(d)]),
            pkCategoria: (id, nome, receita) => id ?? mbPkCategoria(nome, receita));

    test('Pix enviado como empréstimo e pagamento recebido ficam fora do Geral', () {
      final r = mapear([
        tx('e', 'Pix enviado: Ana Souza', -200),
        tx('p', 'Pix recebido: Ana Souza', 80),
      ], [_emp('e', 200, '2026-11-10'), _pag('p', 80, '2026-11-10', 'e')]);
      expect(r.transacoes.map((t) => t.pk), isNot(contains('mb:e')));
      expect(r.transacoes.map((t) => t.pk), isNot(contains('mb:p')));
    });

    test('sobra para reembolso vira reembolso do valor da sobra; para renda vira receita da sobra', () {
      for (final (destino, receita) in [('reembolso', false), ('renda', true)]) {
        final r = mapear([tx('e', 'Pix enviado: Ana Souza', -50), tx('p', 'Pix recebido: Ana Souza', 80)],
            [_emp('e', 50, '2026-11-10'), _pag('p', 80, '2026-11-10', 'e', sobra: 30, sobraPara: destino)]);
        final t = r.transacoes.firstWhere((t) => t.pk == 'mb:p');
        expect([t.valor.abs(), t.receita], [30, receita], reason: destino);
      }
    });

    test('perdão vira gasto sintético na data do perdão e some quando é desfeito', () {
      final base = [tx('e', 'Pix enviado: Ana Souza', -200)];
      final com = mapear(base, [_emp('e', 200, '2026-11-10'), _perdao('e', 200, '2026-11-11')]);
      final t = com.transacoes.firstWhere((t) => t.pk == 'mb:perdao:e');
      expect([t.valor, t.receita, t.data], [-200, false, DateTime(2026, 11, 11, 12)]);
      expect(t.nome, 'Perdão de empréstimo · Ana');
      final sem = mapear(base, [_emp('e', 200, '2026-11-10')]);
      expect(sem.transacoes.map((t) => t.pk), isNot(contains('mb:perdao:e')));
    });
  });

  // Mesmos cenários e totais de apps/worker/test/revisao.test.mjs: o Geral do app e o do Worker têm de bater.
  group('paridade do Geral com o Worker (caso sintético)', () {
    Map<String, dynamic> tx(String id, int diasAtras, String desc, double v) => {
          'id': id, 'account_id': 'cc', 'description': desc, 'amount': v, 'status': 'POSTED', 'category': null, 'scheduled': 0,
          'date': DateTime.now().subtract(Duration(days: diasAtras)).toIso8601String().substring(0, 10),
        };
    String dia(int atras) => DateTime.now().subtract(Duration(days: atras)).toIso8601String().substring(0, 10);
    Registro reg(Map<String, dynamic> d) => Registro('revisoes', d['tipo'] == 'perdao' ? 'perdao:${d['emprestimo_id']}' : 'tx:${d['tx_id']}', d, '2026-11-11T00:00:00.000Z', null);
    double geral(List<Map<String, dynamic>> txs, List<Map<String, dynamic>> decisoes) {
      final r = mbMapearPull({
        'agora': DateTime.now().toUtc().toIso8601String(),
        'contas': [{'id': 'cc', 'type': 'BANK', 'name': 'Conta Inter'}],
        'transacoes': txs,
        'ciclo': {'inicio': dia(10)},
      }, const MbContextoCategoria({}, [], {}),
          revisoes: MbRevisoes.deLinhas([for (final d in decisoes) reg(d)]),
          pkCategoria: (id, nome, receita) => id ?? mbPkCategoria(nome, receita));
      return -r.transacoes.where((t) => !t.receita).fold<double>(0, (s, t) => s + t.valor);
    }

    test('empréstimos saem do Geral e o perdão entra na data dele (365,95 -> 100 -> 140)', () {
      final txs = [tx('p1', 6, 'Pix enviado: Isabel Souza', -250), tx('u1', 5, 'UBER *TRIP', -15.95), tx('m1', 3, 'MERCADO', -100)];
      expect(geral(txs, []).toStringAsFixed(2), '365.95');
      final emprestimos = [_emp('p1', 250, dia(6), pessoa: 'Isabel'), _emp('u1', 15.95, dia(5), pessoa: 'Isabel')];
      expect(geral(txs, emprestimos).toStringAsFixed(2), '100.00');
      expect(geral(txs, [...emprestimos, _perdao('p1', 40, dia(1))]).toStringAsFixed(2), '140.00');
    });

    test('Pix que passa do saldo com sobra para reembolso abate só a sobra (200 -> 170)', () {
      final txs = [tx('g1', 6, 'MERCADO', -200), tx('r1', 3, 'Pix recebido: Maria', 100)];
      final sobra = {..._pag('r1', 100, dia(3), 'x', sobra: 30, sobraPara: 'reembolso'), 'reembolso_de': 'g1'};
      expect(geral(txs, [sobra]).toStringAsFixed(2), '170.00');
    });
  });

  group('fila exige pessoa', () {
    test('empréstimo antigo sem pessoa é pedido de novo; com pessoa, não', () {
      final semPessoa = MbItemRevisao('tx:e', 'pix_enviado', txId: 'e', data: '2026-11-10', valor: 60);
      expect(semPessoa.semPessoa, false); // sem decisão não há o que repetir
    });
  });

  group('barra nova', () {
    test('migra atalhos personalizados uma vez e depois respeita o que o usuário escolher', () {
      final ajustes = <String, dynamic>{'customNavBarShortcut0': 'goals', 'customNavBarShortcut1': 'loans', 'customNavBarShortcut2': 'subscriptions'};
      expect(mbMigrarBarra(ajustes), true);
      expect([for (var i = 0; i < 3; i++) ajustes['customNavBarShortcut$i']], ['home', 'transactions', 'budgets']);
      ajustes['customNavBarShortcut1'] = 'goals';
      expect(mbMigrarBarra(ajustes), false);
      expect(ajustes['customNavBarShortcut1'], 'goals');
    });
  });
}
