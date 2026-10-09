// Number the episodes, on the throwaway test server: a row dragged by its
// handle to below the next, then Check against the episode guide - and
// Cancel, so nothing is renamed.
const { chromium } = require('playwright');
const BASE = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(BASE + '/');
  await page.evaluate(() => fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'smoke', password: 'smoke test password 4417' }) }));
  await page.goto(BASE + '/');
  await page.waitForFunction(() => typeof showShow === 'function' && state.me);
  await page.waitForLoadState('networkidle');
  await page.evaluate(() => fetch('/api/library/rescan', { method: 'POST' }));
  let show = null;
  for (let i = 0; i < 60 && !show; i++) {
    show = await page.evaluate(async () => ((await (await fetch('/api/search?q=&kind=tv')).json()).items || []).find((it) => /Avatar/.test(it.title)) || null);
    if (!show) await page.waitForTimeout(2000);
  }
  if (!show) { console.log('no show'); await browser.close(); return; }
  await page.evaluate((s) => showShow(s), show);
  await page.getByText('Number the episodes', { exact: true }).click();
  await page.locator('.numbering-row').first().waitFor({ timeout: 20000 });
  const read = () => page.evaluate(() => [...document.querySelectorAll('.numbering-row')].map((li) =>
    `${li.querySelector('.numbering-what strong').textContent} ${li.querySelector('.numbering-to').textContent}${li.querySelector('.numbering-guide') ? '  [' + li.querySelector('.numbering-guide').textContent + ']' : ''}`));
  console.log('before:\n  ' + (await read()).join('\n  '));
  const h0 = await page.locator('.numbering-handle').nth(0).boundingBox();
  const r1 = await page.locator('.numbering-row').nth(1).boundingBox();
  await page.mouse.move(h0.x + h0.width / 2, h0.y + h0.height / 2);
  await page.mouse.down();
  for (let k = 1; k <= 10; k++) await page.mouse.move(h0.x + h0.width / 2, h0.y + h0.height / 2 + (r1.height + 20) * k / 10);
  await page.mouse.up();
  console.log('after dragging the first below the second:\n  ' + (await read()).join('\n  '));
  await page.getByText('Check against the episode guide').click();
  await page.waitForFunction(() => /TVmaze|guide does not|reach/.test(document.querySelector('.numbering-guide-row').textContent), null, { timeout: 30000 });
  console.log('guide:', await page.evaluate(() => document.querySelector('.numbering-guide-row span').textContent));
  console.log('rows:\n  ' + (await read()).join('\n  '));
  await page.screenshot({ path: 'numbering2.png' });
  await page.locator('.numbering-buttons .ghost').click();
  console.log('errors:', JSON.stringify(errors));
  await browser.close();
})();
