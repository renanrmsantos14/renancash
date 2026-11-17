import 'package:budget/database/tables.dart';
import 'package:budget/pages/objectivesListPage.dart';
import 'package:budget/struct/mbSync/conexoes.dart';
import 'package:budget/widgets/editorial/resumoTransacoes.dart';
import 'package:budget/widgets/transactionEntry/transactionLabel.dart';
import 'package:flutter_test/flutter_test.dart';

Objective _emprestimo(double valor, {bool receita = true}) => Objective(
      objectivePk: 'e',
      name: 'Vô',
      amount: valor,
      order: 0,
      dateCreated: DateTime(2026, 6, 1),
      income: receita,
      pinned: false,
      walletFk: '0',
      archived: false,
      type: ObjectiveType.loan,
    );

Transaction _tx({String nome = '', String? sub}) => Transaction(
      transactionPk: 't',
      name: nome,
      amount: -20.9,
      note: '',
      categoryFk: 'c',
      subCategoryFk: sub,
      walletFk: '0',
      dateCreated: DateTime(2026, 11, 1),
      income: false,
      paid: false,
      skipPaid: false,
    );

TransactionCategory _cat(String pk, String nome) => TransactionCategory(
    categoryPk: pk,
    name: nome,
    dateCreated: DateTime(2026),
    order: 0,
    income: false,
    methodAdded: null);

void main() {
  group('EM1: total a receber por pessoa', () {
    test('quem pagou a mais conta zero e não abate os outros', () {
      // Saldos: negativo = a receber. "Vô" emprestou 626,56 e pagou 650.
      final saldos = [-670.0, -499.93, -30.0, -250.0, -626.56 + 650];
      final total = saldos.fold<double>(
          0, (s, v) => s + saldoEmprestimoSemExcesso(v, receita: true));
      expect(total, closeTo(-1449.93, 0.001));
    });

    test('a pagar: pagar a mais também conta zero', () {
      expect(saldoEmprestimoSemExcesso(120, receita: false), 120);
      expect(saldoEmprestimoSemExcesso(-15, receita: false), 0);
      expect(saldoEmprestimoSemExcesso(-15, receita: true), -15);
    });
  });

  group('EM2: cartão de empréstimo', () {
    test('quitado mostra o saldo (zero), não o valor recebido', () {
      final d = destaqueMeta(_emprestimo(626.56),
          alvo: 626.56, total: 650, mostrarTotal: false);
      expect(d.rotulo, 'Quitado · nada a receber');
      expect(d.valor, 0);
    });

    test('em aberto segue "A receber" com o que falta', () {
      final d = destaqueMeta(_emprestimo(1000),
          alvo: 1000, total: 330, mostrarTotal: false);
      expect(d.rotulo, 'A receber');
      expect(d.valor, 670);
    });

    test('vazio pede o valor emprestado', () {
      final d = destaqueMeta(_emprestimo(0),
          alvo: 0, total: 0, mostrarTotal: true);
      expect(d.rotulo, 'Valor emprestado');
      expect(d.valor, 0);
    });
  });

  group('MB2: conexão do MeuPluggy mostra o banco', () {
    test('nome vem das contas, sem número, S.A. nem caixa alta', () {
      expect(
          mbNomeDaConexao('MeuPluggy', [
            {'type': 'BANK', 'name': 'BANCO INTER ·69-6'},
            {'type': 'BANK', 'name': 'BANCO INTER ·69-6'},
            {'type': 'CREDIT', 'name': 'Mastercard Black'},
          ]),
          'Banco Inter');
      expect(
          mbNomeDaConexao('MeuPluggy', [
            {'type': 'BANK', 'bank': 'BANCO SANTANDER (BRASIL) S.A.'},
          ]),
          'Banco Santander');
    });

    test('conector que já é o banco fica como está; sem contas, o conector', () {
      expect(
          mbNomeDaConexao('Nubank', [
            {'type': 'BANK', 'name': 'Conta Nubank'}
          ]),
          'Nubank');
      expect(mbNomeDaConexao('MeuPluggy', const []), 'MeuPluggy');
    });
  });

  test('C2: origem da carteira no subtítulo', () {
    final tipos = {'mb:1': 'Conta corrente', 'mb:2': 'Poupança'};
    expect(mbOrigemCarteira('mb:1', tipos), 'Conta corrente · Meu Banco');
    expect(mbOrigemCarteira('mb:2', tipos), 'Poupança · Meu Banco');
    expect(mbOrigemCarteira('mb:investimentos', tipos), 'Meu Banco');
    expect(mbOrigemCarteira('0', tipos), 'Manual');
  });

  test('AS1: contagem diz o que é contado', () {
    expect(contagemAssinaturas(1), '1 assinatura');
    expect(contagemAssinaturas(2), '2 assinaturas');
    expect(contagemAgendadas(1), '1 agendada');
    expect(contagemAgendadas(2), '2 agendadas');
  });

  group('AS2: título vazio usa a subcategoria', () {
    final cat = _cat('c', 'Assinaturas');
    final sub = _cat('s', 'Spotify');

    test('subcategoria antes da categoria', () {
      expect(getTransactionLabelSync(_tx(sub: 's'), cat, subCategory: sub),
          'Spotify');
    });

    test('sem subcategoria, a categoria', () {
      expect(getTransactionLabelSync(_tx(), cat), 'Assinaturas');
    });

    test('com título, o título', () {
      expect(
          getTransactionLabelSync(_tx(nome: 'Plano família', sub: 's'), cat,
              subCategory: sub),
          'Plano família');
    });
  });
}
