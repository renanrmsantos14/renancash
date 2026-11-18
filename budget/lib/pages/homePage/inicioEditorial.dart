import 'dart:async';
import 'dart:math' show max;

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/budgetsListPage.dart';
import 'package:budget/pages/editWalletsPage.dart';
import 'package:budget/pages/budgetPage.dart';
import 'package:budget/pages/meuBancoPage.dart';
import 'package:budget/pages/objectivePage.dart';
import 'package:budget/pages/objectivesListPage.dart';
import 'package:budget/pages/transactionFilters.dart' show SearchFilters;
import 'package:budget/pages/transactionsSearchPage.dart';
import 'package:budget/pages/walletDetailsPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/casosComuns.dart' show MbAtalhoRapido;
import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/mbSync/orcamentos.dart'
    show mbMudouGeral, mbOrcamentoGeralPk;
import 'package:budget/struct/mbSync/revisao.dart' show mbAtualizarRevisar;
import 'package:budget/struct/ritmoCiclo.dart' show textoIdealHoje;
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/budgetContainer.dart' show BarraOrcamento;
import 'package:budget/widgets/editorial/lancamentoRapido.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/editorial/painelTransacao.dart' show abrirTransacao;
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/functions.dart';
import 'package:budget/widgets/navigationFramework.dart' show runAllCloudFunctions;
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/pullDownToRefreshSync.dart' show enableSwipeDownToRefresh;
import 'package:budget/widgets/util/checkWidgetLaunch.dart';
import 'package:flutter/material.dart';
import 'package:budget/struct/pendenciasVencidas.dart' show mbVigiarVencidas;
import 'package:budget/struct/ajustesInicio.dart';
import 'package:budget/database/generatePreviewData.dart' show PreviewDemoWarning;

/// Início do celular: responde "quanto posso gastar neste ciclo".
/// Layout fixo; blocos sem dados somem. Spec: docs/superpowers/specs/2026-11-13-nova-inicio.md.
class InicioEditorial extends StatefulWidget {
  const InicioEditorial({super.key})
      : _modelo = null,
        _atalhos = null,
        _metas = null;
  const InicioEditorial.comModelo(
    ModeloInicio modelo, {
    super.key,
    List<MbAtalhoRapido>? atalhos,
    List<({String nome, double total, double alvo})>? metas,
  })  : _modelo = modelo,
        _atalhos = atalhos,
        _metas = metas;
  final ModeloInicio? _modelo;
  final List<MbAtalhoRapido>? _atalhos;
  final List<({String nome, double total, double alvo})>? _metas;

  @override
  State<InicioEditorial> createState() => _InicioEditorialState();
}

class _InicioEditorialState extends State<InicioEditorial> {
  ModeloInicio? _modelo;
  final _assinaturas = <StreamSubscription<void>>[];
  late final RecargaColapsada _recarga = RecargaColapsada(_carregar);
  bool get _real => widget._modelo == null;

  @override
  void initState() {
    super.initState();
    _modelo = widget._modelo;
    if (_real) {
      meuBancoVerificarPareado();
      mbAtualizarRevisar(); // preenche os empréstimos em aberto
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
    super.dispose();
  }

  Future<void> _carregar() async {
    final r = await mbCarregarModeloInicio(
        '${appStateSettings["username"] ?? ""}', DateTime.now());
    if (!mounted || r.modelo == _modelo) return;
    setState(() => _modelo = r.modelo);
  }

  // Puxar a tela: o indicador do RefreshIndicator volta na hora; o progresso
  // aparece na linha fina do topo (meuBancoSincronizando).
  Future<void> _puxar() async {
    if (enableSwipeDownToRefresh(context)) runAllCloudFunctions(context);
    // O aviso é sobre a Início: se o usuário já abriu outra tela (ex.: uma meta), não cobre o título dela.
    unawaited(meuBancoAtualizar().then((msg) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        openSnackbar(SnackbarMessage(title: msg));
      }
    }));
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final m = _modelo;
    final Widget corpo;
    if (m == null) {
      // Primeiro uso, sem nada salvo no aparelho.
      corpo = Center(
          child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2, color: e.mu)));
    } else {
      final lista = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
        children: [
          const PreviewDemoWarning(),
          _Topo(modelo: m),
          const SizedBox(height: 16),
          if (m.semDados)
            const SemDadosInicio(dica: 'Ainda sem dados. Puxe a tela para atualizar.')
          else
            CartaoSaldoCiclo(
              modelo: m,
              onTap: _real ? () => mbAbrirOrcamentoCiclo(context, editar: false) : null,
              onDefinirLimite: () => mbAbrirOrcamentoCiclo(context, editar: true),
            ),
          if (_real || widget._atalhos != null)
            LancamentoRapidoInicio(atalhos: widget._atalhos),
          if (_real || meuBancoPareadoConferido.value) const AtalhosInicio(),
          if (_real ||
              widget._metas != null ||
              meuBancoEmprestimos.value.abertos.isNotEmpty)
            MetasEmprestimosInicio(metas: widget._metas),
          if (m.contas.isNotEmpty)
            ContasInicio(
                modelo: m,
                onGerenciar: () => pushRoute(context, const MeuBancoPage()),
                onAbrirConta: _real ? (c) => mbAbrirConta(context, c) : null),
        ],
      );
      corpo = _real ? RefreshIndicator(onRefresh: _puxar, child: lista) : lista;
    }
    return ColoredBox(
      color: e.bg,
      child: Stack(
        children: [
          if (_real) const AndroidOnly(child: CheckWidgetLaunch()),
          if (_real) const AndroidOnly(child: RenderHomePageWidgets()),
          SafeArea(bottom: false, child: corpo),
          if (_real)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ValueListenableBuilder<bool>(
                valueListenable: meuBancoSincronizando,
                builder: (context, sincronizando, _) => sincronizando
                    ? LinearProgressIndicator(
                        minHeight: 2,
                        color: e.acc,
                        backgroundColor: Colors.transparent)
                    : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
  }
}

// O Geral pode ainda não existir (aparelho não pareado e sem sync): aí não abre nada.
Future<void> mbAbrirOrcamentoCiclo(BuildContext context,
  {required bool editar}) async {
  final Budget geral;
  try {
    geral = await database.getBudgetInstance(mbOrcamentoGeralPk);
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  pushRoute(
      context,
      editar
          ? AddBudgetPage(
              budget: geral,
              routesToPopAfterDelete: RoutesToPopAfterDelete.None)
          : BudgetPage(budgetPk: geral.budgetPk));
}

/// Uma carteira: abre o detalhe da conta. Várias (Poupanças juntas): as transações delas.
/// Sem carteira no aparelho, cai no Meu Banco.
Future<void> mbAbrirConta(BuildContext context, ContaInicio c) async {
  final pks = [
    for (final pk in c.carteiras.split('|').toSet())
      if (pk.isNotEmpty && await database.getWalletInstanceOrNull(pk) != null) pk
  ];
  if (!context.mounted) return;
  pushRoute(
      context,
      switch (pks) {
        [] => const MeuBancoPage(),
        [final pk] => WatchedWalletDetailsPage(walletPk: pk),
        _ => TransactionsSearchPage(initialFilters: SearchFilters(walletPks: pks)),
      });
}

/// Sem dados: pareado, ainda não sincronizou (`dica`); não pareado, convite para conectar o banco.
class SemDadosInicio extends StatelessWidget {
  const SemDadosInicio({super.key, required this.dica});
  final String dica;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return ValueListenableBuilder<bool>(
      valueListenable: meuBancoPareado,
      builder: (context, pareado, _) => pareado
          ? Text(dica, style: EdTexto.corpo(context).copyWith(color: e.mu))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Conecte seu banco para ver quanto pode gastar no ciclo.',
                  style: EdTexto.corpo(context).copyWith(color: e.mu)),
              TextButton(
                onPressed: () => pushRoute(context, const MeuBancoPage()),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, foregroundColor: e.acc),
                child: const Text('Conectar banco'),
              ),
            ]),
    );
  }
}

/// Sem banco conectado: atalhos para o uso manual, em grade 2×2.
/// Some quando o banco é conectado ou com Configurações › Início › Mostrar atalhos sem banco desligado.
class AtalhosInicio extends StatelessWidget {
  const AtalhosInicio({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge(
            [meuBancoPareado, meuBancoPareadoConferido, mbAjustesMudaram]),
        builder: (context, _) {
          if (!meuBancoPareadoConferido.value ||
              meuBancoPareado.value ||
              !AjustesInicio.atalhos) {
            return const SizedBox.shrink();
          }
          Widget linha(_Atalho a, _Atalho b) => IntrinsicHeight(
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: a),
                      const SizedBox(width: 10),
                      Expanded(child: b),
                    ]),
              );
          return Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Column(children: [
              linha(
                _Atalho(Icons.add, 'Nova transação',
                    () => abrirTransacao(context)),
                _Atalho(Icons.account_balance_wallet_outlined, 'Contas',
                    () => pushRoute(context, EditWalletsPage())),
              ),
              const SizedBox(height: 10),
              linha(
                _Atalho(
                    Icons.donut_large_outlined,
                    'Orçamentos',
                    () => pushRoute(
                        context, const BudgetsListPage(enableBackButton: true))),
                _Atalho(
                    Icons.flag_outlined,
                    'Metas',
                    () => pushRoute(
                        context, const ObjectivesListPage(backButton: true))),
              ),
            ]),
          );
        },
      );
}

/// Os gastos que mais se repetem nos últimos 90 dias (título, categoria e valor mais comum), até 6, em grade de 3:
/// um toque abre o teclado de valor já preenchido e "Lançar" grava. Some sem atalhos ou com Configurações › Início ›
/// Mostrar lançamento rápido desligado.
class LancamentoRapidoInicio extends StatefulWidget {
  const LancamentoRapidoInicio({super.key, this.atalhos});
  final List<MbAtalhoRapido>? atalhos; // prints: sem banco

  @override
  State<LancamentoRapidoInicio> createState() => _LancamentoRapidoInicioState();
}

class _LancamentoRapidoInicioState extends State<LancamentoRapidoInicio> {
  late List<MbAtalhoRapido> _atalhos = widget.atalhos ?? const [];

  @override
  void initState() {
    super.initState();
    if (widget.atalhos != null) return;
    _carregar();
    meuBancoUltimaSync.addListener(_carregar);
  }

  @override
  void dispose() {
    meuBancoUltimaSync.removeListener(_carregar);
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      final a = await mbCarregarAtalhosRapidos();
      if (mounted) setState(() => _atalhos = a);
    } catch (_) {} // sem atalhos: a seção some
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: mbAjustesMudaram,
        builder: (context, _) {
          if (!AjustesInicio.lancamentoRapido || _atalhos.isEmpty) {
            return const SizedBox.shrink();
          }
          return _Secao(
            titulo: 'Lançar rápido',
            divisores: false,
            filhos: [
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: LayoutBuilder(
                  builder: (context, c) => Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final a in _atalhos)
                      SizedBox(
                        width: (c.maxWidth - 16) / 3,
                        child: _AtalhoRapido(
                            atalho: a,
                            onTap: () async {
                              if (await mbLancarRapido(context, a)) _carregar();
                            }),
                      ),
                  ]),
                ),
              ),
            ],
          );
        },
      );
}

class _AtalhoRapido extends StatelessWidget {
  const _AtalhoRapido({required this.atalho, required this.onTap});
  final MbAtalhoRapido atalho;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final titulo = mbTituloAtalho(atalho.titulo);
    return Semantics(
      button: true,
      label: 'Lançar $titulo, ${brl(atalho.valor)}',
      excludeSemantics: true,
      onTap: onTap,
      child: ToqueEscala(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(color: e.chip, borderRadius: BorderRadius.circular(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(titulo,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500, height: 1.2)),
              const SizedBox(height: 4),
              Text(brl(atalho.valor), style: EdTexto.mono(context).copyWith(color: e.mu)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Atalho extends StatelessWidget {
  const _Atalho(this.icone, this.rotulo, this.onTap);
  final IconData icone;
  final String rotulo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Semantics(
      button: true,
      label: rotulo,
      excludeSemantics: true,
      onTap: onTap,
      child: ToqueEscala(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
              color: e.chip, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(icone, size: 20, color: e.tx),
            const SizedBox(width: 10),
            Expanded(
              child: Text(rotulo,
                  maxLines: 2,
                  style: EdTexto.corpo(context)
                      .copyWith(fontWeight: FontWeight.w500)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Topo extends StatelessWidget {
  const _Topo({required this.modelo});
  final ModeloInicio modelo;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(modelo.periodo, style: EdTexto.rotulo(context)),
          const SizedBox(height: 6),
          Text(modelo.saudacao, style: EdTexto.h1(context)),
        ],
      );
}

/// Cartão escuro de saldo: o único bloco pesado da tela.
/// Com limite: quanto resta do ciclo. Sem limite: o saldo das contas.
class CartaoSaldoCiclo extends StatelessWidget {
  const CartaoSaldoCiclo(
      {super.key,
      required this.modelo,
      this.onTap,
      this.onDefinirLimite,
      this.lateral});
  final ModeloInicio modelo;
  final VoidCallback? onTap, onDefinirLimite;

  /// Computador: conteúdo à direita do saldo, separado por uma linha vertical.
  final Widget? lateral;

  @override
  Widget build(BuildContext context) {
    final limite = modelo.limite;
    final saldo = limite != null && limite > 0
        ? _Restante(modelo: modelo, limite: limite)
        : _SemLimite(modelo: modelo, onDefinirLimite: onDefinirLimite);
    final cartao = lateral == null
        ? CartaoEscuro(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16), child: saldo)
        : CartaoEscuro(
            padding: const EdgeInsets.all(28),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: saldo),
                Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 32),
                    color: cores(context).line),
                Expanded(child: lateral!),
              ]),
            ),
          );
    if (onTap == null) return cartao;
    return Semantics(
        button: true,
        label: 'Abrir orçamento do ciclo',
        child: ToqueEscala(onTap: onTap, child: cartao));
  }
}

class _Restante extends StatelessWidget {
  const _Restante({required this.modelo, required this.limite});
  final ModeloInicio modelo;
  final double limite;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final restante = limite - modelo.consumido;
    final estourou = restante < 0;
    // diasRestantes não conta hoje; aqui hoje entra, como no cartão do orçamento (último dia = 1).
    final dias = max(0, modelo.diasRestantes) + 1;
    final quando = dias == 1 ? 'último dia' : 'faltam $dias dias';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(estourou ? 'Acima do limite do ciclo' : 'Para gastar no ciclo',
            style: EdTexto.rotulo(context)),
        const SizedBox(height: 8),
        ContagemValor(
            valor: restante.abs(),
            formatar: brl,
            centavosMenores: true,
            estilo: EdTexto.numeroGrande(context)
                .copyWith(color: estourou ? e.warn : null)),
        const SizedBox(height: 14),
        BarraOrcamento(
            gasto: modelo.consumido,
            limite: limite,
            aVencer: modelo.aVencer,
            hoje: modelo.fracaoHoje,
            alerta: estourou),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text('Gasto ${brl(modelo.consumido)} de ${brl(limite)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.rotulo(context)),
            ),
            const SizedBox(width: 8),
            Text(quando, style: EdTexto.rotulo(context)),
          ],
        ),
        if (modelo.fracaoHoje case final fracao?) ...[
          const SizedBox(height: 4),
          Text(textoIdealHoje(modelo.consumido, limite, fracao, brl),
              maxLines: 2, style: EdTexto.rotulo(context)),
        ],
        if (!estourou && AjustesInicio.ritmoDiario) ...[
          const SizedBox(height: 10),
          Text('Pode gastar ${brl(restante / dias)}/dia',
              style: EdTexto.corpo(context)
                  .copyWith(fontWeight: FontWeight.w500)),
        ],
        if (AjustesInicio.saldoContas) ...[
          const SizedBox(height: 4),
          Text('Nas contas ${brl(modelo.disponivel)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: EdTexto.rotulo(context)),
        ],
      ],
    );
  }
}

class _SemLimite extends StatelessWidget {
  const _SemLimite({required this.modelo, this.onDefinirLimite});
  final ModeloInicio modelo;
  final VoidCallback? onDefinirLimite;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final origem = modelo.origemDisponivel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
            origem.isEmpty
                ? 'Disponível nas contas'
                : 'Disponível nas contas · $origem',
            // Duas linhas: com banco, poupanças e "há x min" não cabe numa só no celular.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: EdTexto.rotulo(context)),
        const SizedBox(height: 8),
        ContagemValor(
            valor: modelo.disponivel,
            formatar: brl,
            centavosMenores: true,
            estilo: EdTexto.numeroGrande(context)),
        const SizedBox(height: 10),
        Text('Gasto no ciclo ${brl(modelo.consumido)}',
            style: EdTexto.rotulo(context)),
        if (onDefinirLimite != null)
          TextButton(
            onPressed: onDefinirLimite,
            style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                foregroundColor: e.acc),
            child: const Text('Definir limite do ciclo'),
          ),
      ],
    );
  }
}

/// Metas (não arquivadas) e empréstimos ao pai em aberto, em grupos de até 2 linhas.
/// Com um grupo só, ele dá o título do bloco e o subtítulo some. Sem nada, o bloco some.
class MetasEmprestimosInicio extends StatefulWidget {
  const MetasEmprestimosInicio({super.key, this.colunaFlex, this.metas});

  /// Computador: vira uma coluna `Expanded(flex)` de uma Row, com 40 px à direita.
  /// Vazio, não ocupa a coluna.
  final int? colunaFlex;
  final List<({String nome, double total, double alvo})>? metas;

  @override
  State<MetasEmprestimosInicio> createState() => _MetasEmprestimosInicioState();
}

class _MetasEmprestimosInicioState extends State<MetasEmprestimosInicio> {
  // Criado uma vez: recriar no build reassinaria a consulta a cada recarga da Início.
  late final Stream<List<Objective>> _metas = database.watchAllObjectives(
      objectiveType: ObjectiveType.goal, hideArchived: true);

  Widget _construir(
      BuildContext context, List<Objective> metasDb, MbEmprestimos emprestimos) {
    final fixas = widget.metas;
    final temMetas = fixas != null ? fixas.isNotEmpty : metasDb.isNotEmpty;
    final qtdMetas = fixas != null ? fixas.length : metasDb.length;
    final abertos = emprestimos.abertos;
    if (!temMetas && abertos.isEmpty) return const SizedBox.shrink();
    final unico = !temMetas || abertos.isEmpty;
    final n = AjustesInicio.linhasMetas;
    final grupos = [
      if (temMetas)
        _Grupo(
          titulo: 'Metas',
          subtitulo: !unico,
          acao: qtdMetas > n ? 'Ver todas' : null,
          onAcao: () =>
              pushRoute(context, const ObjectivesListPage(backButton: true)),
          linhas: [
            if (fixas != null)
              for (final m in fixas.take(n))
                _LinhaProgresso(
                  titulo: m.nome,
                  valor: '${brl(m.total)} de ${brl(m.alvo)}',
                  fracao: m.alvo > 0 ? m.total / m.alvo : 0,
                )
            else
              for (final o in metasDb.take(n))
                WatchTotalAndAmountOfObjective(
                  objective: o,
                  builder: (alvo, total, fracao) => _LinhaProgresso(
                    titulo: o.name,
                    valor: '${brl(total)} de ${brl(alvo)}',
                    fracao: fracao,
                    onTap: () => pushRoute(
                        context, ObjectivePage(objectivePk: o.objectivePk)),
                  ),
                ),
          ],
        ),
      if (abertos.isNotEmpty)
        _Grupo(
          titulo: 'Empréstimos',
          subtitulo: !unico,
          nota: abertos.length > n ? 'mais ${abertos.length - n}' : null,
          linhas: [
            for (final e in abertos.take(n))
              _LinhaProgresso(
                titulo: switch (DateTime.tryParse(e.data ?? '')) {
                  final d? => 'Empréstimo de ${diaMes(d)}',
                  null => 'Empréstimo',
                },
                valor: 'Falta ${brl(e.restante)}',
                fracao: e.original > 0 ? 1 - e.restante / e.original : 0,
              ),
          ],
        ),
    ];
    final bloco = _Secao(
      titulo: unico ? grupos.single.titulo : 'Metas e empréstimos',
      divisores: false,
      filhos: grupos,
    );
    final flex = widget.colunaFlex;
    return flex == null
        ? bloco
        : Expanded(
            flex: flex,
            child: Padding(
                padding: const EdgeInsets.only(right: 40), child: bloco));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.metas != null) {
      return ValueListenableBuilder<MbEmprestimos>(
        valueListenable: meuBancoEmprestimos,
        builder: (context, emprestimos, _) =>
            _construir(context, const <Objective>[], emprestimos),
      );
    }
    return StreamBuilder<List<Objective>>(
      stream: _metas,
      builder: (context, snap) => ValueListenableBuilder<MbEmprestimos>(
        valueListenable: meuBancoEmprestimos,
        builder: (context, emprestimos, _) =>
            _construir(context, snap.data ?? const <Objective>[], emprestimos),
      ),
    );
  }
}

/// Subtítulo pequeno com ação (ou nota) à direita e as linhas do grupo com divisória.
/// Sem subtítulo (grupo único), a ação e a nota ficam ao lado das linhas, no mesmo lugar.
class _Grupo extends StatelessWidget {
  const _Grupo(
      {required this.titulo,
      required this.linhas,
      this.acao,
      this.onAcao,
      this.nota,
      required this.subtitulo});
  final String titulo;
  final String? acao, nota;
  final VoidCallback? onAcao;
  final List<Widget> linhas;
  final bool subtitulo;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final direita = acao != null
        ? GestureDetector(
            onTap: onAcao,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(acao!,
                  style: EdTexto.rotulo(context).copyWith(color: e.acc)),
            ),
          )
        : nota == null
            ? null
            : Text(nota!, style: EdTexto.rotulo(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (subtitulo || direita != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Expanded(
                  child: subtitulo
                      ? Text(titulo, style: EdTexto.rotulo(context))
                      : const SizedBox.shrink()),
              if (direita != null) direita,
            ]),
          ),
        for (var i = 0; i < linhas.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: e.line),
          linhas[i],
        ],
      ],
    );
  }
}

class _LinhaProgresso extends StatelessWidget {
  const _LinhaProgresso(
      {required this.titulo,
      required this.valor,
      required this.fracao,
      this.onTap});
  final String titulo, valor;
  final double fracao;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ToqueEscala(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(titulo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context)
                        .copyWith(fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 8),
              Text(valor, style: EdTexto.rotulo(context)),
            ]),
            const SizedBox(height: 8),
            MedidorEditorial(fracao: fracao),
          ],
        ),
      ),
    );
  }
}

/// Título de bloco (h2) com ação opcional à direita e os filhos separados por linha.
class _Secao extends StatelessWidget {
  const _Secao(
      {required this.titulo,
      required this.filhos,
      this.acao,
      this.onAcao,
      this.divisores = true});
  final String titulo;
  final bool divisores;
  final String? acao;
  final VoidCallback? onAcao;
  final List<Widget> filhos;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: Text(titulo, style: EdTexto.h2(context))),
            if (acao != null && onAcao != null)
              TextButton(
                onPressed: onAcao,
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: e.mu),
                child: Text(acao!),
              ),
          ]),
          const SizedBox(height: 4),
          for (var i = 0; i < filhos.length; i++) ...[
            if (i > 0 && divisores)
              Divider(height: 1, thickness: 1, color: e.line),
            filhos[i],
          ],
        ],
      ),
    );
  }
}

/// Contas por banco, com saldo. Tocar abre as transações daquela conta.
class ContasInicio extends StatelessWidget {
  const ContasInicio(
      {super.key, required this.modelo, this.onGerenciar, this.onAbrirConta});
  final ModeloInicio modelo;
  final VoidCallback? onGerenciar;
  final void Function(ContaInicio)? onAbrirConta;

  @override
  Widget build(BuildContext context) => _Secao(
        titulo: 'Contas',
        acao: 'Gerenciar',
        onAcao: onGerenciar,
        filhos: [
          for (final c in modelo.contas)
            _LinhaConta(
                conta: c,
                onTap: onAbrirConta == null ? null : () => onAbrirConta!(c)),
        ],
      );
}

class _LinhaConta extends StatelessWidget {
  const _LinhaConta({required this.conta, this.onTap});
  final ContaInicio conta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return ToqueEscala(
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: e.chip, borderRadius: BorderRadius.circular(10)),
              child: Text(conta.sigla,
                  style: TextStyle(
                      fontFamily: 'GeistMono',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: e.tx)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(conta.nome,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: EdTexto.corpo(context)
                          .copyWith(fontWeight: FontWeight.w500)),
                  Text(conta.tipo, style: EdTexto.rotulo(context)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(brl(conta.saldo),
                style: EdTexto.corpo(context)
                    .copyWith(fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
