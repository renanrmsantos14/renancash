import 'package:budget/pages/homePage/homePageConexaoCaida.dart'
    show mbReconectarAviso;
import 'package:budget/pages/homePage/homePageParaRevisar.dart'
    show ItemParaRevisar;
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/avisos.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

/// Aba Pendências: bancos desconectados numa faixa fixa e a fila Para revisar um item por vez.
/// "Pular" (botão ou deslizar para a esquerda) manda o item para o fim da fila só nesta sessão.
class PendenciasPage extends StatefulWidget {
  // `atualizar` existe para os testes preencherem as filas sem o banco.
  const PendenciasPage({super.key, this.atualizar = true});
  final bool atualizar;

  @override
  State<PendenciasPage> createState() => _PendenciasPageState();
}

class _PendenciasPageState extends State<PendenciasPage> {
  final List<String> _pulados = [];

  @override
  void initState() {
    super.initState();
    if (widget.atualizar) mbAtualizarRevisar();
  }

  /// Ordem da fila: os não pulados na ordem original, depois os pulados na ordem em que foram pulados.
  List<MbItemRevisao> _ordenar(List<MbItemRevisao> itens) {
    final porId = {for (final i in itens) i.id: i};
    return [
      for (final i in itens)
        if (!_pulados.contains(i.id)) i,
      for (final id in _pulados)
        if (porId[id] case final i?) i,
    ];
  }

  void _pular(String id) => setState(() => _pulados
    ..remove(id)
    ..add(id));

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return ColoredBox(
      color: e.bg,
      child: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: Listenable.merge([meuBancoAvisos, meuBancoRevisar]),
          builder: (context, _) {
            final avisos = meuBancoAvisos.value;
            final fila = _ordenar(meuBancoRevisar.value);
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
              children: [
                Text('Pendências', style: EdTexto.h1(context)),
                const SizedBox(height: 16),
                for (final a in avisos) _FaixaDesconectado(aviso: a),
                if (fila.isEmpty && avisos.isEmpty)
                  const _TudoEmDia()
                else if (fila.isEmpty)
                  Text('Nada para revisar.',
                      style: EdTexto.corpo(context).copyWith(color: e.mu))
                else ...[
                  Row(children: [
                    Expanded(
                        child: Text('Para revisar',
                            style: EdTexto.rotulo(context))),
                    Text('1 de ${fila.length}', style: EdTexto.rotulo(context)),
                  ]),
                  const SizedBox(height: 10),
                  _CartaoTriagem(
                    key: ValueKey(fila.first.id),
                    item: fila.first,
                    aoPular:
                        fila.length > 1 ? () => _pular(fila.first.id) : null,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FaixaDesconectado extends StatelessWidget {
  const _FaixaDesconectado({required this.aviso});
  final Map<String, dynamic> aviso;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
          color: e.warnbg, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.link_off_rounded, size: 20, color: e.warntx),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${aviso['banco'] ?? 'Banco'} desconectado',
                style: EdTexto.corpo(context)
                    .copyWith(fontWeight: FontWeight.w600, color: e.warntx)),
            Text('As compras novas não chegam até reconectar.',
                style: EdTexto.rotulo(context).copyWith(color: e.warntx)),
          ]),
        ),
        TextButton(
          onPressed: () => mbReconectarAviso(context, aviso),
          style: TextButton.styleFrom(foregroundColor: e.warntx),
          child: const Text('Reconectar',
              style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

class _TudoEmDia extends StatelessWidget {
  const _TudoEmDia();

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Padding(
      padding: const EdgeInsets.only(top: 96),
      child: Column(children: [
        Icon(Icons.check_circle_outline_rounded, size: 36, color: e.mu),
        const SizedBox(height: 12),
        Text('Tudo em dia',
            style: EdTexto.corpo(context).copyWith(
                fontSize: 18, fontWeight: FontWeight.w600, color: e.tx)),
        const SizedBox(height: 4),
        Text('Nada para revisar e nenhum banco desconectado.',
            textAlign: TextAlign.center, style: EdTexto.rotulo(context)),
      ]),
    );
  }
}

/// Cartão de um item. Deslizar para a esquerda pula (por distância ou por velocidade);
/// para a direita só resiste, porque não há resposta padrão. O arraste segue só o primeiro dedo.
class _CartaoTriagem extends StatefulWidget {
  const _CartaoTriagem({super.key, required this.item, this.aoPular});
  final MbItemRevisao item;
  final VoidCallback? aoPular; // null: item único, não há para onde pular

  @override
  State<_CartaoTriagem> createState() => _CartaoTriagemState();
}

class _CartaoTriagemState extends State<_CartaoTriagem>
    with SingleTickerProviderStateMixin {
  // Velocidade média do gesto que já conta como "pular", como no Sonner (px/ms).
  static const double _velocidadeMinima = 0.11;
  late final AnimationController _dx =
      AnimationController.unbounded(vsync: this);
  int? _ponteiro;
  double _origem = 0;
  Duration _inicio = Duration.zero;
  bool _arrastando = false;

  @override
  void dispose() {
    _dx.dispose();
    super.dispose();
  }

  void _descer(PointerDownEvent ev) {
    if (_ponteiro != null || widget.aoPular == null) return;
    _ponteiro = ev.pointer;
    _origem = ev.position.dx - _dx.value;
    _inicio = ev.timeStamp;
    _arrastando = false;
    _dx.stop();
  }

  void _mover(PointerMoveEvent ev) {
    if (ev.pointer != _ponteiro) return;
    final dx = ev.position.dx - _origem;
    if (!_arrastando && dx.abs() < kTouchSlop) return;
    _arrastando = true;
    _dx.value = dx > 0 ? dx * .15 : dx;
  }

  void _soltar(PointerEvent ev) {
    if (ev.pointer != _ponteiro) return;
    _ponteiro = null;
    if (!_arrastando) return;
    final largura = context.size?.width ?? 1;
    final ms = (ev.timeStamp - _inicio).inMilliseconds.clamp(1, 1 << 30);
    final velocidade = -_dx.value / ms;
    if (_dx.value < -largura * .3 ||
        (_dx.value < -kTouchSlop * 2 && velocidade > _velocidadeMinima)) {
      _sair();
    } else {
      _voltar();
    }
  }

  void _voltar() {
    if (semMovimento(context)) {
      _dx.value = 0;
      return;
    }
    _dx.animateTo(0,
        duration: const Duration(milliseconds: 300), curve: curvaEditorial);
  }

  Future<void> _sair() async {
    final pular = widget.aoPular;
    if (pular == null) return;
    if (!semMovimento(context)) {
      final largura = context.size?.width ?? 400;
      await _dx.animateTo(-largura * 1.1,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
    pular();
    // O mesmo cartão pode voltar a mostrar o item (fila de um só): recoloca no lugar.
    if (mounted) _dx.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Listener(
      onPointerDown: _descer,
      onPointerMove: _mover,
      onPointerUp: _soltar,
      onPointerCancel: _soltar,
      child: AnimatedBuilder(
        animation: _dx,
        builder: (context, filho) {
          // Esmaece até 40% nos primeiros 300 px para a esquerda.
          final opacidade = 1 - (-_dx.value).clamp(0.0, 300.0) / 300 * .6;
          return Transform.translate(
            offset: Offset(_dx.value, 0),
            child: Opacity(opacity: opacidade, child: filho),
          );
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
          decoration: BoxDecoration(
            color: e.bg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: e.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ItemParaRevisar(item: widget.item),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: widget.aoPular == null
                    ? const SizedBox(height: 40)
                    : TextButton.icon(
                        onPressed: _sair,
                        style: TextButton.styleFrom(foregroundColor: e.mu),
                        icon: const Icon(Icons.arrow_back_rounded, size: 16),
                        label: const Text('Pular'),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
