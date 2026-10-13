// Settings, Devices: the owner's directions for the computer EmberStorm runs
// on (staying awake, the lid, signing in by itself) - the computer the
// installer named, or all three where it named none.
//   node scripts/smoke/hostcard.js
const { chromium } = require('playwright');

const base = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
const ACCOUNT = { username: 'smoke', password: 'smoke test password 4417' };

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.request.post(`${base}/api/login`, { data: ACCOUNT });
  const session = await (await page.request.get(`${base}/api/session`)).json();
  await page.goto(base);
  await page.waitForFunction(() => !document.getElementById('host-block').classList.contains('hidden'), null, { timeout: 15000 });
  const shown = await page.$$eval('#host-block [data-host]', (els) => els.filter((e) => !e.classList.contains('hidden')).map((e) => e.dataset.host));
  await page.evaluate(() => { document.querySelector('#tabs [data-tab="settings"]')?.click(); });
  await page.waitForTimeout(500);
  await page.locator('#subtabs button', { hasText: 'Devices' }).first().click();
  await page.waitForTimeout(400);
  await page.locator('#host-block h2').click();
  await page.waitForTimeout(300);
  await page.evaluate(() => document.getElementById('host-block').scrollIntoView());
  await page.waitForTimeout(500);
  await page.screenshot({ path: process.env.SHOT || 'hostcard.png', fullPage: false });
  const wide = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
  console.log('host in session:', JSON.stringify(session.host), ' shown:', shown.join(', '));
  console.log('wider than the screen:', wide, ' page errors:', errors.length ? errors : 'none');
  await browser.close();
  process.exit(errors.length || wide ? 1 : 0);
})();
