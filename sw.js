// OpsFlow service worker: primero intenta internet (siempre la version nueva),
// si no hay conexion usa la copia guardada.
// Solo guarda archivos de la propia app: nunca respuestas de Supabase ni de otros
// servidores, para que los datos de las personas no queden copiados en el telefono.
const CACHE = 'opsflow-v2';
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
    fetch(e.request)
      .then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; })
      .catch(() => caches.match(e.request))
  );
});
