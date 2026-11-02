// Reads the two physics sample pages (tools/out/lang/phys, built by phys-build.mjs, saved as page1.jpg and page2.jpg) through the dev API
// and checks what the page reader now gives back: a box for each figure and each question, and the question that runs over the page
// edge put together as one. Then takes the join apart and reads page 2 again. Real AI (Gemini), so a run uses a few free requests.
// Makes its own course and paper in the dev database through the API only, and removes them again. Dev only.
// Usage: node tools/pieces-live-test.ts [--env .env.local] [--base https://<dev api>]
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
const truth = JSON.parse(readFileSync('tools/out/lang/phys/truth.json', 'utf8'));
const APP = 'core_academy/1.8.0+10';

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

async function api(method: string, path: string, token: string, body?: unknown, timeout = 60_000) {
  const res = await fetch(BASE + path, {
    method,
    headers: { authorization: `Bearer ${token}`, 'x-app': APP, ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(timeout),
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}

type Box = [number, number, number, number];
const iou = (a: Box, b: Box) => {
  const w = Math.max(0, Math.min(a[2], b[2]) - Math.max(a[0], b[0]));
  const h = Math.max(0, Math.min(a[3], b[3]) - Math.max(a[1], b[1]));
  const inter = w * h;
  return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter);
};

const tag = `pieces${Date.now().toString(36)}`;
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
  check('a course is made to hold the paper', course.status === 201, course.body);
  const C = course.body.course.id as string;
  made.courses.push(C);

  const pages = [readFileSync('tools/out/lang/phys/page1.jpg'), readFileSync('tools/out/lang/phys/page2.jpg')];
  const made1 = await api('POST', '/teacher/papers', T, { pages: 2, sizes: pages.map((p) => p.length), course_id: C, exam_name: `${tag} physics` });
  check('the paper is started', made1.status === 201, made1.body);
  const P = made1.body.paper.id as string;
  made.papers.push(P);
  for (const u of made1.body.uploads as { page_no: number; put_url: string }[]) {
    const put = await fetch(u.put_url, { method: 'PUT', headers: { 'content-type': 'image/jpeg' }, body: pages[u.page_no - 1] });
    check(`page ${u.page_no} is uploaded`, put.status < 300, put.status);
    await api('POST', `/teacher/papers/${P}/pages/${u.page_no}/uploaded`, T);
  }

  // ---------------------------------------------------------------- both pages read at once, as the app does it
  const t0 = Date.now();
  const reads = await Promise.all([1, 2].map((n) => api('POST', `/teacher/papers/${P}/pages/${n}/read`, T, undefined, 180_000)));
  console.log(`      both pages read in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  check('both pages are read', reads.every((r) => r.status === 200), reads.map((r) => [r.status, r.body?.error ?? null]));

  const load = async () => (await api('GET', `/teacher/papers/${P}`, T)).body.drafts as any[];
  let drafts = (await load()).filter((d) => d.status !== 'discarded');
  console.log('      drafts:', drafts.map((d) => `p${d.page_no} Q${d.number_label ?? '-'} ${d.kind}${d.joined ? ' joined' : ''}${d.cont_next ? ' cont_next' : ''}${d.cont_prev ? ' cont_prev' : ''}${d.needs_diagram ? ' figure' : ''}`).join(' | '));
  check('the paper holds six questions (the cut one counted once)', drafts.length === 6, drafts.length);
  check('no loose rest-of-a-question is left', !drafts.some((d) => d.cont_prev), drafts.filter((d) => d.cont_prev).map((d) => d.text));

  // ---------------------------------------------------------------- the question that ran over the page edge
  const joined = drafts.find((d) => d.joined);
  check('one question was joined from two pages', !!joined, drafts.map((d) => d.number_label));
  if (joined) {
    check('it is multiple choice with four options', joined.kind === 'mcq' && joined.options.length === 4, [joined.kind, joined.options]);
    check('it starts on page 1 and keeps its number', joined.page_no === 1 && String(joined.number_label).includes('4'), [joined.page_no, joined.number_label]);
    check('it is no longer cut', joined.cont_next === false && joined.cont_prev === false, [joined.cont_next, joined.cont_prev]);
    check('it holds the picture of both parts', Array.isArray(joined.question_boxes) && joined.question_boxes.map((b: any) => b.page).join() === '1,2', joined.question_boxes);
    check('it can be undone', !!joined.joined_from?.part, Object.keys(joined.joined_from ?? {}));
  }

  // ---------------------------------------------------------------- figures and question boxes
  const figs = drafts.filter((d) => d.needs_diagram);
  console.log('      figure questions:', figs.map((d) => `p${d.page_no} Q${d.number_label} box ${JSON.stringify(d.figure_box?.box)}`).join(' | '));
  check('three questions need a figure', figs.length === 3, figs.map((d) => d.number_label));
  check('each of them has a figure box on its own page', figs.every((d) => d.figure_box?.page === d.page_no && d.figure_box.box.length === 4), figs.map((d) => d.figure_box));
  const wanted: Record<string, Box> = { '1:2': truth.page1.fig2t, '1:3': truth.page1.fig3t, '2:5': truth.page2.fig5t };
  for (const d of figs) {
    const want = wanted[`${d.page_no}:${String(d.number_label).replace(/\D/g, '')}`];
    const v = want && d.figure_box ? iou(d.figure_box.box, want) : 0;
    check(`the figure box of Q${d.number_label} overlaps the drawing (${(v * 100).toFixed(0)} %)`, v >= 0.5, d.figure_box);
  }
  check('most questions know where they are on the page', drafts.filter((d) => d.question_boxes?.length).length >= 5, drafts.map((d) => !!d.question_boxes));
  check('a question with no figure has no figure box', drafts.filter((d) => !d.needs_diagram).every((d) => d.figure_box == null), drafts.map((d) => d.figure_box));

  // ---------------------------------------------------------------- the tutor undoes the join
  if (joined) {
    const undone = await api('POST', `/teacher/drafts/${joined.id}/unjoin`, T);
    check('the join can be undone', undone.status === 200 && undone.body.drafts.length === 2, undone.body);
    drafts = (await load()).filter((d) => d.status !== 'discarded');
    check('there are seven questions again', drafts.length === 7, drafts.length);
    const first = drafts.find((d) => d.id === joined.id);
    check('the first part is cut again, as it was', first?.joined === false && first.cont_next === true && first.options.length < 4, [first?.joined, first?.cont_next, first?.options]);
    const rest = drafts.find((d) => d.cont_prev);
    check('the rest is a question of its own on page 2, kept apart', rest?.page_no === 2 && rest.keep_apart === true, rest);
    const again = await api('POST', `/teacher/drafts/${joined.id}/unjoin`, T);
    check('a question that is not joined cannot be undone', again.status === 409, again);
    await api('POST', `/teacher/papers/${P}/answers`, T, undefined, 120_000);
    drafts = (await load()).filter((d) => d.status !== 'discarded');
    check('the next pass does not join them again', drafts.length === 7 && !drafts.some((d) => d.joined), drafts.map((d) => [d.number_label, d.joined]));

    // reading page 2 again starts from what the page says, so the two can join again
    const reread = await api('POST', `/teacher/papers/${P}/pages/2/read`, T, undefined, 180_000);
    check('page 2 is read again', reread.status === 200, reread.body);
    drafts = (await load()).filter((d) => d.status !== 'discarded');
    console.log('      after reading page 2 again:', drafts.map((d) => `p${d.page_no} Q${d.number_label ?? '-'}${d.joined ? ' joined' : ''}${d.cont_prev ? ' cont_prev' : ''}`).join(' | '));
    check('and the question is whole again', drafts.length === 6 && drafts.some((d) => d.joined), drafts.length);
  }

  // ---------------------------------------------------------------- the figure box and the cut flags can be set
  const any = drafts.find((d) => d.needs_diagram) ?? drafts[0];
  const bad = await api('PATCH', `/teacher/drafts/${any.id}`, T, { figure_box: { page: 1, box: [0.5, 0.5, 0.5, 0.5] } });
  check('a figure box with no size is refused', bad.status === 400, bad);
  const worse = await api('PATCH', `/teacher/drafts/${any.id}`, T, { figure_box: 'everything' });
  check('a figure box that is not a box is refused', worse.status === 400, worse);
  const good = await api('PATCH', `/teacher/drafts/${any.id}`, T, { figure_box: { page: any.page_no, box: [100, 200, 600, 500] } });
  check('a figure box is kept (0 to 1000 is understood)', good.status === 200 && JSON.stringify(good.body.draft.figure_box?.box) === JSON.stringify([0.1, 0.2, 0.6, 0.5]), good.body?.draft?.figure_box);
  const gone = await api('PATCH', `/teacher/drafts/${any.id}`, T, { figure_box: null });
  check('a figure box of null forgets it', gone.status === 200 && gone.body.draft.figure_box === null, gone.body?.draft?.figure_box);
  const cut = drafts.find((d) => d.joined) ?? any;
  const fixed = await api('PATCH', `/teacher/drafts/${cut.id}`, T, { text: `${cut.text} (fixed)` });
  check('fixing the words clears the cut flags', fixed.status === 200 && fixed.body.draft.cont_next === false && fixed.body.draft.cont_prev === false, fixed.body?.draft);
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
