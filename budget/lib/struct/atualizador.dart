import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

// O prefixo meu-cashew abaixo fica para links antigos (o GitHub redireciona o nome anterior).
const String atualizadorUrlLatest =
    "https://api.github.com/repos/renanrmsantos14/renancash/releases/latest";
// Prefixos aceitos para baixar o APK (o GitHub redireciona para o CDN; o redirect é seguido pelo http).
// Os dois nomes do repositório: depois do rename meu-cashew → renancash a API devolve links com o nome novo.
const List<String> _prefixosDownload = [
  "https://github.com/renanrmsantos14/renancash/releases/download/",
  "https://github.com/renanrmsantos14/meu-cashew/releases/download/",
];
const int _tamanhoMaximoApk = 300 * 1024 * 1024;
const String _chaveOferta = "atualizacaoOfertada";

/// Resultado de procurar atualização. [versao] é a versão da tag (ex. "5.4.3").
///
/// [urlSha256] é o arquivo `<apk>.sha256` publicado na mesma Release (formato do
/// `sha256sum`: "<64 hex>  <nome>"). Sem ele a Release é recusada.
class AtualizacaoDisponivel {
  final String versao;
  final int build;
  final String urlApk;
  final int tamanhoApk;
  final String urlSha256;
  const AtualizacaoDisponivel(
      {required this.versao,
      required this.build,
      required this.urlApk,
      required this.tamanhoApk,
      required this.urlSha256});
}

/// Falha esperada do atualizador, com mensagem em pt-BR pronta para o usuário.
class AtualizadorException implements Exception {
  final String mensagem;
  const AtualizadorException(this.mensagem);
  @override
  String toString() => mensagem;
}

/// Extrai o buildNumber de uma tag `v<versão>+<build>` (ex. v5.4.3+417 -> 417).
/// Retorna null se a tag não tiver o formato esperado.
int? atualizadorBuildDaTag(String tag) {
  final m = RegExp(r'^v?\d+(?:\.\d+)*\+(\d+)$').firstMatch(tag.trim());
  return m == null ? null : int.parse(m.group(1)!);
}

/// Extrai a versão (sem "v" e sem build) de uma tag. Ex.: v5.4.3+417 -> 5.4.3.
String atualizadorVersaoDaTag(String tag) =>
    tag.trim().replaceFirst(RegExp(r'^v'), '').split('+').first;

/// True se a tag tem buildNumber maior que o do app instalado.
/// [buildAtual] <= 0 (versão instalada ilegível) nunca conta como atualização.
bool atualizadorTagEhMaisNova(String tag, int buildAtual) {
  final build = atualizadorBuildDaTag(tag);
  return buildAtual > 0 && build != null && build > buildAtual;
}

/// True só para APKs hospedados nas Releases deste repositório, via https.
bool atualizadorUrlConfiavel(String url) {
  final uri = Uri.tryParse(url)?.normalizePath();
  return uri != null && _prefixosDownload.any(uri.toString().startsWith);
}

/// Monta a atualização a partir do JSON da Release. Retorna null se a tag não é
/// mais nova que [buildAtual]. Lança [AtualizadorException] se a Release não
/// puder ser instalada com segurança (sem APK, sem `.sha256`, link ou tamanho ruins).
AtualizacaoDisponivel? atualizadorInterpretarRelease(
    Map<String, dynamic> dados, int buildAtual) {
  if (buildAtual <= 0) {
    throw const AtualizadorException(
        "Não consegui ler a versão instalada do app. Baixe o APK mais recente manualmente na página de Releases do RenanCash.");
  }
  final tag = (dados["tag_name"] ?? "").toString();
  if (!atualizadorTagEhMaisNova(tag, buildAtual)) return null;
  final assets = (dados["assets"] as List? ?? []).cast<Map<String, dynamic>>();
  String nome(Map<String, dynamic> a) => (a["name"] ?? "").toString();
  final apk = assets.firstWhere((a) => nome(a).toLowerCase().endsWith(".apk"),
      orElse: () => {});
  if (apk.isEmpty) throw const AtualizadorException("Release sem arquivo .apk");
  final hash = assets.firstWhere(
      (a) => nome(a).toLowerCase() == "${nome(apk).toLowerCase()}.sha256",
      orElse: () => {});
  if (hash.isEmpty) {
    // Releases publicadas antes da verificação não têm hash: recusa, não instala às cegas.
    throw AtualizadorException(
        "A versão ${atualizadorVersaoDaTag(tag)} foi publicada sem o hash SHA-256 e não pode ser instalada pelo app. Baixe o APK manualmente na página de Releases do RenanCash.");
  }
  final url = apk["browser_download_url"].toString();
  final urlHash = hash["browser_download_url"].toString();
  final tamanho = (apk["size"] as num).toInt();
  if (!atualizadorUrlConfiavel(url) || !atualizadorUrlConfiavel(urlHash)) {
    throw const AtualizadorException(
        "Release com endereço de download não confiável");
  }
  if (tamanho <= 0 || tamanho > _tamanhoMaximoApk) {
    throw AtualizadorException(
        "Release com tamanho de APK inválido ($tamanho bytes)");
  }
  return AtualizacaoDisponivel(
    versao: atualizadorVersaoDaTag(tag),
    build: atualizadorBuildDaTag(tag)!,
    urlApk: url,
    tamanhoApk: tamanho,
    urlSha256: urlHash,
  );
}

/// Consulta a última Release. Retorna null se não há versão mais nova.
/// Lança exceção em falha de rede/formato (quem chama decide se mostra).
Future<AtualizacaoDisponivel?> atualizadorProcurar() async {
  final buildAtual = int.tryParse(packageInfoGlobal?.buildNumber ?? "") ?? 0;
  final resp = await http.get(Uri.parse(atualizadorUrlLatest), headers: {
    "Accept": "application/vnd.github+json"
  }).timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) {
    throw Exception("GitHub respondeu ${resp.statusCode}");
  }
  return atualizadorInterpretarRelease(
      json.decode(resp.body) as Map<String, dynamic>, buildAtual);
}

String _hoje() => DateTime.now().toIso8601String().substring(0, 10);

/// Verificação automática (ao abrir o app). Silenciosa em falhas; não bloqueia.
/// Após "Depois", não oferece a mesma versão de novo no mesmo dia.
Future<void> atualizadorVerificarAutomatico(BuildContext context) async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    final nova = await atualizadorProcurar();
    if (nova == null) return;
    if (appStateSettings[_chaveOferta] == "${nova.build}|${_hoje()}") return;
    if (!context.mounted) return;
    await atualizadorMostrarDialogo(context, nova);
  } catch (e) {
    debugPrint("Atualizador (silencioso): $e");
  }
}

/// Botão manual. Retorna mensagem para exibir ao usuário.
Future<String> atualizadorVerificarManual(BuildContext context) async {
  if (kIsWeb || !Platform.isAndroid) return "Atualização dentro do app só no Android.";
  try {
    final nova = await atualizadorProcurar();
    if (nova == null) return "Você já está na versão mais recente.";
    if (!context.mounted) return "";
    await atualizadorMostrarDialogo(context, nova);
    return "";
  } catch (e) {
    return "Não foi possível procurar atualização: $e";
  }
}

Future<void> atualizadorMostrarDialogo(
    BuildContext context, AtualizacaoDisponivel nova) async {
  await openPopup(
    context,
    icon: Icons.system_update_rounded,
    title: "Nova versão ${nova.versao}",
    description: "Baixar e instalar agora?",
    onSubmitLabel: "Atualizar",
    onCancelLabel: "Depois",
    onSubmit: () async {
      Navigator.of(context).pop();
      await atualizadorBaixarEInstalar(context, nova);
    },
    onCancel: () async {
      Navigator.of(context).pop();
      await updateSettings(_chaveOferta, "${nova.build}|${_hoje()}",
          updateGlobalState: false);
    },
  );
}

Future<T> _comTimeout<T>(Future<T> f, Duration limite, String quando) =>
    f.timeout(limite,
        onTimeout: () => throw AtualizadorException(
            "O servidor não respondeu $quando (${limite.inSeconds} s). Verifique a internet e tente de novo."));

/// Lê o SHA-256 esperado do arquivo `.sha256` ("<64 hex>  <nome>").
Future<String> _baixarHashEsperado(
    http.Client cliente, String url, Duration inatividade) async {
  final resp = await _comTimeout(
      cliente.get(Uri.parse(url)), inatividade, "ao baixar o hash SHA-256");
  if (resp.statusCode != 200) {
    throw AtualizadorException(
        "Não foi possível baixar o hash SHA-256 (HTTP ${resp.statusCode}).");
  }
  final m = resp.bodyBytes.length > 1024
      ? null
      : RegExp(r'^\s*([0-9a-fA-F]{64})(?:\s|$)').firstMatch(resp.body);
  if (m == null) {
    throw const AtualizadorException("Arquivo de hash SHA-256 inválido.");
  }
  return m.group(1)!.toLowerCase();
}

/// Baixa o APK para [pasta], com timeout de [inatividade] sem receber bytes,
/// confere o tamanho e o SHA-256 publicado. Devolve o arquivo só se tudo bater;
/// em qualquer falha apaga o arquivo e lança [AtualizadorException].
Future<File> atualizadorBaixarVerificado(
  AtualizacaoDisponivel nova, {
  required http.Client cliente,
  required Directory pasta,
  void Function(double? progresso)? aoProgredir,
  Duration inatividade = const Duration(seconds: 30),
}) async {
  if (!atualizadorUrlConfiavel(nova.urlApk) ||
      !atualizadorUrlConfiavel(nova.urlSha256)) {
    throw const AtualizadorException(
        "Endereço de download não confiável. Nada foi baixado.");
  }
  final esperado = await _baixarHashEsperado(cliente, nova.urlSha256, inatividade);
  final arquivo = File("${pasta.path}/renancash-${nova.versao}.apk");
  try {
    if (await arquivo.exists()) await arquivo.delete();
    final resp = await _comTimeout(
        cliente.send(http.Request("GET", Uri.parse(nova.urlApk))),
        inatividade,
        "ao iniciar o download");
    if (resp.statusCode != 200) {
      throw AtualizadorException(
          "O servidor respondeu HTTP ${resp.statusCode} ao baixar o APK.");
    }
    final total = nova.tamanhoApk;
    int baixado = 0;
    final sink = arquivo.openWrite();
    try {
      await for (final parte in resp.stream.timeout(inatividade)) {
        baixado += parte.length;
        if (baixado > total) {
          throw const AtualizadorException(
              "O arquivo baixado é maior que o esperado.");
        }
        sink.add(parte);
        aoProgredir?.call(total > 0 ? (baixado / total).clamp(0.0, 1.0) : null);
      }
    } on TimeoutException {
      throw AtualizadorException(
          "O download parou: nenhum dado recebido por ${inatividade.inSeconds} s. Verifique a internet e tente de novo.");
    } finally {
      await sink.close();
    }
    final tamanho = await arquivo.length();
    if (tamanho != total) {
      throw AtualizadorException(
          "Arquivo incompleto ($tamanho de $total bytes). Tente de novo.");
    }
    final calculado = (await sha256.bind(arquivo.openRead()).first).toString();
    if (calculado != esperado) {
      throw const AtualizadorException(
          "O arquivo baixado não confere com o SHA-256 publicado (corrompido ou adulterado). A instalação foi cancelada e o arquivo apagado.");
    }
    return arquivo;
  } catch (_) {
    try {
      if (await arquivo.exists()) await arquivo.delete();
    } catch (e) {
      debugPrint("Atualizador: não apagou APK: $e");
    }
    rethrow;
  }
}

/// Baixa e confere o APK mostrando progresso; só abre o instalador se o SHA-256 bater.
Future<void> atualizadorBaixarEInstalar(
    BuildContext context, AtualizacaoDisponivel nova) async {
  final progresso = ValueNotifier<double?>(0);
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: Text("Baixando ${nova.versao}"),
      content: ValueListenableBuilder<double?>(
        valueListenable: progresso,
        builder: (_, p, __) =>
            Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: p),
          const SizedBox(height: 10),
          Text(p == null ? "" : "${(p * 100).round()}%"),
        ]),
      ),
    ),
  );
  String? erro;
  File? arquivo;
  final cliente = http.Client();
  try {
    final dir = await getTemporaryDirectory();
    arquivo = await atualizadorBaixarVerificado(nova,
        cliente: cliente,
        pasta: dir,
        aoProgredir: (p) => progresso.value = p);
  } on AtualizadorException catch (e) {
    erro = e.mensagem;
  } catch (e) {
    erro = "Falha de rede ou de armazenamento: $e";
  } finally {
    cliente.close();
    navigator.pop(); // sempre fecha o diálogo, mesmo em falha ou timeout
  }
  if (arquivo == null) {
    if (context.mounted) {
      openSnackbar(SnackbarMessage(
          title: "Falha ao baixar a atualização", description: erro));
    }
    return;
  }
  await OpenFilex.open(arquivo.path,
      type: "application/vnd.android.package-archive");
}
