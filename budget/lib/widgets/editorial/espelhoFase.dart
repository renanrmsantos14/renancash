import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/agendador.dart' show mbEspelhoAdiar, mbEspelhoConfirmarSemeio;
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:flutter/material.dart';

/// O Android pede a confirmação do semeio ou da troca e mostra o andamento (e o erro, com "Tentar de novo" e
/// "Agora não") cobrindo o app; a web, enquanto espera o celular semear, só mostra um banner que não bloqueia nada
/// (o sync antigo segue valendo). Pronto, indisponível ou ainda sem resposta: não aparece.
class EspelhoFase extends StatelessWidget {
  const EspelhoFase({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<MbFaseEspelho>(
        valueListenable: mbFaseEspelho,
        child: child,
        builder: (context, fase, child) {
          final cobrir = switch (fase) {
            MbFaseEspelho.confirmar ||
            MbFaseEspelho.confirmarTroca ||
            MbFaseEspelho.semeando ||
            MbFaseEspelho.trocando ||
            MbFaseEspelho.erro =>
              true,
            _ => false,
          };
          return Stack(
            textDirection: TextDirection.ltr,
            children: [
              Positioned.fill(child: child!),
              if (fase == MbFaseEspelho.aguardando) _banner(context),
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

  Widget _banner(BuildContext context) => Positioned(
        left: 12,
        right: 12,
        bottom: 12,
        // Só informa: toques passam para o app embaixo.
        child: IgnorePointer(
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Material(
                  color: cores(context).cartao,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Aguardando o celular enviar os dados', style: EdTexto.h2(context)),
                        const SizedBox(height: 4),
                        Text('Abra o RenanCash no celular e confirme o envio. Até lá, o app segue como está.',
                            style: EdTexto.corpo(context)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _conteudo(BuildContext context, MbFaseEspelho fase) {
    switch (fase) {
      case MbFaseEspelho.confirmar:
        return _cartao(
          context,
          'Este celular vira a fonte oficial',
          'Os dados daqui serão enviados para a nuvem uma única vez. Depois, a web e os outros aparelhos '
              'passam a usar esses dados e só sincronizam pelo espelho. Não use o app até terminar.',
          'Enviar e virar fonte oficial',
        );
      case MbFaseEspelho.confirmarTroca:
        return ValueListenableBuilder<int>(
          valueListenable: mbPendentesAntesDaTroca,
          builder: (context, n, _) => _cartao(
            context,
            'Trocar pelos dados da nuvem',
            'Outro aparelho já virou a fonte oficial. Os dados deste celular serão apagados e baixados da nuvem; '
                'o que só existe aqui e não foi enviado será perdido.'
                '${n > 0 ? ' Há $n alteração(ões) do Meu Banco ainda não enviada(s).' : ''} A aparência fica como está.',
            'Apagar e baixar da nuvem',
          ),
        );
      case MbFaseEspelho.erro:
        return ValueListenableBuilder<String>(
          valueListenable: mbErroEspelho,
          builder: (context, erro, _) => _cartao(
            context,
            'Não deu para concluir',
            erro.isEmpty ? 'O envio parou no meio. Os dados já enviados não se perdem.' : erro,
            'Tentar de novo',
          ),
        );
      case MbFaseEspelho.semeando:
        return _espera(context, 'Enviando os dados do celular');
      default:
        return _espera(context, 'Atualizando com os dados da nuvem');
    }
  }

  Widget _cartao(BuildContext context, String titulo, String texto, String acao) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(titulo, style: EdTexto.h1(context)),
          const SizedBox(height: 12),
          Text(texto, style: EdTexto.corpo(context)),
          const SizedBox(height: 24),
          FilledButton(onPressed: mbEspelhoConfirmarSemeio, child: Text(acao)),
          const SizedBox(height: 8),
          TextButton(onPressed: mbEspelhoAdiar, child: const Text('Agora não')),
        ],
      );

  Widget _espera(BuildContext context, String titulo) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(titulo, style: EdTexto.h1(context)),
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          ValueListenableBuilder<String>(
            valueListenable: mbProgressoEspelho,
            builder: (context, texto, _) =>
                texto.isEmpty ? const SizedBox.shrink() : Text(texto, style: EdTexto.rotulo(context)),
          ),
        ],
      );
}
