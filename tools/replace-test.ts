// Checks that the AI question maker replaces the questions its checks could not settle: a paper AI wrote keeps the request it was
// written from, a question left without an answer (or marked against what the writer meant) is left out and a new question takes
// its number, and nothing is ever replaced that the tutor has touched, that waits for its second opinion, that a call is working
// on, or that belongs to an uploaded paper. The states are seeded straight into the dev database; the new questions come from the
// real writer, so the API needs its AI keys (the deployed dev function has them, or tools/out/dev-serve.mjs).
// Makes its own paper and removes it again. Dev only.
// Usage: node tools/replace-test.ts [--env .env.local] [--base https://...]
import { readFileSync } from 'node:fs';
import pg from 'pg';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error(`No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in ${envFile}).`);
if (process.env.NEON_BRANCH !== 'dev') throw new Error(`This only runs against the dev branch (${envFile} says ${process.env.NEON_BRANCH}).`);
const root: any = await fetch(`${BASE}/`).then((r) => r.json());
if (root.branch !== 'dev') throw new Error(`The API at ${BASE} says it is branch ${root.branch}, not dev.`);
if (!root.ai) throw new Error('The API has no AI keys, so the writer cannot be asked.');
const logins = JSON.parse(readFileSync('tools/out/sample-logins.dev.json', 'utf8'));
const MATHS = '00000000-0000-4000-8000-000000000001';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

async function api(method: string, path: string, token: string, body?: unknown) {
  const res = await fetch(BASE + path, {
    method,
    headers: { authorization: `Bearer ${token}`, 'x-app': 'core_academy/1.7.0+9', ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(180_000),
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();
const papers: string[] = [];

try {
  const login = await fetch(`${BASE}/auth/login`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: logins.teacher.username, secret: logins.teacher.password }),
  }).then((r) => r.json() as Promise<any>);
  const T = login.token as string;
  check('the tutor logs in', !!T, login);

  // ---------------------------------------------------------------- a paper AI wrote, six questions
  const made = await api('POST', '/teacher/papers/chat', T, { class_level: 9, subject_id: MATHS, request: 'Easy questions on adding and subtracting fractions', count: 6 });
  check('AI writes six questions into a new paper', made.status === 201 && made.body.questions === 6, made.body);
  const P = made.body.paper.id as string;
  papers.push(P);
  const read = async () => (await api('GET', `/teacher/papers/${P}`, T)).body;
  const first = await read();
  check('the paper can have its questions replaced, and the request stays on the server', first.paper.replaceable === true && !('ai_request' in first.paper), first.paper);
  const stored = await db.query('select ai_request from papers where id = $1', [P]);
  check('the paper keeps the request it was written from', stored.rows[0].ai_request === 'Easy questions on adding and subtracting fractions', stored.rows[0]);

  const ids: string[] = first.drafts.map((d: any) => d.id);
  const [d0, d1, d2, d3, d4, d5] = ids;
  const seed = (id: string, set: string) => db.query(`update paper_drafts set ${set} where id = $1`, [id]);
  await seed(d0, `answer_checked = true, correct_option = null, ai_note = 'disagree'`);
  await seed(d1, `answer_checked = true, correct_option = 1, answer_source = 'ai', ai_note = 'writer_differs'`);
  await seed(d2, `answer_checked = true, correct_option = null, ai_note = 'unsure', edited = true`);
  await seed(d3, `answer_checked = true, correct_option = null, ai_votes = '{"tries":0}'::jsonb`);
  await seed(d4, `answer_checked = true, correct_option = 2, answer_source = 'ai'`);
  await seed(d5, `answer_checked = true, correct_option = null, ai_note = 'no_option', answer_claimed_at = now()`);
  const labels = new Map<string, { seq: number; label: string; page: number }>(first.drafts.map((d: any) => [d.id, { seq: d.seq, label: d.number_label, page: d.page_no }]));

  // ---------------------------------------------------------------- what is replaced, and what is not
  const r1 = await api('POST', `/teacher/papers/${P}/replace`, T);
  check('two are replaced: the one with no answer and the one marked against the writer', r1.status === 200 && r1.body.replaced === 2, r1.body);
  check('and nothing else is waiting to be: one is the tutor\'s, one waits for its second opinion, one is being worked on', r1.body.left === 0, r1.body);
  const after = await read();
  const byId = new Map<string, any>(after.drafts.map((d: any) => [d.id, d]));
  check('both are left out, under Skipped, with the reason', [d0, d1].every((id) => byId.get(id).status === 'discarded' && byId.get(id).ai_note === 'replaced'), [d0, d1].map((id) => byId.get(id)));
  const fresh = after.drafts.filter((d: any) => !ids.includes(d.id));
  check('two new questions took their place', fresh.length === 2 && fresh.every((d: any) => d.status === 'draft' && d.kind === 'mcq' && d.options.length === 4), fresh);
  check('each has the number and position of the one it replaced', fresh.every((d: any) => [d0, d1].some((id) => labels.get(id)!.seq === d.seq && labels.get(id)!.label === d.number_label && labels.get(id)!.page === d.page_no)), fresh.map((d: any) => [d.seq, d.number_label]));
  check('they start unchecked, with what the writer meant kept for the checks', fresh.every((d: any) => d.answer_checked === false && d.correct_option === null && d.edited === false && (d.proposed_option === null || typeof d.proposed_option === 'number')), fresh);
  check('the paper still has six live questions', after.drafts.filter((d: any) => d.status === 'draft').length === 6);
  check('the three it must not touch are as they were',
    byId.get(d2).status === 'draft' && byId.get(d2).ai_note === 'unsure' && byId.get(d3).status === 'draft' && byId.get(d3).ai_votes !== null && byId.get(d4).status === 'draft' && byId.get(d4).correct_option === 2,
    [byId.get(d2), byId.get(d3), byId.get(d4)].map((d) => [d.status, d.ai_note]));
  check('and the one a call was working on', byId.get(d5).status === 'draft' && byId.get(d5).ai_note === 'no_option');

  const r2 = await api('POST', `/teacher/papers/${P}/replace`, T);
  check('asking again changes nothing: the new questions are not checked yet', r2.status === 200 && r2.body.replaced === 0 && r2.body.left === 0, r2.body);

  // The call that was working on d5 has finished: it is unsettled like the rest, and is replaced.
  await seed(d5, 'answer_claimed_at = null');
  const r3 = await api('POST', `/teacher/papers/${P}/replace`, T);
  check('a question whose claim has been let go is replaced', r3.status === 200 && r3.body.replaced === 1, r3.body);
  const later = await read();
  check('and the tutor\'s own, and the one waiting for its second opinion, are still left alone',
    later.drafts.find((d: any) => d.id === d2).status === 'draft' && later.drafts.find((d: any) => d.id === d3).status === 'draft');

  // ---------------------------------------------------------------- what the tutor does makes a question hers
  const back = await api('PATCH', `/teacher/drafts/${d0}`, T, { status: 'draft' });
  check('a question brought back from Skipped is the tutor\'s now', back.status === 200 && back.body.draft.status === 'draft' && back.body.draft.edited === true, back.body);
  const r4 = await api('POST', `/teacher/papers/${P}/replace`, T);
  check('and is not replaced again, though it still has no answer', r4.status === 200 && r4.body.replaced === 0, r4.body);

  const target = later.drafts.find((d: any) => d.status === 'draft' && d.edited === false && d.answer_checked === false);
  await seed(target.id, `answer_checked = true, ai_note = 'unsure'`);
  const mark = await api('PATCH', `/teacher/drafts/${target.id}`, T, { correct_option: 0 });
  const unmark = await api('PATCH', `/teacher/drafts/${target.id}`, T, { correct_option: null });
  check('a question the tutor marked is hers, even if she takes the mark off again',
    mark.status === 200 && unmark.status === 200 && unmark.body.draft.edited === true && unmark.body.draft.correct_option === null, [mark.body, unmark.body]);
  await seed(target.id, `answer_checked = true, ai_note = 'disagree'`);
  const r5 = await api('POST', `/teacher/papers/${P}/replace`, T);
  check('so it is not replaced either', r5.status === 200 && r5.body.replaced === 0, r5.body);

  // ---------------------------------------------------------------- a ceiling, so a topic the checks never settle cannot go on for ever
  const fillers = Array.from({ length: 25 }, (_, i) => i);
  for (const i of fillers) {
    await db.query(
      `insert into paper_drafts (paper_id, page_no, seq, number_label, kind, text, options, status, ai_note) values ($1, 1, $2, $3, 'mcq', $4, array['a','b','c','d'], 'discarded', 'replaced')`,
      [P, 100 + i, String(101 + i), `cap filler ${i}`],
    );
  }
  const other = later.drafts.find((d: any) => d.status === 'draft' && d.edited === false);
  await seed(other.id, `answer_checked = true, correct_option = null, ai_note = 'unsure', answer_claimed_at = null`);
  const r6 = await api('POST', `/teacher/papers/${P}/replace`, T);
  check('a paper that has had as many questions replaced as it should is left alone', r6.status === 200 && r6.body.replaced === 0 && r6.body.left === 0, r6.body);
  check('and says so, so the app stops asking', (await read()).paper.replaceable === false);

  // ---------------------------------------------------------------- an uploaded paper is never touched
  const up = await api('POST', '/teacher/papers', T, { pages: 1, class_level: 9, subject_id: MATHS });
  check('a paper is uploaded', up.status === 201, up.body);
  papers.push(up.body.paper.id);
  const dr = await db.query(
    `insert into paper_drafts (paper_id, page_no, seq, kind, text, options, answer_checked, ai_note) values ($1, 1, 0, 'mcq', 'printed?', array['a','b','c','d'], true, 'unsure') returning id`,
    [up.body.paper.id],
  );
  const r7 = await api('POST', `/teacher/papers/${up.body.paper.id}/replace`, T);
  check('an uploaded paper\'s questions are the paper\'s own: nothing is replaced', r7.status === 200 && r7.body.replaced === 0 && r7.body.left === 0, r7.body);
  const upRead = (await api('GET', `/teacher/papers/${up.body.paper.id}`, T)).body;
  check('and it is not replaceable', upRead.paper.replaceable === false && upRead.drafts.find((d: any) => d.id === dr.rows[0].id).status === 'draft', upRead.paper);
  check('a paper that is not there is not found', (await api('POST', '/teacher/papers/00000000-0000-4000-8000-0000000000dd/replace', T)).status === 404);
} catch (e) {
  fail++;
  console.log('FAIL  unexpected error:', e);
} finally {
  for (const id of papers) await db.query('delete from papers where id = $1', [id]).catch((e) => console.log('cleanup problem:', e));
  await db.end().catch(() => {});
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
}
