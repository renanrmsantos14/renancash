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
  MbFonteSugestao.ia: 'Sugestão da IA',
  MbFonteSugestao.padrao: 'Como você já respondeu',
  MbFonteSugestao.atual: 'Categoria do banco',
  MbFonteSugestao.usuario: 'Sua escolha',
  MbFonteSugestao.mesPassado: 'Como no mês passado',
};

/// Um lançamento da fila Para classificar: dados do banco, a sugestão em destaque com "Confirmar", alternativas em
/// chips e "Explicar" em texto livre (a IA interpreta e o usuário confirma). Nada é aplicado sem o toque em Confirmar.
class ItemClassificar extends StatefulWidget {
  const ItemClassificar({super.key, required this.lancamento, this.pedirSugestoes = true});
  final MbLancamentoIa lancamento;
  final bool pedirSugestoes; // false nos testes: sem rede

  @override
  State<ItemClassificar> createState() => _ItemClassificarState();
}

class _ItemClassificarState extends State<ItemClassificar> {
  /// A parte de uma conta / o estorno já tem um gasto em destaque: a caixa "Sem sugestão" só competiria com ele.
  bool _comDestaque = false;
  final _explicacao = TextEditingController();
  MbSugestao? _escolha; // o que o usuário mexeu (chip, sub, vínculo, título, explicação); null = a sugestão
  bool _enviando = false, _entendendo = false;
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

  @override
  void dispose() {
    _explicacao.dispose();
    super.dispose();
  }

  void _mudar(MbSugestao s) => setState(() {
        _escolha = s;
        _aviso = null;
      });

  Future<void> _confirmar(MbSugestao s) => _salvar(() => mbConfirmarClassificacao(_l, s));

  Future<void> _ligar(MbGastoCandidato g) => _salvar(() => mbConfirmarReembolso(_l, g.pk));

  /// Mostra a lista dos iguais antes; um toque em "Confirmar N" aplica a mesma escolha a todos.
  Future<void> _aplicarIguais(MbSugestao s, List<MbLancamentoIa> iguais) async {
    final cat = mbOpcoesClassificar.categoria(s.categoriaPk);
    final sub = cat?.subs.where((x) => x.pk == s.subPk).firstOrNull;
    final ok = await openBottomSheet(
      context,
      PopupFramework(
        title: 'Aplicar a ${iguais.length} iguais',
        subtitle: [
          if (cat != null) sub == null ? cat.nome : '${cat.nome} › ${sub.nome}',
          if (s.titulo != null) s.titulo!,
        ].join(' · '),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final x in iguais) _LinhaLancamento(lancamento: x),
          const SizedBox(height: 12),
          _BotaoPrincipal(rotulo: 'Confirmar ${iguais.length}', onTap: () => popRoute(context, true)),
        ]),
      ),
    );
    if (ok == true) await _salvar(() => mbConfirmarVarios(iguais, s));
  }

  Future<void> _salvar(Future<void> Function() acao) async {
    if (_enviando) return;
    setState(() => _enviando = true);
    try {
      await acao();
    } catch (_) {
      if (mounted) setState(() => _aviso = 'Não deu para salvar. Tente de novo.');
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _entender() async {
    final texto = _explicacao.text.trim();
    if (texto.isEmpty || _entendendo) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _entendendo = true;
      _aviso = null;
    });
    final s = await mbEntenderExplicacao(_l, texto);
    if (!mounted) return;
    setState(() {
      _entendendo = false;
      if (s != null) {
        _escolha = s;
        _explicacao.clear();
      } else {
        _aviso = meuBancoIaOk.value == false
            ? 'Sem a IA agora. Escolha a categoria acima.'
            : 'Não entendi. Tente com outras palavras ou escolha acima.';
      }
    });
  }

  Future<void> _maisCategorias(MbSugestao? atual) async {
    final op = mbOpcoesClassificar;
    final escolhida = await openBottomSheet(
      context,
      PopupFramework(
        title: 'Categoria',
        subtitle: _l.descricao,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final c in op.categorias)
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
    if (escolhida is MbCategoriaOpcao) {
      _mudar((atual ?? MbSugestao(_l.pk, escolhida.pk)).comCategoria(escolhida.pk));
    }
  }

  Future<void> _escolherVinculo(MbSugestao s) async {
    final op = mbOpcoesClassificar;
    final v = await openBottomSheet(
      context,
      PopupFramework(
        title: 'Vincular',
        subtitle: 'Empréstimo ou meta deste lançamento',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final v in op.vinculos)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(v.nome, style: EdTexto.corpo(context)),
              subtitle: Text(v.tipo == 'emprestimo' ? 'Empréstimo' : 'Meta', style: EdTexto.rotulo(context)),
              onTap: () => popRoute(context, v),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Sem vínculo', style: EdTexto.corpo(context)),
            onTap: () => popRoute(context, 'nenhum'),
          ),
        ]),
      ),
    );
    if (v is MbVinculoOpcao || v == 'nenhum') {
      _mudar(MbSugestao(_l.pk, s.categoriaPk,
          subPk: s.subPk,
          titulo: s.titulo,
          vinculoPk: v is MbVinculoOpcao ? v.pk : null,
          confianca: 1));
    }
  }

  Future<void> _editarTitulo(MbSugestao s) async {
    final ctrl = TextEditingController(text: s.titulo ?? '');
    final titulo = await openBottomSheet(
      context,
      PopupFramework(
        title: 'Título',
        subtitle: 'Vazio volta ao texto do banco',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Campo(controller: ctrl, dica: 'Ex.: Almoço, Uber, Empréstimo Mãe', aoEnviar: (t) => popRoute(context, t)),
          const SizedBox(height: 12),
          _BotaoPrincipal(rotulo: 'Usar', onTap: () => popRoute(context, ctrl.text)),
        ]),
      ),
    );
    ctrl.dispose();
    if (titulo is String) {
      final t = titulo.trim();
      _mudar(MbSugestao(_l.pk, s.categoriaPk,
          subPk: s.subPk, titulo: t.isEmpty ? null : t, vinculoPk: s.vinculoPk, confianca: 1));
    }
  }

  /// O que aconteceu com o pedido à IA para este lançamento (null: a sugestão da IA já está na caixa).
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
        final sugestao = _escolha ?? meuBancoSugestoes.value[_l.pk];
        final alternativas = mbAlternativas(_l, sugestao?.categoriaPk, mbUsoClassificar, op);
        final situacaoIa = _situacaoIa();
        final iguais = mbIguaisNaFila(meuBancoClassificar.value, _l);
        // Salário e rendimento já vêm com a categoria do mês passado: sem "Rachou uma conta?" na frente.
        final parteDeConta = _l.valor > 0 &&
            !mbEhJurosPoupanca(_l) &&
            meuBancoSugestoes.value[_l.pk]?.fonte != MbFonteSugestao.mesPassado;
        // Com o gasto/compra em destaque, a caixa "Sem sugestão" só competiria com ele (as categorias seguem abaixo).
        final ocultarSemSugestao = parteDeConta && _comDestaque && op.categoria(sugestao?.categoriaPk) == null;
        return Opacity(
          opacity: _enviando ? .5 : 1,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(brl(_l.valor),
                style: EdTexto.numeroGrande(context).copyWith(fontSize: 32, color: _l.valor > 0 ? e.pos : e.tx)),
            const SizedBox(height: 6),
            Text([diaMes(_l.data), if (_l.conta.isNotEmpty) _l.conta].join(' · '), style: EdTexto.rotulo(context)),
            const SizedBox(height: 2),
            Text(_l.descricao,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: EdTexto.corpo(context).copyWith(color: e.mu)),
            if (situacaoIa != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                Icon(situacaoIa.icone, size: 14, color: e.mu),
                const SizedBox(width: 6),
                Expanded(child: Text(situacaoIa.texto, style: EdTexto.rotulo(context))),
              ]),
            ],
            const SizedBox(height: 16),
            if (parteDeConta) ...[
              ParteDeConta(
                  lancamento: _l,
                  enviando: _enviando,
                  aoLigar: _ligar,
                  aoDestacar: (v) {
                    if (v != _comDestaque) setState(() => _comDestaque = v);
                  }),
              const SizedBox(height: 12),
            ],
            if (!ocultarSemSugestao) ...[
              _Sugestao(
                lancamento: _l,
                sugestao: sugestao,
                opcoes: op,
                enviando: _enviando,
                aoConfirmar: _confirmar,
                aoMudar: _mudar,
                aoVincular: _escolherVinculo,
                aoEditarTitulo: _editarTitulo,
                iguais: iguais.length,
                aoAplicarIguais: (s) => _aplicarIguais(s, iguais),
              ),
              const SizedBox(height: 16),
            ],
            Text(sugestao == null ? 'Qual é a categoria?' : 'Ou escolha outra', style: EdTexto.h2(context)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in alternativas)
                BotaoEscolha(
                    rotulo: c.nome,
                    onTap: _enviando
                        ? null
                        : () => _mudar((sugestao ?? MbSugestao(_l.pk, c.pk)).comCategoria(c.pk))),
              BotaoEscolha(rotulo: 'Mais…', onTap: _enviando ? null : () => _maisCategorias(sugestao)),
            ]),
            const SizedBox(height: 16),
            Text('Explicar o que foi', style: EdTexto.h2(context)),
            const SizedBox(height: 8),
            _Campo(
              controller: _explicacao,
              dica: 'Ex.: almoço com cliente, empréstimo para a minha mãe',
              aoEnviar: (_) => _entender(),
              sufixo: _entendendo
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(
                      tooltip: 'Entender explicação',
                      onPressed: _enviando ? null : _entender,
                      icon: Icon(Icons.arrow_upward_rounded, color: e.tx)),
            ),
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

/// Caixa da sugestão: de onde veio, a pergunta da IA (se houver), categoria › sub, subcategorias, título, vínculo
/// e "Confirmar".
class _Sugestao extends StatelessWidget {
  const _Sugestao({
    required this.lancamento,
    required this.sugestao,
    required this.opcoes,
    required this.enviando,
    required this.aoConfirmar,
    required this.aoMudar,
    required this.aoVincular,
    required this.aoEditarTitulo,
    required this.iguais,
    required this.aoAplicarIguais,
  });
  final MbLancamentoIa lancamento;
  final MbSugestao? sugestao;
  final MbOpcoes opcoes;
  final bool enviando;
  final int iguais; // este e os outros da fila com o mesmo favorecido
  final void Function(MbSugestao) aoConfirmar, aoMudar, aoVincular, aoEditarTitulo, aoAplicarIguais;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final s = sugestao;
    final cat = opcoes.categoria(s?.categoriaPk);
    final caixa = BoxDecoration(color: e.surf, borderRadius: BorderRadius.circular(12));
    if (s == null || cat == null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: caixa,
        child: Text('Sem sugestão para este. Escolha abaixo ou explique o que foi.', style: EdTexto.rotulo(context)),
      );
    }
    final sub = cat.subs.where((x) => x.pk == s.subPk).firstOrNull;
    final vinculo = opcoes.vinculo(s.vinculoPk);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: caixa,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (s.fonte == MbFonteSugestao.ia || s.fonte == MbFonteSugestao.mesPassado) ...[
            Icon(s.fonte == MbFonteSugestao.ia ? Icons.auto_awesome_rounded : Icons.history_rounded,
                size: 14, color: e.acc),
            const SizedBox(width: 6),
          ],
          Expanded(
              child: Text(_rotuloFonte[s.fonte]!,
                  style: EdTexto.rotulo(context)
                      .copyWith(color: s.fonte == MbFonteSugestao.mesPassado ? e.acc : null))),
          if (s.fonte == MbFonteSugestao.ia || s.fonte == MbFonteSugestao.padrao)
            Text('${(s.confianca * 100).round()}% · ${s.confianca >= mbLimiarPergunta ? 'confiante' : 'na dúvida'}',
                style: EdTexto.mono(context).copyWith(color: s.confianca >= mbLimiarPergunta ? e.acc : e.warntx)),
        ]),
        if (s.pergunta != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(s.pergunta!,
                style: EdTexto.corpo(context).copyWith(fontSize: 15, fontWeight: FontWeight.w500, height: 1.3)),
          ),
        ],
        const SizedBox(height: 8),
        Text(sub == null ? cat.nome : '${cat.nome} › ${sub.nome}',
            style: EdTexto.corpo(context).copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
        if (cat.subs.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final x in cat.subs)
              _ChipSub(
                rotulo: x.nome,
                marcado: x.pk == s.subPk,
                onTap: enviando
                    ? null
                    : () => aoMudar(MbSugestao(lancamento.pk, s.categoriaPk,
                        subPk: x.pk == s.subPk ? null : x.pk,
                        titulo: s.titulo,
                        vinculoPk: s.vinculoPk,
                        confianca: 1)),
              ),
          ]),
        ],
        const SizedBox(height: 10),
        _Linha(
            icone: Icons.short_text_rounded,
            texto: 'Título: ${s.titulo ?? nomeSemEspacosRepetidos(lancamento.descricao)}',
            iconeFim: Icons.edit_outlined,
            dica: 'Editar título',
            onTap: enviando ? null : () => aoEditarTitulo(s)),
        if (opcoes.vinculos.isNotEmpty)
          _Linha(
              icone: Icons.link_rounded,
              texto: vinculo == null
                  ? 'Vincular a empréstimo ou meta'
                  : '${vinculo.tipo == 'emprestimo' ? 'Empréstimo' : 'Meta'}: ${vinculo.nome}',
              onTap: enviando ? null : () => aoVincular(s)),
        const SizedBox(height: 10),
        _BotaoPrincipal(rotulo: 'Confirmar', onTap: enviando ? null : () => aoConfirmar(s)),
        if (iguais > 1) ...[
          const SizedBox(height: 8),
          _BotaoPrincipal(
              rotulo: 'Aplicar a todos os $iguais iguais',
              secundario: true,
              onTap: enviando ? null : () => aoAplicarIguais(s)),
        ],
      ]),
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
              Text(destaque.nome,
                  maxLines: 1,
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
            Text('${diaMes(itens.last.data)} a ${diaMes(itens.first.data)} · ${itens.first.descricao}',
                maxLines: 2, overflow: TextOverflow.ellipsis, style: EdTexto.corpo(context).copyWith(color: e.mu)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              decoration: BoxDecoration(color: e.surf, borderRadius: BorderRadius.circular(12)),
              child: escolha == null || cat == null
                  ? Text('Escolha a categoria abaixo.', style: EdTexto.rotulo(context))
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(_rotuloFonte[escolha.fonte]!, style: EdTexto.rotulo(context)),
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

/// Uma linha da lista "Aplicar a N iguais": descrição, data e conta, valor.
class _LinhaLancamento extends StatelessWidget {
  const _LinhaLancamento({required this.lancamento});
  final MbLancamentoIa lancamento;

  @override
  Widget build(BuildContext context) {
    final l = lancamento;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(nomeSemEspacosRepetidos(l.descricao),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: EdTexto.corpo(context)),
            Text([diaMes(l.data), if (l.conta.isNotEmpty) l.conta].join(' · '), style: EdTexto.rotulo(context)),
          ]),
        ),
        const SizedBox(width: 8),
        Text(brl(l.valor), style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

class _ChipSub extends StatelessWidget {
  const _ChipSub({required this.rotulo, required this.marcado, this.onTap});
  final String rotulo;
  final bool marcado;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Semantics(
      button: true,
      selected: marcado,
      label: rotulo,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: marcado ? e.tx : e.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: marcado ? e.tx : e.line),
          ),
          child: Text(rotulo,
              style: EdTexto.corpo(context).copyWith(fontSize: 13, color: marcado ? e.bg : e.tx)),
        ),
      ),
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
        constraints: const BoxConstraints(minHeight: 40),
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
      height: 44,
      child: FilledButton(
        style: FilledButton.styleFrom(
            backgroundColor: secundario ? e.bg : e.tx,
            foregroundColor: secundario ? e.tx : e.bg,
            side: secundario ? BorderSide(color: e.line) : null,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
        onPressed: onTap,
        child: Text(rotulo, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _Campo extends StatelessWidget {
  const _Campo({required this.controller, required this.dica, required this.aoEnviar, this.sufixo});
  final TextEditingController controller;
  final String dica;
  final ValueChanged<String> aoEnviar;
  final Widget? sufixo;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return TextField(
      controller: controller,
      maxLength: 300,
      minLines: 1,
      maxLines: 3,
      textInputAction: TextInputAction.send,
      onSubmitted: aoEnviar,
      style: EdTexto.corpo(context),
      decoration: InputDecoration(
        hintText: dica,
        hintStyle: EdTexto.corpo(context).copyWith(color: e.mu),
        counterText: '',
        filled: true,
        fillColor: e.chip,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        suffixIcon: sufixo,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      ),
    );
  }
}
