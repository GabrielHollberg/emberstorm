// Settings, About on the test server: the build line shows to somebody signed
// in, and the session says nothing of it to anybody who is not.
//   node scripts/smoke/aboutbuild.js
const { chromium } = require('playwright');

const base = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
const ACCOUNT = { username: 'smoke', password: 'smoke test password 4417' };

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const anon = await (await browser.newContext()).request.get(`${base}/api/session`);
  const told = 'build' in (await anon.json());
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.request.post(`${base}/api/login`, { data: ACCOUNT });
  await page.goto(base);
  await page.waitForFunction(() => document.getElementById('about-build').textContent.length > 0, null, { timeout: 15000 });
  const line = await page.$eval('#about-build', (el) => el.textContent);
  console.log('signed out told the build:', told);
  console.log('About says:', line);
  console.log('page errors:', errors.length ? errors : 'none');
  await browser.close();
  process.exit(told || errors.length ? 1 : 0);
})();
