import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:budget/struct/atualizador.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('extrai build e versão da tag', () {
    expect(atualizadorBuildDaTag('v5.4.3+417'), 417);
    expect(atualizadorVersaoDaTag('v5.4.3+417'), '5.4.3');
    expect(atualizadorBuildDaTag('v5.4.3'), isNull);
    expect(atualizadorBuildDaTag('lixo'), isNull);
  });

  test('compara só o buildNumber', () {
    expect(atualizadorTagEhMaisNova('v5.4.3+417', 416), isTrue);
    expect(atualizadorTagEhMaisNova('v5.4.3+417', 417), isFalse);
    expect(atualizadorTagEhMaisNova('v5.4.3+9', 417), isFalse);
    expect(atualizadorTagEhMaisNova('v5.4.3+1000', 999), isTrue);
    expect(atualizadorTagEhMaisNova('invalida', 1), isFalse);
  });

  test('só aceita APK das Releases do repositório via https', () {
    const base =
        'https://github.com/renanrmsantos14/meu-cashew/releases/download/';
    expect(atualizadorUrlConfiavel('${base}v5.4.3+417/app.apk'), isTrue);
    expect(
        atualizadorUrlConfiavel(
            'http://github.com/renanrmsantos14/meu-cashew/releases/download/v1/a.apk'),
        isFalse);
    expect(
        atualizadorUrlConfiavel('https://github.com.evil.com/x.apk'), isFalse);
    expect(
        atualizadorUrlConfiavel(
            'https://github.com/outro/meu-cashew/releases/download/v1/a.apk'),
        isFalse);
    expect(atualizadorUrlConfiavel('${base}../../../evil/a.apk'), isFalse);
  });

  test('aceita o nome novo do repositório (renancash) e o antigo', () {
    expect(
        atualizadorUrlConfiavel(
            'https://github.com/renanrmsantos14/renancash/releases/download/v5.4.17+431/renancash-5.4.17+431.apk'),
        isTrue);
    expect(
        atualizadorUrlConfiavel(
            'https://github.com/renanrmsantos14/renancash/releases/download/../../outro/a.apk'),
        isFalse);
    expect(
        atualizadorUrlConfiavel(
            'https://github.com/outro/renancash/releases/download/v1/a.apk'),
        isFalse);
  });

  test('versão instalada ilegível (build 0) nunca é atualização', () {
    expect(atualizadorTagEhMaisNova('v5.4.3+417', 0), isFalse);
    expect(atualizadorTagEhMaisNova('v5.4.3+417', -1), isFalse);
  });

  group('Release', () {
    const base =
        'https://github.com/renanrmsantos14/renancash/releases/download/v5.4.46+460/';
    Map<String, dynamic> release({bool comHash = true, String tag = 'v5.4.46+460'}) =>
        {
          'tag_name': tag,
          'assets': [
            {
              'name': 'renancash-5.4.46+460.apk',
              'browser_download_url': '${base}renancash-5.4.46+460.apk',
              'size': 1000
            },
            if (comHash)
              {
                'name': 'renancash-5.4.46+460.apk.sha256',
                'browser_download_url': '${base}renancash-5.4.46+460.apk.sha256',
                'size': 90
              },
          ],
        };

    test('com APK e hash → atualização com as duas URLs', () {
      final a = atualizadorInterpretarRelease(release(), 459)!;
      expect(a.urlApk, '${base}renancash-5.4.46+460.apk');
      expect(a.urlSha256, '${base}renancash-5.4.46+460.apk.sha256');
      expect(a.tamanhoApk, 1000);
    });

    test('sem hash → recusa e pede atualização manual', () {
      expect(
          () => atualizadorInterpretarRelease(release(comHash: false), 459),
          throwsA(isA<AtualizadorException>().having(
              (e) => e.mensagem, 'mensagem', contains('manualmente'))));
    });

    test('build instalado 0 → não oferece, nem Release nova nem antiga', () {
      for (final tag in ['v5.4.46+460', 'v1.0.0+1']) {
        expect(
            () => atualizadorInterpretarRelease(release(tag: tag), 0),
            throwsA(isA<AtualizadorException>()));
      }
    });

    test('mesma versão ou mais antiga → null (sem downgrade)', () {
      expect(atualizadorInterpretarRelease(release(), 460), isNull);
      expect(atualizadorInterpretarRelease(release(), 500), isNull);
    });
  });

  group('download verificado', () {
    const base =
        'https://github.com/renanrmsantos14/renancash/releases/download/v5.4.46+460/';
    final apk = utf8.encode('conteudo-do-apk-' * 50);
    final hashCerto = sha256.convert(apk).toString();
    late Directory pasta;

    setUp(() => pasta = Directory.systemTemp.createTempSync('atualizador_'));
    tearDown(() => pasta.deleteSync(recursive: true));

    AtualizacaoDisponivel nova({int? tamanho}) => AtualizacaoDisponivel(
          versao: '5.4.46',
          build: 460,
          urlApk: '${base}a.apk',
          tamanhoApk: tamanho ?? apk.length,
          urlSha256: '${base}a.apk.sha256',
        );

    // Cliente falso: `hash` null → 404 no .sha256; `stream` troca o corpo do APK.
    http.Client cliente({String? hash, Stream<List<int>>? stream}) =>
        MockClient.streaming((req, _) async {
          if (req.url.path.endsWith('.sha256')) {
            return hash == null
                ? http.StreamedResponse(const Stream.empty(), 404)
                : http.StreamedResponse(
                    Stream.value(utf8.encode(hash)), 200);
          }
          return http.StreamedResponse(
              stream ?? Stream.value(apk), 200);
        });

    File arquivoBaixado() => File('${pasta.path}/renancash-5.4.46.apk');

    test('hash certo → arquivo pronto para instalar', () async {
      final f = await atualizadorBaixarVerificado(nova(),
          cliente: cliente(hash: '$hashCerto  a.apk\n'), pasta: pasta);
      expect(f.path, arquivoBaixado().path);
      expect(f.readAsBytesSync(), apk);
    });

    test('hash errado → apaga o arquivo e mostra erro', () async {
      await expectLater(
          atualizadorBaixarVerificado(nova(),
              cliente: cliente(hash: '${'0' * 64}  a.apk'), pasta: pasta),
          throwsA(isA<AtualizadorException>()
              .having((e) => e.mensagem, 'mensagem', contains('SHA-256'))));
      expect(arquivoBaixado().existsSync(), isFalse);
    });

    test('hash ausente (404) ou ilegível → recusa sem deixar arquivo', () async {
      for (final c in [cliente(), cliente(hash: 'não é um hash')]) {
        await expectLater(
            atualizadorBaixarVerificado(nova(), cliente: c, pasta: pasta),
            throwsA(isA<AtualizadorException>()));
        expect(arquivoBaixado().existsSync(), isFalse);
      }
    });

    test('tamanho diferente do anunciado → apaga e erro', () async {
      await expectLater(
          atualizadorBaixarVerificado(nova(tamanho: apk.length + 1),
              cliente: cliente(hash: hashCerto), pasta: pasta),
          throwsA(isA<AtualizadorException>()));
      expect(arquivoBaixado().existsSync(), isFalse);
    });

    test('stream que para → erro por timeout e nada fica preso', () async {
      final parado = StreamController<List<int>>()..add(apk.sublist(0, 10));
      addTearDown(() {
        parado.close();
      });
      final progressos = <double?>[];
      await expectLater(
          atualizadorBaixarVerificado(nova(),
              cliente: cliente(hash: hashCerto, stream: parado.stream),
              pasta: pasta,
              aoProgredir: progressos.add,
              inatividade: const Duration(milliseconds: 200)),
          throwsA(isA<AtualizadorException>()
              .having((e) => e.mensagem, 'mensagem', contains('parou'))));
      expect(progressos, isNotEmpty); // chegou a baixar algo antes de parar
      expect(arquivoBaixado().existsSync(), isFalse);
    });

    test('URL fora das Releases do repositório → nem tenta baixar', () async {
      final ruim = AtualizacaoDisponivel(
          versao: '5.4.46',
          build: 460,
          urlApk: 'https://evil.example/a.apk',
          tamanhoApk: 10,
          urlSha256: '${base}a.apk.sha256');
      await expectLater(
          atualizadorBaixarVerificado(ruim,
              cliente: cliente(hash: hashCerto), pasta: pasta),
          throwsA(isA<AtualizadorException>()));
    });
  });
}
