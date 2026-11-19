import 'package:budget/database/tables.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/espelhoTriggers.dart' show mbTabelasEspelhadas;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:http/http.dart' as http;

class LinhaServidor {
  Map<String, dynamic>? dados;
  String updatedAt, serverAt, aparelho;
  String? deletedAt;
  LinhaServidor(this.dados, this.updatedAt, this.deletedAt, this.serverAt, this.aparelho);
}

/// Imita o contrato de POST/GET /api/espelho do Worker: LWW por `updated_at` (empate: maior aparelho), junção de
/// colunas novas sobre as antigas, cursor `server_at|tabela|pk` e paginação por `mais`.
class ServidorEspelho {
  final Map<String, LinhaServidor> linhas = {};
  bool semeado = true;
  int _relogio = 0;
  int paginaMax = 2000;
  final List<int> tamanhosDeLote = [];
  final Set<String> tabelasConhecidas = {...mbTabelasEspelhadas};

  String _serverAt() => '2026-11-18T00:00:00.${(++_relogio).toString().padLeft(6, '0')}Z';

  Map<String, dynamic> enviar(String aparelho, List<Map<String, dynamic>> lote) {
    if (!semeado) throw MbErroHttp(409, 'nao_semeado');
    tamanhosDeLote.add(lote.length);
    var aceitos = 0;
    final rejeitados = <Map<String, dynamic>>[];
    for (final l in lote) {
      final chave = '${l['tabela']}|${l['pk']}';
      final atual = linhas[chave];
      final novo = l['updated_at'] as String;
      if (!tabelasConhecidas.contains(l['tabela']) && l['tabela'] != '_config') {
        rejeitados.add({'tabela': l['tabela'], 'pk': l['pk'], 'motivo': 'tabela_desconhecida'});
        continue;
      }
      // Reenvio idêntico (mesmo aparelho, mesma hora) conta como aceito.
      final vence = atual == null ||
          novo.compareTo(atual.updatedAt) > 0 ||
          (novo == atual.updatedAt && aparelho.compareTo(atual.aparelho) >= 0);
      if (!vence) {
        rejeitados.add({
          'tabela': l['tabela'],
          'pk': l['pk'],
          'motivo': 'mais_antiga',
          'atual': {
            'dados': atual.dados,
            'updated_at': atual.updatedAt,
            'deleted_at': atual.deletedAt,
            'aparelho': atual.aparelho,
          },
        });
        continue;
      }
      final dados = l['dados'] == null
          ? null
          : {...?atual?.dados, ...(l['dados'] as Map).cast<String, dynamic>()};
      linhas[chave] = LinhaServidor(dados, novo, l['deleted_at'] as String?, _serverAt(), aparelho);
      aceitos++;
    }
    return {'aceitos': aceitos, 'rejeitados': rejeitados};
  }

  bool _semeando = false;
  final List<int> lotesDeSemeio = [];

  /// Contrato de POST /api/espelho/semear: lotes de 0 em diante; o primeiro limpa o espelho e o `fim` marca `semeado`.
  Map<String, dynamic> semear(int lote, List<Map<String, dynamic>> lote_, bool fim) {
    if (semeado) throw MbErroHttp(409, 'ja_semeado');
    if (lote == 0) {
      linhas.clear();
      _semeando = true;
    } else if (!_semeando) {
      throw MbErroHttp(409, 'semeio_nao_iniciado');
    }
    lotesDeSemeio.add(lote);
    for (final l in lote_) {
      linhas['${l['tabela']}|${l['pk']}'] = LinhaServidor(
          (l['dados'] as Map?)?.cast<String, dynamic>(), l['updated_at'] as String, null, _serverAt(), 'semeio');
    }
    if (fim) {
      semeado = true;
      _semeando = false;
    }
    return {'aceitos': lote_.length, 'rejeitados': [], 'lote': lote, 'fim': fim, 'cursor': puxar(null, 1 << 30)['cursor']};
  }

  Map<String, dynamic> puxar(String? desde, int limite) {
    final todas = [
      for (final e in linhas.entries) (e.value.serverAt, e.key, e.value)
    ]..sort((a, b) => '${a.$1}|${a.$2}'.compareTo('${b.$1}|${b.$2}'));
    final depois = [
      for (final t in todas)
        if (desde == null || '${t.$1}|${t.$2}'.compareTo(desde) > 0) t
    ];
    final pagina = depois.take(limite < paginaMax ? limite : paginaMax).toList();
    return {
      'semeado': semeado,
      'linhas': [
        for (final t in pagina)
          {
            'tabela': t.$2.split('|').first,
            'pk': t.$2.substring(t.$2.indexOf('|') + 1),
            'dados': t.$3.dados,
            'updated_at': t.$3.updatedAt,
            'deleted_at': t.$3.deletedAt,
            'server_at': t.$3.serverAt,
          }
      ],
      'cursor': pagina.isEmpty ? desde : '${pagina.last.$1}|${pagina.last.$2}',
      'mais': depois.length > pagina.length,
    };
  }
}

class ClienteEspelhoFalso extends MbCliente {
  ClienteEspelhoFalso(this.servidor) : super(base: 'https://teste');
  final ServidorEspelho servidor;
  bool semRede = false;

  /// Id com que o servidor diz ter autenticado este aparelho (vai em `aparelho` do POST e do GET).
  String idServidor = 'servidor-a';

  /// Cursores recebidos nos GETs, para os testes conferirem o recuo de 30 s na primeira página.
  final List<String?> cursoresPedidos = [];

  /// Roda no meio do envio, depois de o servidor aceitar e antes de a fila ser limpa.
  Future<void> Function()? duranteEnvio;

  @override
  Future<Map<String, dynamic>> espelhoEnviar(String aparelho, List<Map<String, dynamic>> linhas) async {
    if (semRede) throw http.ClientException('sem rede');
    final r = servidor.enviar(aparelho, linhas);
    await duranteEnvio?.call();
    return {...r, 'aparelho': idServidor};
  }

  /// Lança no lote indicado (antes de o servidor receber), para testar a retomada.
  int? cairNoLote;
  final List<int> lotesEnviados = [];

  @override
  Future<Map<String, dynamic>> espelhoSemear(int lote, List<Map<String, dynamic>> linhas,
      {required bool fim}) async {
    if (semRede || cairNoLote == lote) {
      cairNoLote = null;
      throw http.ClientException('sem rede');
    }
    lotesEnviados.add(lote);
    return {...servidor.semear(lote, linhas, fim), 'aparelho': idServidor};
  }

  @override
  Future<Map<String, dynamic>> espelhoPuxar(String? desde, {int limite = 2000}) async {
    if (semRede) throw http.ClientException('sem rede');
    cursoresPedidos.add(desde);
    return {...servidor.puxar(desde, limite), 'aparelho': idServidor};
  }
}

Future<void> categoria(FinanceDatabase db, String pk, String nome, {String? cor}) =>
    db.into(db.categories).insert(CategoriesCompanion.insert(
        categoryPk: Value(pk),
        name: nome,
        order: 0,
        colour: Value(cor),
        dateTimeModified: Value(DateTime.now())));

Future<List<String>> fila(FinanceDatabase db) async => [
      for (final l in await db.customSelect('SELECT tabela, pk FROM mb_saida ORDER BY tabela, pk').get())
        '${l.read<String>('tabela')}|${l.read<String>('pk')}'
    ];

Future<Map<String, Object?>?> linhaDe(FinanceDatabase db, String tabela, String col, String pk) async =>
    (await db.customSelect('SELECT * FROM $tabela WHERE $col = ?', variables: [Variable<String>(pk)])
            .getSingleOrNull())
        ?.data;
