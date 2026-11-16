# Nova Início e aba Pendências — brief

## Objetivo
Refazer a tela Início para responder em 2 segundos "quanto posso gastar neste ciclo". As pendências saem da Início e ganham uma aba própria, em formato de triagem. Gráficos e patrimônio vão para Orçamentos.

## Decisões (grilling de 13/11/2026)

### Início (celular primeiro)
- Base: `lib/pages/homePage/inicioEditorial.dart`, que passa a ser a Início real no lugar da `HomePage` de seções.
- Layout fixo, sem personalização. Bloco sem dados some. O acesso a "Editar Início" é desligado.
- Topo: só o ciclo (ex.: "Ciclo 06/11 – 05/12") e a saudação. Saem os botões Atualizar e menu; puxar a tela atualiza.
- Cartão de saldo (único bloco pesado):
  - Número grande: restante do orçamento do ciclo (limite − gasto).
  - Barra do ciclo, "Gasto R$ X de R$ Y · faltam N dias", "Pode gastar R$ Z/dia" e o saldo das contas em texto menor.
  - Sem limite definido: mostra o saldo das contas bancárias e um link discreto "Definir limite do ciclo".
  - Estouro: "R$ N acima do limite" em terracota, barra cheia, sem ritmo diário.
  - Toque: abre o orçamento padrão do ciclo.
- Abaixo do cartão, nesta ordem:
  1. Metas e empréstimos: até 3 linhas com barra fina e valor, "Ver todas" se houver mais; some sem nada em aberto.
  2. Contas e cartões em dois grupos: Contas (nome e saldo) e Cartões (fatura atual e uso do limite em barra fina). Toque abre o detalhe.
- Fora da Início: últimas transações, gráficos (linha, pizza, mapa de calor), patrimônio, Para revisar e conexão caída.
- Carregamento: mostra os valores da última sincronização na hora e uma linha de progresso fina no topo enquanto atualiza. Loader central só no primeiro uso, sem dados salvos.
- Movimento só funcional: o número conta ao mudar de valor, a barra desliza até o novo ponto e o toque encolhe para 0,97 (160 ms, ease-out). Sem animação de entrada. Com "reduzir movimento", só opacidade.

### Aba Pendências
- 5ª aba: Início · Transações · Pendências · Orçamentos · Mais. Selo com o número de itens; some quando zera.
- Conteúdo: Banco desconectado (com "Reconectar") e Para revisar.
- Triagem de um item por vez: cartão grande com Confirmar, Trocar categoria e Pular. Deslizar para a direita confirma e para a esquerda pula; dispensa por distância ou por velocidade (> ~0,11 px/ms). Ao arrastar, o cartão captura o ponteiro e ignora um segundo toque.
- Estado vazio: "Tudo em dia".

### Análise
- Orçamentos vira "Orçamentos e análise": gráficos e patrimônio no topo, orçamentos abaixo. Sem aba nova.

## Etapas (uma PR cada)
1. Nova Início no celular.
2. Aba Pendências com triagem.
3. Gráficos e patrimônio em Orçamentos.
4. Versão para computador (`PainelDesktop`).
5. Remover a `HomePage` antiga, as seções sem uso e `EditHomePage`.

As etapas 1 e 2 saem juntas no mesmo build publicado, para que Para revisar e conexão caída não fiquem sem lugar.

## Contexto técnico
- Hoje a navegação abre `HomePage` (`lib/widgets/navigationFramework.dart`, índice 0), com 19 seções em `homePage.dart`.
- `ModeloInicio` (`lib/struct/mbSync/estadoInicio.dart`) já tem `disponivel` (saldo das contas bancárias), `consumido`, `limite` e `percentual`.
- Tokens e textos da tela editorial: `lib/struct/editorial.dart` (`EditorialCores`, `EdTexto`, `CartaoEscuro`, `ContagemValor`).
- Para revisar e conexão caída já existem em `homePageParaRevisar.dart` e `homePageConexaoCaida.dart`.

## Verificação
- `flutter analyze` sem erros novos; os testes existentes passam.
- Capturas de tela no web (`verificar-editorial-web`) em claro e escuro, com 390 e 1280 px de largura.
- Cenários: ciclo no meio (restante > 0); gasto acima do limite; sem limite definido; sem metas nem empréstimos (o bloco some); só contas, sem cartão; primeiro uso sem dados (loader central); dados salvos com atualização em curso (linha fina).
- Bordas: R$ 1.234.567,89 sem quebrar; nome de conta longo com reticências; último dia do ciclo (faltam 0 dias, sem divisão por zero no ritmo diário); "reduzir movimento" ligado.
- Pendências: selo com contador correto e sumindo em zero; deslizar rápido curto confirma; um segundo dedo durante o arraste não faz o cartão pular; estado "Tudo em dia".
- A versão do build no canto continua visível em todos os estados.
- `ux-audit` modo Fluxo na Início e na aba Pendências.

## Alinhamento elemento a elemento (16/11/2026)

- Topo: ciclo pequeno acima, só as datas ("26 out – 25 nov"), saudação grande abaixo.
- Cartão de saldo: escuro, rótulo "Para gastar no ciclo", ritmo diário em linha de texto, "Nas contas" pequeno no fim, centavos menores no número grande.
- Metas e empréstimos: nome, valor e barra fina; dois grupos com subtítulo ("Metas", "Empréstimos"), até 2 linhas cada; com um grupo só, ele vira o título; sem nada, o bloco some.
- Contas: cartões saem da Início por enquanto; uma linha por banco (poupanças agrupadas); tocar abre as transações das carteiras com o mesmo nome (sem correspondência, abre o Meu Banco).
- Barra de abas: contador de Pendências em bolinha com número (etapa 2); rótulo só na aba ativa; a aba continua "Orçamentos".
- Densidade compacta: menos espaço entre blocos e linhas mais baixas.
