import 'dart:async';

import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart' show mbLerEstado;
import 'package:budget/struct/settings.dart' show appStateSettings;
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

/// Espelho completo: mesmo debounce, intervalo e backoff do sync atual. Roda mesmo antes de o aparelho estar pronto
/// (é a rodada que descobre se o servidor tem espelho e semeia ou troca); só `mbEspelho = false` o impede.
final MbAgendador mbEspelhoAgendador = MbAgendador(
  rodar: _rodarEspelho,
  pareado: () => appStateSettings['mbEspelho'] != false && meuBancoPareado.value,
);

/// O Android semeia só depois de o usuário confirmar a tela "Este celular vira a fonte oficial".
bool _semeioConfirmado = false;

void mbEspelhoConfirmarSemeio() {
  _semeioConfirmado = true;
  mbEspelhoAgendador.pedirAgora();
}

Future<bool> _rodarEspelho() async {
  if (mbEspelhoPronto.value) return mbEspelhoSincronizar();
  final cliente = await mbClienteConfigurado();
  if (cliente == null) return false;
  try {
    final fase = await mbEspelhoDoApp(cliente).avaliar(
      podeSemear: !kIsWeb,
      confirmado: _semeioConfirmado,
      aoFase: (f) => mbFaseEspelho.value = f,
      protegido: (acao) => mbEmRodada(acao),
    );
    if (fase == MbFaseEspelho.pronto) {
      await mbEspelhoReavaliar();
    } else if (fase != MbFaseEspelho.indisponivel) {
      // Web esperando o semeio: o aviso `mudou` do servidor no fim dele dispara a troca.
      await _abrirWs();
    }
    return true;
  } catch (_) {
    // Falha no meio do semeio ou da troca: a fase (e a tela que bloqueia edições) fica; o backoff retoma.
    return false;
  } finally {
    mbProgressoEspelho.value = '';
  }
}

MbEspelhoWs? _ws;

// Android só mantém o WebSocket com o app em primeiro plano; na web ele fica aberto.
Future<void> _abrirWs() async {
  final cliente = await mbClienteConfigurado();
  if (cliente == null) return;
  (_ws ??= MbEspelhoWs(
    abrir: () => mbCanalWsDoApp(cliente.base, cliente.token),
    aparelho: () async => await mbLerEstado(mbChaveAparelhoServidor) ?? await mbEspelhoAparelhoId(database),
    aoMudou: mbEspelhoAgendador.pedirAgora,
    aoBanco: mbAgendador.pedirAgora,
  ))
      .iniciar();
}

void mbEspelhoVoltouAoApp() {
  if (appStateSettings['mbEspelho'] == false) return;
  mbEspelhoAgendador.voltouAoApp();
  // Só abre o WebSocket onde o servidor tem espelho (pronto ou já descoberto); com 404 ele nem existe.
  if (mbEspelhoLigado() || _fasesComServidor.contains(mbFaseEspelho.value)) _abrirWs();
}

const _fasesComServidor = {
  MbFaseEspelho.aguardando,
  MbFaseEspelho.confirmar,
  MbFaseEspelho.semeando,
  MbFaseEspelho.trocando,
};

void mbEspelhoSegundoPlano() {
  mbEspelhoAgendador.foiParaSegundoPlano();
  if (!kIsWeb) _ws?.parar();
}

/// Põe fila, agendador e WebSocket em ordem: na abertura, quando `mbEspelho` muda e quando o aparelho fica pronto.
/// A fila só cresce com o espelho ligado (aparelho pronto e sem o desligamento de emergência).
Future<void> mbEspelhoReavaliar() async {
  mbEspelhoPronto.value = await mbLerEstado(mbChaveProntoEspelho) == '1';
  if (mbEspelhoPronto.value) mbFaseEspelho.value = MbFaseEspelho.pronto;
  final ligado = mbEspelhoLigado();
  await mbEspelhoDefinirAtivo(database, ligado);
  if (appStateSettings['mbEspelho'] == false) {
    mbEspelhoAgendador.parar();
    _ws?.parar();
    return;
  }
  mbEspelhoAgendador.iniciar();
  mbEspelhoAgendador.voltouAoApp();
  // Antes de saber que o servidor tem espelho (404 = Worker sem ESPELHO) o WebSocket não abre.
  if (ligado) await _abrirWs();
}

bool _automaticoIniciado = false;

/// Liga o sync automático (idempotente). Só age quando o app está pareado.
void mbIniciarSyncAutomatico() {
  if (_automaticoIniciado) return;
  _automaticoIniciado = true;
  meuBancoVerificarPareado();
  mbAgendador.iniciar();
  unawaited(mbEspelhoReavaliar());
  // Pareou depois da abertura: o espelho descobre sozinho o que fazer (semear, trocar ou esperar).
  meuBancoPareado.addListener(() {
    if (meuBancoPareado.value) mbEspelhoAgendador.voltouAoApp();
  });
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
      .listen((_) => mbAgendador.aoEditar());
  // Qualquer tabela (inclusive `mb_saida`, avisada ao enfileirar configurações): o espelho cobre mais tabelas que o
  // sync antigo. O que o próprio pull grava não reagenda (`aoNotificar` e `_rodando`).
  database.tableUpdates(const TableUpdateQuery.any()).listen((_) => mbEspelhoAgendador.aoEditar());
}
