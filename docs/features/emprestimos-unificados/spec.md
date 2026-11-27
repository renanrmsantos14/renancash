# Empréstimos unificados — spec (v2, após revisão adversarial Opus)

**Problema.** Dois modelos de empréstimo convivem. O **antigo** (objetivo do Cashew `type=1` + lançamentos com `objective_loan_fk`) não aparece na tela Empréstimos nem no "Emprestado em aberto". O **novo** (decisões `emprestimo`/`devolucao`/`perdao` em `mb_revisoes`) alimenta a tela e a soma. Falta uma migração antigo→novo, reversível, acionada só pelo Renan.

## Mapeamento (por objetivo antigo `income=1` = "emprestei")
- Lançamento ligado e pago: despesa → decisão `emprestimo`; receita → decisão `devolucao`. Tipo pelo sinal do `amount` (Cashew); `income` divergente do sinal → "revisar". Data = dia em America/Sao_Paulo (`dia()` do espelho).
- `tx_id` **sintético** `mig:<obj>:<tx>` (id real faria o app apagar a transação antiga). Transações antigas **não são tocadas**; a linha do objetivo também não.
- Grupo (`emprestimo_id`) = `tx_id` do 1º empréstimo do objetivo (por data, depois pk): convenção do app, e o perdão acha a pessoa pelo grupo.
- `pessoa` = nome do objetivo; vazio → omitida (a tela já mostra "Sem pessoa"). A prévia permite corrigir a pessoa por objetivo (`pessoas{obj}`), e ela entra na assinatura.
- **Não mapeável** (prévia, com motivo): `devo`, valor fixo, sem lançamentos, lançamento não pago, sem data, arquivado com saldo (revisar), id real do lançamento que já tem decisão `emprestimo`/`devolucao` (evita dupla contagem), saldo ≤ 0.
- Devolução anterior ao 1º empréstimo (o app a descartaria): por padrão **fica como diferença explicada**; opção explícita por objetivo `ajustarAnteriores` data a devolução no dia do 1º empréstimo (guarda `data_original` na decisão).

## Prévia (leitura pura)
Por objetivo: pessoa, original, pago, saldo antigo, saldo novo, nº de lançamentos, status (`pronto`, `migrado`, `desatualizado`, `revisar`, `nao_mapeavel`), motivos, e diferença `saldo antigo − saldo novo` listada **por lançamento**. Totais: `antes` = "Emprestado em aberto" hoje (só modelo novo); `depois` = `antes` + Σ saldo novo dos migrados; Σ saldo antigo − Σ saldo novo = Σ diferenças listadas (centavos inteiros, por lançamento). `assinatura` = hash só do que a migração lê: objetivos `type=1`, lançamentos ligados, decisões `mig:` e `tx:` dos ids ligados (decisões alheias da IA/fila não geram 409).
- **Status vem das decisões vivas** no espelho, não da tabela: `migrado` = há decisões `mig:<obj>:*`; `desatualizado` = o plano de hoje difere do gravado (lançamento antigo mudou/apagado depois). A tabela D1 `emprestimos_migracao` é só histórico/auditoria (e sinaliza "inconsistente" se diz migrado e as decisões sumiram, ex.: novo semeio do celular).

## Aplicar e desfazer
- `GET /api/emprestimos/migracao` · `POST .../aplicar {objetivos[], assinatura, pessoas?, ajustarAnteriores?}` · `POST .../desfazer {objetivo}`. Aparelho ou sessão (POST: mesma origem). Corpo ≤ 64 KB.
- Aplicar: `assinatura` igual (senão 409 + prévia nova); idempotente por objetivo; grava as decisões via `gravar` (LWW, ts crescente); registra na tabela: objetivo, pks, saldo antigo/novo, `antes`/`depois`, datas, pessoa gravada.
- Desfazer: tombstone das decisões `mig:<obj>:*`. **Bloqueia** (409 com motivo) se outra decisão/perdão referencia `mig:<obj>` (`emprestimo_id`, `sobra_id`, `perdao:`) ou se remover muda o saldo de **qualquer outro** empréstimo (simula o cálculo antes/depois: pega devolução FIFO antiga). Histórico antigo nunca é apagado.
- O app chama só por toque do Renan, com confirmação (por empréstimo ou em lote).

## Fora do escopo
Nada em PROD nesta entrega; `devo`/valor fixo; aposentar a tela antiga. Alternativa descartada: derivar em tempo de leitura sem gravar (sem desfazer/LWW), porque o pedido exige aplicar e desfazer explícitos e o app (Dart) teria de ser a única fonte do cálculo.
