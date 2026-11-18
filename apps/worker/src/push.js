// src/push.js — Web Push sem conteúdo: só o JWT VAPID (RFC 8292). O service worker busca o texto em /api/notificacoes/entregar.
import { base64url } from "./app.js";

const parte = (obj) => base64url(new TextEncoder().encode(JSON.stringify(obj)));

export async function jwtVapid(audiencia, assunto, jwkPrivada, agoraS) {
  const chave = await crypto.subtle.importKey("jwk", jwkPrivada, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const corpo = `${parte({ typ: "JWT", alg: "ES256" })}.${parte({ aud: audiencia, exp: agoraS + 12 * 3600, sub: assunto })}`;
  const assinatura = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, chave, new TextEncoder().encode(corpo));
  return `${corpo}.${base64url(new Uint8Array(assinatura))}`;
}

export async function enviarPush(endpoint, env) {
  const jwt = await jwtVapid(new URL(endpoint).origin, env.VAPID_ASSUNTO, JSON.parse(env.VAPID_PRIVADA), Math.floor(Date.now() / 1000));
  const r = await fetch(endpoint, { method: "POST", headers: { TTL: "86400", Urgency: "normal", Authorization: `vapid t=${jwt}, k=${env.VAPID_PUBLICA}` } });
  await r.body?.cancel();
  return r.status;
}
