// Claude's own test logins on the dev branch: a tutor with a tuition of its own, and one student in it. A tuition is
// walled off from every other (the dev sample one, and on live the real one), which is what lets these be used for any
// test without disturbing anyone. Passwords are made here and written to tools/out/claude-test-logins.<branch>.json
// (git-ignored), never printed. Nothing here is for the live database: it refuses main.
// Usage: node tools/test-accounts.ts [--env .env.local] [--base https://...] [--reset]
//   no flag  creates what is missing and checks that both logins work and stay inside their own tuition
//   --reset  gives both logins new passwords (the old ones stop working) and rewrites the file
import { randomInt } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import pg from 'pg';
import { hashSecret } from '../api/src/lib/auth.ts';

const args = process.argv.slice(2);
const arg = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
process.loadEnvFile(arg('--env') ?? '.env.local');
const branch = process.env.NEON_BRANCH ?? 'unknown';
if (branch === 'main') throw new Error('Test logins are for the dev branch only, never main.');
const BASE = (arg('--base') ?? process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error('No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in the env file).');
const reset = args.includes('--reset');
const FILE = `tools/out/claude-test-logins.${branch}.json`;
const MATHS = '00000000-0000-4000-8000-000000000001';

const TUITION = 'Claude Test Tuition';
const TUTOR = { username: 'claude.tutor', display_name: 'Claude Test Tutor' };
const STUDENT = { username: 'claude.student', display_name: 'Claude Test Student', class_level: 9 };

// Letters and digits that are not easy to mix up (no 0, o, 1 or l), so a password can be read out or typed from a screen.
const ALPHABET = 'abcdefghijkmnpqrstuvwxyz23456789';
const makePassword = () => Array.from({ length: 16 }, () => ALPHABET[randomInt(ALPHABET.length)]).join('');
const makePin = () => String(randomInt(1000, 10000));

async function api(method: string, path: string, token?: string, body?: unknown) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      'x-app': 'core_academy/1.6.0+8',
      'x-install-id': 'claude-test-accounts',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}
const must = (what: string, r: { status: number; body: any }, ok = [200, 201]) => {
  if (!ok.includes(r.status)) throw new Error(`${what}: ${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
};

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();
try {
  const saved = existsSync(FILE) ? JSON.parse(readFileSync(FILE, 'utf8')) : null;
  const fresh = reset || !saved;
  const teacher = { username: TUTOR.username, password: fresh ? makePassword() : (saved.teacher.password as string) };
  const student = { username: STUDENT.username, pin: fresh ? makePin() : (saved.student.pin as string) };

  const idOf = async (username: string) => (await db.query('select id from users where username = $1', [username])).rows[0]?.id as string | undefined;
  const setSecret = async (id: string, secret: string) => {
    const { hash, salt } = await hashSecret(secret);
    await db.query('update users set secret_hash = $2, secret_salt = $3, failed_count = 0, locked_until = null, active = true where id = $1', [id, hash, salt]);
  };

  // The tutor, then a tuition of their own.
  let tutorId = await idOf(teacher.username);
  if (!tutorId) {
    tutorId = must('sign up the tutor', await api('POST', '/auth/signup-tutor', undefined, { display_name: TUTOR.display_name, username: teacher.username, password: teacher.password })).user.id;
    console.log(`made the tutor ${teacher.username}`);
  } else if (fresh) {
    await setSecret(tutorId, teacher.password);
    console.log(`gave the tutor ${teacher.username} a new password`);
  }
  const token = must('the tutor signs in', await api('POST', '/auth/login', undefined, { username: teacher.username, secret: teacher.password })).token as string;
  let tuitionId = (await db.query(`select t.id from memberships m join tuitions t on t.id = m.tuition_id where m.user_id = $1 and m.role = 'owner' order by m.joined_at limit 1`, [tutorId])).rows[0]?.id as string | undefined;
  if (!tuitionId) {
    tuitionId = must('make the tuition', await api('POST', '/auth/tuitions', token, { name: TUITION, groups: [{ class_level: STUDENT.class_level, subject_id: MATHS }] })).tuition.id;
    console.log(`made the tuition "${TUITION}"`);
  }

  // The student, in that tuition.
  const studentId = await idOf(student.username);
  if (!studentId) {
    must('add the student', await api('POST', '/teacher/students', token, { display_name: STUDENT.display_name, class_level: STUDENT.class_level, username: student.username, pin: student.pin, subject_ids: [MATHS] }));
    console.log(`made the student ${student.username}`);
  } else if (fresh) {
    await setSecret(studentId, student.pin);
    console.log(`gave the student ${student.username} a new PIN`);
  }

  writeFileSync(
    FILE,
    JSON.stringify(
      {
        note: `Claude's own test logins on the ${branch} branch, in their own tuition. Not the real ones. Made and managed by tools/test-accounts.ts.`,
        branch,
        tuition: { id: tuitionId, name: TUITION },
        teacher,
        student,
      },
      null,
      2,
    ) + '\n',
  );

  // They work, and they stay inside their own tuition.
  const t = await api('POST', '/auth/login', undefined, { username: teacher.username, secret: teacher.password });
  check('the tutor signs in', t.status === 200, t.status);
  const s = await api('POST', '/auth/login', undefined, { username: student.username, secret: student.pin });
  check('the student signs in', s.status === 200, s.status);
  const mine = await api('GET', '/teacher/students', t.body?.token);
  check('the tutor sees exactly one student, the test one', mine.status === 200 && mine.body.students.length === 1 && mine.body.students[0].username === student.username, mine.body?.students?.length);
  const tutors = await api('GET', '/teacher/tutors', t.body?.token);
  check('and is the only tutor of their tuition', tutors.status === 200 && tutors.body.tutors.length === 1 && tutors.body.tutors[0].owner === true, tutors.body?.tutors?.length);
  const home = await api('GET', '/student/home', s.body?.token);
  check('the student reaches their home', home.status === 200, home.status);

  // The dev sample tuition cannot see them.
  const samples = existsSync(`tools/out/sample-logins.${branch}.json`) ? JSON.parse(readFileSync(`tools/out/sample-logins.${branch}.json`, 'utf8')) : null;
  if (samples) {
    const o = await api('POST', '/auth/login', undefined, { username: samples.teacher.username, secret: samples.teacher.password });
    const theirStudents = await api('GET', '/teacher/students', o.body?.token);
    const theirTutors = await api('GET', '/teacher/tutors', o.body?.token);
    check(
      'the dev sample tuition lists neither of them',
      theirStudents.status === 200 && theirTutors.status === 200 &&
        !theirStudents.body.students.some((x: any) => x.username === student.username) &&
        !theirTutors.body.tutors.some((x: any) => x.username === teacher.username),
    );
  }
  console.log(`\nTest logins on ${branch}: tutor ${teacher.username}, student ${student.username}. Their passwords are in ${FILE}.`);
  console.log(`${pass} passed, ${fail} failed`);
} finally {
  await db.end();
}
process.exit(fail ? 1 : 0);
