import 'dart:async';

import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart' show mbLerEstado;
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/espelho.dart';
import 'package:budget/struct/mbSync/espelhoTriggers.dart';
import 'package:budget/struct/mbSync/espelhoWs.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:drift/drift.dart' show TableUpdateQuery;

/// Decide quando sincronizar sozinho. A escrita local continua imediata (feedback otimista); aqui só se agenda o envio.
/// - edição local (só o agendador do espelho): espera [debounce] sem novas edições e sincroniza;
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
  pareado: () {
    if (!mbEspelhoPermitido()) return _diag('desligado (mbEspelho = false)');
    if (!meuBancoPareado.value) return _diag('aparelho não pareado');
    return true;
  },
);

/// Anota o motivo no diagnóstico; devolve false para servir de `return` nas checagens.
bool _diag(String motivo) {
  mbDiagnosticoEspelho.value = motivo;
  return false;
}

/// O Android semeia (ou troca pela nuvem) só depois de o usuário confirmar o cartão da tela.
bool _confirmado = false;

/// "Agora não": até o próximo boot o espelho não semeia nem troca (o sync antigo segue funcionando).
bool _adiado = false;

/// Quando o servidor respondeu 404 (Worker sem ESPELHO). Dentro de [_reverificar] não se pergunta de novo; abrir o
/// app (`mbEspelhoVoltouAoApp`) zera, então o custo é um GET por abertura e não um a cada 60 s.
DateTime? _indisponivelDesde;
const Duration _reverificar = Duration(hours: 6);

/// Para os testes: cliente no lugar do pareamento e estado da sessão limpo.
@visibleForTesting
MbCliente? mbClienteEspelhoParaTeste;

@visibleForTesting
void mbEspelhoReiniciarSessao() {
  _confirmado = _adiado = false;
  _indisponivelDesde = null;
}

@visibleForTesting
Future<bool> mbEspelhoRodarUmaVez() => _rodarEspelho();

void mbEspelhoConfirmarSemeio() {
  _confirmado = true;
  _adiado = false;
  mbEspelhoAgendador.pedirAgora();
}

void mbEspelhoAdiar() {
  _adiado = true;
  mbFaseEspelho.value = MbFaseEspelho.desconhecida;
}

String _mensagemErro(Object e) => e is MbErroHttp
    ? 'O servidor respondeu (HTTP ${e.status}): ${e.mensagem}.'
    : 'Sem conexão com o servidor. Confira a internet e tente de novo.';

/// "Enviar dados para a nuvem" em Configurações: confirma o semeio (ou a troca) e roda a avaliação uma vez, esperando.
/// Funciona mesmo que a avaliação automática tenha falhado ou o usuário tenha tocado em "Agora não". Devolve o
/// resultado em texto para a tela (andamento fica em [mbProgressoEspelho]).
Future<String> mbEspelhoEnviarAgora() async {
  if (kIsWeb) return 'Só o celular envia os dados.';
  if (!mbEspelhoPermitido()) return 'O espelho está desligado neste aparelho (mbEspelho = false).';
  _confirmado = true;
  _adiado = false;
  _indisponivelDesde = null;
  mbErroEspelho.value = '';
  final ok = await _rodarEspelho();
  final erro = mbErroEspelho.value;
  if (erro.isNotEmpty) return erro;
  if (!ok) return 'Não deu para concluir: ${mbDiagnosticoEspelho.value}.';
  return switch (mbFaseEspelho.value) {
    MbFaseEspelho.pronto => 'Pronto: este celular é a fonte oficial e os dados estão na nuvem.',
    MbFaseEspelho.indisponivel => 'O servidor ainda não tem o espelho ligado (resposta 404).',
    final f => 'Terminou na fase "${f.name}": ${mbDiagnosticoEspelho.value}.',
  };
}

Future<bool> _rodarEspelho() async {
  if (mbEspelhoPronto.value) {
    mbDiagnosticoEspelho.value = 'este aparelho já é espelho; sincronizando';
    return mbEspelhoSincronizar();
  }
  if (_adiado) {
    _diag('adiado pelo usuário ("Agora não")');
    return true;
  }
  final ate = _indisponivelDesde;
  if (ate != null && DateTime.now().difference(ate) < _reverificar) {
    _diag('servidor sem espelho (404); pergunta de novo ao abrir o app');
    return true;
  }
  final cliente = mbClienteEspelhoParaTeste ?? await mbClienteConfigurado();
  if (cliente == null) return _diag('sem pareamento (token ou endereço ausente)');
  try {
    final fase = await mbEspelhoDoApp(cliente).avaliar(
      podeSemear: !kIsWeb,
      confirmado: _confirmado,
      aoFase: (f) => mbFaseEspelho.value = f,
      protegido: (acao) => mbEmRodada(acao),
    );
    _indisponivelDesde = fase == MbFaseEspelho.indisponivel ? DateTime.now() : null;
    mbErroEspelho.value = '';
    mbDiagnosticoEspelho.value = switch (fase) {
      MbFaseEspelho.indisponivel => 'servidor sem espelho (404)',
      MbFaseEspelho.aguardando => 'esperando o celular enviar os dados',
      MbFaseEspelho.confirmar || MbFaseEspelho.confirmarTroca => 'esperando a confirmação do usuário',
      MbFaseEspelho.pronto => 'ok',
      _ => 'avaliado',
    };
    if (fase == MbFaseEspelho.pronto) {
      await mbEspelhoReavaliar();
    } else if (fase != MbFaseEspelho.indisponivel) {
      // Web esperando o semeio: o aviso `mudou` do servidor no fim dele dispara a troca.
      await _abrirWs();
    }
    return true;
  } catch (e) {
    // Qualquer falha fica no diagnóstico; só o semeio e a troca viram erro cobrindo a tela.
    final msg = _mensagemErro(e);
    mbDiagnosticoEspelho.value = e is MbErroHttp ? 'HTTP ${e.status}: ${e.mensagem}' : 'sem rede ($e)';
    mbErroEspelho.value = msg;
    final f = mbFaseEspelho.value;
    if (f == MbFaseEspelho.semeando || f == MbFaseEspelho.trocando) mbFaseEspelho.value = MbFaseEspelho.erro;
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
  if (!mbEspelhoPermitido()) return;
  _indisponivelDesde = null;
  mbEspelhoAgendador.voltouAoApp();
  // Só abre o WebSocket onde o servidor tem espelho (pronto ou já descoberto); com 404 ele nem existe.
  if (mbEspelhoLigado() || _fasesComServidor.contains(mbFaseEspelho.value)) _abrirWs();
}

const _fasesComServidor = {
  MbFaseEspelho.aguardando,
  MbFaseEspelho.confirmar,
  MbFaseEspelho.confirmarTroca,
  MbFaseEspelho.semeando,
  MbFaseEspelho.trocando,
  MbFaseEspelho.erro,
};

void mbEspelhoSegundoPlano() {
  mbEspelhoAgendador.foiParaSegundoPlano();
  if (!kIsWeb) _ws?.parar();
}

/// Põe fila, agendador e WebSocket em ordem: na abertura, quando `mbEspelho` muda e quando o aparelho fica pronto.
/// A fila só cresce com o espelho ligado (aparelho pronto e sem o desligamento de emergência).
Future<void> mbEspelhoReavaliar() async {
  await mbEspelhoCarregarEstado(forcar: true);
  if (mbEspelhoPronto.value) mbFaseEspelho.value = MbFaseEspelho.pronto;
  final ligado = mbEspelhoLigado();
  // Semeio interrompido: a fila continua ligada para as edições feitas até a retomada não se perderem.
  final semeando = mbEspelhoPermitido() && await mbLerEstado(mbChaveSemeioEspelho) != null;
  await mbEspelhoDefinirAtivo(database, ligado || semeando);
  if (!mbEspelhoPermitido()) {
    _diag('desligado (mbEspelho = false)');
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
  unawaited(mbEspelhoReavaliar().catchError((Object e) {
    _diag('falha ao iniciar o agendador: $e');
  }));
  // Pareou depois da abertura: o espelho descobre sozinho o que fazer (semear, trocar ou esperar).
  meuBancoPareado.addListener(() {
    if (meuBancoPareado.value) mbEspelhoAgendador.voltouAoApp();
  });
  meuBancoSincronizando.addListener(() {
    if (!meuBancoSincronizando.value) mbAgendador.fimDeRodada();
  });
  // Editar dados não puxa mais o banco: o pull dos dados do Pluggy é só periódico, ao voltar ao app e por aviso do servidor.
  // Qualquer tabela (inclusive `mb_saida`, avisada ao enfileirar configurações): o espelho cobre mais tabelas que o
  // sync antigo. O que o próprio pull grava não reagenda (`aoNotificar` e `_rodando`).
  database.tableUpdates(const TableUpdateQuery.any()).listen((_) => mbEspelhoAgendador.aoEditar());
}
