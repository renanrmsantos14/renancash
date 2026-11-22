---
name: verificar-configuracoes
description: "Verifica Configurações e telas do 'resto' (Etapa 5 da revisão de UI): settingsPage (grupos e Mais ajustes), Sobre e Créditos, primeiro uso (onboarding), categorias, títulos associados, notificações, câmbio, histórico de alterações e depuração. Use após mudar budget/lib/pages/settingsPage.dart, aboutPage.dart, onBoardingPage.dart, editCategoriesPage.dart, addCategoryPage.dart, editAssociatedTitlesPage.dart, addAssociatedTitlePage.dart, notificationsPage.dart, exchangeRatesPage.dart, activityPage.dart, debugPage.dart, budget/lib/widgets/notificationsSettings.dart, budget/lib/widgets/timeDigits.dart, budget/lib/widgets/importCSV.dart ou as traduções pt dessas telas."
---
# Verificar Configurações e o resto

## Cobre
- `settingsPage.dart`: `configuracoesItens(context)` monta a lista (celular: página Configurações; computador: aba Mais, sem botão de FAQ do Cashew). `MoreOptionsPagePreferences` é a página "Mais ajustes" (Avançado). `MorePages` é o "Mais" do celular.
- `aboutPage.dart` (Sobre + `CreditosPage`, sem emoji `🍁` sem glifo e com idiomas de tradutores em português), `onBoardingPage.dart` (primeiro uso), categorias (`editCategoriesPage.dart`, `addCategoryPage.dart`), títulos associados (`editAssociatedTitlesPage.dart`, `addAssociatedTitlePage.dart`), notificações (`notificationsPage.dart`, `notificationsSettings.dart`, `timeDigits.dart`), câmbio (`exchangeRatesPage.dart`), `activityPage.dart` (histórico de alterações), `debugPage.dart` (em português).
- Traduções: `budget/assets/translations/generated/pt.json` e a coluna `pt` de `translations.csv` mudam juntas (mesma chave, mesmo texto).

## Estrutura esperada (não perder opção, só mover)
- Configurações: **Aparência** (Tema e cor, Idioma) · **Início e pendências** (Início, Pendências, Análise) · **Transações** (Pagar automaticamente, Data de pagamento, Pedir título + observação, Títulos automáticos, Notificações quando `notificationsGlobalEnabled`) · **Dados e backup** (Meu Banco, Backup no Google Drive, Arrumar dados, Exportar/Importar backup, Exportar/Importar CSV e Google Sheet com botão `template` ≥ 44 px, Histórico de alterações, Bloqueio por biometria quando disponível) · **Avançado** (Mais ajustes) · **Sobre** (versão na descrição).
- Mais ajustes: Estilo (ícones, fonte, animações, animação dos valores, contraste) · Transações (total do dia, resumo mensal, aba de transferência) · Contas e moedas (rótulos, câmbio, moeda principal) · Orçamentos e metas (tipo de total) · Formatação (número, porcentagem, relógio, 1º dia, teclado numérico) · Widgets só no Android.
- Sobre: cabeçalho com ícone, nome e versão (toque longo abre Depuração); App (Ver a introdução, Créditos, Baseado no Cashew, Licenças, Links do app só Android/web); Dados (Excluir todos os dados, com o fluxo de duas confirmações de sempre). Caixas `AboutInfoBox` com altura mínima ≥ 44 px. FAQ e política de privacidade do Cashew saíram.
- Primeiro uso: uma tela só — ícone, nome, frase, botão "Conectar banco" (conclui e abre Meu Banco), "Usar sem banco" (secundário, cor `chip`), links discretos "Moeda: XXX · Trocar" e "Restaurar backup do Google" (fora do iOS). Aberto pelo Sobre tem X para fechar. O passo de orçamento do Cashew saiu (orçamento se cria em Orçamentos).

## Roteiro
1. Ambiente: nunca rode `flutter` localmente se restrito; validação, `flutter analyze`, testes e geração de prints rodam no GitHub Actions (`Checks do PR`, `.github/workflows/checks-pr.yml`, artefato `prints`).
2. `flutter analyze` → 0 erros; nada novo nos arquivos acima.
3. `flutter test test/temas_app_test.dart test/aparencia_page_test.dart test/editorial_test.dart test/desktop_test.dart test/desktop_fluxos_test.dart` → passam.
4. Prints (`budget/test/prints_configuracoes_test.dart`): gera 57 arquivos `.verificacao/prints/config_*_{claro,escuro}.png` (celular 390×844) e `config_*_desktop_claro.png` (desktop 1440×900) cobrindo:
   - `config_lista`, `config_avancado` (`SettingsPageFramework`, `MoreOptionsPagePreferences`)
   - `config_primeiro_uso`, `config_primeiro_uso_fechar` (`OnBoardingPage`)
   - `config_categorias_dados`, `config_categorias_vazio`, `config_categorias_busca_vazia` (`EditCategoriesPage`)
   - `config_categoria_nova`, `config_categoria_editar`, `config_categoria_subcategoria_erro` (`AddCategoryPage`)
   - `config_titulos_dados`, `config_titulos_vazio`, `config_titulos_busca_vazia` (`EditAssociatedTitlesPage`)
   - `config_titulo` (validação vazia), `config_titulo_editar` (`AddAssociatedTitlePage`)
   - `config_notificacoes_ativas`, `config_notificacoes_inativas` (`NotificationsPage`)
   - `config_cambio_dados`, `config_cambio_busca_vazia` (`ExchangeRates`)
   - `config_historico_dados`, `config_historico_vazio` (`ActivityPage`)
   - `config_depuracao` (`DebugPage`)
   - `config_sobre`, `config_creditos` (`AboutPage`, `CreditosPage`)
   O teste carrega `loadCurrencyJSON()`, `loadLanguageNamesJSON()`, carteira padrão BRL e faz `precacheImage` de `assets/icon/icon-small.png` e ícones de categorias. Não duplicar `MoreOptionsPagePreferences` em `prints_visual_test.dart`.

## Casos de borda
- Computador (≥ 1100 px): o Mais mostra direto a lista de Configurações (sem "App", sem Sobre duplicado, sem botão `?` de FAQ do Cashew); em `AddCategoryPage`, o `SaveBottomButton` respeita `getHorizontalPaddingConstrained(context)`.
- "Conectar banco" no primeiro uso grava `hasOnboarded` e empurra `MeuBancoPage` pelo `navigatorKey`; confirmar que a página abre por cima do app e que voltar cai na Início.
- Categorias: vazio sem busca mostra `NoResults` + botão `"add-category"`; busca sem resultado mostra só o vazio de busca; linha da categoria = nome 16/w500 + "Despesa · N transações" em `mu`. Em `AddCategoryPage`, campo de nome usa `TextInput` Editorial (caixa `surf` + borda `line`, sem `bubbly: false`), `AssociatedTitleContainer` tem borda `line` e ícone `X` em `mu`, e o botão `i` de subcategoria tem alvo ≥ 44×44 px.
- Títulos: sem títulos e sem busca mostra frase + botão "Adicionar título" com margem horizontal de 18 px; com busca, só o vazio de busca. Na lista, cada linha mostra o título + nome da categoria abaixo em `mu`. Popup `AddAssociatedTitlePage`: usa `TextInput` Editorial (sem `bubbly: false`), quadrado com "+" até escolher a categoria, e não força foco/seleção ao abrir edição existente.
- Câmbio: crédito da API fica no popup de informação; taxas formatadas com vírgula decimal e até 4 casas (6 para `< 0,01`, sem 14 casas decimais); cada linha tem nome da moeda abaixo em `mu`, altura mínima ≥ 48 px, `borderRadius: 12` e borda `line` quando personalizada/alterada.
- Notificações: `TimeDigits` usa `cores(context).chip` e trata ausência de `EasyLocalization` sem lançar exceção; lista de próximas transações usa caixa `cartao` com borda `line` e divisor fino de 1 px.
- Histórico de alterações: sem botão de nova transação; vazio explica o que aparece; cartão de transação indisponível tem borda `line` e altura mínima ≥ 44 px; em modo de teste (`logsForTest`) omite `SelectedTransactionsAppBar` para não acessar `database`.
- Depuração (`DebugPage`): título, aviso e opções de teste traduzidos para português.
- `increase-text-contrast`: descrição em `mu` (desligado) ou `tx` (ligado), nunca na cor de acento.
- Tema antigo/locale: o título "Tema e cor" mostra o nome do tema salvo.
- Mais (celular) não tem mais "Conecte-se": login/backup do Google fica só em Configurações > Dados e backup > "Backup no Google Drive", com o subtítulo "Cópia dos seus dados na sua conta Google".
- Idioma: "Português (Brasil)" / "Português (Portugal)" (`assets/static/language-names.json`; o title case por palavra não mexe no parêntese).
- Diálogo de sair com alteração (`discardChangesPopup`): título "Descartar alterações?", botões "Continuar editando" e "Descartar".

## Evidência
- Checks do PR verdes no GitHub Actions e artefato `prints` com os PNGs `config_*` inspecionados.
- Configurações sincronizadas (F5): a lista branca de chaves é só `mbConfigLocal` (`mbSync/configuracoes.dart`); `mbConfigsSincronizadas` e o envio por `registros` não existem mais, as chaves viajam pelo espelho. Meu Banco: sem "Enviar tudo como oficial"; "Enviar dados para a nuvem" some em `pronto` (`test/espelho_enviar_test.dart`).
- Cartões de ajustes: em qualquer `PageFramework`/`MorePages`, as linhas entre um `SettingsHeader` e o próximo ficam num `GrupoBento` (`agruparBento`); prints `config_*`, `mais_*`, `ajustes_inicio_*` mostram um cartão por seção, sem linha solta sobre o fundo, no claro e no escuro. `OutlinedContainer` (Backup, seletores) é cartão sem contorno quando não selecionado.
