// Seeds sample data into the branch in .env.local (the dev branch by default).
// Usage: node tools/seed.ts [--reset] [--env .env.local] [--allow-main]
// Logins are written to tools/out/sample-logins.md (git-ignored), never printed or committed.
import { randomBytes, randomInt } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import pg from 'pg';
import { hashSecret, newPin } from '../api/src/lib/auth.ts';
import { shuffle } from '../api/src/lib/attempts.ts';
import { chapters, questions, students } from './sample-data.ts';

// The tuition the app was first built for (made by migration 012). Every row names its tuition: none falls back to it.
const TUITION = '00000000-0000-4000-8000-0000000000a1';
const MATHS = '00000000-0000-4000-8000-000000000001';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
if (process.env.NEON_BRANCH === 'main' && !args.includes('--allow-main')) {
  throw new Error('Refusing to seed the main (production) branch without --allow-main.');
}

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED ?? process.env.DATABASE_URL });
await db.connect();
const q = async (sql: string, params: unknown[] = []) => (await db.query(sql, params)).rows;

const existing = (await q('select count(*)::int as n from users where is_sample'))[0].n;
if (existing && !args.includes('--reset')) {
  console.log('Sample data already exists. Run with --reset to replace it.');
  await db.end();
  process.exit(0);
}

await db.query('begin');
try {
  // Same order as DELETE /teacher/sample-data.
  await q(`delete from test_questions tq using questions qq where qq.id = tq.question_id and qq.is_sample
            and not exists (select 1 from tests t where t.id = tq.test_id and t.is_sample)`);
  for (const t of ['tests', 'questions', 'papers']) await q(`delete from ${t} where is_sample`);
  await q(`delete from users where is_sample and role = 'student'`);
  await q('delete from chapters where is_sample');

  const [{ d0, now }] = await q(
    `select (date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata') as d0, now() as now`,
  );
  const at = (days: number, hours: number, minutes = 0) => new Date(d0.getTime() + ((days * 24 + hours) * 60 + minutes) * 60_000);
  const ago = (minutes: number) => new Date(now.getTime() - minutes * 60_000);

  // The teacher is a real record, kept when sample data is deleted.

  const logins: string[] = [];
  const machine: { teacher?: { username: string; password: string }; students: { username: string; pin: string; class_level: number }[] } = { students: [] };
  const teacher = (await q(`select id, username from users where role = 'teacher' order by created_at limit 1`))[0];
  let teacherId: string;
  if (teacher) {
    teacherId = teacher.id;
    logins.push(`Teacher: existing account "${teacher.username}" kept; its password is unchanged.`);
  } else {
    const password = randomBytes(9).toString('base64url');
    const { hash, salt } = await hashSecret(password);
    teacherId = (await q(
      `insert into users (role, username, display_name, secret_hash, secret_salt)
       values ('teacher', 'coreacademy', 'Core Academy', $1, $2) returning id`,
      [hash, salt],
    ))[0].id;
    // The first tuition (made by migration 012) gets its owner.
    await q(`insert into memberships (tuition_id, user_id, role, status) values ($2, $1, 'owner', 'active')`, [teacherId, TUITION]);
    logins.push(`Teacher: username coreacademy, password ${password} (change it in Settings)`);
    machine.teacher = { username: 'coreacademy', password };
  }

  // Chapters and questions.
  const questionIds: Record<number, string[]> = {};
  for (const [cls, names] of Object.entries(chapters)) {
    const ids: Record<string, string> = {};
    for (const [i, name] of names.entries()) {
      ids[name] = (await q(
        `insert into chapters (tuition_id, class_level, name, sort_order, is_sample) values ($1, $2, $3, $4, true)
         on conflict (tuition_id, class_level, subject_id, name) do update set sort_order = excluded.sort_order returning id`,
        [TUITION, cls, name, i],
      ))[0].id;
    }
    questionIds[Number(cls)] = [];
    for (const qq of questions[Number(cls)]) {
      const row = (await q(
        `insert into questions (tuition_id, class_level, chapter_id, text, options, correct_option, solution, created_by, is_sample)
         values ($1, $2, $3, $4, $5, $6, $7, $8, true) returning id`,
        [TUITION, cls, ids[qq.chapter], qq.text, qq.options, qq.correct, qq.solution, teacherId],
      ))[0];
      questionIds[Number(cls)].push(row.id);
    }
  }

  // A class and subject are a group of the tuition from the moment anything is made for them.
  for (const cls of Object.keys(chapters)) {
    await q('insert into groups (tuition_id, class_level, subject_id) values ($1, $2, $3) on conflict do nothing', [TUITION, cls, MATHS]);
  }

  // Students.
  const studentIds: Record<string, string> = {};
  logins.push('', 'Students (username, PIN):');
  for (const s of students) {
    const pin = newPin();
    const { hash, salt } = await hashSecret(pin);
    studentIds[s.username] = (await q(
      `insert into users (role, username, display_name, class_level, secret_hash, secret_salt, is_sample)
       values ('student', $1, $2, $3, $4, $5, true) returning id`,
      [s.username, s.name, s.classLevel, hash, salt],
    ))[0].id;
    await q(
      `insert into memberships (tuition_id, user_id, role, status, class_level, joined_at) values ($3, $1, 'student', 'active', $2, now() - interval '30 days')`,
      [studentIds[s.username], s.classLevel, TUITION],
    );
    await q(
      `insert into student_subjects (tuition_id, student_id, subject_id) values ($1, $2, $3) on conflict do nothing`,
      [TUITION, studentIds[s.username], MATHS],
    );
    logins.push(`- Class ${s.classLevel}: ${s.name}: ${s.username}, ${pin}`);
    machine.students.push({ username: s.username, pin, class_level: s.classLevel });
  }

  // Tests: two past, one open now, one upcoming, for every class.
  type T = { id: string; qids: string[]; opens: Date; limit: number };
  const tests: Record<number, Record<'weekly' | 'unit1' | 'practice' | 'unit2', T>> = {};
  const makeTest = async (cls: number, title: string, qids: string[], opens: Date, closes: Date, limit: number): Promise<T> => {
    const id = (await q(
      `insert into tests (tuition_id, title, class_level, time_limit_min, opens_at, closes_at, shuffle, assign_all, status, created_by, is_sample)
       values ($1, $2, $3, $4, $5, $6, true, true, 'published', $7, true) returning id`,
      [TUITION, title, cls, limit, opens, closes, teacherId],
    ))[0].id;
    for (const [i, qid] of qids.entries()) {
      await q('insert into test_questions (test_id, question_id, position) values ($1, $2, $3)', [id, qid, i + 1]);
    }
    return { id, qids, opens, limit };
  };
  for (const cls of Object.keys(chapters).map(Number)) {
    const all = questionIds[cls];
    tests[cls] = {
      weekly: await makeTest(cls, 'Weekly quiz', all.slice(0, 4), at(-4, 18), at(-4, 19), 15),
      unit1: await makeTest(cls, 'Unit test 1', all, at(-1, 18), at(-1, 19), 20),
      practice: await makeTest(cls, 'Practice set', all, ago(60), at(2, 21), 15),
      unit2: await makeTest(cls, 'Unit test 2', all, at(1, 18), at(1, 19), 30),
    };
  }

  // Past attempts that hit each student's target score.
  const correctOf = new Map<string, number>(
    (await q('select id, correct_option from questions where is_sample')).map((r: any) => [r.id, r.correct_option]),
  );
  const makeAttempt = async (studentId: string, t: T, correctTarget: number, started: Date, minutes: number) => {
    const order = shuffle(t.qids);
    const optionOrders = Object.fromEntries(t.qids.map((id) => [id, shuffle([0, 1, 2, 3])]));
    const deadline = new Date(started.getTime() + t.limit * 60_000);
    const submitted = new Date(started.getTime() + minutes * 60_000);
    const a = (await q(
      `insert into attempts (test_id, student_id, started_at, deadline_at, submitted_at, question_order, option_orders)
       values ($1, $2, $3, $4, $5, $6::uuid[], $7) returning id`,
      [t.id, studentId, started, deadline, submitted, order, JSON.stringify(optionOrders)],
    ))[0].id;
    const wrongLeft = order.length - correctTarget;
    for (const [i, qid] of order.entries()) {
      const right = correctOf.get(qid)!;
      let chosen: number | null;
      if (i < correctTarget) chosen = right;
      else if (wrongLeft >= 2 && i === order.length - 1) chosen = null; // one skipped question
      else chosen = (right + 1 + randomInt(0, 3)) % 4;
      await q(
        `insert into answers (attempt_id, question_id, chosen_option, answered_at) values ($1, $2, $3, $4)`,
        [a, qid, chosen, new Date(started.getTime() + (i + 1) * 60_000)],
      );
    }
    await q('select grade_attempt($1)', [a]);
  };
  for (const s of students) {
    const id = studentIds[s.username];
    const t = tests[s.classLevel];
    if (s.weekly !== null) await makeAttempt(id, t.weekly, s.weekly, new Date(t.weekly.opens.getTime() + randomInt(2, 9) * 60_000), randomInt(6, 13));
    if (s.unit1 !== null) await makeAttempt(id, t.unit1, s.unit1, new Date(t.unit1.opens.getTime() + randomInt(2, 9) * 60_000), randomInt(9, 18));
    if (s.practiceToday !== null) await makeAttempt(id, t.practice, s.practiceToday, ago(randomInt(20, 50)), randomInt(7, 12));
  }

  await db.query('commit');
  mkdirSync('tools/out', { recursive: true });
  writeFileSync(
    'tools/out/sample-logins.md',
    `# Core Academy sample logins (${process.env.NEON_BRANCH} branch)\n\nGenerated by tools/seed.ts. Not committed.\n\n${logins.join('\n')}\n`,
  );
  // Read by tools/api-test.ts. Keeps the teacher and developer entries from an earlier run (their accounts are not sample data).
  const jsonPath = `tools/out/sample-logins.${process.env.NEON_BRANCH}.json`;
  let previous: (typeof machine & { developer?: { username: string; password: string } }) | null = null;
  try { previous = JSON.parse(readFileSync(jsonPath, 'utf8')); } catch { /* first run */ }
  writeFileSync(jsonPath, JSON.stringify({ ...machine, teacher: machine.teacher ?? previous?.teacher, ...(previous?.developer ? { developer: previous.developer } : {}) }, null, 2));
  const counts = (await q(
    `select (select count(*) from users where is_sample)::int as students, (select count(*) from questions where is_sample)::int as questions,
            (select count(*) from tests where is_sample)::int as tests, (select count(*) from attempts)::int as attempts`,
  ))[0];
  console.log(`Seeded branch ${process.env.NEON_BRANCH}:`, counts, '\nLogins written to tools/out/sample-logins.md');
} catch (e) {
  await db.query('rollback');
  throw e;
} finally {
  await db.end();
}
