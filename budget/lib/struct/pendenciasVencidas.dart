import 'dart:async';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:flutter/foundation.dart';

/// Transações vencidas, para a aba Pendências e o selo quando a opção está ligada.
final ValueNotifier<List<Transaction>> meuBancoVencidas = ValueNotifier(const []);

StreamSubscription<List<Transaction>>? _vigia;
Timer? _renovar;

/// Começa a acompanhar as vencidas uma vez só. A consulta guarda o "agora" de quando foi criada,
/// então é refeita de hora em hora para pegar o que venceu depois. Sem banco local (testes), não faz nada.
void mbVigiarVencidas() {
  if (_renovar != null) return;
  bool assinar() {
    try {
      _vigia?.cancel();
      _vigia = database
          .watchAllOverdueUpcomingTransactions(true)
          .listen((l) => meuBancoVencidas.value = l);
      return true;
    } catch (_) {
      return false;
    }
  }

  if (!assinar()) return;
  _renovar = Timer.periodic(const Duration(hours: 1), (_) => assinar());
}
