---
name: verificar-pendencias
description: "Verifica a aba Pendências e a fila Para classificar com IA: cartão de um lançamento por vez (valor, data, conta, descrição do banco), sugestão da IA do Meu Banco com Confirmar, pergunta quando a IA está na dúvida, chips de alternativas, Mais…, subcategorias, título, vínculo de empréstimo/meta, Explicar em texto livre, padrões locais sem IA e o selo. Use após mudar budget/lib/pages/pendenciasPage.dart, budget/lib/widgets/editorial/itemClassificar.dart, budget/lib/struct/mbSync/classificar.dart, classificarDados.dart, revisao.dart (mbTotalPendencias, mbAtualizarRevisar), seloPendencias.dart ou as rotas /api/ia/* do Worker (meu-banco/apps/worker/src/ia.js)."
---
# Verificar Pendências (Para classificar com IA)

## Cobre
- `struct/mbSync/classificar.dart` (puro): `mbCategoriasSemUtilidade` (fonte única da fila), `mbChavePadrao` (favorecido normalizado), `mbFilaClassificar`, `MbOpcoes`, `MbPadrao`/`mbRegistrarPadrao`, `mbSugestaoLocal` (sem IA), `MbSugestao.daIa` (confere a resposta da IA contra as opções do aparelho), `mbAlternativas`.
- `struct/mbSync/classificarDados.dart`: fila a partir do Drift (`mbAtualizarClassificar`, chamada no fim de `mbAtualizarRevisar`), `mbPedirSugestoes` (POST /api/ia/sugerir, lote de 8), `mbEntenderExplicacao` (POST /api/ia/entender), `mbConfirmarClassificacao`. Estado local em `mb_estado`: `ia_desde`, `ia_revisados`, `ia_padroes`.
- `widgets/editorial/itemClassificar.dart` (cartão) e `pages/pendenciasPage.dart` (fila: Para revisar → Para classificar → contas vencidas).

## Regras que precisam valer
- Entram na fila: lançamentos `mb:` não pendentes e não revisados que (a) estão numa categoria sem utilidade (A classificar, Pix, Transferências, Outros…), ou (b) são novos (data ≥ `ia_desde`, que é a primeira abertura − 7 dias) e não foram editados, ou (c) são "Pix enviado" da fila do Worker. Envio ao Santander, Pix recebido e salário continuam no cartão antigo (Para revisar).
- Pix enviado do Worker aparece uma vez só (no cartão novo) e conta uma vez no selo; Confirmar grava também a decisão `categoria` e a memória do destinatário (`mbResponderRevisao`).
- Nada é aplicado sem tocar em **Confirmar**. Chip, subcategoria, título, vínculo e Explicar só mudam a escolha mostrada ("Sua escolha" / "Sugestão da IA").
- Confirmar grava categoria, subcategoria, título (se houver), `objectiveLoanFk` (empréstimo) ou `objectiveFk` (meta) com `dateTimeModified` = agora; a categoria sobe como ajuste no sync normal; o padrão do favorecido vai para `ia_padroes` e vira exemplo para a IA e sugestão sem IA.
- Sem pareamento, sem internet, Worker sem `/api/ia/*` ou IA com erro: o cartão segue com padrões locais e mostra "Sem IA agora: sugestões pelos seus padrões."
- A IA só pode sugerir pk que existe nas opções do aparelho (categoria útil, sub da mesma categoria, empréstimo/meta não arquivado) e nunca categoria de receita para saída de dinheiro; pergunta só com confiança < 0,7.

## Passos
1. GitHub Actions ("Checks do PR"): `flutter test test/mb_classificar_test.dart test/pendencias_test.dart test/mb_revisao_test.dart` passam; prints `pendencias_ia_{claro,escuro}.png` no artefato "prints" (cartão com valor, pergunta da IA, Família, Empréstimo: Mãe, Confirmar, chips e Explicar). Não rode Flutter no PC local.
2. Worker: em `meu-banco/apps/worker`, `node --test test/ia.test.mjs` (sem deploy).
3. No aparelho (celular pareado, Worker já com o binding AI publicado):
   - Aba Pendências mostra "Para classificar" com "1 de N"; o selo soma esses itens.
   - Um Pix para alguém: aparece "Sugestão da IA" e, na dúvida, a pergunta (ex.: "Esse Pix de R$ 500 para Fabiana foi empréstimo para a Mãe?").
   - Toque num chip: a caixa vira "Sua escolha" com as subcategorias; toque numa sub, em "Título" e em "Vincular"; Confirmar → o item sai da fila e a transação muda em Transações (categoria › sub, título, vínculo).
   - Explicar: digite "almoço com cliente" e envie → aparece o entendimento para confirmar; nada muda até Confirmar.
   - Modo avião: abra a aba → aviso discreto "Sem IA agora…"; um favorecido já confirmado aparece com "Como você já respondeu".
   - No outro aparelho, após sincronizar, a categoria confirmada aparece (ajuste); título, sub e vínculo são locais deste aparelho.
4. Claro e escuro, fonte grande do sistema: nada estourado, botões com 44 px de altura, leitor de tela lê a pergunta (liveRegion) e os chips como botões.
