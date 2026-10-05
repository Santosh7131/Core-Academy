import { Hono } from 'hono';
import type { AppEnv } from '../lib/auth.ts';
import { pool, q, q1, tx, type Db } from '../lib/db.ts';
import { CHECK_MODELS, chat, parseJson, SOLVE_MODELS, VISION_MODELS } from '../lib/groq.ts';
import { bad, HttpError, int, notFound, str, uuid, uuidOpt } from '../lib/http.ts';
import { mustKeepOrder } from '../lib/questions.ts';
import { deleteObjects, maybeViewUrl, readObject, uploadUrl, viewUrl } from '../lib/storage.ts';
import { MATHS } from '../lib/subjects.ts';
import { readBody } from './body.ts';

// Mounted behind requireUser('teacher') in index.ts.
//
// A paper is photographed or picked as a PDF first. AI then reads its first page for the details
// (name, class, subject, category, chapter) and the teacher fills in only what it could not find.
// Every page is read for its questions and any answer key it prints, and AI marks the answers the
// paper does not give only when two models agree and each is sure. The teacher checks and saves.
export const paperRoutes = new Hono<AppEnv>();

const MAX_PAGES = 20;
const pageKey = (paperId: string, pageNo: number) => `papers/${paperId}/p${pageNo}.jpg`;

/** The name of a paper AI has not named yet. */
const UNNAMED = 'New paper';

/** AI marks an answer only when both models pick it and each is at least this sure. */
const SURE = 0.9;

/** How many questions AI answers per request, so each request stays short. */
const ANSWER_BATCH = 6;

const clip = (v: unknown, max: number) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const conf = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? Math.min(Math.max(v, 0), 1) : 0);

/** What a paper still needs before its questions can be saved. */
function missingOf(p: { exam_name: string | null; class_level: number | null; subject_id: string | null }) {
  return [
    ...(!p.exam_name || p.exam_name === UNNAMED ? ['exam_name'] : []),
    ...(p.class_level == null ? ['class_level'] : []),
    ...(p.subject_id == null ? ['subject_id'] : []),
  ];
}

const CATEGORIES = `select category as name, count(*) as papers from papers where category is not null group by 1 order by 1`;

paperRoutes.get('/papers', async (c) => {
  const rows = await q(
    `select p.id, p.class_level, p.exam_name, p.category, p.page_count, p.created_at,
            p.subject_id, (select name from subjects where id = p.subject_id) as subject,
            (select count(*) from paper_pages pp where pp.paper_id = p.id and pp.ai_status = 'done') as pages_read,
            (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'draft' and d.kind = 'mcq') as to_check,
            (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'saved') as saved
       from papers p
      order by p.created_at desc`,
  );
  return c.json({ papers: rows, categories: await q(CATEGORIES) });
});

/**
 * Creates the paper and hands back one direct-upload URL per page. The details are optional: AI
 * finds them afterwards. (The app before 1.3 sends the class, subject and name up front.)
 */
paperRoutes.post('/papers', async (c) => {
  const b = await readBody(c);
  const pages = int(b, 'pages', { min: 1, max: MAX_PAGES })!;
  const classLevel = int(b, 'class_level', { min: 6, max: 12, optional: true }) ?? null;
  // An app that sends a class but no subject is older than subjects: its papers are Maths.
  const subjectId = uuidOpt(b.subject_id, 'subject') ?? (classLevel != null ? MATHS : null);
  const paper = await tx(async (cx) => {
    const p = await q1(
      `insert into papers (class_level, exam_name, category, page_count, uploaded_by, subject_id)
       values ($1, $2, $3, $4, $5, $6) returning id, class_level, exam_name, category, page_count, subject_id`,
      [classLevel, str(b, 'exam_name', { max: 80, optional: true }) ?? UNNAMED, str(b, 'category', { max: 60, optional: true }) ?? null,
        pages, c.get('user').id, subjectId],
      cx,
    );
    for (let n = 1; n <= pages; n++) {
      await cx.query('insert into paper_pages (paper_id, page_no, object_key) values ($1, $2, $3)', [p.id, n, pageKey(p.id, n)]);
    }
    return p;
  });
  const uploads = await Promise.all(
    Array.from({ length: pages }, async (_, i) => ({ page_no: i + 1, put_url: await uploadUrl(pageKey(paper.id, i + 1)) })),
  );
  return c.json({ paper, uploads }, 201);
});

paperRoutes.post('/papers/:id/pages/:n/uploaded', async (c) => {
  const r = await q1(
    `update paper_pages set uploaded = true where paper_id = $1 and page_no = $2 returning page_no`,
    [uuid(c.req.param('id'), 'paper id'), Number(c.req.param('n'))],
  );
  if (!r) throw notFound('This page');
  return c.json({ ok: true });
});

const PAPER_COLS = `p.*, (select name from subjects where id = p.subject_id) as subject,
  (select name from chapters where id = p.chapter_id) as chapter`;

paperRoutes.get('/papers/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const p = await q1(`select ${PAPER_COLS} from papers p where p.id = $1`, [id]);
  if (!p) throw notFound('This paper');
  const pages = await q(
    'select page_no, object_key, uploaded, ai_status, ai_error, read_at, answer_key from paper_pages where paper_id = $1 order by page_no',
    [id],
  );
  const drafts = await q(
    `select d.*, ch.name as chapter from paper_drafts d left join chapters ch on ch.id = d.chapter_id
      where d.paper_id = $1 order by d.page_no, d.seq`,
    [id],
  );
  const chapters =
    p.class_level == null || p.subject_id == null
      ? []
      : await q('select id, name from chapters where class_level = $1 and subject_id = $2 order by sort_order, name', [p.class_level, p.subject_id]);
  // The paper as a set: the questions saved from it, as they now are in the bank, in paper order.
  const questions = await q(
    `select qq.id, qq.text, qq.options, qq.correct_option, qq.image_key, ch.name as chapter, d.number_label
       from paper_drafts d join questions qq on qq.id = d.question_id left join chapters ch on ch.id = qq.chapter_id
      where d.paper_id = $1 and d.status = 'saved'
      order by d.page_no, d.seq`,
    [id],
  );
  return c.json({
    paper: { ...p, missing: missingOf(p) },
    pages: await Promise.all(pages.map(async (pg) => ({ ...pg, image_url: pg.uploaded ? await viewUrl(pg.object_key) : null }))),
    drafts: await Promise.all(drafts.map(async (d) => ({ ...d, image_url: await maybeViewUrl(d.image_key) }))),
    chapters,
    questions: await Promise.all(questions.map(async (x) => ({ ...x, image_url: await maybeViewUrl(x.image_key) }))),
    categories: await q(CATEGORIES),
    // Tests made from this paper, newest first.
    tests: await q(
      `select id, title, status, opens_at, closes_at, (select count(*) from test_questions tq where tq.test_id = t.id) as question_count
         from tests t where t.paper_id = $1 order by t.created_at desc`,
      [id],
    ),
  });
});

/**
 * Sets a paper's details. The class and subject can change only while no question from it is
 * saved, because saved questions use them. (The app before 1.3 sends only the name.)
 */
paperRoutes.patch('/papers/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const b = await readBody(c);
  const cur = await q1(
    `select p.*, (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'saved') as saved from papers p where p.id = $1`,
    [id],
  );
  if (!cur) throw notFound('This paper');
  const classLevel = 'class_level' in b ? (int(b, 'class_level', { min: 6, max: 12, optional: true }) ?? null) : cur.class_level;
  const subjectId = 'subject_id' in b ? uuidOpt(b.subject_id, 'subject') : cur.subject_id;
  const moved = classLevel !== cur.class_level || subjectId !== cur.subject_id;
  if (moved && cur.saved > 0) {
    throw new HttpError(409, 'has_questions', 'Questions from this paper are already saved, so its class and subject stay as they are.');
  }
  const p = await tx(async (cx) => {
    const row = await q1(
      `update papers set exam_name = $2, category = $3, class_level = $4, subject_id = $5,
                         chapter_id = case when $7 then null else $6::uuid end
        where id = $1 returning id`,
      [
        id,
        'exam_name' in b ? str(b, 'exam_name', { max: 80 }) : cur.exam_name,
        'category' in b ? (str(b, 'category', { max: 60, optional: true }) ?? null) : cur.category,
        classLevel,
        subjectId,
        'chapter_id' in b ? uuidOpt(b.chapter_id, 'chapter') : cur.chapter_id,
        moved,
      ],
      cx,
    );
    // Chapters belong to a class and subject: drafts drop the old ones and are matched again.
    if (moved) await cx.query(`update paper_drafts set chapter_id = null where paper_id = $1 and status = 'draft'`, [id]);
    await fillChapters(id, cx);
    return row;
  });
  const row = await q1(`select ${PAPER_COLS} from papers p where p.id = $1`, [p.id]);
  return c.json({ paper: { ...row, missing: missingOf(row) } });
});

// ---------------------------------------------------------------- AI: the paper's details

type Found = { value: unknown; confidence: number };

/** Every class, subject and chapter, for AI to place a paper among. */
async function catalogue() {
  const subjects = await q<{ id: string; name: string }>('select id, name from subjects order by sort_order, name');
  const chapters = await q<{ id: string; class_level: number; subject_id: string; name: string }>(
    'select id, class_level, subject_id, name from chapters order by class_level, subject_id, sort_order, name',
  );
  const lines: string[] = [];
  for (let cls = 6; cls <= 12; cls++) {
    for (const s of subjects) {
      const names = chapters.filter((ch) => ch.class_level === cls && ch.subject_id === s.id).map((ch) => ch.name);
      if (names.length) lines.push(`Class ${cls} ${s.name}: ${names.join('; ')}`);
    }
  }
  return { subjects, chapters, lines };
}

const same = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

/** Reads the first page and fills in the details AI is sure of. Details already set stay. */
paperRoutes.post('/papers/:id/detect', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const p = await q1('select * from papers where id = $1', [id]);
  if (!p) throw notFound('This paper');
  const page = await q1('select * from paper_pages where paper_id = $1 and uploaded order by page_no limit 1', [id]);
  if (!page) throw new HttpError(409, 'not_uploaded', 'The pages have not finished uploading.');
  const { subjects, chapters, lines } = await catalogue();
  const categories = (await q<{ name: string }>(CATEGORIES)).map((r) => r.name);

  const img = await readObject(page.object_key);
  const { content } = await chat({
    task: 'detect_paper',
    userId: c.get('user').id,
    models: VISION_MODELS,
    json: true,
    maxTokens: 800,
    messages: [
      { role: 'system', content: 'You look at the first page of a school question paper or worksheet and report its details as JSON.' },
      {
        role: 'user',
        content: [
          {
            type: 'text',
            text: `This is the first page of a question paper, worksheet or set of questions that a CBSE tuition teacher photographed.
Report its details as JSON:
{"exam_name":"<short name>","class_level":<6 to 12, or null>,"subject":"<subject>","printed_subject":"<subject as printed>","category":"<source>","chapter":"<chapter>",
 "confidence":{"exam_name":0.0,"class_level":0.0,"subject":0.0,"category":0.0,"chapter":0.0}}
Rules:
- exam_name: a short name for the paper from its printed title, leaving out the board, class, subject and year, which have their own fields. "CBSE Class 10 Science Sample Question Paper 2025-26, Set 6" becomes "Sample paper, set 6"; "Half Yearly Examination 2025 Mathematics" becomes "Half-yearly exam". If no title is printed, describe it in a few words, e.g. "Life processes worksheet". At most 40 characters.
- class_level and subject: as printed; otherwise only if the questions make them certain.
- subject must be one of: ${subjects.map((s) => JSON.stringify(s.name)).join(', ')}. Physics, Chemistry and Biology are Science; Mathematics is Maths.
- printed_subject: the subject as printed, even when it is not in that list (e.g. "Social Science"); "" when none is printed.
- category: where the questions come from, e.g. "NCERT Exemplar", "NCERT textbook", "CBSE sample paper", "Previous year paper", "School test", "Worksheet". Reuse one of these names when it fits: ${categories.length ? categories.map((x) => JSON.stringify(x)).join(', ') : '(none yet)'}.
- chapter: only when the whole page is about one chapter, and it must be one of the chapters listed for that class and subject:
${lines.join('\n')}
- confidence: how sure you are of each answer, from 0 to 1. Use "" or null with 0 when you cannot tell. Never guess.`,
          },
          { type: 'image_url', image_url: { url: `data:${img.type};base64,${img.bytes.toString('base64')}` } },
        ],
      },
    ],
  });

  let r: Record<string, any>;
  try {
    r = parseJson<Record<string, any>>(content);
  } catch {
    throw new HttpError(502, 'ai_unreadable', 'AI could not make out this paper. Fill in its details below.');
  }
  const cf = (k: string) => conf(r.confidence?.[k]);
  const found: Record<string, Found> = {};

  const name = clip(r.exam_name, 80);
  if (name && cf('exam_name') >= 0.3) found.exam_name = { value: name, confidence: cf('exam_name') };

  const cls = Number(r.class_level);
  if (Number.isInteger(cls) && cls >= 6 && cls <= 12 && cf('class_level') >= 0.8) found.class_level = { value: cls, confidence: cf('class_level') };

  const subject = subjects.find((s) => same(s.name, clip(r.subject, 40)));
  if (subject && cf('subject') >= 0.8) found.subject_id = { value: subject.id, confidence: cf('subject') };
  // A printed subject the teacher has not added yet (Social Science): the app offers to add it.
  const printed = clip(r.printed_subject, 40);
  if (!found.subject_id && printed && !subjects.some((s) => same(s.name, printed))) found.new_subject = { value: printed, confidence: cf('subject') };

  const category = clip(r.category, 60);
  if (category && cf('category') >= 0.8) {
    found.category = { value: categories.find((x) => same(x, category)) ?? category, confidence: cf('category') };
  }

  const finalClass = p.class_level ?? (found.class_level?.value as number | undefined);
  const finalSubject = p.subject_id ?? (found.subject_id?.value as string | undefined);
  const chapter = chapters.find(
    (ch) => ch.class_level === finalClass && ch.subject_id === finalSubject && same(ch.name, clip(r.chapter, 120)),
  );
  if (chapter && cf('chapter') >= 0.8) found.chapter_id = { value: chapter.id, confidence: cf('chapter') };

  // Only empty details are filled: anything the teacher already chose stays.
  await pool.query(
    `update papers set exam_name = case when exam_name = $2 then coalesce($3, exam_name) else exam_name end,
                       class_level = coalesce(class_level, $4), subject_id = coalesce(subject_id, $5),
                       category = coalesce(category, $6), chapter_id = coalesce(chapter_id, $7), ai_details = $8
      where id = $1`,
    [id, UNNAMED, found.exam_name?.value ?? null, found.class_level?.value ?? null, found.subject_id?.value ?? null,
      found.category?.value ?? null, found.chapter_id?.value ?? null, JSON.stringify(found)],
  );
  const row = await q1(`select ${PAPER_COLS} from papers p where p.id = $1`, [id]);
  return c.json({ paper: { ...row, missing: missingOf(row) }, found: Object.keys(found) });
});

// ---------------------------------------------------------------- AI: the questions on each page

type Extracted = {
  number?: unknown; kind?: unknown; text?: unknown; options?: unknown; needs_diagram?: unknown; chapter_guess?: unknown; printed_answer?: unknown;
};

function readPrompt(p: { class_level: number | null; subject: string | null }, pageNo: number, chapters: string[]) {
  const what = p.class_level != null ? `a Class ${p.class_level} CBSE${p.subject ? ` ${p.subject}` : ''} question paper` : 'a CBSE question paper';
  return `This image is page ${pageNo} of ${what}.
Transcribe every question printed on this page, in order, and any answer key printed on it, as JSON:
{"questions":[{"number":"<question number as printed>","kind":"mcq" or "other","text":"<question text>","options":["<a>","<b>","<c>","<d>"],"needs_diagram":true or false,"chapter_guess":"<chapter>","printed_answer":"<answer printed for it, or empty>"}],
 "answer_key":[{"number":"<question number>","answer":"<the option as printed, e.g. b>"}]}
Rules:
- Copy the wording exactly. Write all maths, formulas and chemical equations in LaTeX inside $...$, e.g. $\\frac{3}{4}$, $x^2$, $\\sqrt{2}$, $90^\\circ$, $H_2O$.
- "mcq" only when exactly four options are printed. Give the option text without its (a)/(A)/(i) label, in printed order. Otherwise use "other" with "options": [].
- needs_diagram is true when the question depends on a figure, graph or diagram.
- chapter_guess must be one of: ${chapters.length ? chapters.map((n) => JSON.stringify(n)).join(', ') : '(none listed, so name the chapter or topic in a few words)'}; use "" if unsure.
- Do not solve anything. printed_answer is only an answer the page itself gives for that question: "Ans: (b)", a ticked or circled option, or the answer written under it. Otherwise "".
- answer_key is an answer key printed on this page, such as "Answers: 1. (b) 2. (c)", in printed order; [] when there is none. A page may hold only an answer key.
- Skip instructions, section headings and marks notes.
- If the page has no questions, return "questions": [].`;
}

/** The option an answer means: a letter, a number, i to iv, or the option's own text. */
export function answerIndex(raw: unknown, options: string[]): number | null {
  if (typeof raw !== 'string' && typeof raw !== 'number') return null;
  let s = String(raw).trim().toLowerCase();
  if (!s) return null;
  s = s.replace(/^(ans(wer)?|option|opt)\s*[:.\-]?\s*/, '').replace(/^[([{]\s*|\s*[)\]}.]+$/g, '').trim();
  if (/^[a-d]$/.test(s)) return s.charCodeAt(0) - 97;
  if (/^[1-4]$/.test(s)) return Number(s) - 1;
  const roman = ['i', 'ii', 'iii', 'iv'].indexOf(s);
  if (roman >= 0) return roman;
  const norm = (x: string) => x.toLowerCase().replace(/[\s$\\{}]/g, '');
  const hits = options.map((o, i) => (norm(o) === norm(s) ? i : -1)).filter((i) => i >= 0);
  return hits.length === 1 ? hits[0] : null;
}

/** "Q 12.", "12)" and "(12)" are all question 12. */
const numberKey = (v: unknown) => String(v ?? '').toLowerCase().replace(/^q(uestion)?\s*/, '').replace(/[^0-9a-z]/g, '').replace(/^0+(?=\d)/, '');

/** Reads one page with AI and replaces that page's unchecked drafts. */
paperRoutes.post('/papers/:id/pages/:n/read', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const pageNo = Number(c.req.param('n'));
  const page = await q1(
    `select pp.*, p.class_level, p.subject_id, p.chapter_id as paper_chapter, (select name from subjects where id = p.subject_id) as subject
       from paper_pages pp join papers p on p.id = pp.paper_id where pp.paper_id = $1 and pp.page_no = $2`,
    [id, pageNo],
  );
  if (!page) throw notFound('This page');
  if (!page.uploaded) throw new HttpError(409, 'not_uploaded', 'This page has not finished uploading.');
  const chapters =
    page.class_level == null || page.subject_id == null
      ? []
      : await q<{ id: string; name: string }>('select id, name from chapters where class_level = $1 and subject_id = $2', [page.class_level, page.subject_id]);

  await pool.query(`update paper_pages set ai_status = 'reading', ai_error = null where id = $1`, [page.id]);
  let items: Extracted[];
  let key: { number: string; answer: string }[];
  try {
    const img = await readObject(page.object_key);
    const dataUrl = `data:${img.type};base64,${img.bytes.toString('base64')}`;
    const { content } = await chat({
      task: 'read_paper_page',
      userId: c.get('user').id,
      models: VISION_MODELS,
      json: true,
      // A page takes about 400 tokens and a dense one a few thousand; Groq counts what is asked for.
      maxTokens: 3000,
      messages: [
        { role: 'system', content: 'You transcribe printed exam papers into JSON. You never solve questions; you only copy answers the paper prints.' },
        {
          role: 'user',
          content: [
            { type: 'text', text: readPrompt(page, pageNo, chapters.map((ch) => ch.name)) },
            { type: 'image_url', image_url: { url: dataUrl } },
          ],
        },
      ],
    });
    const parsed = parseJson<{ questions?: Extracted[]; answer_key?: unknown }>(content);
    if (!Array.isArray(parsed.questions)) throw new Error('The reply had no questions list.');
    items = parsed.questions.slice(0, 60);
    key = (Array.isArray(parsed.answer_key) ? parsed.answer_key : [])
      .map((k: any) => ({ number: clip(k?.number, 20), answer: clip(String(k?.answer ?? ''), 200) }))
      .filter((k) => k.number && k.answer)
      .slice(0, 200);
  } catch (e) {
    const message = e instanceof HttpError ? e.message : 'AI could not read this page. Try a clearer photo.';
    await pool.query(`update paper_pages set ai_status = 'failed', ai_error = $2 where id = $1`, [page.id, message]);
    if (e instanceof HttpError) throw e;
    throw new HttpError(502, 'ai_unreadable', message);
  }

  const byName = new Map(chapters.map((ch) => [ch.name.toLowerCase(), ch.id]));
  await tx(async (cx) => {
    await cx.query(`delete from paper_drafts where paper_id = $1 and page_no = $2 and status = 'draft'`, [id, pageNo]);
    let seq = 0;
    for (const it of items) {
      const text = clip(it.text, 4000);
      if (!text) continue;
      let options = Array.isArray(it.options) ? it.options.map((o) => clip(o, 500)).filter(Boolean) : [];
      const kind = it.kind === 'mcq' && options.length === 4 ? 'mcq' : 'other';
      if (kind === 'other') options = [];
      const guess = clip(it.chapter_guess, 120);
      const printed = kind === 'mcq' ? answerIndex(it.printed_answer, options) : null;
      await cx.query(
        `insert into paper_drafts (paper_id, page_no, seq, number_label, kind, text, options, chapter_id, ai_chapter_guess, needs_diagram,
                                   correct_option, answer_source, answer_checked)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
        [id, pageNo, seq++, clip(it.number, 20) || null, kind, text, options, byName.get(guess.toLowerCase()) ?? page.paper_chapter ?? null,
          guess || null, it.needs_diagram === true, printed, printed == null ? null : 'key', printed != null],
      );
    }
    await cx.query(`update paper_pages set ai_status = 'done', read_at = now(), answer_key = $2 where id = $1`, [page.id, JSON.stringify(key)]);
  });
  const drafts = await q('select * from paper_drafts where paper_id = $1 and page_no = $2 order by seq', [id, pageNo]);
  return c.json({ page_no: pageNo, drafts, answer_key: key.length });
});

// ---------------------------------------------------------------- AI: answers

/** Marks answers from the answer keys printed anywhere in the paper. Returns how many. */
async function applyAnswerKeys(paperId: string, db: Db = pool) {
  const pages = await q<{ answer_key: { number: string; answer: string }[] | null }>(
    'select answer_key from paper_pages where paper_id = $1 order by page_no',
    [paperId],
    db,
  );
  const answers = new Map<string, string | null>();
  for (const k of pages.flatMap((pg) => pg.answer_key ?? [])) {
    const n = numberKey(k.number);
    if (!n) continue;
    // A number with two different answers (two sections both start at 1) is left alone.
    answers.set(n, answers.has(n) && answers.get(n) !== k.answer ? null : k.answer);
  }
  if (!answers.size) return 0;
  const drafts = await q(`select id, number_label, options, correct_option, status, kind from paper_drafts where paper_id = $1`, [paperId], db);
  const mcq = drafts.filter((d) => d.kind === 'mcq' && d.status !== 'discarded');
  const count = new Map<string, number>();
  for (const d of mcq) count.set(numberKey(d.number_label), (count.get(numberKey(d.number_label)) ?? 0) + 1);
  let marked = 0;
  for (const d of mcq) {
    const n = numberKey(d.number_label);
    if (d.status !== 'draft' || d.correct_option != null || !n || count.get(n) !== 1) continue;
    const i = answerIndex(answers.get(n), d.options ?? []);
    if (i == null) continue;
    await db.query(`update paper_drafts set correct_option = $2, answer_source = 'key', answer_checked = true where id = $1`, [d.id, i]);
    marked++;
  }
  return marked;
}

/** Gives drafts without a chapter the one AI guessed (once the class is known), else the paper's. */
async function fillChapters(paperId: string, db: Db = pool) {
  await db.query(
    `update paper_drafts d set chapter_id = coalesce(
        (select ch.id from chapters ch join papers p on p.id = d.paper_id
          where ch.class_level = p.class_level and ch.subject_id = p.subject_id and lower(ch.name) = lower(d.ai_chapter_guess) limit 1),
        (select chapter_id from papers where id = d.paper_id))
      where d.paper_id = $1 and d.status = 'draft' and d.chapter_id is null`,
    [paperId],
  );
}

type Pick = { answer: number | null; confidence: number };

/** One model's answers to a batch: question number -> option and how sure it is. */
async function solve(models: string[], userId: string, p: { class_level: number; subject: string | null }, batch: any[]) {
  const qs = batch.map((d, i) => ({
    id: `q${i + 1}`,
    question: d.text,
    options: { A: d.options[0], B: d.options[1], C: d.options[2], D: d.options[3] },
  }));
  const { content } = await chat({
    task: 'answer_questions',
    userId,
    models,
    json: true,
    maxTokens: 3000,
    reasoning: 'medium',
    messages: [
      {
        role: 'system',
        content: `You are a careful CBSE${p.subject ? ` ${p.subject}` : ''} teacher checking the answers to Class ${p.class_level} multiple-choice questions.`,
      },
      {
        role: 'user',
        content: `Work out the correct option of each question. Reply only as JSON:
{"answers":[{"id":"q1","answer":"A","confidence":0.97}]}
- answer is A, B, C or D, or "" when the question is unclear, needs a figure you cannot see, has no correct option, or has more than one.
- confidence is the probability that your answer is right. Be honest: anything you are not certain of is below 0.9.
Questions:
${JSON.stringify(qs)}`,
      },
    ],
  });
  const out = new Map<number, Pick>();
  let parsed: { answers?: any[] };
  try {
    parsed = parseJson<{ answers?: any[] }>(content);
  } catch {
    return out; // An unreadable reply counts as no answers: the teacher marks these.
  }
  for (const a of Array.isArray(parsed.answers) ? parsed.answers : []) {
    const i = Number(String(a?.id ?? '').replace(/^q/, '')) - 1;
    if (!(i >= 0 && i < batch.length)) continue;
    const letter = String(a?.answer ?? '').trim().toUpperCase();
    out.set(i, { answer: /^[A-D]$/.test(letter) ? letter.charCodeAt(0) - 65 : null, confidence: conf(a?.confidence) });
  }
  return out;
}

/**
 * Finds answers for the next few unanswered questions: first from the paper's own answer keys,
 * then with AI. AI's answer is kept only when two different models pick the same option and each
 * is at least 90% sure. Call it again while `left` is above 0.
 */
paperRoutes.post('/papers/:id/answers', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const p = await q1(`select ${PAPER_COLS} from papers p where p.id = $1`, [id]);
  if (!p) throw notFound('This paper');
  if (p.class_level == null) throw new HttpError(409, 'needs_details', 'Choose the class of this paper first.');
  const fromKey = await applyAnswerKeys(id);
  await fillChapters(id);

  const open = `paper_id = $1 and status = 'draft' and kind = 'mcq' and correct_option is null and not answer_checked`;
  // AI cannot see a figure, so those wait for the teacher.
  await pool.query(`update paper_drafts set answer_checked = true where ${open} and needs_diagram`, [id]);
  const batch = await q(`select id, text, options from paper_drafts where ${open} and array_length(options, 1) = 4 order by page_no, seq limit ${ANSWER_BATCH}`, [id]);
  let byAi = 0;
  if (batch.length) {
    const [a, b] = await Promise.all([solve(SOLVE_MODELS, c.get('user').id, p, batch), solve(CHECK_MODELS, c.get('user').id, p, batch)]);
    await tx(async (cx) => {
      for (const [i, d] of batch.entries()) {
        const x = a.get(i);
        const y = b.get(i);
        const sure = x && y && x.answer != null && x.answer === y.answer && x.confidence >= SURE && y.confidence >= SURE;
        if (sure) byAi++;
        await cx.query(
          `update paper_drafts set answer_checked = true,
                  correct_option = case when $2::smallint is null then correct_option else $2 end,
                  answer_source = case when $2::smallint is null then answer_source else 'ai' end,
                  ai_confidence = $3
            where id = $1 and correct_option is null`,
          [d.id, sure ? x.answer : null, sure ? Math.min(x.confidence, y.confidence) : null],
        );
      }
    });
  }
  const left = await q1(`select count(*) as n from paper_drafts where ${open}`, [id]);
  return c.json({ from_key: fromKey, by_ai: byAi, tried: batch.length, left: left.n });
});

// ---------------------------------------------------------------- checking and saving

paperRoutes.patch('/drafts/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'draft id');
  const b = await readBody(c);
  const d = await q1('select * from paper_drafts where id = $1', [id]);
  if (!d) throw notFound('This question');
  if (d.status === 'saved') throw new HttpError(409, 'saved', 'This question is already in the question bank. Edit it there.');

  let options: string[] | null = d.options;
  if ('options' in b) {
    if (!Array.isArray(b.options) || b.options.some((o: unknown) => typeof o !== 'string')) throw bad('options must be a list of text.');
    options = b.options.map((o: string) => o.trim());
  }
  const kind = 'kind' in b ? (b.kind === 'mcq' ? 'mcq' : 'other') : d.kind;
  const marking = 'correct_option' in b;
  const correct = marking ? (b.correct_option === null ? null : int(b, 'correct_option', { min: 0, max: 3 })) : d.correct_option;
  const status = 'status' in b ? (b.status === 'discarded' ? 'discarded' : 'draft') : d.status;
  const row = await q1(
    `update paper_drafts set text = $2, options = $3, kind = $4, correct_option = $5, chapter_id = $6,
                             needs_diagram = $7, image_key = $8, status = $9,
                             answer_source = case when $10 then (case when $5::smallint is null then null else 'teacher' end) else answer_source end,
                             ai_confidence = case when $10 then null else ai_confidence end
      where id = $1 returning *`,
    [
      id,
      'text' in b ? str(b, 'text', { max: 4000 }) : d.text,
      options,
      kind,
      correct,
      'chapter_id' in b ? uuidOpt(b.chapter_id, 'chapter') : d.chapter_id,
      'needs_diagram' in b ? b.needs_diagram === true : d.needs_diagram,
      'image_key' in b ? (typeof b.image_key === 'string' && b.image_key ? b.image_key : null) : d.image_key,
      status,
      marking,
    ],
  );
  return c.json({ draft: { ...row, image_url: await maybeViewUrl(row.image_key) } });
});

/** Saves every checked multiple-choice draft into the question bank. */
paperRoutes.post('/papers/:id/save', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const paper = await q1('select * from papers where id = $1', [id]);
  if (!paper) throw notFound('This paper');
  const missing = missingOf(paper);
  if (missing.includes('class_level') || missing.includes('subject_id')) {
    throw new HttpError(409, 'needs_details', 'Choose the class and subject of this paper first.');
  }
  const result = await tx(async (cx) => {
    const ready = await q(
      `select * from paper_drafts where paper_id = $1 and status = 'draft' and kind = 'mcq'
          and correct_option is not null and array_length(options, 1) = 4 and (not needs_diagram or image_key is not null)
        order by page_no, seq for update`,
      [id],
      cx,
    );
    for (const d of ready) {
      const qrow = await q1(
        `insert into questions (class_level, chapter_id, text, options, correct_option, keep_option_order, image_key, source, paper_id, created_by,
                                subject_id)
         values ($1, $2, $3, $4, $5, $6, $7, 'paper', $8, $9, $10) returning id`,
        [paper.class_level, d.chapter_id ?? paper.chapter_id, d.text, d.options, d.correct_option, mustKeepOrder(d.options), d.image_key, id,
          c.get('user').id, paper.subject_id],
        cx,
      );
      await cx.query(`update paper_drafts set status = 'saved', question_id = $2 where id = $1`, [d.id, qrow.id]);
    }
    const left = await q1(
      `select count(*) as n from paper_drafts where paper_id = $1 and status = 'draft' and kind = 'mcq'`,
      [id],
      cx,
    );
    return { saved: ready.length, still_to_check: left.n };
  });
  return c.json(result);
});

/** Deletes a paper, its pages and the questions saved from it. Questions a test uses stay in the bank. */
paperRoutes.delete('/papers/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const keys = await q<{ object_key: string }>(
    `select object_key from paper_pages where paper_id = $1
     union all select image_key from paper_drafts where paper_id = $1 and image_key is not null and question_id is null`,
    [id],
  );
  const result = await tx(async (cx) => {
    const gone = await cx.query(
      `delete from questions qq where qq.paper_id = $1 and not exists (select 1 from test_questions tq where tq.question_id = qq.id)`,
      [id],
    );
    const kept = await q1('select count(*) as n from questions where paper_id = $1', [id], cx);
    await cx.query('delete from papers where id = $1', [id]);
    return { questions_deleted: gone.rowCount ?? 0, questions_kept: kept.n };
  });
  await deleteObjects(keys.map((k) => k.object_key)).catch(() => {});
  return c.json({ ok: true, ...result });
});
