// Checks classes 1 to 12 and the levels a tuition names itself (LKG, "NEET 2027"): who can use them,
// what students are told, that tuitions cannot use each other's, and the limits.
// Needs the API (the deployed dev branch by default). Makes its own tutors, tuitions and students and
// removes them again.
// Usage: node tools/levels-test.ts [--env .env.local] [--base http://127.0.0.1:8787]
import { randomInt } from 'node:crypto';
import pg from 'pg';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error(`No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in ${envFile}).`);
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
const code = (r: { body: any }) => r.body?.error?.code;
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();

const tag = `lvl${randomInt(1000, 9999)}`;
const created = { users: [] as string[], tuitions: [] as string[], questions: [] as string[], tests: [] as string[] };
const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();

try {
  // ------------------------------------------------------------------ a tuition that starts with Class 3, 12 and a level of its own
  const su = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Level Tutor', username: `${tag}.p`, password: 'longenough1' }, { 'x-install-id': `${tag}-p` });
  check('a tutor signs up', su.status === 201, su.body);
  created.users.push(su.body.user.id);
  const TP = su.body.token as string;

  const bad0 = await api('POST', '/auth/tuitions', TP, { name: `${tag} bad`, groups: [{ class_level: 13, subject_id: MATHS }] });
  check('a new tuition cannot start with a class that does not exist', bad0.status === 400, bad0.body);
  const bad1 = await api('POST', '/auth/tuitions', TP, { name: `${tag} bad`, groups: [{ class_level: 0, subject_id: MATHS }] });
  check('nor with class 0', bad1.status === 400, bad1.body);
  const mk = await api('POST', '/auth/tuitions', TP, {
    name: `${tag} Tuition P`,
    groups: [{ class_level: 3, subject_id: MATHS }, { level_name: 'LKG', subject_id: MATHS }, { class_level: 12, subject_id: MATHS }],
  });
  check('a tuition starts with Class 3, Class 12 and a level named LKG', mk.status === 201, mk.body);
  const P = mk.body.tuition.id as string;
  created.tuitions.push(P);

  const lv = await api('GET', '/teacher/levels', TP);
  check('the levels are Class 1 to 12 and then LKG', lv.status === 200 && lv.body.levels.length === 13
    && lv.body.levels.slice(0, 12).every((l: any, i: number) => l.code === i + 1 && l.label === `Class ${i + 1}` && l.custom === false)
    && lv.body.levels[12].code === 101 && lv.body.levels[12].label === 'LKG' && lv.body.levels[12].custom === true, lv.body);
  const home = await api('GET', '/teacher/home', TP);
  check('home lists the three groups in order', JSON.stringify(home.body.groups.map((g: any) => g.class_level)) === '[3,12,101]', home.body.groups);

  // ------------------------------------------------------------------ naming levels
  const neet = await api('POST', '/teacher/levels', TP, { label: '  NEET   2027 ' });
  check('a tutor names a level', neet.status === 201 && neet.body.level.code === 102 && neet.body.level.label === 'NEET 2027', neet.body);
  const again = await api('POST', '/teacher/levels', TP, { label: 'neet 2027' });
  check('naming it again gives the same level back', again.status === 201 && again.body.level.code === 102 && again.body.levels.length === 14, again.body);
  check('Class 5 is already there', code(await api('POST', '/teacher/levels', TP, { label: 'Class 5' })) === 'level_exists');
  check('and so is "std 12"', code(await api('POST', '/teacher/levels', TP, { label: 'std 12' })) === 'level_exists');
  check('a name is needed', (await api('POST', '/teacher/levels', TP, { label: '   ' })).status === 400);
  check('and it must be short', (await api('POST', '/teacher/levels', TP, { label: 'x'.repeat(31) })).status === 400);

  // ------------------------------------------------------------------ students and tests in a class or level
  const s3 = await api('POST', '/teacher/students', TP, { display_name: 'Third Class', class_level: 3, username: `${tag}.s3`, pin: '1111', subject_ids: [MATHS] });
  check('a student of Class 3 is added', s3.status === 201 && s3.body.student.class_level === 3, s3.body);
  created.users.push(s3.body.student.id);
  const sn = await api('POST', '/teacher/students', TP, { display_name: 'Neet Student', class_level: 102, username: `${tag}.sn`, pin: '2222', subject_ids: [MATHS] });
  check('a student of the named level is added', sn.status === 201 && sn.body.student.class_level === 102, sn.body);
  created.users.push(sn.body.student.id);
  for (const [n, cls] of [['class 0', 0], ['class 13', 13], ['class 100', 100], ['a level nobody named', 150], ['class 1000', 1000]] as const) {
    const r = await api('POST', '/teacher/students', TP, { display_name: 'Nobody', class_level: cls, username: `${tag}.x${cls}`, pin: '3333', subject_ids: [MATHS] });
    check(`a student of ${n} is refused`, r.status === 400, r.body);
  }

  const login = await api('POST', '/auth/login', undefined, { username: `${tag}.sn`, secret: '2222' });
  const mine = login.body?.tuitions?.find((t: any) => t.id === P);
  check('a student is told the names of the tuition\'s levels', login.status === 200 && mine?.class_level === 102
    && mine.levels.length === 2 && mine.levels.some((l: any) => l.code === 101 && l.label === 'LKG') && mine.levels.some((l: any) => l.code === 102 && l.label === 'NEET 2027'), login.body?.tuitions);
  const ST = login.body.token as string;
  const stu = await api('GET', '/student/tuitions', ST);
  check('and so is the student tuition list', stu.body?.tuitions?.[0]?.levels?.length === 2, stu.body);
  const me = await api('GET', '/auth/me', TP);
  check('a tutor is told them too', me.body?.tuitions?.[0]?.levels?.length === 2, me.body);

  const q = await api('POST', '/teacher/questions', TP, { class_level: 102, text: `${tag} question $2+2$?`, options: ['3', '4', '5', '6'], correct_option: 1, subject_id: MATHS });
  check('a question can be written for the named level', q.status === 201, q.body);
  created.questions.push(q.body.id);
  const test = await api('POST', '/teacher/tests', TP, {
    title: `${tag} NEET test`, class_level: 102, subject_id: MATHS, question_ids: [q.body.id], shuffle: false, assign_all: false, assign_group: true, closes_at: iso(86_400_000),
  });
  check('and a test', test.status === 201, test.body);
  created.tests.push(test.body.id);
  check('which can be posted', (await api('POST', `/teacher/tests/${test.body.id}/publish`, TP, { published: true })).status === 200);
  const seen = (await api('GET', '/student/home', ST)).body?.tests?.some((x: any) => x.id === test.body.id);
  check('the student of that level sees it', seen === true);
  const s3login = await api('POST', '/auth/login', undefined, { username: `${tag}.s3`, secret: '1111' });
  check('the student of Class 3 does not', (await api('GET', '/student/home', s3login.body.token)).body?.tests?.some((x: any) => x.id === test.body.id) === false);
  const badTest = await api('POST', '/teacher/tests', TP, { title: `${tag} bad`, class_level: 150, subject_id: MATHS, question_ids: [q.body.id], assign_all: false, assign_group: true, closes_at: iso(86_400_000) });
  check('a test for a level nobody named is refused', badTest.status === 400, badTest.body);
  const badQ = await api('POST', '/teacher/questions', TP, { class_level: 13, text: 'x', options: ['1', '2', '3', '4'], correct_option: 0, subject_id: MATHS });
  check('and so is a question', badQ.status === 400, badQ.body);

  // ------------------------------------------------------------------ groups
  const g102 = await api('GET', `/teacher/groups/102/${MATHS}`, TP);
  check('the group page opens for the named level', g102.status === 200 && g102.body.students.length === 1 && g102.body.tests.length === 1, g102.body);
  check('not for a level nobody named', (await api('GET', `/teacher/groups/150/${MATHS}`, TP)).status === 400);
  const g1 = await api('POST', '/teacher/groups', TP, { class_level: 1, subject_id: MATHS });
  check('a group can be started for Class 1', g1.status === 201, g1.body);
  check('and removed again', (await api('DELETE', `/teacher/groups/1/${MATHS}`, TP)).status === 200);
  check('an empty named level\'s group can be removed too', (await api('DELETE', `/teacher/groups/101/${MATHS}`, TP)).status === 200);

  // ------------------------------------------------------------------ another tuition cannot use these
  const su2 = await api('POST', '/auth/signup-tutor', undefined, { display_name: 'Other Tutor', username: `${tag}.q`, password: 'longenough1' }, { 'x-install-id': `${tag}-q` });
  created.users.push(su2.body.user.id);
  const TQ = su2.body.token as string;
  const mk2 = await api('POST', '/auth/tuitions', TQ, { name: `${tag} Tuition Q`, groups: [{ class_level: 5, subject_id: MATHS }] });
  created.tuitions.push(mk2.body.tuition.id);
  check('another tuition starts with only Class 1 to 12', (await api('GET', '/teacher/levels', TQ)).body?.levels?.length === 12);
  const steal = await api('POST', '/teacher/students', TQ, { display_name: 'Nobody', class_level: 102, username: `${tag}.y`, pin: '4444', subject_ids: [MATHS] });
  check('it cannot use a level another tuition named', steal.status === 400 && code(steal) === 'unknown_level', steal.body);
  check('nor open its group', (await api('GET', `/teacher/groups/102/${MATHS}`, TQ)).status === 400);
  const own = await api('POST', '/teacher/levels', TQ, { label: 'LKG' });
  check('it can name its own level LKG, with a number of its own', own.status === 201 && own.body.level.code === 101, own.body);
  check('the first tuition\'s levels are unchanged', (await api('GET', '/teacher/levels', TP)).body?.levels?.length === 14);
  check('a student cannot name levels', (await api('POST', '/teacher/levels', ST, { label: 'Sneaky' })).status === 403);

  // ------------------------------------------------------------------ renaming and removing
  const ren = await api('PATCH', '/teacher/levels/102', TP, { label: 'NEET 2028' });
  check('a named level can be renamed', ren.status === 200 && ren.body.levels.some((l: any) => l.code === 102 && l.label === 'NEET 2028'), ren.body);
  check('not to a name it already has', (await api('PATCH', '/teacher/levels/102', TP, { label: 'lkg' })).status === 409);
  check('Class 5 cannot be renamed', code(await api('PATCH', '/teacher/levels/5', TP, { label: 'Fifth' })) === 'not_custom');
  const inUse = await api('DELETE', '/teacher/levels/102', TP);
  check('a level with students and tests cannot be removed', inUse.status === 409 && code(inUse) === 'level_in_use', inUse.body);
  check('LKG, which nothing uses, can', (await api('DELETE', '/teacher/levels/101', TP)).status === 200);
  check('Class 5 cannot be removed', code(await api('DELETE', '/teacher/levels/5', TP)) === 'not_custom');

  // ------------------------------------------------------------------ the limit
  let made = (await api('GET', '/teacher/levels', TP)).body.levels.filter((l: any) => l.custom).length;
  let last: { status: number; body: any } = { status: 201, body: null };
  for (let i = made; i < 21 && last.status === 201; i++) last = await api('POST', '/teacher/levels', TP, { label: `${tag} extra ${i}` });
  check('a tuition can name 20 levels and no more', last.status === 409 && code(last) === 'too_many_levels', last.body);
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
