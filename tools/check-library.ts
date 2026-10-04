// Proves every ready-made question before it can reach the app: four distinct options, the
// marked option equal to the independently computed `expect` and no other option equal to it,
// any `verify` check true, balanced LaTeX, and the same right answer after options are arranged.
// Usage: node tools/check-library.ts
import { arrange, books } from './library/index.ts';

function value(opt: string): number | null {
  const s = opt
    .replace(/\$/g, '')
    .replace(/\\ /g, ' ')
    .replace(/\\text\{[^}]*\}/g, '')
    .replace(/\^\\circ|°[CF]?/g, '')
    .replace(/−/g, '-')
    .replace(/^₹\s*/, '')
    .replace(/(\d),(?=\d)/g, '$1') // 1,200 and the Indian 1,00,000
    .replace(/\s*(sq units|units|cm|mm|km|m|kg|g|mL|L|kWh|km\/h|hours|h|days|years|%|varṇa)?\s*(\^\{?[23]\}?|[²³])?$/, '')
    .trim();
  const frac = s.match(/^(-?)\\t?frac\{(\d+(?:\.\d+)?)\}\{(\d+(?:\.\d+)?)\}$/);
  if (frac) return ((frac[1] ? -1 : 1) * Number(frac[2])) / Number(frac[3]);
  // 5\sqrt{2}, -\sqrt{3}, 2\pi
  const root = s.match(/^(-?\d*(?:\.\d+)?)\\sqrt\{(\d+(?:\.\d+)?)\}$/);
  const pi = s.match(/^(-?\d*(?:\.\d+)?)\\pi$/);
  const coef = (k: string) => (k === '' ? 1 : k === '-' ? -1 : Number(k));
  if (root) return coef(root[1]) * Math.sqrt(Number(root[2]));
  if (pi) return coef(pi[1]) * Math.PI;
  if (/^-?\d+(\.\d+)?$/.test(s)) return Number(s);
  return null;
}

const same = (a: number, b: number) => Math.abs(a - b) < 1e-6;

/** Every $...$ closed, and braces balanced inside each piece of maths. */
function latexOk(s: string): boolean {
  const parts = s.split('$');
  if (parts.length % 2 === 0) return false;
  return parts.every((p, i) => {
    if (i % 2 === 0) return true;
    let depth = 0;
    for (const ch of p.replace(/\\[{}]/g, '')) {
      if (ch === '{') depth++;
      if (ch === '}') depth--;
      if (depth < 0) return false;
    }
    return depth === 0;
  });
}

let failures = 0;
let total = 0;
const spread = [0, 0, 0, 0];
for (const book of books) {
  const seen = new Set<string>();
  let bookCount = 0;
  for (const chapter of book.chapters) {
    if (chapter.questions.length === 0) {
      failures++;
      console.log(`FAIL ${book.classLevel} ${book.subject} / ${chapter.name}: no questions`);
    }
    for (const [i, qq] of chapter.questions.entries()) {
      total++;
      bookCount++;
      const where = `Class ${book.classLevel} ${book.subject} / ${chapter.name} / Q${i + 1}`;
      const fail = (msg: string) => {
        failures++;
        console.log(`FAIL ${where}: ${msg}`);
      };
      if (!qq.text.trim() || !qq.solution.trim()) fail('text or solution is empty');
      if (seen.has(qq.text)) fail('duplicate question text');
      seen.add(qq.text);
      if (qq.options.length !== 4 || qq.options.some((o) => !o.trim())) fail('needs four filled-in options');
      if (new Set(qq.options).size !== 4) fail('options are not all different');
      for (const s of [qq.text, qq.solution, ...qq.options]) if (!latexOk(s)) fail(`unbalanced LaTeX in "${s.slice(0, 50)}"`);
      if (typeof qq.expect === 'number') {
        const expect = qq.expect;
        const vals = qq.options.map(value);
        const v = vals[qq.correct];
        if (v === null) fail(`marked option "${qq.options[qq.correct]}" is not a number`);
        else if (!same(v, expect)) fail(`marked ${v}, but the answer is ${expect}`);
        vals.forEach((x, k) => {
          if (k !== qq.correct && x !== null && same(x, expect)) fail(`option ${'ABCD'[k]} also equals the answer`);
        });
      } else {
        if (qq.options[qq.correct] !== qq.expect) fail(`marked "${qq.options[qq.correct]}", but the answer is "${qq.expect}"`);
        qq.options.forEach((o, k) => {
          if (k !== qq.correct && o === qq.expect) fail(`option ${'ABCD'[k]} also equals the answer`);
        });
      }
      if (qq.verify && !qq.verify()) fail('its verify check is false');
      const stored = arrange(qq);
      if (stored.options[stored.correct] !== qq.options[qq.correct]) fail('arranging the options lost the right answer');
      spread[stored.correct]++;
    }
  }
  console.log(`Class ${book.classLevel} ${book.subject}: ${book.chapters.length} chapters, ${bookCount} questions`);
}
console.log(`${total} questions checked, ${failures} failure${failures === 1 ? '' : 's'}`);
console.log(`right answers stored as A/B/C/D: ${spread.join(' / ')}`);
process.exit(failures ? 1 : 0);
