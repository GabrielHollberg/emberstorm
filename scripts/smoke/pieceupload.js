// The page's own big-file upload (pieces) against the throwaway test server,
// in Firefox, with the first piece's connection cut on purpose to see it sent
// again. Usage: node pieceupload.js <file> [chromium|firefox]
const pw = require('playwright');

const BASE = process.env.SMOKE_URL || 'http://127.0.0.1:8296';

(async () => {
  const which = process.argv[3] || 'firefox';
  const browser = await pw[which].launch();
  const page = await (await browser.newContext({ ignoreHTTPSErrors: true })).newPage();
  let cut = 0;
  let pieces = 0;
  await page.route('**/api/upload/pieces/*?offset=*', (route) => {
    pieces += 1;
    if (cut === 0 && route.request().url().includes('offset=0')) { cut += 1; return route.abort('connectionreset'); }
    return route.continue();
  });
  await page.goto(BASE + '/');
  await page.evaluate(() => fetch('/api/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'smoke', password: 'smoke test password 4417' }),
  }));
  await page.goto(BASE + '/');
  await page.waitForFunction(() => typeof uploadOne === 'function');
  await page.evaluate(() => { const i = document.createElement('input'); i.type = 'file'; i.id = 'pick'; document.body.append(i); });
  await page.setInputFiles('#pick', process.argv[2]);
  const started = Date.now();
  const result = await page.evaluate(async () => {
    const file = document.getElementById('pick').files[0];
    INTAKE.stop = false;
    return uploadOne({ path: file.name, kind: 'video', file }, () => {});
  });
  console.log(`${which}: ${JSON.stringify(result)} in ${((Date.now() - started) / 1000).toFixed(1)}s, ${pieces} piece requests, ${cut} cut on purpose`);
  await browser.close();
})();
