import 'dart:convert';
import 'dart:ui';

import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/mbSync/armazem.dart';
import 'package:budget/struct/mbSync/cliente.dart';
import 'package:budget/struct/mbSync/revisao.dart';
import 'package:budget/struct/meuBancoSync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Notificações do Meu Banco no celular: o Worker manda cada alerta com `chave` e, nos de "Para revisar", o
// `item` da fila. O payload leva os dois, para responder pelos botões sem abrir o app.

const String mbPrefixoPayload = 'mb:';

const Map<String, String> _rotulos = {
  'emprestimo': 'Empréstimo',
  'investimento': 'Investimento',
  'ajuda': 'Ajuda',
  'devolucao': 'Me pagou um empréstimo',
  'reembolso': 'Reembolso',
  'renda': 'Renda',
};

String mbPayloadAlerta(Map<String, dynamic> n) =>
    mbPrefixoPayload + jsonEncode({'chave': '${n['chave']}', if (n['item'] != null) 'item': n['item']});

/// Payload do alerta (`mb:{chave, item?}`) decodificado; null se não for do Meu Banco ou vier malformado.
Map<String, dynamic>? mbDecodificarPayload(String? payload) {
  if (payload == null || !payload.startsWith(mbPrefixoPayload)) return null;
  try {
    final j = jsonDecode(payload.substring(mbPrefixoPayload.length));
    return j is Map ? Map<String, dynamic>.from(j) : null;
  } catch (_) {
    return null;
  }
}

/// Toque simples (sem botão) num alerta de classificação da IA: o Worker manda `item.tipo == 'ia_aplicadas'`; abre "Feito pela IA".
bool mbPayloadEhIa(String? payload) {
  final item = mbDecodificarPayload(payload)?['item'];
  return item is Map && item['tipo'] == 'ia_aplicadas';
}

/// Toque simples num alerta de saúde (`item.tipo == 'saude'`): abre a tela Saúde.
bool mbPayloadEhSaude(String? payload) {
  final item = mbDecodificarPayload(payload)?['item'];
  return item is Map && item['tipo'] == 'saude';
}

/// Respostas que pedem uma escolha (gasto, pessoa ou empréstimo): o botão abre o app em vez de responder sozinho.
const Set<String> _pedemOApp = {'reembolso', 'emprestimo', 'devolucao'};

/// Botões da notificação: as respostas do item.
List<AndroidNotificationAction> mbAcoesDoAlerta(Map<String, dynamic> n) {
  final item = MbItemRevisao.tentar(n['item']);
  if (item == null) return const [];
  return [
    for (final r in item.respostas)
      AndroidNotificationAction(r, _rotulos[r] ?? r,
          showsUserInterface: _pedemOApp.contains(r), cancelNotification: !_pedemOApp.contains(r))
  ];
}

/// Responde a fila pelo botão da notificação. `false` quando não há o que fazer (toque simples, item que já
/// saiu da fila, resposta que pede o app).
Future<bool> mbResponderPelaNotificacao(String? payload, String? acao,
    {MbCliente? clienteParaTeste}) async {
  if (acao == null || acao.isEmpty || _pedemOApp.contains(acao)) return false;
  final item = MbItemRevisao.tentar(mbDecodificarPayload(payload)?['item']);
  if (item == null || !item.respostas.contains(acao)) return false;
  // O aviso chega antes da próxima sincronização: puxa o que houver (offline segue com o que tem) e só barra
  // se já existe decisão para a transação, vinda deste ou de outro aparelho.
  await sincronizarMeuBanco(clienteParaTeste: clienteParaTeste);
  final revisoes = MbRevisoes.deLinhas(await mbLerRevisoes());
  if (revisoes.decisoes.containsKey(item.txId)) return false;
  await mbResponderRevisao(item, acao, clienteParaTeste: clienteParaTeste);
  return true;
}

/// Isolate de segundo plano (botão da notificação com o app fechado) nasce sem os globais do `main`.
Future<void> mbPrepararIsolate() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  try {
    sharedPreferences;
  } on Error {
    sharedPreferences = await SharedPreferences.getInstance();
  }
  try {
    database;
  } on Error {
    database = await constructDb('db');
  }
}

Future<void> mbTratarRespostaNotificacao(NotificationResponse r) async {
  if (r.payload?.startsWith(mbPrefixoPayload) != true) return;
  try {
    await mbPrepararIsolate();
    await mbResponderPelaNotificacao(r.payload, r.actionId);
  } catch (e) {
    if (kDebugMode) debugPrint('Meu Banco: falha ao responder pela notificação: $e');
  }
}
