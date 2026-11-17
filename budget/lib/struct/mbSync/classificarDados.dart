// Fila "Para classificar" (ver classificar.dart): leitura do Drift, sugestões da IA do Meu Banco e confirmação.
// Estado local em mb_estado: `ia_novos_desde` (quando a fila foi instalada), `ia_revisados` (pks já decididos) e
// `ia_padroes` (confirmações por favorecido). Nada disso sobe para o servidor; a categoria confirmada sobe como ajuste.
import 'dart:async';
import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/casosComuns.dart';
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/mapeamento.dart' show CatLocal;
import 'package:budget/struct/mbSync/reembolso.dart' show mbItemDeEntrada;
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/meuBancoMapping.dart' show mbPrefixo;
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/widgets/transactionEntry/transactionLabel.dart' show nomeDaCategoria;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

const String _chaveDesde = 'ia_novos_desde';
const String _chaveDesdeAntiga = 'ia_desde'; // v5.4.41: primeira abertura − 7 dias (pegava histórico)
const String _chaveRevisados = 'ia_revisados';
const String _chavePadroes = 'ia_padroes';
final DateTime _editadoDesde = DateTime.utc(2001); // igual a meuBancoSync: antes disso é "sem edição"

/// Fila que a aba Pendências mostra.
final ValueNotifier<List<MbLancamentoIa>> meuBancoClassificar = ValueNotifier(const []);

/// Sugestões por pk (IA ou locais). Mudam sem mexer na fila.
final ValueNotifier<Map<String, MbSugestao>> meuBancoSugestoes = ValueNotifier(const {});

/// null: ainda não tentou; true: a IA respondeu; false: sem internet, sem pareamento ou IA indisponível.
final ValueNotifier<bool?> meuBancoIaOk = ValueNotifier(null);

/// Situação do pedido à IA por pk, para o cartão mostrar (sai quando chega a sugestão).
enum MbEstadoIa { pedindo, semSugestao, falhou }

final ValueNotifier<Map<String, MbEstadoIa>> meuBancoIaEstado = ValueNotifier(const {});

// Lidos a cada mbAtualizarClassificar; os testes de tela preenchem direto.
MbOpcoes mbOpcoesClassificar = const MbOpcoes();
List<MbPadrao> mbPadroesClassificar = const [];
MbUso mbUsoClassificar = const MbUso();
List<MbHistorico> mbHistoricoClassificar = const []; // todas as transações: "como no mês passado"

Future<Set<String>> _lerRevisados() async {
  try {
    final j = jsonDecode(await mbLerEstado(_chaveRevisados) ?? '[]');
    return {if (j is List) for (final p in j) '$p'};
  } catch (_) {
    return {};
  }
}

/// Marco dos "novos", gravado na primeira execução. Quem já tinha o marco antigo volta ao dia da instalação.
Future<DateTime> _lerDesde() async {
  final salvo = DateTime.tryParse(await mbLerEstado(_chaveDesde) ?? '');
  if (salvo != null) return salvo;
  final antigo = DateTime.tryParse(await mbLerEstado(_chaveDesdeAntiga) ?? '');
  final desde = mbMarcoNovos(antigo, DateTime.now());
  await mbGravarEstado({_chaveDesde: desde.toIso8601String()});
  return desde;
}

Future<MbOpcoes> _carregarOpcoes(List<TransactionCategory> cats) async {
  final objetivos = await (database.select(database.objectives)
        ..where((o) => o.archived.equals(false)))
      .get();
  return MbOpcoes.montar([
    for (final c in cats)
      CatLocal(pk: c.categoryPk, nome: nomeDaCategoria(c), receita: c.income, paiPk: c.mainCategoryPk)
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
    final nomes = {for (final c in cats) c.categoryPk: nomeDaCategoria(c)};
    final txs = await database.select(database.transactions).get();
    mbUsoClassificar = MbUso.de([for (final t in txs) (descricao: t.name, categoriaPk: t.categoryFk)]);
    mbHistoricoClassificar = [
      for (final t in txs)
        (
          pk: t.transactionPk,
          nome: t.name,
          valor: t.amount,
          data: t.dateCreated,
          categoriaPk: t.categoryFk,
          subPk: t.subCategoryFk,
          categoriaNome: nomes[t.categoryFk] ?? '',
          subNome: nomes[t.subCategoryFk],
        )
    ];
    final lancamentos = <MbLancamentoIa>[];
    for (final t in txs) {
      if (!t.transactionPk.startsWith(mbPrefixo)) continue;
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

// "Como no mês passado" na frente de tudo (nem vai para a IA); senão a da IA que já chegou ou a local.
void _preencherLocais(List<MbLancamentoIa> fila) {
  final atual = meuBancoSugestoes.value;
  meuBancoSugestoes.value = {
    for (final l in fila)
      if (mbComoMesPassado(l, mbHistoricoClassificar, mbOpcoesClassificar) case final s?)
        l.pk: s
      else if (atual[l.pk]?.fonte == MbFonteSugestao.ia)
        l.pk: atual[l.pk]!
      else if (mbSugestaoLocal(l, mbPadroesClassificar, mbOpcoesClassificar) case final s?)
        l.pk: s
  };
}

final Set<String> _pedidos = {};
const _semPedir = {MbFonteSugestao.ia, MbFonteSugestao.mesPassado};

/// Pede à IA as sugestões dos próximos da fila (lote pequeno, uma vez por lançamento nesta sessão).
Future<void> mbPedirSugestoes(List<MbLancamentoIa> proximos) async {
  final lote = [
    for (final l in proximos)
      if (!_semPedir.contains(meuBancoSugestoes.value[l.pk]?.fonte) && !_pedidos.contains(l.pk)) l
  ].take(mbLoteIa).toList();
  if (lote.isEmpty || mbOpcoesClassificar.categorias.isEmpty) return;
  _pedidos.addAll(lote.map((l) => l.pk));
  _marcarIa(lote, (_) => MbEstadoIa.pedindo);
  void falhou() {
    // Tenta de novo na próxima vez que o cartão abrir.
    _pedidos.removeAll(lote.map((l) => l.pk));
    meuBancoIaOk.value = false;
    _marcarIa(lote, (_) => MbEstadoIa.falhou);
  }

  try {
    final cliente = await mbClienteConfigurado();
    if (cliente == null) {
      falhou();
      return;
    }
    final r = await cliente.iaSugerir({
      'contexto': mbOpcoesClassificar.contexto(mbExemplosPara(lote, mbPadroesClassificar)),
      'lancamentos': [for (final l in lote) l.toJson()],
    });
    if (r['ia'] == false) {
      falhou(); // Worker sem a IA ou modelo com erro
      return;
    }
    final porPk = {for (final l in lote) l.pk: l};
    final novas = <String, MbSugestao>{
      for (final j in (r['sugestoes'] as List? ?? const []))
        if (porPk[j is Map ? j['id'] : null] case final l?)
          if (MbSugestao.daIa(j, mbOpcoesClassificar, l) case final s?) l.pk: s
    };
    meuBancoIaOk.value = true;
    meuBancoSugestoes.value = {...meuBancoSugestoes.value, ...novas};
    _marcarIa(lote, (l) => novas.containsKey(l.pk) ? null : MbEstadoIa.semSugestao);
  } catch (e) {
    // Sem internet, Worker antigo (404/405), token revogado (401), timeout: segue com os padrões locais.
    falhou();
    if (kDebugMode) debugPrint('Meu Banco: IA indisponível: $e');
  }
}

void _marcarIa(List<MbLancamentoIa> lote, MbEstadoIa? Function(MbLancamentoIa) estado) {
  final m = {...meuBancoIaEstado.value};
  for (final l in lote) {
    if (estado(l) case final e?) {
      m[l.pk] = e;
    } else {
      m.remove(l.pk);
    }
  }
  meuBancoIaEstado.value = m;
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
Future<void> mbConfirmarClassificacao(MbLancamentoIa l, MbSugestao escolha, {bool sincronizar = true}) async {
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
  });
  await _tirarDaFila(l.pk);
  final revisao = l.revisao;
  if (revisao != null) {
    // Mesma resposta da fila Para revisar: decisão e memória do destinatário (já sincroniza).
    unawaited(mbResponderRevisao(revisao, 'categoria', categoriaPk: escolha.categoriaPk));
  } else if (sincronizar) {
    unawaited(sincronizarMeuBanco());
  }
}

/// "Aplicar a todos os iguais" e "Confirmar todos" (rendimentos): a mesma escolha em cada um, um sync só no fim.
Future<void> mbConfirmarVarios(List<MbLancamentoIa> ls, MbSugestao escolha) async {
  for (final l in ls) {
    await mbConfirmarClassificacao(l, escolha, sincronizar: false);
  }
  unawaited(sincronizarMeuBanco());
}

Future<void> _tirarDaFila(String pk) async {
  await mbGravarEstado({_chaveRevisados: jsonEncode([...await _lerRevisados(), pk])});
  meuBancoClassificar.value = [
    for (final x in meuBancoClassificar.value)
      if (x.pk != pk) x
  ];
}

/// "É a parte de uma conta que eu paguei": liga a entrada ao gasto (decisão "reembolso", sincronizada; o pull põe a
/// entrada na categoria do gasto) e tira da fila.
Future<void> mbConfirmarReembolso(MbLancamentoIa l, String gastoPk) async {
  await _tirarDaFila(l.pk);
  unawaited(mbResponderRevisao(mbItemDeEntrada(l.pk, l.valor, l.data, l.descricao), 'reembolso',
      reembolsoDe: gastoPk.substring(mbPrefixo.length)));
}
