// Downloads kept by a phone app (the contract in CLAUDE.md, "Downloads kept
// by the apps"), with a pretend app on the test server: the page hands a
// song to the app to keep, saves its list there, and - opened again with no
// connection - finds it from the app's list and plays it from the app's copy.
// The pretend app keeps what it is asked for in sessionStorage-backed lists
// and answers keptURL from a route that stands for its folder.
const { chromium } = require('playwright');
const BASE = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  const folder = new Map(); // path -> { body, type }
  // Offline, the page's own kept files answer at their own addresses, as
  // the Android app does (KeptFiles.intercept).
  let offlineShell = false;
  await context.route(BASE + '/**', async (route) => {
    const u = new URL(route.request().url());
    if (!offlineShell || u.pathname.startsWith('/__kept/')) return route.fallback();
    const f = folder.get(u.pathname + u.search);
    if (!f) return route.abort('internetdisconnected');
    return route.fulfill({ status: 200, body: f.body, headers: { 'Content-Type': f.type } });
  });
  // The app's folder: answered from what was kept, network or not.
  await context.route('**/__kept/**', async (route) => {
    const u = new URL(route.request().url());
    const key = u.pathname.replace('/__kept', '') + u.search;
    const f = folder.get(key);
    if (!f) return route.fulfill({ status: 404, body: 'not kept' });
    return route.fulfill({ status: 200, body: f.body, headers: { 'Content-Type': f.type } });
  });
  await context.exposeBinding('appFetch', async ({ page }, urls) => {
    const kept = [], failed = [];
    for (const url of urls) {
      const u = new URL(url, BASE);
      const key = u.pathname + u.search;
      const resp = await page.request.get(u.href);
      if (resp.ok()) { folder.set(key, { body: await resp.body(), type: resp.headers()['content-type'] }); kept.push(key); }
      else failed.push(key);
    }
    return { kept, failed };
  });
  await context.addInitScript(() => {
    const store = JSON.parse(sessionStorage.getItem('pretend-app') || '{"index":null,"urls":[],"log":[]}');
    const save = () => sessionStorage.setItem('pretend-app', JSON.stringify(store));
    window.soundstormApp = {
      version: 1, keeps: 1, keptIndex: store.index, keptURLs: store.urls,
      keep(cmd, data) {
        store.log.push(cmd); save();
        if (cmd === 'index') { store.index = data.index; save(); }
        if (cmd === 'shell') window.appFetch(data.urls);
        if (cmd === 'add') {
          window.appFetch(data.urls).then((r) => {
            for (const k of r.kept) if (!store.urls.includes(k)) store.urls.push(k);
            save();
            window.__soundstormKeep({ cmd: 'done', id: data.id, kept: r.kept, failed: r.failed });
          });
        }
      },
      keptURL: (a) => { const u = new URL(a, location.href); return location.origin + '/__kept' + u.pathname + u.search; },
    };
    window.webkit = { messageHandlers: { soundstorm: { postMessage: () => {} } } };
  });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(BASE + '/');
  await page.evaluate(() => fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'smoke', password: 'smoke test password 4417' }) }));
  await page.goto(BASE + '/');
  await page.waitForFunction(() => typeof download === 'function' && state.me);
  const song = await page.evaluate(async () => ((await (await fetch('/api/search?q=&kind=music')).json()).items || [])[0]);
  await page.evaluate((s) => download({ id: 'song:' + s.id, type: 'song', title: s.title }, [s]), song);
  const after = await page.evaluate(async () => ({ keeps: KEEPS, downloaded: hasDownloads(), store: sessionStorage.getItem('pretend-app'),
    webCached: (await (await caches.open('soundstorm-offline-v1')).keys()).length }));
  console.log('after downloading:', JSON.stringify(after), 'kept files:', [...folder.keys()].join(' '));
  // Opened again with no connection: the list from the app, the song from its copy.
  await context.setOffline(true);
  offlineShell = true;
  await page.reload().catch(() => {});
  await page.waitForFunction(() => typeof state !== 'undefined' && state.offline, null, { timeout: 30000 }).catch(() => {});
  const offline = await page.evaluate(() => ({ offline: state.offline, downloads: hasDownloads(),
    changeServer: !$('offline-server').classList.contains('hidden'), strip: getComputedStyle($('offline-strip')).display + ' ' + $('offline-strip').innerText.replace(/s+/g, ' ') }));
  console.log('opened offline:', JSON.stringify(offline));
  await page.evaluate((s) => playAudio(s), song);
  await page.waitForFunction(() => $('audio-player').currentTime > 0.5, null, { timeout: 15000 }).catch(() => {});
  console.log('playing from:', await page.evaluate(() => ({ src: $('audio-player').currentSrc, t: $('audio-player').currentTime })));
  console.log('errors:', JSON.stringify(errors));
  await browser.close();
})();
