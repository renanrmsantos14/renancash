import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/currencyFunctions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/rachadas.dart';
import 'package:budget/struct/tipoMovimento.dart';
import 'package:budget/widgets/editorial/layoutDesktop.dart';
import 'package:budget/widgets/editorial/painelTransacao.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

enum _Filtro { todas, despesas, receitas }

/// Linha da tabela: só o que a tabela mostra (testável sem banco).
class LinhaTransacao {
  const LinhaTransacao({
    required this.transacao,
    required this.categoria,
    required this.conta,
    required this.valorPrincipal,
    this.rachada,
    this.indicacao = '',
  });
  final Transaction transacao;
  final String categoria;
  final String conta;
  final double valorPrincipal; // na moeda principal, com sinal (a minha parte, quando a conta foi rachada)
  final MbRachada? rachada; // conta rachada: Pix de rachar e trocos ficam dentro desta linha
  final String indicacao; // "inclui Pix de Valentina +R$ 50,00…": só aparece numa busca
}

/// Filtra por tipo e por texto (descrição, categoria, conta ou notas).
List<LinhaTransacao> mbFiltrarLinhas(
    List<LinhaTransacao> linhas, String busca, bool? receita) {
  final q = busca.trim().toLowerCase();
  return [
    for (final l in linhas)
      if ((receita == null || l.transacao.income == receita) &&
          (q.isEmpty ||
              '${l.transacao.name} ${l.categoria} ${l.conta} ${l.transacao.note} ${l.rachada?.textoDeBusca ?? ''}'
                  .toLowerCase()
                  .contains(q)))
        l
  ];
}

/// Transações no computador: tabela do mês com busca, filtro e detalhe ao lado.
class TransacoesDesktop extends StatefulWidget {
  const TransacoesDesktop({super.key});

  @override
  State<TransacoesDesktop> createState() => _TransacoesDesktopState();
}

class _TransacoesDesktopState extends State<TransacoesDesktop> {
  DateTime _mes = DateTime(DateTime.now().year, DateTime.now().month);
  final _busca = TextEditingController();
  _Filtro _filtro = _Filtro.todas;
  Map<String, TransactionCategory> _categorias = const {};
  late Stream<List<Transaction>> _transacoes = _streamDoMes();

  Stream<List<Transaction>> _streamDoMes() => database.watchAllTransactions(
      startDate: _mes,
      endDate: DateTime(_mes.year, _mes.month + 1)
          .subtract(const Duration(milliseconds: 1)),
      limit: 100000);

  @override
  void initState() {
    super.initState();
    database.getAllCategories(includeSubCategories: true).then((l) {
      if (mounted)
        setState(() => _categorias = {for (final c in l) c.categoryPk: c});
    });
  }

  @override
  void dispose() {
    _busca.dispose();
    super.dispose();
  }

  void _mudarMes(int passo) => setState(() {
        _mes = DateTime(_mes.year, _mes.month + passo);
        _transacoes = _streamDoMes();
        mbTransacaoSelecionada.value = null;
      });

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final carteiras = Provider.of<AllWallets>(context);
    return ColoredBox(
      color: e.bg,
      child: ValueListenableBuilder<MbRachadas>(
        valueListenable: meuBancoRachadas,
        builder: (context, rachadas, _) => StreamBuilder<List<Transaction>>(
        stream: _transacoes,
        builder: (context, snap) {
          final buscando = _busca.text.trim().isNotEmpty;
          final linhas = [
            for (final t in snap.data ?? const <Transaction>[])
              if (!rachadas.ocultos.contains(t.transactionPk))
              LinhaTransacao(
                transacao: t,
                categoria: _categorias[t.categoryFk]?.name ?? '',
                conta: carteiras.indexedByPk[t.walletFk]?.name ?? '',
                valorPrincipal: rachadas.valorNaLista(t) *
                    amountRatioToPrimaryCurrencyGivenPk(carteiras, t.walletFk),
                rachada: t.amount < 0 ? rachadas.porGasto[t.transactionPk] : null,
                indicacao: buscando && t.amount < 0 ? rachadas.porGasto[t.transactionPk]?.indicacao ?? '' : '',
              )
          ];
          final visiveis = mbFiltrarLinhas(
              linhas,
              _busca.text,
              switch (_filtro) {
                _Filtro.todas => null,
                _Filtro.despesas => false,
                _Filtro.receitas => true,
              });
          // Totais como no resto do app: sem previstas e sem transferências/correções ("0").
          final contaveis = visiveis
              .where((l) => l.transacao.paid && l.transacao.categoryFk != '0');
          final gastos = contaveis
              .where((l) => !l.transacao.income)
              .fold<double>(0, (s, l) => s + l.valorPrincipal.abs());
          final receitas = contaveis
              .where((l) => l.transacao.income)
              .fold<double>(0, (s, l) => s + l.valorPrincipal.abs());
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 12),
                // "Nova transação" fica no topo da lateral; aqui só título e mês.
                child: Row(children: [
                  Flexible(
                    child: Text('Transações',
                        overflow: TextOverflow.ellipsis,
                        style: EdTexto.h1(context)),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                      tooltip: 'Mês anterior',
                      onPressed: () => _mudarMes(-1),
                      icon: const Icon(Icons.chevron_left_rounded)),
                  Text(getMonth(_mes, includeYear: true),
                      style: EdTexto.corpo(context)
                          .copyWith(fontWeight: FontWeight.w600)),
                  IconButton(
                      tooltip: 'Próximo mês',
                      onPressed: () => _mudarMes(1),
                      icon: const Icon(Icons.chevron_right_rounded)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
                child: Row(children: [
                  // Encolhe quando o painel lateral abre; o resumo corta com reticências.
                  Flexible(
                    flex: 3,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: TextField(
                        controller: _busca,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search_rounded, size: 20),
                          hintText: 'Buscar descrição, categoria ou conta',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SegmentedButton<_Filtro>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: _Filtro.todas, label: Text('Todas')),
                      ButtonSegment(
                          value: _Filtro.despesas, label: Text('Despesas')),
                      ButtonSegment(
                          value: _Filtro.receitas, label: Text('Receitas')),
                    ],
                    selected: {_filtro},
                    onSelectionChanged: (s) =>
                        setState(() => _filtro = s.first),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: Text(
                        // Espaço sem quebra: "R$" nunca fica separado do valor.
                        'Gastos ${convertToMoney(carteiras, gastos, allDecimals: true).replaceAll(' ', '\u00A0')} · '
                        'Receitas ${convertToMoney(carteiras, receitas, allDecimals: true).replaceAll(' ', '\u00A0')}',
                        textAlign: TextAlign.end,
                        // Quebra em duas linhas em vez de cortar o total de receitas.
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: EdTexto.rotulo(context)),
                  ),
                ]),
              ),
              _Cabecalho(),
              Expanded(
                child: visiveis.isEmpty
                    ? Center(
                        child: Text(
                            snap.hasData
                                ? 'Nenhuma transação neste filtro.'
                                : 'Carregando…',
                            style:
                                EdTexto.corpo(context).copyWith(color: e.mu)))
                    : ValueListenableBuilder<String?>(
                        valueListenable: mbTransacaoSelecionada,
                        builder: (context, selecionada, _) => ListView.builder(
                          itemCount: visiveis.length,
                          itemExtent: 48,
                          itemBuilder: (context, i) => _Linha(
                            linha: visiveis[i],
                            selecionada: visiveis[i].transacao.transactionPk ==
                                selecionada,
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
        ),
      ),
    );
  }
}

const _colunas = [2, 5, 4, 4, 4]; // Data, Descrição, Categoria, Conta, Valor

class _Cabecalho extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    Widget col(int i, String t, {bool direita = false}) => Expanded(
        flex: _colunas[i],
        child: Text(t,
            textAlign: direita ? TextAlign.end : TextAlign.start,
            style: EdTexto.mono(context)));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
      decoration:
          BoxDecoration(border: Border(bottom: BorderSide(color: e.line))),
      child: Row(children: [
        col(0, 'DATA'),
        col(1, 'DESCRIÇÃO'),
        col(2, 'CATEGORIA'),
        col(3, 'CONTA'),
        col(4, 'VALOR', direita: true),
      ]),
    );
  }
}

class _Linha extends StatefulWidget {
  const _Linha({required this.linha, required this.selecionada});
  final LinhaTransacao linha;
  final bool selecionada;

  @override
  State<_Linha> createState() => _LinhaState();
}

class _LinhaState extends State<_Linha> {
  bool _sobre = false;
  DateTime? _ultimoClique;

  // Clique seleciona na hora (sem a espera do onDoubleTap); 2º clique em até 500 ms edita.
  void _clicar() {
    final t = widget.linha.transacao;
    final agora = DateTime.now();
    final duplo = _ultimoClique != null &&
        agora.difference(_ultimoClique!) < const Duration(milliseconds: 500);
    _ultimoClique = duplo ? null : agora;
    if (duplo) {
      abrirTransacao(context, transacao: t);
    } else {
      mbTransacaoSelecionada.value = t.transactionPk;
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = cores(context);
    final l = widget.linha;
    final t = l.transacao;
    final prevista = !t.paid;
    final tipo = mbTipoDaTransacao(t, l.categoria);
    final cor = prevista ? e.mu : tipo.cor(context);
    final carteiras = Provider.of<AllWallets>(context);
    // Valor na moeda da própria conta (os totais do mês usam a moeda principal).
    final r = l.rachada;
    final bruto = t.amount.abs();
    final liquido = r == null ? bruto : r.liquido((bruto * 100).round()) / 100;
    String dinheiro(double v) => convertToMoney(carteiras, v,
        currencyKey: carteiras.indexedByPk[t.walletFk]?.currency,
        allDecimals: true);
    final valor = dinheiro(liquido);
    Widget celula(int i, String texto,
            {TextStyle? estilo, bool direita = false}) =>
        Expanded(
          flex: _colunas[i],
          child: Text(texto,
              overflow: TextOverflow.ellipsis,
              textAlign: direita ? TextAlign.end : TextAlign.start,
              style: estilo ?? EdTexto.corpo(context).copyWith(color: e.mu)),
        );
    return Semantics(
      button: true,
      selected: widget.selecionada,
      label: '${t.name.isEmpty ? l.categoria : t.name}, $valor',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _sobre = true),
        onExit: (_) => setState(() => _sobre = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _clicar,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            decoration: BoxDecoration(
              color: widget.selecionada
                  ? e.chip
                  : _sobre
                      ? e.surf
                      : null,
              border: Border(bottom: BorderSide(color: e.line)),
            ),
            child: Row(children: [
              celula(0,
                  '${t.dateCreated.day.toString().padLeft(2, '0')}/${t.dateCreated.month.toString().padLeft(2, '0')}'),
              if (l.indicacao.isEmpty)
                celula(1, t.name.isEmpty ? l.categoria : t.name,
                    estilo: EdTexto.corpo(context)
                        .copyWith(color: e.tx, fontWeight: FontWeight.w500))
              else
                Expanded(
                  flex: _colunas[1],
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.name.isEmpty ? l.categoria : t.name,
                            overflow: TextOverflow.ellipsis,
                            style: EdTexto.corpo(context).copyWith(
                                color: e.tx, fontWeight: FontWeight.w500)),
                        Text(l.indicacao,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: EdTexto.rotulo(context)),
                      ]),
                ),
              celula(2, l.categoria),
              celula(3, l.conta),
              Expanded(
                flex: _colunas[4],
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (r != null) ...[
                    // Conta rachada: quem dividiu e o total pago riscado, antes da minha parte.
                    Flexible(
                      child: Text(
                          '👥 ${r.pessoas}  ${t.income ? '+' : '−'}${dinheiro(bruto)}',
                          overflow: TextOverflow.ellipsis,
                          style: EdTexto.rotulo(context)
                              .copyWith(decoration: TextDecoration.lineThrough)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (!prevista) ...[IconeTipo(tipo, tamanho: 20), const SizedBox(width: 8)],
                  Flexible(
                    child: Text('${t.income ? '+' : '−'}$valor${prevista ? ' · previsto' : ''}',
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: EdTexto.corpo(context).copyWith(color: cor, fontWeight: FontWeight.w500)),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
