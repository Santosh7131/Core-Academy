// Checks the notification jobs against the API running on this PC in dry-run mode, where each
// notification is written to the server's log instead of being sent:
//   PUSH_DRY_RUN=1 neon dev --source ./api/src/index.ts --port 8787 > server.log
//   node tools/notify-test.ts --log server.log
// The scheduled route only answers Neon's trigger, and the deployed API drops the trigger header
// from anyone else, so this runs against the local API only. Uses the dev branch in .env.local,
// creates its own student, question and test, and removes them.
import { randomInt, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import pg from 'pg';

const args = process.argv.slice(2);
const arg = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
process.loadEnvFile(arg('--env') ?? '.env.local');
if (process.env.NEON_BRANCH === 'main') throw new Error('This writes test data; run it against dev, not main.');
const BASE = (arg('--base') ?? 'http://127.0.0.1:8787').replace(/\/$/, '');
const LOG = arg('--log');
const logins = JSON.parse(readFileSync(`tools/out/sample-logins.${process.env.NEON_BRANCH}.json`, 'utf8'));

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
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
      ...headers,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}
const login = (username: string, secret: string) => api('POST', '/auth/login', undefined, { username, secret });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();

/** What Neon's trigger sends: the header and the body carry the same invocation id. */
function cron() {
  const id = randomUUID();
  return api('POST', '/cron/notify', undefined, {
    version: 1, invocation_id: id, trigger: { type: 'schedule', id: 'trigger-local', name: 'notify' },
    data: { scheduled_at: new Date().toISOString() },
  }, { 'x-neon-trigger-invocation-id': id });
}

/** Push lines the server logged since the given length of its log. */
const logSize = () => (LOG ? readFileSync(LOG, 'utf8').length : 0);
const pushesSince = (from: number) =>
  LOG ? readFileSync(LOG, 'utf8').slice(from).split('\n').filter((l) => l.includes('[push]')).map((l) => l.trim()) : [];

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();
const created = { users: [] as string[], questions: [] as string[], tests: [] as string[] };
const tag = `notifytest${randomInt(1000, 9999)}`;
let T = '';

try {
  const root = await api('GET', '/');
  check('API is up with push in dry-run', root.status === 200 && root.body?.push === true, root.body);

  const t = await login(logins.teacher.username, logins.teacher.password);
  check('teacher logs in', t.status === 200, t.body);
  T = t.body.token;

  const s = await api('POST', '/teacher/students', T, { display_name: 'Notify Test', class_level: 9, username: `${tag}.one`, pin: '1234' });
  check('teacher creates a student', s.status === 201, s.body);
  created.users.push(s.body.student.id);
  const S = (await login(`${tag}.one`, '1234')).body.token as string;

  const studentPhone = `${tag}-student-phone`;
  const teacherPhone = `${tag}-teacher-phone`;
  check('a phone cannot register without logging in', (await api('POST', '/devices', undefined, { token: studentPhone })).status === 401);
  check('the student registers a phone', (await api('POST', '/devices', S, { token: studentPhone })).status === 200);
  check('registering again is fine', (await api('POST', '/devices', S, { token: studentPhone })).status === 200);
  check('the teacher registers a phone', (await api('POST', '/devices', T, { token: teacherPhone })).status === 200);
  check('a device needs a token', (await api('POST', '/devices', S, {})).status === 400);

  check('the scheduled route refuses a call without the trigger header',
    (await api('POST', '/cron/notify', undefined, { version: 1, invocation_id: 'x', trigger: { type: 'schedule' }, data: {} })).status === 401);
  const mismatch = await api('POST', '/cron/notify', undefined, {
    version: 1, invocation_id: 'a', trigger: { type: 'schedule', id: 't', name: 'n' }, data: { scheduled_at: iso(0) },
  }, { 'x-neon-trigger-invocation-id': 'b' });
  check('the scheduled route refuses a header that does not match the body', mismatch.status === 401, mismatch.body);

  // Clear anything already due on dev, so the runs below only see this test's notifications.
  await cron();
  const settled = await cron();
  check('a run with nothing due does not touch the database', settled.body?.ran === false, settled.body);

  const qn = await api('POST', '/teacher/questions', T, {
    class_level: 9, text: `${tag} What is $2 + 2$?`, options: ['$3$', '$4$', '$5$', '$6$'], correct_option: 1,
  });
  created.questions.push(qn.body.id);
  const title = `${tag} Algebra check`;
  const test = await api('POST', '/teacher/tests', T, {
    title, class_level: 9, question_ids: created.questions, time_limit_min: 15,
    assign_all: false, student_ids: created.users, opens_at: iso(-60_000), closes_at: iso(26 * 3600_000),
  });
  created.tests.push(test.body.id);

  let mark = logSize();
  const pub = await api('POST', `/teacher/tests/${test.body.id}/publish`, T, { published: true });
  check('teacher publishes an open test', pub.status === 200, pub.body);
  await sleep(2500);
  const announced = (await db.query('select announced_at from tests where id = $1', [test.body.id])).rows[0];
  check('publishing announces it straight away', announced.announced_at !== null, announced);
  if (LOG) {
    const lines = pushesSince(mark);
    const closes = /closes (today|tomorrow|\w{3} \d{1,2} \w{3},) \d{1,2}:\d{2} (am|pm)$/;
    check('the student is told: title, questions, time limit, closing time',
      lines.some((l) => l.includes(`1 phone(s) | ${title} | New test · 1 question · 15 min · closes `) && closes.test(l)), lines);
  }
  const after = await cron();
  check('the next run has nothing due', after.body?.ran === false, after.body);

  // Unpublish and publish again: no second announcement.
  mark = logSize();
  await api('POST', `/teacher/tests/${test.body.id}/publish`, T, { published: false });
  await api('POST', `/teacher/tests/${test.body.id}/publish`, T, { published: true });
  await sleep(2000);
  if (LOG) check('publishing again does not repeat the announcement', pushesSince(mark).length === 0, pushesSince(mark));

  // A student given the open test later is told the moment they are added, and only they are told.
  const s2 = await api('POST', '/teacher/students', T, { display_name: 'Notify Test Two', class_level: 9, username: `${tag}.two`, pin: '2468' });
  created.users.push(s2.body.student.id);
  const S2 = (await login(`${tag}.two`, '2468')).body.token as string;
  await api('POST', '/devices', S2, { token: `${tag}-phone-two` });
  mark = logSize();
  const added = await api('PATCH', `/teacher/tests/${test.body.id}`, T, {
    title, class_level: 9, question_ids: created.questions, time_limit_min: 15,
    assign_all: false, student_ids: created.users, opens_at: iso(-60_000), closes_at: iso(26 * 3600_000),
  });
  await sleep(2500);
  check('the teacher adds a second student to the open test', added.status === 200, added.body);
  if (LOG) {
    const lines = pushesSince(mark).filter((l) => l.includes(title));
    check('only the new student is told, once', lines.length === 1 && lines[0].includes('1 phone(s)'), lines);
  }

  // An hour before closing: pretend students have known about it for three hours, then move the
  // closing time to 30 minutes from now.
  await db.query(`update tests set announced_at = now() - interval '3 hours' where id = $1`, [test.body.id]);
  const body = (await api('GET', `/teacher/tests/${test.body.id}`, T)).body;
  const patch = await api('PATCH', `/teacher/tests/${test.body.id}`, T, {
    title, class_level: 9, question_ids: created.questions, time_limit_min: 15,
    assign_all: false, student_ids: created.users, opens_at: body.test.opens_at, closes_at: iso(30 * 60_000),
  });
  check('teacher moves the closing time to half an hour away', patch.status === 200, patch.body);
  await sleep(2000);
  mark = logSize();
  const remind = await cron();
  const r = remind.body?.reminded?.find((x: any) => x.title === title);
  check('the run reminds both students, neither has started', remind.body?.ran === true && r?.people === 2 && r?.phones === 2, remind.body);
  if (LOG) {
    check('the reminder says when it closes',
      pushesSince(mark).some((l) => l.includes(`| ${title} | Closes today`) && l.endsWith('You have not started it yet.')), pushesSince(mark));
  }
  const again = await cron();
  check('the reminder is sent once', again.body?.ran === false || !again.body?.reminded?.some((x: any) => x.title === title), again.body);

  // A student who has started is not reminded: give the test a new closing time and start it.
  await db.query(`update tests set announced_at = now() - interval '3 hours' where id = $1`, [test.body.id]);
  await api('PATCH', `/teacher/tests/${test.body.id}`, T, {
    title, class_level: 9, question_ids: created.questions, time_limit_min: 15,
    assign_all: false, student_ids: created.users, opens_at: body.test.opens_at, closes_at: iso(40 * 60_000),
  });
  await sleep(2000);
  const start = await api('POST', `/student/tests/${test.body.id}/start`, S);
  check('the student starts the test', start.status === 200 || start.status === 201, start.body);
  const second = await cron();
  const r2 = second.body?.reminded?.find((x: any) => x.title === title);
  check('a student who has started is not reminded, the other still is', second.body?.ran === true && r2?.people === 1, second.body);

  // Logging out removes the phone.
  await api('POST', '/auth/logout', S);
  const left = (await db.query('select count(*)::int as n from device_tokens where token = $1', [studentPhone])).rows[0].n;
  check('logging out stops notifications to that phone', left === 0, left);

  const sum = await db.query(`select day, sent_at from daily_summaries order by day desc limit 1`);
  console.log(`\nlatest daily summary row: ${JSON.stringify(sum.rows[0] ?? null)}`);
  if (LOG) console.log(`push lines in this run:\n  ${pushesSince(0).filter((l) => l.includes(tag) || l.includes("Today's tests")).join('\n  ')}`);
} catch (e) {
  fail++;
  console.log('FAIL  unexpected error:', e);
} finally {
  await db.query('delete from tests where id = any($1::uuid[])', [created.tests]);
  await db.query('delete from questions where id = any($1::uuid[])', [created.questions]);
  await db.query('delete from users where id = any($1::uuid[])', [created.users]);
  if (T) await api('POST', '/auth/logout', T);
  await db.end();
  console.log(`\n${pass} passed, ${fail} failed (test data removed)`);
  process.exit(fail ? 1 : 0);
}
