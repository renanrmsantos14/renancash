import 'dart:async';
import 'dart:convert';

import 'package:budget/struct/mbSync/espelhoWsIo.dart' if (dart.library.html) 'package:budget/struct/mbSync/espelhoWsWeb.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// `https://x/mb` -> `wss://x/mb/api/espelho/ws` (e `http` -> `ws`, usado só no Worker local de desenvolvimento).
/// Mantém o prefixo de caminho da base e não deixa `?` vazio.
Uri mbUriWsEspelho(String base) {
  final u = Uri.parse(base);
  return Uri(
    scheme: u.scheme == 'https' ? 'wss' : 'ws',
    userInfo: u.userInfo,
    host: u.host,
    port: u.hasPort ? u.port : null,
    path: '${u.path.replaceFirst(RegExp(r'/+$'), '')}/api/espelho/ws',
  );
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
    this.estavel = const Duration(seconds: 30),
  });

  final WebSocketChannel Function() abrir;
  final Future<String> Function() aparelho;
  final void Function() aoMudou, aoBanco;
  /// Tempo aberto para a conexão contar como boa e o intervalo de reconexão voltar a 1 s.
  final Duration ping, reconexaoMax, estavel;

  WebSocketChannel? _canal;
  StreamSubscription? _sub;
  Timer? _tPing, _tReconectar, _tEstavel;
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
    _tEstavel?.cancel();
    _sub?.cancel();
    _canal?.sink.close();
    _canal = _sub = _tPing = _tEstavel = null;
  }

  void _conectar() {
    try {
      final canal = _canal = abrir();
      // Só uma conexão que se sustenta zera o backoff: servidor que aceita e derruba logo não vira laço apertado.
      canal.ready.then((_) {
        if (_canal == canal) _tEstavel = Timer(estavel, () => _espera = const Duration(seconds: 1));
      }, onError: (_) {});
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
