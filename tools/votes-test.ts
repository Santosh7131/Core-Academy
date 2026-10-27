// The rule that decides when AI marks an answer: at least two different models, each reading the question as having one right
// option, all choosing the same one. A question two options (or none) can answer is never marked.
// Usage: node tools/votes-test.ts
import { HESITANT, readingOf, verdict, type Pick } from '../api/src/lib/votes.ts';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}
const j = JSON.stringify;

/** A model that found exactly one right option. */
const one = (answer: number, confidence = 0.97, by?: string): Pick => ({ answer, confidence, set: [answer], ...(by ? { by } : {}) });
/** A model that found two or more right options. */
const several = (...set: number[]): Pick => ({ answer: null, confidence: 0.95, set });
/** A model that found no right option. */
const none = (confidence = 0.95): Pick => ({ answer: null, confidence, set: [] });

// --- How a model read the question
check('one option at a good confidence is a vote', readingOf(one(2)) === 'one');
check('option 0 is a real answer, not "none"', readingOf(one(0)) === 'one');
check('two options: several', readingOf(several(0, 2)) === 'several');
check('no option: none', readingOf(none()) === 'none');
check('one option but hesitant: counts as none', readingOf(one(1, HESITANT - 0.01)) === 'none' && readingOf(one(1, HESITANT)) === 'one');
check('an old pick without a list: its answer is the one option', readingOf({ answer: 3, confidence: 0.9 }) === 'one' && readingOf({ answer: null, confidence: 1 }) === 'none');

// --- Two models settle it
const agree = verdict({ solver: one(2, 0.97), checker: one(2, 0.99) }, null);
check('two models that choose the same option mark it', agree.mark?.answer === 2 && agree.note === null && agree.picks === null && !agree.more && agree.heard === 2, agree);
check('how sure the mark is = the less sure of them', verdict({ solver: one(1, 0.91), checker: one(1, 0.99) }, null).mark?.confidence === 0.91);
check('option 0 can be marked', verdict({ solver: one(0), checker: one(0) }, null).mark?.answer === 0);
check('old picks (no list) still settle a question', verdict({ solver: { answer: 3, confidence: 0.95 }, checker: { answer: 3, confidence: 0.92 } }, null).mark?.answer === 3);

// --- One model is not enough
const lone = verdict({ solver: one(1) }, null);
check('one model alone never marks, and another may still be asked', lone.mark === null && lone.more && lone.heard === 1 && lone.note === 'unsure', lone);
const nobody = verdict({}, 3);
check('nobody heard: nothing marked, the writer alone shown', nobody.mark === null && nobody.more && j(nobody.picks) === '{"writer":3}', nobody);
check('the same model standing in for two checks is one vote', verdict({ solver: one(1, 0.97, 'm1'), checker: one(1, 0.97, 'm1') }, null).mark === null);
check('two models with different names are two votes', verdict({ solver: one(1, 0.97, 'm1'), checker: one(1, 0.97, 'm2') }, null).mark?.answer === 1);

// --- They split
const split = verdict({ solver: one(1), checker: one(2) }, null);
check('two that choose different options mark nothing and wait for a third', split.mark === null && split.note === 'disagree' && split.more && j(split.picks) === '{"solver":1,"checker":2}', split);
const settled = verdict({ solver: one(1), checker: one(2), tiebreak: one(2) }, null);
check('a third that sides with one of them settles it: two of three', settled.mark?.answer === 2 && !settled.more, settled);
check('and the one it did not choose loses', verdict({ solver: one(0), checker: one(1), tiebreak: one(0) }, null).mark?.answer === 0);
const three = verdict({ solver: one(0), checker: one(1), tiebreak: one(2) }, null);
check('three different answers settle nothing, and nobody else is asked', three.mark === null && three.note === 'disagree' && !three.more, three);

// --- A question two options or none can answer is never marked
const twoRight = verdict({ solver: one(0), checker: several(0, 2) }, null);
check('a model that finds two right options blocks the mark', twoRight.mark === null && twoRight.note === 'disagree' && !twoRight.more, twoRight);
check('even when both chose the same one of them, if the other saw two', verdict({ solver: several(0, 2), checker: several(0, 2) }, null).mark === null);
const noneBoth = verdict({ solver: none(), checker: none() }, null);
check('two that find no right option: a misprint', noneBoth.mark === null && noneBoth.note === 'no_option' && !noneBoth.more, noneBoth);
const noneOne = verdict({ solver: none(), checker: one(1) }, null);
check('one that finds none and one that chose: not marked, left to the tutor', noneOne.mark === null && noneOne.note === 'unsure' && !noneOne.more, noneOne);
check('a hesitant answer blocks the mark like a doubt', verdict({ solver: one(1, 0.6), checker: one(1, 0.99) }, null).mark === null);
check('two that agree and a third that doubts: not marked', verdict({ solver: one(1), checker: one(1), tiebreak: none() }, null).mark === null);
check('two that agree and a third that sees two right options: not marked', verdict({ solver: one(1), checker: one(1), tiebreak: several(1, 3) }, null).mark === null);
check('a split settled against the doubting one still needs no doubt', verdict({ solver: one(1), checker: one(2), tiebreak: none() }, null).mark === null);

// --- The writer's answer (a question AI wrote) asks for a look, and never blocks
const wd = verdict({ solver: one(2), checker: one(2) }, 1);
check('marked against what the writer chose: marked, and the card asks the tutor to check', wd.mark?.answer === 2 && wd.note === 'writer_differs' && j(wd.picks) === '{"writer":1,"solver":2,"checker":2}', wd);
const wsame = verdict({ solver: one(2), checker: one(2) }, 2);
check('marked as the writer chose: nothing more to say', wsame.mark?.answer === 2 && wsame.note === null && wsame.picks === null, wsame);
check('the writer does not make up a vote', verdict({ solver: one(2) }, 2).mark === null);
check('a split question shows the writer too', j(verdict({ solver: one(1), checker: one(2) }, 3).picks) === '{"writer":3,"solver":1,"checker":2}');

// --- Models of one family do not confirm each other
const G = 'gemini-3.1-flash-lite', O1 = 'openai/gpt-oss-120b', O2 = 'openai/gpt-oss-20b', Q = 'qwen/qwen3.8-27b';
const sameFamily = verdict({ solver: one(2, 0.97, O1), checker: one(2, 0.97, O2) }, null);
check('two models of one family that agree are not enough: another family is asked', sameFamily.mark === null && sameFamily.more && sameFamily.heard === 2, sameFamily);
check('two families that agree mark it', verdict({ solver: one(2, 0.97, O1), checker: one(2, 0.97, G) }, null).mark?.answer === 2);
const sameFamilySplit = verdict({ solver: one(1, 0.97, O1), checker: one(2, 0.97, O2) }, null);
check('two of one family that split: "disagree", and another family is asked', sameFamilySplit.mark === null && sameFamilySplit.note === 'disagree' && sameFamilySplit.more, sameFamilySplit);
check('a third of another family completes a pair of one family', verdict({ solver: one(2, 0.97, O1), checker: one(2, 0.97, O2), tiebreak: one(2, 0.97, Q) }, null).mark?.answer === 2);
check('but a third of another family that disagrees with both settles nothing', verdict({ solver: one(2, 0.97, O1), checker: one(2, 0.97, O2), tiebreak: one(1, 0.97, G) }, null).mark === null);
check('two models of one family that both see two right options still block it', verdict({ solver: several(1, 2, undefined as never), checker: several(1, 2) }, null).mark === null);
check('a split between families, settled by a third of the first family, is marked (two of three)', verdict({ solver: one(1, 0.97, O1), checker: one(2, 0.97, G), tiebreak: one(2, 0.97, 'gemini-3.5-flash') }, null).mark?.answer === 2);
check('a model whose name is not known is a family of its own', verdict({ solver: one(1, 0.97, 'x/one'), checker: one(1, 0.97, 'y/two') }, null).mark?.answer === 1);

// --- A split on a question AI wrote is final: the writer replaces it
const wsplit = verdict({ solver: one(1, 0.97, O1), checker: one(2, 0.97, G) }, 1, { written: true });
check('a written question the first two split on is not sent to a stronger model', wsplit.mark === null && wsplit.note === 'disagree' && !wsplit.more, wsplit);
check('a question of an uploaded paper that the same two split on still is', verdict({ solver: one(1, 0.97, O1), checker: one(2, 0.97, G) }, null, { written: false }).more);
check('a written question only one model was heard on is still waited for', verdict({ solver: one(1, 0.97, O1) }, 1, { written: true }).more);

// --- A question AI wrote whose writer could not give its own answer
const lost = verdict({ solver: one(2), checker: one(2) }, null, { written: true });
check('a written question whose writer had no answer is not marked, whatever the checks say', lost.mark === null && lost.note === 'unsure' && !lost.more, lost);
check('an uploaded paper has no writer, and its questions are marked as usual', verdict({ solver: one(2), checker: one(2) }, null, { written: false }).mark?.answer === 2);
check('a written question with a writer is marked as usual', verdict({ solver: one(2), checker: one(2) }, 2, { written: true }).mark?.answer === 2);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
