/* NEXORA PWA service worker — network-first; live commerce data is never cached. */
const NEXORA_SCOPE = "/Mongolia-market/";
self.addEventListener("install", event => {
  self.skipWaiting();
});
self.addEventListener("activate", event => {
  event.waitUntil(self.clients.claim());
});
self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (request.mode === "navigate" && url.pathname.startsWith(NEXORA_SCOPE)) {
    event.respondWith(fetch(request));
  }
});
