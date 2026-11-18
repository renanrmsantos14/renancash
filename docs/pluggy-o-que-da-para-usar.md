# Pluggy: o que a API entrega e o que o RenanCash usa

Levantamento de 18/11/2026. Os nomes dos campos vêm das definições de tipos do SDK oficial (`pluggy-sdk` 0.94.3, `dist/types/*.d.ts`), que espelham a API. Nesta sessão não foi possível abrir docs.pluggy.ai (rede bloqueada). O que depende do comportamento de cada banco está marcado **[confirmar no primeiro sync real]**.

## O que é lido e onde aparece

| Produto e campos | No Worker | No app |
|---|---|---|
| `GET /items/{id}`: `status`, `nextAutoSyncAt`, `consentExpiresAt` | Colunas `pluggy_items.proximo_sync` e `consentimento_expira`. Alerta quando faltam 7 dias ou menos para o consentimento vencer | Contas conectadas: "O banco atualiza de novo às HH:mm" e aviso nos últimos 15 dias do consentimento |
| `GET /identity`: `document` | Fica só em memória durante a sincronização e não é guardado. Serve para calcular `entre_minhas` | — |
| `GET /accounts`: `creditData.minimumPayment`; `bankData.overdraftContractedLimit`, `overdraftUsedLimit`, `automaticallyInvestedBalance` | Colunas `minimum_payment`, `overdraft_limit`, `overdraft_used`, `auto_invested` | Início: mínimo da fatura, cheque especial em uso (linha destacada) e saldo aplicado automaticamente (só informativo, fora do total) |
| `GET /v2/transactions`: `paymentData` (`payer`, `receiver`, `paymentMethod`) | Colunas `contraparte` e `metodo`. `entre_minhas` = 1 quando o documento da outra ponta é o do titular | Detalhe: "Pix para Maria Souza". Quando `entre_minhas` = 1, o lançamento não conta como gasto nem vai para a fila |
| `GET /v2/transactions`: `creditCardMetadata.billId`, `billForecastDate`, `otherCreditsType`, `feeType` | Colunas `bill_id`, `bill_month` e `tipo_credito`. Alerta para rotativo, fatura parcelada e anuidade | Detalhe: a fatura em que a compra cai ("Dezembro de 2026") |
| `GET /bills`: `payments[]`, `financeCharges[]`, `minimumPaymentAmount` | Situação da fatura (`PAID`, `PARTIAL`, `CLOSED`), `pago`, `encargos`, `minimo` | O painel mostra "Paga" e "Paga em parte" |
| `GET /investments`: `amountOriginal`, `amountProfit`, `balance`, `taxes`/`taxes2`, `rate`/`rateType`/`fixedAnnualRate`, rentabilidades, `dueDate`, `purchaseDate`, `issuer` | Campos extras em `investimentos`. O retrato mensal também guarda o aplicado | Investimentos: "Você investiu" e "Rendeu"; aplicado, taxa e vencimento de cada aplicação; rendimento de cada mês sem contar aportes e resgates |
| `GET /investments/{id}/transactions` (`BUY`/`SELL`) | Só quando falta `amountOriginal`, em até 20 investimentos por conexão: aplicado = compras − resgates | O mesmo de cima |
| `GET /loans` | Snapshot `emprestimos:<conexão>` e alerta de parcela atrasada | Contas conectadas: saldo devedor, parcelas pagas, taxa e atrasadas |
| Webhook `transactions/deleted` | Apaga as transações e grava os ids em `transacoes_removidas`. O pull manda esses ids em `removidas` | A transação apagada no banco some do app |

Os webhooks `transactions/created` e `transactions/updated` são ignorados de propósito: chegam junto com `item/updated`, que já dispara a sincronização.

## O que conferir no primeiro sync real

- **Investimentos:** se o Inter e o Santander mandam `amountOriginal`. Os conectores Open Finance costumam mandar `amountProfit` e as rentabilidades como null. Se `amountOriginal` também vier null, o aplicado sai das movimentações. Depois de um resgate parcial, esse valor fica abaixo do real, porque o resgate inclui o rendimento.
- **Faturas:** se `payments[]` vem preenchido. Se vier vazio, a fatura continua aparecendo como "Fechada".
- **Identidade:** se o `/identity` está liberado na conexão e se o CPF da outra ponta chega completo. Mascarado, `entre_minhas` fica null e nada muda.
- **Outros campos:** `billForecastDate`, `otherCreditsType` e `feeType` são, segundo o SDK, "só Open Finance".

## Deploy

As colunas novas entram no D1 com `pnpm --filter @meu-banco/worker migrar -- --remote`. O passo é idempotente e o `deploy.yml` já o roda antes de publicar. Os apps antigos ignoram os campos novos.
