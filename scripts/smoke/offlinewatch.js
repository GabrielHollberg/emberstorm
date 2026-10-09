// A film's place kept while offline, and sent once back online: on the test
// server, its film played, the connection cut, paused (a save), the place
// found kept on the device and not on the server, then the connection back.
const { chromium } = require('playwright');
const BASE = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(BASE + '/');
  await page.evaluate(() => fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'smoke', password: 'smoke test password 4417' }) }));
  await page.goto(BASE + '/');
  await page.waitForFunction(() => typeof playVideo === 'function' && state.me);
  await page.waitForLoadState('networkidle');
  const film = await page.evaluate(async () => ((await (await fetch('/api/search?q=&kind=video')).json()).items || [])[0]);
  if (!film) { console.log('no film'); await browser.close(); return; }
  const key = `soundstorm-watch:${film.sourceId}/${film.id}`;
  await page.evaluate(async (f) => { await fetch(`/api/book/progress?source=${encodeURIComponent(f.sourceId)}&id=${encodeURIComponent(f.id)}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ location: 't=6.0', fraction: 0.01 }) }); }, film);
  await page.evaluate((f) => playVideo(f), film);
  await page.waitForFunction(() => $('video-player').currentTime > 0.5, null, { timeout: 30000 });
  await page.evaluate(() => { const v = $('video-player'); v.currentTime = 30; });
  await page.waitForTimeout(1500);
  await context.setOffline(true);
  await page.evaluate(() => $('video-player').pause());
  await page.waitForTimeout(1500);
  const kept = await page.evaluate((k) => localStorage.getItem(k), key);
  console.log('kept on the device while offline:', kept);
  await context.setOffline(false);
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.waitForTimeout(3000);
  const server = await page.evaluate(async (f) => (await (await fetch(`/api/book/progress?source=${encodeURIComponent(f.sourceId)}&id=${encodeURIComponent(f.id)}`)).json()), film);
  console.log('on the server after reconnecting:', server.location);
  console.log('device copy now:', await page.evaluate((k) => localStorage.getItem(k), key));
  console.log('errors:', JSON.stringify(errors));
  await browser.close();
})();
