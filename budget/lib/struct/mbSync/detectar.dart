import 'dart:convert';

import 'package:budget/struct/mbSync/registro.dart';

class Projetado {
  final String tabela, id;
  final Map<String, dynamic> dados;
  final String? editadoEm;
  const Projetado(this.tabela, this.id, this.dados, this.editadoEm);
  String get chave => '$tabela/$id';
}

class MudancaLocal {
  final Registro registro;
  final Map<String, dynamic>? projecao;
  const MudancaLocal(this.registro, this.projecao);
}

const Map<String, Map<String, dynamic>> _padroes = {
  'orcamentos': {'periodo': 'mensal', 'categoria_ids': <String>[]},
  'dividas': {'tipo': 'emprestimo'},
  'assinaturas': {'status': 'confirmada'},
};

Map<String, dynamic> completarNovo(String tabela, Map<String, dynamic> d) {
  final r = {...?_padroes[tabela], ...d};
  // '*' sobrou de envio rejeitado por nome vazio. O Worker aceita texto de até 200 caracteres.
  if (tabela == 'assinaturas' && (r['padrao'] == null || r['padrao'] == '*')) {
    final nome = (d['nome'] as String).toUpperCase();
    r['padrao'] = '${nome.length > 199 ? nome.substring(0, 199) : nome}*';
  }
  return r;
}

const int mbLimiteEnvio = 8000;

// Projeção sobre o que o servidor já guarda (`base`, que preserva campos que o aparelho não projeta).
// `linha` ausente na projeção (grande demais) não pode herdar a antiga da base.
Map<String, dynamic> dadosParaEnvio(Projetado p, Map<String, dynamic>? base) {
  final dados = completarNovo(p.tabela, {...?base, ...p.dados})
    ..removeWhere((_, v) => v == null);
  if (!p.dados.containsKey('linha')) dados.remove('linha');
  // O Worker rejeita `dados` acima de 8192 bytes; a base do servidor pode ter somado campos à projeção.
  if (utf8.encode(jsonEncode(dados)).length > mbLimiteEnvio) dados.remove('linha');
  return dados;
}

List<MudancaLocal> detectarMudancasLocais({
  required Map<String, Espelho> espelho,
  required Map<String, Projetado> atuais,
  required String agora,
  Set<String> semExclusaoLocal = const {'ajustes'},
  Set<String> existentes = const {},
  // Recebe o espelho de quem só difere por ganhar a `linha` (primeira rodada após atualizar o app): regravar sem
  // enviar, senão tudo subiria com updated_at=agora e atropelaria quem já editou no servidor.
  List<Espelho>? soLinha,
}) {
  final out = <MudancaLocal>[];
  for (final p in atuais.values) {
    final e = espelho[p.chave];
    if (e != null &&
        e.registro.deletedAt == null &&
        e.projecao != null &&
        jsonCanonico(e.projecao) == jsonCanonico(p.dados)) continue;
    if (e != null &&
        e.registro.deletedAt == null &&
        e.projecao != null &&
        !e.projecao!.containsKey('linha') &&
        p.dados.containsKey('linha') &&
        jsonCanonico(e.projecao) ==
            jsonCanonico({...p.dados}..remove('linha'))) {
      soLinha?.add(Espelho(e.registro, p.dados, e.pendente, e.motivo));
      continue;
    }
    if (e != null &&
        e.registro.deletedAt != null &&
        !(p.editadoEm != null &&
            p.editadoEm!.compareTo(e.registro.deletedAt!) > 0)) continue;
    final dados = dadosParaEnvio(
        p, e?.registro.deletedAt == null ? e?.registro.dados : null);
    var quando = p.editadoEm ?? mbNuncaEditado;
    if (e != null && quando.compareTo(e.registro.updatedAt) <= 0) quando = agora;
    out.add(MudancaLocal(Registro(p.tabela, p.id, dados, quando, null),
        semExclusaoLocal.contains(p.tabela) ? null : p.dados));
  }
  for (final e in espelho.values) {
    final r = e.registro;
    if (e.projecao == null ||
        r.deletedAt != null ||
        semExclusaoLocal.contains(r.tabela) ||
        atuais.containsKey(r.chave) ||
        existentes.contains(r.chave)) continue;
    out.add(MudancaLocal(Registro(r.tabela, r.id, null, agora, agora), null));
  }
  return out;
}
