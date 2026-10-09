// Checks that tuitions are walled off from each other, and the sign-up and joining flows.
// Needs the API (the deployed dev branch by default) and the dev logins; makes its own tutors,
// tuitions and students, and removes them again.
// Usage: node tools/tenant-test.ts [--env .env.local] [--base https://...]
import { randomInt } from 'node:crypto';
import { readFileSync } from 'node:fs';
import pg from 'pg';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error(`No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in ${envFile}).`);
const logins = JSON.parse(readFileSync(`tools/out/sample-logins.${process.env.NEON_BRANCH}.json`, 'utf8'));
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
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
      ...headers,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const json: any = await res.json().catch(() => null);
  return { status: res.status, body: json };
}
const login = (username: string, secret: string) => api('POST', '/auth/login', undefined, { username, secret });
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();
const code = (r: { body: any }) => r.body?.error?.code;

const tag = `tenant${randomInt(1000, 9999)}`;
const created = { users: [] as string[], tuitions: [] as string[], subjects: [] as string[], questions: [] as string[], tests: [] as string[], papers: [] as string[] };
let groupsBefore: { class_level: number; subject_id: string }[] = [];
let A = '';

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();

try {
  // ------------------------------------------------------------------ tuition A: the existing one
  const la = await login(logins.teacher.username, logins.teacher.password);
  check('tutor of tuition A logs in', la.status === 200 && Array.isArray(la.body?.tuitions) && la.body.tuitions.length >= 1, la.body);
  const TA = la.body.token as string;
  A = la.body.tuitions[0].id;
  groupsBefore = (await db.query('select class_level, subject_id from groups where tuition_id = $1', [A])).rows;

  const aStudent = await api('POST', '/teacher/students', TA, { display_name: 'Tenant Alpha', class_level: 9, username: `${tag}.alpha`, pin: '1111', subject_ids: [MATHS] });
  check('A adds a student', aStudent.status === 201, aStudent.body);
  const a1 = aStudent.body.student.id as string;
  created.users.push(a1);
  const aq = await api('POST', '/teacher/questions', TA, { class_level: 9, text: `${tag} A question $1+1$?`, options: ['1', '2', '3', '4'], correct_option: 1, subject_id: MATHS });
  created.questions.push(aq.body.id);
  const aTest = await api('POST', '/teacher/tests', TA, {
    title: `${tag} A test`, class_level: 9, subject_id: MATHS, question_ids: [aq.body.id], shuffle: false, assign_all: false, assign_group: true, closes_at: iso(86_400_000),
  });
  check('A makes a test', aTest.status === 201, aTest.body);
  created.tests.push(aTest.body.id);
  await api('POST', `/teacher/tests/${aTest.body.id}/publish`, TA, { published: true });
  const aPaper = await api('POST', '/teacher/papers', TA, { pages: 1, class_level: 9, subject_id: MATHS });
  created.papers.push(aPaper.body.paper.id);
  const aCustom = await api('POST', '/teacher/subjects', TA, { name: `${tag} Custom` });
  check('A adds a subject of its own', aCustom.status === 201, aCustom.body);
  created.subjects.push(aCustom.body.subject.id);

  const sa1 = await login(`${tag}.alpha`, '1111');
  check('A student logs in and is told their tuition', sa1.status === 200 && sa1.body.tuitions?.length === 1 && sa1.body.tuitions[0].id === A, sa1.body);
  const SA1 = sa1.body.token as string;
  const started = await api('POST', `/student/tests/${aTest.body.id}/start`, SA1);
  const attemptA = started.body.attempt.id as string;
  await api('POST', `/student/attempts/${attemptA}/submit`, SA1, { answers: [{ question_id: aq.body.id, choice: 0 }] });

  // ------------------------------------------------------------------ sign-up and creating a tuition
  const inst = { 'x-install-id': `${tag}-b` };
  const weak = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Tutor B', username: `${tag}.b`, password: 'short' }, inst);
  check('a weak password is refused at sign-up', weak.status === 400 && code(weak) === 'weak_password', weak.body);
  const dupName = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Tutor B', username: logins.teacher.username, password: 'longenough1' }, inst);
  check('a taken username is refused at sign-up', dupName.status === 409 && code(dupName) === 'username_taken', dupName.body);
  const su = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Tutor B', username: `${tag}.b`, password: 'longenough1' }, inst);
  check('a tutor signs up', su.status === 201 && !!su.body?.token && su.body.tuitions.length === 0, su.body);
  created.users.push(su.body.user.id);
  const TB = su.body.token as string;
  const noHome = await api('GET', '/teacher/home', TB);
  check('a tutor with no tuition is asked to create one', noHome.status === 409 && code(noHome) === 'no_tuition', noHome.body);
  const std = await api('GET', '/auth/standard-subjects', TB);
  check('a new tutor can read the standard subjects to choose from', std.status === 200 && std.body.subjects.some((s: any) => s.name === 'Physics') && std.body.subjects.some((s: any) => s.id === MATHS), std.body);
  check('a student cannot', (await api('GET', '/auth/standard-subjects', SA1)).status === 403);
  const meNone = await api('GET', '/auth/me', TB);
  check('auth/me works before a tuition exists', meNone.status === 200 && meNone.body.tuitions.length === 0, meNone.body);
  const noName = await api('POST', '/auth/tuitions', TB, { name: '', groups: [] });
  check('a tuition needs a name', noName.status === 400, noName.body);
  const mathsRow = await db.query('select id from subjects where id = $1', [MATHS]);
  check('Maths is a standard subject', mathsRow.rowCount === 1);
  const mk = await api('POST', '/auth/tuitions', TB, {
    name: `${tag} Tuition B`,
    groups: [{ class_level: 9, subject_name: 'Physics' }, { class_level: 10, subject_id: MATHS }, { class_level: 10, subject_name: `${tag} Own` }],
  });
  check('the tutor creates a tuition with groups', mk.status === 201 && mk.body.tuition.role === 'owner' && /^[A-HJ-NP-Z2-9]{6}$/.test(mk.body.tuition.join_code), mk.body);
  const B = mk.body.tuition.id as string;
  const joinCode = mk.body.tuition.join_code as string;
  created.tuitions.push(B);
  const own = await db.query('select id from subjects where tuition_id = $1', [B]);
  created.subjects.push(...own.rows.map((r) => r.id));

  const homeB = await api('GET', '/teacher/home', TB);
  check('B starts with its three groups and no students', homeB.status === 200 && homeB.body.groups.length === 3 && homeB.body.groups.every((g: any) => g.students === 0), homeB.body);
  check('home carries the tuition and its join code', homeB.body.tuition?.id === B && homeB.body.tuition.join_code === joinCode, homeB.body.tuition);
  const subB = await api('GET', '/teacher/subjects', TB);
  const namesB = subB.body.subjects.map((s: any) => s.name).sort();
  check('B teaches only the subjects it chose', JSON.stringify(namesB) === JSON.stringify(['Maths', 'Physics', `${tag} Own`].sort()), namesB);
  const subA = await api('GET', '/teacher/subjects', TA);
  check('A does not see B\'s subjects', !subA.body.subjects.some((s: any) => s.name === 'Physics' || s.name === `${tag} Own`), subA.body.subjects.map((s: any) => s.name));
  const cat = await api('GET', '/teacher/subject-catalogue', TB);
  check('B is offered the standard subjects it does not teach yet', cat.body.subjects.some((s: any) => s.name === 'Chemistry') && !cat.body.subjects.some((s: any) => s.name === 'Physics'), cat.body);

  // ------------------------------------------------------------------ B cannot see or touch A
  const nf = (name: string, r: { status: number }) => check(name, r.status === 404, r);
  check('B lists none of A\'s students', (await api('GET', '/teacher/students', TB)).body.students.length === 0);
  nf('B cannot open A\'s student', await api('GET', `/teacher/students/${a1}`, TB));
  nf('B cannot rename A\'s student', await api('PATCH', `/teacher/students/${a1}`, TB, { display_name: 'Hijack' }));
  nf('B cannot reset A\'s student PIN', await api('POST', `/teacher/students/${a1}/reset-pin`, TB, {}));
  nf('B cannot turn A\'s student off', await api('POST', `/teacher/students/${a1}/active`, TB, { active: false }));
  nf('B cannot delete A\'s student', await api('DELETE', `/teacher/students/${a1}`, TB));
  nf('B cannot open A\'s question', await api('GET', `/teacher/questions/${aq.body.id}`, TB));
  nf('B cannot edit A\'s question', await api('PATCH', `/teacher/questions/${aq.body.id}`, TB, { class_level: 9, text: 'x', options: ['1', '2', '3', '4'], correct_option: 0 }));
  nf('B cannot delete A\'s question', await api('DELETE', `/teacher/questions/${aq.body.id}`, TB));
  check('B lists none of A\'s questions', (await api('GET', '/teacher/questions', TB)).body.questions.length === 0);
  check('B lists none of A\'s tests', (await api('GET', '/teacher/tests', TB)).body.tests.length === 0);
  nf('B cannot open A\'s test', await api('GET', `/teacher/tests/${aTest.body.id}`, TB));
  nf('B cannot see A\'s test results', await api('GET', `/teacher/tests/${aTest.body.id}/results`, TB));
  nf('B cannot unpublish A\'s test', await api('POST', `/teacher/tests/${aTest.body.id}/publish`, TB, { published: false }));
  nf('B cannot delete A\'s test', await api('DELETE', `/teacher/tests/${aTest.body.id}?with_results=1`, TB));
  nf('B cannot grant a retake on A\'s test', await api('POST', `/teacher/tests/${aTest.body.id}/retake`, TB, { student_id: a1 }));
  const rel = await api('POST', `/teacher/tests/${aTest.body.id}/release-results`, TB);
  check('B cannot release A\'s marks', rel.status !== 200, rel);
  nf('B cannot open A\'s attempt', await api('GET', `/teacher/attempts/${attemptA}`, TB));
  check('B lists none of A\'s papers', (await api('GET', '/teacher/papers', TB)).body.papers.length === 0);
  nf('B cannot open A\'s paper', await api('GET', `/teacher/papers/${aPaper.body.paper.id}`, TB));
  nf('B cannot edit A\'s paper', await api('PATCH', `/teacher/papers/${aPaper.body.paper.id}`, TB, { exam_name: 'Hijack' }));
  nf('B cannot delete A\'s paper', await api('DELETE', `/teacher/papers/${aPaper.body.paper.id}`, TB));
  nf('B cannot read A\'s paper with AI', await api('POST', `/teacher/papers/${aPaper.body.paper.id}/detect`, TB));
  nf('B cannot mark A\'s paper page uploaded', await api('POST', `/teacher/papers/${aPaper.body.paper.id}/pages/1/uploaded`, TB));
  nf('B cannot ask AI for answers on A\'s paper', await api('POST', `/teacher/papers/${aPaper.body.paper.id}/answers`, TB));
  nf('B cannot ask AI for a second opinion on A\'s paper', await api('POST', `/teacher/papers/${aPaper.body.paper.id}/second-opinion`, TB));
  nf('B cannot save A\'s paper', await api('POST', `/teacher/papers/${aPaper.body.paper.id}/save`, TB));
  const chatInto = await api('POST', '/teacher/papers/chat', TB, { class_level: 9, subject_id: MATHS, request: 'two questions', count: 2, paper_id: aPaper.body.paper.id });
  check('B cannot add AI questions to A\'s paper by its id', chatInto.status === 404 || chatInto.status === 400, chatInto);
  nf('B cannot rename A\'s custom subject', await api('PATCH', `/teacher/subjects/${aCustom.body.subject.id}`, TB, { name: 'Hijack' }));
  nf('B cannot delete A\'s custom subject', await api('DELETE', `/teacher/subjects/${aCustom.body.subject.id}`, TB));
  const useA = await api('POST', '/teacher/groups', TB, { class_level: 9, subject_id: aCustom.body.subject.id });
  check('B cannot start a group in A\'s custom subject', useA.status === 400 && code(useA) === 'unknown_subject', useA.body);
  const q404 = await api('POST', '/teacher/tests', TB, { title: 'x', class_level: 9, subject_id: MATHS, question_ids: [aq.body.id], assign_all: false, assign_group: true, closes_at: iso(86_400_000) });
  check('B cannot put A\'s question in a test', q404.status === 400 && code(q404) === 'unknown_question', q404.body);
  const tutorsB = await api('GET', '/teacher/tutors', TB);
  check('B lists only its own tutors', tutorsB.body.tutors.length === 1 && tutorsB.body.tutors[0].owner === true, tutorsB.body);
  const settingsB = await api('GET', '/teacher/settings', TB);
  check('settings name B\'s tuition', settingsB.body.tuition_name === `${tag} Tuition B`, settingsB.body);

  const homeA = await api('GET', '/teacher/home', TA);
  check('A\'s home has no group of B\'s', !homeA.body.groups.some((g: any) => g.subject === 'Physics' || g.subject === `${tag} Own`), homeA.body.groups.map((g: any) => g.subject));
  check('A\'s students include no one from B', !(await api('GET', '/teacher/students', TA)).body.students.some((s: any) => s.username?.startsWith(`${tag}.b`)));

  // ------------------------------------------------------------------ B's own work
  const physics = (await api('GET', '/teacher/subjects', TB)).body.subjects.find((s: any) => s.name === 'Physics').id as string;
  const bStudent = await api('POST', '/teacher/students', TB, { display_name: 'Tenant Beta', class_level: 9, username: `${tag}.beta`, pin: '2222', subject_ids: [physics] });
  check('B adds a student', bStudent.status === 201, bStudent.body);
  const b1 = bStudent.body.student.id as string;
  created.users.push(b1);
  const badSubject = await api('POST', '/teacher/students', TB, { display_name: 'No Subject', class_level: 9, username: `${tag}.nos`, pin: '3333', subject_ids: [aCustom.body.subject.id] });
  check('B cannot give a student a subject it does not teach', badSubject.status === 400, badSubject.body);
  const bq = await api('POST', '/teacher/questions', TB, { class_level: 9, text: `${tag} B question`, options: ['a', 'b', 'c', 'd'], correct_option: 2, subject_id: physics });
  check('B makes a question', bq.status === 201, bq.body);
  created.questions.push(bq.body.id);
  const bTest = await api('POST', '/teacher/tests', TB, {
    title: `${tag} B test`, class_level: 9, subject_id: physics, question_ids: [bq.body.id], shuffle: false, assign_all: false, assign_group: true, closes_at: iso(86_400_000),
  });
  check('B makes a test', bTest.status === 201, bTest.body);
  created.tests.push(bTest.body.id);
  await api('POST', `/teacher/tests/${bTest.body.id}/publish`, TB, { published: true });
  const groupB = await api('GET', `/teacher/groups/9/${physics}`, TB);
  check('B\'s group page shows its student and test', groupB.body.students.length === 1 && groupB.body.tests.length === 1, groupB.body);
  check('A cannot open B\'s group page', (await api('GET', `/teacher/groups/9/${physics}`, TA)).status === 404);

  const sb1 = await login(`${tag}.beta`, '2222');
  const SB1 = sb1.body.token as string;
  const homeSB = await api('GET', '/student/home', SB1);
  check('B\'s student sees only B\'s test', homeSB.body.tests.length === 1 && homeSB.body.tests[0].id === bTest.body.id, homeSB.body);
  check('the student home names the tuition', homeSB.body.tuition?.id === B, homeSB.body.tuition);
  const crossStart = await api('POST', `/student/tests/${aTest.body.id}/start`, SB1);
  check('B\'s student cannot start A\'s test', crossStart.status === 404, crossStart);
  const homeSA = await api('GET', '/student/home', SA1);
  check('A\'s student sees only A\'s test', homeSA.body.tests.some((x: any) => x.id === aTest.body.id) && !homeSA.body.tests.some((x: any) => x.id === bTest.body.id), homeSA.body.tests);
  check('a student cannot read another student\'s result', (await api('GET', `/student/attempts/${attemptA}/result`, SB1)).status === 404);

  // ------------------------------------------------------------------ joining a second tuition
  const mine0 = await api('GET', '/student/tuitions', SA1);
  check('a student lists their tuitions', mine0.body.tuitions.length === 1 && mine0.body.tuitions[0].id === A, mine0.body);
  const bad1 = await api('POST', '/student/join', SA1, { code: 'nope' });
  check('a code of the wrong shape is refused', bad1.status === 400 && code(bad1) === 'invalid_code', bad1.body);
  const bad2 = await api('POST', '/student/join', SA1, { code: 'ZZZZZZ' });
  check('a code nobody has is refused', bad2.status === 404 && code(bad2) === 'unknown_code', bad2.body);
  const shown = `${joinCode.slice(0, 3)}-${joinCode.slice(3)}`.toLowerCase();
  const j1 = await api('POST', '/student/join', SA1, { code: shown });
  check('the student asks to join B with its code (any case, with a dash)', j1.status === 201 && j1.body.status === 'pending' && j1.body.tuition.id === B, j1.body);
  const j2 = await api('POST', '/student/join', SA1, { code: joinCode });
  check('asking again changes nothing', j2.status === 200 && j2.body.status === 'pending', j2.body);
  const own2 = await api('POST', '/student/join', SA1, { code: (await db.query('select join_code from tuitions where id = $1', [A])).rows[0].join_code });
  check('a student cannot join the tuition they are in', own2.status === 409 && code(own2) === 'already_member', own2.body);
  const pending = await api('GET', '/teacher/join-requests', TB);
  check('B sees the request', pending.body.requests.length === 1 && pending.body.requests[0].id === a1, pending.body);
  check('B\'s home counts it', (await api('GET', '/teacher/home', TB)).body.pending_requests === 1);
  nf('A sees none of B\'s requests', await api('POST', `/teacher/join-requests/${a1}/accept`, TA, {}));
  const early = await api('GET', '/student/home', SA1, undefined, { 'x-tuition': B });
  check('a waiting student cannot open B yet', early.status === 403 && code(early) === 'not_a_member', early.body);
  const mine1 = await api('GET', '/student/tuitions', SA1);
  check('the student sees B as pending', mine1.body.tuitions.find((x: any) => x.id === B)?.status === 'pending', mine1.body);
  const wrongSubj = await api('POST', `/teacher/join-requests/${a1}/accept`, TB, { class_level: 9, subject_ids: [MATHS.replace(/1$/, '9')] });
  check('accepting with a subject B does not teach is refused', wrongSubj.status === 400, wrongSubj.body);
  const acc = await api('POST', `/teacher/join-requests/${a1}/accept`, TB, { class_level: 9, subject_ids: [physics] });
  check('B lets the student in', acc.status === 200, acc.body);
  check('the request is gone', (await api('GET', '/teacher/join-requests', TB)).body.requests.length === 0);
  const mine2 = await api('GET', '/student/tuitions', SA1);
  check('the student now has two tuitions', mine2.body.tuitions.length === 2 && mine2.body.tuitions.every((x: any) => x.status === 'active'), mine2.body);

  const inB = await api('GET', '/student/home', SA1, undefined, { 'x-tuition': B });
  check('with B chosen the student sees B\'s test only', inB.status === 200 && inB.body.tests.length === 1 && inB.body.tests[0].id === bTest.body.id, inB.body);
  const inA = await api('GET', '/student/home', SA1, undefined, { 'x-tuition': A });
  check('with A chosen the student sees A\'s test only', inA.body.tests.some((x: any) => x.id === aTest.body.id) && !inA.body.tests.some((x: any) => x.id === bTest.body.id), inA.body.tests);
  const noHeader = await api('GET', '/student/home', SA1);
  check('with nothing chosen the first tuition answers, as before', noHeader.body.tuition?.id === A, noHeader.body.tuition);
  const crossB = await api('POST', `/student/tests/${aTest.body.id}/start`, SA1, undefined, { 'x-tuition': B });
  check('a test of A cannot be started in B\'s context', crossB.status === 404, crossB);
  const stB = await api('POST', `/student/tests/${bTest.body.id}/start`, SA1, undefined, { 'x-tuition': B });
  check('the student starts B\'s test', stB.status === 200, stB.body);
  const submitB = await api('POST', `/student/attempts/${stB.body.attempt.id}/submit`, SA1, { answers: [{ question_id: bq.body.id, choice: 2 }] });
  check('and submits it', submitB.status === 200, submitB.body);
  const resB = await api('GET', '/student/results', SA1, undefined, { 'x-tuition': B });
  const resA = await api('GET', '/student/results', SA1, undefined, { 'x-tuition': A });
  check('results are per tuition', resB.body.results.length === 1 && resA.body.results.length === 1 && resB.body.results[0].test_id !== resA.body.results[0].test_id, [resA.body, resB.body]);

  const seenByB = await api('GET', `/teacher/students/${a1}`, TB);
  check('B sees the student with only B\'s results', seenByB.status === 200 && seenByB.body.attempts.length === 1 && seenByB.body.attempts[0].test_id === bTest.body.id, seenByB.body);
  const seenByA = await api('GET', `/teacher/students/${a1}`, TA);
  check('A sees the student with only A\'s results', seenByA.status === 200 && seenByA.body.attempts.every((x: any) => x.test_id !== bTest.body.id) && seenByA.body.attempts.length === 1, seenByA.body.attempts);
  const resultsB = await api('GET', `/teacher/tests/${bTest.body.id}/results`, TB);
  check('B\'s results list the student', resultsB.body.students.some((s: any) => s.id === a1 && s.status === 'submitted'), resultsB.body.students);
  const ren = await api('PATCH', `/teacher/students/${a1}`, TB, { display_name: 'Renamed By B' });
  check('B cannot rename a student who also learns elsewhere', ren.status === 409 && code(ren) === 'shared_student', ren.body);
  const reclass = await api('PATCH', `/teacher/students/${a1}`, TB, { class_level: 10 });
  check('B can move the student to another class in B', reclass.status === 200 && reclass.body.student.class_level === 10, reclass.body);
  const stillA = (await api('GET', `/teacher/students/${a1}`, TA)).body.student;
  check('A\'s view of the class is unchanged', stillA.class_level === 9, stillA);
  const stillHomeA = await api('GET', '/student/home', SA1, undefined, { 'x-tuition': A });
  check('the student still sees A\'s test as a Class 9 student', stillHomeA.body.tests.some((x: any) => x.id === aTest.body.id), stillHomeA.body.tests);

  // ------------------------------------------------------------------ B resets the PIN, then removes the student
  const reset = await api('POST', `/teacher/students/${a1}/reset-pin`, TB, { pin: '9999' });
  check('B resets the shared student\'s PIN', reset.status === 200 && reset.body.login.pin === '9999', reset.body);
  check('the old session is signed out', (await api('GET', '/student/home', SA1)).status === 401);
  const relog = await login(`${tag}.alpha`, '9999');
  check('the new PIN works', relog.status === 200 && relog.body.tuitions.length === 2, relog.body);
  const SA1b = relog.body.token as string;

  const off = await api('POST', `/teacher/students/${a1}/active`, TA, { active: false });
  check('A turns the student off in A', off.status === 200, off.body);
  const afterOff = await api('GET', '/student/tuitions', SA1b);
  check('the student keeps B and loses A', afterOff.body.tuitions.length === 1 && afterOff.body.tuitions[0].id === B, afterOff.body);
  const stillLogs = await login(`${tag}.alpha`, '9999');
  check('the login still works, because B is still a place', stillLogs.status === 200, stillLogs.body);
  const defaultNow = await api('GET', '/student/home', SA1b);
  check('with A off, the default tuition is B', defaultNow.body.tuition?.id === B, defaultNow.body.tuition);
  const asA = await api('GET', '/student/home', SA1b, undefined, { 'x-tuition': A });
  check('and A cannot be opened', asA.status === 403, asA);
  await api('POST', `/teacher/students/${a1}/active`, TA, { active: true });
  check('A turns the student back on', (await api('GET', '/student/tuitions', SA1b)).body.tuitions.length === 2);

  const rm = await api('DELETE', `/teacher/students/${a1}`, TB);
  check('B removes the student from B', rm.status === 200, rm.body);
  const remaining = await api('GET', '/student/tuitions', SA1b);
  check('the student keeps their login and A', remaining.body.tuitions.length === 1 && remaining.body.tuitions[0].id === A, remaining.body);
  const keptAttempts = await api('GET', `/teacher/students/${a1}`, TA);
  check('A still has the student with their results', keptAttempts.status === 200 && keptAttempts.body.attempts.length === 1, keptAttempts.body);
  check('B\'s results of the student went with them', (await db.query('select 1 from attempts where test_id = $1', [bTest.body.id])).rowCount === 0);

  // ------------------------------------------------------------------ the owner, and a second tutor
  const addT = await api('POST', '/teacher/tutors', TB, { display_name: 'Second Tutor', username: `${tag}.tutor2`, password: 'longenough2' });
  check('the owner adds a tutor', addT.status === 201, addT.body);
  created.users.push(addT.body.tutor.id);
  const t2 = await login(`${tag}.tutor2`, 'longenough2');
  const T2 = t2.body.token as string;
  check('the tutor lands in B', t2.body.tuitions.length === 1 && t2.body.tuitions[0].id === B && t2.body.tuitions[0].role === 'tutor', t2.body);
  // B started with three groups; moving a student to Class 10 Physics made a fourth.
  check('the tutor sees B\'s groups', (await api('GET', '/teacher/home', T2)).body.groups.length === 4);
  const reg = await api('POST', '/teacher/tuition/join-code', T2);
  check('only the owner changes the join code', reg.status === 403 && code(reg) === 'owner_only', reg.body);
  nf('A cannot turn B\'s tutor off', await api('POST', `/teacher/tutors/${addT.body.tutor.id}/active`, TA, { active: false }));
  const turnOff = await api('POST', `/teacher/tutors/${addT.body.tutor.id}/active`, TB, { active: false });
  check('B turns the tutor off', turnOff.status === 200, turnOff.body);
  check('their login stops, as it was their only tuition', (await api('GET', '/teacher/home', T2)).status === 401);
  check('a closed tuition login is refused', (await login(`${tag}.tutor2`, 'longenough2')).status === 403);

  const regen = await api('POST', '/teacher/tuition/join-code', TB);
  check('the owner makes a new join code', regen.status === 200 && regen.body.tuition.join_code !== joinCode, regen.body);
  const oldCode = await api('POST', '/student/join', SB1, { code: joinCode });
  check('the old code no longer works', oldCode.status === 404, oldCode.body);
  const closed = await api('PATCH', '/teacher/tuition', TB, { join_open: false });
  check('the owner closes joining', closed.status === 200 && closed.body.tuition.join_open === false, closed.body);
  const closedJoin = await api('POST', '/student/join', SA1b, { code: regen.body.tuition.join_code });
  check('nobody can ask to join a closed tuition', closedJoin.status === 403 && code(closedJoin) === 'not_joinable', closedJoin.body);

  // ------------------------------------------------------------------ guessing codes
  let last: any = null;
  for (let i = 0; i < 9; i++) last = await api('POST', '/student/join', SB1, { code: `ZZZZZ${'ABCDEFGHJ'[i]}` });
  check('wrong codes are limited', last.status === 429 && code(last) === 'too_many_tries', last);

  // ------------------------------------------------------------------ sign-up limits per phone
  let blocked: any = null;
  for (let i = 0; i < 3; i++) {
    const r = await api('POST', '/auth/signup-tutor', undefined, { display_name: `Extra ${i}`, username: `${tag}.x${i}`, password: 'longenough3' }, inst);
    if (r.status === 201) created.users.push(r.body.user.id);
    blocked = r;
  }
  check('one phone cannot sign up endless tutors', blocked.status === 429 && code(blocked) === 'too_many_signups', blocked);

  // ------------------------------------------------------------------ a second tuition for the same tutor
  const mk2 = await api('POST', '/auth/tuitions', TB, { name: `${tag} Second`, groups: [{ class_level: 8, subject_name: 'English' }] });
  check('a tutor can run a second tuition', mk2.status === 201, mk2.body);
  created.tuitions.push(mk2.body.tuition.id);
  const defaultB = await api('GET', '/teacher/home', TB);
  check('the first tuition answers by default', defaultB.body.tuition.id === B, defaultB.body.tuition);
  const second = await api('GET', '/teacher/home', TB, undefined, { 'x-tuition': mk2.body.tuition.id });
  check('x-tuition picks the second', second.body.tuition.id === mk2.body.tuition.id && second.body.groups.length === 1, second.body);
  const strangerHeader = await api('GET', '/teacher/home', TB, undefined, { 'x-tuition': A });
  check('a tutor cannot name a tuition they are not in', strangerHeader.status === 403 && code(strangerHeader) === 'not_a_member', strangerHeader.body);
  const badHeader = await api('GET', '/teacher/home', TB, undefined, { 'x-tuition': 'not-a-uuid' });
  check('a malformed tuition id is refused', badHeader.status === 400, badHeader);
  const sc = await db.query('select id from subjects where tuition_id = $1', [mk2.body.tuition.id]);
  created.subjects.push(...sc.rows.map((r) => r.id));

  // ------------------------------------------------------------------ AI cost is told per tuition
  const usage = await db.query('select count(*) as n from ai_usage where tuition_id is null and created_at > now() - interval \'1 hour\' and user_id = any($1::uuid[])', [created.users]);
  check('AI calls made here carry a tuition', Number(usage.rows[0].n) === 0, usage.rows[0]);

  await api('POST', '/auth/logout', TA);
} catch (e) {
  fail++;
  console.log('FAIL  unexpected error:', e);
} finally {
  // Tests before the questions they use, then people, then the tuitions (which carry their groups and memberships).
  await db.query('delete from tests where id = any($1::uuid[])', [created.tests]);
  await db.query('delete from questions where id = any($1::uuid[]) or paper_id = any($2::uuid[])', [created.questions, created.papers]);
  await db.query('delete from papers where id = any($1::uuid[])', [created.papers]);
  await db.query('delete from app_installs where install_id like $1', [`${tag}-%`]);
  await db.query('delete from users where id = any($1::uuid[])', [created.users]);
  await db.query('delete from tuitions where id = any($1::uuid[])', [created.tuitions]);
  await db.query('delete from subjects where id = any($1::uuid[])', [created.subjects]);
  if (A) {
    // Groups this run made in A go too.
    const keep = groupsBefore.map((g) => `${g.class_level}:${g.subject_id}`);
    const now = (await db.query('select id, class_level, subject_id from groups where tuition_id = $1', [A])).rows;
    const extra = now.filter((g) => !keep.includes(`${g.class_level}:${g.subject_id}`)).map((g) => g.id);
    if (extra.length) await db.query('delete from groups where id = any($1::uuid[])', [extra]);
  }
  await db.end();
  console.log(`\n${pass} passed, ${fail} failed (test data removed)`);
  process.exit(fail ? 1 : 0);
}
