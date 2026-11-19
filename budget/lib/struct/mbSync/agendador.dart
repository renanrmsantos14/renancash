import 'dart:async';

import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:budget/struct/mbSync/espelhoTriggers.dart';
import 'package:budget/struct/mbSync/espelhoWs.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:drift/drift.dart' show TableUpdateQuery;

/// Decide quando sincronizar sozinho. A escrita local continua imediata (feedback otimista); aqui só se agenda o envio.
/// - edição local: espera [debounce] sem novas edições e sincroniza (várias edições viram uma rodada);
/// - voltar ao app e a cada [intervalo] em primeiro plano: puxa do servidor;
/// - rodada já em curso: marca "de novo ao terminar" em vez de descartar;
/// - falha: tenta de novo em [backoff] (o último valor se repete), sem fila de pedidos nem laço apertado;
/// - escritas feitas pela própria rodada (aplicar do pull) não agendam nada (senão haveria laço).
class MbAgendador {
  MbAgendador({
    required this.rodar,
    required this.pareado,
    this.emRodada,
    this.debounce = const Duration(seconds: 2),
    this.intervalo = const Duration(seconds: 60),
    this.backoff = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 60)
    ],
    // Os eventos do stream do banco chegam um pouco depois do fim da gravação.
    this.folga = const Duration(milliseconds: 300),
    DateTime Function()? agora,
  }) : _agora = agora ?? DateTime.now;

  final Future<bool> Function() rodar;
  final bool Function() pareado;
  final bool Function()? emRodada;
  final Duration debounce, intervalo, folga;
  final List<Duration> backoff;
  final DateTime Function() _agora;

  Timer? _tDebounce, _tPeriodico, _tRetry;
  bool _ativo = false, _rodando = false, _denovo = false, _primeiroPlano = true;
  int _falhas = 0;
  DateTime? _ignorarAte;

  int get falhasSeguidas => _falhas;

  void iniciar() {
    if (_ativo) return;
    _ativo = true;
    _tPeriodico = Timer.periodic(intervalo, (_) {
      // Em retry o backoff manda; em segundo plano não se gasta rede.
      if (_primeiroPlano && _tRetry == null) _pedir();
    });
  }

  void parar() {
    _ativo = false;
    _tDebounce?.cancel();
    _tPeriodico?.cancel();
    _tRetry?.cancel();
    _tDebounce = _tPeriodico = _tRetry = null;
  }

  /// Chamar a cada escrita local que sincroniza (tabelas e configurações).
  void aoEditar() {
    if (!_ativo || !pareado()) return;
    final ate = _ignorarAte;
    if (_rodando || (emRodada?.call() ?? false) || (ate != null && _agora().isBefore(ate))) {
      return;
    }
    _tDebounce?.cancel();
    _tDebounce = Timer(debounce, _pedir);
  }

  void voltouAoApp() {
    _primeiroPlano = true;
    _falhas = 0;
    _pedir();
  }

  void foiParaSegundoPlano() => _primeiroPlano = false;

  /// Roda já (aviso em tempo real do servidor), sem esperar o debounce.
  void pedirAgora() => _pedir();

  /// Para quem observa rodadas que este agendador não iniciou (botão, abertura do app).
  void fimDeRodada() => _ignorarAte = _agora().add(folga);

  void _pedir() {
    _tDebounce?.cancel();
    _tDebounce = null;
    if (!_ativo || !pareado()) return;
    if (_rodando) {
      _denovo = true;
      return;
    }
    _executar();
  }

  Future<void> _executar() async {
    _rodando = true;
    _tRetry?.cancel();
    _tRetry = null;
    var ok = false;
    try {
      ok = await rodar();
    } catch (_) {}
    _rodando = false;
    fimDeRodada();
    if (!_ativo) return;
    if (ok) {
      _falhas = 0;
      if (_denovo) {
        _denovo = false;
        _pedir();
      }
    } else {
      _denovo = false; // o retry já refaz
      final espera = backoff[_falhas < backoff.length ? _falhas : backoff.length - 1];
      _falhas++;
      _tRetry = Timer(espera, () {
        _tRetry = null;
        _pedir();
      });
    }
  }
}

final MbAgendador mbAgendador = MbAgendador(
  rodar: () => sincronizarMeuBanco(),
  pareado: () => meuBancoPareado.value,
  emRodada: () => meuBancoSincronizando.value,
);

/// Espelho completo (atrás da flag `mbEspelho`): mesmo debounce, intervalo e backoff do sync atual.
final MbAgendador mbEspelhoAgendador = MbAgendador(
  rodar: mbEspelhoSincronizar,
  pareado: () => mbEspelhoLigado() && meuBancoPareado.value,
);

MbEspelhoWs? _ws;

// Android só mantém o WebSocket com o app em primeiro plano; na web ele fica aberto.
Future<void> _abrirWs() async {
  final cliente = await mbClienteConfigurado();
  if (cliente == null) return;
  (_ws ??= MbEspelhoWs(
    abrir: () => mbCanalWsDoApp(cliente.base, cliente.token),
    aparelho: () => mbEspelhoAparelhoId(database),
    aoMudou: mbEspelhoAgendador.pedirAgora,
    aoBanco: mbAgendador.pedirAgora,
  ))
      .iniciar();
}

void mbEspelhoVoltouAoApp() {
  if (!mbEspelhoLigado()) return;
  mbEspelhoAgendador.voltouAoApp();
  _abrirWs();
}

void mbEspelhoSegundoPlano() {
  mbEspelhoAgendador.foiParaSegundoPlano();
  if (!kIsWeb) _ws?.parar();
}

Future<void> _iniciarEspelho() async {
  // A fila só cresce com o espelho ativo; desligado, ela é esvaziada.
  await mbEspelhoDefinirAtivo(database, mbEspelhoLigado());
  if (!mbEspelhoLigado()) return;
  mbEspelhoAgendador.iniciar();
  mbEspelhoAgendador.voltouAoApp();
  await _abrirWs();
}

bool _automaticoIniciado = false;

/// Liga o sync automático (idempotente). Só age quando o app está pareado.
void mbIniciarSyncAutomatico() {
  if (_automaticoIniciado) return;
  _automaticoIniciado = true;
  meuBancoVerificarPareado();
  mbAgendador.iniciar();
  unawaited(_iniciarEspelho());
  meuBancoSincronizando.addListener(() {
    if (!meuBancoSincronizando.value) mbAgendador.fimDeRodada();
  });
  database
      .tableUpdates(TableUpdateQuery.onAllTables([
        database.wallets,
        database.categories,
        database.budgets,
        database.categoryBudgetLimits,
        database.objectives,
        database.transactions,
        database.associatedTitles,
      ]))
      .listen((_) {
    mbAgendador.aoEditar();
    mbEspelhoAgendador.aoEditar();
  });
}
