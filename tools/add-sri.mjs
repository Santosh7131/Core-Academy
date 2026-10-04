// Adds Subresource Integrity hashes to the CDN tags in design/comps/*.html.
// Run from the project root: node tools/add-sri.mjs
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';

const urls = [
  'https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css',
  'https://cdn.jsdelivr.net/npm/@phosphor-icons/web@2.1.1/src/light/style.css',
  'https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js',
];

const sri = {};
for (const u of urls) {
  const res = await fetch(u);
  if (!res.ok) throw new Error(`${u}: HTTP ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  sri[u] = 'sha384-' + createHash('sha384').update(buf).digest('base64');
}

const dir = 'design/comps';
for (const f of readdirSync(dir).filter((n) => n.endsWith('.html'))) {
  let html = readFileSync(`${dir}/${f}`, 'utf8');
  const before = html;
  for (const [u, h] of Object.entries(sri)) {
    const attr = ` integrity="${h}" crossorigin="anonymous"`;
    html = html
      .replace(`<link rel="stylesheet" href="${u}">`, `<link rel="stylesheet" href="${u}"${attr}>`)
      .replace(`<script src="${u}"></script>`, `<script src="${u}"${attr}></script>`);
  }
  if (html !== before) { writeFileSync(`${dir}/${f}`, html); console.log(`updated ${f}`); }
}
