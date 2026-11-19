import 'dart:convert';
import 'dart:io';

import 'package:budget/struct/mbSync/categoriaEfetiva.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show pkDoId;
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/mbSync/revisao.dart' show mbTipoDeRevisao;
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:flutter_test/flutter_test.dart';

Registro _reg(String tabela, String id, Map<String, dynamic> d) =>
    Registro(tabela, id, d, '2026-11-01T00:00:00.000Z', null);

/// Monta o contexto no formato do app (ajustes, regras, categorias por nome) a partir de linhas no formato dos
/// casos compartilhados com o core. O vínculo `pluggy` das categorias não existe mais no app.
MbContextoCategoria _ctx(Iterable<Registro> regs) {
  final ajustes = <String, Map<String, dynamic>>{};
  final regras = <MbRegraCtx>[];
  final nomes = <String, String>{};
  for (final r in regs) {
    final d = r.dados;
    if (r.deletedAt != null || d == null) continue;
    if (r.tabela == 'ajustes') {
      ajustes[r.id] = d;
    } else if (r.tabela == 'regras') {
      regras.add(MbRegraCtx(r.id, '${d['padrao']}', '${d['categoria_id']}', d['conta_id'] as String?,
          (d['prioridade'] as num?) ?? 0));
    } else if (r.tabela == 'categorias') {
      nomes['${d['tipo']}:${'${d['nome']}'.toLowerCase()}'] = r.id;
    }
  }
  return MbContextoCategoria(ajustes, regras, nomes);
}

MbResultado _pull(Map<String, dynamic> j, Iterable<Registro> regs) =>
    mbMapearPull(j, _ctx(regs),
        pkCategoria: (id, nome, receita) =>
            id != null ? pkDoId(id) : mbPkCategoria(nome, receita));

Map<String, dynamic> _json(Map<String, dynamic> tx) => {
      'agora': '2026-11-09T10:00:00.000Z',
      'contas': [
        {'id': 'cc', 'type': 'BANK', 'name': 'Conta'}
      ],
      'transacoes': [
        {
          'id': 't1',
          'account_id': 'cc',
          'date': '2026-11-02',
          'description': 'COMPRA DROGASIL',
          'amount': -20.0,
          'status': 'POSTED',
          'category': 'Pharmacy',
          'scheduled': 0,
          ...tx,
        }
      ],
      'pendentes': [],
      'ciclo': {'inicio': '2026-11-01'},
      'faturas': {'cc': []},
      'avisos': [
        {'item_id': 'i1'}
      ],
      'config': {'salario': '5000'},
      'sincronizado_em': '2026-11-09T09:00:00.000Z',
    };

void main() {
  group('categoria efetiva: casos compartilhados com o core', () {
    final casos = jsonDecode(
        File('test/fixtures/categoria-casos.json').readAsStringSync()) as List;
    // Os casos com vínculo `pluggy` na categoria valem só para o core: o app não tem mais esse vínculo.
    for (final c in casos.where((c) => !jsonEncode(c['registros']).contains('"pluggy"'))) {
      test(c['nome'] as String, () {
        final tx = c['tx'] as Map<String, dynamic>;
        final regs = [
          for (final r in c['registros'] as List)
            Registro(r['tabela'], r['id'], (r['dados'] as Map).cast<String, dynamic>(),
                '2026-11-01T00:00:00.000Z', r['deleted_at'])
        ];
        final r = mbCategoriaEfetiva(
            txId: tx['id'],
            contaId: tx['account_id'],
            descricao: tx['description'],
            categoriaPluggy: tx['category'],
            receita: c['receita'] as bool,
            ctx: _ctx(regs));
        expect(r.fonte, c['esperado']['fonte']);
        expect(r.categoriaId, c['esperado']['categoria_id']);
      });
    }
  });

  test('mbPadraoCasa escapa o resto e trata o curinga', () {
    expect(mbPadraoCasa('A.B*', 'A.B qualquer'), true);
    expect(mbPadraoCasa('A.B*', 'AxB'), false);
    expect(mbPadraoCasa('  ', 'x'), false);
  });

  group('mbMapearPull', () {
    test('ajuste gasto 0 pula; gasto 1 importa mesmo fora de gasto', () {
      final fora = {'category': 'Credit card payment', 'description': 'PAGAMENTO FATURA'};
      expect(_pull(_json(fora), []).transacoes, isEmpty);
      expect(_pull(_json(fora), [_reg('ajustes', 't1', {'gasto': 1})]).transacoes.length, 1);
      final r = _pull(_json({}), [_reg('ajustes', 't1', {'gasto': 0})]);
      expect(r.transacoes, isEmpty);
      expect(r.ignoradas, 1);
    });

    test('regra muda a categoria de uma transação anterior ao ciclo', () {
      final r = _pull(_json({'date': '2026-10-20'}), [
        _reg('regras', 'r1', {'padrao': 'COMPRA*', 'categoria_id': 'cashew:cx'})
      ]);
      expect(r.transacoes.single.categoriaPk, 'cx');
    });

    test('anterior ao ciclo: sem regra, converte a categoria do banco para a própria', () {
      expect(_pull(_json({'date': '2026-10-20'}), []).transacoes.single.categoriaPk, 'mb:cat:d:Saúde');
    });

    group('validação do ciclo atual', () {
      final aClassificar = mbPkCategoria('A classificar', false);

      test('todo lançamento do ciclo fica em "A classificar" até o usuário validar', () {
        final t = _pull(_json({}), []).transacoes.single;
        expect(t.categoriaNome, 'A classificar');
        expect(t.categoriaPk, aClassificar);
      });

      test('regra, categoria do banco e do painel só sugerem: seguem em "A classificar"', () {
        final t = _pull(_json({}), [
          _reg('regras', 'r1', {'padrao': 'COMPRA*', 'categoria_id': 'cashew:cx'})
        ]).transacoes.single;
        expect(t.categoriaPk, aClassificar);
      });

      test('ajuste de categoria é a validação e vale', () {
        final t = _pull(_json({}), [
          _reg('ajustes', 't1', {'categoria_id': 'cashew:cx'})
        ]).transacoes.single;
        expect(t.categoriaPk, 'cx');
      });

      test('recebimento do ciclo também espera a validação', () {
        final t = _pull(_json({'amount': 150.0, 'description': 'PIX RECEBIDO JOAO'}), []).transacoes.single;
        expect(t.receita, true);
        expect(t.categoriaNome, 'A classificar');
      });

      test('sem ciclo no servidor nada é reclassificado', () {
        final j = _json({})..['ciclo'] = <String, dynamic>{};
        expect(_pull(j, []).transacoes.single.categoriaPk, 'mb:cat:d:Saúde');
      });

      test('"A classificar" é criada como categoria própria', () {
        expect(_pull(_json({}), []).categoriasProprias, contains('A classificar'));
      });
    });

    test('repassa ciclo, faturas, avisos, config e sincronizado_em', () {
      final r = _pull(_json({}), []);
      expect(r.ciclo, {'inicio': '2026-11-01'});
      expect(r.faturas.keys, ['cc']);
      expect(r.avisos.length, 1);
      expect(r.config['salario'], '5000');
      expect(r.sincronizadoEm, '2026-11-09T09:00:00.000Z');
      expect(r.contasBrutas.single['id'], 'cc');
    });
  });

  test('Pix para o próprio titular (entre_minhas = 1) não é gasto nem vai para a fila; o ajuste do usuário manda', () {
    final pix = {'description': 'PIX ENVIADO JOSE', 'category': 'Transfer - PIX', 'amount': -300.0, 'entre_minhas': 1};
    expect(_pull(_json(pix), []).transacoes, isEmpty);
    expect(_pull(_json({...pix, 'entre_minhas': 0}), []).transacoes.length, 1);
    expect(_pull(_json(pix), [_reg('ajustes', 't1', {'gasto': 1})]).transacoes.length, 1);
    expect(mbTipoDeRevisao(descricao: 'PIX ENVIADO JOSE', valor: -300, entreMinhas: true), isNull);
    expect(mbTipoDeRevisao(descricao: 'PIX ENVIADO JOSE', valor: -300)?.tipo, 'pix_enviado');
  });

  test('transação apagada no banco (removidas) sai do app', () {
    final j = {..._json({}), 'transacoes': const [], 'removidas': ['velha']};
    expect(_pull(j, []).naoGastoPks, contains(mbPkTransacao('velha')));
  });
}
