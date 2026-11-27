import 'package:budget/pages/migracaoEmprestimosPage.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/widgets/editorial/movimento.dart';
import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl, diaMes;
import 'package:budget/struct/meuBancoSync.dart' show mbDesfazerPerdao, mbPerdoarEmprestimo;
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:flutter/material.dart';

// Aba Empréstimos: o que o Renan emprestou e ainda não recebeu, por pessoa (valor original, pagamentos recebidos e saldo),
// com "Perdoar o restante" (o saldo vira gasto na data do perdão). Quitados e perdoados ficam numa seção recolhida.
// Empréstimo não é gasto: não entra no Geral nem nos orçamentos.

String _dia(String? data) {
  final d = DateTime.tryParse(data ?? '');
  return d == null ? '' : diaMes(d);
}

class EmprestimosPage extends StatelessWidget {
  // `emprestimos` existe para os testes e prints exercitarem a tela sem o banco.
  const EmprestimosPage({super.key, this.emprestimos});
  final MbEmprestimos? emprestimos;

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      title: 'Empréstimos',
      backButton: false,
      horizontalPaddingConstrained: true,
      listWidgets: [
        if (emprestimos != null)
          _Conteudo(emprestimos!)
        else
          ValueListenableBuilder<MbEmprestimos>(
            valueListenable: meuBancoEmprestimos,
            builder: (context, e, _) => _Conteudo(e),
          ),
      ],
    );
  }
}

class _Conteudo extends StatelessWidget {
  const _Conteudo(this.e);
  final MbEmprestimos e;

  @override
  Widget build(BuildContext context) {
    final cor = cores(context);
    final pessoas = [for (final p in e.porPessoa) if (p.abertos.isNotEmpty) p];
    final quitados = [for (final p in e.porPessoa) if (p.quitados.isNotEmpty) p];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Emprestado em aberto', style: EdTexto.rotulo(context)),
        const SizedBox(height: 4),
        ContagemValor(key: const Key('emprestado_em_aberto'), valor: e.devido, formatar: brl, estilo: EdTexto.numeroGrande(context)),
        const SizedBox(height: 20),
        if (pessoas.isEmpty)
          Text('Nenhum empréstimo em aberto.', style: EdTexto.corpo(context).copyWith(color: cor.mu)),
        for (final p in pessoas) ...[
          _CartaoPessoa(p),
          const SizedBox(height: 12),
        ],
        if (quitados.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const Key('quitados'),
              tilePadding: EdgeInsets.zero,
              title: Text('Quitados (${quitados.fold<int>(0, (s, p) => s + p.quitados.length)})',
                  style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600)),
              children: [
                for (final p in quitados)
                  for (final q in p.quitados) _LinhaQuitado(p.nome, q),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('empréstimos_antigos'),
            onPressed: () => abrirMigracaoEmprestimos(context),
            icon: const Icon(Icons.history_rounded, size: 18),
            label: const Text('Empréstimos antigos'),
          ),
        ),
      ]),
    );
  }
}

class _CartaoPessoa extends StatelessWidget {
  const _CartaoPessoa(this.p);
  final MbEmprestimosDaPessoa p;

  @override
  Widget build(BuildContext context) {
    final cor = cores(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cor.bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cor.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(p.nome, style: EdTexto.corpo(context).copyWith(fontSize: 18, fontWeight: FontWeight.w600))),
          Text(brl(p.restanteCentavos / 100), style: EdTexto.mono(context).copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 2),
        Text('Original ${brl(p.originalCentavos / 100)} · Recebido ${brl(p.pagoCentavos / 100)}',
            style: EdTexto.rotulo(context)),
        for (final e in p.abertos) ...[
          Divider(height: 24, thickness: 1, color: cor.line),
          _LinhaEmprestimo(e),
        ],
      ]),
    );
  }
}

class _LinhaEmprestimo extends StatelessWidget {
  const _LinhaEmprestimo(this.e);
  final MbEmprestimo e;

  Future<void> _perdoar(BuildContext context) async {
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Perdoar o restante?'),
        content: Text('${brl(e.restante)} viram gasto hoje e saem do que você tem a receber.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Perdoar')),
        ],
      ),
    );
    if (confirmou == true) await mbPerdoarEmprestimo(e.txId);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('Emprestado em ${_dia(e.data)}', style: EdTexto.corpo(context))),
        Text(brl(e.original), style: EdTexto.mono(context)),
      ]),
      for (final pg in e.pagamentos)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Expanded(child: Text('Pagou em ${_dia(pg.data)}', style: EdTexto.rotulo(context))),
            Text('− ${brl(pg.centavos / 100)}', style: EdTexto.mono(context)),
          ]),
        ),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(child: Text('Saldo', style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600))),
        Text(brl(e.restante), style: EdTexto.mono(context).copyWith(fontWeight: FontWeight.w700)),
      ]),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: TextButton(onPressed: () => _perdoar(context), child: const Text('Perdoar o restante')),
      ),
    ]);
  }
}

class _LinhaQuitado extends StatelessWidget {
  const _LinhaQuitado(this.nome, this.e);
  final String nome;
  final MbEmprestimo e;

  @override
  Widget build(BuildContext context) {
    final perdoado = e.perdoadoEm != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$nome · ${_dia(e.data)}', style: EdTexto.corpo(context)),
            Text(perdoado ? 'Perdoado ${brl(e.perdoado)} em ${_dia(e.perdoadoEm)}' : 'Pago por completo',
                style: EdTexto.rotulo(context)),
          ]),
        ),
        Text(brl(e.original), style: EdTexto.mono(context)),
        if (perdoado)
          TextButton(onPressed: () => mbDesfazerPerdao(e.txId), child: const Text('Desfazer')),
      ]),
    );
  }
}
