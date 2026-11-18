import 'package:budget/database/tables.dart' show Transaction;
import 'package:budget/functions.dart' show popRoute;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl, diaMes;
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/struct/mbSync/revisao.dart' show mbNormalizarRevisao;
import 'package:budget/struct/meuBancoMapping.dart' show mbPrefixo;
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/transactionEntry/transactionLabel.dart'
    show nomeSemEspacosRepetidos;
import 'package:flutter/material.dart';

// Rachar conta na tela (a regra está em struct/mbSync/reembolso.dart): a lista de gastos para ligar um Pix recebido e o
// vínculo no editar transação.

const String semGastoReembolso = 'sem_gasto';

String _ddmm(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

/// "JUNIOR SILVA" → "Junior Silva" (favorecido normalizado de volta para leitura).
String mbNomeDoPagador(String chave) => chave.isEmpty
    ? 'alguém'
    : chave.split(' ').map((p) => p[0] + p.substring(1).toLowerCase()).join(' ');

/// Folha "De qual conta é essa parte?": devolve o MbGastoCandidato escolhido, [semGastoReembolso] (só com [comNenhum])
/// ou null (fechou sem escolher).
Future<Object?> mbEscolherGastoRachado(BuildContext context,
        {required List<MbSugestaoReembolso> sugestoes,
        required double valor,
        required DateTime data,
        bool comNenhum = false}) =>
    openBottomSheet(
      context,
      PopupFramework(
        title: 'De qual conta é essa parte?',
        subtitle: '${brl(valor.abs())} · ${diaMes(data)}',
        child: GastosRachados(sugestoes: sugestoes, comNenhum: comNenhum),
      ),
    );

/// Gastos dos últimos 30 dias, os mais prováveis primeiro (motivo ao lado: metade, 1/3, o que falta…), com busca.
class GastosRachados extends StatefulWidget {
  const GastosRachados({super.key, required this.sugestoes, this.comNenhum = false});
  final List<MbSugestaoReembolso> sugestoes;
  final bool comNenhum;

  @override
  State<GastosRachados> createState() => _GastosRachadosState();
}

class _GastosRachadosState extends State<GastosRachados> {
  final _busca = TextEditingController();

  @override
  void dispose() {
    _busca.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final termo = mbNormalizarRevisao(_busca.text);
    final lista = [
      for (final s in widget.sugestoes)
        if (termo.isEmpty || mbNormalizarRevisao('${s.gasto.nome} ${s.gasto.categoria}').contains(termo)) s
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _busca,
        onChanged: (_) => setState(() {}),
        style: EdTexto.corpo(context),
        decoration: InputDecoration(
          hintText: 'Buscar gasto',
          hintStyle: EdTexto.corpo(context).copyWith(color: e.mu),
          prefixIcon: Icon(Icons.search_rounded, color: e.mu),
          filled: true,
          fillColor: e.chip,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        ),
      ),
      const SizedBox(height: 8),
      if (lista.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
              widget.sugestoes.isEmpty
                  ? 'Nenhum gasto nos últimos $mbJanelaReembolsoDias dias.'
                  : 'Nenhum gasto com "${_busca.text.trim()}".',
              style: EdTexto.rotulo(context)),
        ),
      for (final s in lista) _LinhaGasto(s),
      if (widget.comNenhum) ...[
        const SizedBox(height: 8),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
          onPressed: () => popRoute(context, semGastoReembolso),
          child: Text('Nenhum desses (abater em Outros)', style: EdTexto.corpo(context)),
        ),
      ],
    ]);
  }
}

class _LinhaGasto extends StatelessWidget {
  const _LinhaGasto(this.s);
  final MbSugestaoReembolso s;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final g = s.gasto;
    final maior = s.motivos.any((m) => m.startsWith('maior'));
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => popRoute(context, g),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(nomeSemEspacosRepetidos(g.nome),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600)),
                Text([diaMes(g.data), if (g.categoria.isNotEmpty) g.categoria, ...s.motivos].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: EdTexto.rotulo(context).copyWith(color: maior ? e.warntx : null)),
              ]),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(brl(g.valor), style: EdTexto.mono(context).copyWith(color: e.tx)),
              if (g.reembolsado > 0) Text('falta ${brl(g.falta / 100)}', style: EdTexto.rotulo(context)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// No editar transação de um lançamento do Meu Banco: a entrada ligada diz de qual gasto é; o gasto com reembolsos
/// mostra cada parte e a minha (avisa se os reembolsos passam do gasto); a entrada sem vínculo oferece "É a parte de
/// uma conta que eu paguei". Ligar e desligar gravam a decisão "reembolso" e sincronizam.
class VinculoReembolso extends StatelessWidget {
  const VinculoReembolso({super.key, required this.transacao});
  final Transaction transacao;

  @override
  Widget build(BuildContext context) {
    final pk = transacao.transactionPk;
    if (!pk.startsWith(mbPrefixo)) return const SizedBox.shrink();
    return ValueListenableBuilder<List<MbVinculoReembolso>>(
      valueListenable: meuBancoReembolsos,
      builder: (context, vinculos, _) {
        final ligado = vinculos.where((v) => v.reembolsoPk == pk).firstOrNull;
        final partes = [
          for (final v in vinculos)
            if (v.gastoPk == pk) v
        ];
        final Widget? conteudo = ligado != null
            ? _ReembolsoLigado(ligado)
            : partes.isNotEmpty
                ? _PartesDoGasto(gasto: transacao, partes: partes)
                : transacao.amount > 0
                    ? _LigarEntrada(transacao)
                    : null;
        if (conteudo == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(17, 14, 17, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Conta rachada', style: EdTexto.h2(context)),
            const SizedBox(height: 6),
            conteudo,
          ]),
        );
      },
    );
  }
}

Future<void> _desligar(String reembolsoPk) async {
  await mbDesfazerRevisao(reembolsoPk.substring(mbPrefixo.length));
  openSnackbar(SnackbarMessage(title: 'Desligado. Os números voltam ao original.'));
}

class _ReembolsoLigado extends StatefulWidget {
  const _ReembolsoLigado(this.v);
  final MbVinculoReembolso v;

  @override
  State<_ReembolsoLigado> createState() => _ReembolsoLigadoState();
}

class _ReembolsoLigadoState extends State<_ReembolsoLigado> {
  late Future<Transaction?> _gasto = _ler();

  Future<Transaction?> _ler() => (database.select(database.transactions)
        ..where((t) => t.transactionPk.equals(widget.v.gastoPk)))
      .getSingleOrNull();

  @override
  void didUpdateWidget(_ReembolsoLigado antigo) {
    super.didUpdateWidget(antigo);
    if (antigo.v.gastoPk != widget.v.gastoPk) _gasto = _ler();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Transaction?>(
      future: _gasto,
      builder: (context, snap) {
        final g = snap.data;
        return _LinhaVinculo(
          texto: g == null ? 'Reembolso de um gasto' : 'Reembolso de ${g.name} ${_ddmm(g.dateCreated)}',
          detalhe: 'Conta como parte desse gasto, não como receita.',
          aoDesligar: () => _desligar(widget.v.reembolsoPk),
        );
      },
    );
  }
}

class _PartesDoGasto extends StatelessWidget {
  const _PartesDoGasto({required this.gasto, required this.partes});
  final Transaction gasto;
  final List<MbVinculoReembolso> partes;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final total = (gasto.amount.abs() * 100).round();
    final minha = mbMinhaParte(total, partes.map((p) => p.centavos));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final p in partes)
        _LinhaVinculo(
          texto: 'Parte de ${mbNomeDoPagador(p.pagador)} · −${brl(p.centavos / 100)} de ${brl(total / 100)}',
          aoDesligar: () => _desligar(p.reembolsoPk),
        ),
      const SizedBox(height: 4),
      Text('Sua parte: ${brl(minha.parte / 100)}',
          style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600)),
      if (minha.excesso > 0)
        Semantics(
          liveRegion: true,
          child: Text(
              'Os reembolsos passam do gasto em ${brl(minha.excesso / 100)}. Confira se algum é de outra conta.',
              style: EdTexto.rotulo(context).copyWith(color: e.warntx)),
        ),
    ]);
  }
}

class _LigarEntrada extends StatefulWidget {
  const _LigarEntrada(this.t);
  final Transaction t;

  @override
  State<_LigarEntrada> createState() => _LigarEntradaState();
}

class _LigarEntradaState extends State<_LigarEntrada> {
  bool _enviando = false;

  Future<void> _ligar() async {
    final t = widget.t;
    setState(() => _enviando = true);
    try {
      final sugestoes = await mbBuscarCandidatosReembolso(t.transactionPk, t.amount, t.dateCreated, t.name);
      if (!mounted) return;
      final g = await mbEscolherGastoRachado(context, sugestoes: sugestoes, valor: t.amount, data: t.dateCreated);
      if (g is! MbGastoCandidato) return;
      await mbResponderRevisao(mbItemDeEntrada(t.transactionPk, t.amount, t.dateCreated, t.name), 'reembolso',
          reembolsoDe: g.pk.substring(mbPrefixo.length));
      openSnackbar(SnackbarMessage(title: 'Ligado a ${g.nome}. O gasto passa a contar só a sua parte.'));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    // Enquanto liga (busca, grava e sincroniza), a linha fica apagada e sem toque.
    return Opacity(
      opacity: _enviando ? .5 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _enviando ? null : _ligar,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(children: [
            Icon(Icons.call_split_rounded, size: 18, color: e.mu),
            const SizedBox(width: 8),
            Expanded(child: Text('É a parte de uma conta que eu paguei', style: EdTexto.corpo(context))),
            Icon(Icons.chevron_right_rounded, size: 18, color: e.mu),
          ]),
        ),
      ),
    );
  }
}

class _LinhaVinculo extends StatelessWidget {
  const _LinhaVinculo({required this.texto, this.detalhe, required this.aoDesligar});
  final String texto;
  final String? detalhe;
  final VoidCallback aoDesligar;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Row(children: [
      Icon(Icons.call_split_rounded, size: 18, color: e.mu),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(texto, style: EdTexto.corpo(context)),
          if (detalhe != null) Text(detalhe!, style: EdTexto.rotulo(context)),
        ]),
      ),
      TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
          onPressed: aoDesligar,
          child: Text('Desligar', style: EdTexto.corpo(context).copyWith(color: e.acc))),
    ]);
  }
}
