import { Hono } from 'hono';
import { tuitionOf, type AppEnv } from '../lib/auth.ts';
import { pool, q, q1, tq, tq1, tx, type Db } from '../lib/db.ts';
import { isGemini } from '../lib/gemini.ts';
import { CHECK_MODELS, chat, parseJson, SOLVE_MODELS, TIEBREAK_MODELS, VISION_MODELS, WRITE_MODELS } from '../lib/groq.ts';
import { bad, HttpError, int, notFound, str, uuid, uuidOpt } from '../lib/http.ts';
import { customLevels, isClassNumber, levelIn, levelLabel, studyOf } from '../lib/levels.ts';
import { wrapBareMath } from '../lib/latex-json.ts';
import { verdict, type Pick } from '../lib/votes.ts';
import { mustKeepOrder } from '../lib/questions.ts';
import { asciiDigits, hasIndicText, indicLabelIndex, namesIndicLanguage } from '../lib/text.ts';
import { declaredSize, deleteObjects, MAX_IMAGE_BYTES, maybeViewUrl, objectSize, readObject, uploadUrl, viewUrl } from '../lib/storage.ts';
import { defaultSubject, ensureGroup, ownChapter, ownImageKey, taughtSubject } from '../lib/tuition.ts';
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

/** Papers one tuition may start in a day. Each one is photos in storage and AI work, so there is a ceiling. */
const MAX_PAPERS_PER_DAY = 100;

/** The name old papers carry until AI or the tutor names them. */
const UNNAMED = 'New paper';

/** "Paper 10 Oct": the name a paper starts with, so nothing waits for a tutor to type one. AI replaces it with the paper's own title when it finds one. */
const autoName = () => `Paper ${new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'Asia/Kolkata' })}`;

/** How many questions AI answers per request, so each request stays short. */
const ANSWER_BATCH = 6;

const clip = (v: unknown, max: number) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const conf = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? Math.min(Math.max(v, 0), 1) : 0);

/** What a paper still needs before its questions can be saved. A name is never one of them: it starts with the date. */
function missingOf(p: { exam_name: string | null; class_level: number | null; subject_id: string | null }) {
  return [
    ...(p.class_level == null ? ['class_level'] : []),
    ...(p.subject_id == null ? ['subject_id'] : []),
  ];
}

const CATEGORIES = `select category as name, count(*) as papers from papers where tuition_id = @T and category is not null group by 1 order by 1`;

paperRoutes.get('/papers', async (c) => {
  const T = tuitionOf(c).id;
  const rows = await tq(
    T,
    `select p.id, p.class_level, p.exam_name, p.category, p.page_count, p.created_at,
            p.subject_id, (select name from subjects where id = p.subject_id) as subject,
            (select count(*) from paper_pages pp where pp.paper_id = p.id and pp.ai_status = 'done') as pages_read,
            (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'draft' and d.kind = 'mcq') as to_check,
            (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'saved') as saved
       from papers p
      where p.tuition_id = @T
      order by p.created_at desc`,
  );
  return c.json({ papers: rows, categories: await tq(T, CATEGORIES) });
});

/**
 * Creates the paper and hands back one direct-upload URL per page. The details are optional: AI
 * finds them afterwards. (The app before 1.3 sends the class, subject and name up front.)
 */
paperRoutes.post('/papers', async (c) => {
  const T = tuitionOf(c).id;
  const b = await readBody(c);
  const pages = int(b, 'pages', { min: 1, max: MAX_PAGES })!;
  const classLevel = (await levelIn(b, 'class_level', T, { optional: true })) ?? null;
  const named = str(b, 'exam_name', { max: 80, optional: true });
  // An app that sends a class but no subject is older than subjects: its papers are Maths (or the tuition's first subject).
  const sent = uuidOpt(b.subject_id, 'subject');
  const subjectId = sent ? (await taughtSubject(T, sent)).id : classLevel != null ? await defaultSubject(T) : null;
  // An app from 1.5.0 says how big each page is, and its upload URL then takes exactly that many bytes.
  const sizes: unknown[] = Array.isArray(b.sizes) ? b.sizes : [];
  if (sizes.length && sizes.length !== pages) throw bad('Say the size of every page, or none.');
  const declared = Array.from({ length: pages }, (_, i) => declaredSize(sizes[i]));
  const today = await tq1<{ n: number }>(T, `select count(*) as n from papers where tuition_id = @T and created_at > now() - interval '1 day'`);
  if ((today?.n ?? 0) >= MAX_PAPERS_PER_DAY) {
    throw new HttpError(429, 'too_many_papers', 'That is a lot of papers for one day. Please try again tomorrow.');
  }
  const paper = await tx(async (cx) => {
    const p = await q1(
      `insert into papers (tuition_id, class_level, exam_name, category, page_count, uploaded_by, subject_id, name_auto)
       values ($1, $2, $3, $4, $5, $6, $7, $8) returning id, class_level, exam_name, category, page_count, subject_id`,
      [T, classLevel, named ?? autoName(), str(b, 'category', { max: 60, optional: true }) ?? null,
        pages, c.get('user').id, subjectId, named === undefined],
      cx,
    );
    for (let n = 1; n <= pages; n++) {
      await cx.query('insert into paper_pages (paper_id, page_no, object_key) values ($1, $2, $3)', [p.id, n, pageKey(p.id, n)]);
    }
    return p;
  });
  const uploads = await Promise.all(
    Array.from({ length: pages }, async (_, i) => ({
      page_no: i + 1,
      put_url: await uploadUrl(pageKey(paper.id, i + 1), 'image/jpeg', declared[i] ?? undefined),
    })),
  );
  return c.json({ paper, uploads }, 201);
});

/** One reply holds about this many questions, so a longer test is written in several calls. */
const WRITE_BATCH = 25;
/** Hindi and Tamil take several times the tokens of English for the same question, so a call writes fewer. */
const INDIC_WRITE_BATCH = 10;

/**
 * The chat: the tutor says what test they want and AI writes it. The questions become the drafts
 * of a new paper with no pages, so they get the same checking as an uploaded one: two other models
 * solve each question without seeing the writer's answer, and it is marked only when both agree
 * with each other and with the writer. Anything else is left for the tutor, with a warning.
 *
 * A call writes at most WRITE_BATCH questions. A longer test is several calls: the first makes the
 * paper, and each later one sends its `paper_id` and adds to it, told what is already there so it
 * writes something new. The test can be any length.
 *
 * Papers belong to the tuition, not to the tutor who made them: every paper route is open to every
 * tutor (they share all groups, tests and papers, and any of them can already edit or delete a
 * paper), so adding to one checks its kind, class and subject but not who made it.
 */
paperRoutes.post('/papers/chat', async (c) => {
  const T = tuitionOf(c).id;
  const b = await readBody(c);
  const classLevel = (await levelIn(b, 'class_level', T))!;
  const subjectId = uuid(b.subject_id, 'subject');
  const request = str(b, 'request', { max: 1500 })!;
  const count = int(b, 'count', { min: 1, max: WRITE_BATCH, optional: true }) ?? 15;
  const paperId = b.paper_id == null ? null : uuid(b.paper_id, 'paper id');
  const subject = await taughtSubject(T, subjectId);
  const study = await studyOf(T, classLevel);
  // A request in Hindi or Tamil (or asking for one) is written in that language, a few questions at a time.
  const indic = hasIndicText(request) || namesIndicLanguage(request);
  const asked = indic ? Math.min(count, INDIC_WRITE_BATCH) : count;

  // The questions the paper already has, so a later call does not write them again.
  let written: { text: string; seq: number }[] = [];
  let paperName = '';
  if (paperId) {
    // Only a paper of this tuition: adding to another tuition's paper by its id is refused as not found.
    const p = await tq1<{ exam_name: string; class_level: number; subject_id: string; category: string | null; page_count: number }>(
      T,
      'select exam_name, class_level, subject_id, category, page_count from papers where id = $1 and tuition_id = @T',
      [paperId],
    );
    if (!p) throw notFound('This paper');
    if (p.category !== 'Made with AI' || p.page_count !== 0 || p.class_level !== classLevel || p.subject_id !== subjectId) {
      throw bad('That paper was not written here, so questions cannot be added to it.');
    }
    paperName = p.exam_name;
    written = await q<{ text: string; seq: number }>('select text, seq from paper_drafts where paper_id = $1 order by seq', [paperId]);
  }
  const already = written.slice(-150).map((w) => `- ${w.text.replace(/\s+/g, ' ').slice(0, 90)}`).join('\n');

  const { content } = await chat({
    task: 'write_questions',
    userId: c.get('user').id,
    tuitionId: T,
    models: WRITE_MODELS,
    json: true,
    maxTokens: indic ? 10000 : 8000,
    temperature: 0.7,
    reasoning: 'low',
    messages: [
      { role: 'system', content: `You write multiple-choice questions for ${isClassNumber(classLevel) ? 'a CBSE tuition teacher' : 'a tuition teacher'} in India. You are exact about maths and science.` },
      {
        role: 'user',
        content: `Write exactly ${asked} multiple-choice questions for ${study} ${subject.name}, as the teacher asks below. The request may name a number of questions for the whole test: ignore that, this reply is ${asked}.
Teacher's request:
"""
${request}
"""
${written.length ? `
The test already has ${written.length} questions, listed below. Write ${asked} new ones on new ground within the request: not the same question, and not one of these reworded.
${already}
` : ''}

Reply only as JSON:
{${written.length ? '' : '"name":"<short test name>",'}"questions":[{"text":"<question>","options":["<a>","<b>","<c>","<d>"],"answer":"<the correct option, copied exactly as it is written in options>"}]}
Rules:
- Exactly four options per question, and exactly one is correct. "answer" is the text of that option, copied character for character from "options" (not a letter). Spread the right answers over all four positions.
- Write all maths, formulas and chemical equations in LaTeX inside $...$, in the options as well as in the question, e.g. $\\frac{3}{4}$, $x^2$, $90^\\circ$, $H_2O$. This is JSON, so write every LaTeX backslash twice, as in "$\\\\frac{3}{4}$". Give each option's text without a letter label.
- Follow the teacher's topic and difficulty. Match the ${study} syllabus.
- Write the questions and the options in the language of the teacher's request: English, Hindi or Tamil, or the one the request asks for. Hindi and Tamil questions use the standard school-textbook terms, and every number is written with the digits 0 to 9. The JSON keys and the answer letters A to D stay as shown.
- Every question must be answerable from its text alone: no figures, graphs or diagrams, and no "all of the above" or "none of the above".
- Wrong options are plausible mistakes. Do not repeat a question.
${written.length ? '' : '- name: at most 40 characters, e.g. "Quadratic equations, set 1".'}`,
      },
    ],
  });

  const items: { text: string; options: string[]; answer: number | null }[] = [];
  for (const it of listIn(content, 'questions')) {
    const text = asciiDigits(clip(it?.text, 4000));
    const options = Array.isArray(it?.options)
      ? it.options.map((o: unknown) => wrapBareMath(asciiDigits(clip(typeof o === 'string' ? o : String(o ?? ''), 500))))
      : [];
    if (!text || options.length !== 4 || options.some((o: string) => !o)) continue;
    // The writer's own answer is one opinion among three: a question whose answer cannot be told is still kept.
    items.push({ text, options, answer: writerAnswer(it?.answer, options) });
    if (items.length >= asked) break;
  }
  if (!items.length) throw new HttpError(502, 'ai_unreadable', 'AI could not write that test. Try again, in different words.');
  let name = paperName;
  if (!paperId) {
    try {
      name = clip((parseJson<{ name?: unknown }>(content) as { name?: unknown })?.name, 40);
    } catch {
      // The questions are what matters: a missing name gets a plain one.
    }
    name ||= `${subject.name} questions`;
  }
  const first = written.length ? Math.max(...written.map((w) => w.seq)) + 1 : 0;

  const paper = await tx(async (cx) => {
    const p = paperId
      ? { id: paperId }
      : await q1(
          `insert into papers (tuition_id, class_level, exam_name, category, page_count, uploaded_by, subject_id)
           values ($1, $2, $3, 'Made with AI', 0, $4, $5) returning id`,
          [T, classLevel, name, c.get('user').id, subjectId],
          cx,
        );
    for (const [i, it] of items.entries()) {
      await cx.query(
        `insert into paper_drafts (paper_id, page_no, seq, number_label, kind, text, options, answer_checked, proposed_option)
         values ($1, 1, $2, $3, 'mcq', $4, $5, false, $6)`,
        [p.id, first + i, String(first + i + 1), it.text, it.options, it.answer],
      );
    }
    return p;
  });
  return c.json({ paper: { id: paper.id, exam_name: name }, questions: items.length, total: first + items.length }, 201);
});

paperRoutes.post('/papers/:id/pages/:n/uploaded', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const n = Number(c.req.param('n'));
  const page = await tq1(
    tuitionOf(c).id,
    `select pp.object_key from paper_pages pp join papers p on p.id = pp.paper_id
      where p.tuition_id = @T and pp.paper_id = $1 and pp.page_no = $2`,
    [id, n],
  );
  if (!page) throw notFound('This page');
  // The upload went straight to storage, which cannot cap its size: look at what arrived.
  const size = await objectSize(page.object_key);
  if (size === null) throw new HttpError(409, 'not_uploaded', 'This page did not finish uploading. Please add it again.');
  if (size > MAX_IMAGE_BYTES) {
    await deleteObjects([page.object_key]).catch(() => {});
    throw new HttpError(413, 'too_big', 'That picture is too big. Use one under 15 MB.');
  }
  await pool.query('update paper_pages set uploaded = true where paper_id = $1 and page_no = $2', [id, n]);
  return c.json({ ok: true });
});

const PAPER_COLS = `p.*, (select name from subjects where id = p.subject_id) as subject,
  (select name from chapters where id = p.chapter_id) as chapter`;

paperRoutes.get('/papers/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'paper id');
  const p = await tq1(T, `select ${PAPER_COLS} from papers p where p.id = $1 and p.tuition_id = @T`, [id]);
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
      : await tq(T, 'select id, name from chapters where tuition_id = @T and class_level = $1 and subject_id = $2 order by sort_order, name', [p.class_level, p.subject_id]);
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
    categories: await tq(T, CATEGORIES),
    // Tests made from this paper, newest first.
    tests: await tq(
      T,
      `select id, title, status, opens_at, closes_at, (select count(*) from test_questions tq where tq.test_id = t.id) as question_count
         from tests t where t.paper_id = $1 and t.tuition_id = @T order by t.created_at desc`,
      [id],
    ),
  });
});

/**
 * Sets a paper's details. The class and subject can change only while no question from it is
 * saved, because saved questions use them. (The app before 1.3 sends only the name.)
 */
paperRoutes.patch('/papers/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'paper id');
  const b = await readBody(c);
  const cur = await tq1(
    T,
    `select p.*, (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'saved') as saved from papers p
      where p.id = $1 and p.tuition_id = @T`,
    [id],
  );
  if (!cur) throw notFound('This paper');
  const classLevel = 'class_level' in b ? ((await levelIn(b, 'class_level', T, { optional: true })) ?? null) : cur.class_level;
  const subjectId = 'subject_id' in b ? uuidOpt(b.subject_id, 'subject') : cur.subject_id;
  if (subjectId && subjectId !== cur.subject_id) await taughtSubject(T, subjectId);
  const moved = classLevel !== cur.class_level || subjectId !== cur.subject_id;
  if (moved && cur.saved > 0) {
    throw new HttpError(409, 'has_questions', 'Questions from this paper are already saved, so its class and subject stay as they are.');
  }
  const p = await tx(async (cx) => {
    const row = await q1(
      `update papers set exam_name = $2, category = $3, class_level = $4, subject_id = $5,
                         chapter_id = case when $7 then null else $6::uuid end,
                         name_auto = case when $8 then false else name_auto end
        where id = $1 returning id`,
      [
        id,
        'exam_name' in b ? str(b, 'exam_name', { max: 80 }) : cur.exam_name,
        'category' in b ? (str(b, 'category', { max: 60, optional: true }) ?? null) : cur.category,
        classLevel,
        subjectId,
        'chapter_id' in b ? await ownChapter(T, uuidOpt(b.chapter_id, 'chapter'), cx) : cur.chapter_id,
        moved,
        'exam_name' in b,
      ],
      cx,
    );
    // Chapters belong to a class and subject: drafts drop the old ones and are matched again.
    if (moved) await cx.query(`update paper_drafts set chapter_id = null where paper_id = $1 and status = 'draft'`, [id]);
    await fillChapters(id, cx);
    if (classLevel != null && subjectId) await ensureGroup(T, classLevel, subjectId, cx);
    return row;
  });
  const row = await q1(`select ${PAPER_COLS} from papers p where p.id = $1`, [p.id]);
  return c.json({ paper: { ...row, missing: missingOf(row) } });
});

// ---------------------------------------------------------------- AI: the paper's details

type Found = { value: unknown; confidence: number };

/** Every class, subject and chapter of the tuition, for AI to place a paper among. */
async function catalogue(T: string) {
  const subjects = await tq<{ id: string; name: string }>(
    T,
    'select sj.id, sj.name from subjects sj join tuition_subjects ts on ts.subject_id = sj.id and ts.tuition_id = @T order by sj.sort_order, sj.name',
  );
  const chapters = await tq<{ id: string; class_level: number; subject_id: string; name: string }>(
    T,
    'select id, class_level, subject_id, name from chapters where tuition_id = @T order by class_level, subject_id, sort_order, name',
  );
  const lines: string[] = [];
  const named = new Map((await customLevels(T)).map((l) => [l.code, l.label]));
  for (const cls of [...new Set(chapters.map((ch) => ch.class_level))].sort((x, y) => x - y)) {
    for (const s of subjects) {
      const names = chapters.filter((ch) => ch.class_level === cls && ch.subject_id === s.id).map((ch) => ch.name);
      if (names.length) lines.push(`${named.get(cls) ?? `Class ${cls}`} ${s.name}: ${names.join('; ')}`);
    }
  }
  return { subjects, chapters, lines };
}

const same = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

/** Reads the first page and fills in the details AI is sure of. Details already set stay. */
paperRoutes.post('/papers/:id/detect', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'paper id');
  const p = await tq1(T, 'select * from papers where id = $1 and tuition_id = @T', [id]);
  if (!p) throw notFound('This paper');
  const page = await q1('select * from paper_pages where paper_id = $1 and uploaded order by page_no limit 1', [id]);
  if (!page) throw new HttpError(409, 'not_uploaded', 'The pages have not finished uploading.');
  const { subjects, chapters, lines } = await catalogue(T);
  const categories = (await tq<{ name: string }>(T, CATEGORIES)).map((r) => r.name);

  const img = await readPageImage(page.object_key);
  const { content } = await chat({
    task: 'detect_paper',
    userId: c.get('user').id,
    tuitionId: T,
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
{"exam_name":"<short name>","class_level":<1 to 12, or null>,"subject":"<subject>","printed_subject":"<subject as printed>","category":"<source>","chapter":"<chapter>",
 "confidence":{"exam_name":0.0,"class_level":0.0,"subject":0.0,"category":0.0,"chapter":0.0}}
Rules:
- exam_name: a short name from the title printed on this page, leaving out the board, class, subject and year, which have their own fields: a printed "Half Yearly Examination 2025 Mathematics" becomes "Half-yearly exam". If no title is printed, name it in a few words from its questions, e.g. "Life processes worksheet". These examples only show the form; never copy one. At most 40 characters.
- class_level and subject: as printed; otherwise only if the questions make them certain.
- The paper may be in English, Hindi or Tamil. Give subject, class_level and chapter in the English forms listed here, matching by meaning: गणित and கணிதம் are Maths; विज्ञान and அறிவியல் are Science. exam_name follows the title in the language it is printed.
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
  if (isClassNumber(cls) && cf('class_level') >= 0.8) found.class_level = { value: cls, confidence: cf('class_level') };

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
    `update papers set exam_name = case when (name_auto or exam_name = $2) and $3::text is not null then $3 else exam_name end,
                       name_auto = case when (name_auto or exam_name = $2) and $3::text is not null then false else name_auto end,
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
  unclear?: unknown;
};

/** A box AI leaves where the page itself cannot be read (some PDFs print ■ for every subscript). */
const BOX = '■';

function readPrompt(p: { study: string | null; subject: string | null }, pageNo: number, chapters: string[]) {
  const what = p.study != null ? `a ${p.study}${p.subject ? ` ${p.subject}` : ''} question paper` : 'a CBSE question paper';
  return `This image is page ${pageNo} of ${what}.
Transcribe every question printed on this page, in order, and any answer key printed on it, as JSON:
{"questions":[{"number":"<question number as printed>","kind":"mcq" or "other","text":"<question text>","options":["<a>","<b>","<c>","<d>"],"needs_diagram":true or false,"unclear":true or false,"chapter_guess":"<chapter>","printed_answer":"<answer printed for it, or empty>"}],
 "answer_key":[{"number":"<question number>","answer":"<the option as printed, e.g. b>"}]}
Rules:
- Copy the wording exactly. Write all maths, formulas and chemical equations in LaTeX inside $...$, e.g. $\\frac{3}{4}$, $x^2$, $\\sqrt{2}$, $90^\\circ$, $H_2O$.
- "text" is the question itself, without its number or label: leave out "1.", "Q1", "Question 1", "प्रश्न 1" and "வினா 1" (the number goes in "number").
- The paper may be in English, Hindi or Tamil, or mix them (maths terms in English inside Hindi or Tamil sentences). Transcribe each line in the language and script it is printed in: never translate, transliterate or correct it. Write every number with the digits 0 to 9, even when the page prints Hindi or Tamil digits (१२ and ௧௨ are 12).
- Some pages cannot be read in places: smudged, cut off, or printed as boxes such as ${BOX} (a PDF can show every subscript that way). Each box stands for exactly one missing character, so "t${BOX}${BOX}${BOX}" had three, such as "n+1". Restore a box only when the question's own formula or wording forces it: "t${BOX} = 3n - 4" can only be $t_n = 3n - 4$, and "t${BOX} = 7 and t${BOX}${BOX}${BOX} = 2t${BOX}" is $t_1 = 7$ and $t_{n+1} = 2t_n$. Never pick a number, letter or sign that nothing forces: "t${BOX} - t${BOX}" stays "$t_${BOX} - t_${BOX}$", because nothing says which terms. Set "unclear": true for every question where you filled anything in or kept a ${BOX}.
- "mcq" only when exactly four options are printed. Give the option text without its label, in printed order: the label may be (a)/(A)/(i)/(1) or, in Hindi and Tamil papers, (क)(ख)(ग)(घ), (अ)(ब)(स)(द), (அ)(ஆ)(இ)(ஈ). Otherwise use "other" with "options": [].
- needs_diagram is true when the question depends on a figure, graph or diagram.
- chapter_guess must be one of: ${chapters.length ? chapters.map((n) => JSON.stringify(n)).join(', ') : '(none listed, so name the chapter or topic in a few words)'}; use "" if unsure.
- Do not solve anything. printed_answer is only an answer the page itself gives for that question: "Ans: (b)", "उत्तर: (ख)", "விடை: ஆ", a ticked or circled option, or the answer written under it. Otherwise "". Give it as printed, e.g. b, 2, ख or ஆ.
- answer_key is an answer key printed on this page, such as "Answers: 1. (b) 2. (c)" or "उत्तर: 1. (ख) 2. (ग)", in printed order; [] when there is none. A page may hold only an answer key.
- Skip instructions, section headings and marks notes.
- If the page has no questions, return "questions": [].`;
}

/**
 * Which option the test writer says is right. It is asked to copy the option's text, which models do far
 * more reliably than naming a letter; a bare letter is still understood. Null when it cannot be told (the
 * text matches no option, or two the same), and the question then goes on without the writer's opinion.
 */
export function writerAnswer(raw: unknown, options: string[]): number | null {
  const s = asciiDigits(String(raw ?? '')).trim();
  if (!s) return null;
  const norm = (x: string) => asciiDigits(x).toLowerCase().replace(/[\s$\\{}]/g, '');
  const hits = options.map((o, i) => (norm(o) === norm(s) ? i : -1)).filter((i) => i >= 0);
  if (hits.length === 1) return hits[0];
  if (hits.length > 1) return null;
  const letter = /^\(?([A-Da-d])\)?[.:]?$/.exec(s);
  return letter ? letter[1].toUpperCase().charCodeAt(0) - 65 : null;
}

/**
 * The option an answer means: a letter, a number, i to iv, a Hindi or Tamil label ((ख), (ஆ)), or the
 * option's own text. Hindi and Tamil digits count as 0 to 9.
 */
export function answerIndex(raw: unknown, options: string[]): number | null {
  if (typeof raw !== 'string' && typeof raw !== 'number') return null;
  let s = asciiDigits(String(raw)).trim().toLowerCase();
  if (!s) return null;
  s = s
    .replace(/^(ans(wer)?|option|opt|सही उत्तर|उत्तर|विकल्प|சரியான விடை|விடை|பதில்)\s*[:.\-]?\s*/, '')
    .replace(/^[([{]\s*|\s*[)\]}.]+$/g, '')
    .trim();
  if (/^[a-d]$/.test(s)) return s.charCodeAt(0) - 97;
  if (/^[1-4]$/.test(s)) return Number(s) - 1;
  const roman = ['i', 'ii', 'iii', 'iv'].indexOf(s);
  if (roman >= 0) return roman;
  const label = indicLabelIndex(s);
  if (label != null) return label;
  const norm = (x: string) => asciiDigits(x).toLowerCase().replace(/[\s$\\{}]/g, '');
  const hits = options.map((o, i) => (norm(o) === norm(s) ? i : -1)).filter((i) => i >= 0);
  return hits.length === 1 ? hits[0] : null;
}

/** "Q 12.", "12)", "(12)", "प्र. 12" and "வினா ௧௨" are all question 12. */
const numberKey = (v: unknown) => asciiDigits(String(v ?? '')).toLowerCase().replace(/^q(uestion)?\s*/, '').replace(/[^0-9a-z]/g, '').replace(/^0+(?=\d)/, '');

/**
 * A question and its options without spacing, punctuation or LaTeX commands, so the same question
 * read twice ("$18$ seats" and "18 seats") compares equal. Letters of every script count: keeping
 * only a to z would make every Hindi or Tamil question without digits equal to every other one.
 */
export const sameKey = (text: string, options: string[] | null) =>
  asciiDigits([text, ...(options ?? [])].join('|')).toLowerCase().replace(/\\[a-z]+/g, '').replace(/[^\p{L}\p{M}\p{N}|]/gu, '');

/**
 * Skips each draft that repeats an earlier one of the same paper, as when a PDF holds its pages
 * twice. A saved copy, else the first one in the paper, is the one kept.
 */
async function skipRepeats(paperId: string, db: Db) {
  const drafts = await q<{ id: string; text: string; options: string[] | null; status: string }>(
    `select id, text, options, status from paper_drafts where paper_id = $1 and status in ('draft', 'saved')
      order by status = 'saved' desc, page_no, seq`,
    [paperId],
    db,
  );
  const first = new Map<string, string>();
  for (const d of drafts) {
    const k = sameKey(d.text, d.options);
    const kept = first.get(k);
    if (!kept) first.set(k, d.id);
    else if (d.status === 'draft') {
      await db.query(`update paper_drafts set status = 'discarded', ai_note = 'duplicate', duplicate_of = $2 where id = $1`, [d.id, kept]);
    }
  }
}

/** A page's picture, read into memory. One that has grown past the limit since it was checked is deleted. */
async function readPageImage(key: string) {
  try {
    return await readObject(key);
  } catch (e) {
    if (e instanceof Error && e.message.startsWith('The stored file is larger')) {
      await deleteObjects([key]).catch(() => {});
      throw new HttpError(413, 'too_big', 'That picture is too big. Use one under 15 MB.');
    }
    throw e;
  }
}

/**
 * Reads one page with each vision model in turn until one gives a usable reply: JSON with a list of
 * questions or an answer key. A reply with nothing on it is confirmed by the next model before the page
 * is believed to be blank. Throws the last failure when no model could read it.
 */
async function readPageWithAI(T: string, userId: string, prompt: string, dataUrl: string) {
  type Read = { items: Extracted[]; key: { number: string; answer: string }[] };
  let lastError: unknown = null;
  let empty: Read | null = null;
  for (const model of VISION_MODELS) {
    let content: string;
    try {
      ({ content } = await chat({
        task: 'read_paper_page',
        userId,
        tuitionId: T,
        models: [model],
        json: true,
        // A page takes about 400 tokens and a dense one a few thousand (Hindi and Tamil several times more); Groq counts what is asked for.
        maxTokens: isGemini(model) ? 6000 : 3000,
        messages: [
          { role: 'system', content: 'You transcribe printed exam papers into JSON. You never solve questions; you only copy answers the paper prints.' },
          { role: 'user', content: [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: dataUrl } }] },
        ],
      }));
    } catch (e) {
      lastError = e;
      continue;
    }
    let whole: unknown;
    try {
      whole = parseJson<unknown>(content);
    } catch {
      lastError = new Error('The reply was not JSON.');
      continue;
    }
    const list = listIn(content, 'questions') as Extracted[];
    if (!list.length && !(whole && typeof whole === 'object' && 'questions' in (whole as object))) {
      lastError = new Error('The reply had no questions list.');
      continue;
    }
    const rawKey = Array.isArray((whole as { answer_key?: unknown })?.answer_key) ? (whole as { answer_key: unknown[] }).answer_key : [];
    const key = rawKey
      .map((k: any) => ({ number: clip(k?.number, 20), answer: clip(String(k?.answer ?? ''), 200) }))
      .filter((k) => k.number && k.answer)
      .slice(0, 200);
    const read: Read = { items: list.slice(0, 60), key };
    if (read.items.length || read.key.length) return read;
    empty = read;
  }
  if (empty) return empty;
  throw lastError ?? new Error('No model could read this page.');
}

/** Reads one page with AI and replaces that page's unchecked drafts. */
paperRoutes.post('/papers/:id/pages/:n/read', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'paper id');
  const pageNo = Number(c.req.param('n'));
  const page = await tq1(
    T,
    `select pp.*, p.class_level, p.subject_id, p.chapter_id as paper_chapter, (select name from subjects where id = p.subject_id) as subject
       from paper_pages pp join papers p on p.id = pp.paper_id where pp.paper_id = $1 and pp.page_no = $2 and p.tuition_id = @T`,
    [id, pageNo],
  );
  if (!page) throw notFound('This page');
  if (!page.uploaded) throw new HttpError(409, 'not_uploaded', 'This page has not finished uploading.');
  const chapters =
    page.class_level == null || page.subject_id == null
      ? []
      : await tq<{ id: string; name: string }>(T, 'select id, name from chapters where tuition_id = @T and class_level = $1 and subject_id = $2', [page.class_level, page.subject_id]);

  await pool.query(`update paper_pages set ai_status = 'reading', ai_error = null where id = $1`, [page.id]);
  let items: Extracted[];
  let key: { number: string; answer: string }[];
  try {
    const img = await readPageImage(page.object_key);
    const dataUrl = `data:${img.type};base64,${img.bytes.toString('base64')}`;
    const prompt = readPrompt({ study: page.class_level != null ? await studyOf(T, page.class_level) : null, subject: page.subject }, pageNo, chapters.map((ch) => ch.name));
    ({ items, key } = await readPageWithAI(T, c.get('user').id, prompt, dataUrl));
  } catch (e) {
    const message = e instanceof HttpError ? e.message : 'AI could not read this page. Try a clearer photo.';
    await pool.query(`update paper_pages set ai_status = 'failed', ai_error = $2 where id = $1`, [page.id, message]);
    if (e instanceof HttpError) throw e;
    throw new HttpError(502, 'ai_unreadable', message);
  }

  const byName = new Map(chapters.map((ch) => [ch.name.toLowerCase(), ch.id]));
  await tx(async (cx) => {
    // The page's unchecked drafts go, and so do its repeats that were skipped for being repeats.
    await cx.query(
      `delete from paper_drafts where paper_id = $1 and page_no = $2 and (status = 'draft' or (status = 'discarded' and ai_note = 'duplicate'))`,
      [id, pageNo],
    );
    let seq = 0;
    for (const it of items) {
      // Hindi and Tamil digits become 0 to 9, which every solver and the maths renderer read.
      const text = asciiDigits(clip(it.text, 4000));
      if (!text) continue;
      let options = Array.isArray(it.options) ? it.options.map((o) => asciiDigits(clip(o, 500))).filter(Boolean) : [];
      const kind = it.kind === 'mcq' && options.length === 4 ? 'mcq' : 'other';
      if (kind === 'other') options = [];
      const guess = clip(it.chapter_guess, 120);
      const printed = kind === 'mcq' ? answerIndex(it.printed_answer, options) : null;
      // Part of it could not be read (still a box in it, or AI filled something in): an answer
      // worked out from a guess would be a guess too, so AI leaves it until the teacher has checked
      // the question and says it looks right (PATCH /drafts/:id with confirmed).
      const unclear = it.unclear === true || [text, ...options].some((s) => s.includes(BOX));
      await cx.query(
        `insert into paper_drafts (paper_id, page_no, seq, number_label, kind, text, options, chapter_id, ai_chapter_guess, needs_diagram,
                                   correct_option, answer_source, answer_checked, ai_note)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`,
        [id, pageNo, seq++, clip(it.number, 20) || null, kind, text, options, byName.get(guess.toLowerCase()) ?? page.paper_chapter ?? null,
          guess || null, it.needs_diagram === true, printed, printed == null ? null : 'key', printed != null || unclear,
          unclear ? 'unclear' : null],
      );
    }
    // Pages are read side by side, so repeats between pages are skipped by the next answers call,
    // which sees every page that has finished by then.
    await cx.query(`update paper_pages set ai_status = 'done', read_at = now(), answer_key = $2 where id = $1`, [page.id, JSON.stringify(key)]);
  });
  const drafts = await q('select * from paper_drafts where paper_id = $1 and page_no = $2 order by seq', [id, pageNo]);
  return c.json({ page_no: pageNo, drafts, answer_key: key.length });
});

// ---------------------------------------------------------------- AI: answers

/**
 * Marks answers from the answer keys printed anywhere in the paper. Returns how many. A printed
 * key beats an answer AI worked out (the app answers pages while later ones, perhaps holding the
 * key, are still being read), but never a mark the teacher made.
 */
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
  const drafts = await q(`select id, number_label, options, correct_option, answer_source, status, kind from paper_drafts where paper_id = $1`, [paperId], db);
  const mcq = drafts.filter((d) => d.kind === 'mcq' && d.status !== 'discarded');
  const count = new Map<string, number>();
  for (const d of mcq) count.set(numberKey(d.number_label), (count.get(numberKey(d.number_label)) ?? 0) + 1);
  let marked = 0;
  for (const d of mcq) {
    const n = numberKey(d.number_label);
    if (d.status !== 'draft' || !n || count.get(n) !== 1) continue;
    if (d.correct_option != null && d.answer_source !== 'ai') continue; // the teacher's mark, or a key already applied
    const i = answerIndex(answers.get(n), d.options ?? []);
    if (i == null) continue;
    await db.query(
      // The paper's own answer ends whatever AI was unsure about: no split note, no second opinion to wait for.
      `update paper_drafts set correct_option = $2, answer_source = 'key', ai_confidence = null, answer_checked = true,
              ai_note = case when ai_note in ('disagree', 'unsure', 'writer_differs') then null else ai_note end,
              ai_picks = null, ai_votes = null
        where id = $1`,
      [d.id, i],
    );
    marked++;
  }
  return marked;
}

/** Gives drafts without a chapter the one AI guessed (once the class is known), else the paper's. */
async function fillChapters(paperId: string, db: Db = pool) {
  await db.query(
    `update paper_drafts d set chapter_id = coalesce(
        (select ch.id from chapters ch join papers p on p.id = d.paper_id
          where ch.class_level = p.class_level and ch.subject_id = p.subject_id and ch.tuition_id = p.tuition_id
             and lower(ch.name) = lower(d.ai_chapter_guess) limit 1),
        (select chapter_id from papers where id = d.paper_id))
      where d.paper_id = $1 and d.status = 'draft' and d.chapter_id is null`,
    [paperId],
  );
}

/**
 * The list a model's JSON reply holds, whatever shape it chose: the object that was asked for
 * (`{"answers": [...]}`), a bare list, or a list under another name. Models reading with
 * `responseMimeType: application/json` and no schema do all three.
 */
export function listIn(content: string, key: string): any[] {
  let parsed: unknown;
  try {
    parsed = parseJson<unknown>(content);
  } catch {
    return [];
  }
  if (Array.isArray(parsed)) return parsed;
  if (parsed && typeof parsed === 'object') {
    const o = parsed as Record<string, unknown>;
    if (Array.isArray(o[key])) return o[key] as any[];
    const other = Object.values(o).find(Array.isArray);
    if (other) return other as any[];
  }
  return [];
}

/**
 * One model's answers to a batch: position in the batch -> option and how sure it is. The models are
 * tried in order, and a model that left questions out is followed by the next one, asked only for
 * those. Throws only when every model failed outright (the caller gives the batch back).
 */
async function solve(
  models: string[],
  userId: string,
  tuitionId: string,
  p: { class_level: number; subject: string | null },
  batch: any[],
  how: { task?: string; deadline?: number; attemptMs?: number } = {},
) {
  const who = isClassNumber(p.class_level)
    ? `a careful CBSE${p.subject ? ` ${p.subject}` : ''} teacher checking the answers to Class ${p.class_level} multiple-choice questions`
    : `a careful${p.subject ? ` ${p.subject}` : ''} teacher checking the answers to ${await levelLabel(tuitionId, p.class_level)} multiple-choice questions`;
  const out = new Map<number, Pick>();
  let failure: unknown = null;
  for (const model of models) {
    const todo = batch.map((_, i) => i).filter((i) => !out.has(i));
    if (!todo.length) break;
    const qs = todo.map((i) => ({
      id: `q${i + 1}`,
      question: batch[i].text,
      options: { A: batch[i].options[0], B: batch[i].options[1], C: batch[i].options[2], D: batch[i].options[3] },
    }));
    const messages = [
      {
        role: 'system' as const,
        content: `You are ${who}. The questions may be in English, Hindi or Tamil, or mix them; you read all three equally well.`,
      },
      {
        role: 'user' as const,
        content: `Work out the correct option of each question. Reply only as JSON:
{"answers":[{"id":"q1","answer":"A","confidence":0.97}]}
- answer is A, B, C or D, or "" when the question is unclear, needs a figure you cannot see, has no correct option, or has more than one.
- confidence is the probability that your answer is right. Be honest: anything you are not certain of is below 0.9.
Questions:
${JSON.stringify(qs)}`,
      },
    ];
    let content: string;
    try {
      // A model that is slow today (the same one answers in 2 s on another call) is cut off, and the next one is asked.
      const cutOff = how.attemptMs === undefined ? how.deadline : Math.min(how.deadline ?? Infinity, Date.now() + how.attemptMs);
      ({ content } = await chat({
        task: how.task ?? 'answer_questions', userId, tuitionId, models: [model], json: true, maxTokens: 3000, reasoning: 'medium', messages, deadline: cutOff,
      }));
    } catch (e) {
      failure = e;
      continue;
    }
    let got = 0;
    for (const a of listIn(content, 'answers')) {
      const i = Number(String(a?.id ?? '').replace(/^q/, '')) - 1;
      if (!todo.includes(i) || out.has(i)) continue;
      const letter = String(a?.answer ?? '').trim().toUpperCase();
      out.set(i, { answer: /^[A-D]$/.test(letter) ? letter.charCodeAt(0) - 65 : null, confidence: conf(a?.confidence) });
      got++;
    }
    if (got > 0) failure = null; // it answered: the next model only fills in what it left out
  }
  if (!out.size && failure) throw failure;
  return out;
}

/** How long a batch of questions stays claimed by a call that has not finished with it. */
const CLAIM_MINUTES = 3;

/** A question AI has looked for this many times, with no model answering it, is left to the tutor. */
const MAX_ANSWER_TRIES = 2;

/**
 * The most time one model gets to answer a batch before the next is asked. They answer in 1 to 5 seconds; one
 * call in a while takes 40 and would hold up the whole paper (a Gemini checker did, in a test).
 */
const ANSWER_ATTEMPT_MS = 20_000;

/** What the first two checks said about a question they could not settle, kept for its second opinion (migration 016). */
type Votes = { solver?: Pick; checker?: Pick; tries: number };

/**
 * Finds answers for the next few unanswered questions: first from the paper's own answer keys,
 * then with AI. Two different models work each question out on their own and it is marked when they
 * pick the same option and each is at least 90% sure. A question they split on or hesitated over keeps
 * what each said and waits for a second opinion, which is a step of its own (`/second-opinion`) so the
 * tutor does not wait for the slow, strong model. A question AI wrote in the chat keeps its writer's
 * answer as one more opinion, which can ask the tutor to check the mark but no longer blocks it. A
 * question no model answered at all is asked again.
 *
 * The app calls this several times at once, and while pages are still being read. Each call claims
 * its own batch (so no question is answered twice), and a call that finds nothing open while pages
 * are still coming simply asks again a moment later. `left` counts the questions nobody has
 * claimed yet; `second` counts the questions of this batch now waiting for a second opinion.
 */
paperRoutes.post('/papers/:id/answers', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'paper id');
  const p = await tq1(T, `select ${PAPER_COLS} from papers p where p.id = $1 and p.tuition_id = @T`, [id]);
  if (!p) throw notFound('This paper');
  if (p.class_level == null) throw new HttpError(409, 'needs_details', 'Choose the class of this paper first.');
  await skipRepeats(id, pool);
  const fromKey = await applyAnswerKeys(id);
  await fillChapters(id);

  const open = `paper_id = $1 and status = 'draft' and kind = 'mcq' and correct_option is null and not answer_checked
                and (answer_claimed_at is null or answer_claimed_at < now() - interval '${CLAIM_MINUTES} minutes')`;
  // AI cannot see a figure, so those wait for the teacher.
  await pool.query(`update paper_drafts set answer_checked = true where ${open} and needs_diagram`, [id]);
  const batch = (
    await q<{ id: string; text: string; options: string[]; page_no: number; seq: number; proposed_option: number | null; answer_tries: number }>(
      `update paper_drafts set answer_claimed_at = now()
        where id in (select id from paper_drafts where ${open} and array_length(options, 1) = 4
                      order by page_no, seq limit ${ANSWER_BATCH} for update skip locked)
        returning id, text, options, page_no, seq, proposed_option, answer_tries`,
      [id],
    )
  ).sort((x, y) => x.page_no - y.page_no || x.seq - y.seq);
  let byAi = 0;
  let second = 0;
  if (batch.length) {
    try {
      const userId = c.get('user').id;
      const how = { attemptMs: ANSWER_ATTEMPT_MS };
      const [a, b] = await Promise.all([solve(SOLVE_MODELS, userId, T, p, batch, how), solve(CHECK_MODELS, userId, T, p, batch, how)]);
      await tx(async (cx) => {
        for (const [i, d] of batch.entries()) {
          const x = a.get(i);
          const y = b.get(i);
          const { mark, note, picks } = verdict(x, y, undefined, d.proposed_option);
          if (mark) byAi++;
          const heard = x != null || y != null;
          // Split or hesitant models (not "no option fits", which is usually a misprint) leave the question
          // waiting for a stronger model's opinion; the card says so until it comes.
          const waits = !mark && note !== 'no_option' && heard && TIEBREAK_MODELS.length > 0;
          if (waits) second++;
          // A question no model said anything about is asked again; after two tries it is left to the tutor.
          const askAgain = !mark && !heard && d.answer_tries + 1 < MAX_ANSWER_TRIES;
          const votes: Votes = { solver: x, checker: y, tries: 0 };
          await cx.query(
            `update paper_drafts set answer_checked = $6, answer_claimed_at = null, answer_tries = answer_tries + 1,
                    correct_option = case when $2::smallint is null then correct_option else $2 end,
                    answer_source = case when $2::smallint is null then answer_source else 'ai' end,
                    ai_confidence = $3,
                    ai_note = case when $4::text is not null and ai_note is null then $4 else ai_note end,
                    ai_picks = case when $5::jsonb is not null then $5::jsonb else ai_picks end,
                    ai_votes = $7::jsonb
              where id = $1 and correct_option is null`,
            [d.id, mark?.answer ?? null, mark?.confidence ?? null, askAgain ? null : note, picks ? JSON.stringify(picks) : null, !askAgain, waits ? JSON.stringify(votes) : null],
          );
        }
      });
    } catch (e) {
      // AI was busy or failed: give the batch back, so the next call (or the teacher's retry) takes it.
      await pool.query(`update paper_drafts set answer_claimed_at = null where id = any($1::uuid[])`, [batch.map((d) => d.id)]).catch(() => {});
      throw e;
    }
  }
  const left = await q1(`select count(*) as n from paper_drafts where ${open}`, [id]);
  return c.json({ from_key: fromKey, by_ai: byAi, tried: batch.length, left: left.n, second });
});

/** How many questions one second-opinion call takes, and the most time it may spend on them (the strong models are slow). */
const SECOND_BATCH = 6;
const SECOND_MS = 55_000;

/** The stronger models take 3 to 40 seconds. Each gets this long, so the one behind it still has time when the first hangs. */
const SECOND_ATTEMPT_MS = 35_000;

/** A second opinion that could not be had this many times is given up on, and the question is left to the tutor. */
const MAX_SECOND_TRIES = 2;

/**
 * The second opinion: questions the first two checks could not settle go to a stronger model, and are marked
 * when two of the three agree (see `verdict`). It is a call of its own, made after the answers, because the
 * strong models are slow and often busy: the tutor reviews the paper while it works, and what it cannot help
 * with stays with the tutor, with what each check chose on the card. A busy model never fails the call: it
 * counts as a try, and after two the question is left alone. `left` counts the questions still waiting that
 * nobody has claimed.
 */
paperRoutes.post('/papers/:id/second-opinion', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'paper id');
  const p = await tq1(T, `select ${PAPER_COLS} from papers p where p.id = $1 and p.tuition_id = @T`, [id]);
  if (!p) throw notFound('This paper');
  if (p.class_level == null) throw new HttpError(409, 'needs_details', 'Choose the class of this paper first.');

  const waiting = `paper_id = $1 and status = 'draft' and kind = 'mcq' and correct_option is null and ai_votes is not null
                   and (answer_claimed_at is null or answer_claimed_at < now() - interval '${CLAIM_MINUTES} minutes')`;
  const batch = (
    await q<{ id: string; text: string; options: string[]; page_no: number; seq: number; proposed_option: number | null; ai_votes: Votes }>(
      `update paper_drafts set answer_claimed_at = now()
        where id in (select id from paper_drafts where ${waiting} and array_length(options, 1) = 4
                      order by page_no, seq limit ${SECOND_BATCH} for update skip locked)
        returning id, text, options, page_no, seq, proposed_option, ai_votes`,
      [id],
    )
  ).sort((x, y) => x.page_no - y.page_no || x.seq - y.seq);
  let byAi = 0;
  const third = new Map<number, Pick>();
  if (batch.length) {
    try {
      const got = await solve(TIEBREAK_MODELS, c.get('user').id, T, p, batch, { task: 'second_opinion', deadline: Date.now() + SECOND_MS, attemptMs: SECOND_ATTEMPT_MS });
      for (const [i, v] of got) third.set(i, v);
    } catch {
      // Nobody could be asked in time. That counts as a try below.
    }
    try {
      await tx(async (cx) => {
        for (const [i, d] of batch.entries()) {
          const t = third.get(i);
          const { mark, note, picks } = verdict(d.ai_votes.solver, d.ai_votes.checker, t, d.proposed_option);
          if (mark) byAi++;
          const tries = (d.ai_votes.tries ?? 0) + 1;
          // Finished when the stronger model has said something, or when it could not be asked twice.
          const done = t != null || tries >= MAX_SECOND_TRIES;
          await cx.query(
            `update paper_drafts set answer_claimed_at = null,
                    correct_option = case when $2::smallint is null then correct_option else $2 end,
                    answer_source = case when $2::smallint is null then answer_source else 'ai' end,
                    ai_confidence = $3, ai_note = $4, ai_picks = $5::jsonb, ai_votes = $6::jsonb
              where id = $1 and correct_option is null and ai_votes is not null`,
            [d.id, mark?.answer ?? null, mark?.confidence ?? null, note, picks ? JSON.stringify(picks) : null, done ? null : JSON.stringify({ ...d.ai_votes, tries })],
          );
        }
      });
    } catch (e) {
      // The claim runs out by itself after a few minutes; the next call takes these again.
      await pool.query(`update paper_drafts set answer_claimed_at = null where id = any($1::uuid[])`, [batch.map((d) => d.id)]).catch(() => {});
      throw e;
    }
  }
  const left = await q1(`select count(*) as n from paper_drafts where ${waiting}`, [id]);
  // `asked` is how many the stronger model gave an opinion on: none means it was busy, and a pause helps before the next call.
  return c.json({ by_ai: byAi, tried: batch.length, asked: third.size, left: left.n });
});

// ---------------------------------------------------------------- checking and saving

paperRoutes.patch('/drafts/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'draft id');
  const b = await readBody(c);
  const d = await tq1(
    tuitionOf(c).id,
    'select d.* from paper_drafts d join papers p on p.id = d.paper_id where d.id = $1 and p.tuition_id = @T',
    [id],
  );
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
  const text = 'text' in b ? str(b, 'text', { max: 4000 })! : d.text;
  // A question the teacher has reworded is new to AI, and one she says "looks right" is checked by
  // her: either way its note goes, and AI may look for its answer.
  const confirmed = b.confirmed === true && d.ai_note === 'unclear';
  const reworded = confirmed || text !== d.text || kind !== d.kind || JSON.stringify(options ?? []) !== JSON.stringify(d.options ?? []);
  const row = await q1(
    `update paper_drafts set text = $2, options = $3, kind = $4, correct_option = $5, chapter_id = $6,
                             needs_diagram = $7, image_key = $8, status = $9,
                             answer_source = case when $10 then (case when $5::smallint is null then null else 'teacher' end) else answer_source end,
                             ai_confidence = case when $10 then null else ai_confidence end,
                             ai_note = case when $11 or ($10 and $5::smallint is not null and ai_note in ('disagree', 'unsure', 'writer_differs'))
                                            then null else ai_note end,
                             ai_picks = case when $11 or ($10 and $5::smallint is not null) then null else ai_picks end,
                             ai_votes = case when $11 or ($10 and $5::smallint is not null) then null else ai_votes end,
                             answer_checked = case when $11 and $5::smallint is null then false else answer_checked end
      where id = $1 returning *`,
    [
      id,
      text,
      options,
      kind,
      correct,
      'chapter_id' in b ? await ownChapter(tuitionOf(c).id, uuidOpt(b.chapter_id, 'chapter')) : d.chapter_id,
      'needs_diagram' in b ? b.needs_diagram === true : d.needs_diagram,
      'image_key' in b ? ownImageKey(tuitionOf(c).id, b.image_key, d.image_key) : d.image_key,
      status,
      marking,
      reworded,
    ],
  );
  return c.json({ draft: { ...row, image_url: await maybeViewUrl(row.image_key) } });
});

/** Saves every checked multiple-choice draft into the question bank. */
paperRoutes.post('/papers/:id/save', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'paper id');
  const paper = await tq1(T, 'select * from papers where id = $1 and tuition_id = @T', [id]);
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
    // A question the bank already has (the same paper uploaded twice, or two papers sharing
    // questions) is not saved again.
    const bank = await tq<{ text: string; options: string[] }>(
      T,
      'select text, options from questions where tuition_id = @T and class_level = $1 and subject_id = $2',
      [paper.class_level, paper.subject_id],
      cx,
    );
    const have = new Set(bank.map((x) => sameKey(x.text, x.options)));
    let already = 0;
    for (const d of ready) {
      const k = sameKey(d.text, d.options);
      if (have.has(k)) {
        await cx.query(`update paper_drafts set status = 'discarded', ai_note = 'in_bank' where id = $1`, [d.id]);
        already++;
        continue;
      }
      have.add(k);
      const qrow = await q1(
        `insert into questions (tuition_id, class_level, chapter_id, text, options, correct_option, keep_option_order, image_key, source, paper_id,
                                created_by, subject_id)
         values ($1, $2, $3, $4, $5, $6, $7, $8, 'paper', $9, $10, $11) returning id`,
        [T, paper.class_level, d.chapter_id ?? paper.chapter_id, d.text, d.options, d.correct_option, mustKeepOrder(d.options), d.image_key, id,
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
    return { saved: ready.length - already, already_in_bank: already, still_to_check: left.n };
  });
  return c.json(result);
});

/** Deletes a paper, its pages and the questions saved from it. Questions a test uses stay in the bank. */
paperRoutes.delete('/papers/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'paper id');
  if (!(await tq1(T, 'select 1 as x from papers where id = $1 and tuition_id = @T', [id]))) throw notFound('This paper');
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
