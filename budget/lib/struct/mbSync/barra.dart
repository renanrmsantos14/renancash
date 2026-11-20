// Barra de baixo do modo Meu Banco: Início, Transações, Orçamentos, Empréstimos, Investimentos (fixa). Quem tinha atalhos
// personalizados (customNavBarShortcut0..2, inclusive Metas, Assinaturas ou Pendências) volta aos três primeiros itens
// da barra nova, uma única vez. Metas, Assinaturas, Pendências e Sobre seguem acessíveis em Configurações.

const String mbChaveBarraMigrada = "barraEmprestimosMigrada";
const List<String> mbAtalhosDaBarra = ["home", "transactions", "budgets"];

/// Devolve true se mudou algo (o chamador grava as preferências).
bool mbMigrarBarra(Map<String, dynamic> ajustes) {
  if (ajustes[mbChaveBarraMigrada] == true) return false;
  for (var i = 0; i < mbAtalhosDaBarra.length; i++) {
    ajustes["customNavBarShortcut$i"] = mbAtalhosDaBarra[i];
  }
  ajustes[mbChaveBarraMigrada] = true;
  return true;
}
