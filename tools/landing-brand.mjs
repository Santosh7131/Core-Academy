// Renames the product on the landing page, in one go.
//
//   node tools/landing-brand.mjs "NewName"
//   node tools/landing-brand.mjs "NewName" --repo owner/repo
//   node tools/landing-brand.mjs --site https://example.com   (the address the page will live at)
//   node tools/landing-brand.mjs --check                      (lists what is still to fill in, changes nothing)
//
// The current name, the GitHub repository the download button reads from and, once known, the address
// the page lives at are kept in landing/brand.json. The page is plain files with no build step, so a
// rename is a find and replace across them; this script does it and updates brand.json. The Open Graph
// picture (landing/assets/og.png) carries the name too and has to be redrawn by hand.
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { join, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'landing');
const brandPath = join(root, 'brand.json');
const brand = JSON.parse(readFileSync(brandPath, 'utf8'));
const TEXT = new Set(['.html', '.css', '.js', '.svg', '.txt', '.md', '.json', '']);
const SKIP = new Set(['vendor', 'fonts']);

function* files(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (!SKIP.has(name)) yield* files(path);
    } else if (TEXT.has(extname(name)) && name !== 'brand.json') {
      yield path;
    }
  }
}

const args = process.argv.slice(2);

if (args.includes('--check')) {
  let left = 0;
  for (const path of files(root)) {
    const text = readFileSync(path, 'utf8');
    for (const [i, line] of text.split('\n').entries()) {
      for (const m of line.matchAll(/FILL IN[^<"]*/g)) {
        left++;
        console.log(`${path.slice(root.length + 1)}:${i + 1}  ${m[0].trim()}`);
      }
    }
  }
  console.log(left ? `\n${left} blank(s) still to fill in.` : 'No blanks left.');
  if (!brand.site) console.log('The page address is not set: run with --site https://your-domain so link previews find the picture.');
  process.exit(0);
}

const flagValue = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : null;
};
const newRepo = flagValue('--repo');
const newSite = flagValue('--site');
const valueAt = new Set(['--repo', '--site'].map((f) => args.indexOf(f)).filter((i) => i >= 0).map((i) => i + 1));
const newName = args.find((a, i) => !a.startsWith('--') && !valueAt.has(i));
if (!newName && !newRepo && !newSite) {
  console.error('Give the new name, for example: node tools/landing-brand.mjs "Slate"');
  process.exit(1);
}
if (newName && !/^[A-Za-z0-9][A-Za-z0-9 .'-]{0,30}$/.test(newName)) {
  console.error('Use letters, digits, spaces, dots, apostrophes and hyphens only (at most 31 characters).');
  process.exit(1);
}
if (newRepo && !/^[\w.-]+\/[\w.-]+$/.test(newRepo)) {
  console.error('The repository looks like owner/name.');
  process.exit(1);
}
if (newSite && !/^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(newSite)) {
  console.error('The site address looks like https://example.com, with no path and no trailing slash.');
  process.exit(1);
}

let changed = 0;
for (const path of files(root)) {
  const before = readFileSync(path, 'utf8');
  let after = before;
  if (newName && newName !== brand.name) after = after.split(brand.name).join(newName);
  if (newRepo && newRepo !== brand.repo) after = after.split(brand.repo).join(newRepo);
  if (after !== before) {
    writeFileSync(path, after);
    changed++;
    console.log('updated', path.slice(root.length + 1));
  }
}

// Link previews need absolute addresses: the picture, and the page's own address.
if (newSite) {
  for (const [file, page] of [['index.html', ''], ['privacy.html', 'privacy']]) {
    const target = join(root, file);
    const url = `${newSite}/${page}`;
    const tags = file === 'index.html'
      ? [`<meta property="og:url" content="${url}">`, `<link rel="canonical" href="${url}">`]
      : [`<link rel="canonical" href="${url}">`];
    let html = readFileSync(target, 'utf8');
    html = html.replace(/<meta property="og:url"[^>]*>\n?/g, '').replace(/<link rel="canonical"[^>]*>\n?/g, '');
    html = html.replace(/(<meta name="description"[^>]*>\n)/, `$1${tags.join('\n')}\n`);
    html = html.replace(/<meta property="og:image" content="[^"]*">/, `<meta property="og:image" content="${newSite}/assets/og.png">`);
    writeFileSync(target, html);
    console.log('address set in', file);
  }
  brand.site = newSite;
}
if (newName) brand.name = newName;
if (newRepo) brand.repo = newRepo;
writeFileSync(brandPath, `${JSON.stringify(brand, null, 2)}\n`);
console.log(`\n${changed} file(s) changed. Name: ${brand.name}. Repository: ${brand.repo}.${brand.site ? ` Address: ${brand.site}.` : ''}`);
if (newName) console.log('Redraw landing/assets/og.png if it shows the old name.');
