// The owner's welcome on the test server: one step at a time over the whole
// screen. Resets the test account's welcome, then walks it at phone and
// computer size, a picture of each step, Not now / Keep this address to go on.
//   node scripts/smoke/welcome.js
const { chromium } = require('playwright');

const base = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
const ACCOUNT = { username: 'smoke', password: 'smoke test password 4417' };
const out = process.env.SHOTS || require('os').tmpdir();

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  for (const [name, viewport] of [['phone', { width: 390, height: 844 }], ['computer', { width: 1280, height: 800 }]]) {
    const ctx = await browser.newContext({ viewport, hasTouch: name === 'phone', isMobile: name === 'phone' });
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.request.post(`${base}/api/login`, { data: ACCOUNT });
    const lib = await (await page.request.get(`${base}/api/library`)).json();
    console.log(name, 'library added:', lib.added, 'empty:', lib.empty);
    await page.request.patch(`${base}/api/prefs`, { data: { welcomeDone: false, addressSeen: false, welcomeSeen: [] } });
    // As a brand-new server: only the starter media, one person, no TV, the
    // address still its code, an easier name to be had.
    const fresh = { '/api/library': (b) => ({ ...b, added: false, shareURL: 'https://k3x9m2p7qa.home.emberstorm.app:8099' }),
      '/api/session': (b) => ({ ...b, webName: '', webNames: true }),
      '/api/users': (b) => ({ ...b, users: (b.users || []).slice(0, 1) }),
      '/api/players': (b) => ({ ...b, players: [] }) };
    await page.route(/\/api\/(library|session|users|players)$/, async (route) => {
      const res = await route.fetch();
      const body = await res.json();
      const path = new URL(route.request().url()).pathname;
      await route.fulfill({ response: res, json: fresh[path](body) });
    });
    await page.goto(base);
    await page.waitForSelector('#welcome:not(.hidden)', { timeout: 20000 });
    for (let i = 1; i <= 6; i++) {
      await page.waitForTimeout(400);
      if (await page.$('#welcome.hidden')) { console.log(name, 'welcome closed after', i - 1, 'steps'); break; }
      const title = await page.textContent('#welcome-title');
      const progress = await page.textContent('#welcome-progress');
      const buttons = await page.$$eval('#welcome-actions button', (b) => b.map((x) => x.textContent));
      console.log(name, i, JSON.stringify(progress), JSON.stringify(title), buttons);
      await page.screenshot({ path: `${out}/welcome-${name}-${i}.png` });
      const go = await page.$('#welcome-actions button:text-is("Not now"), #welcome-actions button:text-is("Keep this address"), #welcome-actions button:text-is("Next"), #welcome-actions button:text-is("Got it")');
      if (!go) break;
      await go.click();
    }
    const prefs = await (await page.request.get(`${base}/api/prefs`)).json();
    console.log(name, 'kept:', JSON.stringify(prefs.welcomeSeen), 'done:', prefs.welcomeDone, 'errors:', errors);
    await ctx.close();
  }
  await browser.close();
})();
