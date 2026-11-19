import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/agendador.dart' show mbEspelhoEnviarAgora;
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Linha "Espelho: <fase> · <motivo>" (Configurações > Meu Banco, também na web): mostra por que o espelho está como
/// está, sem precisar adivinhar em produção.
class EspelhoDiagnostico extends StatelessWidget {
  const EspelhoDiagnostico({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([mbFaseEspelho, mbDiagnosticoEspelho]),
        builder: (context, _) => Text(
          'Espelho: ${mbFaseEspelho.value.name} · ${mbDiagnosticoEspelho.value}',
          style: EdTexto.rotulo(context),
        ),
      );
}

/// Item "Enviar dados para a nuvem" (só Android): confirma e faz este celular virar a fonte oficial, mostrando o
/// andamento e, se falhar, o erro com o status HTTP e a mensagem do servidor.
class EspelhoEnviarItem extends StatefulWidget {
  const EspelhoEnviarItem({super.key, this.enviar = mbEspelhoEnviarAgora});

  final Future<String> Function() enviar;

  static const titulo = 'Enviar dados para a nuvem';
  static const subtitulo = 'Este celular vira a fonte oficial';
  static const explicacao = 'Os dados daqui serão enviados para a nuvem uma única vez. Depois, a web e os outros '
      'aparelhos passam a usar esses dados e só sincronizam pelo espelho. Não use o app até terminar.';

  @override
  State<EspelhoEnviarItem> createState() => _EspelhoEnviarItemState();
}

class _EspelhoEnviarItemState extends State<EspelhoEnviarItem> {
  bool _enviando = false;
  String? _resultado;

  Future<void> _tocar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Este celular vira a fonte oficial'),
        content: const Text(EspelhoEnviarItem.explicacao),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Enviar e virar fonte oficial')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _enviando = true;
      _resultado = null;
    });
    String r;
    try {
      r = await widget.enviar();
    } catch (e) {
      r = 'Não deu para concluir: $e';
    }
    if (mounted) {
      setState(() {
        _enviando = false;
        _resultado = r;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([mbFaseEspelho, mbEspelhoPronto]),
      builder: (context, _) =>
          mbFaseEspelho.value == MbFaseEspelho.pronto || mbEspelhoPronto.value ? const SizedBox.shrink() : _corpo(context),
    );
  }

  Widget _corpo(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_upload_rounded),
          title: Text(_enviando ? 'Enviando…' : EspelhoEnviarItem.titulo),
          subtitle: const Text(EspelhoEnviarItem.subtitulo),
          enabled: !_enviando,
          onTap: _enviando ? null : _tocar,
        ),
        if (_enviando)
          ValueListenableBuilder<String>(
            valueListenable: mbProgressoEspelho,
            builder: (context, t, _) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const LinearProgressIndicator(),
                if (t.isNotEmpty) Text(t, style: EdTexto.rotulo(context)),
              ]),
            ),
          ),
        if (_resultado != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_resultado!, style: EdTexto.corpo(context))),
      ],
    );
  }
}
