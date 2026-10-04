// The after-deploy check's walk through the app (scripts/after-deploy.sh).
//
//   node smoke.js live <url>    the live server: healthy, and its page loads
//                               without a script error (signed out: there is
//                               no account here to sign in with)
//   node smoke.js app <url>     the test server (scripts/smoke-stack.sh),
//                               signed in: every main screen, at phone, TV
//                               and computer size
//
// Any script error on any page, or a screen that does not show what it
// should, is a failure; it exits 1 and says which. Uses the Chrome already
// installed (channel 'chrome'), so it downloads no browser.
const { chromium } = require('playwright');

const [mode, base] = process.argv.slice(2);
const ACCOUNT = { username: 'smoke', password: 'smoke test password 4417' };
const results = [];
let failed = false;

async function step(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    results.push(`  ok    ${name} (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
  } catch (err) {
    failed = true;
    results.push(`  FAIL  ${name}: ${String(err && err.message || err).split('\n')[0]}`);
  }
}

// Waits for fn (run in the page) to come back true.
async function until(page, fn, what, timeout = 15000, arg) {
  try {
    await page.waitForFunction(fn, arg, { timeout, polling: 250 });
  } catch {
    throw new Error(`${what} (waited ${timeout / 1000}s)`);
  }
}

async function context(browser, opts) {
  const ctx = await browser.newContext(opts);
  const page = await ctx.newPage();
  page.errors = [];
  page.on('pageerror', (e) => page.errors.push(e.message));
  return { ctx, page };
}

function noErrors(page, where) {
  if (page.errors.length) throw new Error(`script error on ${where}: ${page.errors.join(' | ')}`);
}

const shown = (id) => { const el = document.getElementById(id); return Boolean(el && !el.classList.contains('hidden') && el.getClientRects().length); };

async function live(browser) {
  await step('live server is healthy', async () => {
    const r = await fetch(`${base}/healthz`);
    if (!r.ok) throw new Error(`healthz answered ${r.status}`);
    const body = await r.json();
    const want = Number(process.env.SMOKE_LIVE_SOURCES || 9);
    if ((body.sources || 0) < want) throw new Error(`${body.sources} sources, expected ${want}`);
  });
  await step('live page loads without a script error', async () => {
    const { ctx, page } = await context(browser, { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    await page.goto(`${base}/`, { waitUntil: 'load' });
    try {
      await until(page, () => !document.getElementById('boot') || document.getElementById('boot').classList.contains('hidden')
        || !document.querySelector('#boot .boot-mark'), 'the page to get past its loading screen');
    } catch (err) {
      // Stuck loading is usually a script error: say which.
      throw new Error(page.errors.length ? `stuck loading - script error: ${page.errors.join(' | ')}` : err.message);
    }
    await page.waitForTimeout(1500);
    noErrors(page, 'the live page');
    await ctx.close();
  });
}

async function signedIn(browser, opts, path = '/') {
  const c = await context(browser, opts);
  const r = await c.page.request.post(`${base}/api/login`, { data: ACCOUNT });
  if (!r.ok()) throw new Error(`signing in answered ${r.status()}`);
  await c.page.goto(`${base}${path}`, { waitUntil: 'load' });
  // A TV asks who is listening: the one person.
  await c.page.waitForTimeout(1500);
  await c.page.evaluate(() => {
    const p = document.getElementById('profiles');
    if (p && !p.classList.contains('hidden')) { const b = p.querySelector('button'); if (b) b.click(); }
  });
  await until(c.page, () => { const a = document.getElementById('app'); return a && !a.classList.contains('hidden'); }, 'the app to show after signing in', 20000);
  return c;
}

async function tab(page, name) {
  await page.evaluate((n) => document.querySelector(`[data-tab="${n}"]`).click(), name);
}

async function app(browser) {
  const phone = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true };
  let c;
  await step('phone: signs in, Home shows, nothing wider than the screen', async () => {
    c = await signedIn(browser, phone);
    await until(c.page, () => document.querySelectorAll('#tabs [data-tab]').length >= 3, 'the tab bar');
    await c.page.waitForTimeout(1500);
    const wide = await c.page.evaluate(() => document.documentElement.scrollWidth - innerWidth);
    if (wide > 1) throw new Error(`the page is ${wide}px wider than the phone`);
    noErrors(c.page, 'Home');
  });
  if (!c) return;
  const { page } = c;
  await step('phone: Music lists songs or albums', async () => {
    await tab(page, 'music');
    await until(page, () => document.querySelectorAll('#music-view .item, #results .item, #music-view .album-card, #music-view button.item').length > 0, 'music to list');
    noErrors(page, 'Music');
  });
  await step('phone: a song plays and Now Playing opens', async () => {
    await page.evaluate(async () => {
      const r = await (await fetch('/api/search?q=&kind=music')).json();
      playQueue(r.items, 0);
      openNowPlaying();
    });
    await until(page, () => document.getElementById('audio-player').currentTime > 0.5, 'the song to play', 20000);
    await until(page, shown, 'Now Playing to show', 5000, 'now-playing');
    await page.evaluate(() => { stopAudio(); });
    noErrors(page, 'Now Playing');
  });
  await step('phone: Photos is a timeline, a photo and a video open', async () => {
    await tab(page, 'photos');
    // The tab as it opens, on its first pill (it once showed nothing: a pill
    // without its hidden chip).
    await until(page, () => document.querySelectorAll('.tl-month').length > 0 && document.querySelectorAll('.tl-grid .item').length > 0, 'the Photos tab to show photos as it opens', 20000);
    await page.evaluate(() => { const b = [...document.querySelectorAll('#subtabs button')].find((x) => x.textContent.trim() === 'Photos & videos'); if (b) b.click(); });
    await page.waitForTimeout(800);
    await until(page, () => document.querySelectorAll('.tl-month').length > 0 && document.querySelectorAll('.tl-grid .item').length > 0, 'months and photos', 20000);
    await page.evaluate(() => [...document.querySelectorAll('.tl-grid .item')].find((x) => !x.querySelector('.tl-length')).click());
    await until(page, shown, 'the photo viewer', 5000, 'photo-overlay');
    await page.evaluate(() => closePhoto());
    const hasClip = await page.evaluate(() => Boolean(document.querySelector('.tl-grid .item .tl-length')));
    if (hasClip) {
      await page.evaluate(() => document.querySelector('.tl-grid .item .tl-length').closest('.item').click());
      await until(page, () => { const v = document.getElementById('photo-video'); return v.currentTime > 0.2; }, 'the video to play in the viewer', 15000);
      await page.evaluate(() => closePhoto());
    }
    noErrors(page, 'Photos');
  });
  await step('phone: Watch lists a film, and it plays', async () => {
    await tab(page, 'watch');
    await until(page, () => document.querySelectorAll('#results .item, #music-view .item').length > 0, 'films to list', 20000);
    await page.evaluate(async () => { const r = await (await fetch('/api/search?q=&kind=video')).json(); play(r.items[0]); });
    await until(page, () => document.getElementById('video-player').currentTime > 0.5, 'the film to play', 30000);
    await page.evaluate(() => closeVideo());
    noErrors(page, 'Watch');
  });
  await step('phone: a book opens in the reader', async () => {
    await tab(page, 'books');
    await page.evaluate(async () => { const r = await (await fetch('/api/search?q=&kind=ebook')).json(); play(r.items[0]); });
    await until(page, shown, 'the reader', 15000, 'reader-overlay');
    await page.waitForTimeout(2500);
    noErrors(page, 'the reader');
    await page.keyboard.press('Escape');
  });
  await step('phone: Settings opens', async () => {
    await page.evaluate(() => { const r = document.getElementById('reader-close') || document.querySelector('#reader-overlay .close'); if (r) r.click(); });
    await tab(page, 'settings');
    await until(page, shown, 'Settings', 8000, 'account');
    noErrors(page, 'Settings');
  });
  await c.ctx.close();

  await step('TV: opens, plays a song in Now Playing', async () => {
    const t = await signedIn(browser, { viewport: { width: 1280, height: 720 } }, '/?tv=1');
    await t.page.evaluate(async () => {
      const r = await (await fetch('/api/search?q=&kind=music')).json();
      playQueue(r.items, 0);
    });
    await until(t.page, () => document.getElementById('audio-player').currentTime > 0.5, 'the song to play on the TV', 20000);
    await until(t.page, shown, 'Now Playing on the TV', 8000, 'now-playing');
    noErrors(t.page, 'the TV');
    await t.ctx.close();
  });
  await step('computer: Home shows', async () => {
    const d = await signedIn(browser, { viewport: { width: 1366, height: 860 } });
    await d.page.waitForTimeout(1500);
    noErrors(d.page, 'Home on a computer');
    await d.ctx.close();
  });
}

(async () => {
  if (!base || !['live', 'app'].includes(mode)) {
    console.error('usage: node smoke.js live|app <url>');
    process.exit(2);
  }
  const browser = await chromium.launch({ channel: 'chrome', args: ['--autoplay-policy=no-user-gesture-required'] });
  try {
    if (mode === 'live') await live(browser); else await app(browser);
  } finally {
    await browser.close();
  }
  console.log(results.join('\n'));
  process.exit(failed ? 1 : 0);
})();
