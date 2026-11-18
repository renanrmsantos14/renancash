import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/estadoInicio.dart' show brl, diaMes;
import 'package:budget/struct/mbSync/mapeamento.dart';
import 'package:budget/struct/meuBancoMapping.dart' show mbCarteiraInvestimentos;
import 'package:drift/drift.dart';

// Metas do Meu Banco.
//
// Modelo: a meta é um Objetivo "meta" do RenanCash (já sincronizado como `metas`). O que o RenanCash não tem é
// "a meta é composta por estas aplicações": isso vive em `mb_meta_aplicacao` (aplicação -> meta). A chave
// primária na aplicação garante "cada aplicação em uma meta só". O vínculo é copiado em
// `transactions.objective_fk` das transações `mb:inv:*` (mbReconciliarVinculos), e o progresso nativo do RenanCash
// (soma dos lançamentos pagos da meta) passa a ser a soma dos saldos atuais dessas aplicações.
// A tabela própria (e não só o objective_fk) existe porque o vínculo precisa sobreviver a um aparelho em que a
// transação da aplicação ainda não existe; e mexer só em `objective_fk` não cria ajuste (`mb_aplicado`) nem
// altera `dateTimeModified` das transações.

/// Meta criada uma vez, sem valor alvo. Pk fixo: dois aparelhos que a criem juntos não duplicam (LWW).
const String mbMetaReservaPk = 'mb:meta:reserva';
const String mbMetaReservaNome = 'Reserva de emergência';
const String _prefixoAplicacao = 'mb:inv:';
const String _chaveReservaCriada = 'reserva_criada';
const String _chaveAplicacoesVistas = 'aplicacoes_vistas';

/// Id da aplicação no sync (id Pluggy, sem o prefixo local).
String mbIdAplicacao(String pk) =>
    pk.startsWith(_prefixoAplicacao) ? pk.substring(_prefixoAplicacao.length) : pk;
String mbPkAplicacao(String id) => _prefixoAplicacao + id;

// ---------------------------------------------------------------------------------------------
// Vínculos

/// A tabela nasce com o primeiro uso (app sem Meu Banco pareado também abre a edição de meta).
Future<void> _tabela() => database.customStatement(mbDdlMetaAplicacao);

/// aplicação (pk) -> meta (pk), só de metas que existem.
Future<Map<String, String>> mbVinculosMetas() async {
  await _tabela();
  final linhas = await database
      .customSelect('SELECT v.aplicacao_pk, v.meta_pk FROM mb_meta_aplicacao v '
          'JOIN objectives o ON o.objective_pk = v.meta_pk')
      .get();
  return {
    for (final l in linhas) l.read<String>('aplicacao_pk'): l.read<String>('meta_pk')
  };
}

/// Ids de aplicação (sem prefixo, ordenados) de cada meta: o campo `aplicacao_ids` do sync.
Future<Map<String, List<String>>> mbAplicacoesPorMeta() async {
  final out = <String, List<String>>{};
  for (final e in (await mbVinculosMetas()).entries) {
    (out[e.value] ??= []).add(mbIdAplicacao(e.key));
  }
  for (final l in out.values) {
    l.sort();
  }
  return out;
}

/// Copia o vínculo para `objective_fk` das transações das aplicações (só escreve onde difere) e descarta
/// vínculos de metas que não existem mais.
Future<void> mbReconciliarVinculos() async {
  await database.customUpdate(
      'DELETE FROM mb_meta_aplicacao WHERE meta_pk NOT IN (SELECT objective_pk FROM objectives)',
      updates: {},
      updateKind: UpdateKind.delete);
  const alvo = '(SELECT v.meta_pk FROM mb_meta_aplicacao v '
      'WHERE v.aplicacao_pk = transactions.transaction_pk)';
  const diverge = "transaction_pk LIKE '$_prefixoAplicacao%' AND objective_fk IS NOT $alvo";
  // Sem divergência não escreve: evita recarregar os streams de transações a cada sync.
  if ((await database.customSelect('SELECT 1 FROM transactions WHERE $diverge LIMIT 1').get()).isEmpty) return;
  await database.customUpdate(
      "UPDATE transactions SET objective_fk = $alvo WHERE $diverge",
      updates: {database.transactions},
      updateKind: UpdateKind.update);
}

/// Define as aplicações da meta [metaPk]. Aplicação que estava em outra meta passa para esta (a interface
/// bloqueia isso; vale para sincronização remota conflitante).
Future<void> mbDefinirAplicacoesDaMeta(String metaPk, Iterable<String> aplicacaoPks) =>
    database.transaction(() async {
      await _tabela();
      await database
          .customStatement('DELETE FROM mb_meta_aplicacao WHERE meta_pk = ?', [metaPk]);
      for (final pk in aplicacaoPks) {
        await database.customStatement(
            'INSERT OR REPLACE INTO mb_meta_aplicacao (aplicacao_pk, meta_pk) VALUES (?, ?)',
            [pk, metaPk]);
      }
      // O tile do RenanCash só mostra o progresso positivo em meta de poupança (income); saldo de aplicação é positivo.
      if (aplicacaoPks.isNotEmpty) {
        await database.customUpdate(
            'UPDATE objectives SET income = 1 WHERE objective_pk = ? AND income = 0',
            variables: [Variable.withString(metaPk)],
            updates: {database.objectives},
            updateKind: UpdateKind.update);
      }
      await mbReconciliarVinculos();
    });

// ---------------------------------------------------------------------------------------------
// Aplicações atuais

class MbAplicacao {
  final String pk, nome;
  final String? banco, metaPk;
  final double saldo;
  const MbAplicacao(this.pk, this.nome, this.banco, this.saldo, this.metaPk);
  String get id => mbIdAplicacao(pk);
}

/// Aplicações da meta [metaPk] e as livres (sem meta nenhuma): o painel da tela da meta.
({List<MbAplicacao> ligadas, List<MbAplicacao> livres}) mbSepararAplicacoes(
        List<MbAplicacao> todas, String metaPk) =>
    (
      ligadas: [for (final a in todas) if (a.metaPk == metaPk) a],
      livres: [for (final a in todas) if (a.metaPk == null) a],
    );

double mbSaldoAplicacoes(Iterable<MbAplicacao> l) => l.fold(0.0, (s, a) => s + a.saldo);

/// Escolha feita na tela da meta. Toca a meta antes (data de edição nova: o sync leva as aplicações por LWW);
/// depois grava os vínculos, que também passam a meta para poupança (`income`).
Future<void> mbEscolherAplicacoesDaMeta(Objective meta, Set<String> aplicacaoPks) async {
  await database.createOrUpdateObjective(meta);
  await mbDefinirAplicacoesDaMeta(meta.objectivePk, aplicacaoPks);
}

/// Aplicações da carteira Investimentos, com a meta a que pertencem (ou null).
Future<List<MbAplicacao>> mbAplicacoes() async {
  final vinculos = await mbVinculosMetas();
  final txs = await (database.select(database.transactions)
        ..where((t) =>
            t.walletFk.equals(mbCarteiraInvestimentos) &
            t.transactionPk.like('$_prefixoAplicacao%'))
        // Nomes repetidos (4 "CDB - BANCO INTER"): maior saldo primeiro, ordem estável.
        ..orderBy([
          (t) => OrderingTerm.asc(t.name),
          (t) => OrderingTerm.desc(t.amount)
        ]))
      .get();
  return [
    for (final t in txs)
      MbAplicacao(t.transactionPk, t.name, t.note.isEmpty ? null : t.note, t.amount,
          vinculos[t.transactionPk])
  ];
}

// ---------------------------------------------------------------------------------------------
// Reserva de emergência

/// Cria a Reserva uma vez: pk fixo + `insertOrIgnore`; nada se o espelho já tem (ou apagou) a meta, ou se ela já
/// foi criada neste aparelho (quem apagar não a vê voltar). Chamar depois do pull.
Future<void> mbGarantirReserva({DateTime? agora}) async {
  if (await mbLerEstado(_chaveReservaCriada) != null) return;
  final id = idDoPk(mbMetaReservaPk);
  final noEspelho = await database
      .customSelect('SELECT 1 FROM mb_registros WHERE tabela = ? AND id = ?',
          variables: [Variable<String>('metas'), Variable<String>(id)])
      .get();
  final existe = noEspelho.isNotEmpty ||
      await (database.select(database.objectives)
            ..where((o) => o.objectivePk.equals(mbMetaReservaPk)))
          .getSingleOrNull() !=
          null;
  if (!existe) {
    await database.into(database.objectives).insert(
        ObjectivesCompanion.insert(
          objectivePk: const Value(mbMetaReservaPk),
          type: const Value(ObjectiveType.goal),
          name: mbMetaReservaNome,
          amount: 0,
          order: await _contarObjetivos(),
          pinned: const Value(true),
          income: const Value(true),
          walletFk: const Value('0'),
          dateTimeModified: Value(agora ?? DateTime.now()),
        ),
        mode: InsertMode.insertOrIgnore);
  }
  await mbGravarEstado({_chaveReservaCriada: '1'});
}

/// Vínculo inicial: toda aplicação (inclusive poupança) que o app ainda não tinha visto e que está sem meta vai para
/// a Reserva, uma única vez. Os ids vistos ficam em `mb_estado`; quem desvincula depois não é vinculado de novo.
/// Sem a Reserva (apagada ou ainda não criada) nada é marcado como visto. Chamar depois de `mbGarantirReserva`.
Future<void> mbVincularAplicacoesNovas() async {
  final reserva = await (database.select(database.objectives)
        ..where((o) => o.objectivePk.equals(mbMetaReservaPk)))
      .getSingleOrNull();
  if (reserva == null) return;
  final aplicacoes = await mbAplicacoes();
  final bruto = await mbLerEstado(_chaveAplicacoesVistas);
  final vistas = <String>{
    if (bruto != null) ...(jsonDecode(bruto) as List).cast<String>()
  };
  final novas = [for (final a in aplicacoes) if (!vistas.contains(a.pk)) a];
  if (novas.isEmpty) return;
  final livres = [for (final a in novas) if (a.metaPk == null) a.pk];
  if (livres.isNotEmpty) {
    // Toca a meta (o sync leva as aplicações por LWW) e só acrescenta: vínculos de aplicações ainda sem transação ficam.
    await database.createOrUpdateObjective(reserva);
    await database.transaction(() async {
      for (final pk in livres) {
        await database.customStatement(
            'INSERT OR IGNORE INTO mb_meta_aplicacao (aplicacao_pk, meta_pk) VALUES (?, ?)',
            [pk, mbMetaReservaPk]);
      }
      await database.customUpdate(
          'UPDATE objectives SET income = 1 WHERE objective_pk = ? AND income = 0',
          variables: [Variable.withString(mbMetaReservaPk)],
          updates: {database.objectives},
          updateKind: UpdateKind.update);
      await mbReconciliarVinculos();
    });
  }
  await mbGravarEstado({
    _chaveAplicacoesVistas: jsonEncode(([...vistas, ...novas.map((a) => a.pk)]..sort()))
  });
}

Future<int> _contarObjetivos() async => (await database
        .customSelect('SELECT COUNT(*) AS n FROM objectives')
        .getSingle())
    .read<int>('n');

// ---------------------------------------------------------------------------------------------
// Evolução mensal (série do Worker: `investimentos_mensal`)

class MbRetratoMes {
  final String mes; // aaaa-mm
  final List<MbAplicacaoMes> itens;
  const MbRetratoMes(this.mes, this.itens);
  double get total => itens.fold(0.0, (s, i) => s + i.saldo);
}

class MbAplicacaoMes {
  final String id, nome;
  final String? banco;
  final double saldo;
  /// Valor aplicado (amountOriginal do Pluggy) no fim do mês; null em retratos antigos ou quando o banco não informa.
  final double? aplicado;
  const MbAplicacaoMes(this.id, this.nome, this.banco, this.saldo, {this.aplicado});
}

/// Lê a série do JSON do Worker. Resposta sem o campo (Worker antigo) ou inválida = lista vazia.
List<MbRetratoMes> mbSerieDeJson(Object? json) {
  if (json is! List) return const [];
  final out = <MbRetratoMes>[];
  for (final m in json) {
    if (m is! Map || m['mes'] is! String || m['itens'] is! List) continue;
    if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(m['mes'] as String)) continue;
    out.add(MbRetratoMes(m['mes'] as String, [
      for (final i in m['itens'] as List)
        if (i is Map && i['id'] is String && i['saldo'] is num)
          MbAplicacaoMes(i['id'] as String, '${i['nome'] ?? ''}',
              i['banco'] is String ? i['banco'] as String : null, (i['saldo'] as num).toDouble(),
              aplicado: i['aplicado'] is num ? (i['aplicado'] as num).toDouble() : null)
    ]));
  }
  out.sort((a, b) => a.mes.compareTo(b.mes));
  return out;
}

/// Total de cada mês, a variação sobre o mês anterior (null no primeiro) e quanto dela foi rendimento.
/// `rendimento` = soma, por aplicação, da variação de (saldo − aplicado): aporte e resgate mexem nos dois e se anulam.
/// Aplicação nova no mês conta o que rendeu desde a compra; a que saiu (resgate total) não entra. Null quando alguma
/// aplicação do mês não tem `aplicado` (retrato antigo ou banco que não informa) ou no primeiro mês.
List<({MbRetratoMes mes, double? variacao, double? rendimento})> mbSerieComVariacao(
        List<MbRetratoMes> serie) =>
    [
      for (var i = 0; i < serie.length; i++)
        (
          mes: serie[i],
          variacao: i == 0 ? null : serie[i].total - serie[i - 1].total,
          rendimento: i == 0 ? null : _rendimentoDoMes(serie[i - 1], serie[i]),
        )
    ];

double? _rendimentoDoMes(MbRetratoMes antes, MbRetratoMes agora) {
  final ganhoAntes = {
    for (final a in antes.itens)
      if (a.aplicado != null) a.id: a.saldo - a.aplicado!
  };
  final idsAntes = {for (final a in antes.itens) a.id};
  var total = 0.0;
  for (final a in agora.itens) {
    if (a.aplicado == null) return null;
    final ganho = a.saldo - a.aplicado!;
    if (!idsAntes.contains(a.id)) {
      total += ganho; // aplicação nova no mês
    } else if (ganhoAntes.containsKey(a.id)) {
      total += ganho - ganhoAntes[a.id]!;
    } else {
      return null; // existia sem `aplicado`: não dá para separar
    }
  }
  return total;
}

Future<List<MbRetratoMes>> mbLerSerieMensal() async {
  final texto = await mbLerEstado(chaveSerieMensal);
  if (texto == null) return const [];
  try {
    return mbSerieDeJson(jsonDecode(texto));
  } catch (_) {
    return const [];
  }
}

const String chaveSerieMensal = 'investimentos_mensal';

// ---------------------------------------------------------------------------------------------
// Detalhes de cada aplicação (Worker: campos extras de `investimentos`, tirados do objeto Investment do Pluggy)

class MbDetalheInvestimento {
  /// Aplicado (amountOriginal) e rendimento bruto (saldo − aplicado, ou amountProfit). Null: o banco não informa.
  final double? aplicado, rendimento, liquido, impostos;
  final ({double valor, String? indexador})? taxa;
  final double? rentabilidadeMes, rentabilidade12m;
  final DateTime? vencimento, aplicadoEm;
  final String? emissor, subtipo;
  const MbDetalheInvestimento({
    this.aplicado,
    this.rendimento,
    this.liquido,
    this.impostos,
    this.taxa,
    this.rentabilidadeMes,
    this.rentabilidade12m,
    this.vencimento,
    this.aplicadoEm,
    this.emissor,
    this.subtipo,
  });

  /// Rendimento sobre o aplicado, em %. Null sem os dois valores.
  double? get percentual =>
      aplicado == null || rendimento == null || aplicado! <= 0 ? null : rendimento! / aplicado! * 100;
}

const String chaveDetalhesInvestimentos = 'investimentos_detalhes';

double? _numOuNull(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
DateTime? _diaOuNull(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// Detalhes por id da aplicação (o mesmo de [MbAplicacao.id]). Worker antigo (sem os campos) = detalhes vazios.
Map<String, MbDetalheInvestimento> mbDetalhesDeJson(Object? json) {
  if (json is! List) return const {};
  return {
    for (final i in json)
      if (i is Map && i['id'] != null)
        i['id'].toString(): MbDetalheInvestimento(
          aplicado: _numOuNull(i['aplicado']),
          rendimento: _numOuNull(i['rendimento']),
          liquido: _numOuNull(i['liquido']),
          impostos: _numOuNull(i['impostos']),
          taxa: i['taxa'] is Map && _numOuNull((i['taxa'] as Map)['valor']) != null
              ? (
                  valor: _numOuNull((i['taxa'] as Map)['valor'])!,
                  indexador: (i['taxa'] as Map)['indexador']?.toString()
                )
              : null,
          rentabilidadeMes: _numOuNull(i['rentabilidade_mes']),
          rentabilidade12m: _numOuNull(i['rentabilidade_12m']),
          vencimento: _diaOuNull(i['vencimento']),
          aplicadoEm: _diaOuNull(i['aplicado_em']),
          emissor: i['emissor']?.toString(),
          subtipo: i['subtipo']?.toString(),
        )
  };
}

Future<Map<String, MbDetalheInvestimento>> mbLerDetalhesInvestimentos() async {
  final texto = await mbLerEstado(chaveDetalhesInvestimentos);
  if (texto == null) return const {};
  try {
    return mbDetalhesDeJson(jsonDecode(texto));
  } catch (_) {
    return const {};
  }
}

/// "110% do CDI", "IPCA + 6,5%", "12,5% a.a." (prefixada). Null sem taxa.
String? mbRotuloTaxa(({double valor, String? indexador})? t) {
  if (t == null) return null;
  final v = t.valor.toStringAsFixed(t.valor % 1 == 0 ? 0 : 2).replaceAll('.', ',');
  final ix = t.indexador?.toUpperCase();
  if (ix == null || ix == 'PRE') return '$v% a.a.';
  if (ix == 'IPCA' || ix == 'IGPM') return '${ix == 'IGPM' ? 'IGP-M' : ix} + $v%';
  return '$v% do ${ix == 'DOLAR' ? 'dólar' : ix}';
}

// ---------------------------------------------------------------------------------------------
// Resumo (função pura; o resumo semanal do PR 7 usa a mesma)

class MbMetaDados {
  final String pk, nome;
  final double alvo; // 0 = sem valor definido
  final DateTime? prazo;
  final List<String> aplicacaoPks;
  const MbMetaDados(
      {required this.pk,
      required this.nome,
      required this.alvo,
      this.prazo,
      this.aplicacaoPks = const []});
}

class MbMetaResumo {
  final String pk, nome, texto;
  final double saldo;
  final double? alvo; // null = sem valor definido
  final double? progresso; // 0..1 (limitado); null sem alvo
  final double? falta; // 0 se atingiu; null sem alvo
  final DateTime? prazo;
  final int? diasRestantes; // negativo = vencido; null sem prazo
  const MbMetaResumo(this.pk, this.nome, this.texto, this.saldo, this.alvo,
      this.progresso, this.falta, this.prazo, this.diasRestantes);
}

/// Resumo de cada meta: saldo = soma dos saldos das suas aplicações ([saldoPorAplicacao] por pk).
/// [texto] é a linha pronta para o resumo semanal e a Início.
List<MbMetaResumo> mbResumoMetas(
    {required List<MbMetaDados> metas,
    required Map<String, double> saldoPorAplicacao,
    required DateTime hoje}) {
  final dia = DateTime(hoje.year, hoje.month, hoje.day);
  return [
    for (final m in metas)
      () {
        final saldo = m.aplicacaoPks.fold(0.0, (s, pk) => s + (saldoPorAplicacao[pk] ?? 0));
        final temAlvo = m.alvo > 0;
        final falta = temAlvo ? (m.alvo - saldo).clamp(0, double.infinity).toDouble() : null;
        final progresso = temAlvo ? (saldo / m.alvo).clamp(0.0, 1.0).toDouble() : null;
        final dias = m.prazo == null
            ? null
            : DateTime(m.prazo!.year, m.prazo!.month, m.prazo!.day).difference(dia).inDays;
        final partes = <String>[
          if (temAlvo) '${brl(saldo)} de ${brl(m.alvo)} (${(progresso! * 100).floor()}%)' else brl(saldo),
          if (!temAlvo) 'defina o valor da meta',
          if (temAlvo && falta! > 0) 'faltam ${brl(falta)}',
          if (temAlvo && falta == 0) 'meta atingida',
          if (m.prazo != null)
            dias! < 0
                ? 'prazo venceu em ${diaMes(m.prazo!)}'
                : dias == 0
                    ? 'prazo é hoje'
                    : 'prazo ${diaMes(m.prazo!)} ($dias ${dias == 1 ? 'dia' : 'dias'})',
        ];
        return MbMetaResumo(m.pk, m.nome, '${m.nome}: ${partes.join(', ')}', saldo,
            temAlvo ? m.alvo : null, progresso, falta, m.prazo, dias);
      }()
  ];
}

/// Metas do banco (não arquivadas) prontas para [mbResumoMetas].
Future<List<MbMetaResumo>> mbResumoMetasLocais({DateTime? hoje}) async {
  final porMeta = await mbVinculosMetas();
  final aplicacoes = await mbAplicacoes();
  final saldos = {for (final a in aplicacoes) a.pk: a.saldo};
  final aplicPorMeta = <String, List<String>>{};
  for (final e in porMeta.entries) {
    (aplicPorMeta[e.value] ??= []).add(e.key);
  }
  final objetivos = await (database.select(database.objectives)
        ..where((o) => o.type.equalsValue(ObjectiveType.goal) & o.archived.equals(false))
        ..orderBy([(o) => OrderingTerm.asc(o.order)]))
      .get();
  return mbResumoMetas(
      metas: [
        for (final o in objetivos)
          MbMetaDados(
              pk: o.objectivePk,
              nome: o.name,
              alvo: o.amount,
              prazo: o.endDate,
              aplicacaoPks: aplicPorMeta[o.objectivePk] ?? const [])
      ],
      saldoPorAplicacao: saldos,
      hoje: hoje ?? DateTime.now());
}
