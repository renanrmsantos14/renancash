// "Feito pela IA": modelo do que o Worker aplicou e a importação única dos padrões locais para a memória dele.
import 'dart:convert';

import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:flutter/foundation.dart';

/// Nome, categoria e subcategoria de uma transação num instante (antes ou depois da IA).
class MbIaValores {
  final String nome;
  final String? categoriaPk, subPk;
  const MbIaValores(this.nome, this.categoriaPk, this.subPk);

  static MbIaValores? tentar(Object? j) => j is Map
      ? MbIaValores('${j['name'] ?? ''}', _txt(j['category_fk']), _txt(j['sub_category_fk']))
      : null;
}

String? _txt(Object? v) => v is String && v.isNotEmpty ? v : null;

class MbIaAplicada {
  final String txId, origem, status; // origem: memoria|regra|llama|anotacao|devolucao; status: pendente|aplicada|desfeita
  final MbIaValores? antes;
  final MbIaValores depois;
  final DateTime? data;
  const MbIaAplicada(this.txId, this.origem, this.status, this.antes, this.depois, this.data);

  bool get desfeita => status == 'desfeita';

  /// Devolução de compra: não tem nome nem categoria para corrigir, só Desfazer.
  bool get devolucao => origem == 'devolucao';

  /// Linha do Drift no espelho (`mb:<tx_id>`).
  String get pk => 'mb:$txId';

  String get rotuloOrigem => switch (origem) {
        'memoria' => 'Memória',
        'regra' => 'Regra',
        'llama' => 'IA',
        'anotacao' => 'Anotação',
        'devolucao' => 'Devolução de compra',
        _ => origem,
      };

  static MbIaAplicada? tentar(Object? j) {
    if (j is! Map || j['tx_id'] is! String) return null;
    final depois = MbIaValores.tentar(j['depois']);
    if (depois == null) return null;
    return MbIaAplicada(j['tx_id'] as String, '${j['origem'] ?? ''}', '${j['status'] ?? ''}',
        MbIaValores.tentar(j['antes']), depois,
        DateTime.tryParse('${j['aplicado_em'] ?? j['criado_em'] ?? ''}')?.toLocal());
  }

  static List<MbIaAplicada> lista(Map<String, dynamic> resposta) => [
        if (resposta['itens'] is List)
          for (final i in resposta['itens'] as List)
            if (tentar(i) case final a?) a
      ];
}

const String mbChaveMemoriaEnviada = 'ia_memoria_enviada';

bool _iaMemoriaEnviada = false; // confirmado nesta execução: não relê o estado a cada sync

/// Primeiro sync depois de atualizar: manda os padrões locais (`ia_padroes`) para `POST /api/ia/memoria`, uma vez só.
/// Só marca como enviado se o Worker aceitou; qualquer falha deixa para o próximo sync. Nunca lança.
Future<void> mbImportarPadroesParaIa(MbCliente cliente) async {
  if (_iaMemoriaEnviada) return;
  try {
    if (await mbLerEstado(mbChaveMemoriaEnviada) != null) {
      _iaMemoriaEnviada = true;
      return;
    }
    final padroes = mbPadroesDeJson(jsonDecode(await mbLerEstado('ia_padroes') ?? '[]'));
    if (padroes.isNotEmpty) {
      await cliente.iaMemoria([
        for (final p in padroes)
          {
            'chave': p.chave,
            'category_fk': p.categoriaPk,
            'sub_category_fk': p.subPk,
            'nome': p.titulo ?? '',
            'confirmacoes': p.vezes,
          }
      ]);
    }
    await mbGravarEstado({mbChaveMemoriaEnviada: '1'});
    _iaMemoriaEnviada = true;
  } catch (e) {
    if (kDebugMode) debugPrint('Meu Banco: importação dos padrões para a IA falhou: $e');
  }
}
