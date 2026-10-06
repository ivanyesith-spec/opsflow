// OpsFlow service worker: primero intenta internet (siempre la version nueva),
// si no hay conexion usa la copia guardada.
// Solo guarda archivos de la propia app: nunca respuestas de Supabase ni de otros
// servidores, para que los datos de las personas no queden copiados en el telefono.
const CACHE = 'opsflow-v4';
const APP = ['./', './index.html', './demo.html', './manifest.json', './icon-192.png', './icon-512.png'];
self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(APP)));
});
self.addEventListener('activate', e => e.waitUntil(
  caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim())
));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  if (new URL(e.request.url).origin !== self.location.origin) return;
  e.respondWith(
    // Siempre preguntar a GitHub si hay version nueva (sin esperar a la cache del navegador)
    fetch(e.request.mode === 'navigate' ? new Request(e.request.url, { cache: 'no-cache', credentials: 'same-origin' }) : e.request, e.request.mode === 'navigate' ? undefined : { cache: 'no-cache' })
      .then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request))
  );
});

// Avisos: mostrar la notificacion aunque la app este cerrada, y avisar a la app si esta abierta
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: 'OpsFlow', body: e.data ? e.data.text() : '' }; }
  const url = new URL(d.url || './', self.registration.scope).href;
  e.waitUntil(Promise.all([
    self.registration.showNotification(d.title || 'OpsFlow', {
      body: d.body || '', tag: d.tag || undefined, renotify: true,
      icon: 'icon-192.png', badge: 'icon-192.png', vibrate: [200, 100, 200], data: { url },
    }),
    self.clients.matchAll({ type: 'window', includeUncontrolled: true })
      .then(cs => cs.forEach(c => c.postMessage({ tipo: 'aviso' }))),
  ]));
});
// Al tocar el aviso: abrir la app en la pantalla que toca
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || self.registration.scope;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    const c = cs.find(x => x.url.startsWith(self.registration.scope));
    if (c) return c.focus().then(w => (w || c).navigate ? (w || c).navigate(url) : null).catch(() => self.clients.openWindow(url));
    return self.clients.openWindow(url);
  }));
});
