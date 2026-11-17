// Ritmo do ciclo: onde fica a marca de "hoje" na barra do orçamento e quanto
// seria o gasto até hoje se o limite fosse gasto por igual. Funções puras.

/// Dia de [agora] em America/Sao_Paulo. UTC vira UTC−3 (sem horário de verão
/// desde 2019); hora local é a do aparelho, que já está no fuso.
DateTime diaSaoPaulo(DateTime agora) {
  final d = agora.isUtc ? agora.subtract(const Duration(hours: 3)) : agora;
  return DateTime.utc(d.year, d.month, d.day);
}

DateTime _dia(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// Dias decorridos (contando hoje) ÷ dias do ciclo, de 1/n no primeiro dia a 1
/// no último. Nulo com hoje fora do ciclo: sem marca de "hoje".
double? fracaoDoCiclo(DateTime inicio, DateTime fim, DateTime agora) {
  final ini = _dia(inicio), hoje = diaSaoPaulo(agora);
  final total = _dia(fim).difference(ini).inDays + 1;
  final decorridos = hoje.difference(ini).inDays + 1;
  if (total <= 0 || decorridos < 1 || decorridos > total) return null;
  return decorridos / total;
}

/// Quanto se teria gasto até hoje gastando o limite por igual no ciclo.
double idealAteHoje(double limite, double fracao) => limite * fracao;

/// "Ideal até hoje R$ 520 · R$ 149 acima" (ou "abaixo", ou "no ritmo").
String textoIdealHoje(double gasto, double limite, double fracao,
    String Function(double) formatar,
    {bool renda = false}) {
  final ideal = idealAteHoje(limite, fracao);
  final dif = gasto - ideal;
  final rotulo = renda ? 'Meta até hoje' : 'Ideal até hoje';
  final ritmo = dif.abs() < .5
      ? 'no ritmo'
      : '${formatar(dif.abs())} ${dif > 0 ? 'acima' : 'abaixo'}';
  return '$rotulo ${formatar(ideal)} · $ritmo';
}

/// Rótulo de leitor de tela da barra.
String semanticaBarraCiclo(double gasto, double limite, double? fracao,
    {bool renda = false}) {
  String pct(double f) => '${(f * 100).round()}%';
  final base = renda
      ? 'Guardado ${pct(gasto / limite)} da meta'
      : 'Gasto ${pct(gasto / limite)} do limite';
  return fracao == null
      ? base
      : '$base; o ideal até hoje é ${pct(fracao)}';
}
