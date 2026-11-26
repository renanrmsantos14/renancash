import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _d(String tx, String data, String dest, {String resposta = 'emprestimo', String? pessoa}) => {
      'tipo': 'decisao',
      'tx_id': tx,
      'resposta': resposta,
      'valor': 100.0,
      'data': data,
      'destinatario': dest,
      if (pessoa != null) 'pessoa': pessoa,
    };

void main() {
  test('devolve a pessoa do empréstimo mais recente do mesmo destinatário', () {
    final ds = [
      _d('a', '2026-10-01', 'JOAO SILVA', pessoa: 'João'),
      _d('b', '2026-11-05', 'JOAO SILVA', pessoa: 'Pai'),
      _d('c', '2026-11-20', 'MARIA', pessoa: 'Mãe'),
    ];
    expect(mbPessoaLembrada(ds)['JOAO SILVA'], 'Pai');
    expect(mbPessoaLembrada(ds)['MARIA'], 'Mãe');
  });

  test('sem destinatário, sem histórico, sem pessoa ou outra resposta: null', () {
    final ds = [
      _d('a', '2026-11-01', 'JOAO SILVA'),
      _d('b', '2026-11-02', 'JOAO SILVA', pessoa: '  '),
      _d('c', '2026-11-03', 'JOAO SILVA', resposta: 'devolucao', pessoa: 'Pai'),
    ];
    expect(mbPessoaLembrada(ds)['JOAO SILVA'], isNull);
    expect(mbPessoaLembrada(ds)['OUTRO'], isNull);
    expect(mbPessoaLembrada(ds).containsKey(null), isFalse);
    expect(mbPessoaLembrada(ds)[''], isNull);
    expect(mbPessoaLembrada(const [])['JOAO SILVA'], isNull);
  });

  test('pessoa vazia mais recente não esconde a anterior, e o nome vem sem espaços sobrando', () {
    final ds = [
      _d('a', '2026-10-01', 'JOAO SILVA', pessoa: ' Pai '),
      _d('b', '2026-11-05', 'JOAO SILVA'),
    ];
    expect(mbPessoaLembrada(ds)['JOAO SILVA'], 'Pai');
  });
}
