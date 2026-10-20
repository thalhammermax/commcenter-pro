const CACHE = "commcenter-pro-v0.19.0";
const CORE = ["/", "/manifest.webmanifest"];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(CORE)));
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  // Drop every previous cache version so stale bundles never load after a deploy.
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return;

  const requestUrl = new URL(event.request.url);

  // Only cache CommCenter's own application shell/static assets.
  // Supabase REST/Realtime/Storage and every other cross-origin request must
  // always go directly to the network so CAD operational data can never be
  // satisfied from a service-worker cache.
  if (requestUrl.origin !== self.location.origin) return;

  // Vite emits content-hashed, immutable files under /assets/. Serve them
  // cache-first: a field phone on a weak cellular link should never re-download
  // a bundle it already has.
  if (requestUrl.pathname.startsWith("/assets/")) {
    event.respondWith(
      caches.match(event.request).then(cached => cached || fetch(event.request).then(response => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE).then(cache => cache.put(event.request, copy));
        }
        return response;
      }))
    );
    return;
  }

  // Everything else (index.html, manifest, the worker itself) is network-first
  // so a deploy is picked up immediately, with the cache as the offline fallback.
  event.respondWith(
    fetch(event.request)
      .then(response => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE).then(cache => cache.put(event.request, copy));
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
