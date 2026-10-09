// Checks the tutors' evening summary goes to each tuition's own tutors, against the API running on this PC in
// dry-run mode (see tools/notify-test.ts). It only exists after 8 pm India time, so the check is skipped before then.
//   PUSH_DRY_RUN=1 neon dev --source ./api/src/index.ts --port 8787 > server.log
//   node tools/summary-test.ts --log server.log
import { randomInt, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import pg from 'pg';

const args = process.argv.slice(2);
const arg = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
process.loadEnvFile(arg('--env') ?? '.env.local');
if (process.env.NEON_BRANCH === 'main') throw new Error('This writes test data; run it against dev, not main.');
const BASE = (arg('--base') ?? 'http://127.0.0.1:8787').replace(/\/$/, '');
const LOG = arg('--log');
const MATHS = '00000000-0000-4000-8000-000000000001';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}
async function api(method: string, path: string, token?: string, body?: unknown, headers: Record<string, string> = {}) {
  const res = await fetch(BASE + path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();
function cron() {
  const id = randomUUID();
  return api('POST', '/cron/notify', undefined, {
    version: 1, invocation_id: id, trigger: { type: 'schedule', id: 'trigger-local', name: 'notify' },
    data: { scheduled_at: new Date().toISOString() },
  }, { 'x-neon-trigger-invocation-id': id });
}
const logSize = () => (LOG ? readFileSync(LOG, 'utf8').length : 0);
const pushesSince = (from: number) =>
  LOG ? readFileSync(LOG, 'utf8').slice(from).split('\n').filter((l) => l.includes('[push]')).map((l) => l.trim()) : [];

const hourIndia = new Date(Date.now() + 5.5 * 3_600_000).getUTCHours();
if (hourIndia < 20) {
  console.log(`It is ${hourIndia}:xx in India: the summary starts at 20:00, so there is nothing to check yet.`);
  process.exit(0);
}

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();
const tag = `summary${randomInt(1000, 9999)}`;
const created = { users: [] as string[], tuitions: [] as string[], tests: [] as string[], questions: [] as string[] };

try {
  const inst = { 'x-install-id': `${tag}-x` };
  const su = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Summary Tutor', username: `${tag}.t`, password: 'longenough1' }, inst);
  created.users.push(su.body.user.id);
  const T = su.body.token as string;
  const mk = await api('POST', '/auth/tuitions', T, { name: `${tag} Tuition`, groups: [{ class_level: 9, subject_id: MATHS }] });
  check('a tuition is made', mk.status === 201, mk.body);
  created.tuitions.push(mk.body.tuition.id);

  const s = await api('POST', '/teacher/students', T, { display_name: 'Summary Student', class_level: 9, username: `${tag}.s`, pin: '4321', subject_ids: [MATHS] });
  created.users.push(s.body.student.id);
  const qn = await api('POST', '/teacher/questions', T, { class_level: 9, text: `${tag} 1+1?`, options: ['1', '2', '3', '4'], correct_option: 1, subject_id: MATHS });
  created.questions.push(qn.body.id);
  const test = await api('POST', '/teacher/tests', T, {
    title: `${tag} test`, class_level: 9, subject_id: MATHS, question_ids: [qn.body.id], shuffle: false, assign_all: false, assign_group: true, closes_at: iso(5 * 3_600_000),
  });
  created.tests.push(test.body.id);
  await api('POST', `/teacher/tests/${test.body.id}/publish`, T, { published: true });
  const login = await api('POST', '/auth/login', undefined, { username: `${tag}.s`, secret: '4321' });
  const S = login.body.token as string;
  const start = await api('POST', `/student/tests/${test.body.id}/start`, S);
  const done = await api('POST', `/student/attempts/${start.body.attempt.id}/submit`, S, { answers: [{ question_id: qn.body.id, choice: 1 }] });
  check('the student writes the test', done.status === 200, done.body);

  const phone = `${tag}-phone-${randomUUID()}`;
  const reg = await api('POST', '/devices', T, { token: phone });
  check('the tutor registers a phone', reg.status === 200, reg.body);

  // The job only wakes the database when something is due. A test that opens in a few seconds makes the next run due.
  const wake = await api('POST', '/teacher/tests', T, {
    title: `${tag} wake`, class_level: 9, subject_id: MATHS, question_ids: [qn.body.id], shuffle: false, assign_all: false, assign_group: true,
    opens_at: iso(2500), closes_at: iso(5 * 3_600_000),
  });
  created.tests.push(wake.body.id);
  await api('POST', `/teacher/tests/${wake.body.id}/publish`, T, { published: true });
  await new Promise((r) => setTimeout(r, 4500));

  const mark = logSize();
  const run = await cron();
  check('the evening run covers this tuition', run.body?.ran === true && run.body.summary?.tuitions >= 1, run.body);
  const row = await db.query('select 1 from daily_summaries where tuition_id = $1 and day = (now() at time zone \'Asia/Kolkata\')::date', [mk.body.tuition.id]);
  check('the tuition is marked as summarised today', row.rowCount === 1);
  if (LOG) {
    const lines = pushesSince(mark).filter((l) => l.includes("Today's tests"));
    check('the tutor is told what was written, in one message',
      lines.length === 1 && lines[0].includes('1 student wrote 1 test today, average 100%.'), lines);
  }
  const again = await cron();
  check('the next run does not summarise again', !again.body?.summary || again.body.summary.tuitions === 0 || again.body.ran === false, again.body);
} catch (e) {
  fail++;
  console.log('FAIL  unexpected error:', e);
} finally {
  await db.query('delete from tests where id = any($1::uuid[])', [created.tests]);
  await db.query('delete from questions where id = any($1::uuid[])', [created.questions]);
  await db.query('delete from app_installs where install_id like $1', [`${tag}-%`]);
  await db.query('delete from users where id = any($1::uuid[])', [created.users]);
  await db.query('delete from tuitions where id = any($1::uuid[])', [created.tuitions]);
  await db.end();
  console.log(`\n${pass} passed, ${fail} failed (test data removed)`);
  process.exit(fail ? 1 : 0);
}
