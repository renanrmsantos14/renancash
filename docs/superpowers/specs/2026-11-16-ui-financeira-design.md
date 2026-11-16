# Revisão da UI inteira no padrão de app financeiro

Data: 16/11/2026. Pedido: "reveja toda a UI e faça no padrão de app financeiro; reorganize, reanime, valide a UI de tudo", com execução autônoma (PRs, checks e merge sem consulta).

## Decisões
- Estilo: estender o editorial da Início (Geist, monocromático com um acento, números grandes com centavos menores, cartões planos separados por `surf` e borda, sem sombra). Nada de cor forte por categoria além do ícone.
- Animação: sutil e funcional. Toque com escala (`ToqueEscala`), entrada curta de listas e cartões (150–250 ms, fade + deslocamento de 8 px, em cascata limitada aos primeiros itens), valores que contam ao mudar (`ContagemValor`), transições de página suaves. Tudo desligado com "reduzir movimento" (`semMovimento`).
- Reorganizar: dentro de cada tela (hierarquia: número principal primeiro, ações secundárias depois), navegação e menus, e cortar telas que não funcionam neste fork ou fogem do uso pessoal.
- Execução: um PR por etapa, validado (analyze, testes, prints claro/escuro, navegador web) e mergeado antes da próxima etapa que dependa dele.

## Princípios de app financeiro
1. O valor é o protagonista: tabular (GeistMono ou `FontFeature.tabularFigures`), centavos menores, sinal − para gasto e verde só para entrada.
2. Uma ação principal por tela; o resto em linha secundária ou menu.
3. Listas de transações agrupadas por dia, com total do dia, linha de 56–64 px, ícone da categoria, descrição, conta em texto secundário e valor alinhado à direita.
4. Estados vazios curtos com uma ação; carregamento sem saltos de layout.
5. Textos pt-BR em caixa de frase, BRL, sem jargão do Cashew ("Wallet" → "Conta").
6. Toque mínimo de 44 px; contraste AA; leitor de tela com rótulos.
7. Confirmação para ações destrutivas; nada de excluir sem confirmar.

## Etapas
1. **Base e cortes** (`feat/ui-base`): componentes compartilhados herdados do Cashew no padrão editorial (cabeçalho de página, `SettingsContainer*`, botões, campos, folhas inferiores e popups, linha de transação, ícone de categoria, placeholders), transição de página e entrada de listas; corte das telas sem função no fork, tirando as entradas dos menus e o código morto, sem tocar em tabelas do banco.
2. **Transações**: lista, busca e filtros, nova/editar transação, detalhe, recorrentes e vencidas.
3. **Contas**: detalhe da conta (walletDetails), editar contas, nova conta, Meu Banco e conexões.
4. **Orçamentos e metas**: lista, detalhe, novo/editar orçamento e limites, histórico, metas e empréstimos.
5. **Configurações e o resto**: Configurações, categorias, títulos associados, onboarding, sobre, notificações, câmbio.
6. **Validação final**: varredura de todas as telas no navegador (celular 390×844 e desktop 1440×900, claro e escuro), correção do que sobrar.

## Corte de telas (critério)
Corta se a função depende de serviço que este fork não tem (Firebase, login Google, compras), ou não serve ao uso pessoal em pt-BR. Candidatas a confirmar no código: divisor de conta, modelos de e-mail e transações automáticas por e-mail, Premium/doação, changelog detalhado, orçamentos compartilhados e atividade. Mantém backup e exportação se funcionarem. Não remove colunas nem tabelas do banco; só UI, rotas e entradas de menu.

## Validação por etapa
- `flutter analyze` sem erros novos; testes existentes e novos passando.
- Prints `PRINTS=1` das telas mexidas, claro e escuro, conferidos.
- `flutter build web --base-href /app/` e `shot.mjs` nas telas acessíveis sem pareamento.
- Revisão de código (`/code-review high`) e correção antes do merge; skill `verificar-editorial-web` atualizada.

## Fora do escopo
Mudança de regras de negócio, sincronização Meu Banco, banco de dados e o backend.
