import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart' show popRoute;
import 'package:budget/pages/objectivesListPage.dart' show cartaoPlano;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl;
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/outlinedButtonStacked.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:flutter/material.dart';

/// Posição de cada nome entre os repetidos ("1 de 4"), null quando o nome é único. O Worker manda só
/// nome, banco e saldo das aplicações (sem vencimento nem taxa), então 4 "CDB - BANCO INTER" se
/// distinguem pela posição e pelo saldo.
List<String?> mbPosicoesRepetidas(List<String> nomes) {
  final total = <String, int>{};
  for (final n in nomes) total[n] = (total[n] ?? 0) + 1;
  final visto = <String, int>{};
  return [
    for (final n in nomes)
      total[n]! < 2 ? null : '${visto[n] = (visto[n] ?? 0) + 1} de ${total[n]}'
  ];
}

/// Escolha das aplicações que compõem uma meta (tela de editar meta). Cada aplicação fica em uma meta só:
/// as que já estão em outra meta aparecem desabilitadas, com o nome dessa meta.
/// Some quando o app não tem aplicações (sem Meu Banco ou sem investimentos).
class MbAplicacoesDaMeta extends StatefulWidget {
  const MbAplicacoesDaMeta(
      {required this.metaPk, required this.selecionadas, required this.onChanged, super.key});

  /// Meta sendo editada (null = meta nova).
  final String? metaPk;
  final Set<String> selecionadas;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<MbAplicacoesDaMeta> createState() => _MbAplicacoesDaMetaState();
}

class _MbAplicacoesDaMetaState extends State<MbAplicacoesDaMeta> {
  List<MbAplicacao>? aplicacoes;
  Map<String, String> nomesDasMetas = {};

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final lista = await mbAplicacoes();
    final metas = await database.select(database.objectives).get();
    if (!mounted) return;
    setState(() {
      aplicacoes = lista;
      nomesDasMetas = {for (final m in metas) m.objectivePk: m.name};
    });
  }

  @override
  Widget build(BuildContext context) {
    final lista = aplicacoes;
    if (lista == null || lista.isEmpty) return const SizedBox.shrink();
    final suave = getColor(context, "textLight");
    final saldo = lista
        .where((a) => widget.selecionadas.contains(a.pk))
        .fold(0.0, (s, a) => s + a.saldo);
    final posicoes = mbPosicoesRepetidas([for (final a in lista) a.nome]);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 20, end: 20, top: 25),
      child: OutlinedContainer(
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(vertical: 8, horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16, end: 16, top: 8),
                child: TextFont(text: 'Aplicações da meta', fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16, end: 16, bottom: 4),
                child: TextFont(
                    text: 'O progresso é a soma do saldo atual das aplicações escolhidas.',
                    fontSize: 13,
                    maxLines: 3,
                    textColor: suave),
              ),
              for (final (i, a) in lista.indexed)
                Builder(builder: (context) {
                  final emOutra = a.metaPk != null && a.metaPk != widget.metaPk;
                  final marcada = widget.selecionadas.contains(a.pk);
                  return CheckboxListTile(
                    key: ValueKey('aplicacao-${a.id}'),
                    value: marcada,
                    enabled: !emOutra,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (v) => widget.onChanged(v == true
                        ? {...widget.selecionadas, a.pk}
                        : ({...widget.selecionadas}..remove(a.pk))),
                    title: TextFont(text: a.nome, fontSize: 15, maxLines: 2),
                    subtitle: TextFont(
                        text: emOutra
                            ? 'Já na meta ${nomesDasMetas[a.metaPk] ?? ''}'.trim()
                            : [a.banco, posicoes[i]].whereType<String>().join(' · '),
                        fontSize: 12.5,
                        textColor: suave),
                    secondary: TextFont(text: brl(a.saldo), fontSize: 14, fontWeight: FontWeight.bold),
                  );
                }),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16, end: 16, top: 6, bottom: 8),
                child: TextFont(
                    text: 'Saldo escolhido: ${brl(saldo)}',
                    fontSize: 14,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Painel da tela da meta de poupança: as aplicações que compõem o guardado e o que fazer quando não há nenhuma.
/// Carrega as aplicações e abre a escolha; [onDepositar] registra um depósito manual na meta.
class AplicacoesDaMetaNaTela extends StatefulWidget {
  const AplicacoesDaMetaNaTela(
      {required this.meta, required this.onDepositar, super.key});
  final Objective meta;
  final VoidCallback onDepositar;

  @override
  State<AplicacoesDaMetaNaTela> createState() => _AplicacoesDaMetaNaTelaState();
}

class _AplicacoesDaMetaNaTelaState extends State<AplicacoesDaMetaNaTela> {
  List<MbAplicacao>? todas;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final l = await mbAplicacoes();
    if (mounted) setState(() => todas = l);
  }

  Future<void> _escolher(Set<String> atuais) async {
    await openBottomSheet(
      context,
      PopupFramework(
        title: 'Aplicações da meta',
        child: _EscolherAplicacoes(
          metaPk: widget.meta.objectivePk,
          inicial: atuais,
          onSalvar: (pks) => mbEscolherAplicacoesDaMeta(widget.meta, pks),
        ),
      ),
      showScrollbar: true,
    );
    await _carregar();
  }

  @override
  Widget build(BuildContext context) {
    final l = todas;
    if (l == null) return const SizedBox.shrink();
    final s = mbSepararAplicacoes(l, widget.meta.objectivePk);
    return PainelAplicacoesMeta(
      ligadas: s.ligadas,
      livres: s.livres,
      onEscolher: l.isEmpty
          ? null
          : () => _escolher({for (final a in s.ligadas) a.pk}),
      onDepositar: widget.onDepositar,
    );
  }
}

/// Sem acesso ao banco (prints): lista das aplicações ligadas, ou o vazio que explica e leva a escolher.
/// [onEscolher] nulo = o app não tem aplicações (sem Meu Banco ou sem investimentos): só depósito manual.
class PainelAplicacoesMeta extends StatelessWidget {
  const PainelAplicacoesMeta({
    super.key,
    required this.ligadas,
    required this.livres,
    required this.onEscolher,
    required this.onDepositar,
  });
  final List<MbAplicacao> ligadas, livres;
  final VoidCallback? onEscolher;
  final VoidCallback onDepositar;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final rotulo = EdTexto.rotulo(context);
    final forte = EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500);
    final decoracao = cartaoPlano(e);
    final depositar = TextButton(
      onPressed: onDepositar,
      style: TextButton.styleFrom(foregroundColor: e.acc),
      child: const Text('Registrar depósito'),
    );
    if (ligadas.isEmpty) {
      final String explicacao;
      if (onEscolher == null) {
        explicacao = 'O guardado é a soma dos depósitos que você registrar nesta meta.';
      } else if (livres.isEmpty) {
        explicacao =
            'O guardado é a soma do saldo das aplicações que você escolher. Todas já estão em outras metas.';
      } else {
        final quantas = livres.length == 1
            ? 'Há 1 aplicação sem meta'
            : 'Há ${livres.length} aplicações sem meta';
        explicacao = 'O guardado é a soma do saldo das aplicações que você escolher. '
            '$quantas, somando ${brl(mbSaldoAplicacoes(livres))}.';
      }
      return Container(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 8),
        decoration: decoracao,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(Icons.savings_outlined, size: 20, color: e.acc),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(
                      onEscolher == null
                          ? 'Nenhum depósito ainda'
                          : 'Nenhuma aplicação ligada a esta meta',
                      style: forte)),
            ]),
            const SizedBox(height: 6),
            Text(explicacao, style: rotulo),
            const SizedBox(height: 14),
            if (onEscolher != null)
              Button(label: 'Escolher aplicações', onTap: onEscolher!),
            depositar,
          ],
        ),
      );
    }
    final posicoes = mbPosicoesRepetidas([for (final a in ligadas) a.nome]);
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 4),
      decoration: decoracao,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
                child: Text(
                    ligadas.length == 1
                        ? '1 aplicação nesta meta'
                        : '${ligadas.length} aplicações nesta meta',
                    style: forte)),
            if (onEscolher != null)
              TextButton(
                onPressed: onEscolher,
                style: TextButton.styleFrom(foregroundColor: e.acc),
                child: const Text('Escolher'),
              ),
          ]),
          for (final (i, a) in ligadas.indexed)
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 6, end: 8),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.nome,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: EdTexto.corpo(context)),
                      if (a.banco != null || posicoes[i] != null)
                        Text([a.banco, posicoes[i]].whereType<String>().join(' · '),
                            style: rotulo),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(brl(a.saldo), style: forte),
              ]),
            ),
          const SizedBox(height: 4),
          Align(alignment: AlignmentDirectional.centerStart, child: depositar),
        ],
      ),
    );
  }
}

class _EscolherAplicacoes extends StatefulWidget {
  const _EscolherAplicacoes(
      {required this.metaPk, required this.inicial, required this.onSalvar});
  final String metaPk;
  final Set<String> inicial;
  final Future<void> Function(Set<String>) onSalvar;

  @override
  State<_EscolherAplicacoes> createState() => _EscolherAplicacoesState();
}

class _EscolherAplicacoesState extends State<_EscolherAplicacoes> {
  late Set<String> selecionadas = {...widget.inicial};
  bool salvando = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MbAplicacoesDaMeta(
          metaPk: widget.metaPk,
          selecionadas: selecionadas,
          onChanged: (v) => setState(() => selecionadas = v),
        ),
        const SizedBox(height: 16),
        Button(
          label: 'Salvar',
          disabled: salvando,
          onTap: () async {
            if (salvando) return;
            setState(() => salvando = true);
            try {
              await widget.onSalvar(selecionadas);
              if (context.mounted) popRoute(context);
            } finally {
              if (mounted) setState(() => salvando = false);
            }
          },
        ),
      ],
    );
  }
}
