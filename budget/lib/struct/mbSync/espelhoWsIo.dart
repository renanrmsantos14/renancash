import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Android: o token do aparelho vai no cabeçalho.
WebSocketChannel mbAbrirCanalWs(Uri uri, String? token) => IOWebSocketChannel.connect(uri,
    headers: {if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token'});
