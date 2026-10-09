// Sends big files to the throwaway test server from Firefox, as the page's
// uploadOne does (one XMLHttpRequest PUT with the File as its body), to find
// where a large upload fails. Usage: node bigupload.js <file>...
const { firefox } = require('playwright');

const BASE = process.env.SMOKE_URL || 'http://127.0.0.1:8296';

(async () => {
  const browser = await firefox.launch();
  const page = await (await browser.newContext({ ignoreHTTPSErrors: true })).newPage();
  await page.goto(BASE + '/');
  // A fresh server (the HTTPS one) needs its account made first.
  await page.evaluate(async (code) => fetch('/api/signup', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'smoke', password: 'smoke test password 4417', setupCode: code }),
  }), process.env.SETUP_CODE || '');
  const login = await page.evaluate(async () => (await fetch('/api/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'smoke', password: 'smoke test password 4417' }),
  })).status);
  console.log('login', login);
  await page.setContent('<input type="file" id="f" multiple>');
  await page.goto(BASE + '/');
  await page.evaluate(() => { const i = document.createElement('input'); i.type = 'file'; i.id = 'pick'; document.body.append(i); });
  for (const path of process.argv.slice(2)) {
    await page.setInputFiles('#pick', path);
    const result = await page.evaluate((kind) => new Promise((resolve) => {
      const file = document.getElementById('pick').files[0];
      const started = performance.now();
      let loaded = 0;
      const params = new URLSearchParams({ path: file.name, kind });
      const r = new XMLHttpRequest();
      r.open('PUT', '/api/upload?' + params);
      r.upload.addEventListener('progress', (e) => { loaded = e.loaded; });
      const took = () => ((performance.now() - started) / 1000).toFixed(1) + 's';
      r.addEventListener('load', () => resolve(`${file.name} (${file.size}): status ${r.status} after ${took()} - ${r.responseText.slice(0, 160)}`));
      r.addEventListener('error', () => resolve(`${file.name} (${file.size}): ERROR (connection lost) after ${took()}, ${loaded} bytes sent`));
      r.send(file);
    }), process.env.UPLOAD_KIND || 'video');
    console.log(result);
  }
  await browser.close();
})();
