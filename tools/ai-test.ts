// Runs the AI paper reader on the 2-page sample paper (tools/out/paper/page1.jpg, page2.jpg)
// through the real API and scores the drafts against what is actually printed.
// Usage: node tools/ai-test.ts [--base https://... | http://127.0.0.1:PORT] [--keep]
import { readFileSync } from 'node:fs';
import pg from 'pg';

process.loadEnvFile('.env.local');
const args = process.argv.slice(2);
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
const logins = JSON.parse(readFileSync(`tools/out/sample-logins.${process.env.NEON_BRANCH}.json`, 'utf8'));

// What the sample paper prints (design/comps/paper/sample.html).
const truth = [
  { n: '1', kind: 'mcq', options: ['1', '2', '3', '4'], diagram: false, chapter: 'Real Numbers' },
  { n: '2', kind: 'mcq', options: ['1', '-1', '2', '-2'], diagram: false, chapter: 'Polynomials' },
  { n: '3', kind: 'mcq', options: ['3', '-3', '5/3', '9'], diagram: false, chapter: 'Quadratic Equations' },
  { n: '4', kind: 'mcq', options: ['1', '1/3', '3', '4/3'], diagram: false, chapter: 'Arithmetic Progressions' },
  { n: '5', kind: 'other', options: [], diagram: false, chapter: null },
  { n: '6', kind: 'mcq', options: ['2cm', '3cm', '4cm', '6.75cm'], diagram: true, chapter: null },
  { n: '7', kind: 'mcq', options: ['3', '4', '5', '7'], diagram: false, chapter: null },
  { n: '8', kind: 'mcq', options: ['0', '1', '2', 'tantheta'], diagram: false, chapter: null },
  { n: '9', kind: 'other', options: [], diagram: false, chapter: 'Real Numbers' },
];

// "$\frac{5}{3}$" -> "5/3", "$\tan \theta$" -> "tantheta", "6.75 cm" -> "6.75cm"
const norm = (s: string) =>
  s.replace(/\$/g, '').replace(/\\[dt]?frac\{([^}]*)\}\{([^}]*)\}/g, '$1/$2').replace(/\\text\{([^}]*)\}/g, '$1')
    .replace(/\\/g, '').replace(/[\s{}]/g, '').replace(/^\(?[a-d]\)\s*/i, '').toLowerCase();

async function api(method: string, path: string, token?: string, body?: unknown) {
  const res = await fetch(BASE + path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}

const T = (await api('POST', '/auth/login', undefined, { username: logins.teacher.username, secret: logins.teacher.password })).body.token;
const examName = args.includes('--name') ? args[args.indexOf('--name') + 1] : 'AI test paper';
const created = await api('POST', '/teacher/papers', T, { class_level: 10, exam_name: examName, pages: 2 });
if (created.status !== 201) throw new Error(`create paper: ${JSON.stringify(created.body)}`);
const paperId = created.body.paper.id;

for (const u of created.body.uploads) {
  const bytes = readFileSync(`tools/out/paper/page${u.page_no}.jpg`);
  const put = await fetch(u.put_url, { method: 'PUT', headers: { 'content-type': 'image/jpeg' }, body: bytes });
  if (!put.ok) throw new Error(`upload page ${u.page_no}: HTTP ${put.status} ${await put.text()}`);
  await api('POST', `/teacher/papers/${paperId}/pages/${u.page_no}/uploaded`, T);
}
console.log(`uploaded 2 pages to paper ${paperId}`);

const drafts: any[] = [];
for (const n of [1, 2]) {
  const t0 = Date.now();
  const r = await api('POST', `/teacher/papers/${paperId}/pages/${n}/read`, T);
  console.log(`page ${n}: HTTP ${r.status} in ${((Date.now() - t0) / 1000).toFixed(1)} s, ${r.body?.drafts?.length ?? 0} questions`);
  if (r.status !== 200) console.log('   ', JSON.stringify(r.body));
  else drafts.push(...r.body.drafts);
}

const detail = await api('GET', `/teacher/papers/${paperId}`, T);
const chapterName = new Map(detail.body.chapters.map((c: any) => [c.id, c.name]));
let fieldsOk = 0;
let fields = 0;
for (const want of truth) {
  const got = drafts.find((d) => String(d.number_label ?? '').replace(/\D/g, '') === want.n);
  const checks: [string, boolean][] = [
    ['found', !!got],
    ['kind', got?.kind === want.kind],
    ['options', JSON.stringify((got?.options ?? []).map(norm)) === JSON.stringify(want.options)],
    ['diagram', (got?.needs_diagram ?? false) === want.diagram],
  ];
  if (want.chapter) checks.push(['chapter', chapterName.get(got?.chapter_id) === want.chapter]);
  fields += checks.length;
  fieldsOk += checks.filter(([, ok]) => ok).length;
  const bad = checks.filter(([, ok]) => !ok).map(([k]) => k);
  console.log(`Q${want.n}: ${bad.length ? 'MISMATCH ' + bad.join(', ') : 'ok'}${got ? '' : ''}`);
  if (bad.length && got) console.log(`    got kind=${got.kind} options=${JSON.stringify(got.options)} diagram=${got.needs_diagram} chapter=${chapterName.get(got.chapter_id) ?? got.ai_chapter_guess}`);
  if (got) console.log(`    text: ${got.text.slice(0, 110)}`);
}
console.log(`\nmatch: ${fieldsOk}/${fields} fields (${Math.round((100 * fieldsOk) / fields)}%), ${drafts.length} drafts for ${truth.length} printed questions`);

// AI must never pre-mark answers.
console.log(`answers pre-marked by AI: ${drafts.filter((d) => d.correct_option !== null).length} (must be 0)`);

if (!args.includes('--keep')) {
  const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
  await db.connect();
  await db.query('delete from questions where paper_id = $1', [paperId]);
  await db.end();
  await api('DELETE', `/teacher/papers/${paperId}`, T);
  console.log('test paper removed');
}
