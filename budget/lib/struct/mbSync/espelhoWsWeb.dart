import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Web: o navegador não aceita cabeçalhos no WebSocket; a sessão vai por cookie, na mesma origem.
WebSocketChannel mbAbrirCanalWs(Uri uri, String? token) => HtmlWebSocketChannel.connect(uri);
