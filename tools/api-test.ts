// End-to-end checks of the marking rules against a running API (the deployed dev branch by default).
// Creates its own students, questions and tests, then removes them.
// Usage: node tools/api-test.ts [--env .env.local] [--base https://...] [--skip-wait]
import { randomInt } from 'node:crypto';
import { readFileSync } from 'node:fs';
import pg from 'pg';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error(`No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in ${envFile}).`);
const logins = JSON.parse(readFileSync(`tools/out/sample-logins.${process.env.NEON_BRANCH}.json`, 'utf8'));

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

async function api(method: string, path: string, token?: string, body?: unknown) {
  const res = await fetch(BASE + path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const json: any = await res.json().catch(() => null);
  return { status: res.status, body: json };
}
const login = (username: string, secret: string) => api('POST', '/auth/login', undefined, { username, secret });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();

const created = { users: [] as string[], questions: [] as string[], tests: [] as string[], subjects: [] as string[], papers: [] as string[] };
const tag = `apitest${randomInt(1000, 9999)}`;

try {
  check('API is up', (await api('GET', '/')).status === 200);

  const t = await login(logins.teacher.username, logins.teacher.password);
  check('teacher logs in', t.status === 200 && t.body?.user?.role === 'teacher', t.body);
  const T = t.body.token as string;

  // Two temporary class 9 students.
  const s1 = await api('POST', '/teacher/students', T, { display_name: 'Test Student One', class_level: 9, username: `${tag}.one`, pin: '1234' });
  const s2 = await api('POST', '/teacher/students', T, { display_name: 'Test Student Two', class_level: 9, username: `${tag}.two`, pin: '5678' });
  check('teacher creates students', s1.status === 201 && s2.status === 201, [s1.body, s2.body]);
  created.users.push(s1.body.student.id, s2.body.student.id);
  const dup = await api('POST', '/teacher/students', T, { display_name: 'Dup', class_level: 9, username: `${tag}.one`, pin: '1111' });
  check('duplicate username is refused', dup.status === 409 && dup.body?.error?.code === 'username_taken', dup.body);

  // Three questions; the third must keep its option order.
  const qdefs = [
    { text: `${tag} What is $2 + 2$?`, options: ['$3$', '$4$', '$5$', '$6$'], correct_option: 1 },
    { text: `${tag} What is $3 \\times 3$?`, options: ['$6$', '$9$', '$12$', '$33$'], correct_option: 1 },
    { text: `${tag} Which are even?`, options: ['$2$', '$4$', 'Both (a) and (b)', 'Neither'], correct_option: 2 },
  ];
  for (const d of qdefs) {
    const r = await api('POST', '/teacher/questions', T, { class_level: 9, ...d });
    check(`teacher creates question "${d.text.slice(tag.length + 1, tag.length + 20)}"`, r.status === 201, r.body);
    created.questions.push(r.body.id);
  }
  const keep = await api('GET', `/teacher/questions/${created.questions[2]}`, T);
  check('"Both (a) and (b)" question keeps option order', keep.body?.question?.keep_option_order === true, keep.body?.question);

  const mkTest = async (title: string, extra: Record<string, unknown>) => {
    const r = await api('POST', '/teacher/tests', T, {
      title: `${tag} ${title}`, class_level: 9, question_ids: created.questions, shuffle: true,
      assign_all: false, student_ids: created.users, ...extra,
    });
    created.tests.push(r.body.id);
    const p = await api('POST', `/teacher/tests/${r.body.id}/publish`, T, { published: true });
    check(`test "${title}" created and published`, r.status === 201 && p.status === 200, [r.body, p.body]);
    return r.body.id as string;
  };
  const A = await mkTest('open', { time_limit_min: 10, opens_at: iso(-60_000), closes_at: iso(30 * 60_000) });

  // Students log in and see the test.
  const l1 = await login(`${tag}.one`, '1234');
  const l2 = await login(`${tag}.two`, '5678');
  check('students log in with username + PIN', l1.status === 200 && l2.status === 200, [l1.body, l2.body]);
  const S1 = l1.body.token as string;
  const S2 = l2.body.token as string;
  const home = await api('GET', '/student/home', S1);
  const homeTest = home.body?.tests?.find((x: any) => x.id === A);
  check('home lists the test as open', homeTest?.state === 'open', homeTest);

  // Starting never sends the answers.
  const st1 = await api('POST', `/student/tests/${A}/start`, S1);
  const st2 = await api('POST', `/student/tests/${A}/start`, S2);
  check('student starts the test', st1.status === 200 && st1.body.questions.length === 3, st1.body);
  check('start payload contains no correct answers', !/correct/i.test(JSON.stringify(st1.body)));
  const again = await api('POST', `/student/tests/${A}/start`, S1);
  check('starting again resumes the same attempt', again.body?.attempt?.id === st1.body.attempt.id);
  const sig = (b: any) => JSON.stringify(b.questions.map((x: any) => [x.id, x.options]));
  check('two students get different orders', sig(st1.body) !== sig(st2.body));
  const kept = st1.body.questions.find((x: any) => x.id === created.questions[2]);
  check('kept-order question is not shuffled', JSON.stringify(kept.options) === JSON.stringify(qdefs[2].options), kept.options);

  // Answer two right and one wrong, by option text, through the shuffle.
  const answers = st1.body.questions.map((x: any) => {
    const def = qdefs[created.questions.indexOf(x.id)];
    const rightText = def.options[def.correct_option];
    const isLast = x.id === created.questions[0];
    const choice = isLast ? x.options.findIndex((o: string) => o !== rightText) : x.options.indexOf(rightText);
    return { question_id: x.id, choice, flagged: isLast };
  });
  const saved = await api('PUT', `/student/attempts/${st1.body.attempt.id}/answers`, S1, { answers });
  check('answers save', saved.status === 200 && saved.body.saved === 3, saved.body);
  const resume = await api('POST', `/student/tests/${A}/start`, S1);
  check('saved answers come back on resume', resume.body.questions.every((x: any) => x.chosen !== null), resume.body.questions);

  const sub = await api('POST', `/student/attempts/${st1.body.attempt.id}/submit`, S1, {});
  check('submit grades 2 of 3', sub.status === 200 && sub.body.attempt.score === 2 && sub.body.attempt.max_score === 3, sub.body?.attempt);
  const reviewOk = sub.body.review.every((r: any) => {
    const def = qdefs[created.questions.indexOf(r.id)];
    return r.options[r.correct] === def.options[def.correct_option];
  });
  check('review shows the right correct option through the shuffle', reviewOk, sub.body.review);
  check('answers cannot change after submit', (await api('PUT', `/student/attempts/${st1.body.attempt.id}/answers`, S1, { answers })).status === 409);
  const second = await api('POST', `/student/tests/${A}/start`, S1);
  check('second attempt is refused', second.status === 409 && second.body?.error?.code === 'already_done', second.body);

  const grant = await api('POST', `/teacher/tests/${A}/retake`, T, { student_id: created.users[0] });
  const retake = await api('POST', `/student/tests/${A}/start`, S1);
  check('teacher-granted retake starts a new attempt', grant.status === 200 && retake.status === 200 && retake.body.attempt.id !== st1.body.attempt.id, retake.body);
  const sub2 = await api('POST', `/student/attempts/${retake.body.attempt.id}/submit`, S1, {});
  check('empty retake scores 0 with 3 skipped', sub2.body?.attempt?.score === 0 && sub2.body?.attempt?.skipped === 3, sub2.body?.attempt);

  const res = await api('GET', `/teacher/tests/${A}/results`, T);
  const row1 = res.body?.students?.find((s: any) => s.id === created.users[0]);
  check('teacher results list both students', res.status === 200 && res.body.students.length === 2, res.body?.students);
  check('teacher results show the latest attempt', row1?.attempt_no === 2 && row1?.status === 'submitted', row1);
  check('per-question stats are present', res.body?.questions?.length === 3 && res.body.questions.every((x: any) => x.option_counts.length === 4), res.body?.questions);

  check('students cannot open teacher pages', (await api('GET', '/teacher/dashboard', S1)).status === 403);
  check('teacher dashboard loads', (await api('GET', '/teacher/dashboard', T)).status === 200);

  // Window rules.
  const B = await mkTest('future', { opens_at: iso(86_400_000), closes_at: iso(90_000_000) });
  const C = await mkTest('closed', { opens_at: iso(-7_200_000), closes_at: iso(-3_600_000) });
  const sb = await api('POST', `/student/tests/${B}/start`, S2);
  const sc = await api('POST', `/student/tests/${C}/start`, S2);
  check('not-yet-open test is refused', sb.status === 409 && sb.body.error.code === 'not_open_yet', sb.body);
  check('closed test is refused', sc.status === 409 && sc.body.error.code === 'closed', sc.body);
  const home2 = await api('GET', '/student/home', S2);
  const states = Object.fromEntries(home2.body.tests.filter((x: any) => [B, C].includes(x.id)).map((x: any) => [x.id, x.state]));
  check('home shows upcoming and missed', states[B] === 'upcoming' && states[C] === 'missed', states);

  // Deadline: the attempt is submitted automatically once the closing time plus grace has passed.
  if (!args.includes('--skip-wait')) {
    const D = await mkTest('closing', { opens_at: iso(-60_000), closes_at: iso(6_000) });
    const sd = await api('POST', `/student/tests/${D}/start`, S2);
    check('deadline is the closing time', sd.status === 200 && Math.abs(new Date(sd.body.attempt.deadline_at).getTime() - (Date.now() + 6_000)) < 15_000, sd.body?.attempt);
    const one = sd.body.questions[0];
    await api('PUT', `/student/attempts/${sd.body.attempt.id}/answers`, S2, { answers: [{ question_id: one.id, choice: 0 }] });
    console.log('      waiting 40 s for the deadline and grace period...');
    await sleep(40_000);
    const late = await api('PUT', `/student/attempts/${sd.body.attempt.id}/answers`, S2, { answers: [{ question_id: one.id, choice: 1 }] });
    check('saving after the deadline is refused', late.status === 409 && late.body.error.code === 'time_up', late.body);
    const r = await api('GET', `/student/attempts/${sd.body.attempt.id}/result`, S2);
    check('expired attempt was auto-submitted with the saved answer', r.status === 200 && r.body.attempt.auto_submitted === true && r.body.review.some((x: any) => x.chosen !== null), r.body?.attempt);
  }

  // Groups: a class and a subject. A group test reaches only the class's students who study it.
  // The group checks use a subject of their own, so no real student (on live, a real 9th Science
  // student) is ever given, or notified about, a test from this script.
  const subj = await api('GET', '/teacher/subjects', T);
  const maths = subj.body?.subjects?.find((x: any) => x.is_default);
  check('Maths and Science are subjects, Maths the default',
    maths?.name === 'Maths' && subj.body?.subjects?.some((x: any) => x.name === 'Science'), subj.body);
  const ns = await api('POST', '/teacher/subjects', T, { name: tag });
  check('teacher adds a subject', ns.status === 201 && ns.body?.subject?.name === tag, ns.body);
  const own = ns.body.subject;
  created.subjects.push(own.id);
  const s3 = await api('POST', '/teacher/students', T, {
    display_name: 'Test Student Three', class_level: 9, username: `${tag}.three`, pin: '4321', subject_ids: [own.id],
  });
  check('a student of one other subject can be added', s3.status === 201, s3.body);
  created.users.push(s3.body.student.id);
  const names = (r: any) => JSON.stringify(r.body?.student?.subjects?.map((x: any) => x.name));
  const d1 = await api('GET', `/teacher/students/${created.users[0]}`, T);
  const d3 = await api('GET', `/teacher/students/${s3.body.student.id}`, T);
  check('students added by the older app study maths', names(d1) === '["Maths"]', d1.body?.student?.subjects);
  check('that student studies only that subject', names(d3) === JSON.stringify([tag]), d3.body?.student?.subjects);

  const sq = await api('POST', '/teacher/questions', T, {
    class_level: 9, subject_id: own.id, text: `${tag} Which gas do plants take in for photosynthesis?`,
    options: ['Oxygen', 'Carbon dioxide', 'Nitrogen', 'Hydrogen'], correct_option: 1,
  });
  created.questions.push(sq.body.id);
  const sqRow = await api('GET', `/teacher/questions/${sq.body.id}`, T);
  check('a question can belong to that subject', sq.status === 201 && sqRow.body?.question?.subject === tag, sqRow.body?.question);
  const sciList = await api('GET', `/teacher/questions?class=9&subject=${own.id}&q=${tag}`, T);
  check('the question bank filters by subject', sciList.body?.questions?.length === 1 && sciList.body.questions[0].id === sq.body.id,
    sciList.body?.questions?.map((x: any) => x.text));

  const g = await api('POST', '/teacher/tests', T, {
    title: `${tag} group`, class_level: 9, subject_id: own.id, question_ids: [sq.body.id],
    assign_all: false, assign_group: true, opens_at: iso(-60_000), closes_at: iso(30 * 60_000),
  });
  created.tests.push(g.body.id);
  const gp = await api('POST', `/teacher/tests/${g.body.id}/publish`, T, { published: true });
  check('a test can go to a class + subject group', g.status === 201 && gp.status === 200, [g.body, gp.body]);
  const S3 = (await login(`${tag}.three`, '4321')).body.token as string;
  const sees = async (token: string) => ((await api('GET', '/student/home', token)).body?.tests ?? []).some((x: any) => x.id === g.body.id);
  check('a group member sees the group test', await sees(S3));
  check('a classmate outside the group does not see it', !(await sees(S1)));
  check('and cannot start it', (await api('POST', `/student/tests/${g.body.id}/start`, S1)).status === 404);
  const gr = await api('GET', `/teacher/tests/${g.body.id}/results`, T);
  check('the group test results list only the group', JSON.stringify(gr.body?.students?.map((x: any) => x.id)) === JSON.stringify([s3.body.student.id]),
    gr.body?.students?.map((x: any) => x.display_name));
  const groups = await api('GET', '/teacher/groups', T);
  check('groups count the new group', groups.body?.groups?.some((x: any) => x.class_level === 9 && x.subject === tag && x.students === 1), groups.body);
  await api('PATCH', `/teacher/students/${created.users[0]}`, T, { subject_ids: [maths.id, own.id] });
  check('adding Science to a student brings in the group test', await sees(S1));

  const old = await api('POST', '/teacher/tests', T, { title: `${tag} older app`, class_level: 9, question_ids: [created.questions[0]] });
  created.tests.push(old.body.id);
  const oldRow = (await api('GET', `/teacher/tests/${old.body.id}`, T)).body?.test;
  check('a test from the older app is a whole-class maths test', oldRow?.subject_id === maths.id && oldRow?.assign_all === true && oldRow?.assign_group === false, oldRow);
  check('a subject in use cannot be deleted', (await api('DELETE', `/teacher/subjects/${own.id}`, T)).status === 409);
  check('Maths cannot be deleted', (await api('DELETE', `/teacher/subjects/${maths.id}`, T)).status === 409);

  // A question paper is kept under its name and lists the questions saved from it, in paper order.
  const pp = await api('POST', '/teacher/papers', T, { class_level: 9, subject_id: maths.id, exam_name: `${tag} paper`, year: 2025, pages: 1 });
  const paperId = pp.body?.paper?.id;
  if (paperId) created.papers.push(paperId);
  check('teacher uploads a named paper', pp.status === 201 && pp.body?.paper?.exam_name === `${tag} paper`, pp.body);
  // Two questions as the AI reader leaves them, with the right options already marked by the teacher.
  const pdb = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
  await pdb.connect();
  await pdb.query(
    `insert into paper_drafts (paper_id, page_no, seq, number_label, kind, text, options, correct_option)
     values ($1, 1, 2, '2', 'mcq', $3, $4, 1), ($1, 1, 1, '1', 'mcq', $2, $4, 0)`,
    [paperId, `${tag} first`, `${tag} second`, ['a', 'b', 'c', 'd']],
  );
  await pdb.end();
  const sv = await api('POST', `/teacher/papers/${paperId}/save`, T);
  check('checked questions from a paper are saved', sv.status === 200 && sv.body?.saved === 2, sv.body);
  const one = await api('GET', `/teacher/papers/${paperId}`, T);
  check('the paper lists its saved questions in paper order',
    JSON.stringify(one.body?.questions?.map((x: any) => x.text)) === JSON.stringify([`${tag} first`, `${tag} second`]), one.body?.questions);
  const rn = await api('PATCH', `/teacher/papers/${paperId}`, T, { exam_name: `${tag} renamed`, year: null, school_id: null });
  check('teacher renames the paper', rn.status === 200 && rn.body?.paper?.exam_name === `${tag} renamed` && rn.body?.paper?.year === null, rn.body);
  const prow = (await api('GET', '/teacher/papers', T)).body?.papers?.find((x: any) => x.id === paperId);
  check('the papers list shows the new name and the saved count', prow?.exam_name === `${tag} renamed` && prow?.saved === 2, prow);
  check('a paper cannot be renamed to nothing', (await api('PATCH', `/teacher/papers/${paperId}`, T, { exam_name: '  ' })).status === 400);

  // Lockout, PIN reset and deactivation.
  let last = 0;
  for (let i = 0; i < 5; i++) last = (await login(`${tag}.two`, '0000')).status;
  check('fifth wrong PIN locks the login', last === 429);
  check('right PIN is refused while locked', (await login(`${tag}.two`, '5678')).status === 429);
  const reset = await api('POST', `/teacher/students/${created.users[1]}/reset-pin`, T, { pin: '2468' });
  check('teacher resets the PIN', reset.status === 200 && reset.body.login.pin === '2468', reset.body);
  check('old session stops working after reset', (await api('GET', '/student/home', S2)).status === 401);
  check('new PIN works and the lock is cleared', (await login(`${tag}.two`, '2468')).status === 200);
  await api('POST', `/teacher/students/${created.users[0]}/active`, T, { active: false });
  check('deactivated student cannot log in', (await login(`${tag}.one`, '1234')).status === 403);
  check('deactivated student session stops working', (await api('GET', '/student/home', S1)).status === 401);
} catch (e) {
  fail++;
  console.log('FAIL  unexpected error:', e);
} finally {
  const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
  await db.connect();
  await db.query('delete from tests where id = any($1::uuid[])', [created.tests]);
  await db.query('delete from questions where id = any($1::uuid[]) or paper_id = any($2::uuid[])', [created.questions, created.papers]);
  await db.query('delete from papers where id = any($1::uuid[])', [created.papers]);
  await db.query('delete from users where id = any($1::uuid[])', [created.users]);
  await db.query('delete from subjects where id = any($1::uuid[])', [created.subjects]);
  await db.end();
  console.log(`\n${pass} passed, ${fail} failed (test data removed)`);
  process.exit(fail ? 1 : 0);
}
