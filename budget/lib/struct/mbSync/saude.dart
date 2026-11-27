// "Saúde": último resultado do check diário do Worker (Pluggy, IA, espelho e cron) e o aviso ao abrir o app.
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:flutter/foundation.dart';

enum MbSaudeStatus { ok, atencao, erro, desconhecido }

MbSaudeStatus _status(Object? v) => switch (v) {
      'ok' => MbSaudeStatus.ok,
      'atencao' => MbSaudeStatus.atencao,
      'erro' => MbSaudeStatus.erro,
      _ => MbSaudeStatus.desconhecido,
    };

String? _txt(Object? v) => v is String && v.isNotEmpty ? v : null;

class MbSaudeDetalhe {
  final String nome, texto;
  final MbSaudeStatus status;
  const MbSaudeDetalhe(this.nome, this.status, this.texto);
}

class MbSaudeItem {
  final String id, nome, resumo;
  final MbSaudeStatus status;
  final String? acao; // o que fazer; só vem quando há problema
  final List<MbSaudeDetalhe> detalhes;
  const MbSaudeItem(this.id, this.nome, this.status, this.resumo, this.acao, this.detalhes);

  static MbSaudeItem? tentar(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    return MbSaudeItem(
      j['id'] as String,
      _txt(j['nome']) ?? '${j['id']}',
      _status(j['status']),
      _txt(j['resumo']) ?? '',
      _txt(j['acao']),
      [
        if (j['detalhes'] is List)
          for (final d in j['detalhes'] as List)
            if (d is Map) MbSaudeDetalhe(_txt(d['nome']) ?? '', _status(d['status']), _txt(d['texto']) ?? '')
      ],
    );
  }
}

class MbSaude {
  final MbSaudeStatus status;
  final DateTime? verificadoEm;
  final bool atrasado; // o check diário não rodou nas últimas 26 h
  final List<MbSaudeItem> itens;
  const MbSaude(this.status, this.verificadoEm, this.atrasado, this.itens);

  /// Nunca rodou (Worker novo): não há o que mostrar além de "ainda não verificou".
  bool get semResultado => verificadoEm == null;

  bool get comProblema => atrasado || status == MbSaudeStatus.atencao || status == MbSaudeStatus.erro;

  static MbSaude deJson(Map<String, dynamic> j) => MbSaude(
        _status(j['status']),
        DateTime.tryParse('${j['verificado_em'] ?? ''}')?.toLocal(),
        j['atrasado'] == true,
        [
          if (j['itens'] is List)
            for (final i in j['itens'] as List)
              if (MbSaudeItem.tentar(i) case final item?) item
        ],
      );
}

/// Aviso da Início: só existe quando há problema (ou o check atrasou). Atualizado ao abrir e ao puxar a tela.
final ValueNotifier<MbSaude?> meuBancoSaudeAviso = ValueNotifier(null);

/// Texto curto do aviso: o problema mais grave primeiro.
String mbSaudeResumoAviso(MbSaude s) {
  if (s.atrasado && s.status == MbSaudeStatus.ok) return 'O check diário atrasou';
  final piores = s.itens.where((i) => i.status == s.status).toList();
  if (piores.isEmpty) return s.atrasado ? 'O check diário atrasou' : 'Verifique a saúde do app';
  return piores.first.resumo.isEmpty ? piores.first.nome : piores.first.resumo;
}

/// Atualiza o aviso da Início com um resultado já lido (a tela Saúde reaproveita o que carregou).
void mbAplicarSaude(MbSaude s) {
  final aviso = s.comProblema && !s.semResultado ? s : null;
  final atual = meuBancoSaudeAviso.value;
  // Sem mudança, não notifica: a Início não reconstrói à toa.
  if (aviso?.verificadoEm != atual?.verificadoEm || aviso?.atrasado != atual?.atrasado || (aviso == null) != (atual == null)) {
    meuBancoSaudeAviso.value = aviso;
  }
}

/// Lê a saúde no Worker e atualiza o aviso da Início. Nunca lança: offline ou Worker antigo (sem a rota) não avisam nada.
Future<MbSaude?> mbChecarSaude({MbCliente? clienteParaTeste}) async {
  try {
    final cliente = clienteParaTeste ?? await mbClienteConfigurado();
    if (cliente == null) return null;
    final s = MbSaude.deJson(await cliente.saude());
    mbAplicarSaude(s);
    return s;
  } catch (e) {
    if (kDebugMode) debugPrint('Meu Banco: não foi possível ler a saúde: $e');
    return null;
  }
}
