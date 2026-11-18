import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:flutter/material.dart';

/// Logo oficial do banco (`assets/bancos/<logo>.png`, 128 px, quadrado). Sem logo (banco fora da lista
/// ou arquivo ausente): selo quadrado na cor do banco com as iniciais; "Outros": ícone genérico.
class LogoBanco extends StatelessWidget {
  const LogoBanco({super.key, required this.banco, this.tamanho = 40});
  final BancoInicio banco;
  final double tamanho;

  @override
  Widget build(BuildContext context) {
    final raio = BorderRadius.circular(tamanho * .25);
    final logo = banco.logo;
    return ExcludeSemantics(
      child: SizedBox(
        width: tamanho,
        height: tamanho,
        child: ClipRRect(
          borderRadius: raio,
          child: logo == null
              ? _selo(context)
              : Image.asset('assets/bancos/$logo.png',
                  width: tamanho,
                  height: tamanho,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, __, ___) => _selo(context)),
        ),
      ),
    );
  }

  Widget _selo(BuildContext context) {
    final e = cores(context);
    final cor = banco.cor;
    final outros = banco.id == 'outros';
    final letras = mbSigla(banco.nome);
    return Container(
      color: cor != null ? Color(cor) : e.chip,
      alignment: Alignment.center,
      child: outros
          ? Icon(Icons.account_balance_outlined, size: tamanho * .5, color: e.mu)
          : Text(letras,
              style: TextStyle(
                  fontFamily: 'GeistMono',
                  fontSize: tamanho * .32,
                  fontWeight: FontWeight.w600,
                  color: cor != null ? Colors.white : e.tx)),
    );
  }
}

/// "Seu dinheiro": os totais Nas contas e Investido e um bloco por banco, com conta, aplicações e fatura.
/// [recolher] (celular): cada banco começa só com o cabeçalho e abre ao toque; o banco com fatura em
/// destaque já começa aberto. No desktop fica tudo aberto. [onAbrir] recebe as carteiras do item tocado
/// (`mb:<id>`, separadas por '|').
class BancosInicio extends StatelessWidget {
  const BancosInicio(
      {super.key,
      required this.dados,
      required this.formatar,
      this.onAbrir,
      this.recolher = true});
  final PatrimonioInicio dados;
  final String Function(double) formatar;
  final void Function(String carteiras)? onAbrir;
  final bool recolher;

  @override
  Widget build(BuildContext context) {
    final p = dados.patrimonio;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Seu dinheiro', style: EdTexto.h2(context)),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                  child: _Total('Nas contas', formatar(p.correntes + p.poupancas))),
              const SizedBox(width: 10),
              Expanded(child: _Total('Investido', formatar(p.investimentos))),
            ]),
          ),
          for (final b in dados.bancos)
            Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _BlocoBanco(
                    key: ValueKey(b.id),
                    banco: b,
                    formatar: formatar,
                    onAbrir: onAbrir,
                    recolher: recolher)),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total(this.rotulo, this.valor);
  final String rotulo, valor;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Semantics(
      label: '$rotulo $valor',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: e.surf,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: e.line)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(rotulo,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: EdTexto.rotulo(context).copyWith(fontSize: 11.5)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(valor,
                  maxLines: 1,
                  style: EdTexto.corpo(context)
                      .copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlocoBanco extends StatefulWidget {
  const _BlocoBanco(
      {super.key,
      required this.banco,
      required this.formatar,
      required this.recolher,
      this.onAbrir});
  final BancoInicio banco;
  final String Function(double) formatar;
  final bool recolher;
  final void Function(String carteiras)? onAbrir;

  @override
  State<_BlocoBanco> createState() => _BlocoBancoState();
}

class _BlocoBancoState extends State<_BlocoBanco> {
  late bool _aberto =
      !widget.recolher || widget.banco.itens.any((i) => i.destaque);

  void _alternar() => setState(() => _aberto = !_aberto);

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final banco = widget.banco, formatar = widget.formatar;
    final aberto = !widget.recolher || _aberto;
    final cabecalho = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        LogoBanco(banco: banco),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(banco.nome,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.corpo(context)
                      .copyWith(fontWeight: FontWeight.w600)),
              Text(banco.subtitulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.rotulo(context)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(formatar(banco.total),
            style: EdTexto.corpo(context)
                .copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
        if (widget.recolher) ...[
          const SizedBox(width: 4),
          AnimatedRotation(
              turns: _aberto ? .5 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(Icons.keyboard_arrow_down_rounded, size: 22, color: e.mu)),
        ],
      ]),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
          color: e.surf,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: e.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            button: widget.recolher,
            expanded: widget.recolher ? _aberto : null,
            onTap: widget.recolher ? _alternar : null,
            label: '${banco.nome}, ${banco.subtitulo}, total ${formatar(banco.total)}',
            excludeSemantics: true,
            child: widget.recolher
                ? ToqueEscala(onTap: _alternar, child: cabecalho)
                : cabecalho,
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: aberto
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 2),
                      Divider(height: 1, thickness: 1, color: e.line),
                      for (final i in banco.itens)
                        _LinhaItem(
                            item: i, formatar: formatar, onAbrir: widget.onAbrir),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _LinhaItem extends StatelessWidget {
  const _LinhaItem({required this.item, required this.formatar, this.onAbrir});
  final ItemBanco item;
  final String Function(double) formatar;
  final void Function(String carteiras)? onAbrir;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final valor = formatar(item.valor);
    // Fatura em vermelho; a que vence em até 3 dias ganha fundo e negrito.
    final estilo = EdTexto.corpo(context).copyWith(
        fontSize: 14,
        fontWeight: item.destaque ? FontWeight.w700 : FontWeight.w500,
        color: item.fatura ? (item.destaque ? e.warntx : e.warn) : null);
    final texto = EdTexto.corpo(context).copyWith(
        fontSize: 14,
        fontWeight: item.destaque ? FontWeight.w700 : FontWeight.w400,
        color: item.fatura ? (item.destaque ? e.warntx : e.warn) : e.mu);
    return Semantics(
      button: onAbrir != null,
      label: '${item.rotulo} $valor',
      excludeSemantics: true,
      child: ToqueEscala(
        onTap: onAbrir == null ? null : () => onAbrir!(item.carteiras),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
              color: item.destaque ? e.warnbg : null,
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Expanded(
                child: Text(item.rotulo,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: texto)),
            const SizedBox(width: 8),
            Text(valor, style: estilo),
          ]),
        ),
      ),
    );
  }
}
