// Explicit shell allowlist. Health API responses and session credentials NEVER
// enter CacheStorage, even while a user is signed in.
const CACHE = "opencircuit-shell-v2";
const SHELL = [
  "/",
  "/index.html",
  "/app.css",
  "/app.js",
  "/model.mjs",
  "/app.webmanifest",
  "/icon-192.png",
  "/icon-512.png",
  "/apple-touch-icon.png",
];
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) =>
        cache.addAll(
          SHELL.map((url) => new Request(url, { credentials: "omit" })),
        ),
      )
      .then(() => self.skipWaiting()),
  );
});
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter(
              (key) => key.startsWith("opencircuit-shell-") && key !== CACHE,
            )
            .map((key) => caches.delete(key)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (
    event.request.method !== "GET" ||
    url.origin !== self.location.origin ||
    url.search ||
    !SHELL.includes(url.pathname)
  )
    return;
  event.respondWith(
    fetch(new Request(url.href, { credentials: "omit", cache: "no-store" }))
      .then((response) => {
        if (response.ok)
          event.waitUntil(
            caches
              .open(CACHE)
              .then((cache) => cache.put(url.pathname, response.clone())),
          );
        return response;
      })
      .catch(() => caches.match(url.pathname)),
  );
});
