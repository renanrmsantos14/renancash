// Migração dos empréstimos do modelo antigo (objetivos do Cashew) para as decisões que alimentam a tela Empréstimos.
// O Worker calcula a prévia e grava; aqui ficam só os modelos das respostas e as chamadas. Valores em centavos inteiros.
import 'package:budget/struct/mbSync/cliente.dart';

int _int(Object? v) => v is num ? v.round() : int.tryParse('$v') ?? 0;
String? _txt(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
List<String> _lista(Object? v) => v is List ? [for (final x in v) if (x is String) x] : const [];

class MbMigDiferenca {
  final String? data;
  final int centavos; // negativo: valor pago a mais que o saldo do dia (não vira dívida)
  final String motivo;
  const MbMigDiferenca(this.data, this.centavos, this.motivo);
  static MbMigDiferenca? tentar(Object? j) =>
      j is Map ? MbMigDiferenca(_txt(j['data']), _int(j['centavos']), '${j['motivo'] ?? ''}') : null;
}

/// O que o outro modo (com ou sem ajuste de datas) daria para o mesmo empréstimo.
class MbMigAlternativa {
  final bool ajustar;
  final int saldoNovoCentavos, diferencaCentavos;
  const MbMigAlternativa(this.ajustar, this.saldoNovoCentavos, this.diferencaCentavos);
  static MbMigAlternativa? tentar(Object? j) => j is Map
      ? MbMigAlternativa(j['ajustar'] == true, _int(j['saldoNovoCentavos']), _int(j['diferencaCentavos']))
      : null;
}

class MbMigItem {
  final String objetivo, nome, status; // status: pronto | revisar | migrado | desatualizado | nao_mapeavel
  final String? pessoa;
  final List<String> motivos, avisos;
  final int lancamentos, originalCentavos, pagoCentavos, saldoAntigoCentavos, saldoNovoCentavos;
  final List<MbMigDiferenca> diferencas;
  final MbMigAlternativa? alternativa;
  const MbMigItem({
    required this.objetivo,
    required this.nome,
    required this.status,
    this.pessoa,
    this.motivos = const [],
    this.avisos = const [],
    this.lancamentos = 0,
    this.originalCentavos = 0,
    this.pagoCentavos = 0,
    this.saldoAntigoCentavos = 0,
    this.saldoNovoCentavos = 0,
    this.diferencas = const [],
    this.alternativa,
  });

  bool get migravel => status == 'pronto' || status == 'revisar';
  bool get migrado => status == 'migrado' || status == 'desatualizado';

  /// Σ das diferenças = saldo antigo − saldo novo (cada centavo explicado).
  int get diferencaCentavos => saldoAntigoCentavos - saldoNovoCentavos;

  /// Com ajuste de datas o saldo novo chega mais perto do antigo: a tela já o oferece ligado.
  bool get ajusteRecomendado {
    final a = alternativa;
    return a != null && a.ajustar && a.diferencaCentavos.abs() < diferencaCentavos.abs();
  }

  static MbMigItem? tentar(Object? j) {
    if (j is! Map || j['objetivo'] is! String) return null;
    return MbMigItem(
      objetivo: j['objetivo'] as String,
      nome: '${j['nome'] ?? ''}',
      status: '${j['status'] ?? ''}',
      pessoa: _txt(j['pessoa']),
      motivos: _lista(j['motivos']),
      avisos: _lista(j['avisos']),
      lancamentos: _int(j['lancamentos']),
      originalCentavos: _int(j['originalCentavos']),
      pagoCentavos: _int(j['pagoCentavos']),
      saldoAntigoCentavos: _int(j['saldoAntigoCentavos']),
      saldoNovoCentavos: _int(j['saldoNovoCentavos']),
      diferencas: [if (j['diferencas'] is List) for (final d in j['diferencas'] as List) if (MbMigDiferenca.tentar(d) case final x?) x],
      alternativa: MbMigAlternativa.tentar(j['alternativa']),
    );
  }
}

class MbMigPrevia {
  final String assinatura;
  final List<MbMigItem> itens;
  final int antesCentavos, depoisCentavos, saldoAntigoCentavos, saldoNovoCentavos, diferencaCentavos, efeitosCentavos, efeitosQtd;
  const MbMigPrevia({
    required this.assinatura,
    required this.itens,
    required this.antesCentavos,
    required this.depoisCentavos,
    required this.saldoAntigoCentavos,
    required this.saldoNovoCentavos,
    required this.diferencaCentavos,
    required this.efeitosCentavos,
    required this.efeitosQtd,
  });

  List<MbMigItem> get migraveis => [for (final i in itens) if (i.migravel) i];
  List<MbMigItem> get migrados => [for (final i in itens) if (i.migrado) i];
  List<MbMigItem> get naoMapeaveis => [for (final i in itens) if (i.status == 'nao_mapeavel') i];

  static MbMigPrevia? tentar(Map<String, dynamic> j) {
    final totais = j['totais'];
    if (j['assinatura'] is! String || j['itens'] is! List || totais is! Map) return null;
    final efeitos = totais['efeitosSobreOutros'];
    return MbMigPrevia(
      assinatura: j['assinatura'] as String,
      itens: [for (final i in j['itens'] as List) if (MbMigItem.tentar(i) case final x?) x],
      antesCentavos: _int(totais['antesCentavos']),
      depoisCentavos: _int(totais['depoisCentavos']),
      saldoAntigoCentavos: _int(totais['saldoAntigoCentavos']),
      saldoNovoCentavos: _int(totais['saldoNovoCentavos']),
      diferencaCentavos: _int(totais['diferencaCentavos']),
      efeitosCentavos: efeitos is List ? efeitos.fold<int>(0, (s, e) => s + (e is Map ? _int(e['centavos']) : 0)) : 0,
      efeitosQtd: efeitos is List ? efeitos.length : 0,
    );
  }
}

class MbMigResultado {
  final int antesCentavos, depoisCentavos, migrados;
  const MbMigResultado(this.antesCentavos, this.depoisCentavos, this.migrados);
}

extension MbClienteMigracao on MbCliente {
  /// Prévia (leitura pura). `ajustar`: objetivos com ajuste de datas dos pagamentos.
  Future<MbMigPrevia> emprestimosPrevia({Iterable<String> ajustar = const []}) async {
    final lista = ajustar.toList();
    final j = await chamarEmprestimos('GET', '/api/emprestimos/migracao', query: lista.isEmpty ? null : {'ajustar': lista.join(',')});
    return MbMigPrevia.tentar(j) ?? (throw MbErroHttp(502, 'Resposta inesperada do Meu Banco.'));
  }

  /// Grava as decisões dos [objetivos] escolhidos. 409: os dados mudaram desde a prévia (recarregue).
  Future<MbMigResultado> emprestimosMigrar(List<String> objetivos, String assinatura,
      {Map<String, String> pessoas = const {}, Iterable<String> ajustar = const []}) async {
    final j = await chamarEmprestimos('POST', '/api/emprestimos/migracao/aplicar',
        corpo: {'objetivos': objetivos, 'assinatura': assinatura, 'pessoas': pessoas, 'ajustar': ajustar.toList()});
    return MbMigResultado(_int(j['antesCentavos']), _int(j['depoisCentavos']), j['aplicados'] is List ? (j['aplicados'] as List).length : 0);
  }

  /// Apaga as decisões migradas do empréstimo (o histórico antigo nunca foi tocado). 409: algo já depende delas.
  Future<MbMigResultado> emprestimosDesfazerMigracao(String objetivo) async {
    final j = await chamarEmprestimos('POST', '/api/emprestimos/migracao/desfazer', corpo: {'objetivo': objetivo});
    return MbMigResultado(_int(j['antesCentavos']), _int(j['depoisCentavos']), _int(j['removidas']));
  }
}
