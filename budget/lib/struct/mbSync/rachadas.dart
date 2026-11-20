import 'package:budget/database/tables.dart' show Transaction;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl;
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/struct/mbSync/revisao.dart' show mbNormalizarRevisao;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

// Conta rachada nas listas: o gasto mostra a minha parte (−38,11) com o total pago riscado (−76,23) e quem dividiu, e os
// Pix de rachar (reembolsos ligados e trocos) ficam só dentro dele. As linhas continuam no banco: categorias, orçamentos e
// o Geral somam as três (o mesmo total do Worker); só as listas escondem os Pix e trocam o valor do gasto pelo líquido.

/// Um Pix de rachar dentro do gasto: reembolso (quem mandou) ou troco (a quem devolvi).
class MbParteRachada {
  final String pk, pessoa;
  final int centavos;
  const MbParteRachada(this.pk, this.pessoa, this.centavos);
}

class MbRachada {
  final List<MbParteRachada> reembolsos, trocos;
  const MbRachada(this.reembolsos, this.trocos);

  /// Minha parte do gasto (centavos, nunca abaixo de zero).
  int liquido(int gasto) => mbMinhaParte(gasto, reembolsos.map((p) => p.centavos), trocos.map((p) => p.centavos)).parte;

  /// Primeiro nome de quem dividiu, sem repetir: "Valentina, Isabel".
  String get pessoas => {for (final p in reembolsos) p.pessoa}.join(', ');

  /// "inclui Pix de Valentina +R$ 50,00 e troco −R$ 11,88": o que a busca mostra quando acha o gasto pela pessoa ou valor.
  String get indicacao {
    final partes = [
      for (final p in reembolsos) 'Pix de ${p.pessoa} +${brl(p.centavos / 100)}',
      for (final p in trocos) 'troco −${brl(p.centavos / 100)}',
    ];
    return partes.isEmpty ? '' : 'inclui ${partes.join(' e ')}';
  }

  /// Texto que a busca compara: pessoas e valores dos Pix e dos trocos (50, 50,00, 11,88).
  String get textoDeBusca => [
        for (final p in [...reembolsos, ...trocos]) ...[mbNormalizarRevisao(p.pessoa), _valores(p.centavos)],
      ].join(' ');
}

/// Maiúsculas sem acento, mantendo números, vírgula e ponto (o normalizador da fila apaga os dígitos).
String _paraBusca(String s) => s
    .trim()
    .split(RegExp(r'\s+'))
    .map((t) => RegExp(r'^[0-9.,]+$').hasMatch(t) ? t : mbNormalizarRevisao(t))
    .join(' ');

String _valores(int centavos) {
  final reais = centavos ~/ 100, resto = centavos % 100;
  final dec = resto.toString().padLeft(2, '0');
  return [
    '$reais,$dec',
    '$reais.$dec',
    if (resto == 0) '$reais',
  ].join(' ');
}

class MbRachadas {
  final Map<String, MbRachada> porGasto; // pk do gasto -> partes
  final Set<String> ocultos; // pks dos Pix (reembolsos e trocos) que as listas escondem
  const MbRachadas([this.porGasto = const {}, this.ocultos = const {}]);

  /// Resumo do conteúdo: o notificador só avisa as listas quando algo mudou de verdade.
  String get _assinatura => [
        for (final e in porGasto.entries)
          '${e.key}:${[for (final p in [...e.value.reembolsos, ...e.value.trocos]) '${p.pk}/${p.pessoa}/${p.centavos}'].join(',')}'
      ].join(';');

  @override
  bool operator ==(Object other) =>
      other is MbRachadas && other._assinatura == _assinatura && setEquals(other.ocultos, ocultos);

  @override
  int get hashCode => Object.hash(_assinatura, ocultos.length);

  /// Gastos rachados que a busca acha pela pessoa (começo do nome) ou pelo valor (exato: 50, 50,00, 11,88) dos Pix de rachar.
  List<String> gastosDaBusca(String busca) {
    final q = _paraBusca(busca);
    if (q.isEmpty || porGasto.isEmpty) return const [];
    final comLetra = RegExp(r'[A-Z]').hasMatch(q);
    return [
      for (final e in porGasto.entries)
        if (e.value.textoDeBusca.split(' ').any((t) => t == q || (comLetra && t.startsWith(q)))) e.key
    ];
  }

  /// Valor do gasto na lista: a minha parte (negativa) quando ele foi rachado; senão o próprio valor.
  double valorNaLista(Transaction t) {
    final r = porGasto[t.transactionPk];
    if (r == null || t.amount >= 0) return t.amount;
    return -r.liquido((t.amount.abs() * 100).round()) / 100;
  }
}

final ValueNotifier<MbRachadas> meuBancoRachadas = ValueNotifier(const MbRachadas());

String _primeiroNome(MbVinculoReembolso v) {
  final nome = v.nome.isNotEmpty ? v.nome : v.pagador;
  final p = nome.split(' ').firstWhere((x) => x.isNotEmpty, orElse: () => '');
  return p.isEmpty ? 'alguém' : p[0] + p.substring(1).toLowerCase();
}

/// Só valem os Pix cujo gasto existe no aparelho (`gastosNoAparelho`): sem o gasto, o Pix continua na lista.
MbRachadas mbCalcularRachadas(
    Iterable<MbVinculoReembolso> vinculos, Iterable<MbTroco> trocos, Set<String> gastosNoAparelho) {
  final reembolsos = <String, List<MbParteRachada>>{};
  final trocosDoGasto = <String, List<MbParteRachada>>{};
  final ocultos = <String>{};
  final gastoDoReembolso = <String, MbVinculoReembolso>{};
  for (final v in vinculos) {
    if (!gastosNoAparelho.contains(v.gastoPk)) continue;
    gastoDoReembolso[v.reembolsoPk] = v;
    (reembolsos[v.gastoPk] ??= []).add(MbParteRachada(v.reembolsoPk, _primeiroNome(v), v.centavos));
    ocultos.add(v.reembolsoPk);
  }
  for (final t in trocos) {
    final v = gastoDoReembolso[t.reembolsoPk];
    if (v == null) continue;
    (trocosDoGasto[v.gastoPk] ??= []).add(MbParteRachada(t.trocoPk, _primeiroNome(v), t.centavos));
    ocultos.add(t.trocoPk);
  }
  return MbRachadas({
    for (final e in reembolsos.entries) e.key: MbRachada(e.value, trocosDoGasto[e.key] ?? const []),
  }, ocultos);
}

/// Relê do banco quais gastos dos vínculos existem e atualiza [meuBancoRachadas]. Não lança.
Future<void> mbAtualizarRachadas(Iterable<MbVinculoReembolso> vinculos, Iterable<MbTroco> trocos) async {
  try {
    final gastos = {for (final v in vinculos) v.gastoPk};
    final existentes = gastos.isEmpty
        ? <String>{}
        : {
            for (final t in await (database.select(database.transactions)
                  ..where((t) => t.transactionPk.isIn(gastos) & t.amount.isSmallerThanValue(0)))
                .get())
              t.transactionPk
          };
    meuBancoRachadas.value = mbCalcularRachadas(vinculos, trocos, existentes);
  } catch (e) {
    if (kDebugMode) debugPrint('Meu Banco: falha ao calcular as contas rachadas: $e');
  }
}
