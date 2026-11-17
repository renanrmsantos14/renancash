import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/material.dart';

const Curve curvaEditorial = Cubic(.23, 1, .32, 1);

bool semMovimento(BuildContext c) => MediaQuery.disableAnimationsOf(c);

class ContagemValor extends StatefulWidget {
  const ContagemValor(
      {super.key,
      required this.valor,
      required this.formatar,
      this.estilo,
      this.centavosMenores = false});

  final double valor;
  final String Function(double) formatar;
  final TextStyle? estilo;

  /// Mostra ",00" com 55% do tamanho, como nos apps de banco.
  final bool centavosMenores;

  @override
  State<ContagemValor> createState() => _ContagemValorState();
}

class _ContagemValorState extends State<ContagemValor> {
  double _anterior = 0;

  @override
  void didUpdateWidget(ContagemValor antigo) {
    super.didUpdateWidget(antigo);
    _anterior = antigo.valor;
  }

  @override
  Widget build(BuildContext context) {
    if (semMovimento(context)) {
      return _ajustado(widget.formatar(widget.valor));
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey(widget.valor),
      tween: Tween(begin: _anterior, end: widget.valor),
      duration: const Duration(milliseconds: 900),
      curve: curvaEditorial,
      builder: (context, v, _) => _ajustado(widget.formatar(v)),
    );
  }

  Widget _ajustado(String texto) {
    // Separador decimal = último ',' ou '.' seguido só de 1–2 dígitos ("1.855,90" e "1,855.90");
    // "6,500" (milhar sem centavos) fica inteiro.
    final virgula = widget.centavosMenores
        ? (RegExp(r'[,.]\d{1,2}$').firstMatch(texto)?.start ?? -1)
        : -1;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: virgula < 0
          ? Text(texto, style: widget.estilo, maxLines: 1)
          : Text.rich(
              TextSpan(text: texto.substring(0, virgula), children: [
                TextSpan(
                    text: texto.substring(virgula),
                    style: TextStyle(
                        fontSize: (widget.estilo?.fontSize ??
                                DefaultTextStyle.of(context).style.fontSize ??
                                14) *
                            .55)),
              ]),
              style: widget.estilo,
              maxLines: 1),
    );
  }
}

class MedidorEditorial extends StatelessWidget {
  const MedidorEditorial(
      {super.key, required this.fracao, this.alerta = false});

  final double fracao;
  final bool alerta;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final alvo = fracao.clamp(0.0, 1.0);
    Widget preenchimento(double v) => Transform(
          alignment: Alignment.centerLeft,
          transform: Matrix4.diagonal3Values(v, 1, 1),
          child: ColoredBox(color: alerta ? e.warn : e.acc),
        );
    return SizedBox(
      height: 2,
      child: ColoredBox(
        color: e.line,
        child: SizedBox.expand(
          child: semMovimento(context)
              ? preenchimento(alvo)
              : TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: alvo),
                  duration: const Duration(milliseconds: 900),
                  curve: curvaEditorial,
                  builder: (context, v, _) => preenchimento(v),
                ),
        ),
      ),
    );
  }
}

class BarrasDias extends StatelessWidget {
  const BarrasDias(
      {super.key,
      required this.valores,
      required this.indiceHoje,
      this.altura = 40});

  final List<double> valores;
  final int indiceHoje;
  final double altura;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final maior = valores.fold<double>(0, (m, v) => v > m ? v : m);
    final passado = e.tx.withOpacity(.12);
    final n = valores.length;
    const passo = 28;
    final total = 420 + passo * n;

    Widget barras(double Function(int) escala) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < n; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(
                child: i > indiceHoje
                    ? const SizedBox.shrink()
                    : Transform(
                        alignment: Alignment.bottomCenter,
                        transform: Matrix4.diagonal3Values(1, escala(i), 1),
                        child: SizedBox(
                          height: maior <= 0
                              ? 1
                              : (altura * valores[i] / maior)
                                  .clamp(1.0, altura),
                          child: ColoredBox(
                              color: i == indiceHoje ? e.acc : passado),
                        ),
                      ),
              ),
            ],
          ],
        );

    return SizedBox(
      height: altura,
      child: semMovimento(context)
          ? barras((_) => 1)
          : TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: total),
              builder: (context, t, _) => barras((i) =>
                  Interval(passo * i / total, 1, curve: curvaEditorial)
                      .transform(t)),
            ),
    );
  }
}

class ToqueEscala extends StatefulWidget {
  const ToqueEscala({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<ToqueEscala> createState() => _ToqueEscalaState();
}

class _ToqueEscalaState extends State<ToqueEscala> {
  bool _pressionado = false;

  void _definir(bool v) {
    // Sem onTap o item não é tocável: não encolhe ao pressionar.
    if (v && widget.onTap == null) return;
    if (_pressionado != v) setState(() => _pressionado = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _definir(true),
      onPointerUp: (_) => _definir(false),
      onPointerCancel: (_) => _definir(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressionado && !semMovimento(context) ? .97 : 1,
          duration: const Duration(milliseconds: 150),
          curve: curvaEditorial,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Entrada curta de itens de lista e cartões: fade + 8 px em 200 ms, em
/// cascata de 30 ms só nos primeiros [EntradaSuave.cascata] itens; os demais
/// aparecem direto. Não bloqueia toques e some com "reduzir movimento" ou com
/// as animações do app desligadas. [animar] falso (lista já montada, item que
/// volta à tela ao rolar) mostra o item direto.
class EntradaSuave extends StatefulWidget {
  const EntradaSuave(
      {super.key, required this.child, this.indice = 0, this.animar = true});

  final Widget child;
  final int indice;
  final bool animar;

  static const cascata = 8;

  @override
  State<EntradaSuave> createState() => _EntradaSuaveState();
}

class _EntradaSuaveState extends State<EntradaSuave>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;
  Animation<double>? _v;

  @override
  void initState() {
    super.initState();
    if (!widget.animar ||
        widget.indice >= EntradaSuave.cascata ||
        appStateSettings["appAnimations"] != AppAnimations.all.index) return;
    // Atraso dentro da própria animação (Interval), sem Timer pendente.
    final atraso = 30 * widget.indice;
    final c = AnimationController(
        vsync: this, duration: Duration(milliseconds: 200 + atraso))
      ..forward();
    _c = c;
    _v = CurvedAnimation(
        parent: c,
        curve: Interval(atraso / (200 + atraso), 1, curve: curvaEditorial));
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    if (v == null || semMovimento(context)) return widget.child;
    return FadeTransition(
      opacity: v,
      child: AnimatedBuilder(
        animation: v,
        child: widget.child,
        builder: (context, child) => Transform.translate(
            offset: Offset(0, 8 * (1 - v.value)), child: child),
      ),
    );
  }
}
