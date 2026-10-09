// A second drop while the first is being sent is queued, then looked at and
// sent once the first is in - on the throwaway test server, the first upload
// slowed down so the second really arrives mid-send.
const { chromium } = require('playwright');

const BASE = process.env.SMOKE_URL || 'http://127.0.0.1:8296';

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
  const sent = [];
  await page.route('**/api/upload?*', async (route) => {
    const p = new URL(route.request().url()).searchParams.get('path');
    sent.push(p);
    if (p.includes('First')) await new Promise((r) => setTimeout(r, 3000));
    return route.continue();
  });
  await page.goto(BASE + '/');
  await page.evaluate(() => fetch('/api/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'smoke', password: 'smoke test password 4417' }),
  }));
  await page.goto(BASE + '/');
  await page.waitForFunction(() => typeof intake === 'function');
  const toasts = [];
  page.on('console', () => {});
  const file = (name) => page.evaluateHandle((n) => new File([crypto.getRandomValues(new Uint8Array(4096))], n, { type: 'audio/flac' }), name);

  // The first drop: review, then Add.
  await page.evaluate(() => { window.__q1 = intake({ items: [], files: [new File([crypto.getRandomValues(new Uint8Array(4096))], 'Queue Test First ' + Date.now() + '.flac')] }); });
  const add = page.locator('#intake .intake-actions button:not(.ghost)');
  await add.waitFor();
  await add.click();
  await page.waitForTimeout(500);
  // The second, mid-send.
  await page.evaluate(() => intake({ items: [], files: [new File([crypto.getRandomValues(new Uint8Array(4096))], 'Queue Test Second ' + Date.now() + '.flac')] }));
  await page.waitForTimeout(200);
  toasts.push(await page.evaluate(() => document.querySelector('#toast') ? document.querySelector('#toast').textContent : ''));
  // Its review comes once the first is in.
  try {
    await page.waitForFunction(() => /Ready to add 1 file/.test(document.getElementById('intake-title').textContent), null, { timeout: 15000 });
  } catch (e) {
    console.log('STUCK. sent:', JSON.stringify(sent), 'toast:', JSON.stringify(toasts[0]), 'panel:', await page.evaluate(() => document.getElementById('intake-title').textContent), 'queue:', await page.evaluate(() => intakeQueue.length));
    await browser.close(); return;
  }
  await add.click();
  await page.waitForFunction(() => /Added 1 file/.test(document.getElementById('intake-title').textContent), null, { timeout: 15000 });
  console.log('sent in order:', JSON.stringify(sent));
  console.log('message for the second drop:', JSON.stringify(toasts[0]));
  console.log('last panel:', await page.evaluate(() => document.getElementById('intake-title').textContent));
  await browser.close();
})();
