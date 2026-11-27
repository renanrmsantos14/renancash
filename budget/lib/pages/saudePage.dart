import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show haQuanto;
import 'package:budget/struct/mbSync/saude.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

/// "Saúde": o último resultado do check diário do Meu Banco (bancos, IA, espelho e cron), item por item.
/// Só lê o que o Worker já verificou; "Verificar agora" roda o check de novo.
class SaudePage extends StatefulWidget {
  const SaudePage({super.key, this.clienteParaTeste, this.agoraParaTeste});

  final MbCliente? clienteParaTeste;
  final DateTime? agoraParaTeste;

  @override
  State<SaudePage> createState() => _SaudePageState();
}

class _SaudePageState extends State<SaudePage> {
  MbSaude? _saude;
  String? _erro;
  bool _offline = false;
  bool _verificando = false;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<MbCliente> _cliente() async {
    final c = widget.clienteParaTeste ?? await mbClienteConfigurado();
    if (c == null) throw MbErroHttp(401, 'Pareie o aparelho com o Meu Banco para ver a saúde.');
    return c;
  }

  Future<void> _carregar({bool verificar = false}) async {
    setState(() {
      if (verificar) {
        _verificando = true;
      } else {
        _saude = null;
      }
      _erro = null;
      _offline = false;
    });
    try {
      final c = await _cliente();
      final s = MbSaude.deJson(verificar ? await c.saudeVerificar() : await c.saude());
      if (!mounted) return;
      setState(() => _saude = s);
      mbAplicarSaude(s); // a Início acompanha: tudo certo tira o aviso, problema acende
    } on MbErroHttp catch (e) {
      if (mounted) setState(() => _erro = e.mensagem);
    } catch (e) {
      if (!mounted) return;
      if (mbErroDeRede(e) != null) {
        setState(() => _offline = true);
      } else {
        setState(() => _erro = 'Não foi possível carregar agora.');
      }
    } finally {
      if (mounted) setState(() => _verificando = false);
    }
  }

  Color _cor(MbSaudeStatus s, EditorialCores e) => switch (s) {
        MbSaudeStatus.ok => e.pos,
        MbSaudeStatus.atencao => e.warntx,
        MbSaudeStatus.erro => e.warn,
        MbSaudeStatus.desconhecido => e.mu,
      };

  IconData _icone(MbSaudeStatus s) => switch (s) {
        MbSaudeStatus.ok => Icons.check_circle_rounded,
        MbSaudeStatus.atencao => Icons.error_outline_rounded,
        MbSaudeStatus.erro => Icons.cancel_rounded,
        MbSaudeStatus.desconhecido => Icons.help_outline_rounded,
      };

  String _rotulo(MbSaudeStatus s) => switch (s) {
        MbSaudeStatus.ok => 'Tudo certo',
        MbSaudeStatus.atencao => 'Atenção',
        MbSaudeStatus.erro => 'Com problema',
        MbSaudeStatus.desconhecido => 'Sem verificação',
      };

  Widget _mensagem(String texto, {String? acao, IconData icone = Icons.favorite_border_rounded}) {
    final e = cores(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 0),
      child: Column(children: [
        Icon(icone, size: 32, color: e.mu),
        const SizedBox(height: 12),
        Text(texto, textAlign: TextAlign.center, style: EdTexto.corpo(context).copyWith(color: e.mu)),
        if (acao != null) ...[
          const SizedBox(height: 16),
          OutlinedButton(onPressed: _carregar, child: Text(acao)),
        ],
      ]),
    );
  }

  Widget _resumo(MbSaude s) {
    final e = cores(context);
    final cor = _cor(s.status, e);
    final quando = s.verificadoEm;
    final agora = widget.agoraParaTeste ?? DateTime.now();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: CartaoBento(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(_icone(s.status), color: cor, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_rotulo(s.status),
                  style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600, color: cor)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(quando == null ? 'Ainda não houve verificação.' : 'Verificado ${haQuanto(quando, agora)}',
              style: EdTexto.rotulo(context)),
          if (s.atrasado) ...[
            const SizedBox(height: 6),
            Text('O check diário atrasou: confira os Cron Triggers do Worker.',
                style: EdTexto.rotulo(context).copyWith(color: e.warntx)),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _verificando ? null : () => _carregar(verificar: true),
            child: Text(_verificando ? 'Verificando…' : 'Verificar agora'),
          ),
        ]),
      ),
    );
  }

  Widget _cartao(MbSaudeItem i) {
    final e = cores(context);
    final cor = _cor(i.status, e);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Semantics(
        label: '${i.nome}, ${_rotulo(i.status)}. ${i.resumo}',
        excludeSemantics: true,
        child: CartaoBento(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(_icone(i.status), color: cor, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(i.nome, style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600)),
              ),
              Text(_rotulo(i.status), style: EdTexto.rotulo(context).copyWith(color: cor)),
            ]),
            if (i.resumo.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(i.resumo, style: EdTexto.corpo(context)),
            ],
            for (final d in i.detalhes.where((d) => d.status != MbSaudeStatus.ok && d.texto != i.resumo)) ...[
              const SizedBox(height: 4),
              Text(d.texto, style: EdTexto.rotulo(context).copyWith(color: _cor(d.status, e))),
            ],
            if (i.acao != null && i.status != MbSaudeStatus.ok) ...[
              const SizedBox(height: 8),
              Text('O que fazer: ${i.acao}', style: EdTexto.rotulo(context)),
            ],
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _saude;
    return PageFramework(
      dragDownToDismiss: true,
      horizontalPaddingConstrained: true,
      title: 'Saúde',
      listWidgets: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          child: Text(
              'O Meu Banco confere todo dia se bancos, IA, espelho e o próprio check seguem funcionando. Se algo falhar, você recebe um aviso.',
              style: EdTexto.rotulo(context)),
        ),
        if (_offline)
          _mensagem('Sem conexão com o Meu Banco.', acao: 'Tentar de novo', icone: Icons.cloud_off_rounded)
        else if (_erro != null)
          _mensagem(_erro!, acao: 'Tentar de novo', icone: Icons.error_outline_rounded)
        else if (s == null)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _resumo(s),
          for (final i in s.itens) _cartao(i),
          const SizedBox(height: 24),
        ],
      ],
    );
  }
}
