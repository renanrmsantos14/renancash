import 'package:budget/struct/mbSync/conexoes.dart';
import 'dart:async';
import 'dart:convert';

import 'package:budget/struct/meuBancoSync.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:universal_html/html.dart' as html;

/// Mensagem de "sem conexão" quando [e] é falha de rede (tempo esgotado ou cliente HTTP); senão null.
String? mbErroDeRede(Object e) =>
    e is TimeoutException || e is http.ClientException ? 'Sem conexão com o Meu Banco.' : null;

class MbErroHttp implements Exception {
  final int status;
  final String mensagem;
  MbErroHttp(this.status, this.mensagem);
  @override
  String toString() => mensagem;
}

class MbErroLimite extends MbErroHttp {
  final DateTime? liberadoEm;
  MbErroLimite(String mensagem, this.liberadoEm) : super(429, mensagem);
}

class MbCliente {
  MbCliente({required this.base, this.token, http.Client? cliente})
      : _http = cliente ?? http.Client();

  // Android: https com token. Web: mesma origem, a sessão vai por cookie.
  final String base;
  final String? token;
  final http.Client _http;

  Uri _uri(String caminho, [Map<String, String>? query]) {
    final uri = Uri.parse(base + caminho)
        .replace(queryParameters: query == null || query.isEmpty ? null : query);
    final local = uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '10.0.2.2';
    // O token nunca sai por conexão sem criptografia (http só em depuração, para o Worker local).
    if (uri.scheme != 'https' && !kIsWeb && !(kDebugMode && local)) {
      throw 'O endereço do Meu Banco precisa começar com https://';
    }
    return uri;
  }

  Future<Map<String, dynamic>> _chamar(String metodo, String caminho,
      {Map<String, String>? query,
      Object? corpo,
      Duration limite = const Duration(seconds: 45)}) async {
    final req = http.Request(metodo, _uri(caminho, query));
    req.headers['Accept'] = 'application/json';
    if (token != null && token!.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    if (corpo != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(corpo);
    }
    final resp = await http.Response.fromStream(
        await _http.send(req).timeout(limite));
    Map<String, dynamic> json = {};
    try {
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is Map) json = j.cast<String, dynamic>();
    } catch (_) {}
    if (resp.statusCode >= 200 && resp.statusCode < 300) return json;
    final msg = (json['mensagem'] ?? json['erro'])?.toString();
    switch (resp.statusCode) {
      case 401:
        if (kIsWeb) html.window.location.href = '/login?volta=/app/';
        throw MbErroHttp(401,
            'Token inválido ou revogado. Gere um novo token no Meu Banco.');
      case 429:
        throw MbErroLimite(msg ?? 'Atualizado há pouco. Tente de novo em instantes.',
            DateTime.tryParse('${json['liberado_em']}'));
      case 404:
        throw MbErroHttp(404, msg ?? 'Não encontrado no Meu Banco.');
      case 405:
        throw MbErroHttp(405,
            'O servidor do Meu Banco ainda não tem esse recurso. Atualize o Meu Banco e tente de novo.');
      case 400:
        throw MbErroHttp(400, 'O servidor recusou o pedido${msg == null ? '' : ': $msg'}.');
      default:
        throw MbErroHttp(resp.statusCode,
            msg ?? 'O Meu Banco respondeu com erro ${resp.statusCode}.');
    }
  }

  // Sem token: a senha do painel vira um token de aparelho.
  Future<Object?> parear(String senha) async => (await _chamar(
      'POST', '/api/app/parear',
      corpo: {'senha': senha, 'nome': 'RenanCash'}))['token'];

  Future<Map<String, dynamic>> puxar(String? desde) => _chamar('GET', '/api/sync',
      query: desde == null || desde.isEmpty ? null : {'desde': desde});

  /// Espelho completo: fila local -> servidor. Até 500 linhas por chamada.
  Future<Map<String, dynamic>> espelhoEnviar(String aparelho, List<Map<String, dynamic>> linhas) =>
      _chamar('POST', '/api/espelho', corpo: {'aparelho': aparelho, 'linhas': linhas});

  /// Espelho completo: linhas depois do cursor (`server_at|tabela|pk`), com apagadas; `mais` indica nova página.
  Future<Map<String, dynamic>> espelhoPuxar(String? desde, {int limite = 2000}) =>
      _chamar('GET', '/api/espelho',
          query: {if (desde != null && desde.isNotEmpty) 'desde': desde, 'limite': '$limite'});

  /// Espelho completo: semeio pelo Android, em lotes de 0 a n. `fim` no último; o servidor marca `semeado` aí.
  Future<Map<String, dynamic>> espelhoSemear(int lote, List<Map<String, dynamic>> linhas, {required bool fim}) =>
      _chamar('POST', '/api/espelho/semear',
          corpo: {'lote': lote, 'linhas': linhas, 'fim': fim}, limite: const Duration(seconds: 90));

  // Marca a entrada que é o salário (usado pela fila "Para revisar" quando o salário não foi detectado).
  Future<void> definirSalario(String txId) async {
    await _chamar('PUT', '/api/config', corpo: {'salario_id': txId});
  }

  // Sugestões da aba Pendências (Workers AI no Meu Banco). O Worker devolve lista vazia se a IA falhar.
  Future<Map<String, dynamic>> iaSugerir(Map<String, dynamic> corpo) => _chamar(
      'POST', '/api/ia/sugerir',
      corpo: corpo, limite: const Duration(seconds: 25));

  /// "Feito pela IA": o que o Worker aplicou (sem `desde`, os últimos 14 dias).
  Future<Map<String, dynamic>> iaAplicadas({String? desde}) =>
      _chamar('GET', '/api/ia/aplicadas', query: desde == null ? null : {'desde': desde});

  /// Desfaz uma aplicação. 404: não existe; 409: já desfeita (ambos viram MbErroHttp).
  Future<void> iaDesfazer(String txId) async {
    await _chamar('POST', '/api/ia/desfazer', corpo: {'tx_id': txId});
  }

  /// Importação única dos padrões do aparelho para a memória do Worker.
  Future<void> iaMemoria(List<Map<String, dynamic>> padroes) async {
    await _chamar('POST', '/api/ia/memoria',
        corpo: {'padroes': padroes}, limite: const Duration(seconds: 60));
  }

  Future<Map<String, dynamic>> iaEntender(Map<String, dynamic> corpo) => _chamar(
      'POST', '/api/ia/entender',
      corpo: corpo, limite: const Duration(seconds: 25));

  Future<Map<String, dynamic>> atualizar() =>
      _chamar('POST', '/api/sync/atualizar', corpo: const {});

  Future<String> connectToken({String? itemId}) async =>
      (await _chamar('POST', '/api/pluggy/connect-token',
          corpo: {'itemId': itemId}))['accessToken'] as String;

  Future<void> registrarItem(String itemId) async {
    await _chamar('POST', '/api/pluggy/items', corpo: {'itemId': itemId});
  }

  /// Conexões ativas (bancos) com status e contas.
  Future<List<MbConexao>> conexoes() async => [
        for (final c in ((await _chamar('GET', '/api/pluggy/items'))['conexoes']
                as List? ??
            const []))
          if (c is Map) MbConexao.deJson(c.cast<String, dynamic>())
      ];

  /// Apaga a conexão no Pluggy e no Meu Banco (as contas dela saem do app; o histórico fica).
  Future<void> removerConexao(String itemId) async {
    await _chamar('DELETE', '/api/pluggy/items/${Uri.encodeComponent(itemId)}');
  }

  Future<Map<String, dynamic>> notificacoes(String? desde) =>
      _chamar('GET', '/api/notificacoes',
          query: desde == null || desde.isEmpty ? null : {'desde': desde});
}

Future<MbCliente?> mbClienteConfigurado() async {
  if (kIsWeb) return MbCliente(base: Uri.base.origin);
  final token = await meuBancoLerToken();
  if (token == null || token.isEmpty) return null;
  return MbCliente(base: await meuBancoLerUrl(), token: token);
}
