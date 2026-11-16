---
name: verificar-configuracoes
description: "Verifica Configurações e telas do 'resto' (Etapa 5 da revisão de UI): settingsPage (grupos e Mais ajustes), Sobre e Créditos, primeiro uso (onboarding), categorias, títulos associados, notificações, câmbio, histórico de alterações e depuração. Use após mudar budget/lib/pages/settingsPage.dart, aboutPage.dart, onBoardingPage.dart, editCategoriesPage.dart, addCategoryPage.dart, editAssociatedTitlesPage.dart, addAssociatedTitlePage.dart, notificationsPage.dart, exchangeRatesPage.dart, activityPage.dart, debugPage.dart ou as traduções pt dessas telas."
---
# Verificar Configurações e o resto

## Cobre
- `settingsPage.dart`: `configuracoesItens(context)` monta a lista (celular: página Configurações; computador: aba Mais). `MoreOptionsPagePreferences` é a página "Mais ajustes" (Avançado). `MorePages` é o "Mais" do celular.
- `aboutPage.dart` (Sobre + `CreditosPage`), `onBoardingPage.dart` (primeiro uso), categorias, títulos, notificações, câmbio, `activityPage.dart` (histórico de alterações), `debugPage.dart`.
- Traduções: `budget/assets/translations/generated/pt.json` e a coluna `pt` de `translations.csv` mudam juntas (mesma chave, mesmo texto).

## Estrutura esperada (não perder opção, só mover)
- Configurações: **Aparência** (Tema e cor, Idioma) · **Início e pendências** (Início, Pendências, Análise) · **Transações** (Pagar automaticamente, Data de pagamento, Pedir título + observação, Títulos automáticos, Notificações quando `notificationsGlobalEnabled`) · **Dados e backup** (Meu Banco, Backup no Google Drive, Exportar/Importar backup, Exportar/Importar CSV e Google Sheet, Histórico de alterações, Bloqueio por biometria quando disponível) · **Avançado** (Mais ajustes) · **Sobre** (versão na descrição).
- Mais ajustes: Estilo (ícones, fonte, animações, animação dos valores, contraste) · Transações (total do dia, resumo mensal, aba de transferência) · Contas e moedas (rótulos, câmbio, moeda principal) · Orçamentos e metas (tipo de total) · Formatação (número, porcentagem, relógio, 1º dia, teclado numérico) · Widgets só no Android.
- Sobre: cabeçalho com ícone, nome e versão (toque longo abre Depuração); App (Ver a introdução, Créditos, Baseado no Cashew, Licenças, Links do app só Android/web); Dados (Excluir todos os dados, com o fluxo de duas confirmações de sempre). FAQ e política de privacidade do Cashew saíram.
- Primeiro uso: uma tela só — ícone, nome, frase, botão "Conectar banco" (conclui e abre Meu Banco), "Usar sem banco" (secundário, cor `chip`), links discretos "Moeda: XXX · Trocar" e "Restaurar backup do Google" (fora do iOS). Aberto pelo Sobre tem X para fechar. O passo de orçamento do Cashew saiu (orçamento se cria em Orçamentos).

## Roteiro
1. Ambiente: `export PATH=/c/Users/mendo/development/flutter-3.24.5/bin:$PATH` (Windows) ou `$HOME/dev/flutter/bin` (nuvem); `cd budget`. Se o PC local estiver proibido de rodar flutter, rode tudo no GitHub Actions/nuvem.
2. `flutter analyze` → 0 erros; nada novo nos arquivos acima.
3. `flutter test test/temas_app_test.dart test/aparencia_page_test.dart test/editorial_test.dart test/desktop_test.dart test/desktop_fluxos_test.dart` → passam.
4. Prints: `PRINTS=1 flutter test test/prints_configuracoes_test.dart --update-goldens` gera `.verificacao/prints/config_{lista,avancado,sobre,creditos,titulo}_{claro,escuro}.png`. Textos `.tr()` saem como chave (teste sem EasyLocalization); grupos e descrições novas já saem em pt. Imagens de asset (ícone do app) e o ícone do Google não carregam no teste: o espaço vazio é esperado.
5. Web: `MSYS_NO_PATHCONV=1 flutter build web --base-href /app/` (confira que `build/web` tem `main.dart.js`; só `index.html` + `canvaskit` = build interrompido) e `node .claude/skills/verificar-editorial-web/shot.mjs budget/build/web .verificacao/<pasta> <roteiro.json>`. Perfil limpo abre o primeiro uso: print, `clicar` "Usar sem banco", depois Mais › Configurações e Mais › Categorias; repita com `{"acao":"contexto","escuro":true}`.

## Casos de borda
- Computador (≥ 1100 px): o Mais mostra direto a lista de Configurações (sem "App", sem Sobre duplicado); celular: Mais › App › Configurações/Notificações/Google/Sobre.
- "Conectar banco" no primeiro uso grava `hasOnboarded` e empurra `MeuBancoPage` pelo `navigatorKey`; confirmar no navegador que a página abre por cima do app e que voltar cai na Início.
- Categorias: busca sem resultado usa o vazio de busca; linha da categoria = nome 16/w500 + "Despesa · N transações" em `mu`.
- Títulos: sem títulos e sem busca mostra frase + botão "Adicionar título"; com busca, só o vazio de busca. Popup de título: quadrado com "+" até escolher a categoria; botão fica desabilitado sem nome e categoria.
- Câmbio: crédito da API foi para o popup de informação; linhas de taxa personalizada em `surf`.
- Histórico de alterações: sem botão de nova transação; vazio explica o que aparece; apagadas tocáveis para restaurar.
- `increase-text-contrast`: descrição em `mu` (desligado) ou `tx` (ligado), nunca na cor de acento.
- Tema antigo/locale: o título "Tema e cor" mostra o nome do tema salvo.

## Evidência
- Tail do analyze e dos testes, PNGs `config_*` e prints do navegador em `.verificacao/<data>-<branch>/`.
