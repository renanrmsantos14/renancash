// Fila "Para classificar" da aba Pendências (funções puras, test/mb_classificar_test.dart).
//
// Entram os lançamentos do Meu Banco novos (a partir de quando a fila foi instalada) e os antigos sem categoria útil;
// ajuste de saldo e investimentos nunca entram. A sugestão vem da
// IA do Meu Banco (POST /api/ia/sugerir, Workers AI) ou, sem ela, dos padrões que o usuário já confirmou. Nada é
// aplicado sem o toque do usuário. Os padrões (favorecido normalizado → escolha) ficam só neste aparelho e vão como
// exemplos para a IA; a escolha confirmada sobe pelo sync normal (ajuste da categoria).
import 'package:budget/struct/mbSync/mapeamento.dart' show CatLocal;
import 'package:budget/struct/mbSync/revisao.dart'
    show MbItemRevisao, mbNormalizarRevisao;
import 'package:budget/struct/meuBancoMapping.dart' show mbDescricaoDelivery, mbPkInvestimento;

/// Categoria de ajuste de saldo (também a dos investimentos): nunca entra na fila nem vira opção.
const String mbCategoriaAjuste = '0';

/// Categorias que não dizem nada sobre o gasto (fonte única da fila). Também conta qualquer "Transferência…".
const Set<String> mbCategoriasSemUtilidade = {
  'a classificar',
  'sem categoria',
  'outros',
  'other',
  'pix',
  'pix para terceiros',
  'ted',
  'ted para terceiros',
  'doc para terceiros',
  'boleto para terceiros',
  'débito para terceiros',
  'transfers',
};

bool mbSemCategoriaUtil(String? nome) {
  final n = (nome ?? '').trim().toLowerCase();
  return n.isEmpty || mbCategoriasSemUtilidade.contains(n) || n.startsWith('transferência');
}

const double mbLimiarPergunta = 0.7; // igual a LIMIAR_PERGUNTA do Worker (src/ia.js)
const int mbMaxPadroes = 300;
const int mbMaxExemplos = 20;
const int mbLoteIa = 8; // igual a MAX_LANCAMENTOS do Worker

final RegExp _prefixoBanco = RegExp(
    r'^(?:PIX (?:ENVIAD[OA]|ENVIO|RECEBID[OA]|RECEBIMENTO)|(?:TED|DOC|TRANSFERENCIA)(?: (?:ENVIAD[OA]|RECEBID[OA]))?|PAGAMENTO(?: DE)?|PAG|COMPRA(?: NO)?(?: (?:DEBITO|CREDITO))?)\b ?');

/// Texto que o banco escreve ("PIX ENVIADO - …", "COMPRA NO DEBITO - …"), não um título dado pelo usuário.
bool mbTextoDoBanco(String descricao) => _prefixoBanco.hasMatch(mbNormalizarRevisao(descricao));

/// Favorecido/estabelecimento normalizado: sem acento, número, pontuação e prefixo do banco ("PIX ENVIADO", "COMPRA"),
/// até 4 palavras. "PIX ENVIADO - Fabiana Silva 123" e "Pix enviado Fabiana Silva" viram "FABIANA SILVA".
String mbChavePadrao(String descricao) => mbNormalizarRevisao(descricao)
    .replaceFirst(_prefixoBanco, '')
    .split(' ')
    .where((p) => p.length > 1)
    .take(4)
    .join(' ');

/// Uma confirmação do usuário, lembrada pelo favorecido.
class MbPadrao {
  final String chave, categoriaPk;
  final String? subPk, titulo, vinculoPk;
  final int vezes;
  const MbPadrao(this.chave, this.categoriaPk,
      {this.subPk, this.titulo, this.vinculoPk, this.vezes = 1});

  bool mesmaEscolha(MbPadrao o) =>
      categoriaPk == o.categoriaPk && subPk == o.subPk && vinculoPk == o.vinculoPk;

  Map<String, dynamic> toJson() => {
        'chave': chave,
        'categoria': categoriaPk,
        if (subPk != null) 'sub': subPk,
        if (titulo != null) 'titulo': titulo,
        if (vinculoPk != null) 'vinculo': vinculoPk,
        'vezes': vezes,
      };

  static MbPadrao? tentar(Object? j) {
    if (j is! Map || j['chave'] is! String || j['categoria'] is! String) return null;
    return MbPadrao(j['chave'] as String, j['categoria'] as String,
        subPk: _texto(j['sub']),
        titulo: _texto(j['titulo']),
        vinculoPk: _texto(j['vinculo']),
        vezes: (j['vezes'] as num?)?.toInt() ?? 1);
  }
}

String? _texto(Object? v) => v is String ? v : null;

List<MbPadrao> mbPadroesDeJson(Object? j) => [
      if (j is List)
        for (final p in j)
          if (MbPadrao.tentar(p) case final padrao?) padrao
    ];

/// Guarda a confirmação na frente (mais recente primeiro). Mesmo favorecido com a mesma escolha soma uma vez.
List<MbPadrao> mbRegistrarPadrao(List<MbPadrao> atuais, MbPadrao novo) {
  if (novo.chave.isEmpty) return atuais;
  final antigo = atuais.where((p) => p.chave == novo.chave).firstOrNull;
  final vezes = antigo != null && antigo.mesmaEscolha(novo) ? antigo.vezes + 1 : 1;
  return [
    MbPadrao(novo.chave, novo.categoriaPk,
        subPk: novo.subPk, titulo: novo.titulo, vinculoPk: novo.vinculoPk, vezes: vezes),
    ...atuais.where((p) => p.chave != novo.chave),
  ].take(mbMaxPadroes).toList();
}

/// Lançamento do Meu Banco já no aparelho. `revisao`: item "Pix enviado" da fila do Worker para o mesmo lançamento
/// (a resposta também grava a decisão e a memória do destinatário).
class MbLancamentoIa {
  final String pk, descricao, conta, categoriaNome;
  final String? categoriaPk;
  final double valor; // sinal do RenanCash: saída negativa
  final DateTime data;
  final bool editado, pendente;
  final MbItemRevisao? revisao;
  const MbLancamentoIa({
    required this.pk,
    required this.descricao,
    required this.valor,
    required this.data,
    this.conta = '',
    this.categoriaNome = '',
    this.categoriaPk,
    this.editado = false,
    this.pendente = false,
    this.revisao,
  });

  String get _dia =>
      '${data.year}-${data.month.toString().padLeft(2, '0')}-${data.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() => {
        'id': pk,
        'descricao': descricao,
        'valor': valor,
        'data': _dia,
        'conta': conta,
        'categoria': categoriaNome,
      };
}

/// Fila "Para validar": fora os pendentes, os já revisados, o ajuste de saldo e os investimentos. Entra tudo que o
/// mapeamento deixou em "A classificar" (todo lançamento do ciclo atual até o usuário validar, além do antigo sem
/// categoria útil) e o que o Worker pede para revisar. Mais recentes primeiro.
List<MbLancamentoIa> mbFilaClassificar(Iterable<MbLancamentoIa> lancamentos, {Set<String> revisados = const {}}) {
  final fila = [
    for (final l in lancamentos)
      if (!l.pendente &&
          !revisados.contains(l.pk) &&
          l.categoriaPk != mbCategoriaAjuste &&
          !l.pk.startsWith(mbPkInvestimento('')) &&
          (l.revisao != null || mbSemCategoriaUtil(l.categoriaNome)))
        l
  ];
  return fila..sort((a, b) => b.data.compareTo(a.data));
}

class MbCategoriaOpcao {
  final String pk, nome;
  final bool receita;
  final List<({String pk, String nome})> subs;
  const MbCategoriaOpcao(this.pk, this.nome, this.receita, [this.subs = const []]);
}

class MbVinculoOpcao {
  final String pk, nome, tipo; // tipo: emprestimo | meta
  const MbVinculoOpcao(this.pk, this.nome, this.tipo);
}

/// O que o usuário pode escolher: categorias úteis (uma por nome, a do usuário antes da `mb:`; nunca a de ajuste) e
/// empréstimos/metas abertos.
class MbOpcoes {
  final List<MbCategoriaOpcao> categorias;
  final List<MbVinculoOpcao> vinculos;
  final Map<String, String> _mesmoNome; // pk de cada categoria útil → pk da que ficou com aquele nome
  const MbOpcoes([this.categorias = const [], this.vinculos = const [], this._mesmoNome = const {}]);

  factory MbOpcoes.montar(Iterable<CatLocal> cats, [List<MbVinculoOpcao> vinculos = const []]) {
    String chave(CatLocal c) => '${c.receita}:${c.nome.toLowerCase()}';
    final uteis = [
      for (final c in cats)
        if (c.paiPk == null && c.pk != mbCategoriaAjuste && !mbSemCategoriaUtil(c.nome)) c
    ];
    final pais = <String, CatLocal>{};
    for (final c in uteis) {
      final atual = pais[chave(c)];
      if (atual == null || (atual.pk.startsWith('mb:') && !c.pk.startsWith('mb:'))) pais[chave(c)] = c;
    }
    return MbOpcoes([
      for (final p in pais.values)
        MbCategoriaOpcao(p.pk, p.nome, p.receita, [
          for (final s in cats)
            if (s.paiPk == p.pk) (pk: s.pk, nome: s.nome)
        ])
    ], vinculos, {
      for (final c in uteis) c.pk: pais[chave(c)]!.pk
    });
  }

  /// Também acha pela repetida de mesmo nome ("mb:cat:d:Transporte" → a Transporte do usuário).
  MbCategoriaOpcao? categoria(String? pk) {
    final alvo = _mesmoNome[pk] ?? pk;
    return categorias.where((c) => c.pk == alvo).firstOrNull;
  }
  MbVinculoOpcao? vinculo(String? pk) => vinculos.where((v) => v.pk == pk).firstOrNull;

  /// Contexto do POST /api/ia/*: categorias, vínculos e exemplos (pks; o Worker os troca por códigos curtos).
  Map<String, dynamic> contexto(List<MbPadrao> exemplos) => {
        'categorias': [
          for (final c in categorias)
            {
              'pk': c.pk,
              'nome': c.nome,
              'receita': c.receita,
              'subs': [for (final s in c.subs) {'pk': s.pk, 'nome': s.nome}],
            }
        ],
        'vinculos': [for (final v in vinculos) {'pk': v.pk, 'nome': v.nome, 'tipo': v.tipo}],
        'exemplos': [
          for (final p in exemplos)
            {
              'descricao': p.chave,
              'categoria': p.categoriaPk,
              if (p.subPk != null) 'subcategoria': p.subPk,
              if (p.titulo != null) 'titulo': p.titulo,
              if (p.vinculoPk != null) 'vinculo': p.vinculoPk,
            }
        ],
      };
}

/// Exemplos para a IA: primeiro os do mesmo favorecido do lote, depois os mais recentes.
List<MbPadrao> mbExemplosPara(Iterable<MbLancamentoIa> lote, List<MbPadrao> padroes) {
  final chaves = {for (final l in lote) mbChavePadrao(l.descricao)};
  return [
    ...padroes.where((p) => chaves.contains(p.chave)),
    ...padroes.where((p) => !chaves.contains(p.chave)),
  ].take(mbMaxExemplos).toList();
}

enum MbFonteSugestao { ia, padrao, atual, usuario, mesPassado }

/// Sugestão para um lançamento (da IA, de um padrão ou a categoria atual) e também a escolha final do usuário.
class MbSugestao {
  final String txPk, categoriaPk;
  final String? subPk, titulo, vinculoPk, pergunta;
  final double confianca;
  final MbFonteSugestao fonte;
  const MbSugestao(this.txPk, this.categoriaPk,
      {this.subPk,
      this.titulo,
      this.vinculoPk,
      this.pergunta,
      this.confianca = 0,
      this.fonte = MbFonteSugestao.usuario});

  MbSugestao comCategoria(String categoriaPk, {String? subPk}) =>
      MbSugestao(txPk, categoriaPk,
          subPk: subPk, titulo: titulo, vinculoPk: vinculoPk, confianca: 1);

  /// Resposta do Worker, conferida de novo contra as opções do aparelho: categoria precisa existir (e não ser de
  /// receita para saída de dinheiro), sub precisa ser dela e o vínculo precisa estar aberto.
  static MbSugestao? daIa(Object? j, MbOpcoes op, MbLancamentoIa l) {
    if (j is! Map || j['id'] != l.pk) return null;
    final cat = op.categoria(_texto(j['categoria']));
    if (cat == null || (l.valor < 0 && cat.receita)) return null;
    final sub = cat.subs.where((s) => s.pk == j['subcategoria']).firstOrNull;
    final c = j['confianca'];
    final confianca = c is num ? c.toDouble().clamp(0.0, 1.0) : 0.0;
    final titulo = '${j['titulo'] ?? ''}'.trim();
    final pergunta = '${j['pergunta'] ?? ''}'.trim();
    return MbSugestao(l.pk, cat.pk,
        subPk: sub?.pk,
        titulo: titulo.isEmpty ? null : titulo,
        vinculoPk: op.vinculo(_texto(j['vinculo']))?.pk,
        pergunta: confianca < mbLimiarPergunta && pergunta.isNotEmpty ? pergunta : null,
        confianca: confianca,
        fonte: MbFonteSugestao.ia);
  }
}

/// Sem IA: o padrão do mesmo favorecido (confiança alta se já confirmado mais de uma vez), senão a categoria atual se
/// ela for útil. Só sugere o que ainda existe nas opções.
MbSugestao? mbSugestaoLocal(MbLancamentoIa l, List<MbPadrao> padroes, MbOpcoes op) {
  final chave = mbChavePadrao(l.descricao);
  final p = chave.isEmpty ? null : padroes.where((p) => p.chave == chave).firstOrNull;
  final cat = op.categoria(p?.categoriaPk);
  if (p != null && cat != null && !(l.valor < 0 && cat.receita)) {
    return MbSugestao(l.pk, cat.pk,
        subPk: cat.subs.any((s) => s.pk == p.subPk) ? p.subPk : null,
        titulo: p.titulo,
        vinculoPk: op.vinculo(p.vinculoPk)?.pk,
        confianca: p.vezes > 1 ? 0.9 : 0.8,
        fonte: MbFonteSugestao.padrao);
  }
  if (l.valor < 0 && mbDescricaoDelivery.hasMatch(l.descricao)) {
    final alimentacao = op.categorias.where((c) => !c.receita && c.nome.toLowerCase() == 'alimentação').firstOrNull;
    final delivery = alimentacao?.subs.where((s) => s.nome.toLowerCase() == 'delivery').firstOrNull;
    if (alimentacao != null && delivery != null) {
      return MbSugestao(l.pk, alimentacao.pk, subPk: delivery.pk, confianca: 0.7, fonte: MbFonteSugestao.atual);
    }
  }
  final atual = op.categoria(l.categoriaPk);
  if (atual == null || mbSemCategoriaUtil(l.categoriaNome)) return null;
  return MbSugestao(l.pk, atual.pk, confianca: 0.5, fonte: MbFonteSugestao.atual);
}

// Palavras do favorecido que identificam descrições parecidas ("MUNDO DO CABELEIREIRO" → MUNDO, CABELEIREIRO).
Set<String> _palavras(String descricao) => {
      for (final p in mbChavePadrao(descricao).split(' '))
        if (p.length > 2) p
    };

/// Quantas vezes cada categoria foi usada nos lançamentos já classificados: no geral e por palavra do favorecido.
class MbUso {
  final Map<String, int> geral;
  final Map<String, Map<String, int>> porPalavra;
  const MbUso([this.geral = const {}, this.porPalavra = const {}]);

  factory MbUso.de(Iterable<({String descricao, String categoriaPk})> lancamentos) {
    final geral = <String, int>{};
    final porPalavra = <String, Map<String, int>>{};
    for (final l in lancamentos) {
      geral.update(l.categoriaPk, (n) => n + 1, ifAbsent: () => 1);
      for (final p in _palavras(l.descricao)) {
        porPalavra.putIfAbsent(p, () => {}).update(l.categoriaPk, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return MbUso(geral, porPalavra);
  }
}

/// Chips de alternativas do tipo certo (despesa ou receita), sem a sugerida: a categoria atual (se útil), depois as
/// mais usadas em descrições parecidas, depois as mais usadas em geral.
List<MbCategoriaOpcao> mbAlternativas(MbLancamentoIa l, String? sugeridaPk, MbUso uso, MbOpcoes op, {int max = 4}) {
  // Contagens por opção (a categoria repetida de mesmo nome conta para a que ficou).
  Map<String, int> somar(Iterable<Map<String, int>> contagens) {
    final out = <String, int>{};
    for (final e in contagens.expand((m) => m.entries)) {
      if (op.categoria(e.key) case final c?) out.update(c.pk, (n) => n + e.value, ifAbsent: () => e.value);
    }
    return out;
  }

  final parecidas = somar([for (final p in _palavras(l.descricao)) uso.porPalavra[p] ?? const {}]);
  final geral = somar([uso.geral]);
  final atual = op.categoria(l.categoriaPk)?.pk;
  final candidatas = [
    for (final c in op.categorias)
      if (c.pk != sugeridaPk && c.receita == (l.valor > 0)) c
  ];
  int comparar(int a, int b) {
    final (ca, cb) = (candidatas[a], candidatas[b]);
    for (final d in [
      (cb.pk == atual ? 1 : 0) - (ca.pk == atual ? 1 : 0),
      (parecidas[cb.pk] ?? 0) - (parecidas[ca.pk] ?? 0),
      (geral[cb.pk] ?? 0) - (geral[ca.pk] ?? 0),
    ]) {
      if (d != 0) return d;
    }
    return a - b; // empate fica na ordem das opções (o sort do Dart não é estável)
  }

  final ordem = [for (var i = 0; i < candidatas.length; i++) i]..sort(comparar);
  return [for (final i in ordem.take(max)) candidatas[i]];
}
