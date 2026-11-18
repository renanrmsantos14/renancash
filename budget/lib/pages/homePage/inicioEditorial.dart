import 'dart:async';
import 'dart:math' show max;

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/budgetsListPage.dart';
import 'package:budget/pages/editWalletsPage.dart';
import 'package:budget/pages/budgetPage.dart';
import 'package:budget/pages/meuBancoPage.dart';
import 'package:budget/pages/objectivePage.dart';
import 'package:budget/pages/homePage/homePageFaturaPatrimonio.dart' show CarregaPatrimonio;
import 'package:budget/pages/pendenciasPage.dart' show PendenciasPage;
import 'package:budget/widgets/editorial/layoutDesktop.dart' show mbIrParaPagina;
import 'package:intl/intl.dart' show NumberFormat;
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
    show mbMudouGeral, mbOrcamentoGeralPk, mbWatchGastoOrcamento;
import 'package:budget/struct/currencyFunctions.dart' show budgetAmountToPrimaryCurrency;
import 'package:budget/struct/mbSync/classificarDados.dart' show meuBancoClassificar;
import 'package:budget/struct/mbSync/revisao.dart'
    show mbAtualizarRevisar, meuBancoRevisar;
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
import 'package:flutter/foundation.dart' show listEquals;
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
        _metas = null,
        _patrimonio = null,
        _limites = null,
        _transacoes = const [];
  const InicioEditorial.comModelo(
    ModeloInicio modelo, {
    super.key,
    List<MbAtalhoRapido>? atalhos,
    List<({String nome, double total, double alvo})>? metas,
    PatrimonioInicio? patrimonio,
    List<LimiteInicio>? limites,
    List<TransacaoInicio> transacoes = const [],
  })  : _modelo = modelo,
        _atalhos = atalhos,
        _metas = metas,
        _patrimonio = patrimonio,
        _limites = limites,
        _transacoes = transacoes;
  final ModeloInicio? _modelo;
  final List<MbAtalhoRapido>? _atalhos;
  final List<({String nome, double total, double alvo})>? _metas;
  final PatrimonioInicio? _patrimonio; // prints: sem banco local
  final List<LimiteInicio>? _limites;
  final List<TransacaoInicio> _transacoes;

  @override
  State<InicioEditorial> createState() => _InicioEditorialState();
}

class _InicioEditorialState extends State<InicioEditorial> {
  ModeloInicio? _modelo;
  List<TransacaoInicio> _transacoes = const [];
  final _assinaturas = <StreamSubscription<void>>[];
  late final RecargaColapsada _recarga = RecargaColapsada(_carregar);
  bool get _real => widget._modelo == null;

  @override
  void initState() {
    super.initState();
    _modelo = widget._modelo;
    _transacoes = widget._transacoes;
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
    if (!mounted ||
        (r.modelo == _modelo && listEquals(r.transacoes, _transacoes))) {
      return;
    }
    setState(() {
      _modelo = r.modelo;
      _transacoes = r.transacoes;
    });
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
          if (!m.semDados) ...[
            const AlertaPendenciasInicio(),
            if (_real || widget._patrimonio != null)
              ResumoInicio(modelo: m, fixo: widget._patrimonio),
          ],
          if (_real || widget._atalhos != null)
            LancamentoRapidoInicio(atalhos: widget._atalhos),
          if (_real || meuBancoPareadoConferido.value) const AtalhosInicio(),
          GastoPorDiaInicio(modelo: m),
          if (_real || widget._limites != null)
            LimitesInicio(fixos: widget._limites),
          if (_real ||
              widget._metas != null ||
              meuBancoEmprestimos.value.abertos.isNotEmpty)
            MetasEmprestimosInicio(metas: widget._metas),
          UltimasInicio(transacoes: _transacoes),
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
                // Três por linha; IntrinsicHeight iguala a altura dos cartões da linha
                // (título que quebra em 2 linhas não deixa o vizinho mais baixo).
                child: Column(children: [
                  for (var i = 0; i < _atalhos.length; i += 3)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var j = i; j < i + 3; j++) ...[
                              if (j > i) const SizedBox(width: 8),
                              Expanded(
                                child: j >= _atalhos.length
                                    ? const SizedBox.shrink()
                                    : _AtalhoRapido(
                                        atalho: _atalhos[j],
                                        onTap: () async {
                                          if (await mbLancarRapido(
                                              context, _atalhos[j])) {
                                            _carregar();
                                          }
                                        }),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ]),
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
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
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
          // Só existe depois da primeira sincronização com o banco.
          ValueListenableBuilder<DateTime?>(
            valueListenable: meuBancoUltimaSync,
            builder: (context, quando, _) => quando == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('Sincronizado ${haQuanto(quando, DateTime.now())}',
                        style: EdTexto.rotulo(context).copyWith(fontSize: 11)),
                  ),
          ),
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
      this.onDefinirLimite});
  final ModeloInicio modelo;
  final VoidCallback? onTap, onDefinirLimite;

  @override
  Widget build(BuildContext context) {
    final limite = modelo.limite;
    final saldo = limite != null && limite > 0
        ? _Restante(modelo: modelo, limite: limite)
        : _SemLimite(modelo: modelo, onDefinirLimite: onDefinirLimite);
    final cartao = CartaoEscuro(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16), child: saldo);
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
                minimumSize: const Size(0, 44),
                alignment: Alignment.centerLeft,
                visualDensity: VisualDensity.compact,
                foregroundColor: e.acc),
            child: const Text('Definir limite do ciclo'),
          ),
      ],
    );
  }
}

/// Metas (não arquivadas) e empréstimos ao pai em aberto, cada um numa seção com até `linhasMetas` linhas.
/// Seção sem itens some.
class MetasEmprestimosInicio extends StatefulWidget {
  const MetasEmprestimosInicio({super.key, this.metas});

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
    final abertos = emprestimos.abertos;
    if (!temMetas && abertos.isEmpty) return const SizedBox.shrink();
    final n = AjustesInicio.linhasMetas;
    final bloco = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (temMetas)
          _Secao(
            titulo: 'Metas',
            acao: 'Ver todas',
            onAcao: () =>
                pushRoute(context, const ObjectivesListPage(backButton: true)),
            divisores: true,
            filhos: [
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
          _Secao(
            titulo: 'Empréstimos',
            divisores: true,
            filhos: [
              for (final e in abertos.take(n))
                _LinhaProgresso(
                  titulo: switch (DateTime.tryParse(e.data ?? '')) {
                    final d? => 'Empréstimo de ${diaMes(d)}',
                    null => 'Empréstimo',
                  },
                  valor: 'Falta ${brl(e.restante)}',
                  fracao: e.original > 0 ? 1 - e.restante / e.original : 0,
                ),
              if (abertos.length > n)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('mais ${abertos.length - n}',
                      style: EdTexto.rotulo(context)),
                ),
            ],
          ),
      ],
    );
    return bloco;
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

class _LinhaProgresso extends StatelessWidget {
  const _LinhaProgresso(
      {required this.titulo,
      required this.valor,
      required this.fracao,
      this.alerta = false,
      this.onTap});
  final String titulo, valor;
  final double fracao;
  final bool alerta;
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
            MedidorEditorial(fracao: fracao, alerta: alerta, altura: 6),
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
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(44, 44),
                    alignment: Alignment.centerRight,
                    visualDensity: VisualDensity.compact,
                    foregroundColor: e.acc),
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

final _brlInteiro =
    NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$', decimalDigits: 0);
String _brl0(double v) => _brlInteiro
    .format(v)
    .replaceAll(' ', ' ')
    .replaceFirst(RegExp(r'^-'), '−');

/// "N para classificar · R$ total" com atalho para as Pendências. Some sem itens na fila
/// (Para revisar + Para classificar, a mesma contagem do selo, sem bancos desconectados nem contas vencidas).
class AlertaPendenciasInicio extends StatelessWidget {
  const AlertaPendenciasInicio({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([meuBancoRevisar, meuBancoClassificar]),
        builder: (context, _) {
          final e = cores(context);
          final revisar = meuBancoRevisar.value;
          final classificar =
              meuBancoClassificar.value.where((l) => l.revisao == null).toList();
          final n = revisar.length + classificar.length;
          if (n == 0) return const SizedBox.shrink();
          final total = revisar.fold<double>(0, (s, i) => s + i.valor.abs()) +
              classificar.fold<double>(0, (s, l) => s + l.valor.abs());
          void abrir() => pushRoute(context, const PendenciasPage());
          return Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Semantics(
              button: true,
              label: '$n para classificar, revisar',
              excludeSemantics: true,
              onTap: abrir,
              child: ToqueEscala(
                onTap: abrir,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                      color: e.warnbg, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                              text: '$n para classificar',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (total > 0) TextSpan(text: ' · ${brl(total)}'),
                        ]),
                        style: EdTexto.corpo(context).copyWith(color: e.warntx),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('Revisar →',
                        style: EdTexto.corpo(context).copyWith(color: e.warntx)),
                  ]),
                ),
              ),
            ),
          );
        },
      );
}

/// Três números do patrimônio: Nas contas (correntes + poupanças), Investido e Fatura aberta.
/// Lê os saldos do aparelho (`CarregaPatrimonio`); `fixo` só nos prints. Sem contas, some.
class ResumoInicio extends StatelessWidget {
  const ResumoInicio({super.key, required this.modelo, this.fixo});
  final ModeloInicio modelo;
  final PatrimonioInicio? fixo;

  @override
  Widget build(BuildContext context) =>
      fixo != null ? _kpis(context, fixo!) : CarregaPatrimonio(construir: _kpis);

  Widget _kpis(BuildContext context, PatrimonioInicio d) {
    final p = d.patrimonio;
    final vencimentos = [
      for (final f in d.faturas)
        if (f.valor > 0 && f.vence != null) f.vence!
    ]..sort();
    final contas = modelo.contas.length;
    String dd(int v) => v.toString().padLeft(2, '0');
    return _Secao(
      titulo: 'Resumo',
      divisores: false,
      filhos: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                  child: _Kpi('Nas contas', _brl0(p.correntes + p.poupancas),
                      contas == 1 ? '1 conta' : '$contas contas')),
              const SizedBox(width: 8),
              Expanded(child: _Kpi('Investido', _brl0(p.investimentos))),
              if (d.faturas.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                    child: _Kpi(
                        'Fatura aberta',
                        _brl0(p.fatura),
                        vencimentos.isEmpty
                            ? null
                            : 'vence ${dd(vencimentos.first.day)}/${dd(vencimentos.first.month)}',
                        true)),
              ],
            ]),
          ),
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.rotulo, this.valor, [this.sub, this.subAlerta = false]);
  final String rotulo, valor;
  final String? sub;
  final bool subAlerta;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Semantics(
      label: '$rotulo $valor${sub == null ? '' : ', $sub'}',
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
                      .copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            if (sub != null) ...[
              const SizedBox(height: 2),
              Text(sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.rotulo(context)
                      .copyWith(fontSize: 11, color: subAlerta ? e.warn : e.mu)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Gasto de cada dia do ciclo: barras até hoje (hoje em destaque), dias futuros tracejados.
class GastoPorDiaInicio extends StatelessWidget {
  const GastoPorDiaInicio({super.key, required this.modelo});
  final ModeloInicio modelo;

  @override
  Widget build(BuildContext context) {
    if (modelo.porDia.isEmpty) return const SizedBox.shrink();
    final pontas = modelo.periodo.split(' – ');
    return _Secao(
      titulo: 'Gasto por dia',
      divisores: false,
      filhos: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: BarrasDias(
              valores: modelo.porDia, indiceHoje: modelo.indiceHoje, altura: 72),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (pontas.length > 1) Text(pontas.first, style: EdTexto.mono(context)),
            Text('hoje', style: EdTexto.mono(context)),
            if (pontas.length > 1) Text(pontas.last, style: EdTexto.mono(context)),
          ],
        ),
      ],
    );
  }
}

typedef LimiteInicio = ({String nome, double gasto, double limite});

/// Os 3 orçamentos (fora o Geral e rendas) com maior fração do limite usada; barra vermelha a partir de 90%.
/// Lê os orçamentos do aparelho; `fixos` só nos prints. Sem orçamentos com limite, some.
class LimitesInicio extends StatefulWidget {
  const LimitesInicio({super.key, this.fixos});
  final List<LimiteInicio>? fixos;

  @override
  State<LimitesInicio> createState() => _LimitesInicioState();
}

class _LimitesInicioState extends State<LimitesInicio> {
  List<LimiteInicio> _limites = const [];
  StreamSubscription<List<Budget>>? _orcamentos;
  final _gastos = <StreamSubscription<double>>[];
  int _geracao = 0;

  @override
  void initState() {
    super.initState();
    final fixos = widget.fixos;
    if (fixos != null) {
      _limites = fixos;
      return;
    }
    _orcamentos = database
        .watchAllBudgets(hideArchived: true)
        .listen(_aoMudarOrcamentos, onError: (_) {});
  }

  void _cancelarGastos() {
    for (final g in _gastos) {
      g.cancel();
    }
    _gastos.clear();
  }

  @override
  void dispose() {
    _orcamentos?.cancel();
    _cancelarGastos();
    super.dispose();
  }

  Future<void> _aoMudarOrcamentos(List<Budget> todos) async {
    final geracao = ++_geracao;
    _cancelarGastos();
    final carteiras = await database.watchAllWalletsIndexed().first;
    if (!mounted || geracao != _geracao) return;
    final agora = DateTime.now();
    final gastos = <String, double>{};
    final base = <String, ({Budget b, double limite})>{};
    for (final b in todos) {
      final limite = budgetAmountToPrimaryCurrency(carteiras, b);
      if (b.budgetPk != mbOrcamentoGeralPk && !b.income && limite > 0) {
        base[b.budgetPk] = (b: b, limite: limite);
      }
    }
    void recalcular() {
      final lista = [
        for (final e in base.entries)
          if (gastos[e.key] != null)
            (nome: e.value.b.name, gasto: gastos[e.key]!, limite: e.value.limite)
      ]..sort((a, b) => (b.gasto / b.limite).compareTo(a.gasto / a.limite));
      if (mounted) setState(() => _limites = lista.take(3).toList());
    }

    if (base.isEmpty) {
      recalcular();
      return;
    }
    for (final e in base.entries) {
      _gastos.add(mbWatchGastoOrcamento(
              e.value.b, carteiras, getBudgetDate(e.value.b, agora))
          .listen((g) {
        gastos[e.key] = g;
        recalcular();
      }, onError: (_) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_limites.isEmpty) return const SizedBox.shrink();
    return _Secao(
      titulo: 'Limites perto do fim',
      acao: 'Orçamentos',
      onAcao: () =>
          pushRoute(context, const BudgetsListPage(enableBackButton: true)),
      divisores: false,
      filhos: [
        for (final l in _limites)
          _LinhaProgresso(
            titulo: l.nome,
            valor: '${brl(l.gasto)} de ${brl(l.limite)}',
            fracao: l.gasto / l.limite,
            alerta: l.gasto / l.limite >= .9,
          ),
      ],
    );
  }
}

/// As 4 últimas transações, com atalho para a aba Transações. Sem transações, some.
class UltimasInicio extends StatelessWidget {
  const UltimasInicio({super.key, required this.transacoes});
  final List<TransacaoInicio> transacoes;

  @override
  Widget build(BuildContext context) {
    if (transacoes.isEmpty) return const SizedBox.shrink();
    final e = cores(context);
    final agora = DateTime.now();
    return _Secao(
      titulo: 'Últimas transações',
      acao: 'Ver todas',
      onAcao: () => mbIrParaPagina(1),
      filhos: [
        for (final t in transacoes.take(4))
          SizedBox(
            height: 56,
            child: Row(children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.transaction.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: EdTexto.corpo(context)
                            .copyWith(fontWeight: FontWeight.w500)),
                    Text(
                        '${quandoRelativo(t.transaction.dateCreated, agora)} · ${t.category.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: EdTexto.rotulo(context)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                  '${t.transaction.income ? '+' : '−'}${brl(t.transaction.amount.abs())}',
                  style: EdTexto.corpo(context).copyWith(
                      fontWeight: FontWeight.w500,
                      color: t.transaction.income ? e.pos : e.tx)),
            ]),
          ),
      ],
    );
  }
}
