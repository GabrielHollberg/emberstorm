// Choose a poster, placed by hand: on the throwaway test server, the film's
// menu, a poster tapped, the square frame shown, dragged, and Use - and the
// film's cover changes.
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
  const tag = () => page.evaluate(async () => {
    const r = await (await fetch('/api/search?q=&kind=video')).json();
    const it = (r.items || []).find((i) => /Bunny/.test(i.title));
    return it ? it.artId.split('_').pop() : '';
  });
  await page.goto(BASE + '/');
  const before = await tag();
  await page.locator('.tab[data-tab="watch"], [data-tab="watch"]').first().click();
  const card = page.locator('.item', { hasText: 'Big Buck Bunny' }).first();
  await card.waitFor();
  await card.click({ button: 'right' });
  await page.getByText('Choose a poster', { exact: true }).click();
  const tile = page.locator('.poster-choice').nth(3);
  await tile.waitFor({ timeout: 20000 });
  await tile.click();
  const frame = page.locator('.crop-frame');
  await frame.waitFor({ timeout: 20000 });
  const box = await frame.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.wheel(0, -400); // zoom in
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2 + 60, box.y + box.height / 2 + 40, { steps: 5 });
  await page.mouse.up();
  await page.screenshot({ path: 'poster-frame.png' });
  await page.locator('.crop-buttons .primary').click();
  await page.waitForFunction(() => /Cover changed/.test(document.body.innerText), null, { timeout: 20000 });
  let after = before;
  for (let i = 0; i < 10 && after === before; i++) { await page.waitForTimeout(1000); after = await tag(); }
  console.log('cover tag before', before, 'after', after, after !== before ? 'CHANGED' : 'SAME', 'errors:', JSON.stringify(errors));
  await browser.close();
})();
