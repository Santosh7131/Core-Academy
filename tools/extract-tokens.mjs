// Copies the Soft Structuralism token layer verbatim out of the design guide:
//   §6 Flutter block -> app/lib/theme.dart   (accent renamed to its single purpose)
//   §7 CSS block     -> design/comps/tokens.css
// Run from the project root: node tools/extract-tokens.mjs
import { readFileSync, writeFileSync } from 'node:fs';

const guide = readFileSync('design/soft-structuralism-ui-guide.md', 'utf8').replace(/\r\n/g, '\n');

function block(sectionTitle, lang) {
  const start = guide.indexOf(sectionTitle);
  if (start < 0) throw new Error(`section not found: ${sectionTitle}`);
  const open = guide.indexOf('```' + lang + '\n', start);
  const close = guide.indexOf('\n```', open + 4);
  return guide.slice(open + lang.length + 4, close + 1);
}

function replaceOnce(src, from, to) {
  const n = src.split(from).length - 1;
  if (n !== 1) throw new Error(`expected exactly one "${from}", found ${n}`);
  return src.replace(from, to);
}

// ---- Flutter (§6)
let dart = block('## 6. Flutter implementation', 'dart');
dart = replaceOnce(dart,
  '// ---- the ONE accent. Give it a single purpose and enforce it.\nconst accent = Color(0xFF5B3DF5);\nColor get accentSoft =>',
  '// ---- the ONE accent. Single purpose: the AI paper reader (Papers tab,\n// "Read with AI", the AI mark on drafted questions). Nowhere else.\nconst aiAccent = Color(0xFF5B3DF5);\nColor get aiAccentSoft =>');
writeFileSync('app/lib/theme.dart',
  '// Soft Structuralism token layer — copied verbatim from the design guide §6\n' +
  '// by tools/extract-tokens.mjs. Only the accent was renamed to its purpose.\n' +
  '// Do not retype values here; change the guide and re-run the script.\n' +
  '// ignore_for_file: unused_local_variable\n\n' + dart);

// ---- CSS (§7)
let css = block('## 7. CSS implementation', 'css');
css = replaceOnce(css, '/* ONE purpose only */', '/* ONE purpose only: the AI paper reader */');
writeFileSync('design/comps/tokens.css',
  '/* Soft Structuralism tokens — copied verbatim from the design guide §7\n' +
  '   by tools/extract-tokens.mjs. */\n' + css);

console.log(`theme.dart: ${dart.split('\n').length} lines, tokens.css: ${css.split('\n').length} lines`);
