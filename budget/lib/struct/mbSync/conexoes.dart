import 'dart:convert';

import 'package:budget/struct/mbSync/armazem.dart' show mbLerEstado;
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/meuBancoMapping.dart' show mbPkConta, mbPrefixo;

/// Situação de uma conexão (item do Pluggy) para a tela "Contas conectadas".
enum MbSituacao { emDia, atualizando, reconectar }

class MbContaConexao {
  const MbContaConexao(
      {required this.nome,
      required this.tipo,
      required this.saldo,
      required this.cartao});
  final String nome;
  final String tipo;
  final double? saldo;
  final bool cartao;

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
    );
  }
}

class MbConexao {
  const MbConexao(
      {required this.id,
      required this.banco,
      required this.status,
      required this.precisaReconectar,
      required this.atualizado,
      required this.contas});
  final String id;
  final String banco;
  final String? status;
  final bool precisaReconectar;
  final DateTime? atualizado;
  final List<MbContaConexao> contas;

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
      contas: [for (final c in contas) MbContaConexao.deJson(c)],
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
