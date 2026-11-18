// test/push.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { jwtVapid } from "../src/push.js";

test("JWT VAPID ES256 válido para a chave pública", async () => {
  const par = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", par.privateKey);
  const jwt = await jwtVapid("https://fcm.googleapis.com", "https://exemplo.dev", jwk, 1_800_000_000);
  const [h, p, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { typ: "JWT", alg: "ES256" });
  const corpo = JSON.parse(Buffer.from(p, "base64url"));
  assert.equal(corpo.aud, "https://fcm.googleapis.com");
  assert.equal(corpo.exp, 1_800_000_000 + 12 * 3600);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, par.publicKey, Buffer.from(s, "base64url"), new TextEncoder().encode(`${h}.${p}`));
  assert.equal(ok, true);
});
