// Number the episodes, on the throwaway test server: a ripped disc's show
// ("Disc Show": C1-C4 episodes, B1 a play-all, A1 an extra) opened, the
// suggestion read, C2 moved below C3, Apply - and the files renamed.
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
  let show = null;
  for (let i = 0; i < 60 && !show; i++) {
    show = await page.evaluate(async () => {
      const r = await (await fetch('/api/search?q=&kind=tv')).json();
      return (r.items || []).find((it) => /Disc Show/.test(it.title)) || null;
    });
    if (!show) await page.waitForTimeout(2000);
  }
  if (!show) { console.log('the show never appeared'); await browser.close(); return; }
  await page.goto(BASE + '/');
  await page.waitForFunction(() => typeof showShow === 'function' && state.me);
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(1500);
  await page.evaluate((s) => showShow(s), show);
  await page.getByText('Number the episodes', { exact: true }).click();
  await page.locator('.numbering-row').first().waitFor({ timeout: 20000 });
  const read = () => page.evaluate(() => [...document.querySelectorAll('.numbering-row')].map((li) =>
    `${li.querySelector('.numbering-what strong').textContent} [${li.querySelector('select').value}] ${li.querySelector('.numbering-to').textContent}`));
  console.log('suggested:\n  ' + (await read()).join('\n  '));
  await page.screenshot({ path: 'numbering.png', fullPage: false });
  // Move C2 down one (below C3).
  const rows = page.locator('.numbering-row');
  const n = await rows.count();
  for (let i = 0; i < n; i++) {
    if (/C2_t02/.test(await rows.nth(i).locator('.numbering-what strong').textContent())) {
      await rows.nth(i).locator('button[aria-label="Move down"]').click();
      break;
    }
  }
  console.log('after moving C2 down:\n  ' + (await read()).join('\n  '));
  await page.locator('.numbering-buttons .primary').click();
  try {
    await page.waitForFunction(() => /Done/.test(document.body.innerText), null, { timeout: 20000 });
  } catch {
    console.log('NOT DONE:', await page.evaluate(() => (document.querySelector('.numbering-note') || {}).textContent));
  }
  console.log('errors:', JSON.stringify(errors));
  await browser.close();
})();
