// Casos mais comuns, para resolver com menos toques (funções puras, test/mb_casos_comuns_test.dart): iguais na fila
// Para classificar, rendimentos de poupança, estornos de compra, o que se repete todo mês e os atalhos de lançamento
// rápido da Início. Tudo continua sendo só sugestão: nada é aplicado sem o toque do usuário.
import 'package:budget/struct/mbSync/classificar.dart';
import 'package:budget/struct/mbSync/reembolso.dart' show MbGastoCandidato;
import 'package:budget/struct/mbSync/revisao.dart' show mbNormalizarRevisao;

/// Uma transação já no aparelho (do banco ou manual), com os nomes da categoria e da sub para ler.
typedef MbHistorico = ({
  String pk,
  String nome,
  double valor, // sinal do RenanCash: saída negativa
  DateTime data,
  String categoriaPk,
  String? subPk,
  String categoriaNome,
  String? subNome,
});

int _centavos(double v) => (v.abs() * 100).round();

/// O lançamento e os outros da fila com o mesmo favorecido normalizado e o mesmo sinal (8 "Uber"), ele primeiro.
List<MbLancamentoIa> mbIguaisNaFila(List<MbLancamentoIa> fila, MbLancamentoIa l) {
  final chave = mbChavePadrao(l.descricao);
  return [
    l,
    if (chave.isNotEmpty)
      for (final x in fila)
        if (x.pk != l.pk && (x.valor > 0) == (l.valor > 0) && mbChavePadrao(x.descricao) == chave) x
  ];
}

final RegExp _juros = RegExp(r'\b(JUROS|RENDIMENTOS?|REMUNERACAO)\b');

/// Rendimento de poupança: entrada de centavos (menos de R$ 1) com "JUROS" ou "RENDIMENTO" na descrição.
bool mbEhJurosPoupanca(MbLancamentoIa l) =>
    l.valor > 0 && l.valor < 1 && _juros.hasMatch(mbNormalizarRevisao(l.descricao));

/// Rendimentos de poupança da fila que viram um cartão só (2 ou mais); vazio quando há só um.
List<MbLancamentoIa> mbRendimentosJuntos(List<MbLancamentoIa> fila) {
  final juros = [for (final l in fila) if (mbEhJurosPoupanca(l)) l];
  return juros.length > 1 ? juros : const [];
}

/// Estorno de compra no cartão ("Estorno - Compra cartão", "ESTORNO UBER").
bool mbEhEstorno(MbLancamentoIa l) => l.valor > 0 && mbNormalizarRevisao(l.descricao).contains('ESTORN');

const Set<String> _semEstabelecimento = {'ESTORNO', 'ESTORNADA', 'ESTORNADO', 'COMPRA', 'CARTAO', 'CREDITO', 'DEBITO'};

/// A compra que o estorno devolve: mesmo valor inteiro (ainda sem nada abatido), mais palavras do estabelecimento em
/// comum e, no empate, a mais recente. null: nenhuma compra com esse valor.
MbGastoCandidato? mbCompraDoEstorno(Iterable<MbGastoCandidato> gastos, MbLancamentoIa estorno) {
  final alvo = _centavos(estorno.valor);
  final palavras = mbChavePadrao(estorno.descricao).split(' ').toSet().difference(_semEstabelecimento);
  int emComum(MbGastoCandidato g) => mbChavePadrao(g.nome).split(' ').where(palavras.contains).length;
  MbGastoCandidato? melhor;
  for (final g in gastos) {
    if (g.reembolsado > 0 || (g.centavos - alvo).abs() > 1) continue;
    if (melhor == null) {
      melhor = g;
      continue;
    }
    final d = emComum(g) - emComum(melhor);
    if (d > 0 || (d == 0 && g.data.isAfter(melhor.data))) melhor = g;
  }
  return melhor;
}

final RegExp _salario = RegExp(r'\bSALARIO\b');

/// O mesmo lançamento do mês passado (20 a 40 dias antes) numa categoria útil do tipo certo: saída para o mesmo
/// favorecido com o mesmo valor (Pix de R$ 21 todo mês) ou entrada do mesmo favorecido ou da categoria "Salário" com
/// valor parecido (±15%). Sugere a categoria, a sub e, quando o favorecido mudou (salário), o título usados da última
/// vez. null: nada parecido no mês passado.
MbSugestao? mbComoMesPassado(MbLancamentoIa l, Iterable<MbHistorico> historico, MbOpcoes op) {
  final chave = mbChavePadrao(l.descricao);
  final alvo = _centavos(l.valor);
  final dia = DateTime(l.data.year, l.data.month, l.data.day);
  final inicio = DateTime(dia.year, dia.month, dia.day - 40);
  final fim = DateTime(dia.year, dia.month, dia.day - 19); // exclusivo: até 20 dias antes
  MbHistorico? achado;
  var achadoMesmo = false;
  for (final a in historico) {
    if (a.pk == l.pk || a.data.isBefore(inicio) || !a.data.isBefore(fim)) continue;
    final cat = op.categoria(a.categoriaPk);
    if (cat == null || cat.receita != (l.valor > 0) || (a.valor > 0) != (l.valor > 0)) continue;
    final mesmo = chave.isNotEmpty && mbChavePadrao(a.nome) == chave;
    final diferenca = (_centavos(a.valor) - alvo).abs();
    final ok = l.valor < 0
        ? mesmo && diferenca <= 1
        : (mesmo || _salario.hasMatch(mbNormalizarRevisao('${a.categoriaNome} ${a.subNome ?? ''}'))) &&
            diferenca <= alvo * .15;
    if (ok && (achado == null || a.data.isAfter(achado.data))) {
      achado = a;
      achadoMesmo = mesmo;
    }
  }
  final a = achado;
  if (a == null) return null;
  final cat = op.categoria(a.categoriaPk)!;
  return MbSugestao(l.pk, cat.pk,
      subPk: cat.subs.any((s) => s.pk == a.subPk) ? a.subPk : null,
      titulo: achadoMesmo ? null : a.nome.trim(),
      confianca: .9,
      fonte: MbFonteSugestao.mesPassado);
}
