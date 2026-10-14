// Raw screens for the app stores' pictures, on the test server with made-up
// music (scripts/store-media.py) and the demo's free films, photos and books:
// Home, Now Playing caught as a big lightning bolt lands, a visualizer at a
// strike, an album, the films, the photo timeline, a book, and a TV-sized
// storm for the feature graphic. scripts/store-frames.py then frames them.
//
//   node store-shots.js OUT_DIR
const { chromium } = require('playwright');
const path = require('path');

const base = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
const out = process.argv[2] || '.';
const phone = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true };

async function signedIn(browser, opts, query = '/') {
  const ctx = await browser.newContext(opts);
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.log('page error:', e.message));
  if (query.includes('tv=1')) {
    // A TV draws its looks at less than a pixel to keep a projector smooth;
    // the picture is drawn as sharp as a phone's here.
    await page.route('**/static/app.js*', async (route) => {
      const res = await route.fetch();
      const body = (await res.text()).replace('const VIZ_DENSITY = TV ? 0.5 : 1;', 'const VIZ_DENSITY = 1;')
        .replace('const dpr = TV ? 0.6 : Math.min(window.devicePixelRatio || 1, 2);', 'const dpr = Math.min(window.devicePixelRatio || 1, 2);');
      await route.fulfill({ response: res, body });
    });
  }
  await page.request.post(`${base}/api/login`, { data: { username: 'smoke', password: 'smoke test password 4417' } });
  await page.goto(base + query, { waitUntil: 'load' });
  await page.waitForFunction(() => !document.getElementById('app').classList.contains('hidden'), null, { timeout: 30000 });
  await page.waitForTimeout(2500);
  return { ctx, page };
}

async function clean(page) {
  await page.evaluate(() => {
    document.body.classList.remove('demo-account');
    for (const id of ['hold-tip', 'install-offer', 'welcome']) { const e = document.getElementById(id); if (e) e.classList.add('hidden'); }
    document.querySelectorAll('.toast').forEach((e) => e.remove());
  });
  await page.waitForTimeout(600);
}

async function shot(page, name) {
  await clean(page);
  await page.screenshot({ path: path.join(out, `${name}.png`) });
  console.log('wrote', name);
}

async function pill(page, re) {
  await page.evaluate((src) => {
    const b = [...document.querySelectorAll('#subtabs button, #music-tabs button')].find((x) => new RegExp(src).test(x.textContent));
    if (b) b.click();
  }, re.source);
}

async function tab(page, name) {
  await page.evaluate((n) => document.querySelector(`#tabs [data-tab="${n}"]`).click(), name);
  await page.waitForTimeout(3000);
}

// Plays the album's first song in a look, and holds the next frame to a big
// strike, the screen taken as it is brightest.
async function strike(page, album, look) {
  await page.evaluate(async ({ album, look }) => {
    state.prefs = state.prefs || {};
    state.prefs.coverStyle = look;
    const r = await (await fetch('/api/search?q=' + encodeURIComponent(album) + '&kind=music')).json();
    const items = r.items.filter((x) => JSON.stringify(x).includes(album));
    playQueue(items.length ? items : r.items, 0);
    openNowPlaying();
    applyCoverStyle();
  }, { album, look });
  await page.waitForFunction(() => document.getElementById('audio-player').currentTime > 0.3, null, { timeout: 30000 });
  await page.waitForTimeout(7000);
  await page.evaluate((look) => new Promise((done) => {
    if (look === 'storm') {
      const made = stormBolt;
      stormBolt = (w, h, s, age) => {
        for (let n = 0; n < 500; n++) {
          const b = made(w, h, s, age);
          if (b.tier === 2 && !b.crawl && b.branches.length >= 5 && Math.abs(b.ex - b.x) < w * 0.2 &&
            Math.abs(b.ex - w / 2) > w * 0.2 && Math.abs(b.ex - w / 2) < w * 0.32) return b;
        }
        return made(w, h, s, age);
      };
    }
    const scenes = (typeof FULL_SCENES !== 'undefined' && FULL_SCENES[look]) ? FULL_SCENES : VIZ_SCENES;
    const orig = scenes[look];
    let fired = false, frames = 0;
    scenes[look] = (st, m) => {
      if (!fired) { fired = true; Object.assign(m, { drop: true, firstDrop: false, dropPower: 1, dropLoud: 0.97, dropBass: 0.95, dropEnv: 1 }); }
      orig(st, m);
      if (fired && ++frames === (look === 'storm' ? 3 : 8)) done();
    };
    setTimeout(done, 4000);
  }), look);
}

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', args: ['--autoplay-policy=no-user-gesture-required'] });
  let { ctx, page } = await signedIn(browser, phone);
  // Music's albums, every cover.
  await tab(page, 'music');
  await pill(page, /Albums/); await page.waitForTimeout(2500);
  // Only the made-up albums: not the test server's own plain ones.
  await page.evaluate(() => document.querySelectorAll('#music-view *').forEach((e) => {
    if (e.children.length && /Smoke Band|Test Trio/.test(e.textContent) && e.querySelector('img') && !e.querySelector('[class*=grid]')) {
      if (e.parentElement && e.parentElement.children.length > 2) e.style.display = 'none';
    }
  }));
  await shot(page, 'albums');
  // The films, once each and without the test server's Continue row (its
  // test film was matched to one of them in an earlier test).
  await tab(page, 'watch');
  await page.evaluate(() => {
    document.querySelectorAll('#continue, .continue-row').forEach((e) => { e.style.display = 'none'; });
    const seen = new Set();
    document.querySelectorAll('#results > *').forEach((e) => {
      const t = (e.textContent || '').trim();
      if (seen.has(t)) e.style.display = 'none'; else seen.add(t);
    });
  });
  await shot(page, 'films');
  await tab(page, 'photos'); await page.waitForTimeout(2500); await shot(page, 'photos');
  await tab(page, 'music');
  await page.evaluate(async () => {
    const r = await (await fetch('/api/music/albums?size=100')).json();
    const list = r.albums || r.items || [];
    const a = list.find((x) => /Starlight Motel/.test(x.name || x.title || '')) || list[0];
    if (a) await showAlbum(a.sourceId, a.id);
  });
  await page.waitForTimeout(3000); await shot(page, 'album');
  await strike(page, 'Afterglow', 'storm'); await shot(page, 'storm');
  await page.evaluate(() => stopAudio());
  await strike(page, 'Prism', 'galaxy'); await shot(page, 'galaxy');
  await page.evaluate(() => stopAudio());
  await strike(page, 'City of Glass', 'aurora'); await shot(page, 'aurora');
  await page.evaluate(() => stopAudio());
  await page.evaluate(() => { const n = document.getElementById('now-playing'); if (n && typeof closeNowPlaying === 'function') closeNowPlaying(); });
  await tab(page, 'books');
  await pill(page, /Ebooks/); await page.waitForTimeout(3000); await shot(page, 'books');
  await ctx.close();

  // The TV: a storm across the whole screen, for the feature graphic.
  ({ ctx, page } = await signedIn(browser, { viewport: { width: 1280, height: 720 }, deviceScaleFactor: 2 }, '/?tv=1'));
  await strike(page, 'Afterglow', 'storm'); await shot(page, 'tv-storm');
  await ctx.close();
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
