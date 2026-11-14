// Service worker minimal : réseau d'abord, copie en cache en secours (démarrage hors connexion).
var CACHE = 'prieres-v1';

self.addEventListener('install', function (e) {
  e.waitUntil(
    caches.open(CACHE)
      .then(function (c) { return c.addAll(['./', 'index.html', 'icon-180.png']); })
      .then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys()
      .then(function (ks) {
        return Promise.all(ks.filter(function (k) { return k !== CACHE; })
                             .map(function (k) { return caches.delete(k); }));
      })
      .then(function () { return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function (e) {
  var r = e.request;
  // On ne gère que les fichiers de l'application ; les appels aux services météo/horaires passent directement.
  if (r.method !== 'GET' || new URL(r.url).origin !== self.location.origin) { return; }
  e.respondWith(
    fetch(r).then(function (resp) {
      var copie = resp.clone();
      caches.open(CACHE).then(function (c) { c.put(r, copie); });
      return resp;
    }).catch(function () {
      return caches.match(r).then(function (m) { return m || caches.match('index.html'); });
    })
  );
});
