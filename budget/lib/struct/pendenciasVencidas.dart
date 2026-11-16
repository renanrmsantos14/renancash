import 'dart:async';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:flutter/foundation.dart';

/// Transações vencidas (a pagar), para a aba Pendências e o selo quando a opção está ligada.
final ValueNotifier<List<Transaction>> meuBancoVencidas = ValueNotifier(const []);

StreamSubscription<List<Transaction>>? _vigia;

/// Começa a acompanhar as vencidas uma vez só (o stream do banco segue vivo com o app).
/// Sem banco local (testes), não faz nada.
void mbVigiarVencidas() {
  if (_vigia != null) return;
  try {
    _vigia = database
        .watchAllOverdueUpcomingTransactions(true)
        .listen((l) => meuBancoVencidas.value = l);
  } catch (_) {}
}
