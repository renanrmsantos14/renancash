import 'dart:async' show unawaited;

import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/editorial.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show quandoRelativo;
import 'package:budget/struct/mbSync/iaAplicadas.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/widgets/editorial/painelTransacao.dart' show abrirTransacao;
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:flutter/material.dart';

const _diasLista = 14; // o Worker devolve os últimos 14 dias sem `desde`

/// "Feito pela IA": o que o Meu Banco classificou sozinho nos últimos 14 dias, com Desfazer e Corrigir.
/// Os valores novos já chegam pelo espelho; aqui só se lista, se desfaz (Worker) e se abre o editor normal.
class FeitoPelaIaPage extends StatefulWidget {
  const FeitoPelaIaPage({super.key, this.clienteParaTeste, this.nomesParaTeste});

  final MbCliente? clienteParaTeste;
  final Map<String, String>? nomesParaTeste; // pk da categoria -> nome (testes sem banco)

  @override
  State<FeitoPelaIaPage> createState() => _FeitoPelaIaPageState();
}

class _FeitoPelaIaPageState extends State<FeitoPelaIaPage> {
  List<MbIaAplicada>? _itens;
  String? _erro;
  bool _offline = false;
  Map<String, String> _nomes = const {};
  final Set<String> _desfazendo = {};
  final Set<String> _desfeitosAgora = {};

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    setState(() {
      _itens = null;
      _erro = null;
      _offline = false;
    });
    try {
      final cliente = widget.clienteParaTeste ?? await mbClienteConfigurado();
      if (cliente == null) throw MbErroHttp(401, 'Pareie o aparelho com o Meu Banco para ver o que a IA fez.');
      final nomes = widget.nomesParaTeste ??
          {for (final c in (await database.getAllCategoriesIndexed()).values) c.categoryPk: c.name};
      final itens = MbIaAplicada.lista(await cliente.iaAplicadas());
      // Pendente ainda não foi aplicado, então não é "feito".
      final feitos = itens.where((i) => i.status != 'pendente').toList()
        ..sort((a, b) => (b.data ?? DateTime(0)).compareTo(a.data ?? DateTime(0)));
      if (!mounted) return;
      setState(() {
        _nomes = nomes;
        _itens = feitos;
      });
    } on MbErroHttp catch (e) {
      if (mounted) setState(() => _erro = e.mensagem);
    } catch (e) {
      if (!mounted) return;
      if (mbErroDeRede(e) != null) {
        setState(() => _offline = true);
      } else {
        setState(() => _erro = 'Não foi possível carregar agora.');
      }
    }
  }

  Future<void> _desfazer(MbIaAplicada i) async {
    setState(() => _desfazendo.add(i.txId));
    String msg;
    var feito = false;
    try {
      final cliente = widget.clienteParaTeste ?? await mbClienteConfigurado();
      if (cliente == null) throw MbErroHttp(401, 'Pareie o aparelho com o Meu Banco.');
      await cliente.iaDesfazer(i.txId);
      feito = true;
      msg = i.devolucao
          ? 'Desfeito. O Pix volta para a fila Para revisar.'
          : 'Desfeito. A transação volta para a fila Para classificar.';
    } on MbErroHttp catch (e) {
      feito = e.status == 409;
      msg = feito ? 'Essa classificação já estava desfeita.' : e.mensagem;
    } catch (e) {
      final rede = mbErroDeRede(e);
      msg = rede != null ? '$rede Tente de novo.' : 'Não foi possível desfazer agora.';
    }
    if (feito) unawaited(sincronizarMeuBanco()); // traz o nome e a categoria de volta pelo espelho
    openSnackbar(SnackbarMessage(title: msg));
    if (!mounted) return;
    setState(() {
      _desfazendo.remove(i.txId);
      if (feito) _desfeitosAgora.add(i.txId);
    });
  }

  Future<void> _corrigir(MbIaAplicada i) async {
    final tx = await database.tryGetTransactionFromPk(i.pk);
    if (tx == null) {
      openSnackbar(SnackbarMessage(title: 'Essa transação ainda não chegou neste aparelho. Sincronize e tente de novo.'));
      return;
    }
    if (mounted) await abrirTransacao(context, transacao: tx);
  }

  String _categoria(MbIaValores v) {
    final c = v.categoriaPk == null ? null : _nomes[v.categoriaPk];
    final s = v.subPk == null ? null : _nomes[v.subPk];
    if (c == null) return 'Sem categoria';
    return s == null ? c : '$c › $s';
  }

  Widget _mensagem(String texto, {String? acao, IconData icone = Icons.auto_awesome_rounded}) {
    final e = cores(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 0),
      child: Column(children: [
        Icon(icone, size: 32, color: e.mu),
        const SizedBox(height: 12),
        Text(texto, textAlign: TextAlign.center, style: EdTexto.corpo(context).copyWith(color: e.mu)),
        if (acao != null) ...[
          const SizedBox(height: 16),
          OutlinedButton(onPressed: _carregar, child: Text(acao)),
        ],
      ]),
    );
  }

  Widget _cartao(MbIaAplicada i) {
    final e = cores(context);
    final desfeita = i.desfeita || _desfeitosAgora.contains(i.txId);
    final antes = i.antes;
    final nomeMudou = antes != null && antes.nome.isNotEmpty && antes.nome != i.depois.nome;
    final data = i.data;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: CartaoBento(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (nomeMudou)
            Text(antes.nome,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: EdTexto.rotulo(context).copyWith(decoration: TextDecoration.lineThrough)),
          Text(i.depois.nome.isEmpty ? 'Sem nome' : i.depois.nome,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: EdTexto.corpo(context).copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
              i.devolucao
                  ? 'Reembolso da compra'
                  : antes == null || _categoria(antes) == _categoria(i.depois)
                  ? _categoria(i.depois)
                  : '${_categoria(antes)} → ${_categoria(i.depois)}',
              style: EdTexto.corpo(context)),
          const SizedBox(height: 2),
          Text(
              [
                i.rotuloOrigem,
                if (data != null) quandoRelativo(data, DateTime.now()),
                if (desfeita) 'Desfeita',
              ].join(' · '),
              style: EdTexto.rotulo(context).copyWith(color: desfeita ? e.warntx : null)),
          const SizedBox(height: 10),
          Row(children: [
            if (!desfeita) ...[
              Expanded(
                child: FilledButton(
                  onPressed: _desfazendo.contains(i.txId) ? null : () => _desfazer(i),
                  child: Text(_desfazendo.contains(i.txId) ? 'Desfazendo…' : 'Desfazer'),
                ),
              ),
              if (!i.devolucao) const SizedBox(width: 10),
            ],
            if (!i.devolucao)
              Expanded(
                child: OutlinedButton(onPressed: () => _corrigir(i), child: const Text('Corrigir')),
              ),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final itens = _itens;
    return PageFramework(
      dragDownToDismiss: true,
      horizontalPaddingConstrained: true,
      title: 'Feito pela IA',
      listWidgets: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
          child: Text('O que foi classificado sozinho nos últimos $_diasLista dias. Desfaça ou corrija o que não estiver certo: o app aprende com isso.',
              style: EdTexto.rotulo(context)),
        ),
        if (_offline)
          _mensagem('Sem conexão com o Meu Banco.', acao: 'Tentar de novo', icone: Icons.cloud_off_rounded)
        else if (_erro != null)
          _mensagem(_erro!, acao: 'Tentar de novo', icone: Icons.error_outline_rounded)
        else if (itens == null)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (itens.isEmpty)
          _mensagem('Nada classificado pela IA nos últimos $_diasLista dias.')
        else ...[
          for (final i in itens) _cartao(i),
          const SizedBox(height: 24),
        ],
      ],
    );
  }
}
