"use strict";
// Service worker do Meu Banco. Troque VERSAO (o "pnpm push" faz isso) para renovar o cache do shell.
const VERSAO = "v0.0.66";
const SHELL = "shell-" + VERSAO;
const DADOS = "dados-" + VERSAO;
const ARQUIVOS = ["/", "/login", "/regras.js", "/manifest.webmanifest", "/icons/icon-192.png", "/icons/icon-512.png", "/apple-touch-icon.png"];
const ROTAS_DADOS = /^\/api\/(dados|historico|fatura|ciclo)$/;

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
  if (req.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/app/")) return;
  if (ROTAS_DADOS.test(url.pathname)) e.respondWith(redePrimeiro(e, DADOS));
  else if (!url.pathname.startsWith("/api/")) e.respondWith(redePrimeiro(e, SHELL));
});

// Push sem conteúdo: busca os alertas com o cookie da sessão. Sem sessão ou sem rede, mostra um aviso genérico.
self.addEventListener("push", (e) => e.waitUntil(mostrarAlertas()));
async function mostrarAlertas() {
  let lista = [];
  try {
    const r = await fetch("/api/notificacoes/entregar", { method: "POST" });
    if (r.ok) lista = (await r.json()).notificacoes || [];
  } catch {}
  const icone = "/icons/icon-192.png";
  if (!lista.length) return self.registration.showNotification("Meu Banco", { body: "Você tem alertas novos. Abra o app para ver.", icon: icone, tag: "meu-banco" });
  // Vários alertas de uma vez (o que ficou retido no silêncio, por exemplo): uma notificação só, para não virar enxurrada.
  if (lista.length > 1) return self.registration.showNotification(`${lista.length} alertas do Meu Banco`, { body: lista.map((n) => n.titulo).join("\n"), icon: icone, tag: "meu-banco-lote", data: { url: destino(lista) } });
  const [n] = lista;
  await self.registration.showNotification(n.titulo, { body: n.corpo, icon: icone, tag: n.chave, data: { url: destino(lista) } });
}
// "Para revisar" e conexão caída pedem ação na Início do app web (/app/); o resto abre o painel.
const destino = (lista) => (lista.some((n) => /^(revisar|conexao):/.test(n.chave)) ? "/app/" : "/");
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = e.notification.data?.url || "/";
  e.waitUntil(self.clients.matchAll({ type: "window" }).then((ws) => (ws[0] ? ws[0].navigate(url).then((c) => (c || ws[0]).focus()) : self.clients.openWindow(url))));
});
