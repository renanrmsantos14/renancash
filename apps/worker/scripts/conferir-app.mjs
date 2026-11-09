// Confere se o build web do app (Flutter) está em public/app antes do deploy.
import { existsSync } from "node:fs";

const indice = new URL("../public/app/index.html", import.meta.url);
if (!existsSync(indice)) {
  console.error("Gere o app web: no meu-cashew, scripts/compilar.sh web <...>/apps/worker/public/app");
  process.exit(1);
}
