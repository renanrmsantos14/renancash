import 'package:budget/functions.dart' show popRoute;
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl, diaMes;
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:flutter/material.dart';

// Folhas da fila "Para revisar" para empréstimos: qual empréstimo um Pix recebido pagou, para onde vai a sobra e de
// quem é um empréstimo novo (ou a qual empréstimo da pessoa somar o Pix enviado).

String _dia(String? data) {
  final d = DateTime.tryParse(data ?? '');
  return d == null ? '' : diaMes(d);
}

class _LinhaEmprestimo extends StatelessWidget {
  const _LinhaEmprestimo(this.e, {required this.onTap});
  final MbEmprestimo e;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = cores(context);
    final nome = (e.pessoa ?? '').trim().isEmpty ? 'Sem pessoa' : e.pessoa!.trim();
    final parcial = e.parcial ? ' · de ${brl(e.original)}' : '';
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(nome, style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600)),
                Text('${_dia(e.data)}$parcial', style: EdTexto.rotulo(context)),
              ]),
            ),
            Text(brl(e.restante), style: EdTexto.mono(context).copyWith(color: c.tx, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// "Qual empréstimo foi pago?": os da [pessoa] primeiro, depois "Outros empréstimos". Devolve o escolhido ou null (fechou).
Future<MbEmprestimo?> mbEscolherEmprestimo(BuildContext context,
    {required MbEmprestimos emprestimos, String? pessoa, required double valor, String titulo = 'Qual empréstimo foi pago?'}) async {
  final grupos = emprestimos.paraPagamento(pessoa);
  final c = cores(context);
  final r = await openBottomSheet(
    context,
    PopupFramework(
      title: titulo,
      subtitle: brl(valor.abs()),
      child: Builder(
        builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final e in grupos.daPessoa) _LinhaEmprestimo(e, onTap: () => popRoute(ctx, e)),
          if (grupos.daPessoa.isNotEmpty && grupos.outros.isNotEmpty) ...[
            const SizedBox(height: 8),
            Divider(height: 24, thickness: 1, color: c.line),
          ],
          if (grupos.outros.isNotEmpty) ...[
            if (grupos.daPessoa.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('Outros empréstimos', style: EdTexto.rotulo(context)),
              ),
            for (final e in grupos.outros) _LinhaEmprestimo(e, onTap: () => popRoute(ctx, e)),
          ],
        ]),
      ),
    ),
  );
  return r is MbEmprestimo ? r : null;
}

/// Para onde vai o que o Pix pagou além do saldo: 'emprestimo' (outro da pessoa), 'reembolso' ou 'renda'. null: fechou.
Future<String?> mbEscolherDestinoDaSobra(BuildContext context,
    {required double sobra, required bool temOutroEmprestimo}) async {
  final r = await openBottomSheet(
    context,
    PopupFramework(
      title: 'O Pix passou do saldo',
      subtitle: 'Sobram ${brl(sobra)}. Para onde vão?',
      child: Builder(
        builder: (ctx) => Wrap(spacing: 8, runSpacing: 8, children: [
          if (temOutroEmprestimo)
            _Opcao('Abater outro empréstimo', () => popRoute(ctx, 'emprestimo')),
          _Opcao('Reembolso de um gasto', () => popRoute(ctx, 'reembolso')),
          _Opcao('Renda', () => popRoute(ctx, 'renda')),
        ]),
      ),
    ),
  );
  return r is String ? r : null;
}

class _Opcao extends StatelessWidget {
  const _Opcao(this.rotulo, this.onTap);
  final String rotulo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = cores(context);
    return Semantics(
      button: true,
      label: rotulo,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: DecoratedBox(
            decoration: BoxDecoration(color: c.chip, borderRadius: BorderRadius.circular(10)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(rotulo, style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pessoa de um empréstimo: o escolhido (da pessoa sugerida ou, em "Outros empréstimos", de qualquer um aberto) soma o
/// Pix a ele; "Criar empréstimo" abre um novo só com a pessoa.
typedef MbPessoaDoEmprestimo = ({String pessoa, String? emprestimoId});

Future<MbPessoaDoEmprestimo?> mbEscolherPessoaDoEmprestimo(BuildContext context,
    {required String sugestao,
    required double valor,
    required List<MbEmprestimo> daPessoa,
    List<MbEmprestimo> outros = const []}) async {
  final r = await openBottomSheet(
    context,
    PopupFramework(
      title: 'Empréstimo',
      subtitle: brl(valor.abs()),
      child: _PessoaDoEmprestimo(sugestao: sugestao, daPessoa: daPessoa, outros: outros),
    ),
  );
  return r is MbPessoaDoEmprestimo ? r : null;
}

class _PessoaDoEmprestimo extends StatefulWidget {
  const _PessoaDoEmprestimo({required this.sugestao, required this.daPessoa, this.outros = const []});
  final String sugestao;
  final List<MbEmprestimo> daPessoa;
  final List<MbEmprestimo> outros; // os abertos de outras pessoas (ou com nome escrito diferente): também dá para somar

  @override
  State<_PessoaDoEmprestimo> createState() => _PessoaDoEmprestimoState();
}

class _PessoaDoEmprestimoState extends State<_PessoaDoEmprestimo> {
  late final _nome = TextEditingController(text: widget.sugestao);

  @override
  void dispose() {
    _nome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = cores(context);
    final pronto = _nome.text.trim().isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.daPessoa.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('Somar a um empréstimo de ${widget.sugestao.trim().isEmpty ? 'quem já tem' : widget.sugestao.trim()}',
              style: EdTexto.rotulo(context)),
        ),
        for (final e in widget.daPessoa) _linha(e),
        Divider(height: 24, thickness: 1, color: c.line),
      ],
      if (widget.outros.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(widget.daPessoa.isEmpty ? 'Somar a um empréstimo existente' : 'Outros empréstimos',
              style: EdTexto.rotulo(context)),
        ),
        for (final e in widget.outros) _linha(e),
        Divider(height: 24, thickness: 1, color: c.line),
      ],
      Text('Empréstimo novo para', style: EdTexto.rotulo(context)),
      const SizedBox(height: 6),
      TextField(
        controller: _nome,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(hintText: 'Nome da pessoa', border: OutlineInputBorder()),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => pronto ? _criar() : null,
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 48,
        child: FilledButton(onPressed: pronto ? _criar : null, child: const Text('Criar empréstimo')),
      ),
    ]);
  }

  Widget _linha(MbEmprestimo e) =>
      _LinhaEmprestimo(e, onTap: () => popRoute(context, (pessoa: (e.pessoa ?? '').trim(), emprestimoId: e.txId)));

  void _criar() => popRoute(context, (pessoa: _nome.text.trim(), emprestimoId: null));
}
