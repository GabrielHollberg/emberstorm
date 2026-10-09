// An episode's picture, chosen by hand: on the throwaway test server, the
// show's page, a hold on the episode, Choose a picture, one of the server's
// photos placed in the wide frame, Use - and the episode's picture changes.
const { chromium } = require('playwright');

const BASE = process.env.SMOKE_URL || 'http://127.0.0.1:8296';

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(BASE + '/');
  await page.evaluate(() => fetch('/api/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'smoke', password: 'smoke test password 4417' }),
  }));
  await page.evaluate(() => fetch('/api/library/rescan', { method: 'POST' }));
  // Wait for the show to be found.
  let show = null;
  for (let i = 0; i < 40 && !show; i++) {
    show = await page.evaluate(async () => {
      const r = await (await fetch('/api/search?q=&kind=tv')).json();
      return (r.items || []).find((it) => /Smoke Show/.test(it.title)) || null;
    });
    if (!show) await page.waitForTimeout(2000);
  }
  if (!show) { console.log('the show never appeared'); await browser.close(); return; }
  const epTag = () => page.evaluate(async (s) => {
    const r = await (await fetch(`/api/tv/show?source=${s.sourceId}&id=${s.id}`)).json();
    const e = (r.episodes || [])[0];
    return e ? (e.artId || '(none)') : '(no episode)';
  }, show);
  await page.goto(BASE + '/');
  const before = await epTag();
  await page.waitForFunction(() => typeof showShow === 'function');
  await page.evaluate((s) => showShow(s), show);
  const row = page.locator('.episode-row').first();
  await row.waitFor({ timeout: 20000 });
  await row.click({ button: 'right' });
  await page.getByText('Choose a picture', { exact: true }).click();
  await page.waitForFunction(() => /No pictures|poster-choice/.test(document.getElementById('item-menu').innerHTML), null, { timeout: 20000 });
  await page.getByText('Choose a picture instead', { exact: true }).click();
  await page.getByText('From your photos', { exact: true }).click();
  const photo = page.locator('.pick-photos img, .pick-photos-tiles button').first();
  await photo.waitFor({ timeout: 20000 });
  await photo.click();
  const frame = page.locator('.crop-frame');
  await frame.waitFor({ timeout: 20000 });
  const box = await frame.boundingBox();
  await page.screenshot({ path: 'episode-frame.png' });
  await page.locator('.crop-buttons .primary').click();
  await page.waitForFunction(() => /Picture changed/.test(document.body.innerText), null, { timeout: 20000 });
  let after = before;
  for (let i = 0; i < 10 && after === before; i++) { await page.waitForTimeout(1000); after = await epTag(); }
  console.log(`frame ${Math.round(box.width)}x${Math.round(box.height)} (${(box.width / box.height).toFixed(2)}),`,
    'episode picture before', before, 'after', after, after !== before ? 'CHANGED' : 'SAME', 'errors:', JSON.stringify(errors));
  await browser.close();
})();
