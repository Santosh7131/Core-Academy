// Sets up a small Courses demo on the dev branch, so a build can be tried on a phone with something in it:
// two courses with people (some in no class and no group), a live test, a finished one with results and a draft.
// Safe to run again: it clears its own courses first. `--clear` takes the demo away again (the people it made
// go too). Refuses main. Writes the demo logins to tools/out/courses-demo.<branch>.txt (git-ignored).
// Usage: node tools/courses-demo.ts [--env .env.local] [--base https://...] [--clear]
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import pg from 'pg';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
if (process.env.NEON_BRANCH === 'main') throw new Error('This writes demo data; run it against dev, not main.');
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error(`No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in ${envFile}).`);
const branch = process.env.NEON_BRANCH;
const logins = JSON.parse(readFileSync(`tools/out/sample-logins.${branch}.json`, 'utf8'));
const clear = args.includes('--clear');
const OUT = `tools/out/courses-demo.${branch}`;

// An app that knows courses.
const NEW = { 'x-app': 'core_academy/1.6.0+8' };

async function api(method: string, path: string, token?: string, body?: unknown) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
      ...NEW,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const json: any = await res.json().catch(() => null);
  return { status: res.status, body: json };
}
/** The call's body, or a stop with what the server said. */
async function must(what: string, call: Promise<{ status: number; body: any }>, ok: number[] = [200, 201]) {
  const r = await call;
  if (!ok.includes(r.status)) throw new Error(`${what}: ${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
}
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();
const DAY = 86_400_000;

const ENGLISH = 'Spoken English';
const OLYMPIAD = 'Maths Olympiad';
const newcomers = [
  { name: 'Meenakshi R', username: 'meenakshi.r', pin: '4242' },
  { name: 'Vignesh K', username: 'vignesh.k', pin: '4242' },
];

const questions: { text: string; options: string[]; correct: number }[] = [
  { text: 'Which sentence is correct?', options: ["She don't like tea.", "She doesn't like tea.", 'She not like tea.', "She doesn't likes tea."], correct: 1 },
  { text: 'Choose the polite way to ask for a favour.', options: ['Give me your pen.', 'I want your pen.', 'Could you lend me your pen, please?', 'Pen, now.'], correct: 2 },
  { text: 'Which word is stressed on the second syllable?', options: ['table', 'begin', 'happy', 'water'], correct: 1 },
  { text: "Complete it: \"I have been waiting ___ an hour.\"", options: ['since', 'for', 'from', 'during'], correct: 1 },
  { text: "Which word rhymes with \"night\"?", options: ['light', 'late', 'lit', 'net'], correct: 0 },
  { text: 'What do you say when you meet someone for the first time?', options: ['See you later!', 'Nice to meet you.', 'Thanks a lot.', 'Never mind.'], correct: 1 },
];

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();

try {
  const la = await must('tutor login', api('POST', '/auth/login', undefined, { username: logins.teacher.username, secret: logins.teacher.password }));
  const TA = la.token as string;

  // Take away what an earlier run left.
  const before = await must('courses', api('GET', '/teacher/courses', TA));
  for (const c of before.courses.filter((x: any) => x.name === ENGLISH || x.name === OLYMPIAD)) {
    await must(`delete ${c.name}`, api('DELETE', `/teacher/courses/${c.id}?with_results=1`, TA));
  }
  const peopleIds = async (names: string[]) => (await db.query('select id, username from users where username = any($1::text[])', [names])).rows as { id: string; username: string }[];
  if (clear) {
    for (const p of await peopleIds(newcomers.map((n) => n.username))) await must(`remove ${p.username}`, api('DELETE', `/teacher/students/${p.id}`, TA), [200, 404]);
    rmSync(`${OUT}.txt`, { force: true });
    console.log('The demo is gone.');
    process.exit(0);
  }

  // ------------------------------------------------------------ Spoken English: five people, three tests
  const english = (await must('make the course', api('POST', '/teacher/courses', TA, { name: ENGLISH }))).course.id as string;
  const existing = await peopleIds(['harini.v', 'aditi.k', 'sanjay.m']);
  await must('add students', api('POST', `/teacher/courses/${english}/people`, TA, { student_ids: existing.map((p) => p.id) }));
  const ids: Record<string, string> = Object.fromEntries(existing.map((p) => [p.username, p.id]));
  for (const n of newcomers) {
    const have = (await peopleIds([n.username]))[0];
    if (have) {
      await must(`add ${n.name}`, api('POST', `/teacher/courses/${english}/people`, TA, { student_ids: [have.id] }));
      ids[n.username] = have.id;
    } else {
      const made = await must(`make ${n.name}`, api('POST', `/teacher/courses/${english}/people/new`, TA, { display_name: n.name, username: n.username, pin: n.pin }));
      ids[n.username] = made.student.id;
    }
  }

  // The questions come in the way a tutor's paper brings them: a paper of the course, saved into it.
  const paper = (await must('make the paper', api('POST', '/teacher/papers', TA, { pages: 1, course_id: english }))).paper.id as string;
  for (const [i, q] of questions.entries()) {
    await db.query(
      `insert into paper_drafts (paper_id, page_no, seq, number_label, kind, text, options, correct_option, answer_source, answer_checked)
       values ($1, 1, $2, $3, 'mcq', $4, $5, $6, 'teacher', true)`,
      [paper, i, String(i + 1), q.text, q.options, q.correct],
    );
  }
  await must('save the questions', api('POST', `/teacher/papers/${paper}/save`, TA, {}));
  const saved = (await must('list the questions', api('GET', `/teacher/questions?course=${english}`, TA))).questions as any[];
  const qid = (n: number) => saved.find((x) => x.text === questions[n].text).id as string;

  const live = (await must('live test', api('POST', '/teacher/tests', TA, {
    title: 'Everyday phrases', course_id: english, question_ids: [0, 1, 3, 5].map(qid), shuffle: false, time_limit_min: 15, closes_at: iso(3 * DAY),
  }))).id as string;
  await must('post the live test', api('POST', `/teacher/tests/${live}/publish`, TA, { published: true }));
  await must('draft test', api('POST', '/teacher/tests', TA, { title: 'Telephone talk', course_id: english, question_ids: [1, 5].map(qid), shuffle: false }));

  // A finished test with results: three people write it, one does not, then it closes.
  const done = (await must('finished test', api('POST', '/teacher/tests', TA, {
    title: 'Sounds and stress', course_id: english, question_ids: [2, 4, 0, 3].map(qid), shuffle: false, closes_at: iso(DAY),
  }))).id as string;
  await must('post the finished test', api('POST', `/teacher/tests/${done}/publish`, TA, { published: true }));
  // The new people's PINs are the ones chosen above; the sample students' are in the sample logins file.
  const sample = (u: string) => (logins.students as any[]).find((s) => s.username === u);
  const pinOf = (u: string) => newcomers.find((n) => n.username === u)?.pin ?? sample(u)?.pin;
  const writers = [
    { user: 'meenakshi.r', right: 4 },
    { user: 'harini.v', right: 3 },
    { user: 'aditi.k', right: 2 },
  ];
  const testQ = [2, 4, 0, 3];
  for (const w of writers) {
    const pin = pinOf(w.user);
    const l = await must(`${w.user} signs in`, api('POST', '/auth/login', undefined, { username: w.user, secret: pin }));
    const start = await must(`${w.user} starts`, api('POST', `/student/tests/${done}/start`, l.token));
    const answers = (start.questions as { id: string }[]).map((q) => {
      const n = testQ.findIndex((i) => qid(i) === q.id);
      const correct = questions[testQ[n]].correct;
      return { question_id: q.id, choice: n < w.right ? correct : (correct + 1) % 4 };
    });
    await must(`${w.user} hands in`, api('POST', `/student/attempts/${start.attempt.id}/submit`, l.token, { answers }));
  }
  // Closed yesterday evening, so it lists as finished with its results open.
  await db.query(`update tests set closes_at = now() - interval '5 hours', created_at = now() - interval '3 days' where id = $1`, [done]);
  await db.query(`update attempts set started_at = started_at - interval '1 day', submitted_at = submitted_at - interval '1 day' where test_id = $1`, [done]);
  // Everyone was in the course well before it closed, so the ones who did not write it count as missed.
  await db.query(`update course_members set added_at = now() - interval '5 days' where course_id = $1`, [english]);

  // ------------------------------------------------------------ Maths Olympiad: two people, nothing posted yet
  const olympiad = (await must('second course', api('POST', '/teacher/courses', TA, { name: OLYMPIAD }))).course.id as string;
  const olympiadPeople = await peopleIds(['harini.v', 'rohan.b']);
  await must('add the second course\'s people', api('POST', `/teacher/courses/${olympiad}/people`, TA, { student_ids: olympiadPeople.map((p) => p.id) }));

  // ------------------------------------------------------------ the sheet to read the logins from
  const lines = [
    `Core Academy Dev: demo logins (dev data only, never the live app)`,
    ``,
    `TUTOR`,
    `  username  ${logins.teacher.username}`,
    `  password  ${logins.teacher.password}`,
    `  sees      Courses tab with "${ENGLISH}" (5 people, 1 live test, 1 draft, 1 finished) and "${OLYMPIAD}" (2 people)`,
    ``,
    `STUDENT IN A CLASS AND A COURSE`,
    `  username  harini.v   PIN ${sample('harini.v')?.pin}   (class 9, in both courses)`,
    `  sees      Tests and Courses toggle; the live test sits under Courses`,
    ``,
    `STUDENT WITH NO CLASS (only in a course)`,
    ...newcomers.flatMap((n) => [`  username  ${n.username}   PIN ${n.pin}   (${n.name})`]),
    `  sees      opens straight on the Courses list, no class bar (Meenakshi wrote the finished test, Vignesh did not)`,
    ``,
    `To take the demo away: node tools/courses-demo.ts --clear`,
  ];
  writeFileSync(`${OUT}.txt`, lines.join('\n') + '\n');
  writeFileSync(`${OUT}.json`, JSON.stringify({ english, olympiad, live, done, ids }, null, 2));
  console.log(lines.join('\n'));
} finally {
  await db.end();
}
