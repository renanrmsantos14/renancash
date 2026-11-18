import 'dart:async';

import 'package:budget/functions.dart';
import 'package:budget/pages/homePage/inicioEditorial.dart';
import 'package:budget/pages/meuBancoPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/tipoMovimento.dart';
import 'package:budget/struct/mbSync/emprestimos.dart' show meuBancoEmprestimos;
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/mbSync/orcamentos.dart' show mbMudouGeral;
import 'package:budget/struct/mbSync/revisao.dart' show mbAtualizarRevisar;
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/editorial/buscaRapida.dart';
import 'package:budget/widgets/editorial/detalheTransacao.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart' show SnackbarMessage;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:budget/struct/pendenciasVencidas.dart' show mbVigiarVencidas;
import 'package:budget/struct/ajustesInicio.dart';
import 'package:budget/widgets/util/checkWidgetLaunch.dart';
import 'package:budget/database/generatePreviewData.dart' show PreviewDemoWarning;

Future<void> mbAtualizarComAviso() async =>
    openSnackbar(SnackbarMessage(title: await meuBancoAtualizar()));

class PainelDesktop extends StatefulWidget {
  const PainelDesktop({super.key})
      : _modelo = null,
        _transacoes = const [],
        _metas = null,
        _patrimonio = null,
        _limites = null;
  const PainelDesktop.comDados(ModeloInicio modelo,
      {super.key,
      List<TransacaoInicio> transacoes = const [],
      List<({String nome, double total, double alvo})>? metas,
      PatrimonioInicio? patrimonio,
      List<LimiteInicio>? limites})
      : _modelo = modelo,
        _transacoes = transacoes,
        _metas = metas,
        _patrimonio = patrimonio,
        _limites = limites;

  final ModeloInicio? _modelo;
  final List<TransacaoInicio> _transacoes;
  final List<({String nome, double total, double alvo})>? _metas;
  final PatrimonioInicio? _patrimonio;
  final List<LimiteInicio>? _limites;

  @override
  State<PainelDesktop> createState() => _PainelDesktopState();
}

class _PainelDesktopState extends State<PainelDesktop> {
  ModeloInicio? _modelo;
  List<TransacaoInicio> _transacoes = const [];
  bool _atualizando = false;
  final _assinaturas = <StreamSubscription<void>>[];
  late final RecargaColapsada _recarga = RecargaColapsada(_carregar);

  @override
  void initState() {
    super.initState();
    if (widget._modelo != null) {
      _modelo = widget._modelo;
      _transacoes = widget._transacoes;
      _publicarLista();
    } else {
      mbAtualizarRevisar();
      meuBancoUltimaSync.addListener(_recarga.pedir);
      mbAjustesMudaram.addListener(_aoMudarAjustes);
      if (AjustesInicio.vencidas) mbVigiarVencidas();
      // O 1º evento do stream já faz a carga inicial (sem corrida com uma gravação entre duas leituras).
      // O limite do ciclo vem do Geral: editar o Geral também recarrega.
      _assinaturas.addAll([
        mbMudouUltimas().listen((_) => _recarga.pedir()),
        mbMudouGeral().listen((_) => _recarga.pedir()),
      ]);
    }
  }

  // Configurações › Início: redesenha (ritmo, saldo, metas) e recarrega (poupanças juntas ou não).
  void _aoMudarAjustes() {
    if (!mounted) return;
    setState(() {});
    _recarga.pedir();
  }

  @override
  void dispose() {
    meuBancoUltimaSync.removeListener(_recarga.pedir);
    mbAjustesMudaram.removeListener(_aoMudarAjustes);
    for (final a in _assinaturas) {
      a.cancel();
    }
    _recarga.fechar();
    mbListaVisivel.value = const [];
    super.dispose();
  }

  void _publicarLista() {
    mbListaVisivel.value = [
      for (final t in _transacoes) t.transaction.transactionPk
    ];
  }

  Future<void> _carregar() async {
    final r = await mbCarregarModeloInicio(
        '${appStateSettings["username"] ?? ""}', DateTime.now());
    if (!mounted ||
        (r.modelo == _modelo && listEquals(r.transacoes, _transacoes))) {
      return;
    }
    setState(() {
      _modelo = r.modelo;
      _transacoes = r.transacoes;
    });
    _publicarLista();
  }

  Future<void> _atualizar() async {
    if (_atualizando) return;
    setState(() => _atualizando = true);
    await mbAtualizarComAviso();
    if (mounted) setState(() => _atualizando = false);
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final m = _modelo;
    final real = widget._modelo == null;
    return ColoredBox(
      color: e.bg,
      child: m == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.fromLTRB(36, 28, 36, 40),
              children: [
                // Android em tela larga (tablet): widgets da tela inicial e toques neles.
                if (real) const AndroidOnly(child: CheckWidgetLaunch()),
                if (real) const AndroidOnly(child: RenderHomePageWidgets()),
                const PreviewDemoWarning(),
                _Topo(
                    modelo: m,
                    atualizando: _atualizando,
                    onAtualizar: _atualizar),
                const SizedBox(height: 28),
                // Mesmas seções do celular em duas colunas: ciclo, atalhos, gráfico e "Seu dinheiro" à esquerda,
                // limites, metas, empréstimos e transações à direita.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (m.semDados)
                            const SemDadosInicio(
                                dica: 'Ainda sem dados. Use Atualizar.')
                          else
                            CartaoSaldoCiclo(
                              modelo: m,
                              onTap: real
                                  ? () => mbAbrirOrcamentoCiclo(context,
                                      editar: false)
                                  : null,
                              onDefinirLimite: () =>
                                  mbAbrirOrcamentoCiclo(context, editar: true),
                            ),
                          if (!m.semDados) const AlertaPendenciasInicio(),
                          if (real || meuBancoPareadoConferido.value)
                            const AtalhosInicio(),
                          GastoPorDiaInicio(modelo: m),
                          // Empilhado na coluna estreita e sempre aberto.
                          if (!m.semDados && (real || widget._patrimonio != null))
                            BancosPorBanco(
                                fixo: widget._patrimonio,
                                recolher: false,
                                onAbrir: real
                                    ? (c) => mbAbrirCarteiras(context, c)
                                    : null),
                        ],
                      ),
                    ),
                    const SizedBox(width: 40),
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (real || widget._limites != null)
                            LimitesInicio(fixos: widget._limites),
                          // Metas leem o banco local; nos testes/prints pode receber metas fixas.
                          if (real ||
                              widget._metas != null ||
                              meuBancoEmprestimos.value.abertos.isNotEmpty)
                            MetasEmprestimosInicio(metas: widget._metas),
                          Padding(
                              padding: const EdgeInsets.only(top: 20),
                              child: _Tabela(transacoes: _transacoes)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _Topo extends StatelessWidget {
  const _Topo(
      {required this.modelo,
      required this.atualizando,
      required this.onAtualizar});
  final ModeloInicio modelo;
  final bool atualizando;
  final VoidCallback onAtualizar;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(modelo.periodo, style: EdTexto.rotulo(context)),
              const SizedBox(height: 6),
              Text(modelo.saudacao, style: EdTexto.h1(context)),
            ],
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Semantics(
                button: true,
                label: 'Buscar ou ir para',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => abrirBuscaRapida(),
                  child: SizedBox(
                    height: 44,
                    child: Center(
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                            color: e.surf,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: e.line)),
                        child: Row(
                          children: [
                            Icon(Icons.search, size: 16, color: e.mu),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text('Buscar ou ir para…',
                                    overflow: TextOverflow.clip,
                                    maxLines: 1,
                                    style: EdTexto.corpo(context)
                                        .copyWith(color: e.mu, fontSize: 13))),
                            Text('Ctrl K', style: EdTexto.mono(context)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          height: 44,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
                foregroundColor: e.tx,
                side: BorderSide(color: e.line),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            onPressed: atualizando ? null : onAtualizar,
            child: Text(atualizando ? 'Atualizando…' : 'Atualizar'),
          ),
        ),
      ],
    );
  }
}

class _Tabela extends StatelessWidget {
  const _Tabela({required this.transacoes});
  final List<TransacaoInicio> transacoes;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final agora = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
                child: Text('Últimas transações', style: EdTexto.h2(context))),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => mbIrParaPagina(1),
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Text('Ver todas',
                        style: EdTexto.rotulo(context).copyWith(color: e.acc)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: e.line)),
                      child: Text('T', style: EdTexto.mono(context)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
                flex: 5,
                child: Text('DESCRIÇÃO', style: EdTexto.mono(context))),
            Expanded(
                flex: 3,
                child: Text('CATEGORIA', style: EdTexto.mono(context))),
            Expanded(
                flex: 3,
                child: Text('VALOR',
                    textAlign: TextAlign.end, style: EdTexto.mono(context))),
          ],
        ),
        const SizedBox(height: 6),
        Divider(height: 1, thickness: 1, color: e.line),
        if (transacoes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('Nenhuma transação ainda.',
                style: EdTexto.rotulo(context)),
          ),
        for (final t in transacoes)
          ValueListenableBuilder<String?>(
            valueListenable: mbTransacaoSelecionada,
            builder: (context, sel, _) {
              final x = t.transaction;
              final ativa = sel == x.transactionPk;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => mbTransacaoSelecionada.value = x.transactionPk,
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.only(left: 10, right: 4),
                  decoration: BoxDecoration(
                    color: ativa ? e.surf : null,
                    border: Border(
                      left: BorderSide(
                          color: ativa ? e.acc : Colors.transparent, width: 2),
                      bottom: BorderSide(color: e.line),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(x.name,
                                overflow: TextOverflow.ellipsis,
                                style: EdTexto.corpo(context)
                                    .copyWith(fontWeight: FontWeight.w500)),
                            Text(quandoRelativo(x.dateCreated, agora),
                                style: EdTexto.rotulo(context)),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ChipCategoria(t.category.name,
                              receita: x.income,
                              alerta: t.category.name == 'Sem categoria'),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          IconeTipo(mbTipoDaTransacao(x, t.category.name), tamanho: 22),
                          const SizedBox(width: 8),
                          Text('${x.income ? '+' : '−'}${brl(x.amount.abs())}',
                              textAlign: TextAlign.end,
                              style: EdTexto.corpo(context).copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: mbTipoDaTransacao(x, t.category.name).cor(context))),
                        ]),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
