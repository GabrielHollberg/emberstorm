// The app opens to what is downloaded when the server answers nothing at all
// (unplugged, not switched off) - the owner's report, 2026-10-09: a black
// screen for ever. A TLS stand-in at test.home.emberstorm.app:8443 passes
// requests to the test server (127.0.0.1:8296) until told to hang, then takes
// every connection and never answers.
//
//   node offlineopen.js <folder holding cert.pem and key.pem>
const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const dir = process.argv[2];
const NAME = 'test.home.emberstorm.app';
const ORIGIN = `https://${NAME}:8443`;
const ACCOUNT = { username: 'smoke', password: 'smoke test password 4417' };
let hang = false;

const proxy = https.createServer({ key: fs.readFileSync(path.join(dir, 'key.pem')), cert: fs.readFileSync(path.join(dir, 'cert.pem')) }, (req, res) => {
  if (hang) return; // taken, never answered
  const up = http.request({ host: '127.0.0.1', port: 8296, path: req.url, method: req.method, headers: { ...req.headers, host: `${NAME}:8443` } }, (r) => {
    res.writeHead(r.statusCode, r.headers);
    r.pipe(res);
  });
  up.on('error', () => { res.writeHead(502); res.end(); });
  req.pipe(up);
});

(async () => {
  await new Promise((r) => proxy.listen(8443, '127.0.0.1', r));
  const browser = await chromium.launch({
    channel: 'chrome',
    args: [`--host-resolver-rules=MAP ${NAME} 127.0.0.1`, '--ignore-certificate-errors'],
  });
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(ORIGIN + '/');
  const login = await page.evaluate(async (a) => (await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(a) })).status, ACCOUNT);
  console.log('signed in:', login);
  await page.reload();
  await page.waitForFunction(() => !document.getElementById('app').classList.contains('hidden'), null, { timeout: 20000 });
  await page.waitForFunction(() => navigator.serviceWorker.controller, null, { timeout: 20000 });
  // One song downloaded, as the hold menu's Download does.
  const got = await page.evaluate(async () => {
    const r = await fetch('/api/search?kind=music&q=');
    const body = await r.json();
    const song = (body.items || []).find((i) => i.kind === 'music');
    if (!song) return 'no song';
    await download({ id: 'song:' + song.id, type: 'song', title: song.title }, [song]);
    return hasDownloads() ? song.title : 'not downloaded';
  });
  console.log('downloaded:', got);
  await page.reload();
  await page.waitForFunction(() => !document.getElementById('app').classList.contains('hidden'), null, { timeout: 20000 });

  hang = true;
  const start = Date.now();
  await page.goto(ORIGIN + '/', { waitUntil: 'commit', timeout: 60000 }).catch((e) => console.log('goto:', e.message));
  const opened = await page.waitForFunction(() => {
    const app = document.getElementById('app');
    return app && !app.classList.contains('hidden') && document.body.textContent.length > 0;
  }, null, { timeout: 45000 }).then(() => true, () => false);
  console.log(opened ? `opened with the server answering nothing, after ${((Date.now() - start) / 1000).toFixed(1)}s` : 'did NOT open within 45s');
  const text = opened ? await page.evaluate(() => document.querySelector('#app').innerText.slice(0, 200).replace(/\s+/g, ' ')) : '';
  console.log('showing:', text);
  console.log('page errors:', errors.length ? errors : 'none');
  await page.screenshot({ path: path.join(dir, 'offline.png') });
  await browser.close();
  proxy.close();
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
