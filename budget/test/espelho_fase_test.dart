import 'dart:io';
import 'dart:ui' as ui;

import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:budget/widgets/editorial/espelhoFase.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _fonte(String familia, String arquivo) async {
  final l = FontLoader(familia)
    ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/$arquivo').readAsBytesSync())));
  await l.load();
}

Widget _app(Widget filho) => MaterialApp(
      theme: ThemeData(extensions: const [EditorialCores.claro]),
      home: filho,
    );

void main() {
  setUp(() => mbFaseEspelho.value = MbFaseEspelho.desconhecida);

  testWidgets('pronto, indisponível e desconhecida não cobrem o app', (t) async {
    await t.pumpWidget(_app(const EspelhoFase(child: Text('app'))));
    for (final f in [MbFaseEspelho.desconhecida, MbFaseEspelho.indisponivel, MbFaseEspelho.pronto]) {
      mbFaseEspelho.value = f;
      await t.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Este celular vira a fonte oficial'), findsNothing);
    }
  });

  testWidgets('web com semeado:false mostra a espera; Android pede a confirmação e "Agora não" a esconde', (t) async {
    await t.pumpWidget(_app(const EspelhoFase(child: Text('app'))));
    mbFaseEspelho.value = MbFaseEspelho.aguardando;
    await t.pump();
    expect(find.text('Aguardando o celular enviar os dados'), findsOneWidget);
    mbFaseEspelho.value = MbFaseEspelho.confirmar;
    await t.pump();
    expect(find.text('Este celular vira a fonte oficial'), findsOneWidget);
    await t.tap(find.text('Agora não'));
    await t.pump();
    expect(find.text('Este celular vira a fonte oficial'), findsNothing);
  });

  // Captura de tela das telas novas: só com ESPELHO_PRINTS=<pasta> (não roda na suíte comum).
  final pasta = Platform.environment['ESPELHO_PRINTS'];
  testWidgets('capturas', skip: pasta == null, (t) async {
    await _fonte('Geist', 'Geist-Regular.ttf');
    await _fonte('Geist', 'Geist-SemiBold.ttf');
    await _fonte('Roboto', 'Roboto-Regular.ttf');
    final chave = GlobalKey();
    Future<void> tirar(MbFaseEspelho f, String nome, Size tela, {String progresso = ''}) async {
      t.view.physicalSize = tela;
      t.view.devicePixelRatio = 2;
      mbFaseEspelho.value = f;
      mbProgressoEspelho.value = progresso;
      await t.pumpWidget(_app(RepaintBoundary(key: chave, child: const EspelhoFase(child: Text('app')))));
      await t.pump();
      await t.runAsync(() async {
        final r = chave.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await r.toImage(pixelRatio: 2);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$pasta/$nome.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    await tirar(MbFaseEspelho.confirmar, 'espelho-android-confirmacao', const Size(780, 1600));
    await tirar(MbFaseEspelho.semeando, 'espelho-android-enviando', const Size(780, 1600), progresso: 'Enviando 1500 de 4000');
    await tirar(MbFaseEspelho.aguardando, 'espelho-web-aguardando', const Size(1600, 900));
  });
}
