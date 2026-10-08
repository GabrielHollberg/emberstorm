// Checks the reader's stylesheet cleaning (cleanCSS in reader.js) against
// what a book could use to reach the server or the outside, and what a
// book's own stylesheet needs kept. Run: node scripts/reader-css-check.js
const fs = require('fs');
const path = require('path');

global.location = { origin: 'https://h.example', host: 'h.example' };
const src = fs.readFileSync(path.join(__dirname, '../internal/webui/assets/reader.js'), 'utf8');
const start = src.indexOf('function ownReference');
const end = src.indexOf('// What a part that is not a page');

const clean = new Function(`${src.slice(start, end)}; return cleanCSS;`)();

const keep = [
  'p{background:url("blob:https://h.example/abc")}',
  'p{background:url(img/a.png)}',
  '@font-face{src:url("blob:https://h.example/f")} q{content:"\\201C"}',
  'p{background:image-set("a.png" 1x, "b.png" 2x)}',
];
const drop = [
  'p{background:url("/api/hls/x")}',
  'p{background:url(https://evil.example/x)}',
  '@import "/api/users";',
  '@import url("https://evil.example/a.css");',
  'p{background:image-set("/api/x" 1x)}',
  'p{background:u\\72l(/api/x)}',
  'p{background:url("\\2f api")}',
  'p{background:url("blob:https://evil.example/x")}',
];
let bad = 0;
for (const css of keep) {
  if (clean(css) !== css) { bad++; console.log('changed, should be kept:', css, '->', clean(css)); }
}
for (const css of drop) {
  const out = clean(css);
  if (/api|evil/.test(out)) { bad++; console.log('kept, should go:', css, '->', out); }
}
console.log(bad ? `${bad} failed` : `all ${keep.length + drop.length} as they should be`);
process.exit(bad ? 1 : 0);
