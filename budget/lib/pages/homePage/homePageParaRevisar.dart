import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/widgets/editorial/movimento.dart' show ToqueEscala;
import 'package:budget/struct/mbSync/classificar.dart' show MbLancamentoIa, mbChavePadrao;
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl, diaMes;
import 'package:budget/struct/mbSync/reembolso.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/tipoMovimento.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/functions.dart' show popRoute;
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/transactionEntry/transactionLabel.dart' show nomeSemEspacosRepetidos;
import 'package:budget/widgets/util/keepAliveClientMixin.dart';
import 'package:budget/widgets/editorial/itemClassificar.dart' show ParteDeConta;
import 'package:budget/widgets/editorial/reembolsoConta.dart'
    show mbEscolherGastoRachado, mbNomeDoPagador, semGastoReembolso;
import 'package:flutter/material.dart';

const _rotulos = {
  'emprestimo': 'Empréstimo',
  'investimento': 'Investimento',
  'ajuda': 'Ajuda',
  'devolucao': 'Devolução',
  'reembolso': 'Reembolso',
  'renda': 'Renda',
};
// Tipo de cada resposta, para a cor do ponto no botão (ajuda ao pai é gasto em Família).
const _tipoDaResposta = {
  'emprestimo': TipoMov.emprestimo,
  'investimento': TipoMov.investimento,
  'ajuda': TipoMov.gasto,
  'devolucao': TipoMov.receita,
  'reembolso': TipoMov.receita,
  'renda': TipoMov.receita,
};
const int _itensNoCartao = 3;

/// Categoria de despesa pelo nome: a do RenanCash com o mesmo nome ou a própria do Meu Banco.
Future<String> _pkDaCategoria(String nome) async {
  final todas = await database.select(database.categories).get();
  for (final c in todas) {
    if (!c.income && c.name.toLowerCase() == nome.toLowerCase()) return c.categoryPk;
  }
  return mbPkCategoria(nome, false);
}

/// Cartão "Para validar" da Início: some quando a fila está vazia; cada item tem os botões das opções.
class HomePageParaRevisar extends StatefulWidget {
  const HomePageParaRevisar({super.key, this.atualizar = true});
  final bool atualizar;

  @override
  State<HomePageParaRevisar> createState() => _HomePageParaRevisarState();
}

class _HomePageParaRevisarState extends State<HomePageParaRevisar> {
  @override
  void initState() {
    super.initState();
    if (widget.atualizar) mbAtualizarRevisar();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<MbItemRevisao>>(
      valueListenable: meuBancoRevisar,
      builder: (context, itens, _) {
        if (itens.isEmpty) return const SizedBox.shrink();
        final e = cores(context);
        final visiveis = itens.take(_itensNoCartao).toList();
        return KeepAliveClientMixin(
          child: Container(
            margin: const EdgeInsetsDirectional.only(
                start: 13, end: 13, bottom: 13),
            padding: const EdgeInsetsDirectional.all(18),
            decoration: BoxDecoration(
              color: e.bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: e.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('Para validar',
                        style: EdTexto.corpo(context).copyWith(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                  ),
                  Container(
                    constraints: const BoxConstraints(minWidth: 24),
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: e.acc,
                        borderRadius: BorderRadius.circular(12)),
                    child: Text('${itens.length}',
                        style: EdTexto.mono(context).copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: e.bg)),
                  ),
                ]),
                for (var idx = 0; idx < visiveis.length; idx++) ...[
                  if (idx == 0)
                    const SizedBox(height: 14)
                  else
                    Divider(height: 28, thickness: 1, color: e.line),
                  ItemParaRevisar(item: visiveis[idx]),
                ],
                if (itens.length > _itensNoCartao) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: e.tx,
                        backgroundColor: e.surf,
                        side: BorderSide(color: e.line),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => openBottomSheet(
                          context,
                          PopupFramework(
                              title: 'Para validar',
                              child: ValueListenableBuilder<List<MbItemRevisao>>(
                                valueListenable: meuBancoRevisar,
                                builder: (context, todos, _) =>
                                    Column(children: [
                                  for (var idx = 0; idx < todos.length; idx++) ...[
                                    if (idx > 0)
                                      Divider(
                                          height: 28,
                                          thickness: 1,
                                          color: e.line),
                                    ItemParaRevisar(item: todos[idx]),
                                  ]
                                ]),
                              ))),
                      child: Text('Ver todos (${itens.length})',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class ItemParaRevisar extends StatefulWidget {
  const ItemParaRevisar({super.key, required this.item});
  final MbItemRevisao item;

  @override
  State<ItemParaRevisar> createState() => _ItemParaRevisarState();
}

class _ItemParaRevisarState extends State<ItemParaRevisar> {
  bool _enviando = false, _escolhendo = false;

  Future<void> _responder(String resposta, {String? categoriaPk, String? reembolsoDe, String? trocoDe}) async {
    if (_enviando) return;
    if (mounted) setState(() => _enviando = true);
    try {
      await mbResponderRevisao(widget.item, resposta,
          categoriaPk: categoriaPk, reembolsoDe: reembolsoDe, trocoDe: trocoDe);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _escolherCategoria() async {
    final nomes = [...mbCategoriasProprias, mbCategoriaOutros];
    final dest = widget.item.destinatario;
    final nome = await openBottomSheet(
      context,
      PopupFramework(
        title: 'Categoria',
        subtitle: dest == null ? null : nomeSemEspacosRepetidos(dest),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final n in nomes)
            BotaoEscolha(
              rotulo: n,
              onTap: () => popRoute(context, n),
            ),
        ]),
      ),
    );
    if (nome is String) {
      await _responder('categoria', categoriaPk: await _pkDaCategoria(nome));
    }
  }

  // Reembolso: o usuário confirma qual gasto dos últimos 30 dias foi reembolsado (ou nenhum). Fechar a folha não responde.
  Future<void> _escolherReembolso() async {
    if (_enviando || _escolhendo) return;
    _escolhendo = true;
    try {
      await _escolherReembolsoSemTrava();
    } finally {
      _escolhendo = false;
    }
  }

  Future<void> _escolherReembolsoSemTrava() async {
    final sugestoes = await mbSugestoesDoItem(widget.item);
    if (!mounted) return;
    final escolha = await mbEscolherGastoRachado(context,
        sugestoes: sugestoes,
        valor: widget.item.valor,
        data: DateTime.tryParse(widget.item.data ?? '') ?? DateTime.now(),
        comNenhum: true);
    if (escolha is MbGastoCandidato) {
      await _responder('reembolso', reembolsoDe: escolha.pk.substring(mbPrefixo.length));
    } else if (escolha == semGastoReembolso) {
      await _responder('reembolso');
    }
  }

  Future<void> _marcarSalario(String txId) async {
    if (_enviando) return;
    setState(() => _enviando = true);
    final erro = await mbMarcarSalario(txId);
    if (erro != null) openSnackbar(SnackbarMessage(title: erro));
    if (mounted) setState(() => _enviando = false);
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final data = DateTime.tryParse(i.data ?? '');
    final pagador = i.tipo == 'pix_recebido'
        ? mbChavePadrao(i.destinatario ?? i.descricao ?? '')
        : '';
    final dest = i.tipo == 'pix_enviado'
        ? mbChavePadrao(i.destinatario ?? i.descricao ?? '')
        : '';
    final destBruto = i.destinatario == null
        ? ''
        : nomeSemEspacosRepetidos(i.destinatario!.trim());
    final titulo = i.ehSalario
        ? 'Salário não detectado'
        : switch (i.tipo) {
            'pix_enviado' => dest.isNotEmpty
                ? 'Pix enviado a ${mbNomeDoPagador(dest)}'
                : 'Pix enviado${destBruto.isEmpty ? '' : ' a $destBruto'}',
            'envio_santander' => 'Enviado ao Santander',
            _ => pagador.isEmpty
                ? 'Pix recebido'
                : 'Pix recebido de ${mbNomeDoPagador(pagador)}',
          };
    final detalhe = i.ehSalario
        ? 'Há ${i.dias} dias sem salário no Inter. Qual entrada é o salário?'
        : '${brl(i.valor.abs())}${data == null ? '' : ' · ${diaMes(data)}'}';
    // Pix enviado é gasto; recebido é receita; o envio ao Santander ainda não tem tipo até responder.
    final tipoItem = i.tipo == 'pix_enviado'
        ? TipoMov.gasto
        : i.tipo == 'envio_santander'
            ? TipoMov.aClassificar
            : TipoMov.receita;
    // Quem já mandou a parte de 2 contas ou mais: o gasto provável já vem no topo, com Confirmar.
    final recorrente = i.tipo == 'pix_recebido' &&
        i.txId != null &&
        mbVezesQueRachou(meuBancoReembolsos.value, mbChavePadrao(i.descricao ?? '')) >= 2;
    // Pix enviado à pessoa que mandou um reembolso há até 3 dias: pode ser o troco (a decisão é do usuário; recusar mantém a categoria).
    final troco = i.tipo == 'pix_enviado' && data != null
        ? mbSugerirTroco(meuBancoReembolsos.value, meuBancoTrocos.value,
            descricao: i.descricao ?? '', valor: i.valor, data: data)
        : null;
    return Opacity(
      opacity: _enviando ? 0.5 : 1,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconeTipo(tipoItem),
          const SizedBox(width: 10),
          Expanded(
            child: Text(titulo,
                style: EdTexto.corpo(context).copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cores(context).tx)),
          ),
        ]),
        const SizedBox(height: 2),
        Text(detalhe, style: EdTexto.rotulo(context).copyWith(color: i.ehSalario ? null : tipoItem.cor(context))),
        const SizedBox(height: 14),
        if (recorrente && data != null) ...[
          ParteDeConta(
              lancamento: MbLancamentoIa(
                  pk: '$mbPrefixo${i.txId}', descricao: i.descricao ?? '', valor: i.valor, data: data),
              enviando: _enviando,
              aoLigar: (g) => _responder('reembolso', reembolsoDe: g.pk.substring(mbPrefixo.length))),
          const SizedBox(height: 12),
        ],
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (troco != null)
            _botao('Devolvi parte do reembolso de ${mbNomeDoPagador(troco.pagador)}',
                () => _responder('troco', trocoDe: troco.reembolsoPk.substring(mbPrefixo.length)),
                tipo: TipoMov.gasto),
          if (i.tipo == 'pix_enviado')
            _botao('Escolher categoria', _escolherCategoria, tipo: TipoMov.gasto),
          for (final r in i.respostas)
            _botao(_rotulos[r]!,
                r == 'reembolso' ? _escolherReembolso : () => _responder(r),
                tipo: _tipoDaResposta[r]),
          for (final c in i.candidatos)
            _botao(
                '${brl(c.valor)} · ${diaMes(DateTime.tryParse(c.data) ?? DateTime.now())}',
                () => _marcarSalario(c.txId)),
        ]),
      ]),
    );
  }

  Widget _botao(String rotulo, VoidCallback onTap, {TipoMov? tipo}) =>
      BotaoEscolha(rotulo: rotulo, tipo: tipo, onTap: _enviando ? null : onTap);
}

/// Resposta em chip da triagem (Para revisar e contas vencidas).
class BotaoEscolha extends StatelessWidget {
  const BotaoEscolha({super.key, required this.rotulo, this.onTap, this.tipo});
  final String rotulo;
  final TipoMov? tipo; // ponto na cor do tipo (gasto, receita, investimento, empréstimo)
  final VoidCallback? onTap; // null: enviando, sem toque

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    return Semantics(
        button: true,
        label: rotulo,
        excludeSemantics: true,
        // excludeSemantics tira a ação do GestureDetector interno: o toque do leitor de tela vem daqui.
        onTap: onTap,
        child: ToqueEscala(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: DecoratedBox(
              decoration: BoxDecoration(
                  color: e.chip, borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tipo != null) ...[
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: tipo!.cor(context))),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(rotulo,
                          style: EdTexto.corpo(context)
                              .copyWith(fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
  }
}
