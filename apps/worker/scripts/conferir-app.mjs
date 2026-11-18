// Confere se o build web do app (Flutter) está em public/app antes do deploy.
import { existsSync } from "node:fs";

const indice = new URL("../public/app/index.html", import.meta.url);
if (!existsSync(indice)) {
  console.error("Gere o app web: na raiz do repositório, scripts/compilar.sh web "$PWD/apps/worker/public/app"");
  process.exit(1);
}
