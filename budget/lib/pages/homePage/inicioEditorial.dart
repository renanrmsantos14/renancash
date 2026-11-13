import 'dart:async';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/budgetPage.dart';
import 'package:budget/pages/meuBancoPage.dart';
import 'package:budget/pages/objectivePage.dart';
import 'package:budget/pages/objectivesListPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/mbSync/orcamentos.dart' show mbOrcamentoGeralPk;
import 'package:budget/struct/mbSync/revisao.dart' show mbAtualizarRevisar;
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/functions.dart';
import 'package:budget/widgets/navigationFramework.dart' show runAllCloudFunctions;
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/pullDownToRefreshSync.dart' show enableSwipeDownToRefresh;
import 'package:budget/widgets/util/checkWidgetLaunch.dart';
import 'package:flutter/material.dart';

/// Início do celular: responde "quanto posso gastar neste ciclo".
/// Layout fixo; blocos sem dados somem. Spec: docs/superpowers/specs/2026-11-13-nova-inicio.md.
class InicioEditorial extends StatefulWidget {
  const InicioEditorial({super.key}) : _modelo = null;
  const InicioEditorial.comModelo(ModeloInicio modelo, {super.key})
      : _modelo = modelo;
  final ModeloInicio? _modelo;

  @override
  State<InicioEditorial> createState() => _InicioEditorialState();
}

class _InicioEditorialState extends State<InicioEditorial> {
  ModeloInicio? _modelo;
  StreamSubscription<void>? _assinatura;
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
      // O 1º evento do stream já faz a carga inicial (sem corrida com uma gravação entre duas leituras).
      _assinatura = mbMudouUltimas().listen((_) => _recarga.pedir());
    }
  }

  @override
  void dispose() {
    meuBancoUltimaSync.removeListener(_recarga.pedir);
    _assinatura?.cancel();
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
    unawaited(meuBancoAtualizar()
        .then((msg) => openSnackbar(SnackbarMessage(title: msg))));
  }

  // O Geral pode ainda não existir (aparelho não pareado e sem sync): aí não abre nada.
  Future<void> _abrirOrcamento({required bool editar}) async {
    final Budget geral;
    try {
      geral = await database.getBudgetInstance(mbOrcamentoGeralPk);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    pushRoute(
        context,
        editar
            ? AddBudgetPage(
                budget: geral,
                routesToPopAfterDelete: RoutesToPopAfterDelete.None)
            : BudgetPage(budgetPk: geral.budgetPk));
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
          _Topo(modelo: m),
          const SizedBox(height: 24),
          if (m.semDados)
            Text('Ainda sem dados. Puxe a tela para atualizar.',
                style: EdTexto.corpo(context).copyWith(color: e.mu))
          else
            _CartaoSaldo(
              modelo: m,
              onTap: _real ? () => _abrirOrcamento(editar: false) : null,
              onDefinirLimite:
                  _real ? () => _abrirOrcamento(editar: true) : null,
            ),
          if (_real) const _MetasEmprestimos(),
          if (m.contas.isNotEmpty || m.cartoes.isNotEmpty)
            _ContasCartoes(
                modelo: m,
                onAbrir: _real
                    ? () => pushRoute(context, const MeuBancoPage())
                    : null),
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

class _Topo extends StatelessWidget {
  const _Topo({required this.modelo});
  final ModeloInicio modelo;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(modelo.ciclo, style: EdTexto.rotulo(context)),
          const SizedBox(height: 6),
          Text(modelo.saudacao, style: EdTexto.h1(context)),
        ],
      );
}

/// Cartão escuro de saldo: o único bloco pesado da tela.
/// Com limite: quanto resta do ciclo. Sem limite: o saldo das contas.
class _CartaoSaldo extends StatelessWidget {
  const _CartaoSaldo(
      {required this.modelo, this.onTap, this.onDefinirLimite});
  final ModeloInicio modelo;
  final VoidCallback? onTap, onDefinirLimite;

  @override
  Widget build(BuildContext context) {
    final limite = modelo.limite;
    final cartao = CartaoEscuro(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      child: limite != null && limite > 0
          ? _Restante(modelo: modelo, limite: limite)
          : _SemLimite(modelo: modelo, onDefinirLimite: onDefinirLimite),
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
    final m = modelo;
    final restante = limite - m.consumido;
    final estourou = restante < 0;
    // diasRestantes não conta hoje; no ritmo diário hoje entra (último dia = 1).
    final dias = m.diasRestantes < 0 ? 0 : m.diasRestantes;
    final quando = dias == 0
        ? 'último dia'
        : dias == 1
            ? 'falta 1 dia'
            : 'faltam $dias dias';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(estourou ? 'Acima do limite do ciclo' : 'Para gastar no ciclo',
            style: EdTexto.rotulo(context)),
        const SizedBox(height: 8),
        ContagemValor(
            valor: restante.abs(),
            formatar: brl,
            estilo: EdTexto.numeroGrande(context)
                .copyWith(color: estourou ? e.warn : null)),
        const SizedBox(height: 20),
        MedidorEditorial(fracao: m.consumido / limite, alerta: estourou),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text('Gasto ${brl(m.consumido)} de ${brl(limite)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.rotulo(context)),
            ),
            const SizedBox(width: 8),
            Text(quando, style: EdTexto.rotulo(context)),
          ],
        ),
        if (!estourou) ...[
          const SizedBox(height: 14),
          Text('Pode gastar ${brl(restante / (dias + 1))}/dia',
              style: EdTexto.corpo(context)
                  .copyWith(fontWeight: FontWeight.w500)),
        ],
        const SizedBox(height: 4),
        Text('Nas contas ${brl(m.disponivel)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: EdTexto.rotulo(context)),
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: EdTexto.rotulo(context)),
        const SizedBox(height: 8),
        ContagemValor(
            valor: modelo.disponivel,
            formatar: brl,
            estilo: EdTexto.numeroGrande(context)),
        const SizedBox(height: 14),
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

/// Até 3 linhas: metas (não arquivadas) e depois os empréstimos ao pai em aberto.
/// Some quando não há nada.
class _MetasEmprestimos extends StatelessWidget {
  const _MetasEmprestimos();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Objective>>(
      stream: database.watchAllObjectives(
          objectiveType: ObjectiveType.goal, hideArchived: true),
      builder: (context, snap) => ValueListenableBuilder<MbEmprestimos>(
        valueListenable: meuBancoEmprestimos,
        builder: (context, emprestimos, _) {
          final linhas = <Widget>[
            for (final o in snap.data ?? const <Objective>[])
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
            for (final e in emprestimos.abertos)
              _LinhaProgresso(
                titulo: e.data == null
                    ? 'Empréstimo'
                    : 'Empréstimo de ${diaMes(DateTime.parse(e.data!))}',
                valor: 'Falta ${brl(e.restante)}',
                fracao: e.original > 0 ? 1 - e.restante / e.original : 0,
              ),
          ];
          if (linhas.isEmpty) return const SizedBox.shrink();
          return _Secao(
            titulo: 'Metas e empréstimos',
            acao: linhas.length > 3 ? 'Ver todas' : null,
            onAcao: () => pushRoute(
                context, const ObjectivesListPage(backButton: true)),
            filhos: linhas.take(3).toList(),
          );
        },
      ),
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
        padding: const EdgeInsets.symmetric(vertical: 12),
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
      padding: const EdgeInsets.only(top: 28),
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

/// Contas (nome e saldo) e Cartões (fatura e uso do limite) num bloco só.
class _ContasCartoes extends StatelessWidget {
  const _ContasCartoes({required this.modelo, this.onAbrir});
  final ModeloInicio modelo;
  final VoidCallback? onAbrir;

  @override
  Widget build(BuildContext context) {
    final linha = Divider(height: 1, thickness: 1, color: cores(context).line);
    Widget subtitulo(String t) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 2),
          child: Text(t, style: EdTexto.rotulo(context)),
        );
    // Divisória só entre itens do mesmo grupo, nunca colada no subtítulo.
    return _Secao(
      titulo: 'Contas e cartões',
      acao: 'Gerenciar',
      onAcao: onAbrir,
      divisores: false,
      filhos: [
        if (modelo.contas.isNotEmpty) subtitulo('Contas'),
        for (var i = 0; i < modelo.contas.length; i++) ...[
          if (i > 0) linha,
          _LinhaConta(conta: modelo.contas[i], onTap: onAbrir),
        ],
        if (modelo.cartoes.isNotEmpty) ...[
          const SizedBox(height: 12),
          subtitulo('Cartões'),
        ],
        for (var i = 0; i < modelo.cartoes.length; i++) ...[
          if (i > 0) linha,
          ToqueEscala(
            onTap: onAbrir,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: _Cartao(cartao: modelo.cartoes[i]),
            ),
          ),
        ],
      ],
    );
  }
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
        height: 56,
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

class _Cartao extends StatelessWidget {
  const _Cartao({required this.cartao});
  final CartaoInicio cartao;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final c = cartao;
    final pct = c.pct;
    final alto = pct != null && pct >= 80;
    final fecha = c.diasFecha == null
        ? null
        : c.diasFecha == 0
            ? 'Fecha hoje'
            : 'Fecha em ${c.diasFecha} ${c.diasFecha == 1 ? 'dia' : 'dias'}';
    final linhaFecha = [
      if (fecha != null) fecha,
      if (c.vence != null) 'vence ${c.vence}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${c.nome}${c.final4.isEmpty ? '' : ' ·${c.final4}'}',
                      style: EdTexto.corpo(context)
                          .copyWith(fontWeight: FontWeight.w500)),
                  if (linhaFecha.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(linhaFecha, style: EdTexto.rotulo(context)),
                  ],
                ],
              ),
            ),
            if (pct != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: alto ? e.warnbg : e.chip,
                    borderRadius: BorderRadius.circular(10)),
                child: Text('${pct.round()}%',
                    style: TextStyle(
                        fontFamily: 'GeistMono',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: alto ? e.warntx : e.tx)),
              ),
          ],
        ),
        if (c.limite != null) ...[
          const SizedBox(height: 12),
          MedidorEditorial(
              fracao: c.fatura / c.limite!, alerta: (pct ?? 0) >= 100),
        ],
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Fatura ${brl(c.fatura)}', style: EdTexto.rotulo(context)),
            if (c.limite != null)
              Text('Limite ${brl(c.limite!)}', style: EdTexto.rotulo(context)),
          ],
        ),
      ],
    );
  }
}
