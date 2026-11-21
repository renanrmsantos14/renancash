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

/// "Seu dinheiro" no desktop: os totais Nas contas e Investido e um bloco por banco, com conta,
/// aplicações e fatura. [onAbrir] recebe as carteiras do item tocado (`mb:<id>`, separadas por '|').
class BancosInicio extends StatelessWidget {
  const BancosInicio(
      {super.key, required this.dados, required this.formatar, this.onAbrir});
  final PatrimonioInicio dados;
  final String Function(double) formatar;
  final void Function(String carteiras)? onAbrir;

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
                child: _BlocoBanco(banco: b, formatar: formatar, onAbrir: onAbrir)),
        ],
      ),
    );
  }
}

/// "Seu dinheiro" no celular: total à direita do título, Nas contas e Investido e um cartão por banco
/// em duas colunas. Banco com um item só abre a conta no toque; com mais, abre a lista dos itens.
class BancosGrade extends StatelessWidget {
  const BancosGrade(
      {super.key, required this.dados, required this.formatar, this.onAbrir});
  final PatrimonioInicio dados;
  final String Function(double) formatar;
  final void Function(String carteiras)? onAbrir;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final p = dados.patrimonio;
    final contas = p.correntes + p.poupancas;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TituloBento('Seu dinheiro',
            fim: Text(formatar(contas + p.investimentos),
                style: EdTexto.corpo(context)
                    .copyWith(fontWeight: FontWeight.w500, color: e.acc))),
        GradeBento(filhos: [
          _Total('Nas contas', formatar(contas), bento: true),
          _Total('Investido', formatar(p.investimentos), bento: true),
          for (final b in dados.bancos)
            _CartaoBanco(
                key: ValueKey(b.id),
                banco: b,
                formatar: formatar,
                onAbrir: onAbrir),
        ]),
      ],
    );
  }
}

class _Total extends StatelessWidget {
  const _Total(this.rotulo, this.valor, {this.bento = false});
  final String rotulo, valor;
  final bool bento;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final conteudo = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(rotulo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: EdTexto.rotulo(context).copyWith(fontSize: bento ? 13 : 11.5)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(valor,
              maxLines: 1,
              style: EdTexto.corpo(context).copyWith(
                  fontSize: bento ? 19 : 17, fontWeight: FontWeight.w600)),
        ),
      ],
    );
    return Semantics(
      label: '$rotulo $valor',
      excludeSemantics: true,
      child: bento
          ? CartaoBento(child: conteudo)
          : Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: e.surf,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: e.line)),
              child: conteudo,
            ),
    );
  }
}

class _CartaoBanco extends StatelessWidget {
  const _CartaoBanco(
      {super.key, required this.banco, required this.formatar, this.onAbrir});
  final BancoInicio banco;
  final String Function(double) formatar;
  final void Function(String carteiras)? onAbrir;

  void _abrir(BuildContext context) {
    if (banco.itens.length == 1) {
      onAbrir?.call(banco.itens.first.carteiras);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: corCartaoBento(context),
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (folha) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CabecalhoBanco(banco: banco, total: formatar(banco.total)),
              for (final i in banco.itens)
                _LinhaItem(
                    item: i,
                    formatar: formatar,
                    onAbrir: onAbrir == null
                        ? null
                        : (c) {
                            Navigator.pop(folha);
                            onAbrir!(c);
                          }),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    // Fatura que vence em até 3 dias toma o lugar do subtítulo, em vermelho.
    final urgente = banco.itens.where((i) => i.destaque).firstOrNull;
    final sub = urgente?.rotulo ?? banco.subtitulo;
    final total = formatar(banco.total);
    return Semantics(
      button: true,
      label: '${banco.nome}, $sub, total $total',
      excludeSemantics: true,
      onTap: () => _abrir(context),
      child: ToqueEscala(
        onTap: () => _abrir(context),
        child: CartaoBento(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                LogoBanco(banco: banco, tamanho: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(banco.nome,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: EdTexto.corpo(context)
                          .copyWith(fontWeight: FontWeight.w500)),
                ),
              ]),
              const SizedBox(height: 14),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(total,
                    maxLines: 1,
                    style: EdTexto.corpo(context)
                        .copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 2),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.rotulo(context)
                      .copyWith(color: urgente != null ? e.warn : null)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CabecalhoBanco extends StatelessWidget {
  const _CabecalhoBanco({required this.banco, required this.total});
  final BancoInicio banco;
  final String total;

  @override
  Widget build(BuildContext context) => Container(
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
          Text(total,
              style: EdTexto.corpo(context)
                  .copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _BlocoBanco extends StatelessWidget {
  const _BlocoBanco({required this.banco, required this.formatar, this.onAbrir});
  final BancoInicio banco;
  final String Function(double) formatar;
  final void Function(String carteiras)? onAbrir;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final total = formatar(banco.total);
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
            label: '${banco.nome}, ${banco.subtitulo}, total $total',
            excludeSemantics: true,
            child: _CabecalhoBanco(banco: banco, total: total),
          ),
          const SizedBox(height: 2),
          Divider(height: 1, thickness: 1, color: e.line),
          for (final i in banco.itens)
            _LinhaItem(item: i, formatar: formatar, onAbrir: onAbrir),
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
