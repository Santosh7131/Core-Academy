// Checks the plan a paper carries when it is made as one of several tests at once (migration 023, app 1.8.0): the day and times
// the tutor chose, kept on the paper so posting it later opens the test as planned. Makes its own course and papers in the dev
// database through the API only (no database port needed), and removes them again. Dev only.
// Usage: node tools/plan-test.ts [--env .env.local] [--base https://<dev api>]
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error(`No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in ${envFile}).`);
if (process.env.NEON_BRANCH !== 'dev') throw new Error(`This only runs against the dev branch (${envFile} says ${process.env.NEON_BRANCH}).`);
const root: any = await fetch(`${BASE}/`).then((r) => r.json());
if (root.branch !== 'dev') throw new Error(`The API at ${BASE} says it is branch ${root.branch}, not dev.`);
const logins = JSON.parse(readFileSync('tools/out/claude-test-logins.dev.json', 'utf8'));
const APP = 'core_academy/1.8.0+10';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

async function api(method: string, path: string, token: string, body?: unknown) {
  const res = await fetch(BASE + path, {
    method,
    headers: { authorization: `Bearer ${token}`, 'x-app': APP, ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60_000),
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}

const tag = `plan${Date.now().toString(36)}`;
const at = (days: number, hour: number) => {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + days);
  d.setUTCHours(hour, 0, 0, 0);
  return d.toISOString();
};
const made = { papers: [] as string[], courses: [] as string[] };
let T = '';

try {
  const login = await fetch(`${BASE}/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ username: logins.teacher.username, secret: logins.teacher.password }),
  }).then((r) => r.json() as Promise<any>);
  T = login.token as string;
  check('the tutor logs in', !!T, login.error ?? login);

  const course = await api('POST', '/teacher/courses', T, { name: `${tag} course` });
  check('a course is made to hold the papers', course.status === 201, course.body);
  const C = course.body.course.id as string;
  made.courses.push(C);

  const make = async (body: Record<string, unknown>) => {
    const r = await api('POST', '/teacher/papers', T, { pages: 1, course_id: C, ...body });
    if (r.status === 201) made.papers.push(r.body.paper.id);
    return r;
  };

  // ---------------------------------------------------------------- a paper made with a plan
  const opens = at(2, 3), closes = at(2, 15);
  const withPlan = await make({ exam_name: `${tag} A`, plan: { opens_at: opens, closes_at: closes, time_limit_min: 45, shuffle: false } });
  check('a paper is made with its plan', withPlan.status === 201, withPlan.body);
  const A = withPlan.body?.paper?.id as string;
  check('the reply carries the plan as sent', withPlan.body?.paper?.plan?.time_limit_min === 45 && withPlan.body.paper.plan.shuffle === false
    && withPlan.body.paper.plan.opens_at === opens && withPlan.body.paper.plan.closes_at === closes, withPlan.body?.paper?.plan);
  const got = await api('GET', `/teacher/papers/${A}`, T);
  check('the paper page carries its plan', got.status === 200 && got.body.paper.plan?.closes_at === closes && got.body.paper.plan.time_limit_min === 45, got.body?.paper?.plan);

  // ---------------------------------------------------------------- the plan's defaults
  const bare = await make({ exam_name: `${tag} B`, plan: { closes_at: closes } });
  check('a plan with only a closing time is kept', bare.status === 201, bare.body);
  const bp = bare.body?.paper?.plan;
  check('it opens at once, has no time limit of its own and shuffles', bp?.opens_at === null && bp?.time_limit_min === null && bp?.shuffle === true, bp);

  const none = await make({ exam_name: `${tag} C` });
  check('a paper with no plan has none (every paper made before this)', none.status === 201 && none.body.paper.plan === null, none.body?.paper);

  const cleared = await make({ exam_name: `${tag} D`, plan: null });
  check('a plan of null is no plan', cleared.status === 201 && cleared.body.paper.plan === null, cleared.body?.paper);

  // ---------------------------------------------------------------- what is refused
  const refuse = async (name: string, plan: unknown) => {
    const r = await api('POST', '/teacher/papers', T, { pages: 1, course_id: C, exam_name: `${tag} refused`, plan });
    if (r.status === 201) made.papers.push(r.body.paper.id);
    check(name, r.status === 400, { status: r.status, body: r.body });
  };
  await refuse('no closing time is refused', { opens_at: opens });
  await refuse('opening after closing is refused', { opens_at: closes, closes_at: opens });
  await refuse('opening when it closes is refused', { opens_at: closes, closes_at: closes });
  await refuse('a plan that is a word is refused', 'tomorrow');
  await refuse('a plan that is a list is refused', [closes]);
  await refuse('a time limit of nothing is refused', { closes_at: closes, time_limit_min: 0 });
  await refuse('a time limit past five hours is refused', { closes_at: closes, time_limit_min: 301 });
  await refuse('a time limit with a fraction is refused', { closes_at: closes, time_limit_min: 7.5 });
  await refuse('a closing time that is not a date is refused', { closes_at: 'banana' });
  await refuse('shuffle that is not true or false is refused', { closes_at: closes, shuffle: 'yes' });

  // ---------------------------------------------------------------- changing it
  const changed = await api('PATCH', `/teacher/papers/${A}`, T, { plan: { opens_at: null, closes_at: at(3, 15), time_limit_min: 30, shuffle: true } });
  check('the plan can be changed', changed.status === 200 && changed.body.paper.plan.time_limit_min === 30 && changed.body.paper.plan.opens_at === null, changed.body);
  const renamed = await api('PATCH', `/teacher/papers/${A}`, T, { exam_name: `${tag} A renamed` });
  check('renaming the paper keeps its plan', renamed.status === 200 && renamed.body.paper.plan?.time_limit_min === 30 && renamed.body.paper.exam_name === `${tag} A renamed`, renamed.body);
  const bad = await api('PATCH', `/teacher/papers/${A}`, T, { plan: { closes_at: 'never' } });
  check('a bad plan is refused', bad.status === 400, { status: bad.status, body: bad.body });
  const still = await api('GET', `/teacher/papers/${A}`, T);
  check('and the plan stays as it was', still.body.paper.plan?.time_limit_min === 30, still.body?.paper?.plan);
  const gone = await api('PATCH', `/teacher/papers/${A}`, T, { plan: null });
  check('a plan of null takes it away', gone.status === 200 && gone.body.paper.plan === null, gone.body);

  // ---------------------------------------------------------------- the lists still work
  const list = await api('GET', `/teacher/papers?course=${C}`, T);
  check('the course lists its papers', list.status === 200 && list.body.papers.length >= 4, list.body?.papers?.length);
} catch (e) {
  fail++;
  console.log(`FAIL  the run stopped: ${(e as Error).message}`);
} finally {
  if (T) {
    for (const id of made.papers) await api('DELETE', `/teacher/papers/${id}`, T).catch(() => {});
    for (const id of made.courses) await api('DELETE', `/teacher/courses/${id}`, T).catch(() => {});
  }
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
