import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/arrumarDados.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/widgets/exportCSV.dart' show cleanFileNameString;
import 'package:budget/widgets/exportDB.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class ArrumarDadosPage extends StatelessWidget {
  const ArrumarDadosPage({super.key, this.conteudo});
  final Widget? conteudo;

  @override
  Widget build(BuildContext context) => PageFramework(
        dragDownToDismiss: true,
        title: "Arrumar dados",
        listWidgets: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 24),
            child: conteudo ?? const ArrumarDados(),
          ),
        ],
      );
}

Future<bool> _backupPadrao(BuildContext context) async =>
    await saveDBFileToDevice(
        boxContext: context,
        fileName:
            "renancash-antes-de-arrumar-${cleanFileNameString(DateTime.now().toString())}.sql") ==
    true;

Future<List<TransactionWallet>> _arquivadasPadrao() async {
  final pks = carteirasArquivadas();
  return [
    for (final w in await database.getAllWallets())
      if (pks.contains(w.walletPk)) w
  ];
}

/// Prévia da limpeza (pares a juntar, categorias a migrar, carteiras a arquivar, categorias vazias) e aplicação
/// com confirmação e backup antes.
class ArrumarDados extends StatefulWidget {
  const ArrumarDados({
    super.key,
    this.calcular = arrumarCalcular,
    this.aplicar = arrumarAplicar,
    this.backup = _backupPadrao,
    this.arquivadas = _arquivadasPadrao,
    this.desarquivar = arrumarDesarquivar,
  });

  // Injetáveis para os testes não precisarem do banco nem do arquivo.
  final Future<ArrumarPlano> Function() calcular, aplicar;
  final Future<bool> Function(BuildContext context) backup;
  final Future<List<TransactionWallet>> Function() arquivadas;
  final Future<void> Function(String walletPk) desarquivar;

  @override
  State<ArrumarDados> createState() => _ArrumarDadosState();
}

class _ArrumarDadosState extends State<ArrumarDados> {
  ArrumarPlano? _plano, _aplicado;
  List<TransactionWallet> _arquivadas = const [];
  String? _erro;
  bool _aplicando = false;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    setState(() => _erro = null);
    try {
      final plano = await widget.calcular();
      final arquivadas = await widget.arquivadas();
      if (mounted) {
        setState(() {
          _plano = plano;
          _arquivadas = arquivadas;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _erro = "Não foi possível calcular: $e");
    }
  }

  Future<void> _aplicar() async {
    final confirmou = await openPopup<bool>(
      context,
      title: "Aplicar mudanças?",
      description: "Antes, um backup completo é salvo no aparelho. Para desfazer, "
          "restaure esse backup em Dados e backup.",
      onSubmitLabel: "Aplicar",
      onCancelLabel: "Continuar revisando",
      onSubmit: () => popRoute(context, true),
      onCancel: () => popRoute(context, false),
    );
    if (confirmou != true || !mounted) return;
    setState(() {
      _aplicando = true;
      _erro = null;
    });
    try {
      final salvo = await widget.backup(context);
      if (!mounted) return;
      if (!salvo) {
        setState(() => _erro = "O backup não foi salvo. Nada foi alterado.");
        return;
      }
      final feito = await widget.aplicar();
      final arquivadas = await widget.arquivadas();
      if (!mounted) return;
      setState(() {
        _aplicado = feito;
        _arquivadas = arquivadas;
      });
      sincronizarMeuBanco(); // manda ajustes e exclusões ao servidor
    } catch (e) {
      if (mounted) setState(() => _erro = "Não foi possível aplicar: $e");
    } finally {
      if (mounted) setState(() => _aplicando = false);
    }
  }

  Future<void> _desarquivar(TransactionWallet w) async {
    await widget.desarquivar(w.walletPk);
    final arquivadas = await widget.arquivadas();
    if (mounted) setState(() => _arquivadas = arquivadas);
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final corpo = EdTexto.corpo(context);
    final plano = _plano;
    final aplicado = _aplicado;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
            "Junta lançamentos manuais repetidos no Meu Banco, leva as categorias do "
            "Meu Banco para as suas, arquiva carteiras antigas e apaga categorias vazias. "
            "Revise antes de aplicar.",
            style: corpo.copyWith(color: e.mu)),
        const SizedBox(height: 16),
        if (_erro != null) ...[
          Text(_erro!, style: corpo.copyWith(color: e.warntx)),
          const SizedBox(height: 8),
        ],
        if (aplicado != null)
          _Resultado(plano: aplicado)
        else if (plano == null && _erro == null)
          const Center(child: CircularProgressIndicator())
        else if (plano == null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(onPressed: _carregar, child: const Text("Tentar de novo")),
          )
        else if (plano.vazio)
          Text("Nada para arrumar.", style: corpo)
        else ...[
          _Previa(plano: plano),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _aplicando ? null : _aplicar,
            child: Text(_aplicando ? "Aplicando…" : "Aplicar"),
          ),
        ],
        if (_arquivadas.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text("Carteiras arquivadas", style: EdTexto.h2(context)),
          const SizedBox(height: 6),
          for (final w in _arquivadas)
            Row(children: [
              Expanded(child: Text(w.name, style: corpo)),
              TextButton(
                  onPressed: () => _desarquivar(w),
                  child: const Text("Mostrar de novo")),
            ]),
        ],
      ],
    );
  }
}

final NumberFormat _reais = NumberFormat.currency(locale: "pt_BR", symbol: "R\$");
final DateFormat _dia = DateFormat("dd/MM");

// Até 5 exemplos por item; o resto vira "e mais N".
List<String> _exemplos(List<String> linhas) => [
      ...linhas.take(5),
      if (linhas.length > 5) "e mais ${linhas.length - 5}",
    ];

String _nomeCategoriaMb(String pk) => pk.replaceFirst(RegExp(r"^mb:cat:[dr]:"), "");

class _Previa extends StatelessWidget {
  const _Previa({required this.plano});
  final ArrumarPlano plano;

  @override
  Widget build(BuildContext context) {
    final p = plano;
    // Categoria do Meu Banco -> destino, com a contagem.
    final porOrigem = <String, ({String destino, int n})>{};
    for (final m in p.migracoes) {
      final origem = _nomeCategoriaMb(m.transacao.categoryFk);
      porOrigem[origem] =
          (destino: m.destino.rotulo, n: (porOrigem[origem]?.n ?? 0) + 1);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (p.pares.isNotEmpty)
        _Item(
          titulo: "Juntar ${p.pares.length} lançamentos repetidos",
          detalhe:
              "Fica o do banco com o seu título, categoria, nota e vínculos; o manual sai.",
          linhas: _exemplos([
            for (final par in p.pares)
              "${par.manual.name.trim().isEmpty ? "(sem título)" : par.manual.name.trim()} · "
                  "${_reais.format(par.manual.amount)} · ${_dia.format(par.manual.dateCreated)}"
                  " → ${par.banco.name} (${par.dias == 0 ? "mesmo dia" : "${par.dias} d"})"
          ]),
        ),
      if (p.migracoes.isNotEmpty)
        _Item(
          titulo: "Migrar ${p.migracoes.length} lançamentos de categoria",
          detalhe: "O mesmo mapa vale para as próximas importações do Meu Banco.",
          linhas: [
            for (final e in porOrigem.entries)
              "${e.key} → ${e.value.destino} (${e.value.n})"
          ],
        ),
      if (p.carteiras.isNotEmpty)
        _Item(
          titulo: "Arquivar ${p.carteiras.length} carteiras",
          detalhe: "Somem das listas e dos totais; nada é apagado.",
          linhas: [for (final w in p.carteiras) w.name],
        ),
      if (p.categorias.isNotEmpty)
        _Item(
          titulo: "Apagar ${p.categorias.length} categorias vazias",
          detalhe: "Sem lançamentos e fora de orçamentos, limites, regras e títulos.",
          linhas: [p.categorias.map((c) => c.name).join(", ")],
        ),
    ]);
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.titulo, required this.detalhe, required this.linhas});
  final String titulo, detalhe;
  final List<String> linhas;

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final corpo = EdTexto.corpo(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: e.surf,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: e.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(titulo, style: EdTexto.h2(context)),
        const SizedBox(height: 4),
        Text(detalhe, style: EdTexto.rotulo(context).copyWith(color: e.mu)),
        if (linhas.isNotEmpty) const SizedBox(height: 8),
        for (final l in linhas)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(l, style: corpo, maxLines: 8, overflow: TextOverflow.ellipsis),
          ),
      ]),
    );
  }
}

class _Resultado extends StatelessWidget {
  const _Resultado({required this.plano});
  final ArrumarPlano plano;

  @override
  Widget build(BuildContext context) {
    final p = plano;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: cores(context).surf, borderRadius: BorderRadius.circular(16)),
      child: Text(
        p.vazio
            ? "Nada para arrumar."
            : "Pronto. ${p.pares.length} lançamentos juntados, ${p.migracoes.length} "
                "migrados de categoria, ${p.carteiras.length} carteiras arquivadas e "
                "${p.categorias.length} categorias apagadas. O backup foi salvo antes.",
        style: EdTexto.corpo(context),
      ),
    );
  }
}
