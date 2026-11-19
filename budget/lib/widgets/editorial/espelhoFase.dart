import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/agendador.dart' show mbEspelhoConfirmarSemeio;
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:flutter/material.dart';

/// Cobre o app enquanto o espelho completo não está pronto neste aparelho: a web espera o celular, o Android pede
/// a confirmação do semeio, e os dois mostram o andamento. Pronto, indisponível ou ainda sem resposta: não aparece.
class EspelhoFase extends StatefulWidget {
  const EspelhoFase({super.key, required this.child});

  final Widget child;

  @override
  State<EspelhoFase> createState() => _EspelhoFaseState();
}

class _EspelhoFaseState extends State<EspelhoFase> {
  // "Agora não" some com o cartão até o próximo boot; o semeio só começa com a confirmação.
  bool _adiado = false;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<MbFaseEspelho>(
        valueListenable: mbFaseEspelho,
        child: widget.child,
        builder: (context, fase, child) {
          final cobrir = switch (fase) {
            MbFaseEspelho.confirmar => !_adiado,
            MbFaseEspelho.aguardando ||
            MbFaseEspelho.semeando ||
            MbFaseEspelho.trocando =>
              true,
            _ => false,
          };
          return Stack(
            textDirection: TextDirection.ltr,
            children: [
              Positioned.fill(child: child!),
              if (cobrir)
                Positioned.fill(
                  child: Material(
                    color: cores(context).bg,
                    child: SafeArea(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: _conteudo(context, fase),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );

  Widget _conteudo(BuildContext context, MbFaseEspelho fase) {
    switch (fase) {
      case MbFaseEspelho.confirmar:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Este celular vira a fonte oficial', style: EdTexto.h1(context)),
            const SizedBox(height: 12),
            Text(
                'Os dados daqui serão enviados para a nuvem uma única vez. Depois, a web e os outros aparelhos '
                'passam a usar esses dados e só sincronizam pelo espelho. Não use o app até terminar.',
                style: EdTexto.corpo(context)),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: mbEspelhoConfirmarSemeio,
              child: const Text('Enviar e virar fonte oficial'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _adiado = true),
              child: const Text('Agora não'),
            ),
          ],
        );
      case MbFaseEspelho.aguardando:
        return _espera(context, 'Aguardando o celular enviar os dados',
            'Abra o RenanCash no celular e confirme o envio. Esta tela atualiza sozinha.');
      case MbFaseEspelho.semeando:
        return _espera(context, 'Enviando os dados do celular', null);
      default:
        return _espera(context, 'Atualizando com os dados da nuvem', null);
    }
  }

  Widget _espera(BuildContext context, String titulo, String? detalhe) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(titulo, style: EdTexto.h1(context)),
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          if (detalhe != null) Text(detalhe, style: EdTexto.corpo(context)),
          ValueListenableBuilder<String>(
            valueListenable: mbProgressoEspelho,
            builder: (context, texto, _) =>
                texto.isEmpty ? const SizedBox.shrink() : Text(texto, style: EdTexto.rotulo(context)),
          ),
        ],
      );
}
