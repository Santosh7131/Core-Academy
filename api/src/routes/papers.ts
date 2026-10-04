import { Hono } from 'hono';
import type { AppEnv } from '../lib/auth.ts';
import { pool, q, q1, tx } from '../lib/db.ts';
import { chat, parseJson, VISION_MODELS } from '../lib/groq.ts';
import { bad, HttpError, int, notFound, str, uuid, uuidOpt } from '../lib/http.ts';
import { mustKeepOrder } from '../lib/questions.ts';
import { deleteObjects, maybeViewUrl, readObject, uploadUrl, viewUrl } from '../lib/storage.ts';
import { readBody } from './body.ts';

// Mounted behind requireUser('teacher') in index.ts.
export const paperRoutes = new Hono<AppEnv>();

const MAX_PAGES = 20;
const pageKey = (paperId: string, pageNo: number) => `papers/${paperId}/p${pageNo}.jpg`;

paperRoutes.get('/papers', async (c) => {
  const rows = await q(
    `select p.id, p.class_level, p.exam_name, p.year, p.page_count, p.created_at, s.name as school,
            (select count(*) from paper_pages pp where pp.paper_id = p.id and pp.ai_status = 'done') as pages_read,
            (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'draft' and d.kind = 'mcq') as to_check,
            (select count(*) from paper_drafts d where d.paper_id = p.id and d.status = 'saved') as saved
       from papers p left join schools s on s.id = p.school_id
      order by p.created_at desc`,
  );
  return c.json({ papers: rows });
});

/** Creates the paper and hands back one direct-upload URL per page. */
paperRoutes.post('/papers', async (c) => {
  const b = await readBody(c);
  const pages = int(b, 'pages', { min: 1, max: MAX_PAGES })!;
  const paper = await tx(async (cx) => {
    const p = await q1(
      `insert into papers (school_id, class_level, exam_name, year, page_count, uploaded_by)
       values ($1, $2, $3, $4, $5, $6) returning id, class_level, exam_name, year, page_count`,
      [uuidOpt(b.school_id, 'school'), int(b, 'class_level', { min: 6, max: 12 }), str(b, 'exam_name', { max: 80 }),
        int(b, 'year', { min: 2000, max: 2100, optional: true }) ?? null, pages, c.get('user').id],
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

paperRoutes.get('/papers/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const p = await q1(
    `select p.*, s.name as school from papers p left join schools s on s.id = p.school_id where p.id = $1`,
    [id],
  );
  if (!p) throw notFound('This paper');
  const pages = await q('select page_no, object_key, uploaded, ai_status, ai_error, read_at from paper_pages where paper_id = $1 order by page_no', [id]);
  const drafts = await q(
    `select d.*, ch.name as chapter from paper_drafts d left join chapters ch on ch.id = d.chapter_id
      where d.paper_id = $1 order by d.page_no, d.seq`,
    [id],
  );
  const chapters = await q('select id, name from chapters where class_level = $1 order by sort_order, name', [p.class_level]);
  return c.json({
    paper: p,
    pages: await Promise.all(pages.map(async (pg) => ({ ...pg, image_url: pg.uploaded ? await viewUrl(pg.object_key) : null }))),
    drafts: await Promise.all(drafts.map(async (d) => ({ ...d, image_url: await maybeViewUrl(d.image_key) }))),
    chapters,
  });
});

type Extracted = {
  number?: unknown; kind?: unknown; text?: unknown; options?: unknown; needs_diagram?: unknown; chapter_guess?: unknown;
};

function prompt(classLevel: number, pageNo: number, chapters: string[]) {
  return `This image is page ${pageNo} of a Class ${classLevel} CBSE mathematics question paper.
Transcribe every question printed on this page, in order, as JSON:
{"questions":[{"number":"<question number as printed>","kind":"mcq" or "other","text":"<question text>","options":["<a>","<b>","<c>","<d>"],"needs_diagram":true or false,"chapter_guess":"<chapter>"}]}
Rules:
- Copy the wording exactly. Write all maths in LaTeX inside $...$, e.g. $\\frac{3}{4}$, $x^2$, $\\sqrt{2}$, $90^\\circ$.
- "mcq" only when exactly four options are printed. Give the option text without its (a)/(A)/(i) label, in printed order. Otherwise use "other" with "options": [].
- needs_diagram is true when the question depends on a figure, graph or diagram.
- chapter_guess must be one of: ${chapters.length ? chapters.map((n) => JSON.stringify(n)).join(', ') : '(none listed)'}; use "" if unsure.
- Skip instructions, section headings and marks notes.
- Never answer, solve or mark a correct option.
- If the page has no questions, return {"questions":[]}.`;
}

const clip = (v: unknown, max: number) => (typeof v === 'string' ? v.trim().slice(0, max) : '');

/** Reads one page with Groq and replaces that page's unchecked drafts. */
paperRoutes.post('/papers/:id/pages/:n/read', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const pageNo = Number(c.req.param('n'));
  const page = await q1(
    `select pp.*, p.class_level from paper_pages pp join papers p on p.id = pp.paper_id where pp.paper_id = $1 and pp.page_no = $2`,
    [id, pageNo],
  );
  if (!page) throw notFound('This page');
  if (!page.uploaded) throw new HttpError(409, 'not_uploaded', 'This page has not finished uploading.');
  const chapters = await q<{ id: string; name: string }>('select id, name from chapters where class_level = $1', [page.class_level]);

  await pool.query(`update paper_pages set ai_status = 'reading', ai_error = null where id = $1`, [page.id]);
  let items: Extracted[];
  try {
    const img = await readObject(page.object_key);
    const dataUrl = `data:${img.type};base64,${img.bytes.toString('base64')}`;
    const { content } = await chat({
      task: 'read_paper_page',
      userId: c.get('user').id,
      models: VISION_MODELS,
      json: true,
      maxTokens: 6000,
      messages: [
        { role: 'system', content: 'You transcribe printed exam papers into JSON. You never solve questions or add answers.' },
        {
          role: 'user',
          content: [
            { type: 'text', text: prompt(page.class_level, pageNo, chapters.map((ch) => ch.name)) },
            { type: 'image_url', image_url: { url: dataUrl } },
          ],
        },
      ],
    });
    const parsed = parseJson<{ questions?: Extracted[] }>(content);
    if (!Array.isArray(parsed.questions)) throw new Error('The reply had no questions list.');
    items = parsed.questions.slice(0, 60);
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
      await cx.query(
        `insert into paper_drafts (paper_id, page_no, seq, number_label, kind, text, options, chapter_id, ai_chapter_guess, needs_diagram)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [id, pageNo, seq++, clip(it.number, 20) || null, kind, text, options, byName.get(guess.toLowerCase()) ?? null,
          guess || null, it.needs_diagram === true],
      );
    }
    await cx.query(`update paper_pages set ai_status = 'done', read_at = now() where id = $1`, [page.id]);
  });
  const drafts = await q('select * from paper_drafts where paper_id = $1 and page_no = $2 order by seq', [id, pageNo]);
  return c.json({ page_no: pageNo, drafts });
});

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
  const correct = 'correct_option' in b ? (b.correct_option === null ? null : int(b, 'correct_option', { min: 0, max: 3 })) : d.correct_option;
  const status = 'status' in b ? (b.status === 'discarded' ? 'discarded' : 'draft') : d.status;
  const row = await q1(
    `update paper_drafts set text = $2, options = $3, kind = $4, correct_option = $5, chapter_id = $6,
                             needs_diagram = $7, image_key = $8, status = $9
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
    ],
  );
  return c.json({ draft: { ...row, image_url: await maybeViewUrl(row.image_key) } });
});

/** Saves every checked multiple-choice draft into the question bank. */
paperRoutes.post('/papers/:id/save', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const paper = await q1('select * from papers where id = $1', [id]);
  if (!paper) throw notFound('This paper');
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
        `insert into questions (class_level, chapter_id, text, options, correct_option, keep_option_order, image_key, source, paper_id, created_by)
         values ($1, $2, $3, $4, $5, $6, $7, 'paper', $8, $9) returning id`,
        [paper.class_level, d.chapter_id, d.text, d.options, d.correct_option, mustKeepOrder(d.options), d.image_key, id, c.get('user').id],
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

paperRoutes.delete('/papers/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'paper id');
  const keys = await q<{ object_key: string }>('select object_key from paper_pages where paper_id = $1', [id]);
  await pool.query('delete from papers where id = $1', [id]);
  await deleteObjects(keys.map((k) => k.object_key)).catch(() => {});
  return c.json({ ok: true });
});
