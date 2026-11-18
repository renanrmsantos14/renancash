import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/configuracoes.dart';
import 'package:budget/struct/mbSync/detectar.dart';
import 'package:budget/struct/mbSync/pareamento.dart';
import 'package:budget/struct/mbSync/projetarLocal.dart';
import 'package:budget/struct/mbSync/registro.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/struct/settings.dart';

// Só o que o usuário cria no app pode ser apagado do servidor por este aparelho. Revisões, ajustes e tudo o que vem
// do banco ficam como estão: este aparelho pode simplesmente não ter essas transações.
const Set<String> _tabelasApagaveis = {
  'carteiras',
  'categorias',
  'orcamentos',
  'limites',
  'metas',
  'dividas',
  'lancamentos',
  'regras',
  'assinaturas',
  'configuracoes',
};

class MbPlanoOficial {
  final List<Registro> registros;
  final int enviados, apagados;
  const MbPlanoOficial(this.registros, this.enviados, this.apagados);
}

/// Parte pura de "Enviar tudo como oficial": tudo o que este aparelho projeta vai com `updated_at = agora`;
/// registro vivo do servidor de tabela manual que não está na projeção (nem em `existentes`) vira tombstone.
MbPlanoOficial mbPlanejarOficial({
  required Map<String, Projetado> atuais,
  required Iterable<Registro> servidor,
  required Set<String> existentes,
  required String agora,
}) {
  final porChave = {for (final r in servidor) r.chave: r};
  // Ajustes e revisões seguem pelo sync normal; este aparelho pode nem ter essas transações.
  atuais = {
    for (final e in atuais.entries)
      if (_tabelasApagaveis.contains(e.value.tabela)) e.key: e.value
  };
  final out = <Registro>[
    for (final p in atuais.values)
      Registro(
          p.tabela,
          p.id,
          dadosParaEnvio(
              p,
              porChave[p.chave]?.deletedAt == null
                  ? porChave[p.chave]?.dados
                  : null),
          agora,
          null)
  ];
  final enviados = out.length;
  for (final r in servidor) {
    if (r.deletedAt != null ||
        !_tabelasApagaveis.contains(r.tabela) ||
        // Configuração fora da lista (de versão mais nova do app) não é nossa para apagar.
        (r.tabela == 'configuracoes' && !mbConfigsSincronizadas.contains(r.id)) ||
        atuais.containsKey(r.chave) ||
        existentes.contains(r.chave)) continue;
    out.add(Registro(r.tabela, r.id, null, agora, agora));
  }
  return MbPlanoOficial(out, enviados, out.length - enviados);
}

class MbResultadoOficial {
  final int enviados, apagados;
  final List<String> rejeitados;
  const MbResultadoOficial(this.enviados, this.apagados, this.rejeitados);
}

/// Motivo pelo qual a operação não deve prosseguir (nada foi alterado).
class MbRecusado implements Exception {
  final String mensagem;
  const MbRecusado(this.mensagem);
  @override
  String toString() => mensagem;
}

/// O que "Enviar tudo como oficial" faria, calculado sem enviar nada (para o diálogo de confirmação).
class MbPreparoOficial {
  final MbPlanoOficial plano;
  final Map<String, Projetado> atuais;
  const MbPreparoOficial(this.plano, this.atuais);
}

Future<List<Registro>> _puxarTudo(MbCliente cliente) async {
  final json = await cliente.puxar(null);
  return [
    for (final r in (json['registros'] as List? ?? const []))
      Registro.fromJson((r as Map).cast<String, dynamic>())
  ];
}

/// Planeja "Enviar tudo como oficial". Lança [MbRecusado] se este aparelho não tem lançamentos e categorias
/// (um aparelho vazio apagaria a nuvem inteira).
Future<MbPreparoOficial> mbPrepararOficial(MbCliente cliente) async {
  await mbCriarTabelas();
  final servidor = await _puxarTudo(cliente);
  final agora = isoMs(DateTime.now());
  final existentes = <String>{};
  final atuais = await mbProjetarLocal(
      {for (final r in servidor) r.chave: Espelho(r, null, false, null)},
      await mbLerAplicado(),
      agora: agora,
      existentes: existentes,
      todasConfiguracoes: true);
  bool tem(String t) => atuais.values.any((p) => p.tabela == t);
  if (!tem('lancamentos') || !tem('categorias')) {
    throw const MbRecusado(
        'Este aparelho não tem lançamentos e categorias; enviar agora apagaria os dados da nuvem.');
  }
  return MbPreparoOficial(
      mbPlanejarOficial(
          atuais: atuais, servidor: servidor, existentes: existentes, agora: agora),
      atuais);
}

/// Faz deste aparelho a fonte oficial: nada do servidor é aplicado aqui. Lança em falha de rede; o que não
/// chegou a sair continua pendente e vai na próxima sincronização. Rejeitados seguem pendentes (e são informados).
Future<MbResultadoOficial> mbExecutarOficial(
        MbCliente cliente, MbPreparoOficial preparo) =>
    mbEmRodada(() async {
      final plano = preparo.plano;
      await mbGravarEspelho([
        for (final r in plano.registros)
          Espelho(r, r.deletedAt != null ? null : preparo.atuais[r.chave]?.dados,
              true, null)
      ]);
      final rejeitados = <String>[];
      final voltam = <Espelho>[];
      while (true) {
        final lote = await mbPendentes();
        if (lote.isEmpty) break;
        final r = await cliente.enviar([for (final e in lote) e.registro]);
        final motivos = {for (final x in r.rejeitados) x.indice: x.motivo};
        await mbMarcarEnviados(lote, motivos);
        for (final x in r.rejeitados) {
          final e = lote[x.indice];
          rejeitados.add('${e.registro.tabela}: ${x.motivo}');
          voltam.add(Espelho(e.registro, e.projecao, true, x.motivo));
        }
      }
      // Fora do laço, senão o rejeitado seria reenviado sem fim.
      if (voltam.isNotEmpty) await mbGravarEspelho(voltam);
      return MbResultadoOficial(plano.enviados, plano.apagados, rejeitados);
    });

Future<MbResultadoOficial> mbTornarOficial(MbCliente cliente) async =>
    mbExecutarOficial(cliente, await mbPrepararOficial(cliente));

class MbContagemNuvem {
  final int lancamentos, categorias, carteiras;
  const MbContagemNuvem(this.lancamentos, this.categorias, this.carteiras);
}

Future<MbContagemNuvem> mbContarNuvem(MbCliente cliente) async {
  final vivos = (await _puxarTudo(cliente)).where((r) => r.deletedAt == null);
  int n(String t) => vivos.where((r) => r.tabela == t).length;
  return MbContagemNuvem(n('lancamentos'), n('categorias'), n('carteiras'));
}

/// "Recomeçar pela nuvem": apaga os dados do usuário que sincronizam e o estado de sincronização, e puxa tudo do
/// servidor. Recusa (sem apagar nada) se o servidor ainda não tem lançamentos e categorias do RenanCash. Retorna null se deu certo,
/// ou a mensagem de erro.
Future<String?> mbRecomecarPelaNuvem(MbCliente cliente) async {
  final c = await mbContarNuvem(cliente);
  if (c.lancamentos == 0 || c.categorias == 0) {
    return 'O servidor ainda não tem lançamentos e categorias do RenanCash. Use "Enviar tudo como oficial" no celular antes.';
  }
  // Na rodada de sincronização: o sync periódico não pode rodar entre apagar e baixar.
  return mbEmRodada(() async {
    await mbLimparDadosLocais();
    if (!await mbSincronizarNaRodada(cliente)) {
      return meuBancoUltimoErro.value ?? 'Não foi possível sincronizar agora.';
    }
    return null;
  });
}

/// Zera o que sincroniza (mbTrocarConta já limpa espelho, estado, aplicados e o que veio do banco).
/// Ficam a carteira e a categoria '0', que existem em todo aparelho; o resto volta do servidor no pull.
Future<void> mbLimparDadosLocais() async {
  await mbTrocarConta();
  await database.transaction(() async {
    for (final sql in const [
      'DELETE FROM mb_orcamento_tx',
      'DELETE FROM transactions',
      'DELETE FROM category_budget_limits',
      'DELETE FROM budgets',
      'DELETE FROM objectives',
      'DELETE FROM associated_titles',
      "DELETE FROM wallets WHERE wallet_pk <> '0'",
      "DELETE FROM categories WHERE category_pk <> '0'",
    ]) {
      await database.customStatement(sql);
    }
  });
  await updateSettings('selectedWalletPk', '0', updateGlobalState: true);
}
