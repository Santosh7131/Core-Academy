// Checks which stored objects count as leftovers of the Library: no file row, and old enough that no signed upload link can still write to them.
// Run: node tools/orphans-test.mjs
import { ORPHAN_AFTER_MS, orphansAmong } from '../api/src/lib/orphans.ts';
let fail = 0;
const eq = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) {
    fail++;
    console.log('FAIL', name, '\n  got ', JSON.stringify(got), '\n  want', JSON.stringify(want));
  } else console.log('ok  ', name);
};

const now = Date.parse('2026-11-02T12:00:00Z');
const MIN = 60 * 1000;
const obj = (key, agoMs) => ({ key, modified: agoMs === null ? null : new Date(now - agoMs) });

eq('the gate outlasts a 15 minute link', ORPHAN_AFTER_MS > 15 * MIN, true);
eq('an old object with no row is a leftover', orphansAmong([obj('a', 2 * ORPHAN_AFTER_MS)], new Set(), now), ['a']);
eq('an old object with a row stays', orphansAmong([obj('a', 2 * ORPHAN_AFTER_MS)], new Set(['a']), now), []);
eq('a young object with no row is left alone', orphansAmong([obj('a', 5 * MIN)], new Set(), now), []);
eq('exactly the age is left alone', orphansAmong([obj('a', ORPHAN_AFTER_MS)], new Set(), now), []);
eq('a millisecond over the age is a leftover', orphansAmong([obj('a', ORPHAN_AFTER_MS + 1)], new Set(), now), ['a']);
eq('no write time is left alone', orphansAmong([obj('a', null)], new Set(), now), []);
eq('nothing stored, nothing to throw away', orphansAmong([], new Set(['a']), now), []);
eq(
  'only the old keys nobody knows are picked, in order',
  orphansAmong([obj('keep', 3 * ORPHAN_AFTER_MS), obj('gone1', 3 * ORPHAN_AFTER_MS), obj('fresh', MIN), obj('gone2', 2 * ORPHAN_AFTER_MS)], new Set(['keep']), now),
  ['gone1', 'gone2'],
);
eq('a shorter age can be given', orphansAmong([obj('a', 2000)], new Set(), now, 1000), ['a']);

console.log(fail ? `\n${fail} failed` : '\nall passed');
process.exit(fail ? 1 : 0);
