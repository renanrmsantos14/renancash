import 'package:budget/functions.dart' show popRoute;
import 'package:budget/pages/homePage/homePageParaRevisar.dart' show BotaoEscolha;
import 'package:budget/struct/editorial.dart';
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
    if (meuBancoSugestoes.value[_l.pk]?.fonte == MbFonteSugestao.ia) return null;
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
            if (_l.valor > 0) ...[
              ParteDeConta(lancamento: _l, enviando: _enviando, aoLigar: _ligar),
              const SizedBox(height: 12),
            ],
            _Sugestao(
              lancamento: _l,
              sugestao: sugestao,
              opcoes: op,
              enviando: _enviando,
              aoConfirmar: _confirmar,
              aoMudar: _mudar,
              aoVincular: _escolherVinculo,
              aoEditarTitulo: _editarTitulo,
            ),
            const SizedBox(height: 16),
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
  });
  final MbLancamentoIa lancamento;
  final MbSugestao? sugestao;
  final MbOpcoes opcoes;
  final bool enviando;
  final void Function(MbSugestao) aoConfirmar, aoMudar, aoVincular, aoEditarTitulo;

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
          if (s.fonte == MbFonteSugestao.ia) ...[
            Icon(Icons.auto_awesome_rounded, size: 14, color: e.acc),
            const SizedBox(width: 6),
          ],
          Expanded(child: Text(_rotuloFonte[s.fonte]!, style: EdTexto.rotulo(context))),
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
      ]),
    );
  }
}

/// Numa entrada: o gasto em destaque quando o casamento é forte (Pix = parte exata e sem empate) e, sempre, "É a parte
/// de uma conta que eu paguei" com a lista para escolher. Nada é ligado sem o toque.
class ParteDeConta extends StatefulWidget {
  const ParteDeConta({super.key, required this.lancamento, required this.aoLigar, this.enviando = false});
  final MbLancamentoIa lancamento;
  final void Function(MbGastoCandidato) aoLigar;
  final bool enviando;

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
        final forte = mbReembolsoForte(s);
        final pagador = mbChavePadrao(_l.descricao);
        final costuma = pagador.isNotEmpty && meuBancoReembolsos.value.any((v) => v.pagador == pagador);
        final abrir = widget.enviando || snap.connectionState != ConnectionState.done ? null : () => _escolher(s);
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(color: e.surf, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.call_split_rounded, size: 14, color: e.acc),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    forte != null
                        ? 'Parece a parte de uma conta que você pagou'
                        : costuma
                            ? '${mbNomeDoPagador(pagador)} já mandou a parte de outras contas'
                            : 'Rachou uma conta?',
                    style: EdTexto.rotulo(context)),
              ),
            ]),
            if (forte != null) ...[
              const SizedBox(height: 8),
              Text(forte.gasto.nome,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.corpo(context).copyWith(fontSize: 17, fontWeight: FontWeight.w600)),
              Text(
                  [
                    diaMes(forte.gasto.data),
                    if (forte.gasto.categoria.isNotEmpty) forte.gasto.categoria,
                    '${forte.motivos.first} de ${brl(forte.gasto.valor)}',
                  ].join(' · '),
                  style: EdTexto.rotulo(context)),
              const SizedBox(height: 10),
              _BotaoPrincipal(
                  rotulo: 'Confirmar', onTap: widget.enviando ? null : () => widget.aoLigar(forte.gasto)),
            ],
            _Linha(
                icone: Icons.receipt_long_rounded,
                texto: forte != null ? 'É de outra conta' : 'É a parte de uma conta que eu paguei',
                onTap: abrir),
          ]),
        );
      },
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
  const _BotaoPrincipal({required this.rotulo, this.onTap});
  final String rotulo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return SizedBox(
      height: 44,
      child: FilledButton(
        style: FilledButton.styleFrom(
            backgroundColor: e.tx,
            foregroundColor: e.bg,
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
