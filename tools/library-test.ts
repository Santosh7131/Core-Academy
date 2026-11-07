// Checks the Library (app 1.8.0): a tutor puts PDFs and photos on the shelf of a group or a course, and its people read and download them.
// Covers sections, adding a file in one request and in parts (with the exact sizes storage must refuse to bend), resuming a half-sent file,
// what students can see and when, downloading under the file's own name, moving and renaming, every way a shelf can be thrown away, other
// tuitions, other roles, and a student who is not in the group. Everything goes through the deployed API (no database access), using
// Claude's own tutor and student and the dev sample tuition as "another tuition", and it removes what it made.
// Dev only. Usage: node tools/library-test.ts [--env .env.local] [--base https://...]
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : process.env.NEON_FUNCTION_API_BASE_URL ?? '').replace(/\/$/, '');
if (!BASE) throw new Error(`No API base URL (pass --base or set NEON_FUNCTION_API_BASE_URL in ${envFile}).`);
if (process.env.NEON_BRANCH !== 'dev') throw new Error(`This only runs against the dev branch (${envFile} says ${process.env.NEON_BRANCH}).`);
const root: any = await fetch(`${BASE}/`).then((r) => r.json());
if (root.branch !== 'dev') throw new Error(`The API at ${BASE} says it is branch ${root.branch}, not dev.`);
const mine = JSON.parse(readFileSync('tools/out/claude-test-logins.dev.json', 'utf8'));
const sample = JSON.parse(readFileSync('tools/out/sample-logins.dev.json', 'utf8'));
const MATHS = '00000000-0000-4000-8000-000000000001';
const APP = 'core_academy/1.8.0+10';
const MB = 1024 * 1024;

let pass = 0;
let fail = 0;
function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok || detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
}

async function api(method: string, path: string, token?: string, body?: unknown, app: string | null = APP) {
  const res = await fetch(BASE + path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(app ? { 'x-app': app } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60_000),
  });
  return { status: res.status, body: (await res.json().catch(() => null)) as any };
}
const code = (r: { body: any }) => r.body?.error?.code;
async function signIn(username: string, secret: string) {
  const r = await api('POST', '/auth/login', undefined, { username, secret });
  if (r.status !== 200 || !r.body?.token) throw new Error(`Could not sign in ${username}: ${r.status} ${JSON.stringify(r.body)}`);
  return r.body.token as string;
}

/** A file that starts the way a PDF does, `size` bytes long. */
const pdf = (size: number) => Buffer.concat([Buffer.from('%PDF-1.4\n'), randomBytes(size - 9)]);
const jpeg = (size: number) => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), randomBytes(size - 4)]);
async function put(url: string, body: Buffer, headers: Record<string, string> = {}) {
  const r = await fetch(url, { method: 'PUT', body: new Uint8Array(body), headers, signal: AbortSignal.timeout(120_000) });
  return r.status;
}

/** Sends the bytes of a file to the links /files gave, the way the app does, and returns the statuses. */
async function send(start: any, bytes: Buffer, only?: number[]) {
  const up = start.upload;
  if (up.mode === 'single') return [await put(up.url, bytes, up.headers)];
  const out: number[] = [];
  for (const p of up.parts) {
    if (p.done || (only && !only.includes(p.n))) continue;
    out.push(await put(p.url, bytes.subarray((p.n - 1) * up.part_size, (p.n - 1) * up.part_size + p.size)));
  }
  return out;
}

const created = { sections: [] as string[], courses: [] as string[], groups: [] as { cls: number; subject: string }[] };
const T1 = await signIn(mine.teacher.username, mine.teacher.password);
const S1 = await signIn(mine.student.username, mine.student.pin);
const T2 = await signIn(sample.teacher.username, sample.teacher.password);
const S2 = await signIn(sample.students[0].username, sample.students[0].pin);
const shelf = `/teacher/groups/9/${MATHS}/library`;
// Section names are made fresh each run, so sections left on the shelf by an earlier run or by the demo files never collide.
const run = Date.now().toString(36).slice(-5);
const PDFS = `PDFs ${run}`;
const BOOKS = `Books ${run}`;
const BOOKS2 = `Books and notes ${run}`;

try {
  // ------------------------------------------------------------------ the shelf and its sections
  const empty = await api('GET', shelf, T1);
  check('a group shelf starts empty (or with leftovers from before)', empty.status === 200 && Array.isArray(empty.body?.library?.sections), empty);
  check('the shelf says the limits: 100 MB a file, a quota', empty.body?.library?.max_file_bytes === 100 * MB && empty.body?.library?.quota_bytes > 100 * MB, empty.body?.library);
  const before = empty.body.library.sections.length;
  const s1 = await api('POST', `${shelf}/sections`, T1, { name: PDFS });
  check('a section is added', s1.status === 201 && s1.body?.section?.name === PDFS, s1);
  const sec = s1.body.section.id as string;
  created.sections.push(sec);
  check('the same name is refused, whatever its case', code(await api('POST', `${shelf}/sections`, T1, { name: PDFS.toLowerCase() })) === 'duplicate');
  check('a blank name is refused', (await api('POST', `${shelf}/sections`, T1, { name: '   ' })).status === 400);
  check('a name over 40 characters is refused', (await api('POST', `${shelf}/sections`, T1, { name: 'x'.repeat(41) })).status === 400);
  const s2 = await api('POST', `${shelf}/sections`, T1, { name: BOOKS });
  created.sections.push(s2.body.section.id);
  const renamed = await api('PATCH', `/teacher/library/sections/${s2.body.section.id}`, T1, { name: BOOKS2 });
  check('a section is renamed', renamed.status === 200 && renamed.body?.section?.name === BOOKS2, renamed);
  check('renaming to another section\'s name is refused', code(await api('PATCH', `/teacher/library/sections/${s2.body.section.id}`, T1, { name: PDFS.toUpperCase() })) === 'duplicate');
  check('a subject the tuition does not teach is refused', (await api('GET', `/teacher/groups/9/${'00000000-0000-4000-8000-0000000000ff'}/library`, T1)).status === 400);
  const after = await api('GET', shelf, T1);
  check('the shelf lists both sections in the order they were made', after.body.library.sections.length === before + 2 && after.body.library.sections.at(-2).name === PDFS, after.body?.library?.sections);

  // ------------------------------------------------------------------ nothing shows to a student until a file is whole
  const sBefore = await api('GET', '/student/library', S1);
  const sHome0 = await api('GET', '/student/home', S1);
  // Files left on the shelf by an earlier run or by the demo files may already show: what counts is the change this run makes.
  const homeBase = Number(sHome0.body?.library ?? 0);
  check('a student can read the list of their libraries', sBefore.status === 200 && Array.isArray(sBefore.body.groups) && Array.isArray(sBefore.body.courses) && Number.isInteger(homeBase), { sBefore: sBefore.body, home: sHome0.body?.library });

  // ------------------------------------------------------------------ one request for a small file
  const small = pdf(300_000);
  const start = await api('POST', `/teacher/library/sections/${sec}/files`, T1, { name: 'Chapter 4 notes.pdf', content_type: 'application/pdf', size: small.length });
  check('a small file starts in one request', start.status === 201 && start.body?.upload?.mode === 'single' && typeof start.body.upload.url === 'string', start);
  const fid = start.body.file.id as string;
  check('storage refuses a body of another length than the one signed', (await put(start.body.upload.url, small.subarray(0, 1000), start.body.upload.headers)) >= 400);
  check('a file that is still going up is not shown to students', (await api('GET', '/student/home', S1)).body.library === homeBase);
  check('nor can anyone get a link to it', (await api('GET', `/teacher/library/files/${fid}/url`, T1)).status === 404);
  check('the whole file is accepted by storage', (await put(start.body.upload.url, small, start.body.upload.headers)) === 200);
  const done = await api('POST', `/teacher/library/files/${fid}/complete`, T1);
  check('complete makes it ready', done.status === 200 && done.body?.file?.name === 'Chapter 4 notes.pdf' && done.body.file.kind === 'pdf' && done.body.file.size_bytes === small.length, done);
  check('completing twice is harmless', (await api('POST', `/teacher/library/files/${fid}/complete`, T1)).status === 200);
  const g1 = await api('GET', '/teacher/groups/9/' + MATHS, T1);
  check('the group page counts the file for its Library tab', g1.status === 200 && g1.body.library >= 1, g1.body?.library);
  const listed = await api('GET', shelf, T1);
  check('the shelf lists it in its section', listed.body.library.sections.find((s: any) => s.id === sec)?.files.map((f: any) => f.id).includes(fid), listed.body?.library);

  // ------------------------------------------------------------------ what the student sees and downloads
  const sList = await api('GET', '/student/library', S1);
  const sGroup = sList.body?.groups?.find((g: any) => g.class_level === 9 && g.subject_id === MATHS);
  check('the student sees the file in its section of their group', sGroup?.sections.find((s: any) => s.id === sec)?.files.some((f: any) => f.id === fid), sList.body);
  check('the home count goes up by one', (await api('GET', '/student/home', S1)).body.library === homeBase + 1);
  const view = await api('GET', `/student/library/files/${fid}/url`, S1);
  const viewed = await fetch(view.body.url);
  const viewedBytes = Buffer.from(await viewed.arrayBuffer());
  check('the student reads it from the link', view.status === 200 && viewed.status === 200 && viewedBytes.equals(small), { status: viewed.status, len: viewedBytes.length });
  check('read inline: the link says inline and the type', /^inline/.test(viewed.headers.get('content-disposition') ?? '') && viewed.headers.get('content-type') === 'application/pdf', [...viewed.headers]);
  const dl = await api('GET', `/student/library/files/${fid}/url?download=1`, S1);
  const downloaded = await fetch(dl.body.url);
  await downloaded.arrayBuffer();
  check('download: the link says attachment with the file name', /^attachment; filename="Chapter 4 notes\.pdf"/.test(downloaded.headers.get('content-disposition') ?? ''), downloaded.headers.get('content-disposition'));

  // ------------------------------------------------------------------ a file that is not what it says, or never arrived
  const html = await api('POST', `/teacher/library/sections/${sec}/files`, T1, { name: 'page.html', content_type: 'text/html', size: 100 });
  check('only PDFs and photos are taken', html.status === 400 && code(html) === 'unsupported_type', html);
  check('a program is refused', code(await api('POST', `/teacher/library/sections/${sec}/files`, T1, { name: 'a.exe', content_type: 'application/x-msdownload', size: 100 })) === 'unsupported_type');
  check('over 100 MB is refused', (await api('POST', `/teacher/library/sections/${sec}/files`, T1, { name: 'big.pdf', content_type: 'application/pdf', size: 100 * MB + 1 })).status === 413);
  check('no size is refused', (await api('POST', `/teacher/library/sections/${sec}/files`, T1, { name: 'x.pdf', content_type: 'application/pdf' })).status === 400);
  check('a zero size is refused', (await api('POST', `/teacher/library/sections/${sec}/files`, T1, { name: 'x.pdf', content_type: 'application/pdf', size: 0 })).status === 400);
  const fake = Buffer.from('this is not a pdf, it is some text '.repeat(10));
  const st2 = await api('POST', `/teacher/library/sections/${sec}/files`, T1, { name: 'fake.pdf', content_type: 'application/pdf', size: fake.length });
  await put(st2.body.upload.url, fake, st2.body.upload.headers);
  const c2 = await api('POST', `/teacher/library/files/${st2.body.file.id}/complete`, T1);
  check('a file that does not start like a PDF is thrown away', c2.status === 409 && code(c2) === 'not_that_type', c2);
  check('and its row is gone', (await api('POST', `/teacher/library/files/${st2.body.file.id}/complete`, T1)).status === 404);
  const st3 = await api('POST', `/teacher/library/sections/${sec}/files`, T1, { name: 'never.pdf', content_type: 'application/pdf', size: 5000 });
  const c3 = await api('POST', `/teacher/library/files/${st3.body.file.id}/complete`, T1);
  check('completing a file nobody sent is refused and thrown away', c3.status === 409 && code(c3) === 'upload_failed', c3);

  // ------------------------------------------------------------------ a big file goes up in parts
  const big = pdf(20 * MB + 123);
  const stB = await api('POST', `/teacher/library/sections/${sec}/files`, T1, { name: 'NCERT Mathematics Class 10.pdf', content_type: 'application/pdf', size: big.length });
  const up = stB.body?.upload;
  check('a 20 MB file starts in 3 parts of 8 MB, 8 MB and the rest', stB.status === 201 && up?.mode === 'multipart' && up.parts.length === 3 && up.part_size === 8 * MB
    && up.parts[0].size === 8 * MB && up.parts[2].size === 4 * MB + 123, stB);
  const bid = stB.body.file.id as string;
  check('a part of the wrong length is refused by storage', (await put(up.parts[0].url, big.subarray(0, 1000))) >= 400);
  check('part 1 goes up', (await send(stB.body, big, [1]))[0] === 200);
  const early = await api('POST', `/teacher/library/files/${bid}/complete`, T1);
  check('complete with parts missing is refused, and the file is kept', early.status === 409 && code(early) === 'incomplete', early);
  const resume = await api('POST', `/teacher/library/files/${bid}/upload`, T1);
  check('resuming says part 1 is done and gives new links for the others', resume.status === 200 && resume.body.upload.parts[0].done === true && !resume.body.upload.parts[0].url
    && resume.body.upload.parts.slice(1).every((p: any) => !p.done && typeof p.url === 'string'), resume);
  const rest = await send(resume.body, big);
  check('the rest goes up', rest.length === 2 && rest.every((s) => s === 200), rest);
  const bdone = await api('POST', `/teacher/library/files/${bid}/complete`, T1);
  check('complete puts the parts together', bdone.status === 200 && bdone.body.file.size_bytes === big.length, bdone);
  const bview = await api('GET', `/teacher/library/files/${bid}/url`, T1);
  const bget = await fetch(bview.body.url);
  const bbytes = Buffer.from(await bget.arrayBuffer());
  check('the tutor reads all 20 MB back, byte for byte', bget.status === 200 && bbytes.equals(big), { status: bget.status, len: bbytes.length });
  check('resuming a finished file is refused', (await api('POST', `/teacher/library/files/${bid}/upload`, T1)).status === 409);

  // ------------------------------------------------------------------ photos
  const photo = jpeg(200_000);
  const stP = await api('POST', `/teacher/library/sections/${s2.body.section.id}/files`, T1, { name: 'Blueprint (photo)', content_type: 'image/jpeg', size: photo.length });
  await send(stP.body, photo);
  const dP = await api('POST', `/teacher/library/files/${stP.body.file.id}/complete`, T1);
  check('a photo is added and is a photo', dP.status === 200 && dP.body.file.kind === 'photo', dP);
  const pdl = await api('GET', `/teacher/library/files/${stP.body.file.id}/url?download=1`, T1);
  const pget = await fetch(pdl.body.url);
  await pget.arrayBuffer();
  check('a download of a name with no extension gets the right one', /filename="Blueprint \(photo\)\.jpg"/.test(pget.headers.get('content-disposition') ?? ''), pget.headers.get('content-disposition'));

  // ------------------------------------------------------------------ renaming and moving
  const ren = await api('PATCH', `/teacher/library/files/${fid}`, T1, { name: 'Chapter 4.pdf' });
  check('a file is renamed', ren.status === 200 && ren.body.file.name === 'Chapter 4.pdf', ren);
  const mov = await api('PATCH', `/teacher/library/files/${fid}`, T1, { section_id: s2.body.section.id });
  check('a file moves to another section of the same group', mov.status === 200 && mov.body.file.section_id === s2.body.section.id, mov);
  const courseR = await api('POST', '/teacher/courses', T1, { name: `Library test ${Date.now().toString(36)}` });
  const course = courseR.body.course.id as string;
  created.courses.push(course);
  const cs = await api('POST', `/teacher/courses/${course}/library/sections`, T1, { name: 'Course notes' });
  check('a course has its own shelf and sections', cs.status === 201, cs);
  const bad = await api('PATCH', `/teacher/library/files/${fid}`, T1, { section_id: cs.body.section.id });
  check('a file cannot move to a section of a course', bad.status === 400, bad);

  // ------------------------------------------------------------------ a course's shelf: only its people
  const cst = await api('POST', `/teacher/library/sections/${cs.body.section.id}/files`, T1, { name: 'Spoken English.pdf', content_type: 'application/pdf', size: small.length });
  await send(cst.body, small);
  const cfile = (await api('POST', `/teacher/library/files/${cst.body.file.id}/complete`, T1)).body.file.id as string;
  check('someone who is not in the course does not see its files', !(await api('GET', '/student/library', S1)).body.courses.some((c: any) => c.id === course));
  check('nor can they get a link to one', (await api('GET', `/student/library/files/${cfile}/url`, S1)).status === 404);
  const stu = await api('GET', '/teacher/groups/9/' + MATHS, T1);
  const me = stu.body.students.find((x: any) => x.username === mine.student.username);
  const added = await api('POST', `/teacher/courses/${course}/people`, T1, { student_ids: [me.id] });
  check('the student is added to the course', added.status === 200 && added.body.added === 1, added);
  const inCourse = await api('GET', '/student/library', S1);
  check('a person added to the course sees its files', inCourse.body.courses.find((c: any) => c.id === course)?.sections[0]?.files[0]?.id === cfile, inCourse.body);
  check('and can read one', (await api('GET', `/student/library/files/${cfile}/url`, S1)).status === 200);
  check('the course page counts its files', (await api('GET', `/teacher/courses/${course}`, T1)).body.library === 1);
  await api('DELETE', `/teacher/courses/${course}/people/${me.id}`, T1);
  check('taken out of the course, they see its files no more', !(await api('GET', '/student/library', S1)).body.courses.some((c: any) => c.id === course)
    && (await api('GET', `/student/library/files/${cfile}/url`, S1)).status === 404);
  const cview = await api('GET', `/teacher/library/files/${cfile}/url`, T1);

  // ------------------------------------------------------------------ other tuitions and other roles
  const t2 = await api('GET', shelf, T2);
  check('another tuition cannot read this shelf (it sees its own, or none)', t2.status !== 200 || t2.body.library.sections.every((s: any) => !created.sections.includes(s.id)), t2);
  check('another tuition cannot get a link to the file', (await api('GET', `/teacher/library/files/${fid}/url`, T2)).status === 404);
  check('nor rename it', (await api('PATCH', `/teacher/library/files/${fid}`, T2, { name: 'mine now' })).status === 404);
  check('nor delete it', (await api('DELETE', `/teacher/library/files/${fid}`, T2)).status === 404);
  check('nor add a file to its section', (await api('POST', `/teacher/library/sections/${sec}/files`, T2, { name: 'x.pdf', content_type: 'application/pdf', size: 100 })).status === 404);
  check('nor rename or delete the section', (await api('PATCH', `/teacher/library/sections/${sec}`, T2, { name: 'x' })).status === 404 && (await api('DELETE', `/teacher/library/sections/${sec}`, T2)).status === 404);
  check('nor finish one of its uploads', (await api('POST', `/teacher/library/files/${fid}/complete`, T2)).status === 404);
  check('a student of another tuition cannot get a link', (await api('GET', `/student/library/files/${fid}/url`, S2)).status === 404);
  check('and sees none of these files', !JSON.stringify((await api('GET', '/student/library', S2)).body).includes(fid));
  check('a student cannot use the tutor routes', (await api('GET', shelf, S1)).status === 403 && (await api('POST', `${shelf}/sections`, S1, { name: 'x' })).status === 403
    && (await api('DELETE', `/teacher/library/files/${fid}`, S1)).status === 403);
  check('a tutor cannot use the student routes', (await api('GET', '/student/library', T1)).status === 403);
  check('nobody signed in is refused', (await api('GET', shelf)).status === 401 && (await api('GET', '/student/library')).status === 401);

  // ------------------------------------------------------------------ old apps are untouched
  check('an app from before the Library still gets its Home and group page', (await api('GET', '/teacher/home', T1, undefined, 'core_academy/1.7.0+9')).status === 200
    && (await api('GET', '/student/home', S1, undefined, 'core_academy/1.7.0+9')).status === 200);

  // ------------------------------------------------------------------ a group with files cannot be removed
  const levels = (await api('GET', '/teacher/levels', T1)).body?.levels ?? [];
  const other = levels.map((l: any) => l.code).find((c: number) => c !== 9);
  if (other !== undefined) {
    const mk = await api('POST', '/teacher/groups', T1, { class_level: other, subject_id: MATHS });
    if (mk.status === 201) {
      created.groups.push({ cls: other, subject: MATHS });
      const og = `/teacher/groups/${other}/${MATHS}/library`;
      const os = await api('POST', `${og}/sections`, T1, { name: 'Temp' });
      const ost = await api('POST', `/teacher/library/sections/${os.body.section.id}/files`, T1, { name: 't.pdf', content_type: 'application/pdf', size: small.length });
      await send(ost.body, small);
      const of = (await api('POST', `/teacher/library/files/${ost.body.file.id}/complete`, T1)).body.file.id;
      const blocked = await api('DELETE', `/teacher/groups/${other}/${MATHS}`, T1);
      check('a group whose Library has files cannot be removed', blocked.status === 409 && /Library/.test(blocked.body?.error?.message ?? ''), blocked);
      await api('DELETE', `/teacher/library/files/${of}`, T1);
      check('once the files are gone it can', (await api('DELETE', `/teacher/groups/${other}/${MATHS}`, T1)).status === 200);
      created.groups.pop();
    } else {
      console.log(`SKIP  group removal check: could not make a group of class ${other} (${mk.status})`);
    }
  } else {
    console.log('SKIP  group removal check: the tuition has only one class');
  }

  // ------------------------------------------------------------------ throwing things away
  const delOne = await api('DELETE', `/teacher/library/files/${fid}`, T1);
  check('a file is deleted', delOne.status === 200);
  check('and its stored bytes are gone', (await fetch(view.body.url)).status === 404);
  const hasFiles = await api('DELETE', `/teacher/library/sections/${s2.body.section.id}`, T1);
  check('a section with files is not deleted without saying so', hasFiles.status === 409 && code(hasFiles) === 'has_files', hasFiles);
  const gone = await api('DELETE', `/teacher/library/sections/${s2.body.section.id}?with_files=1`, T1);
  created.sections = created.sections.filter((x) => x !== s2.body.section.id);
  check('with the flag it is, with its files', gone.status === 200 && gone.body.files_deleted === 1, gone);
  check('the photo\'s bytes went with it', (await fetch(pdl.body.url)).status === 404);
  const cdel = await api('DELETE', `/teacher/courses/${course}?with_results=1`, T1);
  created.courses.pop();
  check('deleting a course deletes its files', cdel.status === 200 && (await fetch(cview.body.url)).status === 404, cdel);
  const sw = await api('DELETE', `/teacher/library/sections/${sec}?with_files=1`, T1);
  created.sections = created.sections.filter((x) => x !== sec);
  check('the first section goes with its big file', sw.status === 200 && (await fetch(bview.body.url)).status === 404, sw);

  // ------------------------------------------------------------------ the limits hold when files are started at the same moment
  // The count and the room used to be read before the row was written, so files started together all passed the same check.
  const outcome = (rs: { status: number; body: any }[], ok: number) => {
    const n: Record<string, number> = {};
    for (const r of rs) { const k = r.status === ok ? 'started' : (code(r) ?? String(r.status)); n[k] = (n[k] ?? 0) + 1; }
    return n;
  };
  const crowd = await api('POST', `${shelf}/sections`, T1, { name: `Crowd ${run}` });
  created.sections.push(crowd.body.section.id);
  const manyAtOnce = await Promise.all(Array.from({ length: 108 }, (_, i) =>
    api('POST', `/teacher/library/sections/${crowd.body.section.id}/files`, T1, { name: `small ${i}.pdf`, content_type: 'application/pdf', size: 1000 })));
  const seen = outcome(manyAtOnce, 201);
  check('108 files started at once: a section holds exactly 100', seen.started === 100 && seen.too_many_files === 8, seen);

  // The same for files moved into a section that has room for just one more.
  const first = manyAtOnce.find((r) => r.status === 201)!;
  await api('DELETE', `/teacher/library/files/${first.body.file.id}`, T1);
  const movers = await api('POST', `${shelf}/sections`, T1, { name: `Movers ${run}` });
  created.sections.push(movers.body.section.id);
  const five: string[] = [];
  for (let i = 0; i < 5; i++) {
    const m = await api('POST', `/teacher/library/sections/${movers.body.section.id}/files`, T1, { name: `mover ${i}.pdf`, content_type: 'application/pdf', size: 1000 });
    five.push(m.body.file.id);
  }
  const movedAtOnce = await Promise.all(five.map((id) => api('PATCH', `/teacher/library/files/${id}`, T1, { section_id: crowd.body.section.id })));
  const seenMoves = outcome(movedAtOnce, 200);
  check('5 files moved at once into a section with room for one: exactly one gets in', seenMoves.started === 1 && seenMoves.too_many_files === 4, seenMoves);

  const roomy = await api('POST', `${shelf}/sections`, T1, { name: `Room ${run}` });
  created.sections.push(roomy.body.section.id);
  const shelfNow = (await api('GET', shelf, T1)).body.library;
  const fits = Math.floor((shelfNow.quota_bytes - shelfNow.used_bytes) / (100 * MB));
  const bigAtOnce = await Promise.all(Array.from({ length: fits + 6 }, (_, i) =>
    api('POST', `/teacher/library/sections/${roomy.body.section.id}/files`, T1, { name: `big ${i}.pdf`, content_type: 'application/pdf', size: 100 * MB })));
  const seenBig = outcome(bigAtOnce, 201);
  check(`${fits + 6} big files started at once: the tuition's room takes exactly ${fits}`, fits > 0 && seenBig.started === fits && seenBig.library_full === 6, { fits, ...seenBig });
} finally {
  for (const id of created.sections) await api('DELETE', `/teacher/library/sections/${id}?with_files=1`, T1).catch(() => {});
  for (const id of created.courses) await api('DELETE', `/teacher/courses/${id}?with_results=1`, T1).catch(() => {});
  for (const g of created.groups) await api('DELETE', `/teacher/groups/${g.cls}/${g.subject}`, T1).catch(() => {});
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
