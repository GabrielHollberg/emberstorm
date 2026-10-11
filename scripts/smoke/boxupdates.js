// Settings, Devices, Updates on the test server, made to look like a box (it
// has no caretaker of its own): the version, Check for updates finding one,
// Update now asking first and saying it is updating.
//   node scripts/smoke/boxupdates.js
const { chromium } = require('playwright');

const base = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
const ACCOUNT = { username: 'smoke', password: 'smoke test password 4417' };
const out = process.env.SHOTS || require('os').tmpdir();

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.request.post(`${base}/api/login`, { data: ACCOUNT });
  await page.request.patch(`${base}/api/prefs`, { data: { welcomeDone: true, addressSeen: true } });

  let looked = false, updating = false, asked = [];
  const status = () => ({
    state: updating ? 'updating' : 'idle', auto: true, version: '2026.10.1',
    installed: '2026-10-10T20:00:00Z', lastCheck: looked ? '2026-10-11T18:00:00Z' : undefined,
    available: looked && !updating ? { version: '2026.10.2', notes: 'Switching off takes one press.' } : undefined,
  });
  await page.route(/\/api\/session$/, async (route) => {
    const res = await route.fetch();
    await route.fulfill({ response: res, json: { ...(await res.json()), boxReset: true } });
  });
  await page.route(/\/api\/box\/timezone$/, (route) => route.fulfill({ json: { zone: 'America/Denver' } }));
  await page.route(/\/api\/reset\/waiting$/, (route) => route.fulfill({ json: {} }));
  await page.route(/\/api\/box\/updates(\/.*)?$/, async (route) => {
    const path = new URL(route.request().url()).pathname;
    asked.push(`${route.request().method()} ${path}`);
    if (path.endsWith('/check')) looked = true;
    if (path.endsWith('/now')) { updating = true; return route.fulfill({ status: 202, json: { updating: true } }); }
    return route.fulfill({ json: status() });
  });
  page.on('dialog', (d) => { asked.push(`confirm: ${d.message()}`); d.accept(); });

  await page.goto(base);
  await page.waitForSelector('[data-tab="settings"]', { state: 'attached', timeout: 20000 }); await page.waitForTimeout(2000);
  await page.evaluate(() => document.querySelector('[data-tab="settings"]').click());
  await page.waitForSelector('#box-updates-block:not(.hidden)', { state: 'attached', timeout: 10000 });
  await page.evaluate(() => {
    const pill = [...document.querySelectorAll('#subtabs button')].find((b) => /devices/i.test(b.textContent));
    if (pill) pill.click();
  });
  await page.waitForTimeout(600);
  await page.evaluate(() => openSettingsCard(document.getElementById('box-updates-block')));
  await page.waitForTimeout(800);
  const text = async () => (await page.textContent('#box-updates-block')).replace(/\s+/g, ' ').trim();
  console.log('before:', await text());
  await page.locator('#box-updates-block').screenshot({ path: `${out}/box-updates-1.png` });
  await page.click('#box-updates-check');
  await page.waitForTimeout(800);
  console.log('after check:', await text());
  await page.locator('#box-updates-block').screenshot({ path: `${out}/box-updates-2.png` });
  await page.click('#box-updates-now');
  await page.waitForTimeout(1500);
  console.log('updating:', await text());
  await page.locator('#box-updates-block').screenshot({ path: `${out}/box-updates-3.png` });
  console.log('asked:', asked.join(' | '));
  console.log('page errors:', errors.length ? errors : 'none');
  console.log('pictures in', out);
  await browser.close();
})();
