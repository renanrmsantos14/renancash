import 'package:budget/functions.dart' show popRoute;
import 'package:budget/pages/homePage/homePageParaRevisar.dart' show BotaoEscolha;
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/casosComuns.dart';
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/classificarDados.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl, diaMes;
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/widgets/editorial/reembolsoConta.dart' show mbEscolherGastoRachado, mbNomeDoPagador;
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/transactionEntry/transactionLabel.dart' show nomeSemEspacosRepetidos;
import 'package:flutter/material.dart';

const _rotuloFonte = {
  MbFonteSugestao.ia: 'A IA sugere',
  MbFonteSugestao.padrao: 'Como você já respondeu',
  MbFonteSugestao.atual: 'Categoria do banco',
  MbFonteSugestao.usuario: 'Sua escolha',
  MbFonteSugestao.mesPassado: 'Como no mês passado',
};

/// Um lançamento da fila "Para validar", um por vez: estabelecimento, conta e data, valor grande, a categoria que a
/// IA sugere com "Confirmar" e, abaixo, as categorias prováveis (tocar numa já valida) e "Outras". Nada é aplicado sem
/// o toque. Subcategoria, título e vínculo ficam no editar transação.
class ItemClassificar extends StatefulWidget {
  const ItemClassificar({super.key, required this.lancamento, this.pedirSugestoes = true});
  final MbLancamentoIa lancamento;
  final bool pedirSugestoes; // false nos testes: sem rede

  @override
  State<ItemClassificar> createState() => _ItemClassificarState();
}

class _ItemClassificarState extends State<ItemClassificar> {
  bool _enviando = false;
  String? _aviso;

  MbLancamentoIa get _l => widget.lancamento;

  @override
  void initState() {
    super.initState();
    if (!widget.pedirSugestoes) return;
    // Este e os próximos da fila num lote só; quem já tem sugestão da IA não é pedido de novo.
    final fila = meuBancoClassificar.value;
    final i = fila.indexWhere((x) => x.pk == _l.pk);
    mbPedirSugestoes(i < 0 ? [_l] : fila.sublist(i));
  }

  Future<void> _confirmar(MbSugestao s) => _salvar(() => mbConfirmarClassificacao(_l, s));

  Future<void> _ligar(MbGastoCandidato g) => _salvar(() => mbConfirmarReembolso(_l, g.pk));

  Future<void> _salvar(Future<void> Function() acao) async {
    if (_enviando) return;
    setState(() {
      _enviando = true;
      _aviso = null;
    });
    try {
      await acao();
    } catch (_) {
      if (mounted) setState(() => _aviso = 'Não deu para salvar. Tente de novo.');
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _outras() async {
    final escolhida = await openBottomSheet(
      context,
      PopupFramework(
        title: 'Categoria',
        subtitle: nomeSemEspacosRepetidos(_l.descricao),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in mbOpcoesClassificar.categorias)
            if (c.receita == (_l.valor > 0))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c.nome, style: EdTexto.corpo(context)),
                subtitle: c.subs.isEmpty
                    ? null
                    : Text(c.subs.map((s) => s.nome).join(' · '),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: EdTexto.rotulo(context)),
                onTap: () => popRoute(context, c),
              ),
        ]),
      ),
    );
    if (escolhida is MbCategoriaOpcao && mounted) {
      await _confirmar(MbSugestao(_l.pk, escolhida.pk, confianca: 1));
    }
  }

  /// O que aconteceu com o pedido à IA para este lançamento (null: a sugestão da IA já está na tela).
  ({IconData icone, String texto})? _situacaoIa() {
    final fonte = meuBancoSugestoes.value[_l.pk]?.fonte;
    if (fonte == MbFonteSugestao.ia || fonte == MbFonteSugestao.mesPassado) return null;
    final estado = meuBancoIaEstado.value[_l.pk];
    if (estado == MbEstadoIa.falhou || meuBancoIaOk.value == false) {
      return (icone: Icons.cloud_off_rounded, texto: 'Sem IA agora: sugestões pelos seus padrões.');
    }
    return switch (estado) {
      MbEstadoIa.pedindo => (icone: Icons.auto_awesome_rounded, texto: 'Pedindo sugestão à IA…'),
      MbEstadoIa.semSugestao => (icone: Icons.auto_awesome_rounded, texto: 'A IA não teve sugestão para este.'),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return ListenableBuilder(
      listenable: Listenable.merge([meuBancoSugestoes, meuBancoIaOk, meuBancoIaEstado]),
      builder: (context, _) {
        final op = mbOpcoesClassificar;
        final sugestao = meuBancoSugestoes.value[_l.pk];
        final cat = op.categoria(sugestao?.categoriaPk);
        final sub = cat?.subs.where((x) => x.pk == sugestao?.subPk).firstOrNull;
        final alternativas = mbAlternativas(_l, cat?.pk, mbUsoClassificar, op);
        final situacaoIa = _situacaoIa();
        // Salário e rendimento já vêm com a categoria do mês passado: sem "Rachou uma conta?" na frente.
        final parteDeConta =
            _l.valor > 0 && !mbEhJurosPoupanca(_l) && sugestao?.fonte != MbFonteSugestao.mesPassado;
        return Opacity(
          opacity: _enviando ? .5 : 1,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: e.surf, borderRadius: BorderRadius.circular(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(nomeSemEspacosRepetidos(_l.descricao),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context).copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text([if (_l.conta.isNotEmpty) _l.conta, diaMes(_l.data)].join(' · '),
                    style: EdTexto.rotulo(context)),
                const SizedBox(height: 16),
                Text(brl(_l.valor),
                    style: EdTexto.numeroGrande(context)
                        .copyWith(fontWeight: FontWeight.w700, color: _l.valor > 0 ? e.pos : e.tx)),
                const SizedBox(height: 16),
                if (cat != null && sugestao != null) ...[
                  Text(_rotuloFonte[sugestao.fonte]!, style: EdTexto.rotulo(context)),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          color: e.pos.withOpacity(.16), borderRadius: BorderRadius.circular(999)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        child: Text(sub == null ? cat.nome : '${cat.nome} › ${sub.nome}',
                            style: EdTexto.corpo(context)
                                .copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: e.pos)),
                      ),
                    ),
                  ),
                  if (sugestao.pergunta != null) ...[
                    const SizedBox(height: 10),
                    Semantics(
                      liveRegion: true,
                      child: Text(sugestao.pergunta!,
                          style: EdTexto.corpo(context).copyWith(fontSize: 14, height: 1.3)),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _BotaoPrincipal(rotulo: 'Confirmar', onTap: _enviando ? null : () => _confirmar(sugestao)),
                ] else
                  Text('Sem sugestão para este. Toque na categoria certa.', style: EdTexto.rotulo(context)),
                if (situacaoIa != null) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    Icon(situacaoIa.icone, size: 14, color: e.mu),
                    const SizedBox(width: 6),
                    Expanded(child: Text(situacaoIa.texto, style: EdTexto.rotulo(context))),
                  ]),
                ],
              ]),
            ),
            const SizedBox(height: 16),
            Text(cat == null || sugestao == null ? 'Qual é a categoria?' : 'Não é isso? Toque na certa', style: EdTexto.h2(context)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in alternativas)
                BotaoEscolha(
                    rotulo: c.nome,
                    onTap: _enviando ? null : () => _confirmar(MbSugestao(_l.pk, c.pk, confianca: 1))),
              BotaoEscolha(rotulo: 'Outras', onTap: _enviando ? null : _outras),
            ]),
            if (parteDeConta) ...[
              const SizedBox(height: 16),
              ParteDeConta(lancamento: _l, enviando: _enviando, aoLigar: _ligar),
            ],
            if (_aviso != null) ...[
              const SizedBox(height: 8),
              Semantics(liveRegion: true, child: Text(_aviso!, style: EdTexto.rotulo(context).copyWith(color: e.warntx))),
            ],
          ]),
        );
      },
    );
  }
}

/// Numa entrada: o gasto em destaque quando o casamento é forte (Pix = parte exata e sem empate; com quem já rachou 2
/// contas ou mais, basta valor parecido) e, sempre, "É a parte de uma conta que eu paguei" com a lista para escolher.
/// Num estorno: a compra de mesmo valor com "Abater da compra" (o mesmo vínculo do reembolso). Nada é ligado sem o toque.
class ParteDeConta extends StatefulWidget {
  const ParteDeConta(
      {super.key, required this.lancamento, required this.aoLigar, this.enviando = false, this.aoDestacar});
  final MbLancamentoIa lancamento;
  final void Function(MbGastoCandidato) aoLigar;
  final bool enviando;

  /// Avisa (depois do carregamento dos candidatos) se há um gasto em destaque com o botão de ligar.
  final ValueChanged<bool>? aoDestacar;

  @override
  State<ParteDeConta> createState() => _ParteDeContaState();
}

class _ParteDeContaState extends State<ParteDeConta> {
  MbLancamentoIa get _l => widget.lancamento;
  late final Future<List<MbSugestaoReembolso>> _candidatos =
      mbBuscarCandidatosReembolso(_l.pk, _l.valor, _l.data, _l.descricao);

  Future<void> _escolher(List<MbSugestaoReembolso> s) async {
    final g = await mbEscolherGastoRachado(context, sugestoes: s, valor: _l.valor, data: _l.data);
    if (g is MbGastoCandidato) widget.aoLigar(g);
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return FutureBuilder<List<MbSugestaoReembolso>>(
      future: _candidatos,
      builder: (context, snap) {
        final s = snap.data ?? const <MbSugestaoReembolso>[];
        final pagador = mbChavePadrao(_l.descricao);
        final vezes = mbVezesQueRachou(meuBancoReembolsos.value, pagador);
        final estorno = mbEhEstorno(_l);
        final compra = estorno ? mbCompraDoEstorno([for (final x in s) x.gasto], _l) : null;
        final forte = estorno ? null : mbReembolsoForte(s, recorrente: vezes >= 2);
        final destaque = compra ?? forte?.gasto;
        final motivo = forte?.motivos.first;
        final nome = mbNomeDoPagador(pagador);
        final cabecalho = switch ((estorno, forte != null, vezes)) {
          (true, _, _) => 'Estorno de uma compra',
          (_, true, >= 2) => '$nome já mandou a parte de $vezes contas',
          (_, true, _) => 'Parece a parte de uma conta que você pagou',
          (_, _, > 0) => '$nome já mandou a parte de outras contas',
          _ => 'Rachou uma conta?',
        };
        final outra = switch ((estorno, destaque != null)) {
          (true, true) => 'É de outra compra',
          (true, false) => 'Escolher a compra estornada',
          (false, true) => 'É de outra conta',
          (false, false) => 'É a parte de uma conta que eu paguei',
        };
        final abrir = widget.enviando || snap.connectionState != ConnectionState.done ? null : () => _escolher(s);
        if (widget.aoDestacar != null && snap.connectionState == ConnectionState.done) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.aoDestacar!(destaque != null);
          });
        }
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(color: e.surf, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(estorno ? Icons.undo_rounded : Icons.call_split_rounded, size: 14, color: e.acc),
              const SizedBox(width: 6),
              Expanded(child: Text(cabecalho, style: EdTexto.rotulo(context))),
            ]),
            if (destaque != null) ...[
              const SizedBox(height: 8),
              Text(nomeSemEspacosRepetidos(destaque.nome),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.corpo(context).copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
              Text(
                  [
                    diaMes(destaque.data),
                    if (destaque.categoria.isNotEmpty) destaque.categoria,
                    switch (motivo) {
                      null => brl(destaque.valor),
                      'como das outras vezes' => '${brl(destaque.valor)} · $motivo',
                      _ => '$motivo de ${brl(destaque.valor)}',
                    },
                  ].join(' · '),
                  style: EdTexto.rotulo(context)),
              const SizedBox(height: 10),
              _BotaoPrincipal(
                  rotulo: estorno ? 'Abater da compra' : 'Confirmar',
                  onTap: widget.enviando ? null : () => widget.aoLigar(destaque)),
            ],
            _Linha(icone: Icons.receipt_long_rounded, texto: outra, onTap: abrir),
          ]),
        );
      },
    );
  }
}

/// Vários rendimentos de poupança (juros de centavos) num cartão só: a categoria sugerida (a do mês passado, um padrão
/// ou a IA) e "Confirmar todos". Nada é aplicado sem o toque.
class RendimentosPoupanca extends StatefulWidget {
  const RendimentosPoupanca({super.key, required this.itens});
  final List<MbLancamentoIa> itens;

  @override
  State<RendimentosPoupanca> createState() => _RendimentosPoupancaState();
}

class _RendimentosPoupancaState extends State<RendimentosPoupanca> {
  String? _categoriaPk; // escolhida num chip; null = a sugerida
  bool _enviando = false;
  String? _aviso;

  Future<void> _confirmar(MbSugestao escolha) async {
    setState(() {
      _enviando = true;
      _aviso = null;
    });
    try {
      await mbConfirmarVarios(widget.itens, escolha);
    } catch (_) {
      if (mounted) setState(() => _aviso = 'Não deu para salvar. Tente de novo.');
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final itens = widget.itens;
    return ValueListenableBuilder<Map<String, MbSugestao>>(
      valueListenable: meuBancoSugestoes,
      builder: (context, sugestoes, _) {
        final op = mbOpcoesClassificar;
        final sugerida = itens.map((l) => sugestoes[l.pk]).nonNulls.firstOrNull;
        final escolha = _categoriaPk == null || _categoriaPk == sugerida?.categoriaPk
            ? sugerida
            : MbSugestao(itens.first.pk, _categoriaPk!);
        final cat = op.categoria(escolha?.categoriaPk);
        final total = itens.fold<double>(0, (t, l) => t + l.valor);
        final contas = {
          for (final l in itens)
            if (l.conta.isNotEmpty) l.conta
        };
        return Opacity(
          opacity: _enviando ? .5 : 1,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(brl(total), style: EdTexto.numeroGrande(context).copyWith(fontSize: 32, color: e.pos)),
            const SizedBox(height: 6),
            Text(['${itens.length} rendimentos de poupança', ...contas].join(' · '), style: EdTexto.rotulo(context)),
            const SizedBox(height: 2),
            Text('${diaMes(itens.last.data)} a ${diaMes(itens.first.data)} · ${nomeSemEspacosRepetidos(itens.first.descricao)}',
                maxLines: 2, overflow: TextOverflow.ellipsis, style: EdTexto.corpo(context).copyWith(color: e.mu)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              decoration: BoxDecoration(color: e.surf, borderRadius: BorderRadius.circular(12)),
              child: escolha == null || cat == null
                  ? Text('Escolha a categoria abaixo.', style: EdTexto.rotulo(context))
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        if (escolha.fonte == MbFonteSugestao.ia ||
                            escolha.fonte == MbFonteSugestao.mesPassado) ...[
                          Icon(
                              escolha.fonte == MbFonteSugestao.ia
                                  ? Icons.auto_awesome_rounded
                                  : Icons.history_rounded,
                              size: 14,
                              color: e.acc),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            _rotuloFonte[escolha.fonte]!,
                            style: EdTexto.rotulo(context).copyWith(
                              color: escolha.fonte == MbFonteSugestao.mesPassado
                                  ? e.acc
                                  : null,
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Text(cat.nome,
                          style: EdTexto.corpo(context).copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 10),
                      _BotaoPrincipal(
                          rotulo: 'Confirmar todos', onTap: _enviando ? null : () => _confirmar(escolha)),
                    ]),
            ),
            const SizedBox(height: 16),
            Text('Ou escolha outra', style: EdTexto.h2(context)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in mbAlternativas(itens.first, cat?.pk, mbUsoClassificar, op))
                BotaoEscolha(rotulo: c.nome, onTap: _enviando ? null : () => setState(() => _categoriaPk = c.pk)),
            ]),
            if (_aviso != null) ...[
              const SizedBox(height: 8),
              Semantics(
                  liveRegion: true, child: Text(_aviso!, style: EdTexto.rotulo(context).copyWith(color: e.warntx))),
            ],
          ]),
        );
      },
    );
  }
}

class _Linha extends StatelessWidget {
  const _Linha(
      {required this.icone, required this.texto, this.iconeFim = Icons.chevron_right_rounded, this.dica, this.onTap});
  final IconData icone, iconeFim;
  final String texto;
  final String? dica; // leitor de tela: o que o toque faz
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(children: [
          Icon(icone, size: 16, color: e.mu),
          const SizedBox(width: 8),
          Expanded(child: Text(texto, style: EdTexto.corpo(context).copyWith(fontSize: 13))),
          Icon(iconeFim, size: 18, color: e.mu, semanticLabel: dica),
        ]),
      ),
    );
  }
}

class _BotaoPrincipal extends StatelessWidget {
  const _BotaoPrincipal({required this.rotulo, this.onTap, this.secundario = false});
  final String rotulo;
  final VoidCallback? onTap;
  final bool secundario; // contorno em vez de preenchido (ação ao lado da principal)

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return SizedBox(
      height: 52,
      child: FilledButton(
        style: FilledButton.styleFrom(
            backgroundColor: secundario ? e.bg : e.pos,
            foregroundColor: secundario ? e.tx : e.bg,
            side: secundario ? BorderSide(color: e.line) : null,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        onPressed: onTap,
        child: Text(rotulo, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
    );
  }
}
