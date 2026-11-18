import 'dart:convert';

import 'package:budget/struct/mbSync/armazem.dart';

// O que o Pluggy conta de cada transação além do básico e que o app só mostra (não vira coluna no Drift):
// quem recebeu ou pagou (paymentData), o meio (Pix, TED...) e a fatura em que a compra do cartão cai (billForecastDate).
// Fica em mb_estado, por id da transação do Pluggy; o pull incremental mescla e o completo substitui.

const String chaveExtrasTransacao = 'extras_transacoes';

typedef MbExtraTransacao = ({String? contraparte, String? metodo, String? faturaMes});

Map<String, Map<String, String>> mbExtrasDoPull(List transacoes) => {
      for (final t in transacoes)
        if (t is Map && t['id'] != null)
          if (_extra(t) case final e when e.isNotEmpty) t['id'].toString(): e
    };

Map<String, String> _extra(Map t) => {
      for (final (campo, chave) in const [('contraparte', 'c'), ('metodo', 'm'), ('bill_month', 'f')])
        if (t[campo] is String && (t[campo] as String).trim().isNotEmpty) chave: (t[campo] as String).trim()
    };

/// Junta os extras novos aos guardados. Transação que voltou sem nenhum extra perde os antigos.
Map<String, Map<String, String>> mbMesclarExtras(
    Map<String, Map<String, String>> antigos, List transacoes, {required bool completo}) {
  final out = completo ? <String, Map<String, String>>{} : {...antigos};
  for (final t in transacoes) {
    if (t is Map && t['id'] != null) out.remove(t['id'].toString());
  }
  out.addAll(mbExtrasDoPull(transacoes));
  return out;
}

Map<String, Map<String, String>> mbExtrasDeTexto(String? texto) {
  if (texto == null) return {};
  try {
    final j = jsonDecode(texto);
    if (j is! Map) return {};
    return {
      for (final e in j.entries)
        if (e.value is Map) '${e.key}': (e.value as Map).map((k, v) => MapEntry('$k', '$v'))
    };
  } catch (_) {
    return {};
  }
}

MbExtraTransacao? mbExtraDe(Map<String, Map<String, String>> extras, String idPluggy) {
  final e = extras[idPluggy];
  if (e == null) return null;
  return (contraparte: e['c'], metodo: e['m'], faturaMes: e['f']);
}

Future<MbExtraTransacao?> mbLerExtraTransacao(String idPluggy) async =>
    mbExtraDe(mbExtrasDeTexto(await mbLerEstado(chaveExtrasTransacao)), idPluggy);

const _meses = [
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
  'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'
];

/// "2026-12" → "Dezembro de 2026".
String? mbRotuloFaturaMes(String? aaaaMm) {
  final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(aaaaMm ?? '');
  final mes = m == null ? null : int.parse(m.group(2)!);
  if (mes == null || mes < 1 || mes > 12) return null;
  final nome = _meses[mes - 1];
  return '${nome[0].toUpperCase()}${nome.substring(1)} de ${m!.group(1)}';
}

/// "Pix para Maria Souza" (saída) ou "Pix de Maria Souza" (entrada). Null sem contraparte.
String? mbRotuloContraparte(MbExtraTransacao? e, {required bool receita}) {
  final nome = e?.contraparte;
  if (nome == null) return null;
  const meios = {'PIX': 'Pix', 'TED': 'TED', 'DOC': 'DOC', 'BOLETO': 'Boleto', 'TEF': 'Transferência'};
  final meio = meios[e?.metodo?.toUpperCase()];
  return '${meio ?? (receita ? 'Recebido' : 'Enviado')} ${receita ? 'de' : 'para'} $nome';
}
