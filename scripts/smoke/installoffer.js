// The app offer on the test server (offerInstall): an Android phone is offered
// the phone app (its download), an iPhone nothing until the App Store listing
// is set (APP_STORE_URL), a computer nothing. The web app is never offered.
//   node scripts/smoke/installoffer.js
const { chromium, devices } = require('playwright');
const base = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  let failed = false;
  for (const [n, opts, want] of [['android', devices['Pixel 7'], true], ['iphone', devices['iPhone 13'], false], ['computer', { viewport: { width: 1280, height: 800 } }, false]]) {
    const ctx = await b.newContext(opts);
    const p = await ctx.newPage();
    await p.request.post(`${base}/api/login`, { data: { username: 'smoke', password: 'smoke test password 4417' } });
    await p.goto(base); await p.waitForTimeout(4000);
    const shown = await p.isVisible('#install-offer');
    console.log(`${shown === want ? 'ok  ' : 'FAIL'} ${n}: offer ${shown ? 'shown' : 'not shown'}`);
    failed = failed || shown !== want;
    await ctx.close();
  }
  await b.close();
  process.exit(failed ? 1 : 0);
})();
