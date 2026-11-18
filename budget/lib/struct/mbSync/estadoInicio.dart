import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/bancos.dart';
import 'package:budget/struct/mbSync/orcamentos.dart' show mbLerCicloGeral;
import 'package:budget/struct/ritmoCiclo.dart' show fracaoDoCiclo;
import 'package:budget/struct/meuBancoMapping.dart'
    show mbCarteiraInvestimentos, mbPkConta, mbPrefixo, mbSemPoupancas;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:intl/intl.dart' show NumberFormat;

/// `carteiras`: pks das carteiras locais das contas da linha (`mb:<id da conta>`, separados por '|').
/// Pelo id, não pelo nome: corrente e poupança do mesmo banco podem ter o mesmo nome.
typedef ContaInicio = ({String sigla, String nome, String tipo, double saldo, String carteiras});
typedef CartaoInicio = ({
  String nome,
  String final4,
  int? diasFecha,
  String? vence,
  double fatura,
  double? limite,
  double? pct
});

class ModeloInicio {
  final String ciclo, saudacao, origemDisponivel;
  final double disponivel, consumido;
  final double? limite, percentual;

  /// Não pago no ciclo (faixa clara da barra) e fração do ciclo decorrida até hoje (marca).
  final double aVencer;
  final double? fracaoHoje;
  final int diasRestantes, indiceHoje;
  final List<double> porDia;
  final List<ContaInicio> contas;
  final List<CartaoInicio> cartoes;
  /// "26 out – 25 nov" (sem o prefixo "Ciclo"); "Ciclo atual" quando não há datas.
  String get periodo => ciclo.startsWith('Ciclo ') && ciclo != 'Ciclo atual'
      ? ciclo.substring(6)
      : ciclo;
  bool get semDados => contas.isEmpty && cartoes.isEmpty && porDia.isEmpty;

  // Igualdade por conteúdo: permite ignorar recargas que não mudaram nada (sem setState).
  @override
  bool operator ==(Object o) =>
      o is ModeloInicio &&
      ciclo == o.ciclo &&
      saudacao == o.saudacao &&
      origemDisponivel == o.origemDisponivel &&
      disponivel == o.disponivel &&
      consumido == o.consumido &&
      limite == o.limite &&
      percentual == o.percentual &&
      aVencer == o.aVencer &&
      fracaoHoje == o.fracaoHoje &&
      diasRestantes == o.diasRestantes &&
      indiceHoje == o.indiceHoje &&
      listEquals(porDia, o.porDia) &&
      listEquals(contas, o.contas) &&
      listEquals(cartoes, o.cartoes);

  @override
  int get hashCode => Object.hash(ciclo, saudacao, disponivel, consumido,
      diasRestantes, indiceHoje, porDia.length, contas.length);

  const ModeloInicio({
    required this.ciclo,
    required this.saudacao,
    required this.disponivel,
    required this.origemDisponivel,
    required this.consumido,
    required this.limite,
    required this.percentual,
    this.aVencer = 0,
    this.fracaoHoje,
    required this.diasRestantes,
    required this.porDia,
    required this.indiceHoje,
    required this.contas,
    required this.cartoes,
  });
}

final _brl = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
String brl(double v) =>
    _brl.format(v).replaceAll('\u00a0', ' ').replaceFirst(RegExp(r'^-'), '−');

const _meses = [
  'jan', 'fev', 'mar', 'abr', 'mai', 'jun',
  'jul', 'ago', 'set', 'out', 'nov', 'dez'
];
String diaMes(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')} ${_meses[d.month - 1]}';
DateTime _soDia(DateTime d) => DateTime(d.year, d.month, d.day);

String quandoRelativo(DateTime d, DateTime agora) {
  final dif = _soDia(agora).difference(_soDia(d)).inDays;
  if (dif == 0) return 'hoje';
  if (dif == 1) return 'ontem';
  return diaMes(d);
}

String haQuanto(DateTime d, DateTime agora) {
  final min = agora.difference(d).inMinutes;
  if (min < 1) return 'agora';
  if (min < 60) return 'há $min min';
  if (min < 1440) return 'há ${min ~/ 60} h';
  return 'há ${min ~/ 1440} d';
}

DateTime? _lerData(Object? v) {
  if (v is! String || v.isEmpty) return null;
  var s = v.trim();
  if (!s.contains('T')) s = s.replaceFirst(' ', 'T');
  if (s.length > 10 && !RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(s)) s += 'Z';
  return DateTime.tryParse(s);
}

// Próxima ocorrência do dia do mês de [iso] (hoje conta).
DateTime? _proximoDia(Object? iso, DateTime agora) {
  if (iso is! String || iso.length < 10) return null;
  final dia = int.tryParse(iso.substring(8, 10));
  if (dia == null) return null;
  DateTime cand(int ano, int mes) {
    final ultimo = DateTime(ano, mes + 1, 0).day;
    return DateTime(ano, mes, dia > ultimo ? ultimo : dia);
  }

  final hoje = _soDia(agora);
  var c = cand(hoje.year, hoje.month);
  if (c.isBefore(hoje)) c = cand(hoje.year, hoje.month + 1);
  return c;
}

// "12 nov" do próximo dia de fechamento/vencimento de [iso].
String? mbProximoDiaMes(Object? iso, DateTime agora) {
  final d = _proximoDia(iso, agora);
  return d == null ? null : diaMes(d);
}

double _num(Object? v) => v is num ? v.toDouble() : 0;

/// Duas letras do banco para o avatar (Início e Contas conectadas).
String mbSigla(String nome) {
  // "Banco Inter" é IN, não BA: pula o prefixo genérico (só "Banco" sozinho fica BA).
  final letras = nome
      .trim()
      .replaceFirst(
          RegExp(r'^(?:(?:banco|conta|cart[ãa]o|d[eoa]s?)\s+)+', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^A-Za-zÀ-ú]'), '');
  return letras.isEmpty
      ? '··'
      : letras.substring(0, letras.length < 2 ? 1 : 2).toUpperCase();
}

String _listaE(List<String> itens) => itens.length <= 1
    ? itens.join()
    : '${itens.sublist(0, itens.length - 1).join(', ')} e ${itens.last}';

ModeloInicio montarModeloInicio({
  required Map<String, dynamic> ciclo,
  required List<Map<String, dynamic>> contas,
  required Map<String, dynamic> faturas,
  required String? sincronizadoEm,
  required String nome,
  required DateTime agora,
  // Configurações › Início: poupanças numa linha só (padrão) ou uma linha por conta.
  bool agruparPoupancas = true,
  // Orçamento Geral (o que "Definir limite do ciclo" edita): limite e gasto vêm dele, pela mesma
  // consulta da tela do orçamento. Sem Geral no aparelho, valem os números do Worker.
  ({double limite, double gasto, double aVencer})? geral,
}) {
  final ini = DateTime.tryParse('${ciclo['inicio']}');
  final fim = DateTime.tryParse('${ciclo['fim']}');
  final rotuloCiclo = ini != null && fim != null
      ? 'Ciclo ${diaMes(ini)} – ${diaMes(fim)}'
      : 'Ciclo atual';

  final bancarias = [for (final c in contas) if (c['type'] == 'BANK') c];
  final poupancas =
      bancarias.where((c) => c['subtype'] == 'SAVINGS_ACCOUNT').toList();
  final correntes =
      bancarias.where((c) => c['subtype'] != 'SAVINGS_ACCOUNT').toList();
  final saldoDe = (List<Map<String, dynamic>> l) =>
      l.fold<double>(0, (s, c) => s + _num(c['balance']));

  final linhas = <ContaInicio>[
    for (final c in correntes)
      (
        sigla: mbSigla('${c['bank'] ?? c['name']}'),
        nome: '${c['bank'] ?? c['name']}',
        tipo: 'Conta corrente',
        saldo: _num(c['balance']),
        carteiras: mbPkConta('${c['id']}')
      ),
    if (poupancas.length == 1 || !agruparPoupancas)
      for (final p in poupancas)
        (
          sigla: mbSigla('${p['bank'] ?? p['name']}'),
          nome: poupancas.length == 1 ? '${p['bank'] ?? p['name']}' : '${p['name']}',
          tipo: poupancas.length == 1 ? 'Poupança' : 'Poupança · ${p['bank'] ?? ''}',
          saldo: _num(p['balance']),
          carteiras: mbPkConta('${p['id']}')
        )
    else if (poupancas.length > 1)
      (
        sigla: 'PP',
        nome: 'Poupanças',
        tipo: '${poupancas.length} contas',
        saldo: saldoDe(poupancas),
        carteiras: poupancas.map((c) => mbPkConta('${c['id']}')).join('|')
      ),
  ];

  final bancos = <String>[];
  for (final c in correntes) {
    // Sem o final do número da conta ("BANCO INTER ·69-6" → "BANCO INTER"): o subtítulo cabe no celular.
    final b = '${c['bank'] ?? c['name']}'
        .replaceFirst(RegExp(r'\s*·\s*[\d-]+$'), '');
    if (!bancos.contains(b)) bancos.add(b);
  }
  if (poupancas.isNotEmpty) bancos.add('poupanças');
  final quando = _lerData(sincronizadoEm);
  final origem = [
    if (bancos.isNotEmpty) _listaE(bancos),
    if (quando != null) haQuanto(quando, agora),
  ].join(' · ');

  final cartoes = <CartaoInicio>[];
  for (final c in contas.where((c) => c['type'] == 'CREDIT')) {
    final bruto = '${c['name']}';
    final m = RegExp(r'\s*·(\d{4})$').firstMatch(bruto);
    final fat = faturas['${c['id']}'];
    final aberta = fat is Map ? fat['open_bill'] : null;
    final fatura = aberta is Map && aberta['total_amount'] is num
        ? _num(aberta['total_amount'])
        : _num(c['balance']);
    final limite = _num(c['credit_limit']);
    final fecha = _proximoDia(c['closing_date'], agora);
    final venceData = aberta is Map && _lerData('${aberta['due_date']}') != null
        ? _lerData('${aberta['due_date']}')
        : _proximoDia(c['due_date'], agora);
    cartoes.add((
      nome: m == null ? bruto : bruto.substring(0, m.start),
      final4: m?.group(1) ?? '',
      diasFecha: fecha?.difference(_soDia(agora)).inDays,
      vence: venceData == null ? null : diaMes(venceData),
      fatura: fatura,
      limite: limite > 0 ? limite : null,
      pct: limite > 0 ? fatura / limite * 100 : null,
    ));
  }

  final dias = [
    for (final d in (ciclo['por_dia'] as List? ?? const []))
      d is Map ? _num(d['valor']) : _num(d)
  ];
  final hojeIso = _soDia(agora).toIso8601String().substring(0, 10);
  var indice = [
    for (final d in (ciclo['por_dia'] as List? ?? const []))
      d is Map ? '${d['data']}' : ''
  ].indexOf(hojeIso);
  if (indice < 0) {
    indice = dias.isNotEmpty && fim != null && agora.isAfter(fim.add(const Duration(days: 1)))
        ? dias.length - 1
        : 0;
  }

  final limiteCiclo = geral != null
      ? (geral.limite > 0 ? geral.limite : null)
      : ciclo['limite'] is num
          ? _num(ciclo['limite'])
          : null;
  final gastoCiclo = geral?.gasto ?? _num(ciclo['consumido']);

  return ModeloInicio(
    ciclo: rotuloCiclo,
    saudacao: nome.trim().isEmpty ? 'Olá' : 'Olá, ${nome.trim()}',
    disponivel: saldoDe(bancarias),
    origemDisponivel: origem,
    consumido: gastoCiclo,
    limite: limiteCiclo,
    percentual: geral == null && ciclo['percentual'] is num
        ? _num(ciclo['percentual'])
        : limiteCiclo == null
            ? null
            : gastoCiclo / limiteCiclo * 100,
    aVencer: geral?.aVencer ?? 0,
    fracaoHoje: ini == null || fim == null ? null : fracaoDoCiclo(ini, fim, agora),
    diasRestantes: (ciclo['diasRestantes'] as num?)?.toInt() ??
        (fim == null ? 0 : _soDia(fim).difference(_soDia(agora)).inDays),
    porDia: dias,
    indiceHoje: indice,
    contas: linhas,
    cartoes: cartoes,
  );
}

Object? _decodificar(String? s) => s == null ? null : jsonDecode(s);

// Poupança não é conta no app: é aplicação (carteira Investimentos), então fica fora de contas e patrimônio.
List<Map<String, dynamic>> _contasSalvas(String? json) => mbSemPoupancas([
      for (final c in (_decodificar(json) as List? ?? const []))
        (c as Map).cast<String, dynamic>()
    ]);

/// Saldo real (o da Início) de cada carteira de conta bancária do Meu Banco (`mb:<id>`).
/// A soma das transações da carteira não é saldo: transferências, pagamento de fatura e
/// aplicações/resgates não viram lançamento, e não há saldo inicial.
Map<String, double> mbSaldosReais(List<Map<String, dynamic>> contas) => {
      for (final c in contas)
        if (c['type'] == 'BANK') mbPkConta('${c['id']}'): _num(c['balance'])
    };

Future<Map<String, double>> mbLerSaldosReais() async =>
    mbSaldosReais(_contasSalvas(await mbLerEstado('contas')));

// Linhas mais recentes do RenanCash para a seção ÚLTIMAS (ficam em paralelo com o modelo, para abrir no editor).
JoinedSelectStatement<HasResultSet, dynamic> _consultaUltimas() =>
    database.select(database.transactions).join([
    innerJoin(database.categories,
        database.categories.categoryPk.equalsExp(database.transactions.categoryFk))
  ])
    // Investimentos (mb:inv:) são saldos, não lançamentos.
    ..where(database.transactions.paid.equals(true) &
        database.transactions.transactionPk.like('mb:inv:%').not())
    ..orderBy([OrderingTerm.desc(database.transactions.dateCreated)])
    ..limit(5);

typedef TransacaoInicio = ({Transaction transaction, TransactionCategory category});

TransacaoInicio _linha(TypedResult r) => (
      category: r.readTable(database.categories),
      transaction: r.readTable(database.transactions)
    );

Future<List<TransacaoInicio>> mbUltimasTransacoes() async =>
    [for (final r in await _consultaUltimas().get()) _linha(r)];

Stream<void> mbMudouUltimas() => _consultaUltimas().watch();

/// Pendência "salário não detectado" (35 dias sem salário no Inter), calculada pelo Worker em `ciclo`.
/// A fila "Para revisar" lê isto. Worker antigo não manda os campos: sem pendência.
typedef SalarioPendente = ({bool pendente, int dias, DateTime? ultimoSalario});

SalarioPendente mbSalarioPendente(Map? ciclo) => (
      pendente: ciclo?['salarioNaoDetectado'] == true,
      dias: (ciclo?['diasSemSalario'] as num?)?.toInt() ?? 0,
      ultimoSalario: DateTime.tryParse('${ciclo?['ultimoSalario']}'),
    );

Future<SalarioPendente> mbLerSalarioPendente() async {
  final ciclo = _decodificar(await mbLerEstado('ciclo'));
  return mbSalarioPendente(ciclo is Map ? ciclo : null);
}

Future<({ModeloInicio modelo, List<({Transaction transaction, TransactionCategory category})> transacoes})>
    mbCarregarModeloInicio(String nome, DateTime agora) async {
  final mapa = <String, Object?>{
    for (final k in ['ciclo', 'contas', 'faturas'])
      k: _decodificar(await mbLerEstado(k))
  };
  final txs = await mbUltimasTransacoes();
  final modelo = montarModeloInicio(
    geral: await mbLerCicloGeral(agora),
    ciclo: ((mapa['ciclo'] as Map?) ?? const {}).cast<String, dynamic>(),
    contas: mbSemPoupancas([
      for (final c in (mapa['contas'] as List? ?? const []))
        (c as Map).cast<String, dynamic>()
    ]),
    faturas: ((mapa['faturas'] as Map?) ?? const {}).cast<String, dynamic>(),
    sincronizadoEm: await mbLerEstado('sincronizado_em'),
    nome: nome,
    agora: agora,
  );
  return (modelo: modelo, transacoes: txs);
}

/// Fatura aberta de um cartão de crédito. `destaque`: vence em até 3 dias (ou já passou) e há valor a pagar.
typedef FaturaAberta = ({String nome, double valor, DateTime? vence, int? dias, bool destaque});

List<FaturaAberta> mbFaturasAbertas({
  required List<Map<String, dynamic>> contas,
  required Map<String, dynamic> faturas,
  required DateTime agora,
}) {
  final out = <FaturaAberta>[];
  for (final c in contas.where((c) => c['type'] == 'CREDIT')) {
    final fat = faturas['${c['id']}'];
    final aberta = fat is Map ? fat['open_bill'] : null;
    final valor = aberta is Map && aberta['total_amount'] is num
        ? _num(aberta['total_amount'])
        : _num(c['balance']);
    final vence = aberta is Map && _lerData('${aberta['due_date']}') != null
        ? _lerData('${aberta['due_date']}')
        : _proximoDia(c['due_date'], agora);
    final dias = vence == null ? null : _soDia(vence).difference(_soDia(agora)).inDays;
    final bruto = '${c['name']}';
    final m = RegExp(r'\s*·(\d{4})$').firstMatch(bruto);
    out.add((
      nome: m == null ? bruto : bruto.substring(0, m.start),
      valor: valor,
      vence: vence,
      dias: dias,
      destaque: valor > 0 && dias != null && dias <= 3,
    ));
  }
  return out;
}

/// Patrimônio = contas correntes + poupanças + investimentos − fatura atual do cartão.
/// Empréstimos e carteiras manuais ficam de fora.
typedef Patrimonio = ({
  double correntes,
  double poupancas,
  double investimentos,
  double fatura,
  double total
});

Patrimonio mbPatrimonio(
        {required double correntes,
        double poupancas = 0,
        required double investimentos,
        required double fatura}) =>
    (
      correntes: correntes,
      poupancas: poupancas,
      investimentos: investimentos,
      fatura: fatura.abs(),
      total: correntes + poupancas + investimentos - fatura.abs()
    );

/// Carteira manual (fora do Meu Banco): saldo = soma dos lançamentos dela, fora do patrimônio.
typedef CarteiraInicio = ({String nome, double saldo});
typedef PatrimonioInicio = ({
  Patrimonio patrimonio,
  List<FaturaAberta> faturas,
  List<CarteiraInicio> carteiras,
  List<BancoInicio> bancos,
  bool semDados
});

/// Dados dos cartões "Fatura do cartão" e "Patrimônio" da Início, lidos do que está no aparelho.
Future<PatrimonioInicio> mbCarregarPatrimonioInicio(DateTime agora) async {
  final contas = _contasSalvas(await mbLerEstado('contas'));
  final faturas = ((_decodificar(await mbLerEstado('faturas')) as Map?) ?? const {})
      .cast<String, dynamic>();
  final abertas = mbFaturasAbertas(contas: contas, faturas: faturas, agora: agora);
  double saldoBancario(bool poupanca) => contas
      .where((c) =>
          c['type'] == 'BANK' && (c['subtype'] == 'SAVINGS_ACCOUNT') == poupanca)
      .fold<double>(0, (s, c) => s + _num(c['balance']));
  // Investimentos (soma dos ajustes de saldo da carteira) entra no patrimônio. As carteiras do
  // Meu Banco (mb:) já estão nas linhas de contas e fatura; as manuais aparecem à parte, fora do total.
  final linhas = await database.customSelect(
      'SELECT w.wallet_pk AS pk, w.name AS nome, COALESCE(SUM(t.amount), 0) AS saldo '
      'FROM wallets w LEFT JOIN transactions t ON t.wallet_fk = w.wallet_pk '
      'GROUP BY w.wallet_pk, w.name ORDER BY w."order"').get();
  var investimentos = 0.0;
  final arquivadas = carteirasArquivadas();
  final carteiras = <CarteiraInicio>[];
  for (final l in linhas) {
    final pk = l.read<String>('pk');
    final saldo = l.read<double>('saldo');
    if (pk == mbCarteiraInvestimentos) {
      investimentos = saldo;
    } else if (!pk.startsWith(mbPrefixo) && saldo != 0 && !arquivadas.contains(pk)) {
      carteiras.add((nome: l.read<String>('nome'), saldo: saldo));
    }
  }
  return (
    patrimonio: mbPatrimonio(
        correntes: saldoBancario(false),
        poupancas: saldoBancario(true),
        investimentos: investimentos,
        fatura: abertas.fold<double>(0, (s, f) => s + f.valor)),
    faturas: abertas,
    carteiras: carteiras,
    bancos: mbAgruparPorBanco(
        contas: contas,
        faturas: faturas,
        investimentos: await _investimentosSalvos(),
        sincronizadoEm: await mbLerEstado('sincronizado_em'),
        agora: agora),
    semDados: contas.isEmpty
  );
}

Future<List<InvestimentoBanco>> _investimentosSalvos() async {
  final txs = await (database.select(database.transactions)
        ..where((t) =>
            t.walletFk.equals(mbCarteiraInvestimentos) &
            t.transactionPk.like('mb:inv:%'))
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .get();
  return [
    for (final t in txs)
      (nome: t.name, banco: t.note.isEmpty ? null : t.note, saldo: t.amount)
  ];
}

/// Aplicação da carteira Investimentos: `banco` vem do Worker (campo `banco`, gravado em `note`).
typedef InvestimentoBanco = ({String nome, String? banco, double saldo});

/// Linha de um banco na Início. `valor` da fatura é negativo (sai do total do banco).
typedef ItemBanco = ({String rotulo, double valor, bool fatura, bool destaque, String carteiras});

/// Um banco com tudo dele: contas, aplicações e fatura. `logo` é o arquivo em `assets/bancos`
/// (null: selo com iniciais na cor `cor`). `id` 'outros' agrupa o que não tem banco identificável.
typedef BancoInicio = ({
  String id,
  String nome,
  String? logo,
  int? cor,
  String subtitulo,
  double total,
  List<ItemBanco> itens
});

class _GrupoBanco {
  _GrupoBanco(this.id, this.nome, this.logo, this.cor);
  final String id, nome;
  final String? logo;
  final int? cor;
  final contas = <ItemBanco>[];
  final aplicacoes = <ItemBanco>[];
  final faturas = <({FaturaAberta f, String carteira})>[];
  bool sincronizado = false;
}

String _dd(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

/// Agrupa por banco as contas (corrente e poupança), as aplicações e as faturas abertas.
/// O banco vem do campo `bank` da conta (ou do nome dela, no cartão) e do `banco` da aplicação;
/// quem não tem nenhum vai para "Outros". Não calcula saldo novo: só reparte os mesmos valores.
/// Ordem: maior total primeiro, "Outros" por último.
List<BancoInicio> mbAgruparPorBanco({
  required List<Map<String, dynamic>> contas,
  required Map<String, dynamic> faturas,
  required List<InvestimentoBanco> investimentos,
  required String? sincronizadoEm,
  required DateTime agora,
}) {
  contas = mbHerdarBanco(contas);
  final grupos = <String, _GrupoBanco>{};
  _GrupoBanco grupo(Object? bruto) {
    final texto = bruto == null ? '' : '$bruto'.trim();
    final conhecido = mbBancoConhecido(texto);
    final limpo = texto.isEmpty ? '' : mbNomeDoBancoLimpo(texto);
    final id = conhecido?.id ?? (limpo.isEmpty ? 'outros' : mbNormalizarBanco(limpo));
    return grupos.putIfAbsent(
        id,
        () => _GrupoBanco(id, conhecido?.nome ?? (limpo.isEmpty ? 'Outros' : limpo),
            conhecido?.logo, conhecido?.cor));
  }

  for (final c in contas.where((c) => c['type'] == 'BANK')) {
    final g = grupo(c['bank'] ?? c['name'])..sincronizado = true;
    g.contas.add((
      rotulo: c['subtype'] == 'SAVINGS_ACCOUNT' ? 'Poupança' : 'Conta corrente',
      valor: _num(c['balance']),
      fatura: false,
      destaque: false,
      carteiras: mbPkConta('${c['id']}')
    ));
  }

  final cartoes = contas.where((c) => c['type'] == 'CREDIT').toList();
  final abertas = mbFaturasAbertas(contas: contas, faturas: faturas, agora: agora);
  for (var i = 0; i < cartoes.length; i++) {
    if (abertas[i].valor.abs() < 0.005) continue;
    grupo(cartoes[i]['bank'] ?? cartoes[i]['name'])
      ..sincronizado = true
      ..faturas.add((f: abertas[i], carteira: mbPkConta('${cartoes[i]['id']}')));
  }

  // "CDB - BANCO INTER" no banco Inter vira "CDB"; aplicações de mesmo nome somam numa linha.
  final somadas = <String, ({String nome, double saldo, int n})>{};
  for (final inv in investimentos) {
    final g = grupo(inv.banco);
    var nome = inv.nome.trim();
    final m = RegExp(r'^(.*?)\s+[-–]\s+([^-–]+)$').firstMatch(nome);
    if (m != null && inv.banco != null) {
      final a = mbBancoConhecido(m.group(2)), b = mbBancoConhecido(inv.banco);
      if (mbNormalizarBanco(m.group(2)!) == mbNormalizarBanco(inv.banco!) ||
          (a != null && a.id == b?.id)) {
        nome = m.group(1)!.trim();
      }
    }
    final chave = '${g.id}\u0000$nome';
    final ant = somadas[chave];
    somadas[chave] = (nome: nome, saldo: (ant?.saldo ?? 0) + inv.saldo, n: (ant?.n ?? 0) + 1);
    if (ant == null) g.aplicacoes.add((
      rotulo: chave, // trocado abaixo pelo rótulo final
      valor: 0,
      fatura: false,
      destaque: false,
      carteiras: mbCarteiraInvestimentos
    ));
  }
  for (final g in grupos.values) {
    for (var i = 0; i < g.aplicacoes.length; i++) {
      final s = somadas[g.aplicacoes[i].rotulo]!;
      g.aplicacoes[i] = (
        rotulo: s.n > 1 ? '${s.nome} · ${s.n} aplicações' : s.nome,
        valor: s.saldo,
        fatura: false,
        destaque: false,
        carteiras: mbCarteiraInvestimentos
      );
    }
  }

  final quando = _lerData(sincronizadoEm);
  final out = <BancoInicio>[];
  for (final g in grupos.values) {
    final itens = [
      ...g.contas,
      ...g.aplicacoes,
      for (final x in g.faturas)
        (
          rotulo: 'Fatura${g.faturas.length > 1 ? ' ${x.f.nome}' : ''}'
              '${x.f.vence == null ? '' : ' · vence ${_dd(x.f.vence!)}'}',
          valor: -x.f.valor.abs(),
          fatura: true,
          destaque: x.f.destaque,
          carteiras: x.carteira
        ),
    ];
    if (itens.isEmpty) continue;
    out.add((
      id: g.id,
      nome: g.nome,
      logo: g.logo,
      cor: g.cor,
      subtitulo: g.id == 'outros'
          ? 'sem banco identificado'
          : g.sincronizado
              ? (quando == null ? 'conectado' : 'sincronizado ${haQuanto(quando, agora)}')
              : 'só investimentos',
      total: itens.fold<double>(0, (s, i) => s + i.valor),
      itens: itens
    ));
  }
  out.sort((a, b) => a.id == 'outros'
      ? 1
      : b.id == 'outros'
          ? -1
          : b.total.compareTo(a.total));
  return out;
}

// Junta gatilhos de recarga em rajada (uma sync dispara o listener da sync e vários eventos
// do stream de transações): no máximo uma recarga em andamento e uma repetição pendente.
class RecargaColapsada {
  RecargaColapsada(this._carregar);
  final Future<void> Function() _carregar;
  bool _rodando = false, _repetir = false, _fechada = false;

  Future<void> pedir() async {
    if (_fechada) return;
    if (_rodando) {
      _repetir = true;
      return;
    }
    _rodando = true;
    try {
      do {
        _repetir = false;
        await _carregar();
      } while (_repetir && !_fechada);
    } finally {
      _rodando = false;
    }
  }

  void fechar() => _fechada = true;
}
