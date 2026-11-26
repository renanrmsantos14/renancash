import 'package:budget/struct/mbSync/revisao.dart' show mbNormalizarRevisao;
import 'package:flutter/foundation.dart';

// Empréstimos a receber, derivados das decisões da fila "Para revisar" (tabela `revisoes`, sincronizada entre aparelhos):
//   resposta "emprestimo" (Pix enviado ou envio do Inter ao Santander) abre um empréstimo com o valor da transação e a `pessoa`;
//     com `emprestimo_id` ela soma o valor a um empréstimo que já existe (o id é o da transação que o abriu);
//   resposta "devolucao" (Pix recebido) abate o empréstimo escolhido (`emprestimo_id`); sem ele, é uma devolução antiga
//     e abate o mais antigo em aberto (FIFO). `sobra` é a parte do Pix que passou do saldo: com `sobra_para: "emprestimo"` e
//     `sobra_id` ela abate outro empréstimo (reembolso e renda não mexem em empréstimo);
//   registro `perdao:<empréstimo>` ({ valor, data }): o saldo restante é perdoado (vira gasto em `data`, ver meuBancoMapping) e sai do aberto.
// Não há tabela própria nem transação no RenanCash: o empréstimo nem entra como gasto (Geral e orçamentos). Reaproveitar os "objetivos
// de empréstimo" do Cashew criaria transações vinculadas por empréstimo, que mexem em gastos, orçamentos e saldos das carteiras.
//
// Os eventos são processados em ordem cronológica (no mesmo dia: empréstimo, devolução, perdão). Pagamento maior que o saldo do
// empréstimo escolhido é limitado ao saldo (a sobra legítima já vem em `sobra`). Devolução anterior a qualquer empréstimo conhecido
// sem vínculo não abate nada; com vínculo a um empréstimo que não existe mais (decisão desfeita), também não.

class MbPagamento {
  final String txId;
  final String? data; // yyyy-MM-dd
  final int centavos;
  const MbPagamento(this.txId, this.data, this.centavos);
}

class MbEmprestimo {
  final String txId; // id do empréstimo: o da transação que o abriu
  final String? data; // yyyy-MM-dd
  final int originalCentavos, restanteCentavos;
  final String? pessoa;
  final int perdoadoCentavos;
  final String? perdoadoEm;
  final List<MbPagamento> pagamentos;
  const MbEmprestimo(this.txId, this.data, this.originalCentavos, this.restanteCentavos,
      {this.pessoa, this.perdoadoCentavos = 0, this.perdoadoEm, this.pagamentos = const []});

  double get original => originalCentavos / 100;
  double get restante => restanteCentavos / 100;
  int get pagoCentavos => originalCentavos - restanteCentavos - perdoadoCentavos;
  double get perdoado => perdoadoCentavos / 100;
  bool get parcial => restanteCentavos < originalCentavos;
  bool get aberto => restanteCentavos > 0 && perdoadoEm == null;
}

/// Empréstimos de uma pessoa (nome normalizado igual para "Isabel", "isabel " e "ISABEL").
class MbEmprestimosDaPessoa {
  final String chave, nome;
  final List<MbEmprestimo> abertos, quitados;
  const MbEmprestimosDaPessoa(this.chave, this.nome, this.abertos, this.quitados);

  int get originalCentavos => abertos.fold(0, (s, e) => s + e.originalCentavos);
  int get restanteCentavos => abertos.fold(0, (s, e) => s + e.restanteCentavos);
  int get pagoCentavos => abertos.fold(0, (s, e) => s + e.pagoCentavos);
}

String mbChavePessoa(String? pessoa) => mbNormalizarRevisao(pessoa ?? '');

class MbEmprestimos {
  final List<MbEmprestimo> abertos; // do mais antigo para o mais novo
  final List<MbEmprestimo> quitados; // pagos por completo ou perdoados, do mais recente para o mais antigo
  const MbEmprestimos([this.abertos = const [], this.quitados = const []]);

  double get devido => abertos.fold<int>(0, (s, e) => s + e.restanteCentavos) / 100;

  MbEmprestimo? porId(String id) {
    for (final e in [...abertos, ...quitados]) {
      if (e.txId == id) return e;
    }
    return null;
  }

  /// Em aberto e quitados agrupados por pessoa (ordem alfabética; sem pessoa por último).
  List<MbEmprestimosDaPessoa> get porPessoa {
    final nomes = <String, String>{};
    final abertosPor = <String, List<MbEmprestimo>>{};
    final quitadosPor = <String, List<MbEmprestimo>>{};
    for (final (lista, destino) in [(abertos, abertosPor), (quitados, quitadosPor)]) {
      for (final e in lista) {
        final chave = mbChavePessoa(e.pessoa);
        nomes.putIfAbsent(chave, () => (e.pessoa ?? '').trim());
        (destino[chave] ??= []).add(e);
      }
    }
    final chaves = nomes.keys.toList()
      ..sort((a, b) => a.isEmpty != b.isEmpty ? (a.isEmpty ? 1 : -1) : a.compareTo(b));
    return [
      for (final c in chaves)
        MbEmprestimosDaPessoa(c, nomes[c]!.isEmpty ? 'Sem pessoa' : nomes[c]!, abertosPor[c] ?? const [],
            quitadosPor[c] ?? const [])
    ];
  }

  /// Em aberto para receber um pagamento de [pessoa] (nome do pagador): os dela primeiro, depois os outros.
  ({List<MbEmprestimo> daPessoa, List<MbEmprestimo> outros}) paraPagamento(String? pessoa) {
    final chave = mbChavePessoa(pessoa);
    final dela = chave.isEmpty ? <MbEmprestimo>[] : [for (final e in abertos) if (mbChavePessoa(e.pessoa) == chave) e];
    return (daPessoa: dela, outros: [for (final e in abertos) if (!dela.contains(e)) e]);
  }

  String _assinatura(MbEmprestimo e) =>
      '${e.txId}|${e.pessoa}|${e.originalCentavos}|${e.restanteCentavos}|${e.perdoadoCentavos}|${e.pagamentos.length}';

  @override
  bool operator ==(Object o) =>
      o is MbEmprestimos &&
      listEquals([for (final e in abertos) _assinatura(e)], [for (final e in o.abertos) _assinatura(e)]) &&
      listEquals([for (final e in quitados) _assinatura(e)], [for (final e in o.quitados) _assinatura(e)]);

  @override
  int get hashCode => Object.hashAll([for (final e in [...abertos, ...quitados]) _assinatura(e)]);
}

String? _dia(Object? data) {
  final m = RegExp(r'^\d{4}-\d{2}-\d{2}').firstMatch('${data ?? ''}');
  return m?.group(0);
}

int _centavos(Object? v) => v is num ? (v.abs() * 100).round() : 0;

String? _texto(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

class _Grupo {
  final String id;
  String? data, pessoa, perdoadoEm;
  int original = 0, restante = 0, perdoado = 0;
  final List<MbPagamento> pagamentos = [];
  _Grupo(this.id, this.data, this.pessoa);
}

/// `decisoes`: as decisões `tx:` (resposta "emprestimo" e "devolucao"); `perdoes`: os registros `perdao:` ({ emprestimo_id, valor, data }).
MbEmprestimos mbCalcularEmprestimos(Iterable<Map<String, dynamic>> decisoes,
    {Iterable<Map<String, dynamic>> perdoes = const []}) {
  // tipo: 0 empréstimo, 1 devolução, 2 perdão (no mesmo dia, nessa ordem)
  final eventos = <({String dia, int tipo, String chave, Map<String, dynamic> d})>[];
  for (final d in decisoes) {
    final resposta = d['resposta'];
    final dia = _dia(d['data']);
    if ((resposta != 'emprestimo' && resposta != 'devolucao') || _centavos(d['valor']) == 0 || dia == null) continue;
    eventos.add((dia: dia, tipo: resposta == 'emprestimo' ? 0 : 1, chave: '${d['tx_id']}', d: d));
  }
  for (final p in perdoes) {
    final dia = _dia(p['data']);
    if (p['emprestimo_id'] is! String || _centavos(p['valor']) == 0 || dia == null) continue;
    eventos.add((dia: dia, tipo: 2, chave: p['emprestimo_id'] as String, d: p));
  }
  eventos.sort((a, b) {
    final c = a.dia.compareTo(b.dia);
    if (c != 0) return c;
    if (a.tipo != b.tipo) return a.tipo.compareTo(b.tipo);
    return a.chave.compareTo(b.chave);
  });
  final grupos = <String, _Grupo>{};
  void abater(_Grupo g, int centavos, String txId, String dia) {
    final abate = centavos < g.restante ? centavos : g.restante;
    if (abate <= 0) return;
    g.restante -= abate;
    g.pagamentos.add(MbPagamento(txId, dia, abate));
  }

  for (final e in eventos) {
    final d = e.d;
    switch (e.tipo) {
      case 0:
        final id = _texto(d['emprestimo_id']) ?? e.chave;
        final g = grupos.putIfAbsent(id, () => _Grupo(id, e.dia, null));
        final c = _centavos(d['valor']);
        g.original += c;
        g.restante += c;
        g.pessoa ??= _texto(d['pessoa']);
        if (g.data == null || e.dia.compareTo(g.data!) < 0) g.data = e.dia;
      case 1:
        final total = _centavos(d['valor']);
        var sobra = _centavos(d['sobra']);
        if (sobra > total) sobra = total;
        final pagamento = total - sobra;
        final alvo = _texto(d['emprestimo_id']);
        if (alvo != null) {
          final g = grupos[alvo];
          if (g != null && g.perdoadoEm == null) abater(g, pagamento, e.chave, e.dia);
        } else {
          var falta = pagamento;
          for (final g in grupos.values.where((g) => g.restante > 0 && g.perdoadoEm == null).toList()
            ..sort((a, b) => '${a.data}${a.id}'.compareTo('${b.data}${b.id}'))) {
            if (falta <= 0) break;
            final antes = g.restante;
            abater(g, falta, e.chave, e.dia);
            falta -= antes - g.restante;
          }
        }
        final destinoSobra = _texto(d['sobra_id']);
        if (sobra > 0 && d['sobra_para'] == 'emprestimo' && destinoSobra != null) {
          final g = grupos[destinoSobra];
          if (g != null && g.perdoadoEm == null) abater(g, sobra, e.chave, e.dia);
        }
      case 2:
        final g = grupos[e.chave];
        if (g == null || g.perdoadoEm != null || g.restante == 0) break;
        g.perdoado = g.restante;
        g.restante = 0;
        g.perdoadoEm = e.dia;
    }
  }
  MbEmprestimo fecha(_Grupo g) => MbEmprestimo(g.id, g.data, g.original, g.restante,
      pessoa: g.pessoa, perdoadoCentavos: g.perdoado, perdoadoEm: g.perdoadoEm, pagamentos: List.unmodifiable(g.pagamentos));
  final todos = [for (final g in grupos.values) fecha(g)];
  int antigo(MbEmprestimo a, MbEmprestimo b) => '${a.data}${a.txId}'.compareTo('${b.data}${b.txId}');
  return MbEmprestimos(
    [for (final e in todos) if (e.aberto) e]..sort(antigo),
    [for (final e in todos) if (!e.aberto) e]..sort((a, b) => antigo(b, a)),
  );
}

/// Empréstimos em aberto como a Início e a aba Empréstimos os mostram, lidos das decisões do aparelho.
final ValueNotifier<MbEmprestimos> meuBancoEmprestimos = ValueNotifier(const MbEmprestimos());

/// Pessoa lembrada por destinatário, já reduzida das decisões do aparelho; atualizada junto com [meuBancoEmprestimos].
final ValueNotifier<Map<String, String>> meuBancoPessoasLembradas = ValueNotifier(const {});

/// Destinatário → a pessoa do empréstimo mais recente (por `data`) feito para ele; sem empréstimo ou sem pessoa, não entra.
Map<String, String> mbPessoaLembrada(Iterable<Map<String, dynamic>> decisoes) {
  final melhores = <String, Map<String, dynamic>>{};
  String chave(Map<String, dynamic> d) => '${d['data'] ?? ''}${d['tx_id'] ?? ''}';
  for (final d in decisoes) {
    final dest = d['destinatario'];
    if (d['resposta'] != 'emprestimo' || dest is! String || dest.isEmpty) continue;
    final pessoa = d['pessoa'];
    if (pessoa is! String || pessoa.trim().isEmpty) continue;
    final atual = melhores[dest];
    if (atual == null || chave(d).compareTo(chave(atual)) > 0) melhores[dest] = d;
  }
  return {for (final e in melhores.entries) e.key: (e.value['pessoa'] as String).trim()};
}
