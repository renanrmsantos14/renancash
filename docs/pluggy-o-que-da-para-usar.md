# Pluggy: o que a API entrega e o que o RenanCash ainda não usa

Levantamento de 18/11/2026. Os nomes dos campos vêm das definições de tipos do SDK oficial (`pluggy-sdk` 0.94.3, `dist/types/*.d.ts`), que espelham a API. Nesta sessão não foi possível abrir docs.pluggy.ai (rede bloqueada). Por isso, o que depende de comportamento ou de cobertura por banco está marcado **[confirmar]**.

## Já usado

| Produto | Uso hoje |
|---|---|
| `GET /items/{id}`, webhooks `item/*` | Status da conexão e aviso de reconexão |
| `GET /accounts` | Saldo, `creditData` (limite, vencimento, fechamento) e `bankData.closingBalance` da poupança |
| `GET /v2/transactions` | Lançamentos, `creditCardMetadata` (parcela n/total) e `merchant` |
| `GET /bills` | Faturas fechadas: `dueDate`, `totalAmount` e `minimumPaymentAmount` |
| `GET /investments` | Saldo e, desde esta mudança, `amountOriginal`, `amountProfit`, `balance`, `taxes`/`taxes2`, `rate`/`rateType`/`fixedAnnualRate`, `lastMonthRate`, `lastTwelveMonthsRate`, `dueDate`, `purchaseDate`/`issueDate`, `issuer`, `subtype` e `taxExempt` |

## Ainda não usado, por valor para o app

1. **Movimentações dos investimentos: `GET /investments/{id}/transactions`.** Cada movimentação traz:
   - `type`: `BUY`, `SELL`, `TAX` ou `TRANSFER`.
   - `amount`, `netAmount`, `date`, `tradeDate`.
   - `expenses.incomeTax`, o IR retido.

   Serve de reserva quando o banco não manda `amountOriginal`: o investido é a soma dos `BUY` menos a dos `SELL`. Também permite mostrar "aportes e resgates do mês" com os valores exatos, sem estimar pela série mensal. O custo é uma chamada por aplicação a cada sincronização. **[confirmar]** Pelo que se lê na documentação, os conectores Open Finance mandam `amountProfit`, `annualRate`, `lastMonthRate` e `lastTwelveMonthsRate` como null. Se `amountOriginal` também vier null no Inter ou no Santander, este é o próximo passo.
2. **Fatura de cada compra: `creditCardMetadata.billId`, `billForecastDate` (AAAA-MM) e `billPostDate`.** Ligam cada compra à fatura certa, inclusive as pendentes e as futuras. Assim a fatura deixa de ser estimada pela data de fechamento. `paymentType` (`SINGLE` ou `INSTALLMENT`) e `totalAmount` dão o valor total da compra parcelada.
3. **Detalhe da fatura: `financeCharges[]` e `payments[]` em `/bills`.**
   - `financeCharges[]` traz juros, multa e IOF.
   - `payments[]` traz `valueType`, `paymentDate` e `amount`, e mostra se a fatura foi paga, total ou parcialmente. Hoje toda fatura aparece como "Fechada" porque o app não usa esse dado.
   - `otherCreditsType=BILL_INSTALLMENT` e `REVOLVING_CREDIT` mostram fatura parcelada e uso do rotativo, o que pede alerta.
   - `feeType=ANNUAL_FEE` identifica a anuidade.
4. **Pix e transferências: `paymentData` (`payer`, `receiver`, `paymentMethod`, `reason`).** Trazem nome e documento de quem pagou ou recebeu. Ajudam a classificar "Pix para pessoa", reembolso e rachar conta, que hoje dependem de ler a descrição. `receiver.documentNumber` e `merchant.cnpj` também ajudam a detectar assinaturas e recorrências; a API não tem um campo próprio de recorrência.
5. **Conta: `bankData.automaticallyInvestedBalance` e `reservedBalances[]`.** Mostram o saldo aplicado automaticamente e as "caixinhas", que hoje não aparecem no patrimônio. `overdraftContractedLimit` e `overdraftUsedLimit` mostram o uso do cheque especial. Em `creditData`, `minimumPayment` e `disaggregatedCreditLimits[]` trazem o pagamento mínimo da fatura aberta e os limites separados.
6. **Sincronização mais leve.**
   - Webhooks `transactions/created` (com `createdTransactionsLink`), `transactions/updated` e `transactions/deleted` (com `transactionIds[]`).
   - Filtro `createdAtFrom` em `/v2/transactions`.
   - Com eles, o Worker busca só o que mudou, em vez da janela inteira. `transactions/deleted` também resolve a pendente que some.
7. **Saúde da conexão: `item.nextAutoSyncAt`, `statusDetail.<produto>.isUpdated/lastUpdatedAt` e `consentExpiresAt`.** Permitem mostrar "o banco atualiza de novo às HH:mm" e avisar antes de o consentimento do Open Finance vencer.
8. **Empréstimos: `GET /loans`.** Traz parcelas pagas, a vencer e atrasadas, além das taxas. Só vale a pena se houver empréstimo bancário.
9. **Identidade: `GET /identity`.** Nome e documento do titular. Ajuda a reconhecer transferência entre as próprias contas (o `payer` ou `receiver` é o próprio titular).

## Próximos passos sugeridos

1. Depois do primeiro sync com esta versão, conferir no app quais aplicações mostram "Você investiu". Se faltar alguma, implementar o item 1 do levantamento.
2. Itens 2 e 3: ligar compra à fatura e saber se a fatura foi paga.
3. Item 4: usar `paymentData` na fila Para validar.
