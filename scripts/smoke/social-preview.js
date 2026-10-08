// Draws web/social-preview.png (1280x640, GitHub's and the website's link
// preview): the wordmark and what EmberStorm is on the left, three phone
// screenshots from web/shots on the right. Drawn in the app's own page on the
// test server, so the wordmark is the app's (its stylesheet and cloud).
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const base = 'http://127.0.0.1:8296';
const root = path.resolve(__dirname, '..', '..');
const shot = (n) => 'data:image/png;base64,' + fs.readFileSync(path.join(root, 'web', 'shots', n)).toString('base64');

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 640 }, deviceScaleFactor: 1 })).newPage();
  await page.goto(base + '/');
  await page.waitForLoadState('networkidle');
  await page.evaluate(({ photos, playing, home }) => {
    document.body.className = '';
    document.body.innerHTML = `
      <div id="sp">
        <div class="left">
          <div class="wordmark sp-mark">EmberStorm</div>
          <p class="lead">Your music, films, TV, audiobooks, ebooks and photos. One app, in your own home.</p>
          <p class="tags"><b>Self-hosted</b> · open source · no subscription</p>
        </div>
        <img class="ph a" src="${photos}">
        <img class="ph c" src="${home}">
        <img class="ph b" src="${playing}">
      </div>`;
    const st = document.createElement('style');
    st.textContent = `
      html, body { margin: 0; overflow: hidden; background: #000; }
      #sp { position: fixed; inset: 0; width: 1280px; height: 640px; overflow: hidden; color: #f3f5f8;
        background: radial-gradient(1100px 700px at 0% 0%, #1a0a14 0%, #050507 55%, #000 100%); }
      .left { position: absolute; left: 72px; top: 200px; width: 560px; }
      .sp-mark { font-size: 60px; color: #f3f5f8; }
      .lead { font-size: 28px; line-height: 1.3; margin: 22px 0 22px; font-weight: 600; }
      .tags { font-size: 23px; color: #9aa3af; margin: 0; }
      .tags b { color: #6aa8ff; font-weight: 600; }
      .ph { position: absolute; width: 238px; border-radius: 30px; border: 6px solid #1c1f26;
        box-shadow: 0 24px 60px rgba(0,0,0,.65); background: #000; }
      .ph.a { left: 668px; top: 108px; transform: rotate(-9deg); }
      .ph.c { left: 1080px; top: 92px; transform: rotate(9deg); }
      .ph.b { left: 862px; top: 44px; width: 240px; }
    `;
    document.head.append(st);
  }, { photos: shot('photos.png'), playing: shot('now-playing.png'), home: shot('home.png') });
  await page.waitForTimeout(800);
  await page.screenshot({ path: path.join(root, 'web', 'social-preview.png') });
  await browser.close();
  console.log('wrote web/social-preview.png');
})().catch((e) => { console.error(e); process.exit(1); });
