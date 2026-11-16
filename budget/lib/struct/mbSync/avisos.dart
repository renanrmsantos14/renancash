import 'dart:convert';

import 'package:budget/struct/mbSync/armazem.dart';
import 'package:flutter/foundation.dart';

/// Avisos de conexão do último pull (`avisos` do estado): item com login pendente ou com erro.
Future<List<Map<String, dynamic>>> mbLerAvisos() async {
  try {
    final bruto = await mbLerEstado('avisos');
    if (bruto != null) {
      return [
        for (final a in jsonDecode(bruto) as List)
          if (a is Map) Map<String, dynamic>.from(a)
      ];
    }
  } catch (_) {}
  return [];
}

/// Bancos desconectados lidos do aparelho (aba Pendências e selo da barra).
/// Atualizado junto com a fila Para revisar (`mbAtualizarRevisar`).
final ValueNotifier<List<Map<String, dynamic>>> meuBancoAvisos = ValueNotifier(const []);

Future<void> mbAtualizarAvisos() async {
  final novos = await mbLerAvisos();
  // Sem mudança, não notifica: o selo e a aba não reconstroem a cada sincronização.
  if (jsonEncode(novos) != jsonEncode(meuBancoAvisos.value)) meuBancoAvisos.value = novos;
}
