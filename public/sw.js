"use strict";
// Service worker do Meu Banco. Troque VERSAO (o "pnpm push" faz isso) para renovar o cache do shell.
const VERSAO = "v0.0.4";
const SHELL = "shell-" + VERSAO;
const DADOS = "dados-" + VERSAO;
const ARQUIVOS = ["/", "/login", "/manifest.webmanifest", "/icons/icon-192.png", "/icons/icon-512.png", "/apple-touch-icon.png"];
const ROTAS_DADOS = /^\/api\/(dados|historico|fatura)$/;

self.addEventListener("install", (e) => {
  // Cada arquivo é opcional: "/" sem sessão redireciona para o login e não deve ser guardado.
  e.waitUntil(
    caches.open(SHELL).then((c) =>
      Promise.all(ARQUIVOS.map((u) => fetch(u).then((r) => (r.ok && !r.redirected ? c.put(u, r) : null)).catch(() => null)))
    ).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((nomes) => Promise.all(nomes.filter((n) => n !== SHELL && n !== DADOS).map((n) => caches.delete(n))))
      .then(() => self.clients.claim())
  );
});

// Guarda a cópia com a hora em x-cache-em. 401 = sessão encerrada: apaga os dados guardados.
async function guardar(req, r, nomeCache) {
  if (r.status === 401) return caches.delete(nomeCache);
  if (!r.ok || r.redirected) return;
  const h = new Headers(r.headers);
  h.set("x-cache-em", new Date().toISOString());
  const cache = await caches.open(nomeCache);
  await cache.put(req.url, new Response(await r.blob(), { status: r.status, headers: h }));
}

// Network-first: a rede manda; o cache só entra quando ela falha. A gravação no cache não atrasa a resposta.
async function redePrimeiro(e, nomeCache) {
  const req = e.request;
  try {
    const r = await fetch(req);
    e.waitUntil(guardar(req, r.clone(), nomeCache).catch(() => {}));
    return r;
  } catch (erro) {
    const guardada = await caches.match(req.url, { cacheName: nomeCache });
    if (guardada) return guardada;
    throw erro;
  }
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== location.origin) return;
  if (ROTAS_DADOS.test(url.pathname)) e.respondWith(redePrimeiro(e, DADOS));
  else if (!url.pathname.startsWith("/api/")) e.respondWith(redePrimeiro(e, SHELL));
});
