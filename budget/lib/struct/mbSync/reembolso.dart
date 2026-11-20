import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/classificar.dart' show mbChavePadrao;
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

// Rachar conta: um Pix recebido é a parte de alguém num gasto que eu paguei. O vínculo é a decisão "reembolso" da fila
// Para revisar (`revisoes` tx:<id>, `reembolso_de` = id do gasto sem "mb:"), sincronizada por LWW e ligada também pela
// aba Pendências e pelo editar transação. No pull, o mapeamento põe o reembolso na categoria do gasto como despesa
// positiva (igual a um estorno): ciclo, orçamentos, categoria e Todos os gastos somam a categoria, então o gasto passa a
// contar só a minha parte, e o reembolso sai das receitas. Um gasto pode ter vários reembolsos. Desligar apaga a
// decisão e o pull seguinte desfaz. Reembolso sem gasto escolhido abate em "Outros".
//
// Troco: a pessoa mandou a mais e eu devolvi parte. É a decisão "troco" (`troco_de` = id do Pix recebido ligado como
// reembolso) no Pix enviado a ela até 3 dias depois. Ela abate o reembolso (líquido = reembolso − troco), fica na categoria
// do gasto e não é gasto novo. Reembolsos e trocos ligados ficam só dentro do gasto nas listas (rachadas.dart).

const int mbJanelaReembolsoDias = 30;
const int _maxPartes = 6; // 1/1 a 1/6 do gasto
const int _pontosExato = 40;
const int _pontosRecorrente = 15; // valor parecido ou "como das outras vezes"
const int _pontosTroco = 5; // some aos 5 de "rachar": 10 no total, depois do exato (40) e do parecido (15)

class MbGastoCandidato {
  final String pk, nome, categoria;
  final DateTime data;
  final int centavos; // positivo
  final int reembolsado; // centavos já ligados por outros reembolsos
  const MbGastoCandidato(this.pk, this.nome, this.categoria, this.data, this.centavos, {this.reembolsado = 0});

  double get valor => centavos / 100;
  int get falta => centavos - reembolsado;
}

typedef MbSugestaoReembolso = ({MbGastoCandidato gasto, int pontos, List<String> motivos});

DateTime _soDia(DateTime d) => DateTime(d.year, d.month, d.day);

final RegExp _deRachar = RegExp(
    r'\b(RESTAURANTE|ALIMENTACAO FORA|DELIVERY|IFOOD|RAPPI|FOOD|PIZZA|PIZZARIA|COMIDA|LANCHE|BURGER|HAMBURGUER|ACAI|SORVETE|PADARIA|CAFE|CAFETERIA|SUSHI|CHURRASCO|MERCADO|SUPERMERCADO|VIAGEM|VIAGENS|UBER|BAR|LAZER|HOTEL|AIRBNB|CINEMA)\b');

/// Aviso do gasto de rachar (mesmo dia ou véspera) para o Pix maior que a metade dele.
const String mbMotivoTroco = 'recebeu mais que a sua parte: devolveu o troco?';

/// "o que falta", "mesmo valor", "metade", "1/3"… quando o Pix é exatamente essa parte do gasto (folga do arredondamento).
String? _parte(MbGastoCandidato g, int alvo) {
  if (g.reembolsado > 0 && (g.falta - alvo).abs() <= 1) return 'o que falta';
  for (var k = 1; k <= _maxPartes; k++) {
    if ((alvo * k - g.centavos).abs() <= k) return switch (k) { 1 => 'mesmo valor', 2 => 'metade', _ => '1/$k' };
  }
  return null;
}

bool _parecido(int base, int alvo) => (base - alvo).abs() <= base * 0.1;

/// Gastos de até 30 dias antes do Pix (nunca depois), sem os já cobertos por outros reembolsos, do mais provável ao
/// menos: Pix = 1/2, 1/3… do gasto ou o que falta dele (exato vale mais que parecido), categoria em que esse pagador já
/// rachou, categoria típica de rachar (restaurante, delivery, mercado, viagem, Uber). Pix maior que o que falta desce.
/// Empate: o mais recente.
List<MbSugestaoReembolso> mbSugerirReembolso(Iterable<MbGastoCandidato> gastos,
    {required double valor, required DateTime data, Set<String> categoriasDoPagador = const {}}) {
  final alvo = (valor.abs() * 100).round();
  final fim = _soDia(data);
  final inicio = DateTime(fim.year, fim.month, fim.day - mbJanelaReembolsoDias);
  final saida = <MbSugestaoReembolso>[];
  for (final g in gastos) {
    final dia = _soDia(g.data);
    if (dia.isBefore(inicio) || dia.isAfter(fim) || g.falta <= 0) continue;
    var pontos = 0;
    final motivos = <String>[];
    var casou = true;
    if (_parte(g, alvo) case final parte?) {
      pontos += _pontosExato;
      motivos.add(parte);
    } else if (_parecido(g.falta, alvo) || _parecido(g.centavos, alvo * 2)) {
      pontos += 15;
      motivos.add('valor parecido');
    } else {
      casou = false;
    }
    if (alvo > g.falta + 1) {
      pontos -= 10;
      motivos.add(g.reembolsado > 0 ? 'maior que o que falta' : 'maior que o gasto');
    }
    if (categoriasDoPagador.contains(g.categoria)) {
      pontos += 15;
      motivos.add('como das outras vezes');
    }
    final deRachar = _deRachar.hasMatch(mbNormalizarRevisao('${g.categoria} ${g.nome}'));
    if (deRachar) pontos += 5;
    // Pix de mais da metade (e não mais que o gasto) sem casar com uma fração: pode ter vindo a mais, com troco depois.
    // Só gasto de rachar do mesmo dia ou da véspera, depois das sugestões exatas (abaixo do "parecido").
    if (deRachar &&
        !casou &&
        !dia.isBefore(DateTime(fim.year, fim.month, fim.day - 1)) &&
        alvo * 2 > g.falta &&
        alvo <= g.falta) {
      pontos += _pontosTroco;
      motivos.add(mbMotivoTroco);
    }
    saida.add((gasto: g, pontos: pontos, motivos: motivos));
  }
  saida.sort((a, b) {
    final c = b.pontos.compareTo(a.pontos);
    if (c != 0) return c;
    final d = b.gasto.data.compareTo(a.gasto.data);
    return d != 0 ? d : a.gasto.pk.compareTo(b.gasto.pk);
  });
  return saida;
}

/// O gasto em destaque no cartão: o primeiro do ranking, sem empate, quando o Pix é exatamente uma parte dele. Se o
/// pagador já mandou a parte de 2 contas ou mais (`recorrente`), basta valor parecido ou a categoria em que ele racha.
MbSugestaoReembolso? mbReembolsoForte(List<MbSugestaoReembolso> s, {bool recorrente = false}) =>
    s.isNotEmpty &&
            s.first.pontos >= (recorrente ? _pontosRecorrente : _pontosExato) &&
            (s.length == 1 || s[1].pontos < s.first.pontos)
        ? s.first
        : null;

/// Quantas vezes o pagador (favorecido normalizado) já mandou a parte de uma conta.
int mbVezesQueRachou(Iterable<MbVinculoReembolso> vinculos, String pagador) =>
    pagador.isEmpty ? 0 : vinculos.where((v) => v.pagador == pagador).length;

/// Minha parte de um gasto (centavos, positivo) depois dos reembolsos ligados e dos trocos que devolvi (cada troco abate o
/// reembolso, nunca além dele). Nunca abaixo de zero: `excesso` > 0 quando os reembolsos líquidos passam do gasto.
({int parte, int excesso}) mbMinhaParte(int gasto, Iterable<int> reembolsos, [Iterable<int> trocos = const []]) {
  final recebido = reembolsos.fold<int>(0, (s, r) => s + r);
  final devolvido = trocos.fold<int>(0, (s, r) => s + r);
  final resto = gasto - (recebido - (devolvido > recebido ? recebido : devolvido));
  return resto < 0 ? (parte: 0, excesso: -resto) : (parte: resto, excesso: 0);
}

/// Nome inteiro da pessoa de um Pix, sem o prefixo do banco nem "devolvido": "Pix recebido - Valentina De Paula Macedo" e
/// "Pix enviado devolvido - Valentina De Paula Macedo" dão o mesmo nome (a chave de 4 palavras não casa os dois).
String mbNomeDaPessoa(String descricao) => mbNormalizarRevisao(descricao)
    .replaceFirst(RegExp(r'^PIX (ENVIAD[OA]|ENVIO|RECEBID[OA]|RECEBIMENTO)\b ?'), '')
    .replaceFirst(RegExp(r'^DEVOLVID[OA]\b ?'), '')
    .trim();

/// Reembolso ligado a um gasto (pks com "mb:"). `pagador`: favorecido normalizado da descrição do Pix; `nome`: o nome
/// inteiro (casa o troco); `data`: dia do Pix recebido.
class MbVinculoReembolso {
  final String reembolsoPk, gastoPk, pagador, nome;
  final int centavos;
  final DateTime? data;
  const MbVinculoReembolso(this.reembolsoPk, this.gastoPk, this.pagador, this.centavos, {this.data, this.nome = ''});
}

/// Troco ligado a um reembolso: Pix enviado à mesma pessoa que abate o reembolso.
class MbTroco {
  final String trocoPk, reembolsoPk;
  final int centavos;
  final DateTime? data;
  const MbTroco(this.trocoPk, this.reembolsoPk, this.centavos, {this.data});
}

List<MbVinculoReembolso> mbVinculosReembolso(Iterable<Map<String, dynamic>> decisoes) => [
      for (final d in decisoes)
        if (d['resposta'] == 'reembolso' && d['reembolso_de'] is String && d['tx_id'] is String)
          MbVinculoReembolso(mbPkTransacao(d['tx_id'] as String), mbPkTransacao(d['reembolso_de'] as String),
              mbChavePadrao('${d['descricao'] ?? ''}'), (((d['valor'] as num?) ?? 0).abs() * 100).round(),
              data: DateTime.tryParse('${d['data'] ?? ''}'), nome: mbNomeDaPessoa('${d['descricao'] ?? ''}'))
    ];

/// Trocos das decisões: só valem os de um reembolso ainda ligado, e juntos nunca passam do reembolso (o que passa fica
/// como um Pix enviado qualquer). Do mais antigo ao mais novo.
List<MbTroco> mbTrocosLigados(Iterable<Map<String, dynamic>> decisoes, Iterable<MbVinculoReembolso> vinculos) {
  final reembolsos = {for (final v in vinculos) v.reembolsoPk: v.centavos};
  final candidatos = [
    for (final d in decisoes)
      if (d['resposta'] == 'troco' && d['troco_de'] is String && d['tx_id'] is String)
        MbTroco(mbPkTransacao(d['tx_id'] as String), mbPkTransacao(d['troco_de'] as String),
            (((d['valor'] as num?) ?? 0).abs() * 100).round(),
            data: DateTime.tryParse('${d['data'] ?? ''}'))
  ]..sort((a, b) {
      final c = (a.data ?? DateTime(0)).compareTo(b.data ?? DateTime(0));
      return c != 0 ? c : a.trocoPk.compareTo(b.trocoPk);
    });
  final devolvido = <String, int>{};
  final validos = <MbTroco>[];
  for (final t in candidatos) {
    final jaDevolvido = devolvido[t.reembolsoPk] ?? 0;
    final total = reembolsos[t.reembolsoPk];
    if (t.centavos <= 0 || total == null || jaDevolvido + t.centavos > total) continue;
    devolvido[t.reembolsoPk] = jaDevolvido + t.centavos;
    validos.add(t);
  }
  return validos;
}

const int mbJanelaTrocoDias = 3;
final RegExp _pixEnviadoTroco = RegExp(r'^PIX (ENVIAD[OA]|ENVIO)\b');

/// "Devolvi parte do reembolso de <pessoa>": Pix enviado à mesma pessoa (nome inteiro igual) de 0 a 3 dias depois de um
/// Pix recebido dela ligado como reembolso, com valor que cabe no que sobra desse reembolso. Vários: o reembolso mais
/// recente. Nada é ligado sem o toque.
MbVinculoReembolso? mbSugerirTroco(Iterable<MbVinculoReembolso> vinculos, Iterable<MbTroco> trocos,
    {required String descricao, required double valor, required DateTime data}) {
  if (!_pixEnviadoTroco.hasMatch(mbNormalizarRevisao(descricao))) return null;
  final nome = mbNomeDaPessoa(descricao);
  final centavos = (valor.abs() * 100).round();
  if (nome.isEmpty || centavos <= 0) return null;
  final dia = DateTime.utc(data.year, data.month, data.day);
  MbVinculoReembolso? melhor;
  for (final v in vinculos) {
    final recebido = v.data;
    if (recebido == null || v.nome != nome) continue;
    final dias = dia.difference(DateTime.utc(recebido.year, recebido.month, recebido.day)).inDays;
    if (dias < 0 || dias > mbJanelaTrocoDias) continue;
    final sobra = v.centavos - trocos.where((t) => t.reembolsoPk == v.reembolsoPk).fold<int>(0, (s, t) => s + t.centavos);
    if (centavos > sobra) continue;
    if (melhor == null ||
        recebido.isAfter(melhor.data!) ||
        (recebido == melhor.data && v.reembolsoPk.compareTo(melhor.reembolsoPk) < 0)) {
      melhor = v;
    }
  }
  return melhor;
}

/// Vínculos das decisões sincronizadas (lidos em mbAtualizarRevisar). Também é o aprendizado: quem já mandou a parte
/// de uma conta, e em que categorias, sobe nas próximas sugestões.
final ValueNotifier<List<MbVinculoReembolso>> meuBancoReembolsos = ValueNotifier(const []);

/// Trocos das decisões sincronizadas (lidos em mbAtualizarRevisar).
final ValueNotifier<List<MbTroco>> meuBancoTrocos = ValueNotifier(const []);

/// Item da fila para uma entrada qualquer (`mb:<id>`): ligar fora da fila do Worker grava a mesma decisão.
MbItemRevisao mbItemDeEntrada(String pk, double valor, DateTime data, String descricao,
        {String tipo = 'pix_recebido'}) =>
    MbItemRevisao(
    'tx:${pk.substring(mbPrefixo.length)}', tipo,
    txId: pk.substring(mbPrefixo.length),
    data: _soDia(data).toIso8601String().substring(0, 10),
    descricao: descricao,
    valor: valor.abs());

/// Candidatos para uma entrada, lidos do aparelho: gastos `mb:` da janela, com o que já foi reembolsado de cada um e as
/// categorias em que o mesmo pagador já rachou. Variável para os testes de tela trocarem (sem banco).
Future<List<MbSugestaoReembolso>> Function(String pk, double valor, DateTime data, String descricao)
    mbBuscarCandidatosReembolso = _candidatosDoBanco;

Future<List<MbSugestaoReembolso>> _candidatosDoBanco(String pk, double valor, DateTime data, String descricao) async {
  final inicio = DateTime(data.year, data.month, data.day - mbJanelaReembolsoDias);
  final fim = DateTime(data.year, data.month, data.day + 1);
  final vinculos = [
    for (final v in meuBancoReembolsos.value)
      if (v.reembolsoPk != pk) v
  ];
  final pagador = mbChavePadrao(descricao);
  final doPagador = {
    for (final v in vinculos)
      if (pagador.isNotEmpty && v.pagador == pagador) v.gastoPk
  };
  final linhas = await (database.select(database.transactions)
        ..where((t) =>
            (t.transactionPk.like('$mbPrefixo%') &
                t.transactionPk.like('${mbPrefixo}inv:%').not() &
                t.income.equals(false) &
                t.amount.isSmallerThanValue(0) &
                t.dateCreated.isBiggerOrEqualValue(inicio) &
                t.dateCreated.isSmallerThanValue(fim)) |
            t.transactionPk.isIn(doPagador)))
      .get();
  final categorias = {for (final c in await database.select(database.categories).get()) c.categoryPk: c.name};
  final reembolsado = <String, int>{};
  for (final v in vinculos) {
    reembolsado.update(v.gastoPk, (s) => s + v.centavos, ifAbsent: () => v.centavos);
  }
  final gastos = [
    for (final t in linhas)
      MbGastoCandidato(t.transactionPk, t.name, categorias[t.categoryFk] ?? '', t.dateCreated,
          (t.amount.abs() * 100).round(),
          reembolsado: reembolsado[t.transactionPk] ?? 0)
  ];
  return mbSugerirReembolso(gastos, valor: valor, data: data, categoriasDoPagador: {
    for (final g in gastos)
      if (doPagador.contains(g.pk) && g.categoria.isNotEmpty) g.categoria
  });
}

/// Sugestões para um item "Pix recebido" da fila Para revisar.
Future<List<MbSugestaoReembolso>> mbSugestoesDoItem(MbItemRevisao item) async {
  final data = DateTime.tryParse(item.data ?? '');
  if (data == null || item.txId == null) return const [];
  return mbBuscarCandidatosReembolso('$mbPrefixo${item.txId}', item.valor, data, item.descricao ?? '');
}
