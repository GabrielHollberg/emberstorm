// The once-per-browser offer to install EmberStorm as an app, on the test
// server. A real install question only comes on a trusted https address, so
// the browser's beforeinstallprompt is played by hand.
//   node scripts/smoke/installoffer.js
const { chromium } = require('playwright');

const base = process.env.SMOKE_URL || 'http://127.0.0.1:8296';
const ACCOUNT = { username: 'smoke', password: 'smoke test password 4417' };
const out = process.env.SHOTS || require('os').tmpdir();

async function fakeInstallQuestion(page) {
  return page.evaluate(() => {
    const e = new Event('beforeinstallprompt', { cancelable: true });
    window.__asked = 0;
    e.prompt = async () => { window.__asked++; };
    e.userChoice = Promise.resolve({ outcome: 'accepted' });
    window.dispatchEvent(e);
  });
}

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const errors = [];

  // A computer's Chrome: offered, Install asks the browser, then never again.
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => errors.push(e.message));
  await page.request.post(`${base}/api/login`, { data: ACCOUNT });
  await page.request.patch(`${base}/api/prefs`, { data: { welcomeDone: true } });
  await page.goto(base);
  await page.waitForSelector('#home-view:not(.hidden)');
  await fakeInstallQuestion(page);
  await page.waitForTimeout(300);
  const shown = await page.isVisible('#install-offer');
  console.log('computer: offered', shown, JSON.stringify(await page.textContent('#install-offer-title')));
  await page.screenshot({ path: `${out}/install-computer.png` });
  await page.click('#install-offer-yes');
  await page.waitForTimeout(300);
  console.log('computer: browser asked', await page.evaluate(() => window.__asked), 'kept', await page.evaluate(() => localStorage.getItem('soundstorm-install-offered')));
  await page.reload();
  await page.waitForSelector('#home-view:not(.hidden)');
  await fakeInstallQuestion(page);
  await page.waitForTimeout(300);
  console.log('computer: offered again after reload', await page.isVisible('#install-offer'));
  await ctx.close();

  // An iPhone's Safari: how to add it, once; Not now remembered too.
  const phone = await browser.newContext({
    viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true,
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  });
  const p2 = await phone.newPage();
  p2.on('pageerror', (e) => errors.push(e.message));
  await p2.request.post(`${base}/api/login`, { data: ACCOUNT });
  await p2.goto(base);
  await p2.waitForSelector('#home-view:not(.hidden)');
  await p2.waitForTimeout(500);
  console.log('iphone: offered', await p2.isVisible('#install-offer'), JSON.stringify(await p2.textContent('#install-offer-text')), JSON.stringify(await p2.textContent('#install-offer-yes')));
  await p2.screenshot({ path: `${out}/install-iphone.png` });
  await p2.click('#install-offer-no');
  await p2.reload();
  await p2.waitForSelector('#home-view:not(.hidden)');
  await p2.waitForTimeout(500);
  console.log('iphone: offered again after Not now', await p2.isVisible('#install-offer'));
  await phone.close();
  console.log('page errors:', errors);
  await browser.close();
})();
