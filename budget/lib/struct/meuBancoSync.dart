import 'dart:async';
import 'dart:convert';
import 'package:budget/database/tables.dart';
import 'package:budget/pages/addWalletPage.dart'
    show initializeBalanceCorrectionCategory;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/espelho.dart' show mbEspelhoApagadas, mbEspelhoCarregarEstado;
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/mbSync/contextoLocal.dart';
import 'package:budget/struct/mbSync/categoriaEfetiva.dart' show MbContextoCategoria;
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/extrasTransacao.dart';
import 'package:budget/struct/mbSync/mapeamento.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/mbSync/widget.dart';
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' show DateFormat;

const String meuBancoUrlPadrao =
    "https://renancash.renanrmsantos14.workers.dev";
// Endereço anterior do Worker (renomeado para renancash): quem pareou com ele passa a usar o novo.
const String _urlAntiga = "https://meu-banco.renanrmsantos14.workers.dev";
const String _chaveToken = "meu_banco_token";
const String _chaveUrl = "meu_banco_url";
const String _chaveDesde = "meuBancoDesde";
// Marca a conversão do histórico para as categorias próprias: uma única carga completa refaz as categorias.
const String _chaveConversao = "conv_categorias_v1";
const String _chaveRevisoesMigradas = "revisoes_migradas_v1";
// Uma decisão da fila "Para revisar" deste aparelho muda como transações antigas são mapeadas: o pull incremental não
// as traz de volta, então a próxima sincronização refaz a carga completa. Decisões de outros aparelhos chegam pelo espelho.
const String _chaveRepuxar = "repuxar_revisoes";

const FlutterSecureStorage _storage = FlutterSecureStorage();

// Estado para a tela "Meu Banco". Fica só em memória (não vai para backups).
final ValueNotifier<String?> meuBancoUltimoErro = ValueNotifier(null);
final ValueNotifier<DateTime?> meuBancoUltimaSync = ValueNotifier(null);
final ValueNotifier<bool> meuBancoSincronizando = ValueNotifier(false);
// Verdadeiro quando o app está pareado (token guardado) ou na web, que usa o cookie da mesma origem.
final ValueNotifier<bool> meuBancoPareado = ValueNotifier(kIsWeb);

/// Vira true quando meuBancoPareado já reflete o token salvo (a leitura é assíncrona).
final ValueNotifier<bool> meuBancoPareadoConferido = ValueNotifier(kIsWeb);

Future<void> meuBancoVerificarPareado() async {
  meuBancoPareado.value = kIsWeb || (await meuBancoLerToken())?.isNotEmpty == true;
  meuBancoPareadoConferido.value = true;
}

Future<String?> meuBancoLerToken() async {
  try {
    return await _storage.read(key: _chaveToken);
  } catch (e) {
    if (kDebugMode) debugPrint("Meu Banco: falha ao ler o token do armazenamento seguro: $e");
    return null;
  }
}

Future<String> meuBancoLerUrl() async {
  try {
    final u = await _storage.read(key: _chaveUrl);
    if (u != null && u.trim().isNotEmpty) {
      if (u.trim() == _urlAntiga) {
        await _storage.write(key: _chaveUrl, value: meuBancoUrlPadrao);
        return meuBancoUrlPadrao;
      }
      return u.trim();
    }
  } catch (e) {
    if (kDebugMode) debugPrint("Meu Banco: falha ao ler a URL do armazenamento seguro: $e");
  }
  return meuBancoUrlPadrao;
}

Future<void> meuBancoSalvarConfig({String? token, String? url}) async {
  if (token != null && token.trim().isNotEmpty) {
    await _storage.write(key: _chaveToken, value: token.trim());
  }
  if (url != null) {
    final u = url.trim().replaceAll(RegExp(r"/+$"), "");
    await _storage.write(key: _chaveUrl, value: u.isEmpty ? meuBancoUrlPadrao : u);
  }
}

// Apaga token e cursor. Não apaga transações já importadas.
Future<void> meuBancoDesconectar() async {
  await _storage.delete(key: _chaveToken);
  meuBancoPareado.value = kIsWeb;
  await updateSettings(_chaveDesde, null, updateGlobalState: false);
  await mbCriarTabelas();
  await mbRemoverEstado('cursor');
  meuBancoUltimoErro.value = null;
  meuBancoUltimaSync.value = null;
}

Future<void> meuBancoAtualizarRevisar() async {
  try {
    await mbCriarTabelas();
    await mbAtualizarRevisar();
  } catch (e) {
    if (kDebugMode) debugPrint("Meu Banco: falha ao atualizar a fila Para revisar: $e");
  }
}

// O cursor saiu dos settings (que vão para backups) e passou para mb_estado.
Future<void> _migrarCursorAntigo() async {
  final antigo = appStateSettings[_chaveDesde];
  if (antigo == null) return;
  if (antigo is String &&
      antigo.isNotEmpty &&
      await mbLerEstado('cursor') == null) {
    await mbGravarEstado({'cursor': antigo});
  }
  await updateSettings(_chaveDesde, null, updateGlobalState: false);
}

// Rodada em andamento e, no máximo, uma rodada extra à espera. Chamada que chega durante um sync (pull da Início
// junto com "Atualizar", pull depois do Pluggy) não se perde nem forma fila: todas dividem a mesma rodada extra,
// que roda uma única vez quando a atual termina e devolve o resultado dela a quem chamou.
Future<bool>? _rodadaEmCurso;
Completer<bool>? _rodadaExtra;
MbCliente? _clienteDaRodadaExtra;

// Retorna true se sincronizou. Nunca lança: guarda a última mensagem em meuBancoUltimoErro.
Future<bool> sincronizarMeuBanco({MbCliente? clienteParaTeste}) {
  if (_rodadaEmCurso != null) {
    _clienteDaRodadaExtra ??= clienteParaTeste;
    return (_rodadaExtra ??= Completer<bool>()).future;
  }
  return _rodar(clienteParaTeste);
}

Future<bool> _rodar(MbCliente? clienteParaTeste) =>
    _rodarCom(() => _puxarUmaVez(clienteParaTeste));

// Roda `acao` como a rodada em curso: o sync periódico e os pulls que chegarem no meio esperam a rodada extra.
// Para operações que trocam o estado inteiro (enviar tudo como oficial, recomeçar pela nuvem).
Future<T> mbEmRodada<T>(Future<T> Function() acao) async {
  while (_rodadaEmCurso != null) {
    await _rodadaEmCurso!.catchError((_) => false);
  }
  late T resultado;
  Object? erro;
  StackTrace? pilha;
  await _rodarCom(() async {
    try {
      resultado = await acao();
    } catch (e, st) {
      erro = e;
      pilha = st;
    }
    return true;
  });
  if (erro != null) Error.throwWithStackTrace(erro!, pilha!);
  return resultado;
}

// Uma sincronização dentro de `mbEmRodada` (que já é a rodada em curso: sincronizarMeuBanco ficaria esperando por ela).
Future<bool> mbSincronizarNaRodada(MbCliente? cliente) =>
    _puxarUmaVez(cliente);

Future<bool> _rodarCom(Future<bool> Function() corpo) async {
  meuBancoSincronizando.value = true;
  final atual = _rodadaEmCurso = corpo();
  // Nunca deve lançar (os erros viram meuBancoUltimoErro), mas se lançar não pode deixar a rodada presa:
  // sem isto _rodadaEmCurso ficaria preenchido e toda chamada seguinte esperaria para sempre.
  final ok = await atual.catchError((_) => false);
  final extra = _rodadaExtra;
  final clienteExtra = _clienteDaRodadaExtra;
  _rodadaEmCurso = null;
  _rodadaExtra = null;
  _clienteDaRodadaExtra = null;
  if (extra == null) {
    meuBancoSincronizando.value = false;
    return ok;
  }
  // A flag segue ligada entre as duas rodadas (a Início não pisca "sincronizado").
  extra.complete(_rodar(clienteExtra));
  return ok;
}

Future<bool> _puxarUmaVez(MbCliente? clienteParaTeste) async {
  try {
    final cliente = clienteParaTeste ?? await mbClienteConfigurado();
    if (cliente == null) return false; // não configurado: silencioso
    await mbCriarTabelas();
    // Decisões de revisão anteriores à F5 vivem em `mb_registros`: copiadas uma vez para `mb_revisoes`.
    if (await mbLerEstado(_chaveRevisoesMigradas) == null) {
      await mbMigrarRevisoes(database);
      await mbGravarEstado({_chaveRevisoesMigradas: '1'});
    }
    // O estado do espelho precisa estar carregado antes de qualquer leitura de `mbEspelhoApagadas`.
    await mbEspelhoCarregarEstado();
    await _migrarCursorAntigo();

    final convertido = await mbLerEstado(_chaveConversao) != null;
    final repuxar = await mbLerEstado(_chaveRepuxar);
    // Pull completo na primeira vez, depois de converter as categorias e quando uma resposta da fila pede o remapeamento.
    final json = await cliente.puxar(
        convertido && repuxar == null ? await mbLerEstado('cursor') : null);

    final categorias = await database.select(database.categories).get();
    final locais = {for (final c in categorias) c.categoryPk};
    // Categoria do RenanCash com o mesmo nome e tipo é reutilizada em vez de criar outra "mb:cat:".
    final porNome = {
      for (final c in categorias) '${c.income}:${c.name.toLowerCase()}': c.categoryPk
    };
    final historico = await _comprasLocais();
    final revisoes = MbRevisoes.deLinhas(await mbLerRevisoes());
    final destinos = mbResolverDestinos([
      for (final c in categorias)
        CatLocal(pk: c.categoryPk, nome: c.name, receita: c.income, paiPk: c.mainCategoryPk)
    ]);
    MbResultado mapear(MbContextoCategoria ctx) => mbMapearPull(json, ctx,
        revisoes: revisoes,
        compras: historico.compras,
        abatimentos: historico.abatimentos,
        destinos: destinos,
        pkCategoria: (id, nome, receita) =>
            id != null && locais.contains(pkDoId(id))
                ? pkDoId(id)
                : porNome['$receita:${nome.toLowerCase()}'] ??
                    mbPkCategoria(nome, receita));
    // Editar só título ou nota não congela a categoria: ela só fica fixa se difere da que o mapeador escolheria.
    final ctxCompleto = await mbContextoLocal();
    final semCategoria = mapear(mbSemCategoriaEditada(ctxCompleto));
    final resultado = mapear(mbSoCategoriaDivergente(ctxCompleto, {
      for (final t in semCategoria.transacoes) t.pk.substring(mbPrefixo.length): t.categoriaPk
    }));
    // Uma transação só: 1 commit em vez de N e 1 notificação aos streams (as telas recarregavam a cada insert).
    await database.transaction(() => _aplicar(resultado, {for (final id in ctxCompleto.ajustes.keys) '$mbPrefixo$id'}));

    final extras = mbMesclarExtras(
        mbExtrasDeTexto(await mbLerEstado(chaveExtrasTransacao)),
        json['transacoes'] as List? ?? const [],
        completo: json['completo'] == true);
    final estado = <String, String>{
      chaveExtrasTransacao: jsonEncode(extras),
      'contas': jsonEncode([
        for (final c in mbHerdarBanco(json['contas'] as List? ?? const []))
          // Conta de conexão removida segue no pull (mapeia transações antigas), mas não aparece.
          if (!mbContaIgnorada(c) && c['removida'] != 1 && c['removida'] != true) c
      ]),
      'faturas': jsonEncode(json['faturas'] ?? const {}),
      'ciclo': jsonEncode(json['ciclo']),
      'avisos': jsonEncode(json['avisos'] ?? const []),
      'config': jsonEncode(json['config'] ?? const {}),
      'sincronizado_em': '${json['sincronizado_em'] ?? ''}',
      // Worker antigo não manda a série: fica a que já temos.
      if (json['investimentos_mensal'] is List)
        chaveSerieMensal: jsonEncode(json['investimentos_mensal']),
      if (json['investimentos'] is List)
        chaveDetalhesInvestimentos: jsonEncode(json['investimentos']),
    };
    if (resultado.agora.isNotEmpty) estado['cursor'] = resultado.agora;
    estado[_chaveConversao] = '1';
    await mbGravarEstado(estado);
    // Todos os orçamentos seguem o ciclo; o Geral nasce depois do pull (se o outro aparelho já o criou, ele veio).
    mbCicloCache = mbCicloDeJson(json['ciclo']);
    await mbGarantirOrcamentoGeral();
    await mbGarantirReserva();
    await mbVincularAplicacoesNovas();
    // Resposta dada durante esta sincronização regrava a marca com outro valor e fica para a próxima.
    if (repuxar != null && await mbLerEstado(_chaveRepuxar) == repuxar) {
      await mbRemoverEstado(_chaveRepuxar);
    }
    await mbAtualizarWidget();
    meuBancoUltimoErro.value = null;
    meuBancoPareado.value = true;
    meuBancoUltimaSync.value = DateTime.now();
    return true;
  } on MbErroHttp catch (e) {
    meuBancoUltimoErro.value = e.mensagem;
  } on TimeoutException {
    meuBancoUltimoErro.value = "Tempo esgotado ao falar com o Meu Banco.";
  } on http.ClientException catch (e) {
    if (kDebugMode) debugPrint("Meu Banco: ClientException: ${e.message}");
    meuBancoUltimoErro.value = "Sem conexão com o Meu Banco.";
  } catch (e) {
    if (kDebugMode) debugPrint("Meu Banco: falha na sincronização: $e");
    meuBancoUltimoErro.value = "Não foi possível sincronizar agora.";
  } finally {
    await meuBancoAtualizarRevisar();
  }
  return false;
}

// Transações `mb:` entram com dateTimeModified fixo (2000), para não contarem como edição do usuário.
final DateTime _semEdicao = DateTime.utc(2000);

Future<void> _criarCarteiraSeFaltar(String pk, String nome) async {
  if (await database.getWalletInstanceOrNull(pk) != null) return;
  await database.createOrUpdateWallet(TransactionWallet(
    walletPk: pk,
    name: nome,
    dateCreated: DateTime.now(),
    dateTimeModified: null,
    order: (await database.getAllWallets()).length,
    currency: "brl",
    decimals: 2,
    homePageWidgetDisplay: defaultWalletHomePageWidgetDisplay,
  ));
}

Future<void> _aplicar(MbResultado r, Set<String> editadas) async {
  final apagadas = await mbEspelhoApagadas('transactions');
  final transacoes = [for (final t in r.transacoes) if (!apagadas.contains(t.pk)) t];
  // Carteiras: criadas se faltarem; as existentes não são tocadas (preserva ordem e edições).
  for (final conta in r.contas) {
    await _criarCarteiraSeFaltar(conta.walletPk, conta.nome);
  }
  // Categorias por nome: criadas se faltarem. As próprias existem sempre, mesmo sem transação.
  final categoriasVistas = <String>{};
  Future<void> criarCategoriaSeFaltar(String pk, String nome, bool receita) async {
    if (!categoriasVistas.add(pk)) return;
    if (await database.getCategoryInstanceOrNull(pk) != null) return;
    await database.createOrUpdateCategory(
      TransactionCategory(
        categoryPk: pk,
        name: nome,
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        order: await database.getAmountOfCategories(),
        income: receita,
        iconName: "image.png",
        methodAdded: MethodAdded.csv,
      ),
      updateSharedEntry: false,
      customDateTimeModified: _semEdicao,
    );
  }

  for (final e in r.categoriasProprias.entries) {
    await criarCategoriaSeFaltar(e.value, e.key, false);
  }
  for (final t in transacoes) {
    // Estorno e cashback entram como despesa (valor positivo), então a categoria é de despesa.
    await criarCategoriaSeFaltar(t.categoriaPk, t.categoriaNome, t.receita);
  }
  // `editadas`: título e nota editados no app (dateTimeModified depois de 2000, como em mbEditadoEm) não voltam ao
  // texto do banco; pendente volta, porque a nota "Pendente" decide a limpeza abaixo.
  // Upsert idempotente pelo pk "mb:<id>", direto no Drift (createOrUpdateTransaction marcaria a categoria como editada).
  // A subcategoria do mapa só entra na primeira importação: depois é escolha do usuário.
  for (final t in transacoes) {
    final manter = editadas.contains(t.pk) && !t.pendente;
    final dados = TransactionsCompanion(
      transactionPk: Value(t.pk),
      name: manter ? const Value.absent() : Value(t.nome),
      amount: Value(t.valor),
      note: manter ? const Value.absent() : Value(t.nota),
      categoryFk: Value(t.categoriaPk),
      walletFk: Value(t.carteiraPk),
      dateCreated: Value(t.data),
      dateTimeModified: manter ? const Value.absent() : Value(_semEdicao),
      originalDateDue: Value(t.data),
      income: Value(t.receita),
      paid: const Value(true),
      skipPaid: const Value(false),
      methodAdded: const Value(MethodAdded.csv),
    );
    // A linha é compartilhada com os outros aparelhos pelo espelho: a atualização grava só o que vem do banco e a
    // categoria decidida pelo mapeador. Pago, "pular pagamento" e origem pertencem a quem editou, e reescrevê-los
    // a cada pull brigaria com os outros aparelhos.
    final atualizacao = dados.copyWith(
        paid: const Value.absent(),
        skipPaid: const Value.absent(),
        methodAdded: const Value.absent());
    await database.into(database.transactions).insert(
        dados.copyWith(
            name: Value(t.nome),
            note: Value(t.nota),
            dateTimeModified: Value(_semEdicao),
            subCategoryFk: Value(t.subcategoriaPk)),
        onConflict: DoUpdate((_) => atualizacao));
  }
  // Importada antes de virar "não é gasto" (transferência): sai do app, sem ajuste para o servidor.
  if (r.naoGastoPks.isNotEmpty) {
    final alvos = r.naoGastoPks.toList();
    // Direto no Drift, como nas contas ignoradas: sem "apagados recentemente".
    await (database.delete(database.transactions)
          ..where((t) => t.transactionPk.isIn(alvos)))
        .go();
  }
  // Conta ignorada importada antes desta regra: apaga a carteira e os lançamentos dela.
  for (final pk in r.contasIgnoradasPks) {
    if (await database.getWalletInstanceOrNull(pk) == null) continue;
    // Direto no Drift: deleteWallet mandaria os lançamentos para "apagados recentemente".
    await (database.delete(database.transactions)
          ..where((t) => t.walletFk.equals(pk)))
        .go();
    await (database.delete(database.wallets)..where((x) => x.walletPk.equals(pk)))
        .go();
    await database.fixOrderWallets();
  }
  if (r.investimentos != null) {
    await _aplicarInvestimentos(r.investimentos!);
    await mbReconciliarVinculos(); // aplicação nova entra na meta a que já pertence
  }
  // Pendente importada que saiu de pendentes some (virou lançada com outro id ou foi cancelada).
  for (final conta in r.contas) {
    final daCarteira =
        await database.getAllTransactionsFromWallet(conta.walletPk);
    for (final t in daCarteira) {
      if (t.transactionPk.startsWith(mbPrefixo) &&
          t.note == "Pendente" &&
          !r.pendentesPks.contains(t.transactionPk)) {
        await database.deleteTransaction(t.transactionPk,
            updateSharedEntry: false);
      }
    }
  }
}

// Despesas `mb:` já no app: um estorno novo pode abater uma compra de um pull anterior (valor negativo),
// e os abatimentos já aplicados (valor positivo) indicam quais compras já foram abatidas.
Future<({List<MbCompra> compras, List<MbCompra> abatimentos})>
    _comprasLocais() async {
  final compras = <MbCompra>[], abatimentos = <MbCompra>[];
  final linhas = await (database.select(database.transactions)
        ..where((t) =>
            t.transactionPk.like('mb:%') & t.income.equals(false)))
      .get();
  for (final t in linhas) {
    final c = MbCompra(t.transactionPk, mbNormalizarEstabelecimento(t.name),
        (t.amount.abs() * 100).round(), t.dateCreated, '', t.categoryFk);
    if (t.amount < 0) {
      compras.add(c);
    } else if (t.amount > 0) {
      abatimentos.add(c);
    }
  }
  return (compras: compras, abatimentos: abatimentos);
}

// Cada investimento vira um ajuste de saldo (categoria "0", fora de gastos e receitas) na carteira "Investimentos",
// com o saldo atual. A data do primeiro import é mantida para não aparecer como lançamento novo a cada sync.
Future<void> _aplicarInvestimentos(List<MbInvestimento> lista) async {
  final existentes = {
    for (final t
        in await database.getAllTransactionsFromWallet(mbCarteiraInvestimentos))
      t.transactionPk: t
  };
  if (lista.isEmpty && existentes.isEmpty) return;
  await _criarCarteiraSeFaltar(mbCarteiraInvestimentos, "Investimentos");
  await initializeBalanceCorrectionCategory();
  for (final i in lista) {
    final antes = existentes[i.pk];
    final nota = i.banco ?? "";
    if (antes != null &&
        antes.amount == i.saldo &&
        antes.name == i.nome &&
        antes.note == nota) continue;
    final data = antes?.dateCreated ?? DateTime.now();
    await database.into(database.transactions).insertOnConflictUpdate(
          TransactionsCompanion(
            transactionPk: Value(i.pk),
            name: Value(i.nome),
            amount: Value(i.saldo),
            note: Value(nota),
            categoryFk: const Value("0"),
            walletFk: const Value(mbCarteiraInvestimentos),
            dateCreated: Value(data),
            dateTimeModified: Value(_semEdicao),
            originalDateDue: Value(data),
            income: Value(i.saldo > 0),
            paid: const Value(true),
            skipPaid: const Value(false),
            methodAdded: const Value(MethodAdded.csv),
          ),
        );
  }
  // Resgatado (saiu da lista): o saldo some.
  final atuais = {for (final i in lista) i.pk};
  final sairam = [
    for (final pk in existentes.keys)
      if (pk.startsWith(mbPrefixo + "inv:") && !atuais.contains(pk)) pk
  ];
  if (sairam.isNotEmpty) {
    await (database.delete(database.transactions)
          ..where((t) => t.transactionPk.isIn(sairam)))
        .go();
  }
}

// Responde um item da fila "Para revisar" (Início, e depois as notificações do PR 7): grava a decisão no espelho
// (a fila some na hora), manda ao servidor e remapeia as transações. `categoriaPk` só para resposta "categoria".
// Offline ou com falha, a decisão fica pendente e vai na próxima sincronização.
Future<void> mbResponderRevisao(MbItemRevisao item, String resposta,
    {String? categoriaPk, String? reembolsoDe, MbCliente? clienteParaTeste}) async {
  if (item.txId == null || !mbRespostasRevisao.contains(resposta)) return;
  if (resposta == 'categoria' && categoriaPk == null) return;
  await mbCriarTabelas();
  await mbGravarRevisoes(mbRegistrosDeResposta(item, resposta,
      categoriaPk: categoriaPk, reembolsoDe: reembolsoDe, agora: isoMs(DateTime.now())));
  await mbGravarEstado({_chaveRepuxar: isoMs(DateTime.now())});
  await mbAtualizarRevisar();
  await sincronizarMeuBanco(clienteParaTeste: clienteParaTeste);
}

// Desliga um reembolso (ou desfaz qualquer resposta): apaga a decisão e o re-pull completo devolve a transação ao que o
// banco diz. Item que vinha da fila do Worker volta para ela.
Future<void> mbDesfazerRevisao(String txId, {MbCliente? clienteParaTeste}) async {
  await mbCriarTabelas();
  final agora = isoMs(DateTime.now());
  await mbGravarRevisoes([Registro('revisoes', 'tx:$txId', null, agora, agora)]);
  await mbGravarEstado({_chaveRepuxar: agora});
  await mbAtualizarRevisar();
  await sincronizarMeuBanco(clienteParaTeste: clienteParaTeste);
}

// "Salário não detectado": marca a entrada escolhida como salário no servidor e sincroniza. Retorna o erro, se houver.
Future<String?> mbMarcarSalario(String txId) async {
  try {
    final cliente = await mbClienteConfigurado();
    if (cliente == null) return "Pareie o app com o Meu Banco primeiro.";
    await cliente.definirSalario(txId);
    await sincronizarMeuBanco();
    return null;
  } on MbErroHttp catch (e) {
    return e.mensagem;
  } on TimeoutException {
    return "O Meu Banco demorou a responder. Tente de novo.";
  } on http.ClientException {
    return "Sem conexão com o Meu Banco.";
  } catch (e) {
    if (kDebugMode) debugPrint("Meu Banco: falha ao marcar o salário: $e");
    return "Não foi possível marcar o salário agora.";
  }
}

// Pede ao Worker para consultar a Pluggy agora e, se deu certo, sincroniza. Retorna a mensagem do snackbar.
Future<String> meuBancoAtualizar() async {
  try {
    final cliente = await mbClienteConfigurado();
    if (cliente == null) return "Pareie o app com o Meu Banco primeiro.";
    final r = await cliente.atualizar();
    if (r['ok'] == true) {
      await sincronizarMeuBanco();
      return "Atualizado";
    }
    return (r['mensagem'] ?? "Não foi possível atualizar agora.").toString();
  } on MbErroLimite catch (e) {
    final quando = e.liberadoEm?.toLocal();
    if (quando == null) return e.mensagem;
    return "Atualizado há pouco. Tente de novo às ${DateFormat.Hm('pt_BR').format(quando)}.";
  } on MbErroHttp catch (e) {
    return e.status == 401 ? "Token inválido ou revogado. Pareie de novo." : e.mensagem;
  } on TimeoutException {
    return "O Meu Banco demorou a responder. Tente de novo.";
  } on http.ClientException {
    return "Sem conexão com o Meu Banco.";
  } catch (e) {
    if (kDebugMode) debugPrint("Meu Banco: falha ao atualizar: $e");
    return "Não foi possível atualizar agora.";
  }
}
