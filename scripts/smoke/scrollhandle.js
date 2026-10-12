// The adding sheet's scrollbar on the test server: a long drop (many albums),
// "Show every file" open, and the sheet's own thumb dragged to the foot -
// the sheet scrolls there. Nothing is added (the sheet is closed after).
//   node scripts/smoke/scrollhandle.js
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
  await page.goto(base);
  await page.waitForSelector('#app:not(.hidden)', { timeout: 20000 }).catch(() => {});
  // Forty albums of six songs each, as a folder drop (the page's own planner).
  const files = [];
  for (let a = 1; a <= 40; a++) for (let t = 1; t <= 6; t++) {
    files.push({ name: `Artist ${a} - Album ${a} - ${t}.flac`, mimeType: 'audio/flac', buffer: Buffer.from('fLaC' + 'x'.repeat(100)) });
  }
  await page.setInputFiles('#file-picker', files);
  await page.waitForFunction(() => !document.getElementById('intake').classList.contains('hidden'), null, { timeout: 20000 });
  await page.waitForTimeout(3000);
  const toggle = await page.$('#intake-files-toggle:not(.hidden)');
  if (toggle) await toggle.click();
  await page.waitForTimeout(500);
  const state = await page.evaluate(() => {
    const sheet = document.getElementById('intake');
    const handles = [...document.querySelectorAll('.scroll-handle:not(.hidden)')].map((h) => h.getBoundingClientRect());
    return { sheetScroll: sheet.scrollHeight - sheet.clientHeight, handles: handles.map((r) => [Math.round(r.left), Math.round(r.top), Math.round(r.height)]) };
  });
  console.log('sheet can scroll by', state.sheetScroll, 'px; handles shown:', JSON.stringify(state.handles));
  await page.screenshot({ path: `${out}/scrollhandle-1.png` });
  // Drag the sheet's own thumb (the first, the widest box) to the foot.
  const thumb = await page.evaluate(() => {
    const t = [...document.querySelectorAll('.scroll-handle:not(.hidden)')]
      .map((h) => h.querySelector('.scroll-handle-thumb').getBoundingClientRect())
      .sort((a, b) => a.left - b.left).pop();
    return t && { x: t.left + t.width / 2, y: t.top + t.height / 2 };
  });
  let moved = null;
  if (thumb) {
    const before = await page.evaluate(() => document.getElementById('intake').scrollTop);
    const cdp = await ctx.newCDPSession(page);
    const touch = (type, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x: thumb.x, y }] });
    await touch('touchStart', thumb.y);
    for (let i = 1; i <= 10; i++) await touch('touchMove', thumb.y + i * 80);
    await touch('touchEnd');
    await page.waitForTimeout(300);
    const after = await page.evaluate(() => { const s = document.getElementById('intake'); return [s.scrollTop, s.scrollHeight - s.clientHeight]; });
    moved = { before, after };
    console.log('dragged: scrollTop', before, '->', after[0], 'of', after[1]);
  }
  await page.screenshot({ path: `${out}/scrollhandle-2.png` });
  console.log('page errors:', errors.length ? errors : 'none');
  await browser.close();
})();
