// Security and robustness checks over every route of the API, found from the app itself so a new route is never forgotten:
//   1. a caller who is not signed in is refused everywhere, and each role is refused the other roles' routes
//   2. a tutor or student of another tuition can neither read nor change anything of this one, on any route that takes an id
//   3. no route answers a malformed body, a wrong type, a junk id or a junk query with a server error
//   4. sessions: a new password signs the other phones out, a PIN reset and a turned-off login sign the student out,
//      and five wrong tries lock a login
//   5. requests that arrive together: wrong tries, sign-ups, tuitions, starts and submits are counted one by one
//   6. a big body that no route reads must not freeze the next request, and one over a megabyte is refused
// Makes its own tutors, tuitions and students and removes them again. Dev only: it refuses to run against any other branch.
// Usage: node tools/security-test.ts [--env .env.local] [--base http://127.0.0.1:8787] [--only '<route regex>'] [--verbose]
import { randomInt } from 'node:crypto';
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
const logins = JSON.parse(readFileSync('tools/out/sample-logins.dev.json', 'utf8'));
const MATHS = '00000000-0000-4000-8000-000000000001';
const UUID0 = '00000000-0000-4000-8000-0000000000dd';
const APP = 'core_academy/1.6.0+8';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  if (!ok || verbose) console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}
const verbose = args.includes('--verbose');
// --only <regex>: fuzz just the routes whose "METHOD /path" matches (the other sections still run).
const only = args.includes('--only') ? new RegExp(args[args.indexOf('--only') + 1]) : null;

type Reply = { status: number; body: any };
async function call(method: string, path: string, token: string | undefined, raw: string | undefined, headers: Record<string, string> = {}): Promise<Reply> {
  try {
    const res = await fetch(BASE + path, {
      method,
      headers: {
        'x-app': APP,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(raw !== undefined ? { 'content-type': 'application/json' } : {}),
        ...headers,
      },
      body: raw,
      signal: AbortSignal.timeout(60_000),
    });
    const text = await res.text();
    let body: any = null;
    try { body = JSON.parse(text); } catch { body = text.slice(0, 200); }
    return { status: res.status, body };
  } catch (e) {
    return { status: 0, body: String(e) };
  }
}
const api = (method: string, path: string, token?: string, body?: unknown, headers: Record<string, string> = {}) =>
  call(method, path, token, body === undefined ? undefined : JSON.stringify(body), headers);
const login = (username: string, secret: string) => api('POST', '/auth/login', undefined, { username, secret });
const code = (r: Reply) => r.body?.error?.code;
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();
const serverError = (r: Reply) => r.status === 0 || code(r) === 'server_error' || (r.status >= 500 && !String(code(r) ?? '').startsWith('ai_'));

async function inParallel<T>(limit: number, items: T[], fn: (x: T) => Promise<void>) {
  let i = 0;
  await Promise.all(Array.from({ length: limit }, async () => {
    while (i < items.length) await fn(items[i++]);
  }));
}

// ------------------------------------------------------------------ the routes, from the app itself
const { default: app } = await import('../api/src/index.ts');
const routes = [...new Map(app.routes.filter((r) => r.method !== 'ALL').map((r) => [`${r.method} ${r.path}`, r])).values()]
  .map((r) => ({ key: `${r.method} ${r.path}`, method: r.method, path: r.path }));
const PUBLIC = new Set(['GET /', 'POST /auth/login', 'POST /auth/signup-tutor', 'POST /cron/notify']);

const tag = `sec${randomInt(1000, 9999)}`;
const created = { users: [] as string[], tuitions: [] as string[], subjects: [] as string[] };
const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();

type World = {
  tuition: string; tutorId: string; T: string; studentId: string; studentName: string; S: string;
  question: string; test: string; course: string; paper: string; draft: string; subject: string; chapter: string; attempt: string; level: string;
};

async function makeWorld(suffix: string): Promise<World> {
  const inst = { 'x-install-id': `${tag}-${suffix}` };
  const su = await api('POST', '/auth/signup-tutor', undefined, { display_name: `Sec ${suffix}`, username: `${tag}.${suffix}`, password: 'longenough1' }, inst);
  if (su.status !== 201) throw new Error(`sign-up of ${suffix} failed: ${JSON.stringify(su.body)}`);
  created.users.push(su.body.user.id);
  const T = su.body.token as string;
  const mk = await api('POST', '/auth/tuitions', T, { name: `${tag} ${suffix}`, groups: [{ class_level: 9, subject_id: MATHS }] });
  if (mk.status !== 201) throw new Error(`tuition of ${suffix} failed: ${JSON.stringify(mk.body)}`);
  created.tuitions.push(mk.body.tuition.id);
  const st = await api('POST', '/teacher/students', T, { display_name: `Pupil ${suffix}`, class_level: 9, username: `${tag}.p${suffix}`, pin: '4321', subject_ids: [MATHS] });
  if (st.status !== 201) throw new Error(`student of ${suffix} failed: ${JSON.stringify(st.body)}`);
  created.users.push(st.body.student.id);
  const sl = await login(`${tag}.p${suffix}`, '4321');
  const S = sl.body.token as string;
  const q = await api('POST', '/teacher/questions', T, { class_level: 9, text: `${tag} ${suffix} 1+1?`, options: ['1', '2', '3', '4'], correct_option: 1, subject_id: MATHS });
  const t = await api('POST', '/teacher/tests', T, {
    title: `${tag} ${suffix} test`, class_level: 9, subject_id: MATHS, question_ids: [q.body.id], shuffle: false, assign_all: false, assign_group: true, closes_at: iso(86_400_000),
  });
  await api('POST', `/teacher/tests/${t.body.id}/publish`, T, { published: true });
  const co = await api('POST', '/teacher/courses', T, { name: `${tag} ${suffix} course` });
  await api('POST', `/teacher/courses/${co.body.course.id}/people`, T, { student_ids: [st.body.student.id] });
  const pa = await api('POST', '/teacher/papers', T, { pages: 1, class_level: 9, subject_id: MATHS });
  const dr = await db.query(
    `insert into paper_drafts (paper_id, page_no, seq, kind, text, options) values ($1, 1, 0, 'mcq', 'draft?', array['a','b','c','d']) returning id`,
    [pa.body.paper.id],
  );
  const sj = await api('POST', '/teacher/subjects', T, { name: `${tag}${suffix} Subject` });
  created.subjects.push(sj.body.subject.id);
  const ch = await api('POST', '/teacher/chapters', T, { class_level: 9, name: `${tag}${suffix} chapter`, subject_id: MATHS });
  const lv = await api('POST', '/teacher/levels', T, { label: `${tag}${suffix}` });
  const started = await api('POST', `/student/tests/${t.body.id}/start`, S);
  await api('POST', `/student/attempts/${started.body.attempt.id}/submit`, S, { answers: [{ question_id: q.body.id, choice: 0 }] });
  return {
    tuition: mk.body.tuition.id, tutorId: su.body.user.id, T, studentId: st.body.student.id, studentName: `${tag}.p${suffix}`, S,
    question: q.body.id, test: t.body.id, course: co.body.course.id, paper: pa.body.paper.id, draft: dr.rows[0].id, subject: sj.body.subject.id,
    chapter: ch.body.chapter.id, attempt: started.body.attempt.id, level: String(lv.body.level.code),
  };
}

/** What every route of one tuition holds, as one hash: it must not change when somebody else pokes at it. */
async function fingerprint(w: World) {
  const r = await db.query(
    `select md5(coalesce(string_agg(x, '|' order by x), '')) as h, count(*) as n from (
       select 'u:' || id || display_name || coalesce(class_level::text, '') || active || username || coalesce(secret_hash, '') as x from users where id = any($1::uuid[])
       union all select 'm:' || user_id || status || coalesce(class_level::text, '') from memberships where tuition_id = $2
       union all select 'q:' || id || text || correct_option || marks from questions where tuition_id = $2
       union all select 't:' || id || title || status || coalesce(closes_at::text, '') || coalesce(results_released_at::text, '') from tests where tuition_id = $2
       union all select 'c:' || id || name from courses where tuition_id = $2
       union all select 'cm:' || course_id || student_id from course_members where course_id in (select id from courses where tuition_id = $2)
       union all select 'p:' || id || exam_name from papers where tuition_id = $2
       union all select 'd:' || id || text || status from paper_drafts where paper_id in (select id from papers where tuition_id = $2)
       union all select 'a:' || id || coalesce(submitted_at::text, '') || coalesce(score::text, '') from attempts where test_id in (select id from tests where tuition_id = $2)
       union all select 'sj:' || id || name from subjects where tuition_id = $2
       union all select 'ch:' || id || name from chapters where tuition_id = $2
       union all select 'lv:' || code || label from tuition_levels where tuition_id = $2
       union all select 'g:' || id || class_level || subject_id from groups where tuition_id = $2
       union all select 'tu:' || name || join_code || join_open from tuitions where id = $2
       union all select 'se:' || token_hash from sessions where user_id = any($1::uuid[])
     ) z`,
    [[w.tutorId, w.studentId], w.tuition],
  );
  return `${r.rows[0].h}/${r.rows[0].n}`;
}

let A: World | undefined;
let B: World | undefined;
try {
  A = await makeWorld('a');
  B = await makeWorld('b');
  const devLogin = await login(logins.developer.username, logins.developer.password);
  const DEV = devLogin.body?.token as string | undefined;
  check('the developer login works on dev', !!DEV, devLogin.body);
  console.log(`${routes.length} routes found; testing them as nobody, a student, a tutor, a developer and the other tuition`);

  // ---------------------------------------------------------------- 1. who may call what
  const bare = (path: string) => path.replace(/:(\w+)/g, (_, k) => (k === 'cls' ? '9' : k === 'n' ? '1' : k === 'code' ? '1001' : UUID0));
  for (const r of routes) {
    const raw = r.method === 'GET' ? undefined : '{}';
    const res = await call(r.method, bare(r.path), undefined, raw);
    if (r.key === 'GET /') check('the root says only what the app needs', res.status === 200 && Object.keys(res.body).sort().join() === 'ai,branch,gemini,name,push', res.body);
    else if (r.key === 'POST /auth/login') check('login with nothing is refused', res.status === 401, res.body);
    else if (r.key === 'POST /auth/signup-tutor') check('sign-up with nothing is refused', res.status === 400, res.body);
    else if (r.key === 'POST /cron/notify') check('the notification trigger refuses a plain caller', res.status === 401 && code(res) === 'not_a_trigger', res.body);
    else check(`${r.key} refuses nobody-at-all`, res.status === 401 && code(res) === 'signed_out', res);
  }
  const forged = await call('POST', '/cron/notify', undefined, '{}', { 'x-neon-trigger-invocation-id': 'abc', 'x-neon-trigger-name': 'notify' });
  check('the notification trigger refuses a forged header', forged.status === 401, forged);

  for (const r of routes) {
    if (PUBLIC.has(r.key)) continue;
    const raw = r.method === 'GET' ? undefined : '{}';
    const first = r.path.split('/')[1];
    // Only the routes with a role are called: /auth/logout and the like would sign the tokens out for everything after them.
    if (!['student', 'teacher', 'admin'].includes(first) && r.key !== 'POST /auth/tuitions' && r.key !== 'GET /auth/standard-subjects') continue;
    const asStudent = await call(r.method, bare(r.path), A.S, raw);
    const asTutor = await call(r.method, bare(r.path), A.T, raw);
    const asDev = DEV ? await call(r.method, bare(r.path), DEV, raw) : null;
    const forbidden = (x: Reply | null) => x === null || (x.status === 403 && code(x) === 'forbidden');
    if (first === 'student') {
      check(`${r.key}: a tutor is refused`, forbidden(asTutor), asTutor);
      check(`${r.key}: the developer is refused`, forbidden(asDev), asDev);
    } else if (first === 'teacher' || r.key === 'POST /auth/tuitions' || r.key === 'GET /auth/standard-subjects') {
      check(`${r.key}: a student is refused`, forbidden(asStudent), asStudent);
      check(`${r.key}: the developer is refused`, forbidden(asDev), asDev);
    } else if (first === 'admin') {
      check(`${r.key}: a student is refused`, forbidden(asStudent), asStudent);
      check(`${r.key}: a tutor is refused`, forbidden(asTutor), asTutor);
    }
  }
  const ghost = await api('GET', '/teacher/home', B.T, undefined, { 'x-tuition': A.tuition });
  check('naming a tuition you are not in is refused', ghost.status === 403 && code(ghost) === 'not_a_member', ghost);
  const badHeader = await api('GET', '/teacher/home', B.T, undefined, { 'x-tuition': "x'; drop table users;--" });
  check('a junk tuition header is a 400', badHeader.status === 400, badHeader);
  const noBearer = await call('GET', '/auth/me', undefined, undefined, { authorization: 'Basic abc' });
  check('a header that is not a bearer token is refused', noBearer.status === 401, noBearer);
  const junkToken = await api('GET', '/auth/me', 'not-a-real-token');
  check('a made-up token is refused', junkToken.status === 401, junkToken);

  // ---------------------------------------------------------------- 2. the other tuition
  // Every route that names something by id, as the other tuition's tutor or student, with a body that would be valid for its owner.
  const q9 = { class_level: 9, text: 'hijack?', options: ['1', '2', '3', '4'], correct_option: 0 };
  type Foreign = { who: 'tutor' | 'student'; method: string; path: string; body?: unknown };
  const foreign: Record<string, Foreign> = {
    'GET /teacher/students/:id': { who: 'tutor', method: 'GET', path: `/teacher/students/${A.studentId}` },
    'PATCH /teacher/students/:id': { who: 'tutor', method: 'PATCH', path: `/teacher/students/${A.studentId}`, body: { display_name: 'Hijack', class_level: 10 } },
    'POST /teacher/students/:id/reset-pin': { who: 'tutor', method: 'POST', path: `/teacher/students/${A.studentId}/reset-pin`, body: { pin: '0000' } },
    'DELETE /teacher/students/:id': { who: 'tutor', method: 'DELETE', path: `/teacher/students/${A.studentId}` },
    'POST /teacher/students/:id/active': { who: 'tutor', method: 'POST', path: `/teacher/students/${A.studentId}/active`, body: { active: false } },
    'PATCH /teacher/subjects/:id': { who: 'tutor', method: 'PATCH', path: `/teacher/subjects/${A.subject}`, body: { name: 'Hijack' } },
    'DELETE /teacher/subjects/:id': { who: 'tutor', method: 'DELETE', path: `/teacher/subjects/${A.subject}` },
    'DELETE /teacher/groups/:cls/:subject': { who: 'tutor', method: 'DELETE', path: `/teacher/groups/9/${MATHS}` },
    'GET /teacher/groups/:cls/:subject': { who: 'tutor', method: 'GET', path: `/teacher/groups/9/${A.subject}` },
    'POST /teacher/tutors/:id/active': { who: 'tutor', method: 'POST', path: `/teacher/tutors/${A.tutorId}/active`, body: { active: false } },
    'PATCH /teacher/chapters/:id': { who: 'tutor', method: 'PATCH', path: `/teacher/chapters/${A.chapter}`, body: { name: 'Hijack' } },
    'DELETE /teacher/chapters/:id': { who: 'tutor', method: 'DELETE', path: `/teacher/chapters/${A.chapter}` },
    'GET /teacher/questions/:id': { who: 'tutor', method: 'GET', path: `/teacher/questions/${A.question}` },
    'PATCH /teacher/questions/:id': { who: 'tutor', method: 'PATCH', path: `/teacher/questions/${A.question}`, body: q9 },
    'DELETE /teacher/questions/:id': { who: 'tutor', method: 'DELETE', path: `/teacher/questions/${A.question}` },
    'GET /teacher/tests/:id': { who: 'tutor', method: 'GET', path: `/teacher/tests/${A.test}` },
    'PATCH /teacher/tests/:id': { who: 'tutor', method: 'PATCH', path: `/teacher/tests/${A.test}`, body: { title: 'Hijack', class_level: 9, question_ids: [A.question], closes_at: iso(3_600_000) } },
    'POST /teacher/tests/:id/publish': { who: 'tutor', method: 'POST', path: `/teacher/tests/${A.test}/publish`, body: { published: false } },
    'DELETE /teacher/tests/:id': { who: 'tutor', method: 'DELETE', path: `/teacher/tests/${A.test}?with_results=1` },
    'POST /teacher/tests/:id/release-results': { who: 'tutor', method: 'POST', path: `/teacher/tests/${A.test}/release-results`, body: {} },
    'GET /teacher/tests/:id/results': { who: 'tutor', method: 'GET', path: `/teacher/tests/${A.test}/results` },
    'POST /teacher/tests/:id/retake': { who: 'tutor', method: 'POST', path: `/teacher/tests/${A.test}/retake`, body: { student_id: A.studentId } },
    'GET /teacher/attempts/:id': { who: 'tutor', method: 'GET', path: `/teacher/attempts/${A.attempt}` },
    'POST /teacher/join-requests/:id/accept': { who: 'tutor', method: 'POST', path: `/teacher/join-requests/${A.studentId}/accept`, body: { class_level: 9 } },
    'POST /teacher/join-requests/:id/decline': { who: 'tutor', method: 'POST', path: `/teacher/join-requests/${A.studentId}/decline`, body: {} },
    'PATCH /teacher/levels/:code': { who: 'tutor', method: 'PATCH', path: `/teacher/levels/${A.level}`, body: { label: 'Hijack' } },
    'DELETE /teacher/levels/:code': { who: 'tutor', method: 'DELETE', path: `/teacher/levels/${A.level}` },
    'GET /teacher/courses/:id': { who: 'tutor', method: 'GET', path: `/teacher/courses/${A.course}` },
    'DELETE /teacher/courses/:id': { who: 'tutor', method: 'DELETE', path: `/teacher/courses/${A.course}?with_results=1` },
    'POST /teacher/courses/:id/people': { who: 'tutor', method: 'POST', path: `/teacher/courses/${A.course}/people`, body: { student_ids: [B.studentId] } },
    'POST /teacher/courses/:id/people/new': { who: 'tutor', method: 'POST', path: `/teacher/courses/${A.course}/people/new`, body: { display_name: 'Hijack Newcomer', username: `${tag}.hijack` } },
    'DELETE /teacher/courses/:id/people/:studentId': { who: 'tutor', method: 'DELETE', path: `/teacher/courses/${A.course}/people/${A.studentId}` },
    'POST /teacher/papers/:id/pages/:n/uploaded': { who: 'tutor', method: 'POST', path: `/teacher/papers/${A.paper}/pages/1/uploaded`, body: {} },
    'GET /teacher/papers/:id': { who: 'tutor', method: 'GET', path: `/teacher/papers/${A.paper}` },
    'PATCH /teacher/papers/:id': { who: 'tutor', method: 'PATCH', path: `/teacher/papers/${A.paper}`, body: { exam_name: 'Hijack' } },
    'POST /teacher/papers/:id/detect': { who: 'tutor', method: 'POST', path: `/teacher/papers/${A.paper}/detect`, body: {} },
    'POST /teacher/papers/:id/pages/:n/read': { who: 'tutor', method: 'POST', path: `/teacher/papers/${A.paper}/pages/1/read`, body: {} },
    'POST /teacher/papers/:id/answers': { who: 'tutor', method: 'POST', path: `/teacher/papers/${A.paper}/answers`, body: {} },
    'POST /teacher/papers/:id/second-opinion': { who: 'tutor', method: 'POST', path: `/teacher/papers/${A.paper}/second-opinion`, body: {} },
    'PATCH /teacher/drafts/:id': { who: 'tutor', method: 'PATCH', path: `/teacher/drafts/${A.draft}`, body: { text: 'Hijack' } },
    'POST /teacher/papers/:id/save': { who: 'tutor', method: 'POST', path: `/teacher/papers/${A.paper}/save`, body: {} },
    'DELETE /teacher/papers/:id': { who: 'tutor', method: 'DELETE', path: `/teacher/papers/${A.paper}` },
    'GET /student/courses/:id': { who: 'student', method: 'GET', path: `/student/courses/${A.course}` },
    'POST /student/tests/:id/start': { who: 'student', method: 'POST', path: `/student/tests/${A.test}/start`, body: {} },
    'PUT /student/attempts/:id/answers': { who: 'student', method: 'PUT', path: `/student/attempts/${A.attempt}/answers`, body: { answers: [{ question_id: A.question, choice: 1 }] } },
    'POST /student/attempts/:id/submit': { who: 'student', method: 'POST', path: `/student/attempts/${A.attempt}/submit`, body: { answers: [] } },
    'GET /student/attempts/:id/result': { who: 'student', method: 'GET', path: `/student/attempts/${A.attempt}/result` },
    'GET /admin/people/:id': { who: 'tutor', method: 'GET', path: `/admin/people/${A.studentId}` },
    'POST /admin/people/:id/sign-out': { who: 'tutor', method: 'POST', path: `/admin/people/${A.studentId}/sign-out`, body: { install_id: 'x' } },
    'POST /admin/people/:id/unlock': { who: 'tutor', method: 'POST', path: `/admin/people/${A.studentId}/unlock`, body: {} },
    'GET /admin/clients/:id': { who: 'tutor', method: 'GET', path: `/admin/clients/${A.tuition}` },
  };
  const named = routes.filter((r) => r.path.includes(':'));
  for (const r of named) {
    check(`${r.key} is covered by the other-tuition checks`, r.key in foreign, 'add it to the table in tools/security-test.ts');
  }
  for (const key of Object.keys(foreign)) check(`${key} is still a route of the API`, routes.some((r) => r.key === key), 'remove it from the table');

  const before = await fingerprint(A);
  for (const [key, f] of Object.entries(foreign)) {
    const token = f.who === 'student' ? B.S : B.T;
    const res = await api(f.method, f.path, token, f.body);
    // Never a 2xx (it worked), never a 5xx (it broke); the other tuition's thing is simply not there.
    const refused = res.status >= 400 && res.status < 500;
    // A level or group is named by its number inside the caller's own tuition, and a delete of something already gone says ok:
    // those may answer 2xx, and the fingerprint below proves they touched nothing of the first tuition.
    const ownNamespace = ['PATCH /teacher/levels/:code', 'DELETE /teacher/levels/:code', 'DELETE /teacher/chapters/:id', 'DELETE /teacher/groups/:cls/:subject'].includes(key);
    const expected = key.startsWith('GET /admin') || key.startsWith('POST /admin') ? res.status === 403 : ownNamespace ? res.status < 500 : refused;
    check(`${key}: the other tuition gets nothing`, expected, res);
  }
  // The same ids named through the other tuition's header, and with a tutor of the same name space, change nothing either.
  const listsA = ['/teacher/students', '/teacher/questions', '/teacher/tests', '/teacher/papers', '/teacher/courses', '/teacher/subjects', '/teacher/chapters', '/teacher/groups', '/teacher/tutors', '/teacher/levels', '/teacher/join-requests'];
  for (const p of listsA) {
    const res = await api('GET', p, B.T);
    const text = JSON.stringify(res.body);
    check(`GET ${p} as the other tuition shows none of ${A.studentName.slice(0, 7)}'s things`, res.status === 200 && !text.includes(A.studentId) && !text.includes(A.question) && !text.includes(A.test) && !text.includes(A.course) && !text.includes(A.paper), res.status);
  }
  const withForeignCourse = await api('GET', `/teacher/questions?course=${A.course}`, B.T);
  check('a list filtered by the other tuition\'s course is refused', withForeignCourse.status === 404, withForeignCourse);
  const after = await fingerprint(A);
  check('after all of that, the first tuition holds exactly what it held before', before === after, { before, after });

  // ---------------------------------------------------------------- 3. nothing answers with a server error
  const keys = ['display_name', 'username', 'pin', 'password', 'current', 'next', 'class_level', 'subject_id', 'subject_ids', 'name', 'title', 'text', 'options', 'correct_option',
    'solution', 'marks', 'question_ids', 'student_ids', 'student_id', 'pages', 'sizes', 'size', 'request', 'count', 'paper_id', 'course_id', 'chapter_id', 'opens_at', 'closes_at',
    'time_limit_min', 'shuffle', 'assign_all', 'assign_group', 'published', 'active', 'answers', 'auto', 'token', 'code', 'label', 'exam_name', 'category', 'tuition_name',
    'join_open', 'confirmed', 'status', 'kind', 'image_key', 'needs_diagram', 'install_id', 'session', 'sort_order', 'groups', 'secret'];
  const junk: unknown[] = [null, 123, -1, 1e21, 'x'.repeat(5000), '', ' ', 'a\u0000b', {}, [], [1, 2, 3], [{}], true, 'ɐ'.repeat(10), '../../etc/passwd', '😀'.repeat(50),
    '2026-13-45', 'NaN', 3.14, 2 ** 53, '1e999', "'; select pg_sleep(5);--", '%00', '\ud800'];
  const bodies: (string | undefined)[] = [undefined, '', '{', '[]', '"s"', 'null', '123', '{}', '{"__proto__":{"x":1}}', '[' .repeat(3000) + ']'.repeat(3000)];
  for (const v of junk) bodies.push(JSON.stringify(Object.fromEntries(keys.map((k) => [k, v]))));
  const queries = ['', '?class=abc', '?class=99999999999', '?class=-5', '?subject=abc', '?chapter=abc', '?course=abc', '?q=%00', '?q=%25%25%25', '?group=zzz', '?group=cat:', '?before=abc',
    '?with_results=abc', '?class=1&subject=2&chapter=3&course=4&q=5&group=6'];
  const junkParams = ['abc', "1' or '1'='1", '%00', '9'.repeat(30), '-1', '1e9', 'NaN', '../..', 'x'.repeat(2000), UUID0];
  const ownParams = (r: { path: string }): string[] => {
    // The real ids of the first tuition, so the handler goes past the id checks into its own logic.
    const segs = r.path.split('/');
    const out: string[] = [];
    const idFor = (seg: string) => ({
      students: A!.studentId, questions: A!.question, tests: A!.test, courses: A!.course, papers: A!.paper, attempts: A!.attempt, drafts: A!.draft, subjects: A!.subject,
      chapters: A!.chapter, tutors: A!.tutorId, people: A!.studentId, clients: A!.tuition, levels: A!.level, 'join-requests': A!.studentId,
    } as Record<string, string>)[seg];
    let path = r.path;
    for (let i = 0; i < segs.length; i++) {
      if (!segs[i].startsWith(':')) continue;
      const kind = segs[i] === ':studentId' ? 'people' : segs[i] === ':cls' ? 'cls' : segs[i] === ':n' ? 'n' : segs[i - 1];
      const v = kind === 'cls' ? '9' : kind === 'n' ? '1' : kind === 'subjects' && segs[i - 2] === 'groups' ? MATHS : (idFor(kind) ?? UUID0);
      path = path.replace(segs[i], v);
    }
    out.push(path);
    return out;
  };
  // Routes that read a query string get the junk queries; for the others a query would change nothing.
  const QUERY_ROUTES = /^(GET \/teacher\/(students|chapters|questions|tests|papers|username-suggestion)|GET \/teacher\/students\/:id|GET \/admin\/log|DELETE \/teacher\/(tests|courses))/;
  const fuzzJobs: { r: (typeof routes)[number]; path: string; raw?: string }[] = [];
  const someBodies = [bodies[0], bodies[7], bodies[bodies.length - 4]];
  for (const r of routes) {
    // Signing out is checked below: fuzzed here it would end the session every later request needs.
    if (r.key === 'POST /cron/notify' || r.key === 'POST /auth/logout') continue;
    if (only && !only.test(r.key)) continue;
    const withBody = r.method !== 'GET';
    const own = ownParams(r)[0];
    const hasParams = r.path.includes(':');
    // 1. real ids of the first tuition, so the handler goes past the id checks into its own logic: every junk body or query.
    // Destructive calls on real ids are checked elsewhere; here they would only empty the tuition for the calls after them.
    const destructive = (r.method === 'DELETE' && hasParams) || /\/(active|reset-pin|release-results|publish|join-code|retake)$/.test(r.path);
    if (!destructive) {
      if (withBody) for (const raw of bodies) fuzzJobs.push({ r, path: own, raw });
      else for (const qs of QUERY_ROUTES.test(r.key) ? queries : ['']) fuzzJobs.push({ r, path: own + qs });
    }
    // 2. junk where the ids go: a few bodies or queries each.
    if (hasParams) {
      for (const j of junkParams) {
        const path = r.path.replace(/:(\w+)/g, () => j);
        if (withBody) for (const raw of someBodies) fuzzJobs.push({ r, path, raw });
        else for (const qs of ['', queries[1], queries[6]]) fuzzJobs.push({ r, path: path + qs });
      }
    }
  }
  const tokenFor = (r: { path: string }) => (r.path.startsWith('/student') ? A!.S : r.path.startsWith('/admin') ? DEV : A!.T);
  const broke = new Map<string, { status: number; sample: string }>();
  const slow = new Map<string, string>();
  let sent = 0;
  const fuzzStart = Date.now();
  const slowTrace: string[] = [];
  await inParallel(6, fuzzJobs, async (job) => {
    const token = tokenFor(job.r);
    if (!token) return;
    const started = Date.now();
    const res = await call(job.r.method, job.path, PUBLIC.has(job.r.key) ? undefined : token, job.raw);
    const ms = Date.now() - started;
    sent++;
    const k = job.r.key;
    if (serverError(res) && !broke.has(k)) broke.set(k, { status: res.status, sample: `${job.r.method} ${job.path.slice(0, 120)} body=${(job.raw ?? '').slice(0, 90)} -> ${JSON.stringify(res.body).slice(0, 120)}` });
    if (ms > 4000 && !slow.has(k)) slow.set(k, `${ms} ms: ${job.path.slice(0, 100)} body=${(job.raw ?? '').slice(0, 60)}`);
    if (ms > 4000) slowTrace.push(`  ${new Date(started).toISOString()} (+${((started - fuzzStart) / 1000).toFixed(1)} s) took ${ms} ms, status ${res.status}: ${job.r.method} ${job.path.slice(0, 80)} body of ${(job.raw ?? '').length} characters: ${(job.raw ?? '').slice(0, 40)}`);
  });
  console.log(`${sent} junk requests sent`);
  if (slowTrace.length) console.log(`${slowTrace.length} of them took over 4 seconds:\n${slowTrace.sort().join('\n')}`);
  // The junk sent to the password route counted as wrong guesses, which locked the tutor, as it should: say so, then unlock for the rest.
  const lockedByJunk = await db.query('select locked_until > now() as locked from users where id = $1', [A.tutorId]);
  if (!only || only.test('POST /teacher/password')) check('guessing the current password over and over locked the tutor', lockedByJunk.rows[0].locked === true, lockedByJunk.rows[0]);
  await db.query('update users set failed_count = 0, locked_until = null where id = $1', [A.tutorId]);
  check('after the junk, the tutor is still signed in', (await api('GET', '/auth/me', A.T)).status === 200);
  check('after the junk, the student is still signed in', (await api('GET', '/student/home', A.S)).status === 200);
  for (const r of routes) {
    if (r.key === 'POST /cron/notify' || r.key === 'POST /auth/logout') continue;
    const b = broke.get(r.key);
    check(`${r.key} never answers junk with a server error`, !b, b);
  }
  for (const [k, v] of slow) check(`${k} never hangs on junk (an injected sleep would show here)`, false, v);


  // ---------------------------------------------------------------- 3b. one bad value in an otherwise good request
  const T4 = (await login(`${tag}.a`, 'longenough1')).body.token as string;
  const nul = 'a\u0000b';
  const good = { class_level: 9, subject_id: MATHS, options: ['1', '2', '3', '4'], correct_option: 0 };
  const textCases: [string, string, unknown][] = [
    ['POST', '/teacher/subjects', { name: nul }],
    ['POST', '/teacher/courses', { name: nul }],
    ['POST', '/teacher/chapters', { class_level: 9, subject_id: MATHS, name: nul }],
    ['POST', '/teacher/levels', { label: nul }],
    ['POST', '/teacher/questions', { ...good, text: nul }],
    ['POST', '/teacher/questions', { ...good, text: 'x', options: ['1', '2', nul, '4'] }],
    ['POST', '/teacher/questions', { ...good, text: 'x', options: ['1', '2', 'y'.repeat(1001), '4'] }],
    ['POST', '/teacher/tests', { title: nul, class_level: 9, subject_id: MATHS, question_ids: [A.question], closes_at: iso(86_400_000) }],
    ['POST', '/teacher/students', { display_name: nul, class_level: 9, username: `${tag}.nul`, subject_ids: [MATHS] }],
    ['POST', '/teacher/tutors', { display_name: nul, username: `${tag}.nul2`, password: 'longenough1' }],
    ['PATCH', '/teacher/settings', { tuition_name: nul }],
    ['PATCH', '/teacher/tuition', { name: nul }],
    ['POST', '/teacher/papers', { pages: 1, class_level: 9, subject_id: MATHS, exam_name: nul }],
    ['POST', '/teacher/papers', { pages: 1, class_level: 9, subject_id: MATHS, category: nul }],
    ['PATCH', `/teacher/drafts/${A.draft}`, { text: nul }],
    ['PATCH', `/teacher/drafts/${A.draft}`, { options: ['a', nul, 'c', 'd'] }],
    ['POST', '/devices', { token: nul }],
    ['POST', '/auth/tuitions', { name: nul, groups: [] }],
    ['POST', '/auth/signup-tutor', { display_name: nul, username: `${tag}.nul3`, password: 'longenough1' }],
  ];
  for (const [m, p, body] of textCases) {
    const res = await api(m, p, p.startsWith('/auth/signup') ? undefined : T4, body);
    check(`${m} ${p} with a NUL character is a 400, not a server error`, res.status === 400, res);
  }
  const loginNul = await login(nul, '1234');
  check('login with a NUL in the username is a plain refusal', loginNul.status === 401, loginNul);
  for (const [what, path] of [
    ['a class that is a word', '/teacher/students?class=abc'], ['a class that is huge', '/teacher/questions?class=99999999999'],
    ['a chapter list with a word for a class', '/teacher/chapters?class=x'], ['a search with a NUL', '/teacher/questions?q=%00'],
    ['a page that is a word', `/teacher/papers/${A.paper}/pages/abc/read`], ['a page that is a uuid', `/teacher/papers/${A.paper}/pages/${UUID0}/uploaded`],
    ['page 0', `/teacher/papers/${A.paper}/pages/0/read`], ['page 21', `/teacher/papers/${A.paper}/pages/21/read`],
  ]) {
    const res = await api(path.includes('/pages/') ? 'POST' : 'GET', path, T4, path.includes('/pages/') ? {} : undefined);
    check(`${what} is a 400`, res.status === 400, res);
  }
  const bigBody = await api('POST', '/teacher/questions', T4, { ...good, text: 'x'.repeat(5_000_000) });
  check('a 5 MB question is refused, not crashed on', bigBody.status >= 400 && bigBody.status < 500, bigBody.status);
  const after2 = await api('GET', '/teacher/home', T4);
  check('and the server is still answering', after2.status === 200, after2.status);

  // A student cannot answer a question that is not in the attempt, whatever it is called.
  const t3 = await api('POST', '/teacher/tests', T4, {
    title: `${tag} words`, class_level: 9, subject_id: MATHS, question_ids: [A.question], shuffle: false, assign_all: false, assign_group: true, closes_at: iso(86_400_000),
  });
  await api('POST', `/teacher/tests/${t3.body.id}/publish`, T4, { published: true });
  const SW = (await login(A.studentName, '4321')).body.token as string;
  const open = await api('POST', `/student/tests/${t3.body.id}/start`, SW);
  const attemptW = open.body?.attempt?.id;
  check('a student starts a test to try odd answers on', open.status === 200 && !!attemptW, open.body);
  for (const qid of ['constructor', '__proto__', 'toString', UUID0, '', 7, null]) {
    const res = await api('PUT', `/student/attempts/${attemptW}/answers`, SW, { answers: [{ question_id: qid, choice: 1 }] });
    check(`an answer for the question ${JSON.stringify(qid)} is a 400`, res.status === 400, res);
  }
  const odd = await api('PUT', `/student/attempts/${attemptW}/answers`, SW, { answers: [{ question_id: A.question, choice: 7 }] });
  check('a choice of 7 is a 400', odd.status === 400, odd);
  const fine = await api('PUT', `/student/attempts/${attemptW}/answers`, SW, { answers: [{ question_id: A.question, choice: 1, flagged: true }] });
  check('and a real answer is saved', fine.status === 200 && fine.body.saved === 1, fine);

  // ---------------------------------------------------------------- 4. sessions and locks
  const second = await login(`${tag}.a`, 'longenough1');
  const T2 = second.body.token as string;
  const wrongNow = await api('POST', '/teacher/password', A.T, { current: 'not-the-password', next: 'newpassword1' });
  check('a wrong current password is refused', wrongNow.status === 400 && code(wrongNow) === 'wrong_password', wrongNow);
  const changed = await api('POST', '/teacher/password', A.T, { current: 'longenough1', next: 'newpassword1' });
  check('a tutor changes their password', changed.status === 200, changed);
  check('the phone that changed it stays signed in', (await api('GET', '/auth/me', A.T)).status === 200);
  check('the other phone is signed out by the change', (await api('GET', '/auth/me', T2)).status === 401);
  check('the old password no longer works', (await login(`${tag}.a`, 'longenough1')).status === 401);
  const relogin = await login(`${tag}.a`, 'newpassword1');
  check('the new one does', relogin.status === 200, relogin.body);
  A.T = relogin.body.token;

  const phone2 = await login(A.studentName, '4321');
  const reset = await api('POST', `/teacher/students/${A.studentId}/reset-pin`, A.T, { pin: '5678' });
  check('a tutor resets a student\'s PIN', reset.status === 200 && reset.body.login.pin === '5678', reset.body);
  check('every phone of that student is signed out', (await api('GET', '/student/home', A.S)).status === 401 && (await api('GET', '/student/home', phone2.body.token)).status === 401);
  const back = await login(A.studentName, '5678');
  A.S = back.body.token;
  check('the new PIN works', back.status === 200, back.body);
  const off = await api('POST', `/teacher/students/${A.studentId}/active`, A.T, { active: false });
  check('a tutor turns a student off', off.status === 200, off.body);
  check('the turned-off student\'s phone is signed out at once', (await api('GET', '/student/home', A.S)).status === 401);
  const offLogin = await login(A.studentName, '5678');
  check('and told so only when the PIN is right', offLogin.status === 403 && code(offLogin) === 'inactive', offLogin.body);
  await api('POST', `/teacher/students/${A.studentId}/active`, A.T, { active: true });

  const victim = await api('POST', '/teacher/students', A.T, { display_name: 'Lock Test', class_level: 9, username: `${tag}.lock`, pin: '2468', subject_ids: [MATHS] });
  created.users.push(victim.body.student.id);
  let last: Reply = { status: 0, body: null };
  for (let i = 0; i < 5; i++) last = await login(`${tag}.lock`, '0000');
  check('the fifth wrong PIN locks the login', last.status === 429 && code(last) === 'locked', last);
  const whileLocked = await login(`${tag}.lock`, '2468');
  check('even the right PIN is refused while it is locked', whileLocked.status === 429, whileLocked);
  const unlocked = await api('POST', `/teacher/students/${victim.body.student.id}/reset-pin`, A.T, { pin: '2468' });
  check('a PIN reset unlocks it', unlocked.status === 200 && (await login(`${tag}.lock`, '2468')).status === 200);

  // Guesses sent all at once are counted one by one: of forty wrong PINs together, four are judged and the other thirty-six turned away.
  const burstVictim = await api('POST', '/teacher/students', A.T, { display_name: 'Burst Test', class_level: 9, username: `${tag}.burst`, pin: '1357', subject_ids: [MATHS] });
  created.users.push(burstVictim.body.student.id);
  const burst = await Promise.all(Array.from({ length: 40 }, (_, i) => login(`${tag}.burst`, String(2000 + i))));
  const judged = burst.filter((r) => r.status === 401).length;
  const turnedAway = burst.filter((r) => r.status === 429 && code(r) === 'locked').length;
  check('forty wrong PINs at once: four are judged, thirty-six turned away', judged === 4 && turnedAway === 36, burst.map((r) => r.status).join(','));
  check('and the login stays locked after the burst', (await login(`${tag}.burst`, '1357')).status === 429);
  const burstPw = await Promise.all(Array.from({ length: 30 }, (_, i) => api('POST', '/teacher/password', A!.T, { current: `wrong-${i}`, next: 'anotherpass1' })));
  check('the same on the password route: four judged, the rest turned away',
    burstPw.filter((r) => r.status === 400).length === 4 && burstPw.filter((r) => r.status === 429).length === 26, burstPw.map((r) => r.status).join(','));
  await db.query('update users set failed_count = 0, locked_until = null where id = $1', [A.tutorId]);
  const rightAgain = await login(`${tag}.a`, 'newpassword1');
  check('a right secret still gets in, and gives the tries back', rightAgain.status === 200, rightAgain.body);
  const afterRight = await db.query('select failed_count, locked_until from users where id = $1', [A.tutorId]);
  check('no tries are held against someone who got it right', afterRight.rows[0].failed_count === 0 && afterRight.rows[0].locked_until === null, afterRight.rows[0]);
  const out = await api('POST', '/auth/logout', A.T);
  check('signing out ends that session', out.status === 200 && (await api('GET', '/auth/me', A.T)).status === 401);

  // ---------------------------------------------------------------- 5. two requests at once
  const two = await login(A.studentName, '5678');
  const S2 = two.body.token as string;
  const T3 = (await login(`${tag}.a`, 'newpassword1')).body.token as string;
  const t2 = await api('POST', '/teacher/tests', T3, {
    title: `${tag} race`, class_level: 9, subject_id: MATHS, question_ids: [A.question], shuffle: false, assign_all: false, assign_group: true, closes_at: iso(86_400_000),
  });
  check('the race test is set up', t2.status === 201, t2.body);
  await api('POST', `/teacher/tests/${t2.body.id}/publish`, T3, { published: true });
  const starts = await Promise.all(Array.from({ length: 8 }, () => api('POST', `/student/tests/${t2.body.id}/start`, S2)));
  const ids = new Set(starts.map((s) => s.body?.attempt?.id));
  check('eight starts at once make one attempt', starts.every((s) => s.status === 200) && ids.size === 1, starts.map((s) => s.status));
  const attempt = [...ids][0] as string;
  const submits = await Promise.all(Array.from({ length: 8 }, () => api('POST', `/student/attempts/${attempt}/submit`, S2, { answers: [{ question_id: A!.question, choice: 1 }] })));
  check('eight submits at once all get an answer', submits.every((s) => s.status === 200), submits.map((s) => s.status));
  const rows = await db.query('select count(*) as n, max(score) as score from attempts where test_id = $1', [t2.body.id]);
  check('and the test holds one attempt, marked once', Number(rows.rows[0].n) === 1 && rows.rows[0].score !== null, rows.rows[0]);
  const racers = await Promise.all([
    api('PUT', `/student/attempts/${attempt}/answers`, S2, { answers: [{ question_id: A.question, choice: 0 }] }),
    api('POST', `/student/attempts/${attempt}/submit`, S2, { answers: [] }),
  ]);
  check('saving and submitting a finished attempt never breaks', racers.every((x) => x.status < 500), racers.map((x) => x.status));

  // The caps hold when the requests arrive together: a count read before any of them was written must not let them all through.
  const signups = await Promise.all(Array.from({ length: 12 }, (_, i) =>
    api('POST', '/auth/signup-tutor', undefined, { display_name: `Burst ${i}`, username: `${tag}.s${i}`, password: 'longenough1' }, { 'x-install-id': `${tag}-burst` })));
  check('twelve sign-ups at once from one phone: three are made, nine turned away',
    signups.filter((r) => r.status === 201).length === 3 && signups.filter((r) => r.status === 429 && code(r) === 'too_many_signups').length === 9, signups.map((r) => r.status).join(','));
  const owner = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Owner Burst', username: `${tag}.own`, password: 'longenough1' }, { 'x-install-id': `${tag}-own` });
  created.users.push(owner.body.user.id);
  const tuitionBurst = await Promise.all(Array.from({ length: 8 }, (_, i) =>
    api('POST', '/auth/tuitions', owner.body.token, { name: `${tag} burst ${i}`, groups: [{ class_level: 9, subject_id: MATHS }] })));
  for (const r of tuitionBurst) if (r.status === 201) created.tuitions.push(r.body.tuition.id);
  check('eight tuitions at once: only the three a tutor may run are made',
    tuitionBurst.filter((r) => r.status === 201).length === 3 && tuitionBurst.filter((r) => r.status === 409 && code(r) === 'too_many_tuitions').length === 5, tuitionBurst.map((r) => r.status).join(','));

  // ---------------------------------------------------------------- 6. a big body nobody reads
  // A large body that no route read could stay in the platform's connection to the function, and the next request on that connection then got no
  // answer for a minute. The server now reads every body away first, and refuses one over a megabyte. A stall would show here as a request with status 0.
  const big = JSON.stringify({ x: 'a'.repeat(300_000) });
  const ignored = `/teacher/join-requests/${UUID0}/decline`;
  const pairs: Reply[] = [];
  for (let i = 0; i < 5; i++) pairs.push(await call('POST', ignored, T3, big), await call('GET', '/auth/me', T3, undefined));
  check('300 KB that the route never reads, then an ordinary request: both answered, five times over', pairs.every((r) => r.status !== 0), pairs.map((r) => r.status).join(','));
  const mixed = await Promise.all(Array.from({ length: 24 }, (_, i) => (i % 2 === 0 ? call('POST', ignored, T3, big) : call('GET', '/auth/me', T3, undefined))));
  check('the same together with ordinary requests: every one answered', mixed.every((r) => r.status !== 0), mixed.map((r) => r.status).join(','));
  const noToken = await call('POST', ignored, undefined, big);
  check('300 KB from nobody is answered with a plain 401, and the next request is too', noToken.status === 401 && (await call('GET', '/auth/me', T3, undefined)).status === 200, noToken.status);
  const huge = await call('POST', ignored, T3, JSON.stringify({ x: 'a'.repeat(1_500_000) }));
  check('a body over a megabyte is refused, not parsed', huge.status === 413 && code(huge) === 'too_big', { status: huge.status, body: huge.body });
  check('and the request after it is answered', (await call('GET', '/auth/me', T3, undefined)).status === 200);
} catch (e) {
  fail++;
  console.log('FAIL  unexpected error:', e);
} finally {
  try {
    const tuitions = created.tuitions;
    await db.query('delete from tests where tuition_id = any($1::uuid[])', [tuitions]);
    await db.query('delete from questions where tuition_id = any($1::uuid[])', [tuitions]);
    await db.query('delete from papers where tuition_id = any($1::uuid[])', [tuitions]);
    await db.query('delete from courses where tuition_id = any($1::uuid[])', [tuitions]);
    await db.query('delete from app_installs where install_id like $1', [`${tag}-%`]);
    // People made through the API in these tuitions (the fuzz may have made some) go with the tuitions' students.
    const members = await db.query(`select user_id from memberships where tuition_id = any($1::uuid[]) and role = 'student'`, [tuitions]);
    await db.query('delete from users where id = any($1::uuid[])', [[...created.users, ...members.rows.map((r) => r.user_id)]]);
    await db.query('delete from users where username like $1', [`${tag}.%`]);
    await db.query('delete from tuitions where id = any($1::uuid[])', [tuitions]);
    await db.query('delete from subjects where id = any($1::uuid[]) or tuition_id = any($2::uuid[])', [created.subjects, tuitions]);
  } catch (e) {
    console.log('cleanup problem:', e);
  }
  await db.end();
  console.log(`\n${pass} passed, ${fail} failed (test data removed)`);
  process.exit(fail ? 1 : 0);
}
