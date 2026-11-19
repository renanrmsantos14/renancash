import 'dart:io';
import 'dart:ui' as ui;

import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:budget/widgets/editorial/espelhoEnviar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget filho) => MaterialApp(
      theme: ThemeData(extensions: const [EditorialCores.claro]),
      home: Scaffold(body: filho),
    );

void main() {
  testWidgets('item abre a confirmação e só envia depois de confirmar; mostra o resultado', (t) async {
    var chamadas = 0;
    await t.pumpWidget(_app(EspelhoEnviarItem(enviar: () async {
      chamadas++;
      return 'O servidor respondeu (HTTP 500): quebrou.';
    })));
    expect(find.text('Enviar dados para a nuvem'), findsOneWidget);
    expect(find.text('Este celular vira a fonte oficial'), findsOneWidget);

    await t.tap(find.text('Enviar dados para a nuvem'));
    await t.pumpAndSettle();
    expect(find.text(EspelhoEnviarItem.explicacao), findsOneWidget);
    await t.tap(find.text('Cancelar'));
    await t.pumpAndSettle();
    expect(chamadas, 0);

    await t.tap(find.text('Enviar dados para a nuvem'));
    await t.pumpAndSettle();
    await t.tap(find.text('Enviar e virar fonte oficial'));
    await t.pumpAndSettle();
    expect(chamadas, 1);
    expect(find.text('O servidor respondeu (HTTP 500): quebrou.'), findsOneWidget);
  });

  testWidgets('linha de diagnóstico mostra fase e motivo', (t) async {
    mbFaseEspelho.value = MbFaseEspelho.desconhecida;
    mbDiagnosticoEspelho.value = 'aparelho não pareado';
    await t.pumpWidget(_app(const EspelhoDiagnostico()));
    expect(find.text('Espelho: desconhecida · aparelho não pareado'), findsOneWidget);
    mbDiagnosticoEspelho.value = 'HTTP 401: token inválido';
    await t.pump();
    expect(find.text('Espelho: desconhecida · HTTP 401: token inválido'), findsOneWidget);
  });

  // Capturas: só com ESPELHO_PRINTS=<pasta>.
  final pasta = Platform.environment['ESPELHO_PRINTS'];
  testWidgets('capturas', skip: pasta == null, (t) async {
    for (final f in [('Geist', 'Geist-Regular.ttf'), ('Geist', 'Geist-SemiBold.ttf'), ('Roboto', 'Roboto-Regular.ttf')]) {
      final l = FontLoader(f.$1)
        ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/${f.$2}').readAsBytesSync())));
      await l.load();
    }
    final chave = GlobalKey();
    t.view.physicalSize = const Size(780, 1600);
    t.view.devicePixelRatio = 2;
    mbFaseEspelho.value = MbFaseEspelho.desconhecida;
    mbDiagnosticoEspelho.value = 'HTTP 401: token inválido';
    await t.pumpWidget(RepaintBoundary(
        key: chave,
        child: _app(Container(
            color: Colors.white,
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              EspelhoEnviarItem(enviar: () async => 'O servidor respondeu (HTTP 401): token inválido.'),
              const SizedBox(height: 8),
              const EspelhoDiagnostico(),
            ])))));
    Future<void> tirar(String nome) async {
      await t.runAsync(() async {
        final r = chave.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await r.toImage(pixelRatio: 2);
        File('$pasta/$nome.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      });
    }

    await t.pump();
    await tirar('espelho-config-item');
    await t.tap(find.text('Enviar dados para a nuvem'));
    await t.pumpAndSettle();
    await tirar('espelho-config-confirmacao');
    await t.tap(find.text('Enviar e virar fonte oficial'));
    await t.pumpAndSettle();
    await tirar('espelho-config-resultado');
  });
}
