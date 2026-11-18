import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/configuracoes.dart';
import 'package:budget/struct/mbSync/detectar.dart';
import 'package:budget/struct/mbSync/mapeamento.dart';
import 'package:budget/struct/mbSync/metas.dart';
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/meuBancoMapping.dart' show mbPrefixo;

String? mbEditadoEm(DateTime? d) => d == null || d.year < 2001 ? null : isoMs(d);

// Carteira manual: sem prefixo `mb:` (inclui a de investimentos) e fora da padrão '0', que existe em todo aparelho.
bool mbCarteiraSincroniza(String pk) => pk != '0' && !pk.startsWith(mbPrefixo);

// Título e nota que o usuário editou numa transação `mb:` (editada = dateTimeModified depois de 2000); sem edição
// o texto vem do banco e não viaja. Nota vazia não é enviada (o esquema não aceita texto vazio): apagar a nota não propaga.
Map<String, dynamic> mbTextosEditados(Transaction t) =>
    mbEditadoEm(t.dateTimeModified) == null
        ? const {}
        : {
            if (t.name.trim().isNotEmpty) 'nome': _cortar200(t.name.trim()),
            if (t.note.trim().isNotEmpty && t.note != 'Pendente')
              'nota': _cortar200(t.note.trim()),
          };
String? _naoVazio(String? s) => s == null || s.isEmpty ? null : s;
String _cortar200(String s) => s.length > 200 ? s.substring(0, 200) : s;

Projetado mbProjCarteira(TransactionWallet w) => Projetado(
    'carteiras',
    idDoPk(w.walletPk),
    {
      'nome': _cortar200(w.name),
      // o Worker rejeita texto vazio
      'cor': _naoVazio(w.colour),
      'icone': _naoVazio(w.iconName),
      'ordem': w.order,
      'moeda': _naoVazio(w.currency),
      'decimais': w.decimals,
    },
    mbEditadoEm(w.dateTimeModified));

Projetado mbProjCategoria(TransactionCategory c) => Projetado(
    'categorias',
    idDoPk(c.categoryPk),
    projetarCategoria(CatLocal(
        pk: c.categoryPk,
        nome: c.name,
        receita: c.income,
        cor: c.colour,
        icone: c.iconName,
        paiPk: c.mainCategoryPk,
        ordem: c.order)),
    mbEditadoEm(c.dateTimeModified));

// `servidor`: dados do registro vigente no servidor. Um sinalizador falso só é enviado (como 0) se o servidor tem o 1.
Projetado mbProjOrcamento(Budget b, {Map<String, dynamic>? servidor}) {
  int? sinal(bool v, String chave) =>
      v ? 1 : (servidor?[chave] != null ? 0 : null);
  return Projetado(
      'orcamentos',
      idDoPk(b.budgetPk),
      projetarOrcamento(OrcLocal(
          pk: b.budgetPk,
          nome: b.name,
          valor: b.amount,
          categoriaPks: b.categoryFks,
          arquivado: sinal(b.archived, 'arquivado'),
          limiteAbsoluto:
              sinal(b.isAbsoluteSpendingLimit, 'limite_absoluto'))),
      mbEditadoEm(b.dateTimeModified));
}

// Limite de uma categoria dentro de um orçamento. `valor` é percentual ou absoluto conforme `limite_absoluto` do orçamento.
Projetado mbProjLimite(CategoryBudgetLimit l) => Projetado(
    'limites',
    idDoPk(l.categoryLimitPk),
    {
      'orcamento_id': idDoPk(l.budgetFk),
      'categoria_id': idDoPk(l.categoryFk),
      'valor': l.amount,
    },
    mbEditadoEm(l.dateTimeModified));

Projetado mbProjObjetivo(Objective o, {List<String> aplicacoes = const []}) {
  final divida = o.type == ObjectiveType.loan;
  return Projetado(
      divida ? 'dividas' : 'metas',
      idDoPk(o.objectivePk),
      projetarObjetivo(ObjLocal(
          pk: o.objectivePk,
          nome: o.name,
          divida: divida,
          receita: o.income,
          valor: o.amount,
          prazo: o.endDate,
          aplicacaoIds: aplicacoes)),
      mbEditadoEm(o.dateTimeModified));
}

const _repeticoes = {
  BudgetReoccurence.daily: 'diaria',
  BudgetReoccurence.weekly: 'semanal',
  BudgetReoccurence.monthly: 'mensal',
  BudgetReoccurence.yearly: 'anual',
  BudgetReoccurence.custom: 'personalizada',
};
String? mbRepeticaoTexto(BudgetReoccurence? r) => _repeticoes[r];
BudgetReoccurence? mbRepeticaoDeTexto(String? s) =>
    _repeticoes.entries.where((e) => e.value == s).map((e) => e.key).firstOrNull;

// Agendada (upcoming) e recorrente (repetitive) viajam como lançamento com `tipo`.
String? mbTipoAgendado(TransactionSpecialType? t) => switch (t) {
      TransactionSpecialType.upcoming => 'agendada',
      TransactionSpecialType.repetitive => 'recorrente',
      _ => null,
    };
TransactionSpecialType? mbTipoAgendadoDeTexto(String? s) => switch (s) {
      'agendada' => TransactionSpecialType.upcoming,
      'recorrente' => TransactionSpecialType.repetitive,
      _ => null,
    };

// Ocorrência paga não é desfeita por versão não paga de outro aparelho (ver _lancamento). Despagar de propósito
// (o servidor tem pago 1 e aqui está 0) vai com `despago: 1`, que acompanha o registro enquanto ela estiver não paga
// (aparelho que ficou dias offline ainda vê o marcador); ao pagar de novo sai `pago: 1` sem ele.
Projetado mbProjLancamento(Transaction t, String carteiraNome,
    {Set<String>? orcamentos,
    bool limparOrcamentos = false,
    Map<String, dynamic>? servidor}) {
  final tipo = mbTipoAgendado(t.type);
  final p = Projetado(
      'lancamentos',
      idDoPk(t.transactionPk),
      projetarLancamento(LancLocal(
          pk: t.transactionPk,
          nome: t.name,
          nota: t.note,
          valor: t.amount,
          categoriaPk: t.categoryFk,
          carteiraNome: carteiraNome,
          data: t.dateCreated,
          metaPk: t.objectiveFk,
          dividaPk: t.objectiveLoanFk,
          orcamentoPks: orcamentos,
          limparOrcamentos: limparOrcamentos,
          tipo: tipo,
          pago: t.paid,
          pulado: t.skipPaid,
          proximaCriada: t.createdAnotherFutureTransaction == true,
          repeticao: mbRepeticaoTexto(t.reoccurrence),
          periodo: t.periodLength,
          fim: t.endDate,
          vencimento: t.originalDateDue)),
      mbEditadoEm(t.dateTimeModified));
  if (tipo == null) return p;
  if (!t.paid && (servidor?['pago'] == 1 || servidor?['despago'] == 1)) {
    p.dados['despago'] = 1;
  } else if (t.paid && servidor?['despago'] != null) {
    p.dados['despago'] = null;
  }
  return p;
}

Projetado mbProjAssinatura(Transaction t) => Projetado(
    'assinaturas',
    idDoPk(t.transactionPk),
    projetarAssinatura(AssinLocal(
        pk: t.transactionPk,
        nome: t.name,
        valor: t.amount,
        dia: t.dateCreated.day,
        categoriaPk: t.categoryFk)),
    mbEditadoEm(t.dateTimeModified));

Projetado? mbProjRegra(
    TransactionAssociatedTitle a, Map<String, dynamic>? base) {
  final dados = projetarRegra(
      RegraLocal(
          pk: a.associatedTitlePk,
          titulo: a.title,
          categoriaPk: a.categoryFk,
          exato: a.isExactMatch),
      base);
  return dados == null
      ? null
      : Projetado('regras', idDoPk(a.associatedTitlePk), dados,
          mbEditadoEm(a.dateTimeModified));
}

// Ids remotos sem o prefixo `cashew:` (criados no painel) viram o pk local sem mudança (D2).
// Na projeção eles precisam voltar ao id original, senão o objeto pareceria novo e o original, excluído.
Set<String> mbIdsSemPrefixo(Iterable<Registro> registros) => {
      for (final r in registros)
        if (!r.id.startsWith(prefixoLocal)) r.id
    };

String mbIdLocal(String pk, Set<String> semPrefixo) =>
    semPrefixo.contains(pk) ? pk : idDoPk(pk);

Projetado mbReescreverIds(Projetado p, Set<String> semPrefixo) {
  if (semPrefixo.isEmpty) return p;
  String? ref(Object? v) => v is String ? mbIdLocal(pkDoId(v), semPrefixo) : null;
  final dados = {
    for (final e in p.dados.entries)
      e.key: switch (e.key) {
        'pai_id' || 'categoria_id' || 'meta_id' || 'divida_id' || 'orcamento_id' =>
          ref(e.value) ?? e.value,
        'categoria_ids' || 'orcamento_ids' when e.value is List => [
            for (final v in e.value as List) ref(v) ?? v
          ],
        _ => e.value,
      }
  };
  final id = p.tabela == 'ajustes' ? p.id : mbIdLocal(pkDoId(p.id), semPrefixo);
  return Projetado(p.tabela, id, dados, p.editadoEm);
}

bool mbEhLancamentoManual(Transaction t) =>
    !t.transactionPk.startsWith('mb:') &&
    (t.type == null ||
        t.type == TransactionSpecialType.credit ||
        t.type == TransactionSpecialType.debt ||
        mbTipoAgendado(t.type) != null);

// Projeta o estado atual do Drift. `espelho` fornece o padrão já conhecido das regras;
// `aplicado` (tx_pk -> categoria aplicada pelo sync) alimenta os ajustes de transações `mb:`.
// `existentes` recebe as chaves que continuam no Drift mas ficam fora da projeção (orçamento
// transação de outro tipo): ausência nelas não pode virar tombstone.
Future<Map<String, Projetado>> mbProjetarLocal(
    Map<String, Espelho> espelho, Map<String, String> aplicado,
    {required String agora, Set<String>? existentes}) async {
  final out = <String, Projetado>{};
  final semPrefixo = mbIdsSemPrefixo([for (final e in espelho.values) e.registro]);
  void add(Projetado? p) {
    if (p != null) {
      final q = mbReescreverIds(p, semPrefixo);
      out[q.chave] = q;
    }
  }

  final listaCarteiras = await database.select(database.wallets).get();
  final carteiras = {for (final w in listaCarteiras) w.walletPk: w.name};
  for (final w in listaCarteiras) {
    if (mbCarteiraSincroniza(w.walletPk)) {
      add(mbProjCarteira(w));
    } else {
      existentes?.add('carteiras/${mbIdLocal(w.walletPk, semPrefixo)}');
    }
  }
  final cats = await database.select(database.categories).get();
  final catPorPk = {for (final c in cats) c.categoryPk: c};
  cats.forEach((c) => add(mbProjCategoria(c)));
  for (final a in await database.select(database.associatedTitles).get()) {
    add(mbProjRegra(a, espelho['regras/${mbIdLocal(a.associatedTitlePk, semPrefixo)}']?.registro.dados));
  }
  final orcamentos = await database.select(database.budgets).get();
  for (final b in orcamentos) {
    add(mbProjOrcamento(b,
        servidor: espelho['orcamentos/${mbIdLocal(b.budgetPk, semPrefixo)}']
            ?.registro
            .dados));
  }
  // Limites por categoria: só os de orçamento que existe aqui (órfão fica fora, sem virar tombstone).
  final orcamentosPks = {for (final b in orcamentos) b.budgetPk};
  for (final l in await database.select(database.categoryBudgetLimits).get()) {
    if (orcamentosPks.contains(l.budgetFk)) {
      add(mbProjLimite(l));
    } else {
      existentes?.add('limites/${mbIdLocal(l.categoryLimitPk, semPrefixo)}');
    }
  }
  final aplicacoesPorMeta = await mbAplicacoesPorMeta();
  for (final o in await database.select(database.objectives).get()) {
    add(mbProjObjetivo(o, aplicacoes: aplicacoesPorMeta[o.objectivePk] ?? const []));
  }

  final escolhas = await mbTodasEscolhasDeOrcamento();
  // O servidor ainda guarda uma escolha que o padrão apagou: manda `orcamento_ids: null`.
  bool servidorTemEscolha(String tabela, String id) {
    final r = espelho['$tabela/$id']?.registro;
    return r != null && r.deletedAt == null && r.dados?['orcamento_ids'] != null;
  }

  final txs = await database.select(database.transactions).get();
  final mbPresentes = <String, Transaction>{};
  for (final t in txs) {
    if (t.transactionPk.startsWith('mb:')) {
      mbPresentes[t.transactionPk] = t;
    } else if (t.type == TransactionSpecialType.subscription) {
      add(mbProjAssinatura(t));
    } else if (mbEhLancamentoManual(t)) {
      add(mbProjLancamento(t, carteiras[t.walletFk] ?? '',
          servidor: espelho['lancamentos/${mbIdLocal(t.transactionPk, semPrefixo)}']
              ?.registro
              .dados,
          orcamentos: escolhas[t.transactionPk],
          limparOrcamentos: escolhas[t.transactionPk] == null &&
              servidorTemEscolha('lancamentos', mbIdLocal(t.transactionPk, semPrefixo))));
    } else {
      final id = mbIdLocal(t.transactionPk, semPrefixo);
      existentes?.addAll(['lancamentos/$id', 'assinaturas/$id']);
    }
  }
  for (final pk in {...mbPresentes.keys, ...aplicado.keys}) {
    final t = mbPresentes[pk];
    final vigente = espelho['ajustes/${pk.substring(pk.startsWith('mb:') ? 3 : 0)}'];
    add(projetarAjuste(
        ajusteDeCategoriaVigente: vigente != null &&
            vigente.registro.deletedAt == null &&
            vigente.registro.dados?['categoria_id'] != null,
        txPk: pk,
        categoriaPkAtual: t?.categoryFk,
        categoriaPkAplicada: aplicado[pk],
        existeLocal: t != null,
        nomeCategoria: catPorPk[t?.categoryFk]?.name ?? '',
        textos: t == null ? const {} : mbTextosEditados(t),
        orcamentoPks: escolhas[pk],
        limparOrcamentos: escolhas[pk] == null &&
            servidorTemEscolha('ajustes', pk.startsWith('mb:') ? pk.substring(3) : pk),
        editadoEm: t == null ? agora : mbEditadoEm(t.dateTimeModified)));
  }
  for (final c in await mbProjConfiguracoes(espelho, existentes ?? <String>{})) {
    out[c.chave] = c;
  }
  return out;
}
