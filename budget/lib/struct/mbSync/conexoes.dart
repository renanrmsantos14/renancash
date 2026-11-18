import 'dart:convert';

import 'package:budget/struct/mbSync/armazem.dart' show mbLerEstado;
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/meuBancoMapping.dart'
    show mbContaIgnorada, mbPkConta, mbPrefixo;

/// Situação de uma conexão (item do Pluggy) para a tela "Contas conectadas".
enum MbSituacao { emDia, atualizando, reconectar }

class MbContaConexao {
  const MbContaConexao(
      {required this.nome,
      required this.tipo,
      required this.saldo,
      required this.cartao,
      required this.foraDoApp});
  final String nome;
  final String tipo;
  final double? saldo;
  final bool cartao;
  /// Corrente e cartão do Santander (mbContaIgnorada): usados por outra pessoa, não entram no app.
  final bool foraDoApp;

  static const _subtipos = {
    'CHECKING_ACCOUNT': 'Conta corrente',
    'SAVINGS_ACCOUNT': 'Poupança',
    'CREDIT_CARD': 'Cartão',
  };

  factory MbContaConexao.deJson(Map<String, dynamic> j) {
    final cartao = j['type'] == 'CREDIT';
    return MbContaConexao(
      nome: '${j['name'] ?? j['bank'] ?? 'Conta'}',
      tipo: _subtipos[j['subtype']] ?? (cartao ? 'Cartão' : 'Conta'),
      saldo: (j['balance'] as num?)?.toDouble(),
      cartao: cartao,
      foraDoApp: mbContaIgnorada(j),
    );
  }
}

/// Empréstimo ou financiamento da conexão (GET /loans do Pluggy, via Worker). Campos que o banco não manda ficam null.
class MbEmprestimo {
  const MbEmprestimo(
      {required this.nome,
      this.saldoDevedor,
      this.parcelasTotal,
      this.pagas,
      this.atrasadas,
      this.taxa,
      this.taxaPeriodo});
  final String nome;
  final double? saldoDevedor, taxa;
  /// 'mes' ou 'ano' (taxPeriodicity); null quando o banco não diz.
  final String? taxaPeriodo;
  final int? parcelasTotal, pagas, atrasadas;

  factory MbEmprestimo.deJson(Map j) {
    int? inteiro(Object? v) => v is num ? v.toInt() : null;
    return MbEmprestimo(
      nome: '${j['nome'] ?? 'Empréstimo'}',
      saldoDevedor: (j['saldo_devedor'] as num?)?.toDouble(),
      parcelasTotal: inteiro(j['parcelas_total']),
      pagas: inteiro(j['pagas']),
      atrasadas: inteiro(j['atrasadas']),
      taxa: (j['taxa_pre'] as num?)?.toDouble(),
      taxaPeriodo: j['taxa_periodo'] as String?,
    );
  }

  /// "10 de 24 parcelas pagas · 2,1% a.m. · 1 atrasada"
  String get detalhe => [
        if (pagas != null && parcelasTotal != null) '$pagas de $parcelasTotal parcelas pagas',
        if (taxa != null)
          '${taxa!.toStringAsFixed(2).replaceAll('.', ',')}%${taxaPeriodo == 'mes' ? ' a.m.' : taxaPeriodo == 'ano' ? ' a.a.' : ' de juros'}',
        if ((atrasadas ?? 0) > 0) atrasadas == 1 ? '1 atrasada' : '$atrasadas atrasadas',
      ].join(' · ');
}

class MbConexao {
  const MbConexao(
      {required this.id,
      required this.banco,
      required this.status,
      required this.precisaReconectar,
      required this.atualizado,
      this.proximoSync,
      this.consentimentoExpira,
      this.emprestimos = const [],
      required this.contas});
  final String id;
  final String banco;
  final String? status;
  final bool precisaReconectar;
  final DateTime? atualizado;
  /// Próxima atualização automática do Pluggy (nextAutoSyncAt) e vencimento do consentimento do Open Finance.
  final DateTime? proximoSync, consentimentoExpira;
  final List<MbContaConexao> contas;
  final List<MbEmprestimo> emprestimos;

  factory MbConexao.deJson(Map<String, dynamic> j) {
    final contas = [
      for (final c in (j['contas'] as List? ?? const []))
        if (c is Map) c.cast<String, dynamic>()
    ];
    return MbConexao(
      id: '${j['id']}',
      banco: mbNomeDaConexao('${j['banco'] ?? 'Banco'}', contas),
      status: j['status'] as String?,
      precisaReconectar: j['precisaReconectar'] == true,
      atualizado: DateTime.tryParse('${j['atualizado']}')?.toLocal(),
      proximoSync: DateTime.tryParse('${j['proximoSync']}')?.toLocal(),
      consentimentoExpira: DateTime.tryParse('${j['consentimentoExpira']}')?.toLocal(),
      emprestimos: [
        for (final e in (j['emprestimos'] as List? ?? const []))
          if (e is Map) MbEmprestimo.deJson(e)
      ],
      // O banco da conexão vale para a regra do Santander quando a conta não traz o seu.
      contas: [
        for (final c in contas) MbContaConexao.deJson({'bank': j['banco'], ...c})
      ],
    );
  }

  // O servidor decide quando pede novo login (mesma regra dos avisos); aqui só vira texto.
  ({MbSituacao situacao, String rotulo}) get situacao => precisaReconectar
      ? (
          situacao: MbSituacao.reconectar,
          rotulo: status == 'WAITING_USER_INPUT'
              ? 'Pede confirmação'
              : 'Senha mudou'
        )
      : switch (status) {
          'UPDATED' => (situacao: MbSituacao.emDia, rotulo: 'Em dia'),
          'OUTDATED' => (
              situacao: MbSituacao.atualizando,
              rotulo: 'Falha temporária'
            ),
          null => (situacao: MbSituacao.atualizando, rotulo: 'Aguardando'),
          _ => (situacao: MbSituacao.atualizando, rotulo: 'Atualizando'),
        };

  String get sigla => mbSigla(banco);

  /// Dias até o consentimento vencer (negativo: já venceu). Null sem a data.
  int? diasParaConsentimento(DateTime agora) => consentimentoExpira == null
      ? null
      : DateTime(consentimentoExpira!.year, consentimentoExpira!.month, consentimentoExpira!.day)
          .difference(DateTime(agora.year, agora.month, agora.day))
          .inDays;

  /// Linhas de rodapé do cartão da conexão: próxima atualização e consentimento (aviso nos últimos 15 dias).
  List<({String texto, bool alerta})> rodape(DateTime agora) {
    String dm(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
    String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final out = <({String texto, bool alerta})>[];
    final p = proximoSync;
    if (p != null && p.isAfter(agora)) {
      final mesmoDia = p.year == agora.year && p.month == agora.month && p.day == agora.day;
      out.add((texto: 'O banco atualiza de novo ${mesmoDia ? 'às ${hm(p)}' : 'em ${dm(p)} às ${hm(p)}'}', alerta: false));
    }
    final n = diasParaConsentimento(agora);
    if (n != null && n <= 15) {
      out.add((
        texto: n < 0
            ? 'A autorização do Open Finance venceu em ${dm(consentimentoExpira!)}. Renove no Meu Pluggy.'
            : 'A autorização do Open Finance vence ${n == 0 ? 'hoje' : n == 1 ? 'amanhã' : 'em $n dias'}. Renove no Meu Pluggy.',
        alerta: true
      ));
    }
    return out;
  }
}

/// Conector agregador (MeuPluggy, do Open Finance) não é banco: o nome sai das
/// contas da conexão ("BANCO INTER ·69-6" → "Banco Inter"). Cartões ficam de fora.
String mbNomeDaConexao(String conector, List<Map<String, dynamic>> contas) {
  if (!conector.toLowerCase().contains('pluggy')) return conector;
  final nomes = <String>{
    for (final c in contas)
      if (c['type'] != 'CREDIT') _nomeDoBanco('${c['bank'] ?? c['name'] ?? ''}')
  }..remove('');
  return nomes.isEmpty ? conector : nomes.join(' · ');
}

String _nomeDoBanco(String s) {
  final n = s
      .replaceFirst(RegExp(r'\s*·\s*[\d-]+$'), '')
      .replaceFirst(RegExp(r'\s*\(brasil\)', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\s+S[./]?A\.?$', caseSensitive: false), '')
      .trim();
  if (n != n.toUpperCase()) return n;
  return n
      .toLowerCase()
      .split(' ')
      .map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1))
      .join(' ');
}

Future<MbCliente> _cliente() async {
  final cliente = await mbClienteConfigurado();
  if (cliente == null)
    throw 'Pareie o app com o Meu Banco para ver as contas conectadas.';
  return cliente;
}

Future<List<MbConexao>> mbCarregarConexoes() async =>
    (await _cliente()).conexoes();

Future<void> mbRemoverConexao(String itemId) async =>
    (await _cliente()).removerConexao(itemId);

/// Tipo ("Conta corrente", "Poupança") de cada carteira do Meu Banco, pelo pk.
/// Vazio fora do Meu Banco (sem a tabela ou sem contas sincronizadas).
Future<Map<String, String>> mbTiposDasCarteiras() async {
  try {
    final contas = jsonDecode(await mbLerEstado('contas') ?? '[]') as List;
    return {
      for (final c in contas)
        if (c is Map)
          mbPkConta('${c['id']}'):
              MbContaConexao.deJson(c.cast<String, dynamic>()).tipo
    };
  } catch (_) {
    return const {};
  }
}

/// Origem de uma carteira para o subtítulo: "Conta corrente · Meu Banco",
/// "Meu Banco" (sem tipo, ex.: Investimentos) ou "Manual".
String mbOrigemCarteira(String walletPk, Map<String, String> tipos) {
  if (!walletPk.startsWith(mbPrefixo)) return 'Manual';
  final tipo = tipos[walletPk];
  return tipo == null ? 'Meu Banco' : '$tipo · Meu Banco';
}

/// Rótulos sem repetição para carteiras de mesmo nome (corrente e poupança do mesmo banco):
/// os repetidos ganham o tipo e, se ainda empatarem (ou sem tipo), a posição.
List<String> mbRotulosCarteiras(List<String> nomes, List<String?> tipos) {
  List<String> desempatar(List<String> base, String Function(int i) sufixo) {
    final contagem = <String, int>{};
    for (final b in base) contagem[b] = (contagem[b] ?? 0) + 1;
    return [
      for (var i = 0; i < base.length; i++)
        contagem[base[i]]! > 1 ? '${base[i]} · ${sufixo(i)}' : base[i]
    ];
  }

  return desempatar(
      desempatar(nomes, (i) => tipos[i] ?? '${i + 1}'), (i) => '${i + 1}');
}

/// [mbRotulosCarteiras] por pk: `nomes` (pk → nome, na ordem da tela) e `tipos` (pk → tipo).
Map<String, String> mbRotulosPorPk(
    Map<String, String> nomes, Map<String, String> tipos) {
  final pks = nomes.keys.toList();
  final rotulos =
      mbRotulosCarteiras([for (final p in pks) nomes[p]!], [for (final p in pks) tipos[p]]);
  return {for (final (i, p) in pks.indexed) p: rotulos[i]};
}
