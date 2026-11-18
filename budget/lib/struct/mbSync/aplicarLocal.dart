import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/configuracoes.dart';
import 'package:budget/struct/mbSync/detectar.dart';
import 'package:budget/struct/mbSync/linha.dart';
import 'package:budget/struct/mbSync/mapeamento.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/mbSync/projetarLocal.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:drift/drift.dart';

const List<String> _ordemAplicar = [
  'carteiras',
  'categorias',
  'regras',
  'orcamentos',
  'limites',
  'metas',
  'dividas',
  'lancamentos',
  'assinaturas',
  'ajustes',
  'configuracoes'
];

DateTime _proximoDia(int dia, DateTime hoje) {
  DateTime em(int ano, int mes) {
    final ultimo = DateTime(ano, mes + 1, 0).day;
    return DateTime(ano, mes, dia > ultimo ? ultimo : dia, 12);
  }

  final deste = em(hoje.year, hoje.month);
  return deste.isBefore(DateTime(hoje.year, hoje.month, hoje.day))
      ? em(hoje.year, hoje.month + 1)
      : deste;
}

// Leituras repetidas por registro, feitas uma vez por chamada de mbAplicarRegistros.
// Categorias e carteiras mudam durante a aplicação (invalidadas em _categoria e _carteira).
class _Cache {
  List<TransactionWallet>? _carteiras;
  final Map<bool, String?> _primeira = {};
  final Map<String, bool> _categoriaExiste = {};

  Future<List<TransactionWallet>> carteiras() async =>
      _carteiras ??= await database.select(database.wallets).get();

  Future<String?> primeiraCategoria(bool receita) async {
    if (!_primeira.containsKey(receita)) {
      _primeira[receita] = await _primeiraCategoria(receita);
    }
    return _primeira[receita];
  }

  Future<bool> categoriaExiste(String pk) async =>
      _categoriaExiste[pk] ??= await database.getCategoryInstanceOrNull(pk) != null;

  void carteirasMudaram() => _carteiras = null;

  void categoriasMudaram() {
    _primeira.clear();
    _categoriaExiste.clear();
  }
}

// Linha Drift completa que veio em `dados['linha']`; null se não veio, se não bate com este app ou se os campos
// mapeados dela divergem de `dados` (o painel do Worker edita `dados` e mantém a linha antiga: o mapeado vale).
// `proj` reprojeta a linha; `ignorar` são chaves que a reprojeção não sabe reproduzir.
T? _linha<T>(Map<String, dynamic> d,
    T Function(Map<String, dynamic>, {ValueSerializer? serializer}) ler,
    Projetado? Function(T) proj,
    {Set<String> ignorar = const {}}) {
  final l = mbLerLinha(d);
  if (l == null) return null;
  final obj = mbLinhaComo((m) => ler(m, serializer: mbSerializador), l);
  if (obj == null) return null;
  final p = proj(obj);
  if (p == null) return null;
  for (final e in p.dados.entries) {
    if (e.key == 'linha' || ignorar.contains(e.key)) continue;
    if (!_igual(e.value, d[e.key])) return null;
  }
  return obj;
}

bool _igual(dynamic a, dynamic b) {
  if (a is num && b is num) return a == b;
  return jsonCanonico(a) == jsonCanonico(b);
}

Future<int> _contar(TableInfo tabela) async => (await database
        .customSelect('SELECT COUNT(*) AS n FROM ${tabela.actualTableName}',
            readsFrom: {tabela}).getSingle())
    .read<int>('n');

// Grava os registros remotos vencedores direto no Drift (sem createOrUpdate*, para não
// gerar efeitos de orçamento compartilhado nem marcar a categoria como editada) e
// atualiza o espelho. Inclusões na ordem de dependência; exclusões na ordem inversa.
Future<void> mbAplicarRegistros(
    List<Registro> vencedores, Map<String, Espelho> espelho,
    {DateTime? agora}) async {
  final hoje = agora ?? DateTime.now();
  final ordenados = [...vencedores]
    ..sort((a, b) => _ordemAplicar
        .indexOf(a.tabela)
        .compareTo(_ordemAplicar.indexOf(b.tabela)));
  final vivos = ordenados.where((r) => r.deletedAt == null);
  final mortos = ordenados.where((r) => r.deletedAt != null).toList().reversed;
  final novos = <Espelho>[];
  final cache = _Cache();
  final semPrefixo = mbIdsSemPrefixo([
    for (final e in espelho.values) e.registro,
    ...vencedores,
  ]);
  await database.transaction(() async {
    for (final r in vivos) {
      Projetado? p;
      final d = r.dados;
      if (d != null) {
        try {
          p = await _aplicar(r, d, espelho, hoje, cache);
          if (p != null) p = mbReescreverIds(p, semPrefixo);
          if (r.tabela == 'carteiras' && p != null) {
            novos.addAll(await _religarLancamentos(r, p, espelho));
            cache.carteirasMudaram();
          }
        } catch (e) {
          // Registro remoto inaplicável (dados fora do formato esperado): fica só no espelho.
          p = null;
        }
      }
      novos.add(Espelho(r, p?.dados, false, null));
    }
    for (final r in mortos) {
      await _apagar(r);
      novos.add(Espelho(r, null, false, null));
    }
    await mbGravarEspelho(novos);
  });
}

Future<Projetado?> _aplicar(Registro r, Map<String, dynamic> d,
    Map<String, Espelho> espelho, DateTime hoje, _Cache cache) async {
  final modificado = Value<DateTime?>(DateTime.parse(r.updatedAt).toLocal());
  switch (r.tabela) {
    case 'carteiras':
      return _carteira(r, d, modificado);
    case 'categorias':
      return _categoria(r, d, modificado, cache);
    case 'regras':
      return _regra(r, d, espelho, modificado, cache);
    case 'orcamentos':
      return _orcamento(r, d, hoje, modificado);
    case 'limites':
      return _limite(r, d, modificado);
    case 'metas':
    case 'dividas':
      return _objetivo(r, d, modificado);
    case 'lancamentos':
      return _lancamento(r, d, modificado, cache);
    case 'configuracoes':
      return mbAplicarConfiguracao(r.id, d);
    case 'ajustes':
      return _ajuste(r, d, modificado);
    case 'assinaturas':
      return _assinatura(r, d, hoje, modificado, cache);
  }
  return null;
}

// Carteira criada em outro aparelho. Ordem local é preservada; carteira nova vai para o fim da lista.
Future<Projetado?> _carteira(
    Registro r, Map<String, dynamic> d, Value<DateTime?> modificado) async {
  final pk = pkDoId(r.id);
  final nome = (d['nome'] as String).trim();
  if (!mbCarteiraSincroniza(pk) || nome.isEmpty) return null;
  final existente = await database.getWalletInstanceOrNull(pk);
  await database.into(database.wallets).insertOnConflictUpdate(
      WalletsCompanion(
        walletPk: Value(pk),
        name: Value(nome),
        colour: Value(d['cor'] as String? ?? existente?.colour),
        iconName: Value(d['icone'] as String? ?? existente?.iconName),
        order: Value(existente?.order ?? (await database.getAllWallets()).length),
        currency: Value(d['moeda'] as String? ?? existente?.currency ?? 'brl'),
        decimals: Value((d['decimais'] as num?)?.toInt() ?? existente?.decimals ?? 2),
        dateTimeModified: modificado,
      ));
  final linha = _linha(d, TransactionWallet.fromJson, mbProjCarteira);
  if (linha != null) {
    await (database.update(database.wallets)..where((w) => w.walletPk.equals(pk)))
        .write(linha.toCompanion(false).copyWith(
            walletPk: const Value.absent(), dateTimeModified: modificado));
  }
  return mbProjCarteira((await database.getWalletInstanceOrNull(pk))!);
}

// Lançamentos que chegaram antes da carteira caíram na '0'; quando ela chega, voltam para ela.
// A data de modificação não muda, e o espelho passa a guardar o nome certo para não virar edição de volta.
Future<List<Espelho>> _religarLancamentos(
    Registro carteira, Projetado p, Map<String, Espelho> espelho) async {
  final pk = pkDoId(carteira.id);
  final nome = p.dados['nome'] as String;
  final alvos = [
    for (final e in espelho.values)
      if (e.registro.tabela == 'lancamentos' &&
          e.registro.deletedAt == null &&
          e.registro.dados?['carteira'] == nome)
        e
  ];
  final out = <Espelho>[];
  for (final e in alvos) {
    final txPk = pkDoId(e.registro.id);
    final n = await (database.update(database.transactions)
          ..where((t) =>
              t.transactionPk.equals(txPk) &
              t.walletFk.equals('0') &
              t.transactionPk.like('mb:%').not()))
        .write(TransactionsCompanion(walletFk: Value(pk)));
    if (n > 0 && e.projecao != null) {
      final linha = e.projecao!['linha'];
      out.add(Espelho(
          e.registro,
          {
            ...e.projecao!,
            'carteira': nome,
            if (linha is Map) 'linha': {...linha, 'walletFk': pk},
          },
          e.pendente,
          e.motivo));
    }
  }
  return out;
}

Future<Projetado?> _categoria(Registro r, Map<String, dynamic> d,
    Value<DateTime?> modificado, _Cache cache) async {
  final c = categoriaDeDados(r.id, d);
  cache.categoriasMudaram();
  final existente = await database.getCategoryInstanceOrNull(c.pk);
  final ordem = d['ordem'] != null
      ? c.ordem
      : existente?.order ?? await database.getAmountOfCategories();
  await database.into(database.categories).insertOnConflictUpdate(
      CategoriesCompanion(
        categoryPk: Value(c.pk),
        name: Value(c.nome),
        income: Value(c.receita),
        colour: Value(c.cor ?? existente?.colour),
        iconName: Value(c.icone ?? existente?.iconName ?? 'image.png'),
        mainCategoryPk: Value(c.paiPk),
        order: Value(ordem),
        dateTimeModified: modificado,
      ));
  final linha = _linha(d, TransactionCategory.fromJson, mbProjCategoria);
  if (linha != null) {
    await (database.update(database.categories)
          ..where((x) => x.categoryPk.equals(c.pk)))
        .write(linha.toCompanion(false).copyWith(
            categoryPk: const Value.absent(),
            methodAdded: const Value.absent(),
            dateTimeModified: modificado));
  }
  return mbProjCategoria((await database.getCategoryInstanceOrNull(c.pk))!);
}

Future<Projetado?> _regra(Registro r, Map<String, dynamic> d,
    Map<String, Espelho> espelho, Value<DateTime?> modificado, _Cache cache) async {
  final g = regraDeDados(r.id, d);
  if (g == null || !await cache.categoriaExiste(g.categoriaPk)) {
    return null;
  }
  final existente = await (database.select(database.associatedTitles)
        ..where((a) => a.associatedTitlePk.equals(g.pk)))
      .getSingleOrNull();
  await database.into(database.associatedTitles).insertOnConflictUpdate(
      AssociatedTitlesCompanion(
        associatedTitlePk: Value(g.pk),
        categoryFk: Value(g.categoriaPk),
        title: Value(g.titulo),
        isExactMatch: Value(g.exato),
        order: Value(existente?.order ??
            await _contar(database.associatedTitles)),
        dateTimeModified: modificado,
      ));
  final linha = _linha(d, TransactionAssociatedTitle.fromJson, (a) => mbProjRegra(a, d));
  if (linha != null) {
    await (database.update(database.associatedTitles)
          ..where((a) => a.associatedTitlePk.equals(g.pk)))
        .write(linha.toCompanion(false).copyWith(
            associatedTitlePk: const Value.absent(),
            categoryFk: const Value.absent(),
            dateTimeModified: modificado));
  }
  final gravado = await (database.select(database.associatedTitles)
        ..where((a) => a.associatedTitlePk.equals(g.pk)))
      .getSingle();
  return mbProjRegra(gravado, d);
}

Future<Projetado?> _orcamento(Registro r, Map<String, dynamic> d, DateTime hoje,
    Value<DateTime?> modificado) async {
  final o = orcamentoDeDados(r.id, d);
  final existente = await (database.select(database.budgets)
        ..where((b) => b.budgetPk.equals(o.pk)))
      .getSingleOrNull();
  final fks = o.categoriaPks == null || o.categoriaPks!.isEmpty
      ? null
      : o.categoriaPks;
  await database.into(database.budgets).insertOnConflictUpdate(BudgetsCompanion(
        budgetPk: Value(o.pk),
        name: Value(o.nome),
        amount: Value(o.valor),
        categoryFks: Value(fks),
        startDate: Value(existente?.startDate ?? DateTime(hoje.year, hoje.month, 1)),
        endDate: Value(existente?.endDate ??
            DateTime(hoje.year, hoje.month + 1, 0, 23, 59, 59)),
        // Sem o campo (registro antigo ou do painel) o estado local fica como está.
        archived: Value(d['arquivado'] == null
            ? existente?.archived ?? false
            : d['arquivado'] == 1),
        isAbsoluteSpendingLimit: Value(d['limite_absoluto'] == null
            ? existente?.isAbsoluteSpendingLimit ?? false
            : d['limite_absoluto'] == 1),
        periodLength: Value(existente?.periodLength ?? 1),
        reoccurrence: Value(existente?.reoccurrence ?? BudgetReoccurence.monthly),
        colour: Value(existente?.colour),
        order: Value(existente?.order ??
            await _contar(database.budgets)),
        walletFk: Value(existente?.walletFk ?? '0'),
        // Sem filtros o RenanCash somaria renda e ajuste de saldo no orçamento.
        budgetTransactionFilters: Value(existente?.budgetTransactionFilters ??
            [BudgetTransactionFilters.defaultBudgetTransactionFilters]),
        dateTimeModified: modificado,
      ));
  final linha = _linha(d, Budget.fromJson, (b) => mbProjOrcamento(b, servidor: d));
  if (linha != null) {
    // Compartilhamento é do aparelho: continua como está aqui.
    await (database.update(database.budgets)..where((b) => b.budgetPk.equals(o.pk)))
        .write(linha.toCompanion(false).copyWith(
            budgetPk: const Value.absent(),
            sharedKey: const Value.absent(),
            sharedOwnerMember: const Value.absent(),
            sharedDateUpdated: const Value.absent(),
            sharedMembers: const Value.absent(),
            sharedAllMembersEver: const Value.absent(),
            memberTransactionFilters: const Value.absent(),
            dateTimeModified: modificado));
  }
  return mbProjOrcamento(
      (await (database.select(database.budgets)
            ..where((b) => b.budgetPk.equals(o.pk)))
          .getSingle()),
      servidor: d);
}

// Limite de categoria: precisa do orçamento e da categoria já aqui (senão fica só no espelho).
Future<Projetado?> _limite(
    Registro r, Map<String, dynamic> d, Value<DateTime?> modificado) async {
  final pk = pkDoId(r.id);
  final orcamento = pkDoId(d['orcamento_id'] as String);
  final categoria = pkDoId(d['categoria_id'] as String);
  if (await (database.select(database.budgets)
            ..where((b) => b.budgetPk.equals(orcamento)))
          .getSingleOrNull() ==
          null ||
      await database.getCategoryInstanceOrNull(categoria) == null) {
    return null;
  }
  await database.into(database.categoryBudgetLimits).insertOnConflictUpdate(
      CategoryBudgetLimitsCompanion(
        categoryLimitPk: Value(pk),
        categoryFk: Value(categoria),
        budgetFk: Value(orcamento),
        amount: Value((d['valor'] as num).toDouble()),
        dateTimeModified: modificado,
      ));
  final linha = _linha(d, CategoryBudgetLimit.fromJson, mbProjLimite);
  if (linha != null) {
    await (database.update(database.categoryBudgetLimits)
          ..where((l) => l.categoryLimitPk.equals(pk)))
        .write(linha.toCompanion(false).copyWith(
            categoryLimitPk: const Value.absent(),
            categoryFk: const Value.absent(),
            budgetFk: const Value.absent(),
            dateTimeModified: modificado));
  }
  return mbProjLimite((await (database.select(database.categoryBudgetLimits)
        ..where((l) => l.categoryLimitPk.equals(pk)))
      .getSingle()));
}

Future<Projetado?> _objetivo(
    Registro r, Map<String, dynamic> d, Value<DateTime?> modificado) async {
  final o = objetivoDeDados(r.id, d, divida: r.tabela == 'dividas');
  final existente = await (database.select(database.objectives)
        ..where((x) => x.objectivePk.equals(o.pk)))
      .getSingleOrNull();
  await database.into(database.objectives).insertOnConflictUpdate(
      ObjectivesCompanion(
        objectivePk: Value(o.pk),
        type: Value(o.divida ? ObjectiveType.loan : ObjectiveType.goal),
        name: Value(o.nome),
        // Registro sem o valor (app antigo, painel) não zera o alvo que já existe aqui.
        amount: Value(
            (o.divida ? d['valor_total'] : d['valor_alvo']) is num || existente == null
                ? o.valor
                : existente.amount),
        // Meta mantém o income local (poupança por padrão): o progresso das aplicações é positivo.
        income: Value(o.divida ? o.receita : existente?.income ?? true),
        endDate: Value(o.prazo),
        order: Value(existente?.order ??
            await _contar(database.objectives)),
        walletFk: Value(existente?.walletFk ?? '0'),
        dateTimeModified: modificado,
      ));
  final linha = _linha(d, Objective.fromJson, (o) => mbProjObjetivo(o), ignorar: const {'aplicacao_ids'});
  if (linha != null) {
    // O tipo (meta ou dívida) vem da tabela do registro.
    await (database.update(database.objectives)
          ..where((x) => x.objectivePk.equals(o.pk)))
        .write(linha.toCompanion(false).copyWith(
            objectivePk: const Value.absent(),
            type: const Value.absent(),
            dateTimeModified: modificado));
  }
  // Sem `aplicacao_ids` (registro de app antigo) os vínculos locais ficam como estão.
  if (o.aplicacaoIds != null) {
    await mbDefinirAplicacoesDaMeta(o.pk, o.aplicacaoIds!.map(mbPkAplicacao));
  }
  return mbProjObjetivo(
      await (database.select(database.objectives)
            ..where((x) => x.objectivePk.equals(o.pk)))
          .getSingle(),
      aplicacoes: (await mbAplicacoesPorMeta())[o.pk] ?? const []);
}

Future<String?> _primeiraCategoria(bool receita) async {
  final l = await (database.select(database.categories)
        ..where((c) => c.income.equals(receita) & c.mainCategoryPk.isNull())
        ..orderBy([(c) => OrderingTerm.asc(c.order)])
        ..limit(1))
      .get();
  return l.isEmpty ? null : l.first.categoryPk;
}

Future<Projetado?> _lancamento(Registro r, Map<String, dynamic> d,
    Value<DateTime?> modificado, _Cache cache) async {
  final valor = (d['valor'] as num).toDouble();
  final receita = valor > 0;
  final padrao = await cache.primeiraCategoria(receita);
  final l = lancamentoDeDados(r.id, d, categoriaPadrao: padrao ?? '');
  var categoria = l.categoriaPk;
  if (!await cache.categoriaExiste(categoria)) {
    if (padrao == null) return null;
    categoria = padrao;
  }
  final carteiras = await cache.carteiras();
  final carteira = carteiras
          .where((w) => w.name == l.carteiraNome)
          .map((w) => w.walletPk)
          .firstOrNull ??
      '0';
  // Agendada/recorrente carrega o estado completo (pago, repetição, vencimento). A ocorrência seguinte
  // tem pk previsível (`updatePredictableKey`): os dois aparelhos geram o mesmo pk e o registro vence por LWW, sem duplicar.
  final tipo = mbTipoAgendadoDeTexto(l.tipo);
  final existente = await (database.select(database.transactions)
        ..where((x) => x.transactionPk.equals(l.pk)))
      .getSingleOrNull();
  // Paga aqui e chegou não paga sem `despago` (edição concorrente de outro aparelho): continua paga e a
  // projeção devolvida (pago 0) difere da local, então a versão paga é reenviada e o outro aparelho a recebe.
  final eraAgendada = mbTipoAgendado(existente?.type) != null;
  final manterPaga =
      tipo != null && !l.pago && d['despago'] != 1 && eraAgendada && existente!.paid;
  await database.into(database.transactions).insertOnConflictUpdate(
      TransactionsCompanion(
        transactionPk: Value(l.pk),
        name: Value(l.nome),
        amount: Value(l.valor),
        note: Value(l.nota),
        categoryFk: Value(categoria),
        walletFk: Value(carteira),
        dateCreated: Value(l.data),
        originalDateDue: Value(tipo == null ? l.data : l.vencimento ?? l.data),
        income: Value(receita),
        paid: Value(tipo == null ? true : l.pago || manterPaga),
        // Deixou de ser agendada (virou lançamento comum em outro aparelho): zera o tipo.
        type: tipo != null || eraAgendada ? Value(tipo) : const Value.absent(),
        skipPaid: tipo == null ? const Value.absent() : Value(l.pulado),
        createdAnotherFutureTransaction:
            tipo == null
                ? const Value.absent()
                : Value(l.proximaCriada ||
                    (manterPaga && existente.createdAnotherFutureTransaction == true)),
        reoccurrence: tipo == null
            ? const Value.absent()
            : Value(mbRepeticaoDeTexto(l.repeticao)),
        periodLength: tipo == null ? const Value.absent() : Value(l.periodo),
        endDate: tipo == null ? const Value.absent() : Value(l.fim),
        objectiveFk: Value(l.metaPk),
        objectiveLoanFk: Value(l.dividaPk),
        dateTimeModified: modificado,
      ));
  final nomeDaLinha = (() {
    final fk = mbLerLinha(d)?['walletFk'];
    return carteiras.where((w) => w.walletPk == fk).map((w) => w.name).firstOrNull;
  })();
  final linha = _linha(
      d,
      Transaction.fromJson,
      (t) => mbProjLancamento(t, nomeDaLinha ?? ''),
      // Orçamentos e `despago` vêm de outros campos; sem a carteira local o nome não é conferível.
      ignorar: {'orcamento_ids', 'despago', if (nomeDaLinha == null) 'carteira'});
  if (linha != null) {
    // Chave que aponta para algo que ainda não chegou fica como a lógica acima resolveu.
    final carteiraExiste = carteiras.any((w) => w.walletPk == linha.walletFk);
    final subExiste = linha.subCategoryFk == null ||
        await cache.categoriaExiste(linha.subCategoryFk!);
    await (database.update(database.transactions)
          ..where((x) => x.transactionPk.equals(l.pk)))
        .write(linha.toCompanion(false).copyWith(
              transactionPk: const Value.absent(),
              categoryFk: await cache.categoriaExiste(linha.categoryFk)
                  ? null
                  : const Value.absent(),
              walletFk: carteiraExiste ? null : const Value.absent(),
              subCategoryFk: subExiste ? null : const Value.absent(),
              objectiveFk: const Value.absent(),
              objectiveLoanFk: const Value.absent(),
              methodAdded: const Value.absent(),
              transactionOwnerEmail: const Value.absent(),
              transactionOriginalOwnerEmail: const Value.absent(),
              sharedKey: const Value.absent(),
              sharedOldKey: const Value.absent(),
              sharedStatus: const Value.absent(),
              sharedDateUpdated: const Value.absent(),
              sharedReferenceBudgetPk: const Value.absent(),
              // A ocorrência paga aqui continua paga (ver manterPaga).
              paid: manterPaga ? const Value(true) : null,
              createdAnotherFutureTransaction:
                  manterPaga && existente.createdAnotherFutureTransaction == true
                      ? const Value(true)
                      : null,
              dateTimeModified: modificado,
            ));
  }
  await mbGravarEscolhaDeOrcamento(l.pk, l.orcamentoPks);
  final t = await (database.select(database.transactions)
        ..where((x) => x.transactionPk.equals(l.pk)))
      .getSingle();
  final nomeCarteira =
      carteiras.where((w) => w.walletPk == t.walletFk).map((w) => w.name).firstOrNull ?? '';
  final p = mbProjLancamento(t, nomeCarteira,
      orcamentos: l.orcamentoPks, servidor: d);
  if (manterPaga) p.dados['pago'] = 0;
  return p;
}

// Ajuste de uma transação `mb:` feito em outro aparelho: só a escolha de orçamentos é aplicada aqui
// (categoria e gasto continuam vindo do mapeamento do servidor). A projeção devolvida é a mesma que
// projetarAjuste produz depois do mapeamento (categoria_id + category, orcamento_ids); com `null` o espelho
// ficaria diferente do local e o ajuste voltaria ao servidor como edição, com data nova, a cada aparelho.
Future<Projetado?> _ajuste(
    Registro r, Map<String, dynamic> d, Value<DateTime?> modificado) async {
  final escolha = orcamentoPksDeDados(d);
  final txPk = 'mb:${r.id}';
  await mbGravarEscolhaDeOrcamento(txPk, escolha);
  // Título e nota editados no outro aparelho; a transação passa a contar como editada (o pull do banco não os desfaz).
  String? texto(String chave) {
    final v = d[chave];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  final nome = texto('nome'), nota = texto('nota');
  await (database.update(database.transactions)
        ..where((t) => t.transactionPk.equals(txPk)))
      .write(TransactionsCompanion(
          name: nome == null ? const Value.absent() : Value(nome),
          note: nota == null ? const Value.absent() : Value(nota),
          dateTimeModified: modificado));
  final dados = <String, dynamic>{};
  final tx = await (database.select(database.transactions)
        ..where((t) => t.transactionPk.equals(txPk)))
      .getSingleOrNull();
  // Mesma projeção que o aparelho gera sozinho (mbTextosEditados), senão o ajuste voltaria como edição.
  if (tx != null) dados.addAll(mbTextosEditados(tx));
  final categoriaId = d['categoria_id'];
  if (categoriaId is String && categoriaId.isNotEmpty) {
    final c = await database.getCategoryInstanceOrNull(pkDoId(categoriaId));
    dados['categoria_id'] = categoriaId;
    dados['category'] = c?.name ?? '';
  }
  if (escolha != null) {
    dados['orcamento_ids'] = (escolha.map(idDoPk).toList()..sort());
  }
  return dados.isEmpty ? null : Projetado('ajustes', r.id, dados, null);
}

Future<Projetado?> _assinatura(Registro r, Map<String, dynamic> d, DateTime hoje,
    Value<DateTime?> modificado, _Cache cache) async {
  final padrao = await cache.primeiraCategoria(false);
  final a = assinaturaDeDados(r.id, d, categoriaPadrao: padrao ?? '');
  if (a == null) return null;
  var categoria = a.categoriaPk;
  if (!await cache.categoriaExiste(categoria)) {
    if (padrao == null) return null;
    categoria = padrao;
  }
  final existente = await (database.select(database.transactions)
        ..where((x) => x.transactionPk.equals(a.pk)))
      .getSingleOrNull();
  final data = existente != null && existente.dateCreated.day == a.dia
      ? existente.dateCreated
      : _proximoDia(a.dia, hoje);
  await database.into(database.transactions).insertOnConflictUpdate(
      TransactionsCompanion(
        transactionPk: Value(a.pk),
        name: Value(a.nome),
        amount: Value(-a.valor.abs()),
        note: Value(existente?.note ?? ''),
        categoryFk: Value(categoria),
        walletFk: Value(existente?.walletFk ?? '0'),
        dateCreated: Value(data),
        originalDateDue: Value(existente?.originalDateDue ?? data),
        income: const Value(false),
        paid: const Value(false),
        type: const Value(TransactionSpecialType.subscription),
        reoccurrence: const Value(BudgetReoccurence.monthly),
        periodLength: const Value(1),
        dateTimeModified: modificado,
      ));
  // Com a linha, ocorrências já pagas ficam pagas (histórico), em vez de virar várias cobranças pendentes.
  final linha = _linha(d, Transaction.fromJson, mbProjAssinatura);
  if (linha != null) {
    final carteiraExiste =
        await database.getWalletInstanceOrNull(linha.walletFk) != null;
    await (database.update(database.transactions)
          ..where((x) => x.transactionPk.equals(a.pk)))
        .write(linha.toCompanion(false).copyWith(
              transactionPk: const Value.absent(),
              categoryFk: categoria == linha.categoryFk ? null : const Value.absent(),
              subCategoryFk: const Value.absent(),
              walletFk: carteiraExiste ? null : const Value.absent(),
              objectiveFk: const Value.absent(),
              objectiveLoanFk: const Value.absent(),
              dateTimeModified: modificado,
            ));
  }
  final t = await (database.select(database.transactions)
        ..where((x) => x.transactionPk.equals(a.pk)))
      .getSingle();
  return mbProjAssinatura(t);
}

Future<void> _apagar(Registro r) async {
  final pk = pkDoId(r.id);
  switch (r.tabela) {
    case 'carteiras':
      // Carteira com transações fica (não destrói dados).
      if (mbCarteiraSincroniza(pk) &&
          (await (database.select(database.transactions)
                    ..where((t) => t.walletFk.equals(pk))
                    ..limit(1))
                  .get())
              .isEmpty) {
        await (database.delete(database.wallets)..where((w) => w.walletPk.equals(pk)))
            .go();
      }
    case 'categorias':
      if ((await database.getAllTransactionsFromCategory(pk)).isEmpty) {
        await (database.delete(database.categories)
              ..where((c) => c.categoryPk.equals(pk)))
            .go();
      }
    case 'regras':
      await (database.delete(database.associatedTitles)
            ..where((a) => a.associatedTitlePk.equals(pk)))
          .go();
    case 'limites':
      await (database.delete(database.categoryBudgetLimits)
            ..where((l) => l.categoryLimitPk.equals(pk)))
          .go();
    case 'orcamentos':
      await (database.delete(database.categoryBudgetLimits)
            ..where((l) => l.budgetFk.equals(pk)))
          .go();
      await database.customStatement(
          'DELETE FROM mb_orcamento_tx WHERE orcamento_pk = ?', [pk]);
      await (database.delete(database.budgets)..where((b) => b.budgetPk.equals(pk)))
          .go();
    case 'metas':
    case 'dividas':
      await database.customStatement(
          'DELETE FROM mb_meta_aplicacao WHERE meta_pk = ?', [pk]);
      await (database.update(database.transactions)
            ..where((t) => t.objectiveFk.equals(pk)))
          .write(const TransactionsCompanion(objectiveFk: Value(null)));
      await (database.update(database.transactions)
            ..where((t) => t.objectiveLoanFk.equals(pk)))
          .write(const TransactionsCompanion(objectiveLoanFk: Value(null)));
      await (database.delete(database.objectives)
            ..where((o) => o.objectivePk.equals(pk)))
          .go();
    case 'lancamentos':
    case 'assinaturas':
      await database.customStatement(
          'DELETE FROM mb_orcamento_tx WHERE tx_pk = ?', [pk]);
      await (database.delete(database.transactions)
            ..where((t) => t.transactionPk.equals(pk)))
          .go();
  }
}
