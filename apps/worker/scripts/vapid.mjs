// scripts/vapid.mjs — gera as chaves VAPID. Uso:
//   node scripts/vapid.mjs vapid-publica.txt | npx wrangler secret put VAPID_PRIVADA
// A pública vai para o arquivo (copie para VAPID_PUBLICA no wrangler.toml); a privada só sai pelo pipe.
import { writeFileSync } from "node:fs";
const destino = process.argv[2];
if (!destino) { console.error("Informe o arquivo da chave pública."); process.exit(1); }
const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
writeFileSync(destino, Buffer.from(await crypto.subtle.exportKey("raw", par.publicKey)).toString("base64url"));
process.stdout.write(JSON.stringify(await crypto.subtle.exportKey("jwk", par.privateKey)));
