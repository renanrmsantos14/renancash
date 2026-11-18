---
name: verificar-atualizador
description: "Verifica o atualizador do app (Android): busca da Release no GitHub, SHA-256 do APK, timeout de inatividade no download, recusa de Release sem hash e de versão instalada ilegível, e o workflow que publica o .sha256. Use após mudar budget/lib/struct/atualizador.dart, budget/test/atualizador_test.dart ou o job apk de .github/workflows/release-android.yml."
---
# Verificar Atualizador

## Cobre
- `budget/lib/struct/atualizador.dart`: `atualizadorInterpretarRelease` (puro: tag mais nova, APK, `.sha256`, URL confiável, tamanho), `atualizadorProcurar`, `atualizadorBaixarVerificado` (hash esperado → download com timeout de inatividade → tamanho → SHA-256 → apaga em qualquer falha), `atualizadorBaixarEInstalar` (diálogo de progresso sempre fechado no `finally`).
- `.github/workflows/release-android.yml` (job `apk`): publica `renancash-<versão>.apk` e `renancash-<versão>.apk.sha256` (saída do `sha256sum`: `<64 hex>  <nome>`).
- Testes: `budget/test/atualizador_test.dart` (cliente HTTP falso `MockClient`).

## Regras que precisam valer
- O app só abre o instalador se o SHA-256 do arquivo baixado for igual ao do `.sha256` da mesma Release. Hash diferente, 404, ilegível ou ausente: apaga o APK, mostra erro em pt-BR e não instala.
- Release sem `.sha256` (todas as anteriores a este recurso) é recusada com "baixe manualmente na página de Releases". Só a Release nova decide: do app antigo para a primeira Release com hash a atualização funciona normalmente.
- 30 s sem receber bytes (`inatividade`) encerram o download com "O download parou…"; o diálogo fecha e o arquivo parcial é apagado.
- Build instalado ilegível (`buildNumber` ≤ 0) nunca vira atualização nem permite instalar/downgrade.
- Limite conhecido: o hash vem da mesma Release do APK; protege de download corrompido ou CDN adulterado, não de quem controla a Release. A assinatura do APK pelo Android continua sendo a barreira final.

## Roteiro
1. GitHub Actions ("Checks do PR"): `flutter test test/atualizador_test.dart` passa (hash certo, errado, ausente, stream parado, tamanho errado, URL ruim, build 0, sem downgrade). Não rode Flutter no PC local.
2. Após o merge, na Release gerada pelo workflow: os assets têm o `.apk` e o `.apk.sha256`; `curl -sL <url do .sha256>` mostra `<hash>  renancash-<versão>.apk` e `sha256sum` do APK baixado bate.
3. No aparelho (versão anterior com a verificação): Configurações › procurar atualização → "Nova versão" → Atualizar → barra de progresso → instalador. Modo avião no meio do download: em até 30 s aparece "Falha ao baixar a atualização" e o diálogo fecha.
