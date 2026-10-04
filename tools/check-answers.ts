// Proves every sample question's marked answer: the option at `correct` must equal the
// independently computed `expect`, and no other option may equal it.
// Usage: node tools/check-answers.ts
import { chapters, questions } from './sample-data.ts';

function value(opt: string): number | null {
  const s = opt
    .replace(/\$/g, '')
    .replace(/\\ /g, ' ')
    .replace(/\\text\{[^}]*\}/g, '')
    .replace(/\^\\circ/g, '')
    .replace(/\^[23]/g, '')
    .replace(/^x\s*=\s*/, '')
    .replace(/\s*cm[²³]?$/, '') // plain units: "28 cm²"
    .trim();
  const frac = s.match(/^(-?)\\t?frac\{(\d+(?:\.\d+)?)\}\{(\d+(?:\.\d+)?)\}$/);
  if (frac) return ((frac[1] ? -1 : 1) * Number(frac[2])) / Number(frac[3]);
  if (/^-?\d+(\.\d+)?$/.test(s)) return Number(s);
  return null;
}

const same = (a: number, b: number) => Math.abs(a - b) < 1e-6;
let failures = 0;
let total = 0;

for (const [cls, list] of Object.entries(questions)) {
  for (const [i, qq] of list.entries()) {
    total++;
    const where = `class ${cls} Q${i + 1}`;
    const fail = (msg: string) => { failures++; console.log(`FAIL ${where}: ${msg}`); };
    if (!chapters[Number(cls)].includes(qq.chapter)) fail(`unknown chapter ${qq.chapter}`);
    if (new Set(qq.options).size !== 4) fail('options are not 4 distinct values');
    if (typeof qq.expect === 'number') {
      const expect = qq.expect;
      const vals = qq.options.map(value);
      const v = vals[qq.correct];
      if (v === null) fail(`correct option "${qq.options[qq.correct]}" is not numeric`);
      else if (!same(v, expect)) fail(`marked ${v}, expected ${expect}`);
      vals.forEach((x, k) => { if (k !== qq.correct && x !== null && same(x, expect)) fail(`option ${k} also equals the answer`); });
    } else {
      if (qq.options[qq.correct] !== qq.expect) fail(`marked "${qq.options[qq.correct]}", expected "${qq.expect}"`);
      qq.options.forEach((o, k) => { if (k !== qq.correct && o === qq.expect) fail(`option ${k} also equals the answer`); });
    }
  }
}
console.log(`${total} questions checked, ${failures} failure${failures === 1 ? '' : 's'}`);
process.exit(failures ? 1 : 0);
