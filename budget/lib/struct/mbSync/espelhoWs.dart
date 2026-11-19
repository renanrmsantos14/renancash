import 'dart:async';
import 'dart:convert';

import 'package:budget/struct/mbSync/espelhoWsIo.dart' if (dart.library.html) 'package:budget/struct/mbSync/espelhoWsWeb.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// `https://x` -> `wss://x/api/espelho/ws` (e `http` -> `ws`, usado só no Worker local de desenvolvimento).
Uri mbUriWsEspelho(String base) {
  final u = Uri.parse(base);
  return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws', path: '/api/espelho/ws', query: '');
}

/// Aviso em tempo real do servidor: `mudou` (outro aparelho enviou) e `banco` (dados do banco mudaram).
/// Só acelera o pull; se o WebSocket cair, o intervalo de 60 s do agendador cobre.
class MbEspelhoWs {
  MbEspelhoWs({
    required this.abrir,
    required this.aparelho,
    required this.aoMudou,
    required this.aoBanco,
    this.ping = const Duration(seconds: 30),
    this.reconexaoMax = const Duration(seconds: 60),
  });

  final WebSocketChannel Function() abrir;
  final Future<String> Function() aparelho;
  final void Function() aoMudou, aoBanco;
  final Duration ping, reconexaoMax;

  WebSocketChannel? _canal;
  StreamSubscription? _sub;
  Timer? _tPing, _tReconectar;
  bool _ativo = false;
  Duration _espera = const Duration(seconds: 1);

  void iniciar() {
    if (_ativo) return;
    _ativo = true;
    _conectar();
  }

  void parar() {
    _ativo = false;
    _tReconectar?.cancel();
    _tReconectar = null;
    _fechar();
  }

  void _fechar() {
    _tPing?.cancel();
    _sub?.cancel();
    _canal?.sink.close();
    _canal = _sub = _tPing = null;
  }

  void _conectar() {
    try {
      final canal = _canal = abrir();
      canal.ready.then((_) => _espera = const Duration(seconds: 1), onError: (_) {});
      _sub = canal.stream.listen(_mensagem, onDone: _cair, onError: (_) => _cair(), cancelOnError: true);
      _tPing = Timer.periodic(ping, (_) => canal.sink.add('ping'));
    } catch (_) {
      _cair();
    }
  }

  Future<void> _mensagem(dynamic m) async {
    if (m is! String || m == 'pong') return;
    try {
      final j = jsonDecode(m);
      if (j is! Map) return;
      if (j['tipo'] == 'banco') {
        aoBanco();
      } else if (j['tipo'] == 'mudou' && j['aparelho'] != await aparelho()) {
        aoMudou();
      }
    } catch (_) {}
  }

  void _cair() {
    _fechar();
    if (!_ativo || _tReconectar != null) return;
    final espera = _espera;
    _espera = _espera * 2 > reconexaoMax ? reconexaoMax : _espera * 2;
    _tReconectar = Timer(espera, () {
      _tReconectar = null;
      if (_ativo) _conectar();
    });
  }
}

/// Canal real: Android com cabeçalho, web com cookie.
WebSocketChannel mbCanalWsDoApp(String base, String? token) => mbAbrirCanalWs(mbUriWsEspelho(base), token);
