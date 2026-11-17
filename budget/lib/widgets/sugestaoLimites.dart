import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl;
import 'package:budget/struct/mbSync/sugestaoLimites.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

/// Abre a sugestão de limites por categoria do orçamento [b] (média dos últimos ciclos).
void abrirSugestaoLimites(BuildContext context, Budget b) {
  final carteiras = Provider.of<AllWallets>(context, listen: false);
  openBottomSheet(
    context,
    PopupFramework(
      title: 'Limites por categoria',
      subtitle: 'Orçamento ${b.name} · média dos últimos $mbCiclosDaSugestao ciclos',
      child: FutureBuilder<List<MbSugestaoLimite>>(
        future: mbCalcularSugestaoLimites(b, carteiras),
        builder: (context, s) {
          if (s.hasError) {
            return _Aviso('Não foi possível calcular agora: ${s.error}');
          }
          final lista = s.data;
          if (lista == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          if (lista.isEmpty) {
            return const _Aviso(
                'Sem gastos suficientes nos últimos ciclos para sugerir limites.');
          }
          return SugestaoLimites(
            sugestoes: lista,
            onSalvar: (valores) async {
              await mbSalvarLimites(b, valores, carteiras);
              if (context.mounted) popRoute(context);
              openSnackbar(SnackbarMessage(
                  title: valores.length == 1
                      ? '1 limite salvo no ${b.name}'
                      : '${valores.length} limites salvos no ${b.name}'));
            },
          );
        },
      ),
    ),
  );
}

class _Aviso extends StatelessWidget {
  const _Aviso(this.texto);
  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(texto,
            textAlign: TextAlign.center, style: EdTexto.corpo(context)),
      );
}

/// "1.234,56" ou "1234.56" -> 1234.56; null se não for número.
double? lerValorLimite(String texto) {
  final t = texto.trim().replaceAll('R\$', '').replaceAll(' ', '');
  final normal = t.contains(',') ? t.replaceAll('.', '').replaceAll(',', '.') : t;
  return double.tryParse(normal);
}

/// Lista das sugestões: marcar, ajustar o valor e salvar. As [preMarcadas] primeiras sem limite vêm marcadas.
class SugestaoLimites extends StatefulWidget {
  const SugestaoLimites(
      {super.key, required this.sugestoes, required this.onSalvar, this.preMarcadas = 5});
  final List<MbSugestaoLimite> sugestoes;
  final Future<void> Function(Map<String, double> valores) onSalvar;
  final int preMarcadas;

  @override
  State<SugestaoLimites> createState() => _SugestaoLimitesState();
}

class _SugestaoLimitesState extends State<SugestaoLimites> {
  late final Set<String> marcadas = {
    for (final s in widget.sugestoes.where((s) => s.atual == null).take(widget.preMarcadas))
      s.categoria.categoryPk
  };
  late final Map<String, TextEditingController> campos = {
    for (final s in widget.sugestoes)
      s.categoria.categoryPk: TextEditingController(text: s.sugerido.toStringAsFixed(0))
  };
  bool salvando = false;

  @override
  void dispose() {
    for (final c in campos.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, double> get _valores => {
        for (final pk in marcadas)
          if ((lerValorLimite(campos[pk]!.text) ?? 0) > 0) pk: lerValorLimite(campos[pk]!.text)!
      };

  @override
  Widget build(BuildContext context) {
    final valores = _valores;
    final rotulo = EdTexto.rotulo(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
            'Reembolsos de conta rachada já descontados. Marque as categorias, ajuste o valor e salve; nada muda antes disso.',
            style: rotulo),
        const SizedBox(height: 8),
        for (final s in widget.sugestoes)
          Builder(builder: (context) {
            final pk = s.categoria.categoryPk;
            final vezes = s.vezes.round();
            return CheckboxListTile(
              key: ValueKey('limite-$pk'),
              value: marcadas.contains(pk),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => setState(() {
                if (v == true) {
                  marcadas.add(pk);
                } else {
                  marcadas.remove(pk);
                }
              }),
              title: Text(s.nome,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w500)),
              subtitle: Text(
                  [
                    'média ${brl(s.media)}',
                    if (vezes > 0) '~$vezes× por ciclo',
                    if (s.atual != null) 'hoje ${brl(s.atual!)}',
                  ].join(' · '),
                  style: rotulo),
              secondary: SizedBox(
                width: 92,
                child: TextField(
                  controller: campos[pk],
                  enabled: !salvando,
                  textAlign: TextAlign.end,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                  onChanged: (_) => setState(() {
                    marcadas.add(pk);
                  }),
                  style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(isDense: true, prefixText: 'R\$ '),
                ),
              ),
            );
          }),
        const SizedBox(height: 16),
        Button(
          label: valores.isEmpty
              ? 'Marque ao menos uma categoria'
              : valores.length == 1
                  ? 'Salvar 1 limite'
                  : 'Salvar ${valores.length} limites',
          disabled: valores.isEmpty || salvando,
          onTap: () async {
            if (valores.isEmpty || salvando) return;
            setState(() => salvando = true);
            try {
              await widget.onSalvar(valores);
            } finally {
              if (mounted) setState(() => salvando = false);
            }
          },
        ),
      ],
    );
  }
}
