// Repairs text that Windows PowerShell 5.1 read as cp1252 and wrote back as UTF-8.
// Usage: node tools/fix-mojibake.mjs <file> [<file> ...]
import { readFileSync, writeFileSync } from 'node:fs';

for (const f of process.argv.slice(2)) {
  let s = readFileSync(f, 'utf8');
  const before = s;
  s = s.replace(/^﻿/, '');                       // BOM added by Set-Content -Encoding utf8
  s = s.replace(/Â([ -¿])/g, '$1');   // "Â·" -> "·", "Â§" -> "§"
  if (s !== before) { writeFileSync(f, s); console.log(`fixed ${f}`); } else console.log(`clean ${f}`);
}
