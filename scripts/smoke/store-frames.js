// The app stores' pictures from store-shots.js's raw screens: each screen in
// a phone, under a headline, on a glow in its own colours (1080x1920), and
// the feature graphic (1024x500) from the TV-sized storm.
//
//   node store-frames.js RAW_DIR OUT_DIR
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const raw = path.resolve(process.argv[2] || 'raw');
const out = path.resolve(process.argv[3] || 'framed');
const assets = path.resolve(__dirname, '../../internal/webui/assets');
const url = (f) => 'file:///' + f.replace(/\\/g, '/');

// Order is the store's order: the first two are what most people see.
const SHOTS = [
  ['storm', 'Music you can see', 'Lightning strikes on the beat.', ['#ff5e8a', '#5a2bc4']],
  ['albums', 'All your music.<br>No subscription.', 'Your own songs, from your own server.', ['#ff7a59', '#7b2ff7']],
  ['galaxy', 'Visuals that dance', 'Twelve looks, each moving with the song.', ['#00c8d2', '#6a1fd0']],
  ['films', 'Your movies,<br>anywhere', 'At home or away, on your phone or TV.', ['#f5a524', '#c2185b']],
  ['photos', 'Your photos<br>stay yours', 'Backed up from your phone to your own server.', ['#38bdf8', '#1d4ed8']],
  ['books', 'Books and<br>audiobooks too', 'Read, listen, or follow along with both.', ['#e0a96d', '#8b3a2f']],
  ['aurora', 'One app for<br>everything', 'Music, movies, TV, books and photos.', ['#22d3ee', '#0f3a8a']],
];

function phonePage(file, title, sub, [a, b]) {
  return `<!doctype html><html><head><style>
  *{margin:0;box-sizing:border-box}
  body{width:1080px;height:1920px;overflow:hidden;font-family:'Segoe UI',sans-serif;color:#fff;
    background:#05040a;position:relative}
  .glow{position:absolute;inset:0;background:
    radial-gradient(900px 700px at 20% 8%, ${a}cc, transparent 70%),
    radial-gradient(900px 900px at 95% 55%, ${b}dd, transparent 70%),
    radial-gradient(700px 600px at 10% 95%, ${b}88, transparent 70%)}
  .grain{position:absolute;inset:0;background:linear-gradient(180deg,rgba(0,0,0,0) 40%,rgba(0,0,0,.35))}
  .brand{position:absolute;top:78px;left:0;right:0;display:flex;justify-content:center;align-items:center;gap:14px;
    font-weight:800;font-style:italic;font-size:40px;letter-spacing:.5px;opacity:.95}
  .brand i{width:50px;height:50px;background:#fff;-webkit-mask:url('${url(path.join(assets, 'cloud.svg'))}') center/contain no-repeat}
  .head{position:relative;padding:160px 60px 0;text-align:center}
  h1{font-family:'Segoe UI Black','Segoe UI',sans-serif;
    font-weight:900;font-size:92px;line-height:1.02;letter-spacing:-1.5px;text-shadow:0 6px 40px rgba(0,0,0,.45)}
  p{margin-top:22px;font-size:40px;font-weight:600;opacity:.88}
  .phone{position:relative;margin:56px auto 0;width:${title.includes('<br>') ? 740 : 780}px;
    border-radius:96px;padding:22px;background:linear-gradient(145deg,#2b2b33,#0b0b0f);
    box-shadow:0 0 0 3px #3a3a44 inset,0 60px 120px rgba(0,0,0,.65),0 0 160px ${a}55}
  .screen{border-radius:76px;overflow:hidden;background:#000;position:relative}
  .screen img{display:block;width:100%}
  .notch{position:absolute;top:22px;left:50%;transform:translateX(-50%);width:34px;height:34px;border-radius:50%;background:#000;
    box-shadow:0 0 0 3px #111}
  </style></head><body><div class="glow"></div><div class="grain"></div>
  <div class="brand"><i></i>EmberStorm</div>
  <div class="head"><h1>${title}</h1><p>${sub}</p></div>
  <div class="phone"><div class="screen"><img src="${url(path.join(raw, file + '.png'))}"><div class="notch"></div></div></div>
  </body></html>`;
}

function featurePage() {
  return `<!doctype html><html><head><style>
  *{margin:0;box-sizing:border-box}
  body{width:1024px;height:500px;overflow:hidden;font-family:'Segoe UI',sans-serif;color:#fff;background:#120a24;position:relative}
  .shot{position:absolute;inset:0;background:url('${url(path.join(raw, 'tv-storm.png'))}') right bottom/112% auto no-repeat}
  .fade{position:absolute;inset:0;background:linear-gradient(90deg,#0d0620 0%,#0d0620ee 30%,#0d062066 58%,transparent 80%)}
  .logo{position:absolute;left:64px;top:120px;display:flex;align-items:center;gap:20px}
  .logo i{width:96px;height:96px;background:#fff;-webkit-mask:url('${url(path.join(assets, 'cloud.svg'))}') center/contain no-repeat;
    filter:drop-shadow(0 0 24px #c9a6ff)}
  .logo b{font-size:74px;font-weight:800;font-style:italic;letter-spacing:-1px;text-shadow:0 0 40px rgba(200,160,255,.5)}
  .tag{position:absolute;left:68px;top:250px;font-size:34px;font-weight:700;line-height:1.2}
  .sub{position:absolute;left:68px;top:340px;font-size:22px;font-weight:600;opacity:.8}
  </style></head><body><div class="shot"></div><div class="fade"></div>
  <div class="logo"><i></i><b>EmberStorm</b></div>
  <div class="tag">Your music, movies, books<br>and photos. Your server.</div>
  <div class="sub">No subscription. No ads. No tracking.</div>
  </body></html>`;
}

(async () => {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ channel: 'chrome', args: ['--allow-file-access-from-files'] });
  const page = await browser.newPage({ viewport: { width: 1080, height: 1920 } });
  const tmp = path.join(out, '_frame.html');
  for (const [i, [file, title, sub, colors]] of SHOTS.entries()) {
    fs.writeFileSync(tmp, phonePage(file, title, sub, colors));
    await page.goto(url(tmp)); await page.waitForTimeout(400);
    await page.screenshot({ path: path.join(out, `${i + 1}-${file}.png`) });
    console.log('framed', file);
  }
  await page.setViewportSize({ width: 1024, height: 500 });
  fs.writeFileSync(tmp, featurePage());
  await page.goto(url(tmp)); await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(out, 'feature-graphic-1024x500.png') });
  fs.unlinkSync(tmp);
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
