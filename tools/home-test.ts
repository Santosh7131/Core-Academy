// Checks the two lists the simpler tutor Home (app 1.8.0) asks for on top of what Home always had: the tests that finished lately
// ("finished") and the papers the tutor started and has not finished ("papers"). An app before 1.8.0 is sent neither. Makes its own
// course, questions, tests and papers in the dev database, and removes them again. Dev only.
// Usage: node tools/home-test.ts [--env .env.local] [--base http://127.0.0.1:8787]
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
const OLD = 'core_academy/1.7.0+9';
const NEW = 'core_academy/1.8.0+10';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

async function api(method: string, path: string, token: string, body?: unknown, app: string | null = NEW) {
  const res = await fetch(BASE + path, {
    method,
    headers: { authorization: `Bearer ${token}`, ...(app ? { 'x-app': app } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60_000),
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();
const tag = `homet${Date.now().toString(36)}`;
const iso = (ms: number) => new Date(Date.now() + ms).toISOString();
const created = { tests: [] as string[], questions: [] as string[], papers: [] as string[], courses: [] as string[] };

try {
  const login = await fetch(`${BASE}/auth/login`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: logins.teacher.username, secret: logins.teacher.password }),
  }).then((r) => r.json() as Promise<any>);
  const T = login.token as string;
  check('the tutor logs in', !!T, login);

  // ---------------------------------------------------------------- who gets the lists
  const old = await api('GET', '/teacher/home', T, undefined, OLD);
  check('an app before 1.8.0 is sent neither list', old.status === 200 && old.body.finished === undefined && old.body.papers === undefined, Object.keys(old.body ?? {}));
  const none = await api('GET', '/teacher/home', T, undefined, null);
  check('nor is a caller that says nothing about itself', none.status === 200 && none.body.finished === undefined && none.body.papers === undefined, Object.keys(none.body ?? {}));
  const home0 = await api('GET', '/teacher/home', T);
  check('app 1.8.0 is sent both', home0.status === 200 && Array.isArray(home0.body.finished) && Array.isArray(home0.body.papers), Object.keys(home0.body ?? {}));
  const later = await api('GET', '/teacher/home', T, undefined, 'core_academy/1.9.2+14');
  check('and so is a later app', later.status === 200 && Array.isArray(later.body.finished) && Array.isArray(later.body.papers));
  const tuition = home0.body.tuition.id as string;

  // ---------------------------------------------------------------- tests
  const mkQ = async (n: number) => {
    const r = await api('POST', '/teacher/questions', T, { class_level: 9, text: `${tag} question ${n} $${n}+1$?`, options: ['1', '2', '3', '4'], correct_option: 1, subject_id: MATHS });
    created.questions.push(r.body.id);
    return r.body.id as string;
  };
  const q1 = await mkQ(1);
  const course = await api('POST', '/teacher/courses', T, { name: `${tag} Spoken English` });
  check('a course is made', course.status === 201, course.body);
  const C = course.body.course.id as string;
  created.courses.push(C);
  const cq = await db.query(
    `insert into questions (tuition_id, text, options, correct_option, source, course_id, keep_option_order) values ($1, $2, $3, 0, 'manual', $4, false) returning id`,
    [tuition, `${tag} Which word is a verb: run, red, rock, rain?`, ['run', 'red', 'rock', 'rain'], C],
  );
  const cqId = cq.rows[0].id as string;
  created.questions.push(cqId);

  const groupTest = async (title: string, extra: Record<string, unknown> = {}, publish = true) => {
    const r = await api('POST', '/teacher/tests', T, {
      title: `${tag} ${title}`, class_level: 9, subject_id: MATHS, question_ids: [q1], shuffle: false, assign_all: false, assign_group: true, closes_at: iso(86_400_000), ...extra,
    });
    if (r.status !== 201) throw new Error(`could not make ${title}: ${JSON.stringify(r.body)}`);
    created.tests.push(r.body.id);
    if (publish) await api('POST', `/teacher/tests/${r.body.id}/publish`, T, { published: true });
    return r.body.id as string;
  };
  const closeAgo = (id: string, hours: number) => db.query(`update tests set closes_at = now() - make_interval(hours => $2) where id = $1`, [id, hours]);

  const gOpen = await groupTest('open');
  const gPosted = await groupTest('posted', { opens_at: iso(2 * 3_600_000) });
  const gDraft = await groupTest('draft', {}, false);
  const gDone = await groupTest('done one hour ago');
  await closeAgo(gDone, 1);
  const cTest = await api('POST', '/teacher/tests', T, { title: `${tag} course quiz`, course_id: C, question_ids: [cqId], shuffle: false, closes_at: iso(86_400_000) });
  check('the course gets a test', cTest.status === 201, cTest.body);
  const cDone = cTest.body.id as string;
  created.tests.push(cDone);
  await api('POST', `/teacher/tests/${cDone}/publish`, T, { published: true });

  const h1 = (await api('GET', '/teacher/home', T)).body;
  const ids = (list: any[]) => list.map((x) => x.id);
  const group = h1.groups.find((g: any) => g.class_level === 9 && g.subject_id === MATHS);
  check('an open test is under Open now and not among the finished', ids(group.live).includes(gOpen) && !ids(h1.finished).includes(gOpen));
  check('a posted test is under Coming up and not among the finished', ids(group.posted).includes(gPosted) && !ids(h1.finished).includes(gPosted));
  check('a draft is in neither', !ids(group.live).includes(gDraft) && !ids(group.posted).includes(gDraft) && !ids(h1.finished).includes(gDraft));
  check('a test past its closing time is finished, and no longer open', ids(h1.finished).includes(gDone) && !ids(group.live).includes(gDone) && !ids(group.posted).includes(gDone));
  const row = h1.finished.find((x: any) => x.id === gDone);
  check('a finished test says its name, its class and subject, and how many handed it in', row.title === `${tag} done one hour ago` && row.class_level === 9 && row.subject_id === MATHS
    && row.subject === 'Maths' && row.course_id === null && row.course === null && typeof row.submitted === 'number' && typeof row.assigned === 'number', row);

  await closeAgo(cDone, 2);
  const h2 = (await api('GET', '/teacher/home', T)).body;
  const crow = h2.finished.find((x: any) => x.id === cDone);
  check('a course\'s finished test is listed too, with its course and no class', !!crow && crow.course_id === C && crow.course === `${tag} Spoken English` && crow.class_level === null && crow.subject === null, crow);
  const order = ids(h2.finished);
  check('the newest finished test comes first', order.indexOf(gDone) !== -1 && order.indexOf(cDone) !== -1 && order.indexOf(gDone) < order.indexOf(cDone), order);
  const courseCard = h2.courses.find((c: any) => c.id === C);
  check('and it has left its course\'s open tests', courseCard && !ids(courseCard.live).includes(cDone) && !ids(courseCard.posted).includes(cDone), courseCard);

  // More than five finished tests: only the five most recent are sent.
  for (let i = 0; i < 5; i++) {
    const id = await groupTest(`older ${i}`);
    await closeAgo(id, 3 + i);
  }
  const h3 = (await api('GET', '/teacher/home', T)).body;
  check('only the five most recent finished tests are sent', h3.finished.length === 5, h3.finished.length);
  const closes = h3.finished.map((x: any) => new Date(x.closes_at).getTime());
  check('newest first', closes.every((t: number, i: number) => i === 0 || closes[i - 1] >= t), closes);
  check('the old ones keep their count of students and hand-ins', h3.finished.every((x: any) => Number.isFinite(x.assigned) && Number.isFinite(x.submitted) && Number.isFinite(x.writing)));

  // ---------------------------------------------------------------- papers
  const mkPaper = async (name: string, opts: { course?: string; pages: number; read: number; ago?: string }) => {
    const p = await db.query(
      `insert into papers (tuition_id, class_level, subject_id, course_id, exam_name, page_count, created_at)
       values ($1, $2, $3, $4, $5, $6, now() - $7::interval) returning id`,
      [tuition, opts.course ? null : 9, opts.course ? null : MATHS, opts.course ?? null, `${tag} ${name}`, opts.pages, opts.ago ?? '1 hour'],
    );
    const id = p.rows[0].id as string;
    created.papers.push(id);
    for (let n = 1; n <= opts.pages; n++) {
      await db.query(`insert into paper_pages (paper_id, page_no, object_key, uploaded, ai_status) values ($1, $2, $3, true, $4)`, [id, n, `${tag}/${id}/${n}`, n <= opts.read ? 'done' : 'pending']);
    }
    return id;
  };
  const draft = (paper: string, seq: number, status: string) =>
    db.query(
      `insert into paper_drafts (paper_id, page_no, seq, number_label, kind, text, options, correct_option, status, answer_checked)
       values ($1, 1, $2, $3, 'mcq', $4, $5, 1, $6, true)`,
      [paper, seq, String(seq + 1), `${tag} q${seq}`, ['a', 'b', 'c', 'd'], status],
    );
  const pUnread = await mkPaper('two pages, one read', { pages: 2, read: 1 });
  const pCheck = await mkPaper('questions to check', { pages: 1, read: 1 });
  await draft(pCheck, 0, 'draft');
  await draft(pCheck, 1, 'saved');
  const pSaved = await mkPaper('saved, no test yet', { pages: 1, read: 1 });
  await draft(pSaved, 0, 'saved');
  const pMade = await mkPaper('saved and made into a test', { pages: 1, read: 1 });
  await draft(pMade, 0, 'saved');
  await db.query(`update tests set paper_id = $2 where id = $1`, [gOpen, pMade]);
  const pSkipped = await mkPaper('every question skipped', { pages: 1, read: 1 });
  await draft(pSkipped, 0, 'discarded');
  const pOld = await mkPaper('left a long time ago', { pages: 1, read: 1, ago: '40 days' });
  await draft(pOld, 0, 'draft');
  const pCourse = await mkPaper('for the course', { course: C, pages: 1, read: 1 });
  await draft(pCourse, 0, 'draft');
  const pEmpty = await mkPaper('nothing on it', { pages: 1, read: 1 });

  const h4 = (await api('GET', '/teacher/home', T)).body;
  const listed = ids(h4.papers);
  check('a paper with a page not read is listed', listed.includes(pUnread));
  check('a paper with questions to check is listed', listed.includes(pCheck));
  check('a paper saved but with no test made from it is listed', listed.includes(pSaved));
  check('a paper a test was made from is not', !listed.includes(pMade));
  check('a paper with every question skipped is not', !listed.includes(pSkipped));
  check('a paper with nothing on it is not', !listed.includes(pEmpty));
  check('a paper left over a month ago is not', !listed.includes(pOld));
  check('a course\'s paper is listed', listed.includes(pCourse));
  const mine = h4.papers.filter((p: any) => String(p.exam_name).startsWith(tag));
  check('newest first', mine.every((p: any, i: number) => i === 0 || new Date(mine[i - 1].created_at) >= new Date(p.created_at)));
  const a = h4.papers.find((p: any) => p.id === pUnread);
  check('a paper says its name, its group, how many pages it has and has read', a.exam_name === `${tag} two pages, one read` && a.class_level === 9 && a.subject === 'Maths' && a.course_id === null
    && a.page_count === 2 && a.pages_read === 1 && a.to_check === 0 && a.saved === 0 && a.has_test === false, a);
  const b = h4.papers.find((p: any) => p.id === pCheck);
  check('and how many questions are to check and how many are saved', b.to_check === 1 && b.saved === 1, b);
  const c = h4.papers.find((p: any) => p.id === pCourse);
  check('a course\'s paper names its course and has no class', c.course === `${tag} Spoken English` && c.class_level === null && c.subject === null, c);

  const page = await api('GET', `/teacher/papers/${pCheck}`, T);
  check('a listed paper opens', page.status === 200 && page.body.paper.id === pCheck && page.body.drafts.length === 2, page.body);

  // The other apps' Home is unchanged by all this.
  const h5 = (await api('GET', '/teacher/home', T, undefined, OLD)).body;
  check('an old app still gets groups, totals and courses as before', Array.isArray(h5.groups) && h5.totals && h5.finished === undefined, Object.keys(h5));
} finally {
  for (const id of created.tests) await db.query(`delete from tests where id = $1`, [id]).catch((e) => console.log('cleanup', e.message));
  for (const id of created.papers) await db.query(`delete from papers where id = $1`, [id]).catch((e) => console.log('cleanup', e.message));
  for (const id of created.questions) await db.query(`delete from questions where id = $1`, [id]).catch((e) => console.log('cleanup', e.message));
  for (const id of created.courses) await db.query(`delete from courses where id = $1`, [id]).catch((e) => console.log('cleanup', e.message));
  await db.end();
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
