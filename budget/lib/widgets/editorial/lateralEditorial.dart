import 'dart:convert';

import 'package:budget/functions.dart';
import 'package:budget/pages/walletDetailsPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/navBarIconsData.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart';
import 'package:budget/widgets/editorial/versaoCanto.dart';
import 'package:budget/widgets/editorial/painelTransacao.dart';
import 'package:budget/widgets/editorial/seloPendencias.dart';
import 'package:flutter/material.dart';
import 'package:timer_builder/timer_builder.dart';

typedef ItemLateral = ({String chave, String rotulo});

const List<ItemLateral> mbItensLateral = [
  (chave: 'home', rotulo: 'Início'),
  (chave: 'transactions', rotulo: 'Transações'),
  (chave: 'pendencias', rotulo: 'Pendências'),
  (chave: 'budgets', rotulo: 'Orçamentos'),
  (chave: 'goals', rotulo: 'Metas'),
  (chave: 'loans', rotulo: 'Dívidas'),
  (chave: 'subscriptions', rotulo: 'Assinaturas'),
];

/// Itens da lateral e da busca: Pendências só existe no modo pareado.
List<ItemLateral> mbItensLateralVisiveis() => [
      for (final i in mbItensLateral)
        if (i.chave != 'pendencias' || meuBancoPareado.value) i
    ];

typedef ContaLateral = ({String id, String nome});

Future<({List<ContaLateral> contas, DateTime? sincronizadoEm})>
    mbCarregarLateral() async {
  final bruto = await mbLerEstado('contas');
  final lista = bruto == null ? const [] : jsonDecode(bruto) as List;
  final sinc = await mbLerEstado('sincronizado_em');
  return (
    contas: [
      for (final c in lista)
        if (c is Map) (id: '${c['id']}', nome: '${c['bank'] ?? c['name']}')
    ],
    sincronizadoEm: sinc == null ? null : DateTime.tryParse(sinc)
  );
}

class LateralEditorial extends StatefulWidget {
  const LateralEditorial({super.key})
      : _contas = null,
        _sincronizadoEm = null;
  const LateralEditorial.comDados(
      {super.key, required List<ContaLateral> contas, DateTime? sincronizadoEm})
      : _contas = contas,
        _sincronizadoEm = sincronizadoEm;

  final List<ContaLateral>? _contas;
  final DateTime? _sincronizadoEm;

  @override
  State<LateralEditorial> createState() => _LateralEditorialState();
}

class _LateralEditorialState extends State<LateralEditorial> {
  List<ContaLateral> _contas = const [];
  DateTime? _sincronizadoEm;

  @override
  void initState() {
    super.initState();
    if (widget._contas != null) {
      _contas = widget._contas!;
      _sincronizadoEm = widget._sincronizadoEm;
    } else {
      meuBancoUltimaSync.addListener(_carregar);
      _carregar();
    }
  }

  @override
  void dispose() {
    meuBancoUltimaSync.removeListener(_carregar);
    super.dispose();
  }

  Future<void> _carregar() async {
    final r = await mbCarregarLateral();
    if (!mounted) return;
    setState(() {
      _contas = r.contas;
      _sincronizadoEm = r.sincronizadoEm;
    });
  }

  Future<void> _abrirConta(String id) async {
    final carteira = await database.getWalletInstanceOrNull('mb:$id');
    if (carteira == null || !mounted) return;
    await pushRoute(context, WalletDetailsPage(wallet: carteira));
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return ColoredBox(
      color: e.bg,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Text('Meu Banco',
                  style: EdTexto.h1(context).copyWith(fontSize: 24)),
            ),
            // Substitui o botão flutuante do celular.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              child: FilledButton.icon(
                onPressed: () => abrirTransacao(context),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Nova transação'),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([mbPaginaAtual, meuBancoPareado]),
                builder: (context, _) => ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final item in mbItensLateralVisiveis())
                      _ItemNavegacao(
                        icone: _icone(item.chave),
                        rotulo: item.rotulo,
                        ativo: navBarIconsData[item.chave]!
                                .navigationIndexedStackIndex ==
                            mbPaginaAtual.value,
                        onTap: () => mbIrParaPagina(navBarIconsData[item.chave]!
                            .navigationIndexedStackIndex),
                      ),
                    if (_contas.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                        child: Text('Contas', style: EdTexto.h2(context)),
                      ),
                      for (final c in _contas)
                        _ItemNavegacao(
                          rotulo: c.nome,
                          ativo: false,
                          onTap: () => _abrirConta(c.id),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_sincronizadoEm != null)
                    TimerBuilder.periodic(
                      const Duration(minutes: 1),
                      builder: (context) => Text(
                          'Sincronizado ${haQuanto(_sincronizadoEm!, DateTime.now())}',
                          style: EdTexto.rotulo(context)),
                    ),
                  const SizedBox(height: 4),
                  // Com página empilhada o VersaoCanto desenha a versão; aqui sai da árvore
                  // (duas versões ficariam sobrepostas se a lateral continuasse visível).
                  ValueListenableBuilder<bool>(
                    valueListenable: mbRotaEmpilhada,
                    builder: (context, empilhada, _) => Visibility(
                      visible: !empilhada,
                      child: Text(
                          textoVersao(
                              packageInfoGlobal?.version ?? '?', mbCompilado),
                          style: EdTexto.mono(context)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ícone do item; Pendências leva a bolinha com o total.
Widget Function(Color) _icone(String chave) => (cor) {
      final icone =
          Icon(navBarIconsData[chave]!.iconData, size: 18, color: cor);
      return chave == 'pendencias' ? SeloPendencias(child: icone) : icone;
    };

class _ItemNavegacao extends StatelessWidget {
  const _ItemNavegacao(
      {this.icone,
      required this.rotulo,
      required this.ativo,
      required this.onTap});
  final Widget Function(Color cor)? icone;
  final String rotulo;
  final bool ativo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    // Nó próprio com nome único e toque: leitores de tela e testes acham "Transações".
    return Semantics(
      container: true,
      button: true,
      selected: ativo,
      label: rotulo,
      onTap: onTap,
      excludeSemantics: true,
      // InkWell: recebe foco por Tab e aciona com Enter/Espaço.
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: ativo ? e.surf : null,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ativo ? e.line : Colors.transparent),
          ),
          child: Row(
            children: [
              if (icone != null) ...[
                icone!(ativo ? e.acc : e.mu),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(rotulo,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context).copyWith(
                        fontWeight: FontWeight.w500,
                        color: ativo ? e.tx : e.mu)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
