// A classroom writes a test all at once: every student logs in, opens the home screen, starts the test, saves answers as they go,
// submits, and then reads the marks, all at the same moment. Checks that nothing answers with a server error, that every student
// ends with one finished attempt marked the way their own answers say, and prints how long each step took.
// Latency here includes the trip from this PC to the database, so read the figures as the worst case; the errors and the marks are exact.
// Makes its own tutor, tuition and students and removes them again. Dev only.
// Usage: node tools/load-test.ts [--env .env.local] [--base http://127.0.0.1:8787] [--students 40] [--questions 30]
import { randomInt } from 'node:crypto';
import pg from 'pg';

const args = process.argv.slice(2);
const opt = (name: string, fallback: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
process.loadEnvFile(opt('--env', '.env.local'));
const BASE = opt('--base', process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error('No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL).');
if (process.env.NEON_BRANCH !== 'dev') throw new Error(`This only runs against the dev branch (the env file says ${process.env.NEON_BRANCH}).`);
const root: any = await fetch(`${BASE}/`).then((r) => r.json());
if (root.branch !== 'dev') throw new Error(`The API at ${BASE} says it is branch ${root.branch}, not dev.`);

const N = Number(opt('--students', '40'));
const Q = Number(opt('--questions', '30'));
const MATHS = '00000000-0000-4000-8000-000000000001';
const APP = 'core_academy/1.6.0+8';
const tag = `load${randomInt(1000, 9999)}`;

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

type Reply = { status: number; body: any };
const samples = new Map<string, { ms: number; status: number }[]>();
async function api(method: string, path: string, token: string | undefined, body?: unknown, headers: Record<string, string> = {}, step?: string): Promise<Reply> {
  const t0 = performance.now();
  let out: Reply;
  try {
    const res = await fetch(BASE + path, {
      method,
      headers: { 'x-app': APP, ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(120_000),
    });
    const text = await res.text();
    let parsed: any = null;
    try { parsed = JSON.parse(text); } catch { parsed = text.slice(0, 200); }
    out = { status: res.status, body: parsed };
  } catch (e) {
    out = { status: 0, body: String(e) };
  }
  if (step) {
    const list = samples.get(step) ?? [];
    list.push({ ms: performance.now() - t0, status: out.status });
    samples.set(step, list);
  }
  return out;
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function inParallel<T>(limit: number, items: T[], fn: (x: T, i: number) => Promise<void>) {
  let next = 0;
  await Promise.all(Array.from({ length: limit }, async () => {
    while (next < items.length) {
      const i = next++;
      await fn(items[i], i);
    }
  }));
}
const pct = (xs: number[], p: number) => xs.slice().sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))];

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();
const created = { users: [] as string[], tuition: '' };

try {
  console.log(`${N} students, ${Q} questions, against ${BASE}`);
  // ------------------------------------------------------------ set-up (not timed)
  const su = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Load Tutor', username: `${tag}.tutor`, password: 'longenough1' }, { 'x-install-id': `${tag}-t` });
  if (su.status !== 201) throw new Error(`tutor sign-up failed: ${JSON.stringify(su.body)}`);
  created.users.push(su.body.user.id);
  const T = su.body.token as string;
  const mk = await api('POST', '/auth/tuitions', T, { name: `${tag} classroom`, groups: [{ class_level: 9, subject_id: MATHS }] });
  if (mk.status !== 201) throw new Error(`tuition failed: ${JSON.stringify(mk.body)}`);
  created.tuition = mk.body.tuition.id;

  const questions: { id: string; correct: number }[] = [];
  await inParallel(6, Array.from({ length: Q }, (_, k) => k), async (k) => {
    const correct = randomInt(0, 4);
    const r = await api('POST', '/teacher/questions', T, { class_level: 9, text: `${tag} question ${k + 1}: pick the right one`, options: ['a', 'b', 'c', 'd'], correct_option: correct, subject_id: MATHS });
    if (r.status !== 201) throw new Error(`question ${k} failed: ${JSON.stringify(r.body)}`);
    questions[k] = { id: r.body.id, correct };
  });
  const students: { id: string; username: string }[] = [];
  await inParallel(6, Array.from({ length: N }, (_, i) => i), async (i) => {
    const username = `${tag}.s${i}`;
    const r = await api('POST', '/teacher/students', T, { display_name: `Pupil ${i}`, class_level: 9, username, pin: '4321', subject_ids: [MATHS] });
    if (r.status !== 201) throw new Error(`student ${i} failed: ${JSON.stringify(r.body)}`);
    created.users.push(r.body.student.id);
    students[i] = { id: r.body.student.id, username };
  });
  const t = await api('POST', '/teacher/tests', T, {
    title: `${tag} classroom test`, class_level: 9, subject_id: MATHS, question_ids: questions.map((q) => q.id), shuffle: false,
    assign_all: false, assign_group: true, closes_at: new Date(Date.now() + 86_400_000).toISOString(), time_limit_min: 45,
  });
  if (t.status !== 201) throw new Error(`test failed: ${JSON.stringify(t.body)}`);
  const testId = t.body.id as string;
  const pub = await api('POST', `/teacher/tests/${testId}/publish`, T, { published: true });
  check('the test is published', pub.status === 200, pub.body);

  // ------------------------------------------------------------ the classroom: everyone at once
  const expected: number[] = [];
  const attempts: string[] = [];
  const tokens: string[] = [];
  const wall0 = performance.now();
  await Promise.all(students.map(async (s, i) => {
    const login = await api('POST', '/auth/login', undefined, { username: s.username, secret: '4321' }, {}, 'login');
    if (login.status !== 200) return;
    const S = login.body.token as string;
    tokens[i] = S;
    await api('GET', '/student/home', S, undefined, {}, 'home');
    const st = await api('POST', `/student/tests/${testId}/start`, S, undefined, {}, 'start');
    if (st.status !== 200) return;
    const attemptId = st.body.attempt.id as string;
    attempts[i] = attemptId;
    const picks = questions.map(() => randomInt(0, 4));
    expected[i] = picks.filter((p, k) => p === questions[k].correct).length;
    const answer = (k: number) => ({ question_id: questions[k].id, choice: picks[k] });
    for (let k = 0; k < Q; k += 5) {
      await sleep(randomInt(0, 150));
      await api('PUT', `/student/attempts/${attemptId}/answers`, S, { answers: picks.slice(k, k + 5).map((_, j) => answer(k + j)) }, {}, 'save');
    }
    await api('POST', `/student/attempts/${attemptId}/submit`, S, { answers: picks.map((_, k) => answer(k)) }, {}, 'submit');
  }));
  const wallSeconds = (performance.now() - wall0) / 1000;

  // ------------------------------------------------------------ afterwards: the marks, the tutor's screens
  const marks = await Promise.all(students.map((_, i) => (tokens[i] && attempts[i] ? api('GET', `/student/attempts/${attempts[i]}/result`, tokens[i], undefined, {}, 'result') : Promise.resolve({ status: 0, body: null } as Reply))));
  await api('GET', '/teacher/home', T, undefined, {}, 'tutor home');
  await api('GET', '/teacher/tests', T, undefined, {}, 'tutor tests');
  await api('GET', `/teacher/tests/${testId}`, T, undefined, {}, 'tutor test');
  await api('GET', '/teacher/students', T, undefined, {}, 'tutor students');

  // ------------------------------------------------------------ what it all came to
  console.log(`\nall ${N} students through in ${wallSeconds.toFixed(1)} s`);
  console.log('step           calls     p50 ms     p95 ms     max ms   not-2xx');
  for (const [step, list] of samples) {
    const ms = list.map((x) => x.ms);
    console.log(`${step.padEnd(12)} ${String(list.length).padStart(7)} ${pct(ms, 50).toFixed(0).padStart(10)} ${pct(ms, 95).toFixed(0).padStart(10)} ${Math.max(...ms).toFixed(0).padStart(10)} ${String(list.filter((x) => x.status < 200 || x.status >= 300).length).padStart(9)}`);
  }
  console.log('');
  const all = [...samples.values()].flat();
  check('no request ended in a server error or no answer', all.every((x) => x.status !== 0 && x.status < 500), all.filter((x) => x.status === 0 || x.status >= 500).slice(0, 5));
  check(`every one of the ${N} students got in, started and submitted`, tokens.filter(Boolean).length === N && attempts.filter(Boolean).length === N && (samples.get('submit') ?? []).every((x) => x.status === 200), {
    logins: tokens.filter(Boolean).length, starts: attempts.filter(Boolean).length,
  });
  const rows = await db.query('select student_id, score, submitted_at is not null as done, correct_count from attempts where test_id = $1', [testId]);
  check('the test holds exactly one attempt per student, all finished', rows.rowCount === N && rows.rows.every((r) => r.done), { rows: rows.rowCount });
  const byStudent = new Map(rows.rows.map((r) => [r.student_id, r]));
  const wrongMarks = students.filter((s, i) => Number(byStudent.get(s.id)?.correct_count) !== expected[i]);
  check('every student was marked on their own answers', wrongMarks.length === 0, wrongMarks.slice(0, 3).map((s) => s.username));
  const opened = await db.query('select results_released_at is not null as open from tests where id = $1', [testId]);
  check('the last student to finish opened the marks for everyone', opened.rows[0].open === true);
  check('and each student can read their marks', marks.every((m) => m.status === 200 && m.body !== null), marks.map((m) => m.status).filter((s) => s !== 200).slice(0, 5));
  const slow = [...samples.entries()].filter(([, l]) => Math.max(...l.map((x) => x.ms)) > 30_000).map(([s]) => s);
  check('no step took longer than 30 seconds', slow.length === 0, slow);
} catch (e) {
  fail++;
  console.log('FAIL  unexpected error:', e);
} finally {
  try {
    if (created.tuition) {
      await db.query('delete from tests where tuition_id = $1', [created.tuition]);
      await db.query('delete from questions where tuition_id = $1', [created.tuition]);
      const members = await db.query(`select user_id from memberships where tuition_id = $1 and role = 'student'`, [created.tuition]);
      await db.query('delete from users where id = any($1::uuid[])', [[...created.users, ...members.rows.map((r) => r.user_id)]]);
      await db.query('delete from tuitions where id = $1', [created.tuition]);
    } else {
      await db.query('delete from users where id = any($1::uuid[])', [created.users]);
    }
    await db.query('delete from users where username like $1', [`${tag}.%`]);
    await db.query('delete from app_installs where install_id like $1', [`${tag}-%`]);
  } catch (e) {
    console.log('cleanup problem:', e);
  }
  await db.end();
  console.log(`\n${pass} passed, ${fail} failed (test data removed)`);
  process.exit(fail ? 1 : 0);
}
