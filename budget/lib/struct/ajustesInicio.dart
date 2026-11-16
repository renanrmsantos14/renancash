import 'package:budget/struct/pendenciasVencidas.dart' show mbVigiarVencidas;
import 'package:budget/struct/settings.dart';
import 'package:flutter/foundation.dart';

/// Avisa as telas (Início, painel, Pendências, Análise, selo) quando uma dessas opções muda:
/// elas são `const` nas abas e não redesenham só com o rebuild do app.
final ValueNotifier<int> mbAjustesMudaram = ValueNotifier(0);

Future<void> mbGravarAjuste(String chave, Object valor) async {
  await updateSettings(chave, valor, updateGlobalState: false);
  if (AjustesInicio.vencidas) mbVigiarVencidas();
  mbAjustesMudaram.value++;
}

/// Configurações da Início, de Pendências e da Análise (Configurações › Início e pendências).
/// Sem a chave salva, vale o comportamento original: só "contas vencidas" começa desligada.
abstract final class AjustesInicio {
  // Início e cartão de saldo
  static bool get ritmoDiario => appStateSettings['inicioRitmoDiario'] != false;
  static bool get saldoContas => appStateSettings['inicioSaldoContas'] != false;
  static bool get atalhos => appStateSettings['inicioAtalhos'] != false;
  static bool get poupancasJuntas =>
      appStateSettings['inicioPoupancasJuntas'] != false;

  /// Linhas de metas e de empréstimos na Início (1 a 4).
  static int get linhasMetas =>
      ((appStateSettings['inicioLinhasMetas'] as num?)?.toInt() ?? 2)
          .clamp(1, 4);

  // Pendências
  static bool get selo => appStateSettings['pendenciasSelo'] != false;
  static bool get bancos => appStateSettings['pendenciasBancos'] != false;
  static bool get vencidas => appStateSettings['pendenciasVencidas'] == true;
  static bool get deslizar => appStateSettings['pendenciasDeslizar'] != false;

  // Análise em Orçamentos: 'patrimonio', 'linha', 'pizza', 'mapa'.
  static bool grafico(String chave) =>
      appStateSettings['analise_$chave'] != false;

  /// Gráfico de linha: 1 = tudo, 2 = só gastos, 3 = só receitas.
  static int get linhaTipo =>
      ((appStateSettings['analiseLinhaTipo'] as num?)?.toInt() ?? 1)
          .clamp(1, 3);
}
