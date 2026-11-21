import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/espelho.dart' show mbEspelhoCarregarEstado;
import 'package:budget/struct/meuBancoSync.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/meuBancoMapping.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart' show BuildContext, Icons;
import 'package:http/http.dart' as http;

class MbPareamento {
  final String base;
  final String token;
  const MbPareamento(this.base, this.token);
}

final RegExp _tokenValido = RegExp(r'^mb_[A-Za-z0-9_-]{43}$');
bool mbTokenValido(String t) => _tokenValido.hasMatch(t);

// Troca a senha do painel por um token. Em falha, lança a mensagem (String) para o usuário.
Future<MbPareamento> mbPedirToken(String base, String senha,
    {http.Client? cliente}) async {
  final http.Client c = cliente ?? http.Client();
  final Object? token;
  try {
    token = await MbCliente(base: base, cliente: c).parear(senha);
  } on MbErroHttp catch (e) {
    throw e.status == 401 ? 'Senha incorreta.' : e.mensagem;
  } catch (_) {
    throw 'Não foi possível falar com o Meu Banco. Confira o endereço e a internet.';
  } finally {
    if (cliente == null) c.close();
  }
  if (token is String && mbTokenValido(token)) return MbPareamento(base, token);
  throw 'Resposta inesperada do Meu Banco.';
}

// https sem caminho; http só em depuração e só para o Worker local (localhost / emulador).
bool mbOrigemPermitida(String u, {required bool debug}) {
  final uri = Uri.tryParse(u);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;
  if (uri.path.isNotEmpty && uri.path != '/') return false;
  if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) return false;
  if (uri.scheme == 'https') return true;
  return debug &&
      uri.scheme == 'http' &&
      (uri.host == 'localhost' || uri.host == '10.0.2.2');
}

MbPareamento? mbLerLinkPareamento(Uri uri) {
  if (uri.scheme != 'meubanco' || uri.host != 'parear') return null;
  final u = uri.queryParameters['u'];
  final t = uri.queryParameters['t'];
  if (u == null || t == null || !_tokenValido.hasMatch(t)) return null;
  if (!mbOrigemPermitida(u, debug: kDebugMode)) return null;
  return MbPareamento(u.replaceAll(RegExp(r'/+$'), ''), t);
}

// Conta nova: apaga o espelho, a fila, o estado e o que foi importado da conta anterior (carteiras sem uso, inclusive).
// O que nasceu no RenanCash fica e é reenviado como novo, porque o espelho está vazio.
Future<void> mbTrocarConta() async {
  (await SharedPreferences.getInstance()).remove('mbNotifCursor');
  await mbCriarTabelas();
  // O espelho da conta anterior: sem calar os triggers, apagar as transações `mb:` enfileiraria uma exclusão para cada
  // uma e elas subiriam para a conta nova. A fila e os apagados também são da conta antiga.
  final espelho = {
    for (final l in await database
        .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('mb_espelho_ctl', 'mb_saida', 'mb_apagados')")
        .get())
      l.read<String>('name')
  };
  final temCtl = espelho.contains('mb_espelho_ctl');
  await database.transaction(() async {
    if (temCtl) await database.customStatement('UPDATE mb_espelho_ctl SET aplicando = 1 WHERE id = 0');
    await database.customStatement('DELETE FROM mb_registros');
    await database.customStatement('DELETE FROM mb_aplicado');
    await database.customStatement('DELETE FROM mb_meta_aplicacao');
    await database.customStatement('DELETE FROM mb_estado');
    await database.customStatement(
        'DELETE FROM transactions WHERE transaction_pk LIKE ?',
        ['$mbPrefixo%']);
    await database.customStatement('''
      DELETE FROM wallets WHERE wallet_pk LIKE 'mb:%'
        AND wallet_pk NOT IN (SELECT wallet_fk FROM transactions)''');
    // Categorias importadas sem uso local saem; as que ainda têm lançamento do RenanCash ficam.
    await database.customStatement(
        "DELETE FROM associated_titles WHERE category_fk LIKE 'mb:cat:%'");
    await database.customStatement('''
      DELETE FROM categories WHERE category_pk LIKE 'mb:cat:%'
        AND category_pk NOT IN (SELECT category_fk FROM transactions)
        AND category_pk NOT IN (SELECT sub_category_fk FROM transactions WHERE sub_category_fk IS NOT NULL)
        AND category_pk NOT IN (SELECT category_fk FROM category_budget_limits)
        AND category_pk NOT IN (SELECT main_category_pk FROM categories WHERE main_category_pk IS NOT NULL)''');
    for (final t in const ['mb_saida', 'mb_apagados']) {
      if (espelho.contains(t)) await database.customStatement('DELETE FROM $t');
    }
    // `ativo = 0`: o aparelho volta a não ser espelho até semear ou baixar a conta nova.
    if (temCtl) await database.customStatement('UPDATE mb_espelho_ctl SET aplicando = 0, ativo = 0 WHERE id = 0');
  });
  // `espelho_pronto` saiu com `mb_estado`: sem recarregar, o agendador seguiria sincronizando com a conta nova como "pronto".
  await mbEspelhoCarregarEstado(forcar: true);
}

Future<bool> _contaDiferente(String base) async =>
    await meuBancoLerUrl() != base;

// Grava o pareamento. Só chamar depois da confirmação do usuário.
Future<void> mbParear(MbPareamento p) async {
  try {
    if (await _contaDiferente(p.base)) await mbTrocarConta();
    await meuBancoSalvarConfig(token: p.token, url: p.base);
    await mbCriarTabelas();
    await mbRemoverEstado('cursor');
  } catch (e) {
    if (kDebugMode) debugPrint("Meu Banco: falha ao parear: $e");
    openSnackbar(
        SnackbarMessage(title: "Não foi possível salvar o pareamento."));
    return;
  }
  openSnackbar(SnackbarMessage(title: "Pareado com ${Uri.parse(p.base).host}"));
  if (!await sincronizarMeuBanco() && meuBancoUltimoErro.value != null) {
    openSnackbar(SnackbarMessage(title: meuBancoUltimoErro.value!));
  }
}

// Nunca grava um pareamento (nem envia a senha) sem o usuário ver o host.
Future<bool> mbConfirmarHost(BuildContext? context, String base) async {
  final ctx = context ?? navigatorKey.currentContext;
  final host = Uri.parse(base).host;
  final jaPareado = (await meuBancoLerToken())?.isNotEmpty == true;
  final trocaConta = await _contaDiferente(base);
  final avisos = [
    "Só continue se o endereço for o do seu painel do Meu Banco.",
    if (jaPareado) "O pareamento atual será substituído.",
    if (trocaConta)
      "Os dados importados da conta anterior serão removidos deste aparelho. O que você criou no RenanCash continua.",
  ];
  final confirmou = await openPopup<bool>(
    ctx,
    title: "Parear com $host?",
    description: avisos.join("\n\n"),
    icon: Icons.link_rounded,
    onSubmitLabel: "Parear",
    onSubmit: () => popRoute(ctx, true),
    onCancelLabel: "Cancelar",
    onCancel: () => popRoute(ctx, false),
  );
  return confirmou == true;
}

// Retorna true se confirmou e pareou.
Future<bool> mbConfirmarEParear(BuildContext? context, MbPareamento p) async {
  if (!await mbConfirmarHost(context, p.base)) return false;
  await mbParear(p);
  return true;
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
