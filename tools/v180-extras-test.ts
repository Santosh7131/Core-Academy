// Checks what app 1.8.0 adds on the server, against the dev branch:
//   - the update gate: an app below the minimum build is turned away, except to finish a test it has started;
//   - a test left open for a week: the list on Home, Close, Remind the students, and the tutor's notification;
//   - the Library: files in the tutor's own order, sections in order, and the notice to students when files are added;
//   - renaming any subject, a standard one included, in a tuition of its own made for this test;
//   - difficulty tags on questions and drafts;
//   - storage per tuition in the developer's app.
// Everything goes through the API. Pushes are only seen when the API runs on this PC in dry-run mode, where each notification is written to
// its log, so those checks need --log:
//   PUSH_DRY_RUN=1 neon dev --source ./api/src/index.ts --port 8787 > tools/out/serve.log
//   node tools/v180-extras-test.ts --base http://127.0.0.1:8787 --log tools/out/serve.log [--ai]
// Without --log the push checks are skipped. --ai also has the AI write a few questions (free-tier calls) to see them come back tagged.
// Dev only. It uses Claude's own tutor and student, the dev sample tuition as "another tuition", and makes and removes its own data.
import { randomBytes, randomInt } from 'node:crypto';
import { readFileSync } from 'node:fs';
import pg from 'pg';

const args = process.argv.slice(2);
const arg = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
process.loadEnvFile(arg('--env') ?? '.env.local');
if (process.env.NEON_BRANCH !== 'dev') throw new Error(`This only runs against the dev branch (${arg('--env') ?? '.env.local'} says ${process.env.NEON_BRANCH}).`);
process.env.PUSH_DRY_RUN = '1';
const BASE = (arg('--base') ?? 'http://127.0.0.1:8787').replace(/\/$/, '');
const LOG = arg('--log');
const WITH_AI = args.includes('--ai');
const root: any = await fetch(`${BASE}/`).then((r) => r.json());
if (root.branch !== 'dev') throw new Error(`The API at ${BASE} says it is branch ${root.branch}, not dev.`);
const mine = JSON.parse(readFileSync('tools/out/claude-test-logins.dev.json', 'utf8'));
const sample = JSON.parse(readFileSync('tools/out/sample-logins.dev.json', 'utf8'));
const MATHS = '00000000-0000-4000-8000-000000000001';
const NEW_APP = 'core_academy/1.8.0+10';
const OLD_APP = 'core_academy/1.6.0+8';
const BEFORE_STALE = 'core_academy/1.7.0+9';
const tag = `v180x${randomInt(1000, 9999)}`;
const DAY = 86_400_000;
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();

let pass = 0;
let fail = 0;
let skipped = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}
function skip(name: string, why: string) {
  skipped++;
  console.log(`SKIP  ${name}  (${why})`);
}

async function api(method: string, path: string, token?: string, body?: unknown, app: string | null = NEW_APP) {
  const res = await fetch(BASE + path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(app ? { 'x-app': app } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(90_000),
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}
const code = (r: { body: any }) => r.body?.error?.code;
async function signIn(username: string, secret: string) {
  const r = await api('POST', '/auth/login', undefined, { username, secret });
  if (r.status !== 200 || !r.body?.token) throw new Error(`Could not sign in ${username}: ${r.status} ${JSON.stringify(r.body)}`);
  return r.body.token as string;
}
const logSize = () => (LOG ? readFileSync(LOG, 'utf8').length : 0);
const pushesSince = (from: number) =>
  LOG ? readFileSync(LOG, 'utf8').slice(from).split('\n').filter((l) => l.includes('[push]')).map((l) => l.trim()) : [];

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();
const one = async (sql: string, params: unknown[] = []) => (await db.query(sql, params)).rows[0];

const T1 = await signIn(mine.teacher.username, mine.teacher.password);
const S1 = await signIn(mine.student.username, mine.student.pin);
const T2 = await signIn(sample.teacher.username, sample.teacher.password);
const D = await signIn(sample.developer.username, sample.developer.password);
const TUITION = mine.tuition.id as string;
const pdf = (size: number) => Buffer.concat([Buffer.from('%PDF-1.4\n'), randomBytes(size - 9)]);

const made = { tests: [] as string[], questions: [] as string[], sections: [] as string[], papers: [] as string[], tokens: [] as string[] };
const origMin = (await one(`select value from app_settings where key = 'min_app_build'`))?.value ?? null;
const setMin = (n: number | null) =>
  n === null
    ? db.query(`delete from app_settings where key = 'min_app_build'`)
    : db.query(`insert into app_settings (key, value) values ('min_app_build', to_jsonb($1::int)) on conflict (key) do update set value = excluded.value`, [n]);

async function makeQuestion(n: number, extra: Record<string, unknown> = {}) {
  const r = await api('POST', '/teacher/questions', T1, {
    class_level: 9, subject_id: MATHS, text: `${tag} question ${n}`, options: ['1', '2', '3', '4'], correct_option: 0, ...extra,
  });
  if (r.status !== 201) throw new Error(`question: ${r.status} ${JSON.stringify(r.body)}`);
  made.questions.push(r.body.id);
  return r.body.id as string;
}
async function makeTest(title: string, question_ids: string[], over: Record<string, unknown> = {}, publish = true) {
  const r = await api('POST', '/teacher/tests', T1, {
    title: `${tag} ${title}`, class_level: 9, subject_id: MATHS, question_ids, shuffle: false, closes_at: iso(30 * DAY), ...over,
  });
  if (r.status !== 201) throw new Error(`test: ${r.status} ${JSON.stringify(r.body)}`);
  made.tests.push(r.body.id);
  if (publish) {
    const p = await api('POST', `/teacher/tests/${r.body.id}/publish`, T1, { published: true });
    if (p.status !== 200) throw new Error(`publish: ${p.status} ${JSON.stringify(p.body)}`);
  }
  return r.body.id as string;
}
/** Makes a posted test look as if it had been posted `days` days ago. */
const age = (id: string, days: number) =>
  db.query(`update tests set published_at = now() - make_interval(days => $2), created_at = now() - make_interval(days => $2), announced_at = now() - make_interval(days => $2) where id = $1`, [id, days]);
const staleIds = async (token = T1, app = NEW_APP) => ((await api('GET', '/teacher/home', token, undefined, app)).body?.stale ?? []).map((t: any) => t.id) as string[];
async function startAttempt(testId: string, app = NEW_APP) {
  const r = await api('POST', `/student/tests/${testId}/start`, S1, undefined, app);
  if (r.status !== 200) throw new Error(`start: ${r.status} ${JSON.stringify(r.body)}`);
  return r.body as { attempt: { id: string }; questions: { id: string }[] };
}

async function section(name: string, fn: () => Promise<void>) {
  console.log(`\n--- ${name}`);
  try {
    await fn();
  } catch (e) {
    check(`${name}: no unexpected error`, false, (e as Error).message);
  }
}

try {
  const qs = [await makeQuestion(1), await makeQuestion(2)];
  const running = await one(
    `select count(*)::int as n from attempts a join users u on u.id = a.student_id
      where u.username = $1 and a.submitted_at is null and (a.deadline_at is null or a.deadline_at > now())`,
    [mine.student.username],
  );
  if (running.n > 0) throw new Error('Claude\'s student already has a test being written on dev; finish or leave it and run this again.');

  // ------------------------------------------------------------------ the update gate
  await section('the update gate', async () => {
    const gateA = await makeTest('gate A', qs, { time_limit_min: 30 });
    const gateB = await makeTest('gate B', qs);
    await setMin(9);
    const turned = await api('GET', '/student/home', S1, undefined, OLD_APP);
    check('an app below the minimum build is turned away with update_required', turned.status === 426 && code(turned) === 'update_required', turned);
    check('the current app is served', (await api('GET', '/student/home', S1, undefined, NEW_APP)).status === 200);
    check('a tutor on an old app is turned away', code(await api('GET', '/teacher/home', T1, undefined, OLD_APP)) === 'update_required');
    check('an old app cannot start a test', code(await api('POST', `/student/tests/${gateA}/start`, S1, undefined, OLD_APP)) === 'update_required');
    check('nor can an old app that names no build be told apart: no build is never too old', (await api('GET', '/student/home', S1, undefined, null)).status === 200);

    const started = await startAttempt(gateA);
    const attempt = started.attempt.id;
    const answers = { answers: [{ question_id: started.questions[0].id, choice: 0 }] };
    const home = await api('GET', '/student/home', S1, undefined, OLD_APP);
    check('with a test being written, the old app still opens (so reopening it takes the student back)', home.status === 200, home);
    check('it can save answers', (await api('PUT', `/student/attempts/${attempt}/answers`, S1, answers, OLD_APP)).status === 200);
    const again = await api('POST', `/student/tests/${gateA}/start`, S1, undefined, OLD_APP);
    check('it can take the same test up again, to the same attempt', again.status === 200 && again.body?.attempt?.id === attempt, again);
    check('it cannot start another test', code(await api('POST', `/student/tests/${gateB}/start`, S1, undefined, OLD_APP)) === 'update_required');
    const handed = await api('POST', `/student/attempts/${attempt}/submit`, S1, answers, OLD_APP);
    check('it can hand the test in', handed.status === 200, handed);
    check('it can see the marks', (await api('GET', `/student/attempts/${attempt}/result`, S1, undefined, OLD_APP)).status === 200);
    check('once the test is in, the old app is asked to update again', code(await api('GET', '/student/home', S1, undefined, OLD_APP)) === 'update_required');
    check('a finished attempt does not let the old app start another', code(await api('POST', `/student/tests/${gateB}/start`, S1, undefined, OLD_APP)) === 'update_required');

    // The calls that finish a test are never refused, even with no test in hand (the attempt may have just run out).
    const other = await api('GET', `/student/attempts/${attempt}/result`, S1, undefined, OLD_APP);
    check('the marks of a finished attempt open from an old app too', other.status === 200, other);
    const foreign = await api('GET', `/student/attempts/00000000-0000-4000-8000-0000000000ff/result`, S1, undefined, OLD_APP);
    check('a result that is not the student\'s own is still not found', foreign.status === 404, foreign);
    await setMin(origMin);
    check('the minimum is back as it was', ((await one(`select value from app_settings where key = 'min_app_build'`))?.value ?? null) === origMin);
  });

  // ------------------------------------------------------------------ a test open for a week
  await section('a test open for a week', async () => {
    const W = await makeTest('week W', qs);
    const fresh = await makeTest('week fresh', qs);
    const soon = await makeTest('week closes soon', qs, { closes_at: iso(3 * 3600_000) });
    const draft = await makeTest('week draft', qs, {}, false);
    await age(W, 8);
    await age(soon, 8);
    const list = (await api('GET', '/teacher/home', T1)).body;
    const w = (list.stale ?? []).find((t: any) => t.id === W);
    check('a test open for 8 days is on the list, with how long and who is waiting', !!w && w.days_open >= 8 && w.waiting >= 1 && w.assigned >= w.waiting && w.title.endsWith('week W'), w);
    check('a test posted today is not', !(list.stale ?? []).some((t: any) => t.id === fresh));
    check('a test about to close by itself is not', !(list.stale ?? []).some((t: any) => t.id === soon));
    check('a test not posted is not', !(list.stale ?? []).some((t: any) => t.id === draft));
    check('an app from before the list is not sent it', (await api('GET', '/teacher/home', T1, undefined, BEFORE_STALE)).body?.stale === undefined);

    // Reminding
    const phoneS = `${tag}-student-phone`;
    const phoneT = `${tag}-tutor-phone`;
    made.tokens.push(phoneS, phoneT);
    await api('POST', '/devices', S1, { token: phoneS });
    await api('POST', '/devices', T1, { token: phoneT });
    check('a student cannot remind anyone', (await api('POST', `/teacher/tests/${W}/remind`, S1, {})).status === 403);
    check('another tuition\'s tutor cannot remind this test\'s students', (await api('POST', `/teacher/tests/${W}/remind`, T2, {})).status === 404);
    check('a test not posted cannot be reminded', code(await api('POST', `/teacher/tests/${draft}/remind`, T1, {})) === 'not_open');
    const before = logSize();
    const rem = await api('POST', `/teacher/tests/${W}/remind`, T1, {});
    check('the tutor reminds the students: it says how many', rem.status === 200 && rem.body?.students >= 1 && typeof rem.body?.phones === 'number', rem);
    if (LOG) {
      const lines = pushesSince(before).filter((l) => l.includes('Your tutor reminds you'));
      check('the reminder reaches the student\'s phone, naming when it closes', lines.length === 1 && lines[0].includes('week W') && /It closes /.test(lines[0]), lines);
      check('and only the student\'s: not the tutor\'s phone', !pushesSince(before).some((l) => l.includes('Test open for a week')));
    } else skip('the reminder text', 'no --log');
    check('after a reminder the warning stays away', !(await staleIds()).includes(W));
    check('reminding again at once is refused', code(await api('POST', `/teacher/tests/${W}/remind`, T1, {})) === 'just_reminded');
    await db.query(`update tests set nudged_at = now() - interval '8 days' where id = $1`, [W]);
    check('a week after the reminder it is back on the list', (await staleIds()).includes(W));

    // The tutor's notification
    if (LOG) {
      const { warnStale } = await import('../api/src/lib/notify.ts');
      const seen: string[] = [];
      const realLog = console.log;
      console.log = (...a: unknown[]) => { seen.push(a.join(' ')); };
      const todo = await staleIds();
      let phones = 0;
      try {
        phones = await warnStale(TUITION);
      } finally {
        console.log = realLog;
      }
      const note = seen.filter((l) => l.includes('Test open for a week'));
      check('the evening run tells the tutor about it', phones >= 1 && note.length === 1, { phones, seen });
      check('naming the test and its days when it is the only one, else counting them',
        todo.length === 1 ? /week W has been open for 8 days\. \d+ students? (has|have) not handed it in/.test(note[0] ?? '') : /\d+ tests have been open for a week or more/.test(note[0] ?? ''), note);
      check('each test is told about once', (await warnStale(TUITION)) === 0);
      await db.query(`update tests set stale_notified_at = now() - interval '8 days' where id = $1`, [W]);
      console.log = (...a: unknown[]) => { seen.push(a.join(' ')); };
      let again = 0;
      try {
        again = await warnStale(TUITION);
      } finally {
        console.log = realLog;
      }
      check('and again a week later while it is still open', again >= 1, again);
    } else skip('the tutor\'s notification', 'no --log');

    // Closing
    check('a student cannot close a test', (await api('POST', `/teacher/tests/${W}/close`, S1, {})).status === 403);
    check('another tuition\'s tutor cannot close it', (await api('POST', `/teacher/tests/${W}/close`, T2, {})).status === 404);
    check('a test not posted cannot be closed', code(await api('POST', `/teacher/tests/${draft}/close`, T1, {})) === 'not_posted');
    const long = await makeTest('week running', qs);
    await age(long, 9);
    const running = await startAttempt(long);
    const closed = await api('POST', `/teacher/tests/${W}/close`, T1, {});
    check('Close closes the test now', closed.status === 200 && new Date(closed.body.test.closes_at).getTime() <= Date.now() + 2000, closed);
    check('it leaves the list', !(await staleIds()).includes(W));
    const startAfter = await api('POST', `/student/tests/${W}/start`, S1, undefined, NEW_APP);
    check('nobody can start it any more', startAfter.status === 409 && code(startAfter) === 'closed', startAfter);
    check('closing twice says it is closed', code(await api('POST', `/teacher/tests/${W}/close`, T1, {})) === 'already_closed');
    check('a closed test cannot be reminded', code(await api('POST', `/teacher/tests/${W}/remind`, T1, {})) === 'not_open');
    // A student still writing gets a few minutes, not what was left of the old closing time.
    const closedRunning = await api('POST', `/teacher/tests/${long}/close`, T1, {});
    check('closing a test someone is writing works', closedRunning.status === 200, closedRunning);
    const att = await one(`select (deadline_at - now()) as left_ from attempts where id = $1`, [running.attempt.id]);
    const leftMs = (att.left_.minutes ?? 0) * 60_000 + (att.left_.seconds ?? 0) * 1000 + (att.left_.hours ?? 0) * 3_600_000 + (att.left_.days ?? 0) * DAY;
    check('the student writing gets about ten minutes to finish', leftMs > 8 * 60_000 && leftMs <= 10 * 60_000 + 5000, att.left_);
    const done = await api('POST', `/student/attempts/${running.attempt.id}/submit`, S1, { answers: [] });
    check('and can still hand the test in', done.status === 200, done);

    // Posting again starts the week again
    const again = await makeTest('week reposted', qs);
    await age(again, 9);
    await db.query(`update tests set nudged_at = now(), stale_notified_at = now() where id = $1`, [again]);
    await api('POST', `/teacher/tests/${again}/publish`, T1, { published: false });
    await api('POST', `/teacher/tests/${again}/publish`, T1, { published: true });
    const reset = await one(`select published_at > now() - interval '1 minute' as fresh, nudged_at, stale_notified_at from tests where id = $1`, [again]);
    check('taking a test down and posting it again counts the week from then', reset.fresh === true && reset.nudged_at === null && reset.stale_notified_at === null, reset);
    check('so it is not on the list', !(await staleIds()).includes(again));
  });

  // ------------------------------------------------------------------ the Library: order, and telling students
  await section('the Library: order and notices', async () => {
    const shelf = '/teacher/groups/9/' + MATHS + '/library';
    const sA = (await api('POST', `${shelf}/sections`, T1, { name: `${tag} A` })).body.section.id as string;
    const sB = (await api('POST', `${shelf}/sections`, T1, { name: `${tag} B` })).body.section.id as string;
    made.sections.push(sA, sB);
    async function addFile(section: string, name: string, bytes: Buffer) {
      const start = await api('POST', `/teacher/library/sections/${section}/files`, T1, { name, content_type: 'application/pdf', size: bytes.length });
      const put = await fetch(start.body.upload.url, { method: 'PUT', body: new Uint8Array(bytes), headers: start.body.upload.headers });
      const done = await api('POST', `/teacher/library/files/${start.body.file.id}/complete`, T1);
      if (put.status !== 200 || done.status !== 200) throw new Error(`file ${name}: ${put.status} ${done.status} ${JSON.stringify(done.body)}`);
      return start.body.file.id as string;
    }
    const names = (secs: any[], id: string) => secs.find((s: any) => s.id === id)?.files.map((f: any) => f.name) as string[];
    const fa = await addFile(sA, 'first.pdf', pdf(2000));
    const fb = await addFile(sA, 'second.pdf', pdf(2000));
    const fc = await addFile(sA, 'third.pdf', pdf(2000));
    const fd = await addFile(sB, 'other.pdf', pdf(2000));
    let lib = (await api('GET', shelf, T1)).body.library;
    check('files go to the end of their section, in the order they were finished', names(lib.sections, sA).join() === 'first.pdf,second.pdf,third.pdf', names(lib.sections, sA));

    check('files are put in the order sent', (await api('PUT', `/teacher/library/sections/${sA}/files/order`, T1, { ids: [fc, fa, fb] })).status === 200);
    lib = (await api('GET', shelf, T1)).body.library;
    check('the shelf shows that order', names(lib.sections, sA).join() === 'third.pdf,first.pdf,second.pdf', names(lib.sections, sA));
    const studentLib = (await api('GET', '/student/library', S1)).body;
    const sGroup = studentLib.groups.find((g: any) => g.class_level === 9 && g.subject_id === MATHS);
    check('and so does the student\'s Library', names(sGroup.sections, sA).join() === 'third.pdf,first.pdf,second.pdf', names(sGroup?.sections ?? [], sA));
    check('a list that leaves a file out is refused', code(await api('PUT', `/teacher/library/sections/${sA}/files/order`, T1, { ids: [fa, fb] })) === 'out_of_date');
    check('a list that repeats a file is refused', code(await api('PUT', `/teacher/library/sections/${sA}/files/order`, T1, { ids: [fa, fa, fb] })) === 'out_of_date');
    check('a list with a file of another section is refused', code(await api('PUT', `/teacher/library/sections/${sA}/files/order`, T1, { ids: [fa, fb, fd] })) === 'out_of_date');
    check('a list that is not ids is refused', (await api('PUT', `/teacher/library/sections/${sA}/files/order`, T1, { ids: ['x'] })).status === 400);
    check('another tuition\'s tutor cannot reorder this section', (await api('PUT', `/teacher/library/sections/${sA}/files/order`, T2, { ids: [fa, fb, fc] })).status === 404);
    check('a student cannot reorder', (await api('PUT', `/teacher/library/sections/${sA}/files/order`, S1, { ids: [fa, fb, fc] })).status === 403);
    check('the order was not changed by the refusals', names((await api('GET', shelf, T1)).body.library.sections, sA).join() === 'third.pdf,first.pdf,second.pdf');

    // Sections
    const order = lib.sections.map((s: any) => s.id) as string[];
    const rest = order.filter((id) => id !== sA && id !== sB);
    check('sections are put in the order sent (mine first, B before A)', (await api('PUT', `${shelf}/sections/order`, T1, { ids: [sB, sA, ...rest] })).status === 200);
    lib = (await api('GET', shelf, T1)).body.library;
    check('the shelf shows the sections in that order, the others after them as they were', lib.sections.map((s: any) => s.id).join() === [sB, sA, ...rest].join(), lib.sections.map((s: any) => s.name));
    const sg2 = (await api('GET', '/student/library', S1)).body.groups.find((g: any) => g.class_level === 9 && g.subject_id === MATHS);
    const mineAtStudent = sg2.sections.filter((s: any) => s.id === sA || s.id === sB).map((s: any) => s.id);
    check('the student sees the sections in that order', mineAtStudent.join() === [sB, sA].join(), mineAtStudent);
    check('a list that leaves a section out is refused', code(await api('PUT', `${shelf}/sections/order`, T1, { ids: [sB] })) === 'out_of_date');
    check('a shelf with no sections takes only an empty list', (await api('PUT', `/teacher/groups/9/${MATHS}/library/sections/order`, T2, { ids: [sA] })).status === 409);

    // A file moved to another section goes to its end
    const moved = await api('PATCH', `/teacher/library/files/${fa}`, T1, { section_id: sB });
    check('a file moved to another section is accepted', moved.status === 200, moved);
    lib = (await api('GET', shelf, T1)).body.library;
    check('and goes to the end of that section', names(lib.sections, sB).join() === 'other.pdf,first.pdf', names(lib.sections, sB));

    // Telling the students
    const phone = `${tag}-student-phone-2`;
    made.tokens.push(phone);
    await api('POST', '/devices', S1, { token: phone });
    check('an empty list of files is refused', (await api('POST', '/teacher/library/announce', T1, { file_ids: [] })).status === 400);
    check('a student cannot announce', (await api('POST', '/teacher/library/announce', S1, { file_ids: [fa] })).status === 403);
    const before = logSize();
    const told = await api('POST', '/teacher/library/announce', T1, { file_ids: [fb, fc] });
    check('announcing two new files tells the group once', told.status === 200 && told.body.files === 2 && told.body.students >= 1, told);
    if (LOG) {
      const lines = pushesSince(before);
      check('one notice, titled with the group and naming both files', lines.length === 1 && lines[0].includes('Class 9 Maths') && /(second|third)\.pdf and (second|third)\.pdf were added to the Library\./.test(lines[0]), lines);
    } else skip('the notice text', 'no --log');
    check('announcing the same files again tells nobody', (await api('POST', '/teacher/library/announce', T1, { file_ids: [fb, fc] })).body?.files === 0);
    const b2 = logSize();
    const one1 = await api('POST', '/teacher/library/announce', T1, { file_ids: [fd, fa] });
    check('files of two sections of one shelf are one notice', one1.body?.files === 2, one1);
    if (LOG) {
      const lines = pushesSince(b2);
      check('and with two names it says "and"', lines.length === 1 && / and .* were added to the Library\./.test(lines[0]), lines);
    }
    check('another tuition\'s tutor cannot announce these files', (await api('POST', '/teacher/library/announce', T2, { file_ids: [fa] })).body?.files === 0);
    const uploading = await api('POST', `/teacher/library/sections/${sA}/files`, T1, { name: 'half.pdf', content_type: 'application/pdf', size: 2000 });
    check('a file still going up is not announced', (await api('POST', '/teacher/library/announce', T1, { file_ids: [uploading.body.file.id] })).body?.files === 0);
  });

  // ------------------------------------------------------------------ renaming any subject
  await section('renaming any subject', async () => {
    const stamp = `${tag}`.toLowerCase();
    const signup = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Subject Test', username: `${stamp}.tutor`, password: 'Subject-test-7' });
    check('a throwaway tutor signs up', signup.status === 201, signup);
    const TT = signup.body.token as string;
    const std: any[] = (await api('GET', '/auth/standard-subjects', TT)).body.subjects;
    const standard = (name: string) => std.find((s) => s.name === name).id as string;
    const tuition = await api('POST', '/auth/tuitions', TT, {
      name: `${tag} tuition`, groups: [{ class_level: 9, subject_id: MATHS }, { class_level: 9, subject_id: standard('Science') }],
    });
    check('and starts a tuition with Class 9 Maths and Science', tuition.status === 201, tuition);
    const TU = tuition.body.tuition.id as string;
    try {
      const subjects = async () => (await api('GET', '/teacher/subjects', TT)).body.subjects as any[];
      const maths0 = (await subjects()).find((s) => s.id === MATHS);
      check('Maths starts as a standard subject, and the main one', maths0?.standard === true && maths0?.is_default === true, maths0);

      const ch = await api('POST', '/teacher/chapters', TT, { class_level: 9, subject_id: MATHS, name: 'Algebra' });
      const qn = await api('POST', '/teacher/questions', TT, { class_level: 9, subject_id: MATHS, chapter_id: ch.body.chapter.id, text: 'What is 2 + 2?', options: ['1', '2', '3', '4'], correct_option: 3, difficulty: 'easy' });
      const stu = await api('POST', '/teacher/students', TT, { display_name: 'Maths Student', class_level: 9, subject_ids: [MATHS], username: `${stamp}.kid`, pin: '2468' });
      const tst = await api('POST', '/teacher/tests', TT, { title: 'Maths test', class_level: 9, subject_id: MATHS, question_ids: [qn.body.id], closes_at: iso(DAY) });
      const shelfOld = `/teacher/groups/9/${MATHS}/library`;
      const sec = await api('POST', `${shelfOld}/sections`, TT, { name: 'Notes' });
      const start = await api('POST', `/teacher/library/sections/${sec.body.section.id}/files`, TT, { name: 'maths.pdf', content_type: 'application/pdf', size: 1500 });
      const bytes = pdf(1500);
      await fetch(start.body.upload.url, { method: 'PUT', body: new Uint8Array(bytes), headers: start.body.upload.headers });
      await api('POST', `/teacher/library/files/${start.body.file.id}/complete`, TT);
      check('Maths has a chapter, a question, a student, a test and a shelf with a file', [ch.status, qn.status, stu.status, tst.status, sec.status, start.status].every((s) => s === 201), [ch.status, qn.status, stu.status, tst.status, sec.status, start.status]);

      const name = 'Maths 9th Batch 1';
      const renamed = await api('PATCH', `/teacher/subjects/${MATHS}`, TT, { name });
      check('Maths, a standard subject, is renamed', renamed.status === 200 && renamed.body?.subject?.name === name, renamed);
      const fresh = renamed.body.subject.id as string;
      check('it is a subject of the tuition\'s own now, with a new id', fresh !== MATHS);
      const list = await subjects();
      check('the subject list shows the new name once, as the tuition\'s own', list.filter((s) => s.name === name && s.id === fresh && s.standard === false).length === 1 && !list.some((s) => s.id === MATHS), list);
      check('Science is untouched', list.some((s) => s.name === 'Science' && s.standard === true));
      const groups = (await api('GET', '/teacher/groups', TT)).body.groups as any[];
      check('the group is called by the new name, with its student', groups.some((g) => g.subject_id === fresh && g.subject === name && g.students === 1) && !groups.some((g) => g.subject_id === MATHS), groups);
      check('the chapter went with it', (await api('GET', '/teacher/chapters?class_level=9&subject_id=' + fresh, TT)).body?.chapters?.some((c: any) => c.id === ch.body.chapter.id));
      const qlist = (await api('GET', `/teacher/questions?subject=${fresh}`, TT)).body.questions as any[];
      check('the question went with it, and still carries its tag', qlist.some((x) => x.id === qn.body.id && x.subject === name && x.difficulty === 'easy'), qlist);
      const test = (await api('GET', `/teacher/tests/${tst.body.id}`, TT)).body.test;
      const listed = ((await api('GET', '/teacher/tests', TT)).body.tests as any[]).find((x) => x.id === tst.body.id);
      check('the test says the new subject', test.subject_id === fresh && listed?.subject === name, { test: test.subject_id, listed });
      const kid = (await api('GET', `/teacher/students/${stu.body.student.id}`, TT)).body.student;
      check('the student studies the renamed subject', kid.subjects.some((s: any) => s.id === fresh && s.name === name) && !kid.subjects.some((s: any) => s.id === MATHS), kid.subjects);
      const shelfNew = (await api('GET', `/teacher/groups/9/${fresh}/library`, TT)).body.library;
      check('the Library shelf and its file went with the group', shelfNew.files === 1 && shelfNew.sections[0]?.name === 'Notes', shelfNew);
      check('the old subject is not the tuition\'s any more', (await api('GET', `/teacher/groups/9/${MATHS}/library`, TT)).status === 400);
      check('the standard Maths can be added again, beside the renamed one', (await api('GET', '/teacher/subject-catalogue', TT)).body.subjects.some((s: any) => s.id === MATHS));

      // Every table that holds a subject: nothing of the tuition is left under the old one.
      const fks = (await db.query(`select conrelid::regclass::text as t from pg_constraint c where c.contype = 'f' and c.confrelid = 'subjects'::regclass order by 1`)).rows.map((r) => r.t as string);
      const { BY_SUBJECT } = await import('../api/src/lib/subjects.ts');
      check('the tables a rename moves are exactly the tables that point at subjects', JSON.stringify([...BY_SUBJECT].sort()) === JSON.stringify([...fks].sort()), { fks, BY_SUBJECT });
      for (const table of fks) {
        const left = await one(`select count(*)::int as n from ${table} where tuition_id = $1 and subject_id = $2`, [TU, MATHS]);
        check(`nothing in ${table} is left under the old subject`, left.n === 0, left);
      }

      // The standard subject is still Maths everywhere else.
      const other = (await api('GET', '/teacher/subjects', T2)).body.subjects as any[];
      check('another tuition still has the standard Maths, with its name and id', other.some((s) => s.id === MATHS && s.name === 'Maths' && s.standard === true), other.map((s) => s.name));
      check('the standard subject itself did not change', (await one(`select name from subjects where id = $1`, [MATHS])).name === 'Maths');

      // More renames
      const again = await api('PATCH', `/teacher/subjects/${fresh}`, TT, { name: 'Maths 9th Batch 2' });
      check('the tuition\'s own subject is renamed where it stands, keeping its id', again.status === 200 && again.body.subject.id === fresh && again.body.subject.name === 'Maths 9th Batch 2', again);
      const same = await api('PATCH', `/teacher/subjects/${fresh}`, TT, { name: 'Maths 9th Batch 2' });
      check('the same name again is no change', same.status === 200 && same.body.subject.id === fresh, same);
      const sci = standard('Science');
      check('a name another subject has is refused, whatever its case', code(await api('PATCH', `/teacher/subjects/${fresh}`, TT, { name: 'SCIENCE' })) === 'duplicate');
      check('a standard subject cannot take a name another subject has either', code(await api('PATCH', `/teacher/subjects/${sci}`, TT, { name: 'maths 9th batch 2' })) === 'duplicate');
      const forked = await api('PATCH', `/teacher/subjects/${sci}`, TT, { name: 'Science and Technology' });
      check('Science is renamed the same way', forked.status === 200 && forked.body.subject.id !== sci, forked);
      check('a subject the tuition does not teach is not found', (await api('PATCH', `/teacher/subjects/${standard('Physics')}`, TT, { name: 'Physics 2' })).status === 404);
      check('another tuition\'s tutor cannot rename this tuition\'s subject', (await api('PATCH', `/teacher/subjects/${fresh}`, T2, { name: 'Mine now' })).status === 404);
      check('a blank name is refused', (await api('PATCH', `/teacher/subjects/${fresh}`, TT, { name: '  ' })).status === 400);
      const removed = await api('DELETE', `/teacher/subjects/${fresh}`, TT);
      check('a renamed subject with chapters still cannot be removed while it is in use', code(removed) === 'in_use', removed);

      // Clean what holds files, then the tuition
      await api('DELETE', `/teacher/library/sections/${sec.body.section.id}?with_files=1`, TT);
    } finally {
      await db.query('delete from tests where tuition_id = $1', [TU]);
      await db.query('delete from tuitions where id = $1', [TU]);
      await db.query(`delete from users where username like $1`, [`${stamp}.%`]);
    }
  });

  // ------------------------------------------------------------------ difficulty tags
  await section('difficulty tags', async () => {
    const hard = await makeQuestion(10, { difficulty: 'hard' });
    const plain = await makeQuestion(11);
    const get = async (id: string) => (await api('GET', `/teacher/questions/${id}`, T1)).body.question;
    const h = await get(hard);
    check('a question made with a tag keeps it, set by the tutor', h.difficulty === 'hard' && h.difficulty_by === 'tutor', h);
    const p = await get(plain);
    check('a question made without one is Medium, and nobody is said to have judged it', p.difficulty === 'medium' && p.difficulty_by === null, p);
    check('a tag that is not easy, medium or hard is refused', (await api('POST', '/teacher/questions', T1, { class_level: 9, subject_id: MATHS, text: `${tag} bad`, options: ['1', '2', '3', '4'], correct_option: 0, difficulty: 'tough' })).status === 400);
    const full = (extra: Record<string, unknown>) => ({ class_level: 9, subject_id: MATHS, text: `${tag} question 10`, options: ['1', '2', '3', '4'], correct_option: 0, ...extra });
    check('a tag is changed with an edit', (await api('PATCH', `/teacher/questions/${hard}`, T1, full({ difficulty: 'easy' }))).status === 200 && (await get(hard)).difficulty === 'easy');
    check('an edit that says nothing about it leaves it as it is (an app from before tags)', (await api('PATCH', `/teacher/questions/${hard}`, T1, full({}))).status === 200 && (await get(hard)).difficulty === 'easy');
    check('an edit with a bad tag is refused and changes nothing', (await api('PATCH', `/teacher/questions/${hard}`, T1, full({ difficulty: 'HARDEST' }))).status === 400 && (await get(hard)).difficulty === 'easy');
    check('a capital letter is understood', (await api('PATCH', `/teacher/questions/${hard}`, T1, full({ difficulty: 'Medium' }))).status === 200 && (await get(hard)).difficulty === 'medium');
    check('a question always has a level: null does not take it away', (await api('PATCH', `/teacher/questions/${hard}`, T1, full({ difficulty: null }))).status === 400 && (await get(hard)).difficulty === 'medium');
    await api('PATCH', `/teacher/questions/${hard}`, T1, full({ difficulty: 'hard' }));
    const hardIds = ((await api('GET', '/teacher/questions?difficulty=hard', T1)).body.questions as any[]).map((x) => x.id);
    check('the list can be cut to one tag', hardIds.includes(hard) && !hardIds.includes(plain), hardIds.length);
    const mediumIds = ((await api('GET', '/teacher/questions?difficulty=medium', T1)).body.questions as any[]).map((x) => x.id);
    check('a question nobody tagged is in the Medium list', mediumIds.includes(plain) && !mediumIds.includes(hard));
    check('there is no "none" any more', (await api('GET', '/teacher/questions?difficulty=none', T1)).status === 400);
    check('a tag that does not exist is refused', (await api('GET', '/teacher/questions?difficulty=tough', T1)).status === 400);
    // A row written by the app from before levels, or from before migration 029, has no level at all: the database says Medium for a new
    // one, and the API says Medium for one that is already there.
    const old = await makeQuestion(12);
    await db.query('update questions set difficulty = null, difficulty_by = null where id = $1', [old]);
    check('a question with no level in the database is Medium to the app', (await get(old)).difficulty === 'medium');
    const oldIds = ((await api('GET', '/teacher/questions?difficulty=medium', T1)).body.questions as any[]).map((x) => x.id);
    check('and is in the Medium list', oldIds.includes(old));
    const dflt = (await db.query('select column_default from information_schema.columns where table_name = $1 and column_name = $2', ['questions', 'difficulty'])).rows[0]?.column_default;
    check('a row inserted without a level gets Medium from the database', typeof dflt === 'string' && dflt.includes('medium'), dflt);
    const t = await makeTest('tagged', [hard, plain, old]);
    const details = (await api('GET', `/teacher/tests/${t}`, T1)).body.questions as any[];
    check('a test\'s questions come with their levels', details.find((x) => x.id === hard)?.difficulty === 'hard' && details.find((x) => x.id === plain)?.difficulty === 'medium' && details.find((x) => x.id === old)?.difficulty === 'medium', details.map((x) => x.difficulty));

    if (!WITH_AI) return skip('the AI writes questions with tags', 'no --ai');
    const chat = await api('POST', '/teacher/papers/chat', T1, { class_level: 9, subject_id: MATHS, request: 'Class 9 percentages: some easy, some medium and some hard questions', count: 4 });
    check('AI writes four questions', chat.status === 201, chat);
    if (chat.status !== 201) return;
    made.papers.push(chat.body.paper.id);
    const paper = (await api('GET', `/teacher/papers/${chat.body.paper.id}`, T1)).body;
    const drafts = paper.drafts as any[];
    check('every draft has a level', drafts.length > 0 && drafts.every((d) => ['easy', 'medium', 'hard'].includes(d.difficulty)), drafts.map((d) => d.difficulty));
    const tagged = drafts.filter((d) => d.difficulty_by === 'ai');
    check('AI judged most of them itself, and the rest are Medium with nobody said to have judged', tagged.length >= Math.ceil(drafts.length / 2)
      && drafts.filter((d) => d.difficulty_by !== 'ai').every((d) => d.difficulty === 'medium' && d.difficulty_by === null), drafts.map((d) => [d.difficulty, d.difficulty_by]));
    const first = drafts[0];
    const set = await api('PATCH', `/teacher/drafts/${first.id}`, T1, { difficulty: 'hard', correct_option: 0 });
    check('the tutor sets a draft\'s tag: it is hers now', set.status === 200 && set.body.draft.difficulty === 'hard' && set.body.draft.difficulty_by === 'tutor', set);
    check('a bad tag on a draft is refused', (await api('PATCH', `/teacher/drafts/${first.id}`, T1, { difficulty: 'x' })).status === 400);
    const saved = await api('POST', `/teacher/papers/${chat.body.paper.id}/save`, T1);
    check('saving puts the tag on the question in the bank', saved.status === 200 && saved.body.saved >= 1, saved);
    const after = (await api('GET', `/teacher/papers/${chat.body.paper.id}`, T1)).body.questions as any[];
    check('the saved question carries the tutor\'s tag', after.some((x) => x.difficulty === 'hard' && x.difficulty_by === 'tutor'), after.map((x) => x.difficulty));
  });

  // ------------------------------------------------------------------ storage per tuition
  await section('storage per tuition (the developer\'s app)', async () => {
    check('a tutor cannot read it', (await api('GET', '/admin/clients', T1)).status === 403);
    const list = await api('GET', '/admin/clients', D);
    const me = list.body?.clients?.find((c: any) => c.id === TUITION);
    check('the clients list carries each tuition\'s Library', list.status === 200 && me?.library && typeof me.library.bytes === 'number' && me.library.quota_bytes > 0, me);
    const used = (await api('GET', `/teacher/groups/9/${MATHS}/library`, T1)).body.library.used_bytes;
    check('its bytes are what the tuition itself sees used', me.library.bytes === used, { admin: me.library.bytes, tutor: used });
    check('the list has the total too', typeof list.body.totals.library_bytes === 'number' && list.body.totals.library_bytes >= me.library.bytes);
    const one2 = await api('GET', `/admin/clients/${TUITION}`, D);
    const s = one2.body?.storage;
    check('one client says what it keeps: Library, question pictures, paper pages', one2.status === 200 && s?.library?.bytes === used && typeof s?.pictures?.bytes === 'number' && typeof s?.pages?.bytes === 'number', s);
    check('with a total that adds up', s?.total_bytes === s.library.bytes + s.pictures.bytes + s.pages.bytes, s);
    check('and the Library split into PDFs and photos', s?.library?.pdfs + s?.library?.photos === s?.library?.files, s?.library);
    check('each kind has its own bytes, which never add up to more than the Library', typeof s?.library?.pdf_bytes === 'number' && typeof s?.library?.photo_bytes === 'number'
      && s.library.pdf_bytes + s.library.photo_bytes <= s.library.bytes, s?.library);
  });
} finally {
  // ------------------------------------------------------------------ clean up
  await setMin(origMin).catch(() => {});
  for (const id of made.sections) await api('DELETE', `/teacher/library/sections/${id}?with_files=1`, T1).catch(() => {});
  for (const id of made.papers) await api('DELETE', `/teacher/papers/${id}`, T1).catch(() => {});
  await db.query(`delete from tests where id = any($1::uuid[])`, [made.tests]).catch((e) => console.log('test cleanup:', e.message));
  await db.query(`delete from questions where id = any($1::uuid[]) or text like $2`, [made.questions, `${tag}%`]).catch((e) => console.log('question cleanup:', e.message));
  await db.query(`delete from device_tokens where token = any($1::text[])`, [made.tokens]).catch(() => {});
  const left = await one(
    `select (select count(*) from tests where title like $1)::int as tests, (select count(*) from questions where text like $1)::int as questions,
            (select count(*) from class_sections where name like $1)::int as sections, (select count(*) from tuitions where name like $1)::int as tuitions`,
    [`${tag}%`],
  );
  check('everything this test made is gone', left.tests + left.questions + left.sections + left.tuitions === 0, left);
  check('the minimum build is as it was', ((await one(`select value from app_settings where key = 'min_app_build'`))?.value ?? null) === origMin);
  await db.end();
}
console.log(`\n${pass} passed, ${fail} failed${skipped ? `, ${skipped} skipped` : ''}`);
process.exit(fail ? 1 : 0);
