import 'dart:math' show max;

import 'package:budget/struct/settings.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart'
    show ehDesktop, mbRotaEmpilhada;
import 'package:budget/widgets/openBottomSheet.dart' show getIsFullScreen;
import 'package:flutter/material.dart';

const String mbCompilado =
    String.fromEnvironment('MB_COMPILADO', defaultValue: 'dev');

String textoVersao(String versionName, String compilado) =>
    'v$versionName · $compilado';

const double mbAlturaFaixaVersao = 16;

TextStyle _estiloVersao(BuildContext context) => EdTexto.mono(context).copyWith(
      color: cores(context).mu.withOpacity(.7),
      fontSize: 10,
      decoration: TextDecoration.none,
    );

String _versaoAtual() =>
    textoVersao(packageInfoGlobal?.version ?? '?', mbCompilado);

/// No celular a versão fica numa faixa própria entre o conteúdo e a barra inferior (nunca sobre ela).
class FaixaVersao extends StatelessWidget {
  const FaixaVersao({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ExcludeSemantics(
          child: Container(
            height: mbAlturaFaixaVersao,
            color: cores(context).bg,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 10),
            child: Text(_versaoAtual(),
                textDirection: TextDirection.ltr,
                style: _estiloVersao(context)),
          ),
        ),
      );
}

class VersaoCanto extends StatelessWidget {
  const VersaoCanto({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Desktop (lateral) e celular com barra inferior mostram a versão no próprio chrome.
    final desktop = ehDesktop(context);
    final noChrome = desktop || !getIsFullScreen(context);
    return ValueListenableBuilder<bool>(
      // Com página empilhada o chrome fica coberto e a versão volta.
      valueListenable: mbRotaEmpilhada,
      child: child,
      builder: (context, empilhada, child) {
        final mostrar = !noChrome || empilhada;
        // Fora do desktop a versão ganha faixa própria embaixo, que encolhe o app: sobre a
        // página ela cobria a última linha. No desktop o canto fica sobre a margem da página.
        final faixa = mostrar && !desktop;
        final mq = MediaQuery.of(context);
        return Stack(
          textDirection: TextDirection.ltr,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: MediaQuery(
                    // A faixa já ocupa a borda de baixo (e o teclado sobe a partir dela).
                    data: faixa
                        ? mq.copyWith(
                            padding: mq.padding.copyWith(bottom: 0),
                            viewPadding: mq.viewPadding.copyWith(bottom: 0),
                            viewInsets: mq.viewInsets.copyWith(
                                bottom: max(
                                    0.0,
                                    mq.viewInsets.bottom -
                                        mbAlturaFaixaVersao -
                                        mq.padding.bottom)),
                          )
                        : mq,
                    child: child!,
                  ),
                ),
                if (faixa)
                  ColoredBox(
                    color: cores(context).bg,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: mq.padding.bottom),
                      child: const FaixaVersao(),
                    ),
                  ),
              ],
            ),
            if (mostrar && desktop)
              Positioned(
                // À esquerda: o botão de salvar das páginas fica no canto direito de baixo.
                bottom: mq.padding.bottom + 4,
                left: 10,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: Text(
                      _versaoAtual(),
                      textDirection: TextDirection.ltr,
                      style: _estiloVersao(context),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
