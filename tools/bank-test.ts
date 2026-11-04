// Checks the Bank (GET /teacher/bank): every question paper the tutor has posted, once each, with how many times it was used and the
// latest test to post it again from. Makes its own questions and tests in the dev database through the API (no database connection is
// needed) and removes them again. Dev only.
// Usage: node tools/bank-test.ts [--env .env.local] [--base http://127.0.0.1:8787]
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error(`No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in ${envFile}).`);
if (process.env.NEON_BRANCH !== 'dev') throw new Error(`This only runs against the dev branch (${envFile} says ${process.env.NEON_BRANCH}).`);
const root: any = await fetch(`${BASE}/`).then((r) => r.json());
if (root.branch !== 'dev') throw new Error(`The API at ${BASE} says it is branch ${root.branch}, not dev.`);
const logins = JSON.parse(readFileSync('tools/out/sample-logins.dev.json', 'utf8'));
const MATHS = '00000000-0000-4000-8000-000000000001';
const APP = 'core_academy/1.8.1+11';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

async function api(method: string, path: string, token: string | null, body?: unknown) {
  const res = await fetch(BASE + path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), 'x-app': APP, ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60_000),
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}

const signIn = (username: string, secret: string) =>
  fetch(`${BASE}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username, secret }) }).then((r) => r.json() as Promise<any>);

const tag = `bankt${Date.now().toString(36)}`;
const day = 86_400_000;
const iso = (ms: number) => new Date(Date.now() + ms).toISOString();
const same = (a: string | null, b: string) => a !== null && Date.parse(a) === Date.parse(b);
const created = { tests: [] as string[], questions: [] as string[] };
const times: Record<string, { opens: string | null; closes: string }> = {};
let T = '';

try {
  const login = await signIn(logins.teacher.username, logins.teacher.password);
  T = login.token as string;
  check('the tutor logs in', !!T, login);

  const bank = async () => {
    const r = await api('GET', '/teacher/bank', T);
    if (r.status !== 200) throw new Error(`the Bank answered ${r.status}: ${JSON.stringify(r.body)}`);
    // The tuition may have tests of its own: only the ones this run made.
    return (r.body.papers as any[]).filter((p) => String(p.title).startsWith(tag));
  };
  const by = (rows: any[], name: string) => rows.find((r) => r.title === `${tag} ${name}`);

  const mkQ = async (n: number) => {
    const r = await api('POST', '/teacher/questions', T, { class_level: 9, text: `${tag} question ${n} $${n}+1$?`, options: ['1', '2', '3', '4'], correct_option: 1, subject_id: MATHS });
    if (r.status !== 201) throw new Error(`could not make question ${n}: ${JSON.stringify(r.body)}`);
    created.questions.push(r.body.id);
    return r.body.id as string;
  };
  const q = [await mkQ(1), await mkQ(2), await mkQ(3), await mkQ(4)];

  /** A test of [ids], opening [opens] ms from now (null: no opening time) and closing at [closes]; posted unless [publish] is false. */
  const mkTest = async (title: string, ids: string[], o: { cls?: number; opens?: number | null; closes?: number; limit?: number; shuffle?: boolean; publish?: boolean; students?: string[] } = {}) => {
    const opens = o.opens === null ? null : iso(o.opens ?? day);
    const closes = iso(o.closes ?? 2 * day);
    const r = await api('POST', '/teacher/tests', T, {
      title: `${tag} ${title}`, class_level: o.cls ?? 9, subject_id: MATHS, question_ids: ids, shuffle: o.shuffle ?? false, assign_all: false,
      assign_group: !o.students, ...(o.students ? { student_ids: o.students } : {}),
      ...(opens ? { opens_at: opens } : {}), closes_at: closes, ...(o.limit ? { time_limit_min: o.limit } : {}),
    });
    if (r.status !== 201) throw new Error(`could not make ${title}: ${JSON.stringify(r.body)}`);
    created.tests.push(r.body.id);
    times[r.body.id] = { opens, closes };
    if (o.publish !== false) {
      const p = await api('POST', `/teacher/tests/${r.body.id}/publish`, T, { published: true });
      if (p.status !== 200) throw new Error(`could not post ${title}: ${JSON.stringify(p.body)}`);
    }
    return r.body.id as string;
  };

  // ---------------------------------------------------------------- who may ask
  const noLogin = await api('GET', '/teacher/bank', null);
  check('the Bank needs a login', noLogin.status === 401, noLogin.status);
  const student = logins.students[0];
  const sl = await signIn(student.username, student.pin);
  const asStudent = sl.token ? await api('GET', '/teacher/bank', sl.token) : null;
  check('and is a tutor\'s, not a student\'s', asStudent !== null && asStudent.status === 403, asStudent?.status ?? sl);

  const empty = await api('GET', '/teacher/bank', T);
  check('the Bank answers with a list of papers', empty.status === 200 && Array.isArray(empty.body.papers), empty.body);
  check('and none of this run\'s are in it yet', (await bank()).length === 0);

  // ---------------------------------------------------------------- one paper, posted again and again
  const same3 = [q[0], q[1], q[2]];
  const a1 = await mkTest('A first', same3, { opens: day, closes: 2 * day, limit: 20, shuffle: false });
  let rows = await bank();
  check('a paper posted once is one row', rows.length === 1, rows);
  const r1 = rows[0];
  check('that says its test, name, class, subject, size, limit and order', r1.id === a1 && r1.title === `${tag} A first` && r1.class_level === 9 && r1.subject_id === MATHS && r1.subject === 'Maths'
    && r1.course_id === null && r1.course === null && r1.question_count === 3 && r1.uses === 1 && r1.time_limit_min === 20 && r1.shuffle === false, r1);
  check('and when that test opened and closed, which is when the paper was last given', same(r1.opens_at, times[a1].opens!) && same(r1.closes_at, times[a1].closes) && same(r1.last_given, times[a1].opens!), r1);
  check('and that it went to the group, not to students chosen one by one', r1.assign_group === true && r1.assign_all === false && r1.chosen === 0, r1);

  const a2 = await mkTest('A again', same3, { opens: 5 * day, closes: 6 * day, limit: 30, shuffle: true });
  rows = await bank();
  check('the same paper posted again is still one row, used twice', rows.length === 1 && rows[0].uses === 2, rows);
  check('and the row is the latest test, with its name, limit and order', rows[0].id === a2 && rows[0].title === `${tag} A again` && rows[0].time_limit_min === 30 && rows[0].shuffle === true, rows[0]);
  check('and says when the paper was first made, which does not move', rows[0].first_made === r1.first_made, [rows[0].first_made, r1.first_made]);

  const a3 = await mkTest('A in between', same3, { opens: 3 * day, closes: 4 * day });
  rows = await bank();
  check('a test made last but given earlier does not take the row', rows.length === 1 && rows[0].uses === 3 && rows[0].id === a2, rows);

  await mkTest('A not posted', same3, { publish: false });
  rows = await bank();
  check('a draft is not counted', rows.length === 1 && rows[0].uses === 3 && rows[0].id === a2, rows);

  // ---------------------------------------------------------------- what makes another paper
  await mkTest('B reordered', [q[2], q[1], q[0]], { opens: 7 * day, closes: 8 * day });
  await mkTest('C two questions', [q[0], q[1]], { opens: 9 * day, closes: 10 * day });
  await mkTest('D class ten', same3, { cls: 10, opens: 11 * day, closes: 12 * day });
  rows = await bank();
  check('the same questions in another order, fewer of them, or for another class are other papers', rows.length === 4, rows.map((r) => r.title));
  check('the same questions in another order: its own paper', by(rows, 'B reordered')?.uses === 1 && by(rows, 'B reordered')?.question_count === 3);
  check('fewer questions: its own paper', by(rows, 'C two questions')?.uses === 1 && by(rows, 'C two questions')?.question_count === 2);
  check('another class: its own paper, in that class', by(rows, 'D class ten')?.uses === 1 && by(rows, 'D class ten')?.class_level === 10);
  check('and the first paper is as it was', by(rows, 'A again')?.uses === 3 && by(rows, 'A again')?.class_level === 9);
  const given = rows.map((r) => Date.parse(r.last_given));
  check('the paper given most lately comes first', given.every((t, i) => i === 0 || given[i - 1] >= t), rows.map((r) => r.title));

  // ---------------------------------------------------------------- students chosen one by one
  const people = await api('GET', '/teacher/students?class=9', T);
  const pick = (people.body?.students as any[] | undefined)?.find((s) => s.active === true);
  check('a class-9 student is there to choose', !!pick, people.status);
  if (pick) {
    await mkTest('F chosen', [q[3], q[2]], { students: [pick.id], opens: 13 * day, closes: 14 * day });
    rows = await bank();
    const f = by(rows, 'F chosen');
    check('a test for students chosen one by one says so, and how many', !!f && f.assign_group === false && f.assign_all === false && f.chosen === 1, f);
  }

  // ---------------------------------------------------------------- no opening time
  await mkTest('E open now', [q[3]], { opens: null, closes: day });
  rows = await bank();
  const e = by(rows, 'E open now');
  check('a test with no opening time was given when it was posted', !!e && e.opens_at === null && Math.abs(Date.parse(e.last_given) - Date.now()) < 5 * 60_000, e);

  // ---------------------------------------------------------------- tests taken down and deleted
  const down = await api('POST', `/teacher/tests/${a2}/publish`, T, { published: false });
  check('a test is taken down', down.status === 200, down.body);
  rows = await bank();
  check('a test taken down is no longer a use, and the row falls back to the latest still posted', by(rows, 'A in between')?.uses === 2 && by(rows, 'A in between')?.id === a3 && !by(rows, 'A again'), rows.map((r) => [r.title, r.uses]));

  await api('DELETE', `/teacher/tests/${a3}`, T);
  rows = await bank();
  check('a test deleted is no longer a use either', by(rows, 'A first')?.uses === 1 && by(rows, 'A first')?.id === a1 && !by(rows, 'A in between'), rows.map((r) => [r.title, r.uses]));

  await api('DELETE', `/teacher/tests/${a1}`, T);
  rows = await bank();
  const others = ['B reordered', 'C two questions', 'D class ten', 'E open now', ...(pick ? ['F chosen'] : [])];
  check('a paper none of whose posted tests is left is no longer in the Bank', !by(rows, 'A first') && !by(rows, 'A again') && !by(rows, 'A in between') && rows.length === others.length, rows.map((r) => r.title));
  check('and the other papers are untouched', others.every((n) => by(rows, n)?.uses === 1));
} finally {
  if (T) {
    for (const id of created.tests) await api('DELETE', `/teacher/tests/${id}?with_results=1`, T).catch((e) => console.log('cleanup', e.message));
    for (const id of created.questions) await api('DELETE', `/teacher/questions/${id}`, T).catch((e) => console.log('cleanup', e.message));
  }
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
