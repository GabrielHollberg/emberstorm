// The web app's manifest, on a phone or tablet only. On a computer it is left
// out, so Chrome and Edge show no install button in the address bar: the
// web app installed beside the real installation confused things (the owner,
// 2026-10-12). A phone keeps it for adding to the home screen from the
// browser's menu, for those who look - nothing offers it.
if (window.matchMedia && matchMedia('(pointer: coarse)').matches && !/SoundStormTV\//.test(navigator.userAgent)) {
  var manifest = document.createElement('link');
  manifest.rel = 'manifest';
  manifest.href = '/manifest.webmanifest';
  document.head.appendChild(manifest);
}

// Register the service worker.
//
// A separate file rather than three lines inline in the shell, and that is
// forced rather than stylistic: the shell is served with script-src 'self',
// which blocks inline scripts outright. Inline, this registration was silently
// refused - the console said so, nothing else did, and "Add to Home Screen"
// simply produced a bookmark. Weakening the policy to 'unsafe-inline' was
// never an option; it is the thing stopping an EPUB running its own
// JavaScript against the session cookie.
//
// Loaded from the shell rather than from app.js so that a worker failing to
// register can never be the reason the app does not start.
//
// navigator.serviceWorker is undefined outside a secure context, so over plain
// http on a LAN address this quietly does nothing and EmberStorm works exactly
// as it did before. That is also why installing to a home screen from a phone
// needs the installer's --https. localhost counts as secure either way, which
// is why it works in development without it.
// Not inside the phone apps (their user agent says SoundStormApp/), and one
// registered there before is taken away: the apps keep their own copy of the
// page and open it offline themselves (Android's KeptFiles, the iPhone's
// KeptFiles.swift), and on Android the worker answered an offline page load
// before the app could - with its error page, the black screen the owner kept
// meeting with the internet off (2026-10-12). Downloads in web storage are
// not the worker's and stay.
if ('serviceWorker' in navigator && /SoundStormApp\//.test(navigator.userAgent)) {
  navigator.serviceWorker.getRegistrations().then(function (all) {
    all.forEach(function (r) { r.unregister(); });
  }).catch(function () {});
} else if ('serviceWorker' in navigator) {
  window.addEventListener('load', function () {
    navigator.serviceWorker.register('/sw.js').catch(function () {
      // Offline start-up is a nicety. Nothing else depends on it.
    });
  });
}
