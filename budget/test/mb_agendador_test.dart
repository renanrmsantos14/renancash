import 'dart:async';

import 'package:budget/struct/mbSync/agendador.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late int rodadas;
  late bool pareado;
  late List<bool> resultados; // respostas sucessivas de rodar(); vazio = true
  late Duration duracao;
  late bool emRodada;
  late MbAgendador a;
  late DateTime Function() agora;

  MbAgendador criar() => MbAgendador(
        rodar: () async {
          rodadas++;
          emRodada = true;
          await Future<void>.delayed(duracao);
          emRodada = false;
          return resultados.isEmpty ? true : resultados.removeAt(0);
        },
        pareado: () => pareado,
        emRodada: () => emRodada,
        agora: agora,
      );

  void ao(FakeAsync f, void Function() corpo) {
    f.run((_) {
      a = criar();
      a.iniciar();
      corpo();
    });
  }

  setUp(() {
    rodadas = 0;
    pareado = true;
    resultados = [];
    duracao = const Duration(milliseconds: 100);
    emRodada = false;
  });

  test('várias edições em sequência viram uma só rodada depois de 2 s', () {
    fakeAsync((f) {
      agora = () => f.getClock(DateTime(2026)).now();
      ao(f, () {
        a.aoEditar();
        f.elapse(const Duration(milliseconds: 1500));
        a.aoEditar(); // reinicia a espera
        f.elapse(const Duration(milliseconds: 1500));
        expect(rodadas, 0);
        f.elapse(const Duration(milliseconds: 600));
        expect(rodadas, 1);
        f.elapse(const Duration(seconds: 1));
        expect(rodadas, 1);
        a.parar();
      });
    });
  });

  test('não pareado: nada roda (edição, volta ao app, periódico)', () {
    fakeAsync((f) {
      agora = () => f.getClock(DateTime(2026)).now();
      pareado = false;
      ao(f, () {
        a.aoEditar();
        a.voltouAoApp();
        f.elapse(const Duration(minutes: 3));
        expect(rodadas, 0);
        a.parar();
      });
    });
  });

  test('volta ao app durante uma rodada pede outra ao terminar (não descarta, não roda em paralelo)', () {
    fakeAsync((f) {
      agora = () => f.getClock(DateTime(2026)).now();
      duracao = const Duration(seconds: 1);
      ao(f, () {
        a.voltouAoApp();
        f.elapse(const Duration(milliseconds: 200));
        a.voltouAoApp();
        a.voltouAoApp();
        expect(rodadas, 1);
        f.elapse(const Duration(seconds: 1));
        expect(rodadas, 2); // as duas chamadas viraram uma rodada extra
        f.elapse(const Duration(seconds: 5));
        expect(rodadas, 2);
        a.parar();
      });
    });
  });

  test('escrita feita durante a rodada e logo depois dela não agenda nada', () {
    fakeAsync((f) {
      agora = () => f.getClock(DateTime(2026)).now();
      ao(f, () {
        a.voltouAoApp();
        f.elapse(const Duration(milliseconds: 50));
        a.aoEditar(); // durante a rodada (aplicar do pull)
        f.elapse(const Duration(milliseconds: 100)); // termina
        a.aoEditar(); // evento atrasado do stream, dentro da folga
        f.elapse(const Duration(seconds: 5));
        expect(rodadas, 1);
        a.aoEditar(); // edição real do usuário, fora da folga
        f.elapse(const Duration(seconds: 3));
        expect(rodadas, 2);
        a.parar();
      });
    });
  });

  test('falha: tenta de novo em 5 s, 15 s e depois a cada 60 s; sucesso zera', () {
    fakeAsync((f) {
      agora = () => f.getClock(DateTime(2026)).now();
      resultados = [false, false, false, false, true];
      duracao = Duration.zero;
      ao(f, () {
        a.voltouAoApp();
        f.flushMicrotasks();
        expect(rodadas, 1);
        f.elapse(const Duration(seconds: 4));
        expect(rodadas, 1);
        f.elapse(const Duration(seconds: 1)); // 5 s
        expect(rodadas, 2);
        f.elapse(const Duration(seconds: 14));
        expect(rodadas, 2);
        f.elapse(const Duration(seconds: 1)); // +15 s
        expect(rodadas, 3);
        f.elapse(const Duration(seconds: 59));
        expect(rodadas, 3);
        f.elapse(const Duration(seconds: 1)); // +60 s
        expect(rodadas, 4);
        f.elapse(const Duration(seconds: 60)); // +60 s de novo (sem crescer)
        expect(rodadas, 5);
        expect(a.falhasSeguidas, 0);
        a.parar();
      });
    });
  });

  test('a cada 60 s em primeiro plano puxa; em segundo plano não', () {
    fakeAsync((f) {
      agora = () => f.getClock(DateTime(2026)).now();
      ao(f, () {
        f.elapse(const Duration(seconds: 61));
        expect(rodadas, 1);
        a.foiParaSegundoPlano();
        f.elapse(const Duration(minutes: 5));
        expect(rodadas, 1);
        a.voltouAoApp();
        f.flushMicrotasks();
        expect(rodadas, 2);
        a.parar();
      });
    });
  });
}
