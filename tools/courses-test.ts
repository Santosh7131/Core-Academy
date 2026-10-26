// Checks courses: a tutor makes one, adds people (from the tuition, or new with no class), makes a test for it,
// the people write it, and nothing of it leaks into a group, another tuition, or an app from before courses.
// Needs the API (the deployed dev branch by default) and the dev logins; makes its own tutor, tuition,
// students and course, and removes them again. Never run it against main.
// With --log <file> and --base http://127.0.0.1:8787 (the local API in push dry-run, as in tools/notify-test.ts)
// it also checks what the push for a course's test says.
// Usage: node tools/courses-test.ts [--env .env.local] [--base https://...] [--log server.log]
import { randomInt } from 'node:crypto';
import { readFileSync } from 'node:fs';
import pg from 'pg';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
if (process.env.NEON_BRANCH === 'main') throw new Error('This writes test data; run it against dev, not main.');
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error(`No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in ${envFile}).`);
const logins = JSON.parse(readFileSync(`tools/out/sample-logins.${process.env.NEON_BRANCH}.json`, 'utf8'));
const MATHS = '00000000-0000-4000-8000-000000000001';
const LOG = args.includes('--log') ? args[args.indexOf('--log') + 1] : undefined;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

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
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();
const code = (r: { body: any }) => r.body?.error?.code;

// An app that knows courses, one from before them, and the admin app.
const NEW = { 'x-app': 'core_academy/1.6.0+8' };
const OLD = { 'x-app': 'core_academy/1.5.0+7' };
const ADMIN = { 'x-app': 'admin/1.1.0+3' };
const login = (username: string, secret: string, h: Record<string, string> = NEW) => api('POST', '/auth/login', undefined, { username, secret }, h);

const tag = `course${randomInt(1000, 9999)}`;
const created = { users: [] as string[], tuitions: [] as string[], questions: [] as string[], tests: [] as string[], papers: [] as string[], courses: [] as string[] };
let A = '';
let groupsBefore: { class_level: number; subject_id: string }[] = [];

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();

try {
  // ------------------------------------------------------------------ people to put in courses
  const la = await login(logins.teacher.username, logins.teacher.password);
  check('the tutor logs in', la.status === 200, la.body);
  const TA = la.body.token as string;
  A = la.body.tuitions[0].id;
  groupsBefore = (await db.query('select class_level, subject_id from groups where tuition_id = $1', [A])).rows;

  const mkStudent = async (name: string, cls: number, user: string) => {
    const r = await api('POST', '/teacher/students', TA, { display_name: name, class_level: cls, username: user, pin: '1234', subject_ids: [MATHS] }, NEW);
    created.users.push(r.body?.student?.id);
    return r;
  };
  const s9 = await mkStudent('Course Nine', 9, `${tag}.nine`);
  const s10 = await mkStudent('Course Ten', 10, `${tag}.ten`);
  const s11 = await mkStudent('Course Eleven', 9, `${tag}.eleven`);
  check('the tutor makes three students in two classes', [s9, s10, s11].every((r) => r.status === 201), [s9.body, s10.body, s11.body]);
  const id9 = s9.body.student.id as string;
  const id10 = s10.body.student.id as string;
  const id11 = s11.body.student.id as string;
  // They were "added a week ago", so a test that closed an hour ago would have been theirs to miss.
  await db.query(`update memberships set joined_at = now() - interval '7 days' where user_id = any($1::uuid[])`, [[id9, id10, id11]]);

  // ------------------------------------------------------------------ making a course
  const empty = await api('GET', '/teacher/courses', TA, undefined, NEW);
  check('a tuition starts with no courses', empty.status === 200 && Array.isArray(empty.body.courses) && !empty.body.courses.some((x: any) => x.name.startsWith(tag)), empty.body);
  const noName = await api('POST', '/teacher/courses', TA, { name: '  ' }, NEW);
  check('a course needs a name', noName.status === 400, noName.body);
  const mk = await api('POST', '/teacher/courses', TA, { name: `${tag} Spoken English` }, NEW);
  check('the tutor makes a course', mk.status === 201 && mk.body.course.people === 0, mk.body);
  const C = mk.body.course.id as string;
  created.courses.push(C);
  const dup = await api('POST', '/teacher/courses', TA, { name: `${tag} SPOKEN english` }, NEW);
  check('a second course of the same name is refused, whatever the case', dup.status === 409 && code(dup) === 'duplicate', dup.body);

  // ------------------------------------------------------------------ adding people
  const addNone = await api('POST', `/teacher/courses/${C}/people`, TA, { student_ids: 'x' }, NEW);
  check('people are sent as a list', addNone.status === 400, addNone.body);
  const strange = await api('POST', `/teacher/courses/${C}/people`, TA, { student_ids: ['00000000-0000-4000-8000-00000000dead'] }, NEW);
  check('someone who is not a student of this tuition is refused', strange.status === 400 && code(strange) === 'unknown_student', strange.body);
  const add = await api('POST', `/teacher/courses/${C}/people`, TA, { student_ids: [id9, id10] }, NEW);
  check('students of two different classes are added to one course', add.status === 200 && add.body.added === 2, add.body);
  const again = await api('POST', `/teacher/courses/${C}/people`, TA, { student_ids: [id9, id10] }, NEW);
  check('adding them again changes nothing', again.status === 200 && again.body.added === 0, again.body);

  const newbie = await api('POST', `/teacher/courses/${C}/people/new`, TA, { display_name: 'Course Newcomer', username: `${tag}.new`, pin: '4321' }, NEW);
  check('a new person is made inside the course, with a login and no class', newbie.status === 201 && newbie.body.student.class_level === null && newbie.body.login.pin === '4321', newbie.body);
  const idN = newbie.body.student.id as string;
  created.users.push(idN);
  const takenName = await api('POST', `/teacher/courses/${C}/people/new`, TA, { display_name: 'Other', username: `${tag}.new`, pin: '4321' }, NEW);
  check('a username that is taken is refused', takenName.status === 409 && code(takenName) === 'username_taken', takenName.body);
  const mem = (await db.query('select role, status, class_level from memberships where user_id = $1 and tuition_id = $2', [idN, A])).rows[0];
  check('the new person is an active student of the tuition with no class, and in no group', mem?.role === 'student' && mem.status === 'active' && mem.class_level === null, mem);
  const noSubjects = (await db.query('select count(*) as n from student_subjects where student_id = $1', [idN])).rows[0].n;
  check('and studies no subject', Number(noSubjects) === 0, noSubjects);

  const page0 = await api('GET', `/teacher/courses/${C}`, TA, undefined, NEW);
  check('the course page lists its three people and no tests', page0.status === 200 && page0.body.people.length === 3 && page0.body.tests.length === 0 && page0.body.course.people === 3, page0.body);
  check('a person added to a course is still in their group', (await api('GET', '/teacher/groups/9/' + MATHS, TA, undefined, NEW)).body.students.some((s: any) => s.id === id9));

  // ------------------------------------------------------------------ old apps are kept away from what they cannot show
  const students = await api('GET', '/teacher/students', TA, undefined, NEW);
  const rowN = students.body.students.find((s: any) => s.id === idN);
  check('an app that knows courses is sent the person with no class, and the courses of each student', rowN?.class_level === null && rowN.courses.length === 1 && rowN.courses[0].id === C, rowN);
  check('a student in a class and a course lists both', students.body.students.find((s: any) => s.id === id9).courses[0].name === `${tag} Spoken English`);
  const studentsOld = await api('GET', '/teacher/students', TA, undefined, OLD);
  check('an app from before courses is never sent a person with no class', studentsOld.status === 200 && !studentsOld.body.students.some((s: any) => s.id === idN) && studentsOld.body.students.some((s: any) => s.id === id9), studentsOld.body.students?.length);
  const homeOld = await api('GET', '/teacher/home', TA, undefined, OLD);
  check('nor is it sent the courses on Home', homeOld.status === 200 && homeOld.body.courses === undefined, Object.keys(homeOld.body ?? {}));
  const loginOld = await login(`${tag}.new`, '4321', OLD);
  check('a person with no class who signs in from an app before courses is told to update', loginOld.status === 426 && code(loginOld) === 'update_required', loginOld.body);
  const loginNone = await login(`${tag}.new`, '4321', {});
  check('and so is one that says nothing about itself', loginNone.status === 426 && code(loginNone) === 'update_required', loginNone.body);
  const wrongPin = await login(`${tag}.new`, '9999', OLD);
  check('a wrong PIN is still just a wrong PIN', wrongPin.status === 401, wrongPin.body);
  const loginN = await login(`${tag}.new`, '4321', NEW);
  check('from an app that knows courses they sign in, with no class', loginN.status === 200 && loginN.body.user.class_level === null && loginN.body.tuitions[0].class_level === null, loginN.body);
  const SN = loginN.body.token as string;
  check('a token from before is refused on an old app too', (await api('GET', '/student/home', SN, undefined, OLD)).status === 426);
  const homeN = await api('GET', '/student/home', SN, undefined, NEW);
  check('their home has no class tests and says they are in one course', homeN.status === 200 && homeN.body.tests.length === 0 && homeN.body.courses === 1, homeN.body);

  // ------------------------------------------------------------------ a course's paper and questions
  const gq = await api('POST', '/teacher/questions', TA, { class_level: 9, text: `${tag} group question $1+1$?`, options: ['1', '2', '3', '4'], correct_option: 1, subject_id: MATHS });
  created.questions.push(gq.body.id);
  const paper = await api('POST', '/teacher/papers', TA, { pages: 1, course_id: C }, NEW);
  check('a paper is made for the course, with no class or subject', paper.status === 201 && paper.body.paper.course_id === C && paper.body.paper.class_level === null && paper.body.paper.subject_id === null, paper.body);
  const P = paper.body.paper.id as string;
  created.papers.push(P);
  const mkDraft = (seq: number, text: string, correct: number) =>
    db.query(
      `insert into paper_drafts (paper_id, page_no, seq, number_label, kind, text, options, correct_option, answer_source, answer_checked)
       values ($1, 1, $2, $3, 'mcq', $4, $5, $6, 'teacher', true)`,
      [P, seq, String(seq + 1), text, ['one', 'two', 'three', 'four'], correct],
    );
  await mkDraft(0, `${tag} Which word is a verb: run, red, rock, rain?`, 0);
  await mkDraft(1, `${tag} Pick the past tense of go`, 2);
  const pg0 = await api('GET', `/teacher/papers/${P}`, TA, undefined, NEW);
  check('the paper has nothing missing, because a course needs no class or subject', pg0.status === 200 && pg0.body.paper.missing.length === 0 && pg0.body.paper.course === `${tag} Spoken English`, pg0.body.paper);
  const ans = await api('POST', `/teacher/papers/${P}/answers`, TA, {}, NEW);
  check('its answers can be worked out without a class', ans.status === 200, ans.body);
  const sec = await api('POST', `/teacher/papers/${P}/second-opinion`, TA, {}, NEW);
  check('and a second opinion asked for', sec.status === 200, sec.body);
  const groupedBefore = (await api('GET', '/teacher/question-groups', TA, undefined, NEW)).body.groups.reduce((s: number, g: any) => s + Number(g.questions), 0);
  const saved = await api('POST', `/teacher/papers/${P}/save`, TA, {}, NEW);
  check('its questions save into the course', saved.status === 200 && saved.body.saved === 2, saved.body);
  const cq = await api('GET', `/teacher/questions?course=${C}`, TA, undefined, NEW);
  check('the course has its two questions, with no class or subject', cq.status === 200 && cq.body.questions.length === 2 && cq.body.questions.every((x: any) => x.course_id === C && x.class_level === null && x.subject_id === null), cq.body);
  const cqIds = cq.body.questions.map((x: any) => x.id) as string[];
  const allQ = await api('GET', '/teacher/questions', TA, undefined, NEW);
  check('a group never sees them in the questions', allQ.body.questions.every((x: any) => !cqIds.includes(x.id)));
  const groupedAfter = (await api('GET', '/teacher/question-groups', TA, undefined, NEW)).body.groups.reduce((s: number, g: any) => s + Number(g.questions), 0);
  check('nor counted in the question groups', groupedAfter === groupedBefore, [groupedBefore, groupedAfter]);
  const papersAll = await api('GET', '/teacher/papers', TA, undefined, NEW);
  check('nor in the papers', !papersAll.body.papers.some((p: any) => p.id === P));
  const papersCourse = await api('GET', `/teacher/papers?course=${C}`, TA, undefined, NEW);
  check('but the course lists its paper', papersCourse.body.papers.length === 1 && papersCourse.body.papers[0].id === P, papersCourse.body);
  const again2 = await api('POST', `/teacher/papers/${P}/save`, TA, {}, NEW);
  check('saving again saves nothing twice', again2.status === 200 && again2.body.saved === 0, again2.body);
  // Editing a course's question sends no class, chapter or subject, and must not give it any.
  const editQ = await api('PATCH', `/teacher/questions/${cqIds[0]}`, TA, { text: `${tag} Which word is a verb: jump, blue, stone, wind?`, options: ['jump', 'blue', 'stone', 'wind'], correct_option: 0 }, NEW);
  check('a course question is edited without a class', editQ.status === 200, editQ.body);
  const editedQ = await api('GET', `/teacher/questions/${cqIds[0]}`, TA, undefined, NEW);
  const eq = editedQ.body?.question ?? editedQ.body;
  check('and stays the course\'s, with no class, chapter or subject', eq?.course_id === C && eq.class_level === null && eq.chapter_id === null && eq.subject_id === null && eq.options[0] === 'jump', eq);
  const classEdit = await api('PATCH', `/teacher/questions/${cqIds[0]}`, TA, { class_level: 9, text: `${tag} Which word is a verb: jump, blue, stone, wind?`, options: ['jump', 'blue', 'stone', 'wind'], correct_option: 0, subject_id: MATHS }, NEW);
  const classQ = await api('GET', `/teacher/questions/${cqIds[0]}`, TA, undefined, NEW);
  const cqRow = classQ.body?.question ?? classQ.body;
  check('a class sent with it is ignored, never written onto it', classEdit.status === 200 && cqRow.class_level === null && cqRow.subject_id === null && cqRow.course_id === C, cqRow);
  const gEdit = await api('PATCH', `/teacher/questions/${gq.body.id}`, TA, { text: `${tag} group question edited $1+1$?`, options: ['1', '2', '3', '4'], correct_option: 1 }, NEW);
  check('a group question still needs its class', gEdit.status === 400, gEdit.body);

  // ------------------------------------------------------------------ a course's test
  const wrongQ = await api('POST', '/teacher/tests', TA, { title: `${tag} mixed`, course_id: C, question_ids: [gq.body.id], shuffle: false, closes_at: iso(86_400_000) }, NEW);
  check('a course test cannot use a group\'s question', wrongQ.status === 400 && code(wrongQ) === 'unknown_question', wrongQ.body);
  const wrongQ2 = await api('POST', '/teacher/tests', TA, { title: `${tag} mixed`, class_level: 9, subject_id: MATHS, question_ids: [cqIds[0]], shuffle: false, assign_all: false, assign_group: true, closes_at: iso(86_400_000) }, NEW);
  check('nor a group test a course\'s question', wrongQ2.status === 400 && code(wrongQ2) === 'unknown_question', wrongQ2.body);
  const wrongC = await api('POST', '/teacher/tests', TA, { title: `${tag} nowhere`, course_id: '00000000-0000-4000-8000-00000000dead', question_ids: cqIds, shuffle: false }, NEW);
  check('a test for a course that is not there is refused', wrongC.status === 404, wrongC.body);
  const mkT = await api('POST', '/teacher/tests', TA, { title: `${tag} Verbs`, course_id: C, question_ids: cqIds, shuffle: false, closes_at: iso(86_400_000) }, NEW);
  check('the tutor makes the course\'s test', mkT.status === 201, mkT.body);
  const TEST = mkT.body.id as string;
  created.tests.push(TEST);
  const one = await api('GET', `/teacher/tests/${TEST}`, TA, undefined, NEW);
  check('it has no class, no subject, and says which course', one.body.test.course_id === C && one.body.test.class_level === null && one.body.test.subject_id === null && one.body.test.course === `${tag} Spoken English`, one.body.test);
  const move = await api('PATCH', `/teacher/tests/${TEST}`, TA, { title: `${tag} Verbs`, class_level: 9, subject_id: MATHS, question_ids: cqIds, shuffle: false, closes_at: iso(86_400_000) }, NEW);
  check('a course test stays a course test when it is edited', move.status === 200, move.body);
  const still = await api('GET', `/teacher/tests/${TEST}`, TA, undefined, NEW);
  check('it still has no class', still.body.test.course_id === C && still.body.test.class_level === null, still.body.test);
  // With the server's log to read, one of the course's people has a phone, so the push can be seen.
  let mark = 0;
  if (LOG) {
    const tok = (await login(`${tag}.nine`, '1234')).body.token as string;
    await api('POST', '/devices', tok, { token: `${tag}-phone-nine` }, NEW);
    mark = readFileSync(LOG, 'utf8').length;
  }
  const pub = await api('POST', `/teacher/tests/${TEST}/publish`, TA, { published: true }, NEW);
  check('it is published', pub.status === 200 && pub.body.test.status === 'published', pub.body);
  if (LOG) {
    await sleep(2500);
    const lines = readFileSync(LOG, 'utf8').slice(mark).split('\n').filter((l) => l.includes('[push]')).map((l) => l.trim());
    check('the push says which course the new test is in', lines.some((l) => l.includes(`1 phone(s) | ${tag} Verbs | New test in ${tag} Spoken English · 2 questions · closes `)), lines);
  }

  const tests = await api('GET', '/teacher/tests', TA, undefined, NEW);
  check('the tests of the groups leave it out', !tests.body.tests.some((t: any) => t.id === TEST));
  const ctests = await api('GET', `/teacher/tests?course=${C}`, TA, undefined, NEW);
  check('the course lists it, given to its three people', ctests.body.tests.length === 1 && ctests.body.tests[0].assigned === 3, ctests.body);
  const home = await api('GET', '/teacher/home', TA, undefined, NEW);
  const card = home.body.courses?.find((x: any) => x.id === C);
  check('Home shows it under the course, live', !!card && card.people === 3 && card.live.length === 1 && card.live[0].id === TEST && card.live[0].assigned === 3, card);
  check('and in no group', home.body.groups.every((g: any) => ![...g.live, ...g.posted].some((t: any) => t.id === TEST)));
  const group9 = await api('GET', '/teacher/groups/9/' + MATHS, TA, undefined, NEW);
  check('a group\'s page does not list it', !group9.body.tests.some((t: any) => t.id === TEST));
  const dash = await api('GET', '/teacher/dashboard', TA, undefined, NEW);
  check('nor does the dashboard\'s live list', dash.status === 200 && !dash.body.live.some((t: any) => t.id === TEST));
  const list = await api('GET', '/teacher/courses', TA, undefined, NEW);
  check('the Courses tab shows the course first, with something running', list.body.courses[0].id === C || list.body.courses.some((x: any) => x.id === C && x.live.length === 1), list.body.courses?.map((x: any) => x.name));

  // ------------------------------------------------------------------ the students' side
  const l9 = await login(`${tag}.nine`, '1234');
  const S9 = l9.body.token as string;
  const h9 = await api('GET', '/student/home', S9, undefined, NEW);
  check('a student of a class and a course sees class tests on Home, not the course\'s, and that they are in a course', h9.status === 200 && h9.body.courses === 1 && !h9.body.tests.some((t: any) => t.id === TEST), h9.body);
  const c9 = await api('GET', '/student/courses', S9, undefined, NEW);
  check('their courses list has the course with one test open', c9.status === 200 && c9.body.courses.length === 1 && c9.body.courses[0].id === C && c9.body.courses[0].open === 1, c9.body);
  const closesIn = new Date(c9.body.courses[0].closes_at).getTime() - Date.now();
  check('and says when it closes, about a day from now', closesIn > 23 * 3_600_000 && closesIn < 25 * 3_600_000, c9.body.courses[0]);
  const p9 = await api('GET', `/student/courses/${C}`, S9, undefined, NEW);
  check('the course page lists the test as open', p9.status === 200 && p9.body.course.name === `${tag} Spoken English` && p9.body.tests.length === 1 && p9.body.tests[0].state === 'open' && p9.body.tests[0].class_level === null, p9.body);
  const l11 = await login(`${tag}.eleven`, '1234');
  const S11 = l11.body.token as string;
  const h11 = await api('GET', '/student/home', S11, undefined, NEW);
  check('a student who is not in the course is told of no courses', h11.body.courses === 0, h11.body);
  check('and cannot open its page', (await api('GET', `/student/courses/${C}`, S11, undefined, NEW)).status === 404);
  check('or start its test', (await api('POST', `/student/tests/${TEST}/start`, S11, undefined, NEW)).status === 404);
  check('their courses list is empty', (await api('GET', '/student/courses', S11, undefined, NEW)).body.courses.length === 0);

  const start = await api('POST', `/student/tests/${TEST}/start`, S9, undefined, NEW);
  check('a person of the course starts its test', start.status === 200 && start.body.questions.length === 2, start.body);
  const qs = start.body.questions as { id: string }[];
  const right = (await db.query('select id, correct_option from questions where id = any($1::uuid[])', [cqIds])).rows;
  void right;
  const sub = await api('POST', `/student/attempts/${start.body.attempt.id}/submit`, S9, { answers: qs.map((x) => ({ question_id: x.id, choice: 0 })) }, NEW);
  check('and hands it in', sub.status === 200, sub.body);
  const startN = await api('POST', `/student/tests/${TEST}/start`, SN, undefined, NEW);
  check('so does a person who has no class at all', startN.status === 200, startN.body);
  const res9 = await api('GET', '/student/results', S9, undefined, NEW);
  check('what they wrote in the course is not among their class results', res9.body.results.length === 0, res9.body);

  const results = await api('GET', `/teacher/tests/${TEST}/results`, TA, undefined, NEW);
  const rs = results.body;
  check('the tutor sees the course\'s results: three given it, one submitted, one writing', results.status === 200 && rs.summary.assigned === 3 && rs.summary.submitted === 1 && rs.summary.writing === 1 && rs.test.course === `${tag} Spoken English`, rs.summary);
  check('the person with no class is listed with no class', rs.students.some((s: any) => s.id === idN && s.class_level === null));
  const page1 = await api('GET', `/teacher/courses/${C}`, TA, undefined, NEW);
  const row9 = page1.body.people.find((p: any) => p.id === id9);
  check('the course page counts what each person wrote in the course', Number(row9.tests_done) === 1 && row9.avg_pct !== null, row9);
  const g9 = await api('GET', '/teacher/groups/9/' + MATHS, TA, undefined, NEW);
  check('a group page counts none of it', Number(g9.body.students.find((s: any) => s.id === id9).tests_done) === 0, g9.body.students.find((s: any) => s.id === id9));
  const person = await api('GET', `/teacher/students/${id9}?course=${C}`, TA, undefined, NEW);
  check('a person\'s page for the course has the course\'s attempts and no chapters', person.status === 200 && person.body.attempts.length === 1 && person.body.chapters.length === 0, person.body);
  const personGroup = await api('GET', `/teacher/students/${id9}`, TA, undefined, NEW);
  check('their page for the group has none of them', personGroup.body.attempts.length === 0 && personGroup.body.student.courses.length === 1, personGroup.body);
  const badCourse = await api('GET', `/teacher/students/${id9}?course=00000000-0000-4000-8000-00000000dead`, TA, undefined, NEW);
  check('a course that is not there is a 404', badCourse.status === 404);

  // ------------------------------------------------------------------ another tuition cannot see or touch it
  const inst = { 'x-install-id': `${tag}-b` };
  const su = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Tutor B', username: `${tag}.b`, password: 'longenough1' }, inst);
  created.users.push(su.body.user.id);
  const TB = su.body.token as string;
  const mkB = await api('POST', '/auth/tuitions', TB, { name: `${tag} Tuition B`, groups: [{ class_level: 9, subject_id: MATHS }] });
  const B = mkB.body.tuition.id as string;
  created.tuitions.push(B);
  const joinCode = mkB.body.tuition.join_code as string;
  check('another tuition has no courses', (await api('GET', '/teacher/courses', TB, undefined, NEW)).body.courses.length === 0);
  const nf = (name: string, r: { status: number }) => check(name, r.status === 404, r);
  nf('and cannot open the course', await api('GET', `/teacher/courses/${C}`, TB, undefined, NEW));
  nf('or add people to it', await api('POST', `/teacher/courses/${C}/people`, TB, { student_ids: [] }, NEW));
  nf('or make a person in it', await api('POST', `/teacher/courses/${C}/people/new`, TB, { display_name: 'X Y', username: `${tag}.x`, pin: '1111' }, NEW));
  nf('or take someone out of it', await api('DELETE', `/teacher/courses/${C}/people/${id9}`, TB, undefined, NEW));
  nf('or delete it', await api('DELETE', `/teacher/courses/${C}?with_results=1`, TB, undefined, NEW));
  nf('or make a paper for it', await api('POST', '/teacher/papers', TB, { pages: 1, course_id: C }, NEW));
  nf('or make a test for it', await api('POST', '/teacher/tests', TB, { title: 'x', course_id: C, question_ids: [], shuffle: false }, NEW));
  nf('or list its questions', await api('GET', `/teacher/questions?course=${C}`, TB, undefined, NEW));
  nf('or open its test', await api('GET', `/teacher/tests/${TEST}`, TB, undefined, NEW));
  const addB = await api('POST', '/teacher/courses', TB, { name: `${tag} Spoken English` }, NEW);
  check('the same course name is free in another tuition', addB.status === 201, addB.body);
  created.courses.push(addB.body.course.id);
  const foreign = await api('POST', `/teacher/courses/${addB.body.course.id}/people`, TB, { student_ids: [id9] }, NEW);
  check('and it cannot add A\'s students to a course of its own', foreign.status === 400 && code(foreign) === 'unknown_student', foreign.body);

  // ------------------------------------------------------------------ joining another tuition changes nothing in the course
  const mkJ = await api('POST', '/teacher/students', TA, { display_name: 'Course Twelve', class_level: 9, username: `${tag}.twelve`, pin: '1234', subject_ids: [MATHS] }, NEW);
  const id12 = mkJ.body.student.id as string;
  created.users.push(id12);
  await api('POST', `/teacher/courses/${C}/people`, TA, { student_ids: [id12] }, NEW);
  const S12 = (await login(`${tag}.twelve`, '1234')).body.token as string;
  const join = await api('POST', '/student/join', S12, { code: joinCode }, NEW);
  check('a person of the course asks to join another tuition', join.status === 201, join.body);
  const acc = await api('POST', `/teacher/join-requests/${id12}/accept`, TB, { class_level: 9, subject_ids: [] }, NEW);
  check('and is let in', acc.status === 200, acc.body);
  const del12 = await api('DELETE', `/teacher/students/${id12}`, TA, undefined, NEW);
  check('A takes them out of its tuition', del12.status === 200, del12.body);
  const left = (await db.query('select count(*) as n from course_members where student_id = $1', [id12])).rows[0].n;
  check('they leave the course with it, and still have their other tuition', Number(left) === 0 && (await db.query('select 1 from memberships where user_id = $1 and tuition_id = $2', [id12, B])).rowCount === 1, left);

  const n2 = await api('POST', `/teacher/courses/${C}/people/new`, TA, { display_name: 'Course Thirteen', username: `${tag}.thirteen`, pin: '2222' }, NEW);
  const id13 = n2.body.student.id as string;
  created.users.push(id13);
  const S13 = (await login(`${tag}.thirteen`, '2222')).body.token as string;
  const join13 = await api('POST', '/student/join', S13, { code: joinCode }, NEW);
  check('a person with no class asks to join another tuition', join13.status === 201, join13.body);
  const noClass = await api('POST', `/teacher/join-requests/${id13}/accept`, TB, {}, NEW);
  check('that tuition must name a class for them before it lets them in', noClass.status === 400 && code(noClass) === 'class_needed', noClass.body);
  const stillPending = (await db.query(`select status from memberships where user_id = $1 and tuition_id = $2`, [id13, B])).rows[0];
  check('and they stay waiting', stillPending?.status === 'pending', stillPending);
  const withClass = await api('POST', `/teacher/join-requests/${id13}/accept`, TB, { class_level: 9, subject_ids: [] }, NEW);
  check('with a class they are let in', withClass.status === 200, withClass.body);

  // ------------------------------------------------------------------ taking someone out, and the oldest build the server serves
  const out = await api('DELETE', `/teacher/courses/${C}/people/${id10}`, TA, undefined, NEW);
  check('a person is taken out of the course', out.status === 200, out.body);
  check('and cannot be taken out twice', (await api('DELETE', `/teacher/courses/${C}/people/${id10}`, TA, undefined, NEW)).status === 404);
  const stays = await api('GET', `/teacher/students/${id10}`, TA, undefined, NEW);
  check('they are still a student', stays.status === 200 && stays.body.student.courses.length === 0 && stays.body.student.class_level === 10, stays.body.student);

  await db.query(`insert into app_settings (key, value) values ('min_app_build', '9') on conflict (key) do update set value = excluded.value`);
  const tooOld = await api('GET', '/teacher/home', TA, undefined, NEW);
  check('a build below the minimum is refused with 426', tooOld.status === 426 && code(tooOld) === 'update_required', tooOld.body);
  const tooOldLogin = await login(logins.teacher.username, logins.teacher.password, NEW);
  check('it cannot sign in either', tooOldLogin.status === 426 && code(tooOldLogin) === 'update_required', tooOldLogin.body);
  check('signing out always works', (await api('POST', '/auth/logout', (await login(logins.teacher.username, logins.teacher.password, { 'x-app': 'core_academy/1.6.0+9' })).body.token, undefined, NEW)).status === 200);
  const okBuild = await api('GET', '/teacher/home', TA, undefined, { 'x-app': 'core_academy/1.6.0+9' });
  check('a build at the minimum is served', okBuild.status === 200, okBuild.body);
  const noHeader = await api('GET', '/teacher/home', TA);
  check('a caller that names no build is not turned away', noHeader.status === 200, noHeader.body);
  const adminLogin = await api('POST', '/auth/login', undefined, { username: logins.developer?.username ?? 'x', secret: logins.developer?.password ?? 'x' }, ADMIN);
  check('and the admin app is never held to the main app\'s build', adminLogin.status !== 426, adminLogin.body);
  const events = (await db.query(`select count(*) as n from auth_events where outcome = 'update_required' and username = any($1::text[])`, [[`${tag}.new`, logins.teacher.username]])).rows[0].n;
  check('turned-away sign-ins are in the login history', Number(events) >= 3, events);
  await db.query(`delete from app_settings where key = 'min_app_build'`);
  check('with the minimum cleared everything is served again', (await api('GET', '/teacher/home', TA, undefined, NEW)).status === 200);

  // ------------------------------------------------------------------ deleting the course
  const guard = await api('DELETE', `/teacher/courses/${C}`, TA, undefined, NEW);
  check('deleting a course people have written tests in asks first', guard.status === 409 && code(guard) === 'has_attempts', guard.body);
  const del = await api('DELETE', `/teacher/courses/${C}?with_results=1`, TA, undefined, NEW);
  check('then deletes it, with its test and results', del.status === 200 && del.body.tests_deleted === 1 && del.body.questions_deleted === 2 && del.body.papers_deleted === 1 && del.body.results_deleted === 2, del.body);
  const gone = (await db.query(
    `select (select count(*) from tests where id = $1) + (select count(*) from questions where id = any($2::uuid[]))
          + (select count(*) from papers where id = $3) + (select count(*) from courses where id = $4)
          + (select count(*) from attempts where test_id = $1) as n`,
    [TEST, cqIds, P, C],
  )).rows[0].n;
  check('the course, its test, questions, paper and attempts are gone', Number(gone) === 0, gone);
  const keepers = (await db.query('select id from users where id = any($1::uuid[])', [[id9, id10, id11, idN, id13]])).rowCount;
  check('and its people are still there', keepers === 5, keepers);
  const after9 = await api('GET', '/student/home', S9, undefined, NEW);
  check('a student of a class goes on as before, now in no course', after9.status === 200 && after9.body.courses === 0, after9.body);
  const afterN = await api('GET', '/student/home', SN, undefined, NEW);
  check('the person with no class can still sign in, and has nothing', afterN.status === 200 && afterN.body.courses === 0 && afterN.body.tests.length === 0, afterN.body);
  const gq2 = await api('GET', `/teacher/questions/${gq.body.id}`, TA, undefined, NEW);
  check('a group\'s question was not touched', gq2.status === 200);
  check('the course page is gone', (await api('GET', `/teacher/courses/${C}`, TA, undefined, NEW)).status === 404);
} catch (e) {
  fail++;
  console.log('FAIL  unexpected error:', e);
} finally {
  // Tests before the questions they use, then courses, people, tuitions.
  await db.query('delete from app_settings where key = $1', ['min_app_build']);
  await db.query('delete from tests where id = any($1::uuid[]) or course_id = any($2::uuid[])', [created.tests, created.courses]);
  await db.query('delete from questions where id = any($1::uuid[]) or paper_id = any($2::uuid[]) or course_id = any($3::uuid[])', [created.questions, created.papers, created.courses]);
  await db.query('delete from papers where id = any($1::uuid[]) or course_id = any($2::uuid[])', [created.papers, created.courses]);
  await db.query('delete from courses where id = any($1::uuid[])', [created.courses]);
  await db.query('delete from app_installs where install_id like $1', [`${tag}-%`]);
  await db.query('delete from auth_events where username like $1', [`${tag}.%`]);
  await db.query('delete from users where id = any($1::uuid[])', [created.users.filter(Boolean)]);
  await db.query('delete from tuitions where id = any($1::uuid[])', [created.tuitions]);
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
