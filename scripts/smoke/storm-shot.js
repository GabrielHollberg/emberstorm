// Takes Now Playing in the Storm look the moment a big close lightning bolt
// lands, on the test server (made-up songs only), for the website: a phone
// shot (web/shots/now-playing.png) and a TV shot (web/shots/tv.png).
// The bolt is the one Storm draws for a loud, bass-heavy hit; here the next
// frame is told it is one, and the screen is taken while it is brightest.
//   node storm-shot.js            both
//   node storm-shot.js phone|tv   one
const { chromium } = require('playwright');
const path = require('path');

const base = 'http://127.0.0.1:8296';
const root = path.resolve(__dirname, '..', '..');
const which = process.argv[2] || 'both';
const TITLE = 'Afterglow', ARTIST = 'Neon Coast', ALBUM = 'Afterglow';

async function shoot(browser, name, ctxOpts, query, out) {
  const ctx = await browser.newContext(ctxOpts);
  const page = await ctx.newPage();
  if (name === 'tv') {
    // A TV draws the animation at 0.6 of a pixel and half the rain, to keep
    // a projector smooth; the picture is drawn as sharp as a phone's.
    await page.route('**/static/app.js*', async (route) => {
      const res = await route.fetch();
      const body = (await res.text()).replace('const VIZ_DENSITY = TV ? 0.5 : 1;', 'const VIZ_DENSITY = 1;')
        .replace('const dpr = TV ? 0.6 : Math.min(window.devicePixelRatio || 1, 2);', 'const dpr = Math.min(window.devicePixelRatio || 1, 2);');
      await route.fulfill({ response: res, body });
    });
  }
  page.on('pageerror', (e) => console.log('page error:', e.message));
  await page.request.post(`${base}/api/login`, { data: { username: 'smoke', password: 'smoke test password 4417' } });
  await page.goto(base + query);
  await page.waitForFunction(() => !document.getElementById('app').classList.contains('hidden'), null, { timeout: 30000 });
  await page.evaluate(async () => {
    state.prefs = state.prefs || {};
    state.prefs.coverStyle = 'storm';
    const r = await (await fetch('/api/search?q=&kind=music')).json();
    // A song on the blue album, whose cover gives the storm its colours.
    const i = Math.max(0, r.items.findIndex((x) => /First Album/.test(JSON.stringify(x))));
    playQueue(r.items, i);
    openNowPlaying();
  });
  await page.waitForFunction(() => document.getElementById('audio-player').currentTime > 0.3, null, { timeout: 30000 });
  // Made-up names, as the other shots use.
  await page.evaluate(({ TITLE, ARTIST, ALBUM }) => {
    const set = (sel, text) => document.querySelectorAll(sel).forEach((e) => { e.textContent = text; });
    set('#np-title', TITLE);
    const a = document.querySelector('#np-sub');
    if (a) a.textContent = `${ARTIST} — ${ALBUM}`;
  }, { TITLE, ARTIST, ALBUM });
  // Let the rain and clouds settle in.
  await page.waitForTimeout(6000);
  // The next frame is a big close strike; the screen is taken as it lands.
  await page.evaluate(() => new Promise((done) => {
    // A big branching bolt to the ground beside the play button (which keeps
    // a clear circle round it), not one crawling across the clouds: Storm picks at random, so it is asked again
    // until it picks that.
    const made = stormBolt;
    stormBolt = (w, h, s, age) => {
      for (let n = 0; n < 500; n++) {
        const b = made(w, h, s, age);
        if (b.tier === 2 && !b.crawl && b.branches.length >= 5 && Math.abs(b.ex - b.x) < w * 0.2 &&
          Math.abs(b.ex - w / 2) > w * 0.2 && Math.abs(b.ex - w / 2) < w * 0.32) return b;
      }
      return made(w, h, s, age);
    };
    const orig = VIZ_SCENES.storm;
    let fired = false, frames = 0;
    VIZ_SCENES.storm = (st, m) => {
      if (!fired) {
        fired = true;
        Object.assign(m, { drop: true, firstDrop: false, dropPower: 1, dropLoud: 0.97, dropBass: 0.95, dropEnv: 1 });
      }
      orig(st, m);
      if (fired && ++frames === 3) done();
    };
  }));
  await page.screenshot({ path: out });
  await ctx.close();
  console.log('wrote', path.relative(root, out));
}

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', args: ['--autoplay-policy=no-user-gesture-required'] });
  if (which !== 'tv') {
    await shoot(browser, 'phone', { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
      '/', path.join(root, 'web', 'shots', 'now-playing.png'));
  }
  if (which !== 'phone') {
    await shoot(browser, 'tv', { viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 },
      '/?tv=1', path.join(root, 'web', 'shots', 'tv.png'));
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
