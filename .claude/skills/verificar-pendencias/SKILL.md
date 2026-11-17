---
name: verificar-pendencias
description: "Verifica a aba Pendências e a fila Para classificar com IA: cartão de um lançamento por vez (valor, data, conta, descrição do banco), sugestão da IA do Meu Banco com Confirmar, pergunta quando a IA está na dúvida, chips de alternativas, Mais…, subcategorias, título, vínculo de empréstimo/meta, Explicar em texto livre, padrões locais sem IA e o selo. Use após mudar budget/lib/pages/pendenciasPage.dart, budget/lib/widgets/editorial/itemClassificar.dart, budget/lib/struct/mbSync/classificar.dart, classificarDados.dart, revisao.dart (mbTotalPendencias, mbAtualizarRevisar), seloPendencias.dart ou as rotas /api/ia/* do Worker (meu-banco/apps/worker/src/ia.js)."
---
# Verificar Pendências (Para classificar com IA)

## Cobre
- `struct/mbSync/classificar.dart` (puro): `mbCategoriasSemUtilidade` (fonte única da fila), `mbChavePadrao` (favorecido normalizado), `mbFilaClassificar`, `mbMarcoNovos`, `MbOpcoes` (sem a categoria de ajuste `0`; acha a repetida `mb:` de mesmo nome), `MbPadrao`/`mbRegistrarPadrao`, `mbSugestaoLocal` (sem IA), `MbSugestao.daIa` (confere a resposta da IA contra as opções do aparelho), `MbUso` + `mbAlternativas`.
- `struct/mbSync/classificarDados.dart`: fila a partir do Drift (`mbAtualizarClassificar`, chamada no fim de `mbAtualizarRevisar`), `mbPedirSugestoes` (POST /api/ia/sugerir, lote de 8; situação por item em `meuBancoIaEstado`: pedindo, sem sugestão, falhou), `mbEntenderExplicacao` (POST /api/ia/entender), `mbConfirmarClassificacao`, `mbUsoClassificar` (uso das categorias em todas as transações). Estado local em `mb_estado`: `ia_novos_desde` (marco dos novos; migra de `ia_desde` + 7 dias), `ia_revisados`, `ia_padroes`.
- `widgets/editorial/itemClassificar.dart` (cartão) e `pages/pendenciasPage.dart` (fila: Para revisar → Para classificar → contas vencidas; `ordenarPulados` e a posição real "N de T").

## Regras que precisam valer
- Entram na fila: lançamentos `mb:` não pendentes e não revisados que (a) estão numa categoria sem utilidade (A classificar, Pix, Transferências, Outros…), ou (b) são novos (data ≥ `ia_novos_desde`, gravado na primeira execução = instalação; sem folga de dias, não pega histórico) e não foram editados, ou (c) são "Pix enviado" da fila do Worker.
- Nunca entram: ajuste de saldo (categoria `0`, "Balance Correction") e investimentos (`mb:inv:`, ex.: "CDB - BANCO INTER S.A").
- Contador "N de T": N é a posição do item na ordem original; avança a cada Pular e volta a 1 na segunda volta.
- Chips "Ou escolha outra": só do tipo certo (despesa/receita), nunca a de ajuste; a categoria atual útil, depois as mais usadas em descrições parecidas (palavras do favorecido), depois as mais usadas no geral. Nenhum texto em inglês ("Balance Correction" sai "Ajuste de saldo" via `nomeDaCategoria`).
- Título: "Título: <texto do banco>" (ou o sugerido), com ícone de editar. Envio ao Santander, Pix recebido e salário continuam no cartão antigo (Para revisar).
- Pix enviado do Worker aparece uma vez só (no cartão novo) e conta uma vez no selo; Confirmar grava também a decisão `categoria` e a memória do destinatário (`mbResponderRevisao`).
- Nada é aplicado sem tocar em **Confirmar**. Chip, subcategoria, título, vínculo e Explicar só mudam a escolha mostrada ("Sua escolha" / "Sugestão da IA").
- Confirmar grava categoria, subcategoria, título (se houver), `objectiveLoanFk` (empréstimo) ou `objectiveFk` (meta) com `dateTimeModified` = agora; a categoria sobe como ajuste no sync normal; o padrão do favorecido vai para `ia_padroes` e vira exemplo para a IA e sugestão sem IA.
- Estado da IA sempre visível no cartão: "Sugestão da IA" com "NN% · confiante/na dúvida"; enquanto pede, "Pedindo sugestão à IA…"; IA respondeu sem nada para o item, "A IA não teve sugestão para este."; sem pareamento, sem internet, 401, timeout, Worker sem `/api/ia/*` ou resposta `ia: false` (modelo com erro), "Sem IA agora: sugestões pelos seus padrões."
- Worker: `MODELO` precisa estar no catálogo atual do Workers AI e na lista de JSON mode (o `@cf/meta/llama-3.1-8b-instruct` saiu do catálogo e toda chamada falhava em silêncio). Erro do modelo responde `ia: false`.
- A IA só pode sugerir pk que existe nas opções do aparelho (categoria útil, sub da mesma categoria, empréstimo/meta não arquivado) e nunca categoria de receita para saída de dinheiro; pergunta só com confiança < 0,7.

## Passos
1. GitHub Actions ("Checks do PR"): `flutter test test/mb_classificar_test.dart test/pendencias_test.dart test/mb_revisao_test.dart` passam; prints `pendencias_ia_{claro,escuro}.png` no artefato "prints" (cartão com valor, pergunta da IA, Família, Empréstimo: Mãe, Confirmar, chips e Explicar). Não rode Flutter no PC local.
2. Worker: em `meu-banco/apps/worker`, `node --test test/ia.test.mjs` (sem deploy). Para confirmar o modelo: a página `https://developers.cloudflare.com/workers-ai/models/<modelo>/` precisa existir e o modelo estar em `features/json-mode`. Depois do deploy, `pnpm logs` (wrangler tail) mostra "IA indisponível: …" se o modelo falhar.
3. No aparelho (celular pareado, Worker já com o binding AI publicado):
   - Aba Pendências mostra "Para classificar" com "1 de N"; Pular → "2 de N"; o selo soma esses itens. Nenhum CDB/ajuste de saldo na fila; nenhum lançamento antigo já com categoria útil.
   - Role até o fim: o "Pular" fica acima da faixa da versão, com folga.
   - Uma compra num cabeleireiro: chips sem "Balance Correction"/"Ajuste de saldo", com as categorias de compras parecidas primeiro.
   - Um Pix para alguém: aparece "Sugestão da IA" e, na dúvida, a pergunta (ex.: "Esse Pix de R$ 500 para Fabiana foi empréstimo para a Mãe?").
   - Toque num chip: a caixa vira "Sua escolha" com as subcategorias; toque numa sub, em "Título" e em "Vincular"; Confirmar → o item sai da fila e a transação muda em Transações (categoria › sub, título, vínculo).
   - Explicar: digite "almoço com cliente" e envie → aparece o entendimento para confirmar; nada muda até Confirmar.
   - Modo avião: abra a aba → aviso discreto "Sem IA agora…"; um favorecido já confirmado aparece com "Como você já respondeu".
   - No outro aparelho, após sincronizar, a categoria confirmada aparece (ajuste); título, sub e vínculo são locais deste aparelho.
4. Claro e escuro, fonte grande do sistema: nada estourado, botões com 44 px de altura, leitor de tela lê a pergunta (liveRegion) e os chips como botões.
