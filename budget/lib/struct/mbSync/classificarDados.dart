// Fila "Para classificar" (ver classificar.dart): leitura do Drift, sugestões da IA do Meu Banco e confirmação.
// Estado local em mb_estado: `ia_desde` (quando a fila começou), `ia_revisados` (pks já decididos) e
// `ia_padroes` (confirmações por favorecido). Nada disso sobe para o servidor; a categoria confirmada sobe como ajuste.
import 'dart:async';
import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show CatLocal;
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

const String _chaveDesde = 'ia_desde';
const String _chaveRevisados = 'ia_revisados';
const String _chavePadroes = 'ia_padroes';
final DateTime _editadoDesde = DateTime.utc(2001); // igual a meuBancoSync: antes disso é "sem edição"

/// Fila que a aba Pendências mostra.
final ValueNotifier<List<MbLancamentoIa>> meuBancoClassificar = ValueNotifier(const []);

/// Sugestões por pk (IA ou locais). Mudam sem mexer na fila.
final ValueNotifier<Map<String, MbSugestao>> meuBancoSugestoes = ValueNotifier(const {});

/// null: ainda não tentou; true: a IA respondeu; false: sem internet, sem pareamento ou IA indisponível.
final ValueNotifier<bool?> meuBancoIaOk = ValueNotifier(null);

// Lidos a cada mbAtualizarClassificar; os testes de tela preenchem direto.
MbOpcoes mbOpcoesClassificar = const MbOpcoes();
List<MbPadrao> mbPadroesClassificar = const [];

Future<Set<String>> _lerRevisados() async {
  try {
    final j = jsonDecode(await mbLerEstado(_chaveRevisados) ?? '[]');
    return {if (j is List) for (final p in j) '$p'};
  } catch (_) {
    return {};
  }
}

Future<DateTime> _lerDesde() async {
  final salvo = DateTime.tryParse(await mbLerEstado(_chaveDesde) ?? '');
  if (salvo != null) return salvo;
  final n = DateTime.now();
  final desde = DateTime(n.year, n.month, n.day - mbDiasFolgaFila);
  await mbGravarEstado({_chaveDesde: desde.toIso8601String()});
  return desde;
}

Future<MbOpcoes> _carregarOpcoes(List<TransactionCategory> cats) async {
  final objetivos = await (database.select(database.objectives)
        ..where((o) => o.archived.equals(false)))
      .get();
  return MbOpcoes.montar([
    for (final c in cats)
      CatLocal(pk: c.categoryPk, nome: c.name, receita: c.income, paiPk: c.mainCategoryPk)
  ], [
    for (final o in objetivos)
      MbVinculoOpcao(o.objectivePk, o.name, o.type == ObjectiveType.loan ? 'emprestimo' : 'meta')
  ]);
}

/// Recalcula a fila a partir do Drift (chamada junto com a fila Para revisar). Itens "Pix enviado" do Worker entram
/// aqui com a sugestão da IA; os outros tipos do Worker (envio ao Santander, Pix recebido, salário) ficam fora.
Future<void> mbAtualizarClassificar() async {
  try {
    await mbCriarTabelas();
    final cats = await database.select(database.categories).get();
    mbOpcoesClassificar = await _carregarOpcoes(cats);
    mbPadroesClassificar = mbPadroesDeJson(jsonDecode(await mbLerEstado(_chavePadroes) ?? '[]'));
    final servidor = {for (final i in meuBancoRevisar.value) if (i.txId != null) 'mb:${i.txId}': i};
    final carteiras = {
      for (final w in await database.select(database.wallets).get()) w.walletPk: w.name
    };
    final nomes = {for (final c in cats) c.categoryPk: c.name};
    final txs = await (database.select(database.transactions)
          ..where((t) => t.transactionPk.like('mb:%')))
        .get();
    final lancamentos = <MbLancamentoIa>[];
    for (final t in txs) {
      final revisao = servidor[t.transactionPk];
      if (revisao != null && revisao.tipo != 'pix_enviado') continue;
      lancamentos.add(MbLancamentoIa(
        pk: t.transactionPk,
        descricao: t.name,
        valor: t.amount,
        data: t.dateCreated,
        conta: carteiras[t.walletFk] ?? '',
        categoriaNome: nomes[t.categoryFk] ?? '',
        categoriaPk: t.categoryFk,
        editado: (t.dateTimeModified ?? _editadoDesde).isAfter(_editadoDesde),
        pendente: t.note == 'Pendente',
        revisao: revisao,
      ));
    }
    final fila = mbFilaClassificar(lancamentos,
        desde: await _lerDesde(), revisados: await _lerRevisados());
    meuBancoClassificar.value = fila;
    _preencherLocais(fila);
  } catch (e) {
    if (kDebugMode) debugPrint('Meu Banco: falha ao montar a fila Para classificar: $e');
  }
}

// Sugestão local para quem ainda não tem uma da IA.
void _preencherLocais(List<MbLancamentoIa> fila) {
  final atual = meuBancoSugestoes.value;
  meuBancoSugestoes.value = {
    for (final l in fila)
      if (atual[l.pk]?.fonte == MbFonteSugestao.ia)
        l.pk: atual[l.pk]!
      else if (mbSugestaoLocal(l, mbPadroesClassificar, mbOpcoesClassificar) case final s?)
        l.pk: s
  };
}

final Set<String> _pedidos = {};

/// Pede à IA as sugestões dos próximos da fila (lote pequeno, uma vez por lançamento nesta sessão).
Future<void> mbPedirSugestoes(List<MbLancamentoIa> proximos) async {
  final lote = [
    for (final l in proximos)
      if (meuBancoSugestoes.value[l.pk]?.fonte != MbFonteSugestao.ia && !_pedidos.contains(l.pk)) l
  ].take(mbLoteIa).toList();
  if (lote.isEmpty || mbOpcoesClassificar.categorias.isEmpty) return;
  _pedidos.addAll(lote.map((l) => l.pk));
  try {
    final cliente = await mbClienteConfigurado();
    if (cliente == null) {
      meuBancoIaOk.value = false;
      return;
    }
    final r = await cliente.iaSugerir({
      'contexto': mbOpcoesClassificar.contexto(mbExemplosPara(lote, mbPadroesClassificar)),
      'lancamentos': [for (final l in lote) l.toJson()],
    });
    final porPk = {for (final l in lote) l.pk: l};
    final novas = <String, MbSugestao>{
      for (final j in (r['sugestoes'] as List? ?? const []))
        if (porPk[j is Map ? j['id'] : null] case final l?)
          if (MbSugestao.daIa(j, mbOpcoesClassificar, l) case final s?) l.pk: s
    };
    meuBancoIaOk.value = r['ia'] != false;
    meuBancoSugestoes.value = {...meuBancoSugestoes.value, ...novas};
  } catch (e) {
    // Sem internet, Worker antigo (404/405) ou erro: segue com os padrões locais e tenta de novo na próxima abertura.
    _pedidos.removeAll(lote.map((l) => l.pk));
    meuBancoIaOk.value = false;
    if (kDebugMode) debugPrint('Meu Banco: IA indisponível: $e');
  }
}

/// Explicação do usuário em texto livre → o que a IA entendeu (para ele confirmar). null: não entendeu ou sem IA.
Future<MbSugestao?> mbEntenderExplicacao(MbLancamentoIa l, String explicacao) async {
  try {
    final cliente = await mbClienteConfigurado();
    if (cliente == null) return null;
    final r = await cliente.iaEntender({
      'contexto': mbOpcoesClassificar.contexto(mbExemplosPara([l], mbPadroesClassificar)),
      'lancamento': l.toJson(),
      'explicacao': explicacao,
    });
    meuBancoIaOk.value = r['ia'] != false;
    return MbSugestao.daIa(r['sugestao'], mbOpcoesClassificar, l);
  } catch (e) {
    meuBancoIaOk.value = false;
    if (kDebugMode) debugPrint('Meu Banco: IA indisponível: $e');
    return null;
  }
}

/// Aplica a escolha do usuário: categoria, subcategoria, título e vínculo no lançamento (com data de edição, para a
/// categoria subir como ajuste), lembra o padrão e tira da fila. Pix enviado do Worker grava também a decisão.
Future<void> mbConfirmarClassificacao(MbLancamentoIa l, MbSugestao escolha) async {
  final vinculo = mbOpcoesClassificar.vinculo(escolha.vinculoPk);
  await (database.update(database.transactions)..where((t) => t.transactionPk.equals(l.pk)))
      .write(TransactionsCompanion(
    categoryFk: Value(escolha.categoriaPk),
    subCategoryFk: Value(escolha.subPk),
    name: escolha.titulo == null ? const Value.absent() : Value(escolha.titulo!),
    objectiveLoanFk: vinculo?.tipo == 'emprestimo' ? Value(vinculo!.pk) : const Value.absent(),
    objectiveFk: vinculo?.tipo == 'meta' ? Value(vinculo!.pk) : const Value.absent(),
    dateTimeModified: Value(DateTime.now()),
  ));
  mbPadroesClassificar = mbRegistrarPadrao(
      mbPadroesClassificar,
      MbPadrao(mbChavePadrao(l.descricao), escolha.categoriaPk,
          subPk: escolha.subPk, titulo: escolha.titulo, vinculoPk: vinculo?.pk));
  await mbGravarEstado({
    _chavePadroes: jsonEncode([for (final p in mbPadroesClassificar) p.toJson()]),
    _chaveRevisados: jsonEncode([...await _lerRevisados(), l.pk]),
  });
  meuBancoClassificar.value = [
    for (final x in meuBancoClassificar.value)
      if (x.pk != l.pk) x
  ];
  final revisao = l.revisao;
  if (revisao != null) {
    // Mesma resposta da fila Para revisar: decisão e memória do destinatário (já sincroniza).
    unawaited(mbResponderRevisao(revisao, 'categoria', categoriaPk: escolha.categoriaPk));
  } else {
    unawaited(sincronizarMeuBanco());
  }
}
