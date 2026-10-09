// The rule that decides when AI marks an answer: two models that agree, each sure enough.
// Usage: node tools/votes-test.ts
import { agreed, SURE, SURE_TIEBREAK, verdict, type Pick } from '../api/src/lib/votes.ts';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

const v = (answer: number | null, confidence: number): Pick => ({ answer, confidence });

check('two models that agree and are sure mark the answer', JSON.stringify(agreed([v(2, 0.97), v(2, 1)], SURE)) === '{"answer":2,"confidence":0.97}');
check('how sure the mark is = the less sure of the two', agreed([v(1, 0.91), v(1, 0.99)], SURE)?.confidence === 0.91);
check('two that disagree mark nothing', agreed([v(1, 0.99), v(2, 0.99)], SURE) === null);
check('agreeing but one under the bar marks nothing', agreed([v(1, 0.99), v(1, 0.8)], SURE) === null);
check('a model that found no option does not vote', agreed([v(null, 1), v(1, 0.99)], SURE) === null);
check('a missing answer does not vote', agreed([undefined, v(1, 0.99)], SURE) === null);
check('one model alone never marks', agreed([v(0, 1)], SURE) === null);

// Three votes (the third model breaks a tie)
check('a split pair settled by the third: two of three', agreed([v(0, 0.95), v(1, 0.95), v(1, 0.9)], SURE_TIEBREAK)?.answer === 1);
check('and the answer the third did not choose loses', agreed([v(0, 0.95), v(1, 0.95), v(0, 0.88)], SURE_TIEBREAK)?.answer === 0);
check('three different answers settle nothing', agreed([v(0, 0.95), v(1, 0.95), v(2, 0.95)], SURE_TIEBREAK) === null);
check('a hesitant pair plus a sure third settles at the lower bar', agreed([v(3, 0.86), v(3, 0.8), v(3, 0.95)], SURE_TIEBREAK)?.answer === 3
  && agreed([v(3, 0.86), v(3, 0.8), v(3, 0.95)], SURE_TIEBREAK)?.confidence === 0.86);
check('but the third alone is not enough', agreed([v(null, 0), v(2, 0.6), v(2, 0.99)], SURE_TIEBREAK) === null);
check('option 0 is a real answer, not "none"', agreed([v(0, 0.99), v(0, 0.99)], SURE)?.answer === 0);

// What the checks on one question add up to: the mark, the note on the card, and what each check chose.
const j = (x: unknown) => JSON.stringify(x);
const sure = verdict(v(2, 0.97), v(2, 0.99), undefined, null);
check('two sure checks: marked, no note, no picks to show', sure.mark?.answer === 2 && sure.note === null && sure.picks === null, sure);
const wd = verdict(v(2, 0.97), v(2, 0.99), undefined, 1);
check('marked, but the writer chose another option: the card asks for a look and keeps every pick',
  wd.mark?.answer === 2 && wd.note === 'writer_differs' && j(wd.picks) === '{"writer":1,"solver":2,"checker":2}', wd);
const wsame = verdict(v(2, 0.97), v(2, 0.99), undefined, 2);
check('the writer agreeing changes nothing', wsame.mark?.answer === 2 && wsame.note === null && wsame.picks === null, wsame);
const split = verdict(v(1, 0.95), v(2, 0.95), undefined, null);
check('two that split are left to the tutor, with both picks', split.mark === null && split.note === 'disagree' && j(split.picks) === '{"solver":1,"checker":2}', split);
const hes = verdict(v(3, 0.86), v(3, 0.88), undefined, null);
check('a hesitant pair with no third opinion is not marked: the lower bar needs a third model', hes.mark === null && hes.note === 'unsure', hes);
check('a hesitant pair plus a third that chose the same is marked at the lower bar',
  verdict(v(3, 0.86), v(3, 0.88), v(3, 0.9), null).mark?.confidence === 0.86);
const cantTell = verdict(v(3, 0.86), v(3, 0.88), v(null, 0), null);
check('a third model that could not tell does not lower the bar', cantTell.mark === null && cantTell.note === 'unsure', cantTell);
const settledSplit = verdict(v(1, 0.95), v(2, 0.95), v(2, 0.9), null);
check('a split pair settled by the third: marked, no note', settledSplit.mark?.answer === 2 && settledSplit.note === null, settledSplit);
const three = verdict(v(0, 0.95), v(1, 0.95), v(2, 0.95), null);
check('three different answers stay with the tutor, all three shown',
  three.mark === null && three.note === 'disagree' && j(three.picks) === '{"solver":0,"checker":1,"tiebreak":2}', three);
check('neither first check found an option that fits: a misprint', verdict(v(null, 1), v(null, 1), undefined, null).note === 'no_option');
const lone = verdict(v(1, 0.99), undefined, undefined, null);
check('one check heard and nothing to compare it with: not sure', lone.mark === null && lone.note === 'unsure' && j(lone.picks) === '{"solver":1}', lone);
check('no check heard at all: nothing to show', j(verdict(undefined, undefined, undefined, 3).picks) === '{"writer":3}');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
