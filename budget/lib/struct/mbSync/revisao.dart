import 'dart:convert';
import 'dart:math' show max;

import 'package:budget/struct/ajustesInicio.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/casosComuns.dart' show mbRendimentosJuntos;
import 'package:budget/struct/pendenciasVencidas.dart' show meuBancoVencidas;
import 'package:budget/struct/mbSync/avisos.dart' show mbAtualizarAvisos, meuBancoAvisos;
import 'package:budget/struct/mbSync/classificarDados.dart'
    show mbAtualizarClassificar, meuBancoClassificar;
import 'package:budget/struct/mbSync/orcamentos.dart';
import 'package:budget/struct/mbSync/emprestimos.dart';
import 'package:budget/struct/mbSync/mapeamento.dart';
import 'package:budget/struct/mbSync/rachadas.dart' show mbAtualizarRachadas;
import 'package:budget/struct/mbSync/reembolso.dart'
    show mbTrocosLigados, mbVinculosReembolso, meuBancoReembolsos, meuBancoTrocos;
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:flutter/foundation.dart';

// Fila "Para revisar": o que precisa de uma decisão do usuário no ciclo atual.
//
// Decisões e memória por destinatário ficam na tabela `revisoes` do `registros` (sincronizada entre aparelhos):
//   id `tx:<transação>`  { tipo: "decisao", tx_id, resposta, categoria_id?, valor, data, descricao }
//   id `dest:<nome>`     { tipo: "destinatario", destinatario, categoria_id }
//   id `perdao:<empréstimo>` { tipo: "perdao", emprestimo_id, valor, data }   (saldo perdoado: vira gasto em `data`)
// "emprestimo" leva `pessoa` (e `emprestimo_id` para somar a um empréstimo que já existe); "devolucao" leva `emprestimo_id` do empréstimo
// que o Pix abate e, se passou do saldo, `sobra`, `sobra_para` (emprestimo | reembolso | renda) e `sobra_id`; `recategorizado`: o item
// "empréstimo sem pessoa" foi resolvido trocando a categoria. Empréstimos e devoluções (emprestimos.dart) e reembolsos (`reembolso_de` = id do gasto reembolsado) saem das decisões
// com resposta "emprestimo" | "devolucao" | "reembolso"; "troco" (Pix enviado, `troco_de` = id do reembolso que ele abate)
// devolve parte de um reembolso (reembolso.dart). A regra de tipo é a mesma de apps/worker/src/revisao.js (tipoDeRevisao).

const String mbCategoriaAClassificar = "A classificar";

const List<String> mbRespostasRevisao = [
  'categoria',
  'emprestimo',
  'investimento',
  'ajuda',
  'devolucao',
  'reembolso',
  'renda',
  'troco',
];

class MbTipoRevisao {
  final String tipo; // pix_enviado | envio_santander | pix_recebido
  final String? destinatario;
  const MbTipoRevisao(this.tipo, [this.destinatario]);
}

String mbNormalizarRevisao(String s) {
  const de = 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ';
  const para = 'AAAAAEEEEIIIIOOOOOUUUUC';
  final b = StringBuffer();
  for (final c in s.toUpperCase().split('')) {
    final i = de.indexOf(c);
    b.write(i >= 0 ? para[i] : c);
  }
  return b.toString().replaceAll(RegExp(r'[^A-Z ]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

final RegExp _pixEnviado = RegExp(r'^PIX (ENVIAD[OA]|ENVIO)\b ?');
final RegExp _pixRecebido = RegExp(r'^PIX (RECEBID[OA]|RECEBIMENTO)\b ?');
final RegExp _santander = RegExp(r'\bSANTANDER\b');
const int _maxDestinatario = 60;

/// Que pergunta a transação gera (ou null). `valor` no sinal do RenanCash; só vale para conta (cartão não pergunta).
MbTipoRevisao? mbTipoDeRevisao(
    {required String descricao, required double valor, String? categoria, bool entreMinhas = false}) {
  final d = mbNormalizarRevisao(descricao);
  if (valor < 0) {
    // Dinheiro do Inter para o Santander: a categoria "transferência entre minhas contas" não impede a pergunta.
    if (_santander.hasMatch(d)) {
      return mbNaoEhGasto(null, descricao) ? null : const MbTipoRevisao('envio_santander');
    }
    if (mbNaoEhGasto(categoria, descricao, entreMinhas: entreMinhas)) return null;
    final m = _pixEnviado.firstMatch(d);
    if (m == null) return null;
    final fim = (m.end + _maxDestinatario) > d.length ? d.length : m.end + _maxDestinatario;
    final nome = d.substring(m.end, fim).trim();
    return MbTipoRevisao('pix_enviado', nome.isEmpty ? null : nome);
  }
  if (valor > 0 && !mbNaoEhGasto(categoria, descricao, entreMinhas: entreMinhas) && _pixRecebido.hasMatch(d)) {
    return const MbTipoRevisao('pix_recebido');
  }
  return null;
}

/// Decisões por transação e memória por destinatário, lidas dos registros (ignora os malformados e os apagados).
class MbRevisoes {
  final Map<String, Map<String, dynamic>> decisoes;
  final Map<String, String> destinos;
  /// Perdões de empréstimo por id do empréstimo ({ emprestimo_id, valor, data }).
  final Map<String, Map<String, dynamic>> perdoes;
  const MbRevisoes([this.decisoes = const {}, this.destinos = const {}, this.perdoes = const {}]);

  factory MbRevisoes.deLinhas(Iterable<Registro> regs) {
    final decisoes = <String, Map<String, dynamic>>{};
    final destinos = <String, String>{};
    final perdoes = <String, Map<String, dynamic>>{};
    for (final r in regs) {
      final d = r.dados;
      if (r.tabela != 'revisoes' || r.deletedAt != null || d == null) continue;
      if (d['tipo'] == 'perdao') {
        final valor = d['valor'];
        if (d['emprestimo_id'] is String &&
            valor is num &&
            valor > 0 &&
            RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch('${d['data'] ?? ''}')) {
          perdoes[d['emprestimo_id'] as String] = d;
        }
      } else if (d['tipo'] == 'decisao' && d['tx_id'] is String && d['resposta'] is String) {
        decisoes[d['tx_id'] as String] = d;
      } else if (d['tipo'] == 'destinatario' &&
          d['destinatario'] is String &&
          d['categoria_id'] is String) {
        destinos[d['destinatario'] as String] = d['categoria_id'] as String;
      }
    }
    // Troco de um reembolso que não está mais ligado (ou nunca foi): vale como se não tivesse resposta, igual ao Worker.
    decisoes.removeWhere((_, d) {
      if (d['resposta'] != 'troco') return false;
      final r = decisoes[d['troco_de']];
      return r == null || r['resposta'] != 'reembolso' || r['reembolso_de'] is! String;
    });
    return MbRevisoes(decisoes, destinos, perdoes);
  }

  /// Resposta do usuário; no Pix enviado, a memória do destinatário conta como "categoria".
  String? resposta(String txId, MbTipoRevisao tipo) =>
      decisoes[txId]?['resposta'] as String? ??
      (tipo.tipo == 'pix_enviado' && tipo.destinatario != null && destinos.containsKey(tipo.destinatario)
          ? 'categoria'
          : null);

  /// Categoria escolhida para este Pix: a da decisão ou, sem ela, a lembrada para o destinatário.
  String? categoriaId(String txId, MbTipoRevisao tipo) =>
      decisoes[txId]?['categoria_id'] as String? ??
      (tipo.destinatario == null ? null : destinos[tipo.destinatario]);
}

class MbCandidatoSalario {
  final String txId, data, descricao;
  final double valor;
  const MbCandidatoSalario(this.txId, this.data, this.descricao, this.valor);
}

/// Item da fila vindo de `ciclo.revisar` (Worker). `salario_nao_detectado` traz `dias` e `candidatos`.
class MbItemRevisao {
  final String id, tipo;
  final String? txId, data, descricao, destinatario;
  final double valor;
  final int dias;
  final List<MbCandidatoSalario> candidatos;
  const MbItemRevisao(this.id, this.tipo,
      {this.txId,
      this.data,
      this.descricao,
      this.destinatario,
      this.valor = 0,
      this.dias = 0,
      this.candidatos = const []});

  bool get ehSalario => tipo == 'salario_nao_detectado';

  /// Empréstimo que já existe (categoria "Empréstimo" ou decisão sem pessoa) e precisa de uma pessoa.
  bool get semPessoa => tipo == 'emprestimo_sem_pessoa';

  /// Respostas oferecidas para este tipo de item (Pix enviado escolhe a categoria, não aparece aqui).
  /// "devolucao" (na tela: "Me pagou um empréstimo") só existe com empréstimo em aberto: [emprestimos] vem de meuBancoEmprestimos.
  List<String> respostasCom(MbEmprestimos emprestimos) => [
        for (final r in respostas)
          if (r != 'devolucao' || emprestimos.abertos.isNotEmpty) r
      ];

  /// Todas as respostas possíveis do tipo (sem olhar os empréstimos em aberto).
  List<String> get respostas => switch (tipo) {
        'envio_santander' => const ['emprestimo', 'investimento', 'ajuda'],
        'pix_recebido' => const ['devolucao', 'reembolso', 'renda'],
        _ => const [],
      };

  static MbItemRevisao? tentar(Object? j) {
    if (j is! Map || j['id'] is! String || j['tipo'] is! String) return null;
    final tipo = j['tipo'] as String;
    if (tipo == 'salario_nao_detectado') {
      return MbItemRevisao(j['id'] as String, tipo,
          dias: (j['dias'] as num?)?.toInt() ?? 0, candidatos: [
        for (final c in (j['candidatos'] as List? ?? const []))
          if (c is Map && c['tx_id'] is String && c['valor'] is num)
            MbCandidatoSalario(c['tx_id'] as String, '${c['data']}', '${c['descricao'] ?? ''}',
                (c['valor'] as num).toDouble())
      ]);
    }
    if (j['tx_id'] is! String || j['valor'] is! num) return null;
    return MbItemRevisao(j['id'] as String, tipo,
        txId: j['tx_id'] as String,
        data: j['data'] is String ? j['data'] as String : null,
        descricao: '${j['descricao'] ?? ''}',
        destinatario: j['destinatario'] as String?,
        valor: (j['valor'] as num).toDouble());
  }
}

/// Itens do `ciclo` guardado no último pull (funciona offline). Worker antigo não manda `revisar`: lista vazia.
List<MbItemRevisao> mbItensRevisar(Object? ciclo) => [
      if (ciclo is Map && ciclo['revisar'] is List)
        for (final j in ciclo['revisar'] as List)
          if (MbItemRevisao.tentar(j) case final item?) item
    ];

/// A fila como o usuário a vê: o que já foi respondido neste aparelho (ou no outro, já puxado) some
/// sem esperar a próxima sincronização.
List<MbItemRevisao> mbFilaVisivel(List<MbItemRevisao> itens, MbRevisoes revisoes) => [
      for (final i in itens)
        if (i.ehSalario ||
            (i.semPessoa && _precisaDePessoa(revisoes.decisoes[i.txId])) ||
            (!i.semPessoa &&
                !revisoes.decisoes.containsKey(i.txId) &&
                !(i.tipo == 'pix_enviado' &&
                    i.destinatario != null &&
                    revisoes.destinos.containsKey(i.destinatario))))
          i
    ];

// O item "empréstimo sem pessoa" some quando a decisão já tem a pessoa ou a categoria foi trocada.
bool _precisaDePessoa(Map<String, dynamic>? d) =>
    d == null || !(d['recategorizado'] == 1 || (d['resposta'] == 'emprestimo' && (d['pessoa'] as String?)?.trim().isNotEmpty == true));

/// Fila que a Início mostra, lida do que está no aparelho.
final ValueNotifier<List<MbItemRevisao>> meuBancoRevisar = ValueNotifier(const []);

/// Total da aba Pendências (selo): itens Para revisar, Para classificar (o Pix enviado do Worker conta uma vez só) e, conforme as configurações,
/// bancos desconectados e contas vencidas.
int mbTotalPendencias() =>
    meuBancoRevisar.value.length +
    meuBancoClassificar.value.where((l) => l.revisao == null).length -
    max<int>(0, mbRendimentosJuntos(meuBancoClassificar.value).length - 1) + // rendimentos: um cartão só
    (AjustesInicio.bancos ? meuBancoAvisos.value.length : 0) +
    (AjustesInicio.vencidas
        ? meuBancoVencidas.value.where((t) => !t.income).length
        : 0);

Future<void> mbAtualizarRevisar() async {
  try {
    await mbCriarTabelas();
    await mbCarregarCicloCache();
    final texto = await mbLerEstado('ciclo');
    Object? ciclo;
    try {
      ciclo = texto == null ? null : jsonDecode(texto);
    } catch (_) {}
    final revisoes = MbRevisoes.deLinhas(await mbLerRevisoes());
    meuBancoRevisar.value = mbFilaVisivel(mbItensRevisar(ciclo), revisoes);
    meuBancoPessoasLembradas.value = mbPessoaLembrada(revisoes.decisoes.values);
    meuBancoEmprestimos.value = mbCalcularEmprestimos(revisoes.decisoes.values, perdoes: revisoes.perdoes.values);
    meuBancoReembolsos.value = mbVinculosReembolso(revisoes.decisoes.values);
    meuBancoTrocos.value = mbTrocosLigados(revisoes.decisoes.values, meuBancoReembolsos.value);
    await mbAtualizarRachadas(meuBancoReembolsos.value, meuBancoTrocos.value);
  } catch (e) {
    if (kDebugMode) debugPrint('Meu Banco: falha ao ler a fila Para revisar: $e');
  }
  await mbAtualizarClassificar(); // depende da fila acima (Pix enviado do Worker) e não lança
  // Fora do try: banco desconectado aparece mesmo se a fila falhar (mbLerAvisos não lança).
  await mbAtualizarAvisos();
}

/// Registro do perdão do saldo de um empréstimo: o valor fica fixo e vira gasto em `data`.
Registro mbRegistroDePerdao(String emprestimoId, double valor, String data, String agora) =>
    Registro('revisoes', 'perdao:$emprestimoId',
        {'tipo': 'perdao', 'emprestimo_id': emprestimoId, 'valor': valor, 'data': data}, agora, null);

/// Registros a gravar ao responder: a decisão da transação e, no Pix enviado com categoria, a memória do destinatário.
List<Registro> mbRegistrosDeResposta(MbItemRevisao item, String resposta,
    {String? categoriaPk,
    String? reembolsoDe,
    String? trocoDe,
    String? pessoa,
    String? emprestimoId,
    double? sobra,
    String? sobraPara,
    String? sobraId,
    bool recategorizado = false,
    required String agora}) {
  final descricao = item.descricao ?? '';
  return [
    Registro(
        'revisoes',
        'tx:${item.txId}',
        {
          'tipo': 'decisao',
          'tx_id': item.txId,
          'resposta': resposta,
          'valor': item.valor,
          'data': item.data,
          'descricao': descricao.length > 200 ? descricao.substring(0, 200) : descricao,
          if (categoriaPk != null) 'categoria_id': idDoPk(categoriaPk),
          if (item.destinatario != null) 'destinatario': item.destinatario,
          // Reembolso: id (sem prefixo "mb:") do gasto que o usuário confirmou como reembolsado.
          if (resposta == 'reembolso' && reembolsoDe != null) 'reembolso_de': reembolsoDe,
          // Troco: id (sem prefixo "mb:") do Pix recebido, ligado como reembolso, que este Pix enviado abate.
          if (resposta == 'troco' && trocoDe != null) 'troco_de': trocoDe,
          // Empréstimo: a pessoa (e, se soma a um que já existe, o id dele). Devolução: o empréstimo que o Pix abateu.
          if (resposta == 'emprestimo' && pessoa != null && pessoa.trim().isNotEmpty) 'pessoa': pessoa.trim(),
          if ((resposta == 'emprestimo' || resposta == 'devolucao') && emprestimoId != null) 'emprestimo_id': emprestimoId,
          // O que passou do saldo e para onde foi (outro empréstimo, reembolso de um gasto ou renda).
          if (resposta == 'devolucao' && sobra != null && sobra > 0 && sobraPara != null) ...{
            'sobra': sobra,
            'sobra_para': sobraPara,
            if (sobraId != null) 'sobra_id': sobraId,
            if (sobraPara == 'reembolso' && reembolsoDe != null) 'reembolso_de': reembolsoDe,
          },
          if (recategorizado) 'recategorizado': 1,
        },
        agora,
        null),
    if (resposta == 'categoria' && categoriaPk != null && item.destinatario != null)
      Registro(
          'revisoes',
          'dest:${item.destinatario}',
          {
            'tipo': 'destinatario',
            'destinatario': item.destinatario,
            'categoria_id': idDoPk(categoriaPk),
          },
          agora,
          null),
  ];
}
