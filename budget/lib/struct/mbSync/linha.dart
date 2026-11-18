import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:drift/drift.dart';

// O Worker aceita até 8192 bytes de `dados` por registro; sem folga o envio inteiro seria rejeitado.
const int mbLimiteDados = 7500;

// Colunas que não viajam: modificação (cada aparelho grava a sua ao aplicar, senão haveria reenvio infinito),
// compartilhamento e origem do lançamento.
const Set<String> mbLinhaSem = {
  'dateTimeModified',
  'methodAdded',
  'transactionOwnerEmail',
  'transactionOriginalOwnerEmail',
  'sharedKey',
  'sharedOldKey',
  'sharedStatus',
  'sharedDateUpdated',
  'sharedReferenceBudgetPk',
  'sharedOwnerMember',
  'sharedMembers',
  'sharedAllMembersEver',
  'memberTransactionFilters',
};

/// Serializador do `toJson`/`fromJson` do Drift: o padrão não converte as listas de enum e devolve
/// `List<dynamic>` onde a data class espera `List<String>`.
class MbSerializador extends ValueSerializer {
  const MbSerializador();

  @override
  dynamic toJson<T>(T value) => value is DateTime
      ? value.millisecondsSinceEpoch
      : value is List
          ? [for (final e in value) e is Enum ? e.index : e]
          : value;

  @override
  T fromJson<T>(dynamic json) {
    if (json == null) return null as T;
    final t = <T>[];
    if (t is List<DateTime?>) {
      return DateTime.fromMillisecondsSinceEpoch(json as int) as T;
    }
    if (t is List<double?> && json is int) return json.toDouble() as T;
    if (json is List) {
      if (t is List<List<String>?>) return List<String>.from(json) as T;
      if (t is List<List<BudgetTransactionFilters>?>) {
        return [
          for (final i in json)
            if (i is int && i >= 0 && i < BudgetTransactionFilters.values.length)
              BudgetTransactionFilters.values[i]
        ] as T;
      }
      if (t is List<List<HomePageWidgetDisplay>?>) {
        return [
          for (final i in json)
            if (i is int && i >= 0 && i < HomePageWidgetDisplay.values.length)
              HomePageWidgetDisplay.values[i]
        ] as T;
      }
    }
    return json as T;
  }
}

const MbSerializador mbSerializador = MbSerializador();

/// Acrescenta `linha` (a linha Drift completa, sem as colunas de `mbLinhaSem`) a `dados`.
/// Passando de [mbLimiteDados] bytes, devolve `dados` sem ela (e o envio segue só com os campos mapeados).
Map<String, dynamic> mbComLinha(
    Map<String, dynamic> dados, Map<String, dynamic> toJson) {
  final com = {
    ...dados,
    'linha': {
      for (final e in toJson.entries)
        if (!mbLinhaSem.contains(e.key)) e.key: e.value
    }
  };
  return utf8.encode(jsonEncode(com)).length > mbLimiteDados ? dados : com;
}

/// `dados['linha']` como mapa, ou null se não veio.
Map<String, dynamic>? mbLerLinha(Map<String, dynamic> dados) {
  final l = dados['linha'];
  return l is Map ? l.cast<String, dynamic>() : null;
}

/// Lê a linha com a data class; formato inesperado (versão diferente do app) devolve null e o mapeado vale.
T? mbLinhaComo<T>(T Function(Map<String, dynamic>) ler, Map<String, dynamic> l) {
  try {
    return ler(l);
  } catch (_) {
    return null;
  }
}
