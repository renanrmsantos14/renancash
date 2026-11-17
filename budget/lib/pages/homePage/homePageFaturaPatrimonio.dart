import 'package:budget/colors.dart';
import 'package:budget/struct/mbSync/emprestimos.dart' show meuBancoEmprestimos;
import 'package:budget/struct/mbSync/estadoInicio.dart';
import 'package:budget/struct/mbSync/revisao.dart' show meuBancoRevisar;
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/util/keepAliveClientMixin.dart';
import 'package:flutter/material.dart';

/// Dados do Patrimônio (cartão e âncora do gráfico). Recarregam quando `mbAtualizarRevisar` roda
/// (após cada sincronização e ao mexer na fila), que também alimenta o "Para revisar".
/// Carregando: nada. Sem Meu Banco no aparelho: [semDados].
class CarregaPatrimonio extends StatefulWidget {
  const CarregaPatrimonio(
      {super.key, required this.construir, this.semDados = const SizedBox.shrink()});
  final Widget Function(BuildContext, PatrimonioInicio) construir;
  final Widget semDados;

  @override
  State<CarregaPatrimonio> createState() => _CarregaPatrimonioState();
}

class _CarregaPatrimonioState extends State<CarregaPatrimonio> {
  PatrimonioInicio? _dados;
  bool _falhou = false;
  late final Listenable _gatilho = Listenable.merge([meuBancoRevisar, meuBancoEmprestimos]);
  late final RecargaColapsada _recarga = RecargaColapsada(_carregar);

  @override
  void initState() {
    super.initState();
    _gatilho.addListener(_recarga.pedir);
    _recarga.pedir();
  }

  @override
  void dispose() {
    _gatilho.removeListener(_recarga.pedir);
    _recarga.fechar();
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      final d = await mbCarregarPatrimonioInicio(DateTime.now());
      if (mounted) setState(() => _dados = d);
    } catch (_) {
      // Dados guardados ilegíveis: mantém o que já está na tela (na 1ª carga, [semDados]).
      if (mounted && _dados == null) setState(() => _falhou = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _dados;
    if (d == null) return _falhou ? widget.semDados : const SizedBox.shrink();
    return d.semDados ? widget.semDados : widget.construir(context, d);
  }
}

Widget _cartao(BuildContext context, List<Widget> filhos) => KeepAliveClientMixin(
      child: Container(
        margin: const EdgeInsetsDirectional.only(start: 13, end: 13, bottom: 13),
        padding: const EdgeInsetsDirectional.all(15),
        decoration: BoxDecoration(
          color: getColor(context, "lightDarkAccentHeavyLight"),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: filhos),
      ),
    );

Widget _linha(String rotulo, String valor, Color suave, {bool forte = false}) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Expanded(
            child: TextFont(
                text: rotulo,
                fontSize: forte ? 16 : 14,
                fontWeight: forte ? FontWeight.bold : FontWeight.normal,
                textColor: forte ? null : suave)),
        TextFont(
            text: valor,
            fontSize: forte ? 16 : 14,
            fontWeight: forte ? FontWeight.bold : FontWeight.normal),
      ]),
    );

/// Patrimônio = contas correntes + poupanças + investimentos − fatura atual (os saldos reais do Meu Banco).
/// Empréstimos ficam de fora; as carteiras manuais aparecem abaixo, também fora do total.
class HomePagePatrimonio extends StatelessWidget {
  const HomePagePatrimonio(this.dados, {super.key});
  final PatrimonioInicio dados;

  @override
  Widget build(BuildContext context) {
    final suave = getColor(context, "textLight");
    final p = dados.patrimonio;
    return _cartao(context, [
      TextFont(text: 'Patrimônio', fontSize: 18, fontWeight: FontWeight.bold),
      const SizedBox(height: 2),
      TextFont(text: brl(p.total), fontSize: 26, fontWeight: FontWeight.bold),
      const SizedBox(height: 4),
      _linha('Contas correntes', brl(p.correntes), suave),
      if (p.poupancas != 0) _linha('Poupanças', brl(p.poupancas), suave),
      _linha('Investimentos', brl(p.investimentos), suave),
      _linha('Fatura atual', '− ${brl(p.fatura)}', suave),
      if (dados.carteiras.isNotEmpty) ...[
        const SizedBox(height: 10),
        TextFont(
            text: 'Carteiras manuais · fora do total',
            fontSize: 14,
            fontWeight: FontWeight.bold,
            textColor: suave),
        for (final c in dados.carteiras) _linha(c.nome, brl(c.saldo), suave),
      ],
    ]);
  }
}
