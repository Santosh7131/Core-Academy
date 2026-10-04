import { randomUUID } from 'node:crypto';
import { waitUntil } from '@neon/functions';
import { Hono } from 'hono';
import {
  checkPassword, checkPin, checkUsername, hashSecret, killSessions, newPin, verifySecret, type AppEnv,
} from '../lib/auth.ts';
import { ASSIGNED_CTE, resultPayload } from '../lib/attempts.ts';
import { pool, q, q1, tx } from '../lib/db.ts';
import { bad, bool, date, HttpError, int, notFound, str, uuid, uuidOpt } from '../lib/http.ts';
import { afterTestChange } from '../lib/notify.ts';
import { mustKeepOrder } from '../lib/questions.ts';
import { deleteObjects, maybeViewUrl, uploadUrl } from '../lib/storage.ts';
import { MATHS, STUDENT_SUBJECTS, subjectIds } from '../lib/subjects.ts';
import { readBody } from './body.ts';

// Mounted behind requireUser('teacher') in index.ts.
export const teacherRoutes = new Hono<AppEnv>();

const pct = (score: number | null, max: number | null) => (score == null || !max ? null : score / max);

// ---------------------------------------------------------------- dashboard

teacherRoutes.get('/dashboard', async (c) => {
  await q('select finalize_expired_attempts()');
  const b = await q1(
    `select now() as now,
            (date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata') as d0`,
  );
  const stats = await q1(
    `with ${ASSIGNED_CTE}
     select
       (select count(*) from attempts where submitted_at >= $1::timestamptz) as submitted_today,
       (select count(*) from assigned a join tests t on t.id = a.test_id
         where (t.opens_at is not null or t.closes_at is not null)
           and coalesce(t.opens_at, '-infinity') < $1::timestamptz + interval '1 day'
           and coalesce(t.closes_at, 'infinity') > $1::timestamptz) as due_today,
       (select count(*) from attempts where submitted_at is null and (deadline_at is null or deadline_at > now())) as writing_now,
       (select count(*) from assigned a join tests t on t.id = a.test_id
         where t.closes_at between now() - interval '7 days' and now()
           and not exists (select 1 from attempts x where x.test_id = a.test_id and x.student_id = a.student_id)) as missed_week`,
    [b.d0],
  );
  const live = await q(
    `with ${ASSIGNED_CTE}
     select t.id, t.title, t.class_level, t.opens_at, t.closes_at, (select name from subjects where id = t.subject_id) as subject,
            (select count(*) from assigned a where a.test_id = t.id) as assigned,
            (select count(distinct x.student_id) from attempts x where x.test_id = t.id and x.submitted_at is not null) as submitted,
            (select count(*) from attempts x where x.test_id = t.id and x.submitted_at is null) as writing
       from tests t
      where t.status = 'published'
        and (t.opens_at is null or t.opens_at <= now())
        and (t.closes_at > now() or exists (select 1 from attempts x where x.test_id = t.id and x.submitted_at is null))
      order by t.closes_at nulls last
      limit 10`,
  );
  const attention = await q(
    `with ${ASSIGNED_CTE},
     missed as (
       select a.student_id, count(*) as missed from assigned a join tests t on t.id = a.test_id
        where t.closes_at between now() - interval '7 days' and now()
          and not exists (select 1 from attempts x where x.test_id = a.test_id and x.student_id = a.student_id)
        group by 1),
     recent as (
       select student_id, avg(score / nullif(max_score, 0)) as avg_pct, count(*) as n
         from (select student_id, score, max_score,
                      row_number() over (partition by student_id order by submitted_at desc) as rn
                 from attempts where submitted_at is not null) z
        where rn <= 3 group by 1)
     select u.id, u.display_name, u.class_level, coalesce(m.missed, 0) as missed, r.avg_pct, coalesce(r.n, 0) as recent_count
       from users u left join missed m on m.student_id = u.id left join recent r on r.student_id = u.id
      where u.role = 'student' and u.active
        and (coalesce(m.missed, 0) >= 2 or (r.n >= 2 and r.avg_pct < 0.4))
      order by coalesce(m.missed, 0) desc, r.avg_pct asc nulls last
      limit 10`,
  );
  const activity = await q(
    `select * from (
       select a.id as attempt_id, 'submitted' as kind, a.submitted_at as at, u.id as student_id, u.display_name,
              t.title, a.score, a.max_score
         from attempts a join users u on u.id = a.student_id join tests t on t.id = a.test_id
        where a.submitted_at is not null
       union all
       select a.id, 'started', a.started_at, u.id, u.display_name, t.title, null, null
         from attempts a join users u on u.id = a.student_id join tests t on t.id = a.test_id
        where a.submitted_at is null
     ) e order by at desc limit 12`,
  );
  return c.json({ server_now: b.now, stats, live, attention, activity });
});

// ---------------------------------------------------------------- students

teacherRoutes.get('/students', async (c) => {
  const cls = c.req.query('class');
  const subject = c.req.query('subject');
  const rows = await q(
    `select u.id, u.display_name, u.username, u.class_level, u.school_id, s.name as school, u.active, u.last_seen_at,
            (select avg(score / nullif(max_score, 0)) from attempts a where a.student_id = u.id and a.submitted_at is not null) as avg_pct,
            (select count(*) from attempts a where a.student_id = u.id and a.submitted_at is not null) as tests_done,
            ${STUDENT_SUBJECTS}
       from users u left join schools s on s.id = u.school_id
      where u.role = 'student' and ($1::smallint is null or u.class_level = $1)
        and ($2::uuid is null or exists (select 1 from student_subjects ss where ss.student_id = u.id and ss.subject_id = $2))
      order by u.active desc, u.class_level, u.display_name`,
    [cls ? Number(cls) : null, subject ? uuid(subject, 'subject') : null],
  );
  return c.json({ students: rows });
});

async function setStudentSubjects(cx: any, studentId: string, ids: string[]) {
  await cx.query('delete from student_subjects where student_id = $1', [studentId]);
  if (ids.length) {
    await cx.query('insert into student_subjects (student_id, subject_id) select $1, unnest($2::uuid[])', [studentId, ids]);
  }
}

teacherRoutes.post('/students', async (c) => {
  const b = await readBody(c);
  const displayName = str(b, 'display_name', { max: 60 })!;
  const classLevel = int(b, 'class_level', { min: 6, max: 12 })!;
  const schoolId = uuidOpt(b.school_id, 'school');
  const username = checkUsername(b.username);
  // The app before subjects sends none: its students study maths.
  const subjects = 'subject_ids' in b ? subjectIds(b.subject_ids) : [MATHS];
  const pin = b.pin === undefined || b.pin === null || b.pin === '' ? newPin() : checkPin(b.pin);
  const { hash, salt } = await hashSecret(pin);
  try {
    const u = await tx(async (cx) => {
      const row = await q1(
        `insert into users (role, username, display_name, class_level, school_id, secret_hash, secret_salt)
         values ('student', $1, $2, $3, $4, $5, $6) returning id, username, display_name, class_level, school_id`,
        [username, displayName, classLevel, schoolId, hash, salt],
        cx,
      );
      await setStudentSubjects(cx, row.id, subjects);
      return row;
    });
    return c.json({ student: u, login: { username, pin } }, 201);
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'username_taken', `The username ${username} is already taken.`);
    if (e.code === '23503') throw bad('One of those subjects no longer exists.');
    throw e;
  }
});

teacherRoutes.get('/students/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'student id');
  await q('select finalize_expired_attempts()');
  const s = await q1(
    `select u.id, u.display_name, u.username, u.class_level, u.school_id, sc.name as school, u.active, u.last_seen_at, u.created_at,
            ${STUDENT_SUBJECTS}
       from users u left join schools sc on sc.id = u.school_id where u.id = $1 and u.role = 'student'`,
    [id],
  );
  if (!s) throw notFound('This student');
  const attempts = await q(
    `select a.id, a.test_id, t.title, a.attempt_no, a.score, a.max_score, a.correct_count, a.wrong_count, a.skipped_count,
            a.started_at, a.submitted_at, a.auto_submitted
       from attempts a join tests t on t.id = a.test_id where a.student_id = $1 order by a.started_at desc`,
    [id],
  );
  const chapters = await q(
    `select coalesce(ch.name, 'No chapter') as chapter, count(*) as total,
            count(*) filter (where an.chosen_option = qq.correct_option) as correct
       from attempts a cross join lateral unnest(a.question_order) as qo(qid)
       join questions qq on qq.id = qo.qid
       left join answers an on an.attempt_id = a.id and an.question_id = qq.id
       left join chapters ch on ch.id = qq.chapter_id
      where a.student_id = $1 and a.submitted_at is not null
      group by 1 order by 1`,
    [id],
  );
  const missed = await q(
    `with ${ASSIGNED_CTE}
     select t.id, t.title, t.closes_at from assigned a join tests t on t.id = a.test_id
      where a.student_id = $1 and t.closes_at < now()
        and not exists (select 1 from attempts x where x.test_id = t.id and x.student_id = $1)
      order by t.closes_at desc`,
    [id],
  );
  return c.json({ student: s, attempts, chapters, missed });
});

teacherRoutes.patch('/students/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'student id');
  const b = await readBody(c);
  const subjects = 'subject_ids' in b ? subjectIds(b.subject_ids) : null;
  const u = await tx(async (cx) => {
    const row = await q1(
      `update users set display_name = coalesce($2, display_name),
                        class_level = coalesce($3, class_level),
                        school_id = case when $5 then $4::uuid else school_id end
        where id = $1 and role = 'student' returning id, display_name, class_level, school_id`,
      [id, str(b, 'display_name', { max: 60, optional: true }) ?? null, int(b, 'class_level', { min: 6, max: 12, optional: true }) ?? null,
        uuidOpt(b.school_id, 'school'), 'school_id' in b],
      cx,
    );
    if (row && subjects) await setStudentSubjects(cx, id, subjects);
    return row;
  });
  if (!u) throw notFound('This student');
  return c.json({ student: u });
});

teacherRoutes.post('/students/:id/reset-pin', async (c) => {
  const id = uuid(c.req.param('id'), 'student id');
  const b = await readBody(c);
  const pin = b.pin ? checkPin(b.pin) : newPin();
  const { hash, salt } = await hashSecret(pin);
  const u = await q1(
    `update users set secret_hash = $2, secret_salt = $3, failed_count = 0, locked_until = null
      where id = $1 and role = 'student' returning username`,
    [id, hash, salt],
  );
  if (!u) throw notFound('This student');
  await killSessions(id);
  return c.json({ login: { username: u.username, pin } });
});

teacherRoutes.post('/students/:id/active', async (c) => {
  const id = uuid(c.req.param('id'), 'student id');
  const active = bool(await readBody(c), 'active');
  const u = await q1(`update users set active = $2 where id = $1 and role = 'student' returning id, active`, [id, active]);
  if (!u) throw notFound('This student');
  if (!active) await killSessions(id);
  return c.json({ student: u });
});

// ---------------------------------------------------------------- schools and chapters

teacherRoutes.get('/schools', async (c) => {
  const rows = await q(
    `select s.id, s.name, (select count(*) from users u where u.school_id = s.id and u.role = 'student') as students
       from schools s order by s.name`,
  );
  return c.json({ schools: rows });
});

teacherRoutes.post('/schools', async (c) => {
  const name = str(await readBody(c), 'name', { max: 80 })!;
  try {
    return c.json({ school: await q1('insert into schools (name) values ($1) returning id, name', [name]) }, 201);
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'duplicate', `${name} is already in the list.`);
    throw e;
  }
});

teacherRoutes.patch('/schools/:id', async (c) => {
  const name = str(await readBody(c), 'name', { max: 80 })!;
  const s = await q1('update schools set name = $2 where id = $1 returning id, name', [uuid(c.req.param('id')), name]);
  if (!s) throw notFound('This school');
  return c.json({ school: s });
});

teacherRoutes.delete('/schools/:id', async (c) => {
  await pool.query('delete from schools where id = $1', [uuid(c.req.param('id'))]);
  return c.json({ ok: true });
});

// ---------------------------------------------------------------- subjects and groups

teacherRoutes.get('/subjects', async (c) => {
  const rows = await q(
    `select sj.id, sj.name, sj.sort_order, sj.id = $1 as is_default,
            (select count(*) from student_subjects ss join users u on u.id = ss.student_id
              where ss.subject_id = sj.id and u.active) as students,
            (select count(*) from chapters ch where ch.subject_id = sj.id) as chapters,
            (select count(*) from questions qq where qq.subject_id = sj.id) as questions,
            (select count(*) from tests t where t.subject_id = sj.id) as tests
       from subjects sj order by sj.sort_order, sj.name`,
    [MATHS],
  );
  return c.json({ subjects: rows });
});

teacherRoutes.post('/subjects', async (c) => {
  const name = str(await readBody(c), 'name', { max: 40 })!;
  try {
    const sj = await q1(
      `insert into subjects (name, sort_order) values ($1, coalesce((select max(sort_order) + 1 from subjects), 0))
       returning id, name, sort_order`,
      [name],
    );
    return c.json({ subject: sj }, 201);
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'duplicate', `${name} is already a subject.`);
    throw e;
  }
});

teacherRoutes.patch('/subjects/:id', async (c) => {
  const name = str(await readBody(c), 'name', { max: 40 })!;
  try {
    const sj = await q1('update subjects set name = $2 where id = $1 returning id, name, sort_order', [uuid(c.req.param('id')), name]);
    if (!sj) throw notFound('This subject');
    return c.json({ subject: sj });
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'duplicate', `${name} is already a subject.`);
    throw e;
  }
});

teacherRoutes.delete('/subjects/:id', async (c) => {
  const id = uuid(c.req.param('id'));
  if (id === MATHS) throw new HttpError(409, 'default_subject', 'Maths is the main subject, so it stays.');
  const used = await q1(
    `select (select count(*) from chapters where subject_id = $1) + (select count(*) from questions where subject_id = $1)
          + (select count(*) from tests where subject_id = $1) + (select count(*) from papers where subject_id = $1) as n`,
    [id],
  );
  if (used.n > 0) throw new HttpError(409, 'in_use', 'This subject has chapters, questions, papers or tests. Delete those first.');
  await pool.query('delete from subjects where id = $1', [id]);
  return c.json({ ok: true });
});

/** Groups that have students: one per class and subject, e.g. "10th Science". */
teacherRoutes.get('/groups', async (c) => {
  const rows = await q(
    `select u.class_level, sj.id as subject_id, sj.name as subject, count(*) as students
       from student_subjects ss join users u on u.id = ss.student_id and u.role = 'student' and u.active
       join subjects sj on sj.id = ss.subject_id
      group by u.class_level, sj.id, sj.name, sj.sort_order
      order by u.class_level, sj.sort_order, sj.name`,
  );
  return c.json({ groups: rows });
});

teacherRoutes.get('/chapters', async (c) => {
  const cls = c.req.query('class');
  const subject = c.req.query('subject');
  const rows = await q(
    `select ch.id, ch.class_level, ch.subject_id, ch.name, ch.sort_order,
            (select count(*) from questions qq where qq.chapter_id = ch.id) as questions
       from chapters ch
      where ($1::smallint is null or ch.class_level = $1) and ($2::uuid is null or ch.subject_id = $2)
      order by ch.class_level, ch.sort_order, ch.name`,
    [cls ? Number(cls) : null, subject ? uuid(subject, 'subject') : null],
  );
  return c.json({ chapters: rows });
});

teacherRoutes.post('/chapters', async (c) => {
  const b = await readBody(c);
  const cls = int(b, 'class_level', { min: 6, max: 12 })!;
  const name = str(b, 'name', { max: 80 })!;
  const subject = uuidOpt(b.subject_id, 'subject') ?? MATHS;
  try {
    const ch = await q1(
      `insert into chapters (class_level, subject_id, name, sort_order)
       values ($1, $2, $3, coalesce((select max(sort_order) + 1 from chapters where class_level = $1 and subject_id = $2), 0))
       returning id, class_level, subject_id, name, sort_order`,
      [cls, subject, name],
    );
    return c.json({ chapter: ch }, 201);
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'duplicate', `This subject already has a Class ${cls} chapter called ${name}.`);
    if (e.code === '23503') throw bad('That subject no longer exists.');
    throw e;
  }
});

teacherRoutes.patch('/chapters/:id', async (c) => {
  const b = await readBody(c);
  const ch = await q1(
    `update chapters set name = coalesce($2, name), sort_order = coalesce($3, sort_order) where id = $1
     returning id, class_level, name, sort_order`,
    [uuid(c.req.param('id')), str(b, 'name', { max: 80, optional: true }) ?? null, int(b, 'sort_order', { optional: true }) ?? null],
  );
  if (!ch) throw notFound('This chapter');
  return c.json({ chapter: ch });
});

teacherRoutes.delete('/chapters/:id', async (c) => {
  await pool.query('delete from chapters where id = $1', [uuid(c.req.param('id'))]);
  return c.json({ ok: true });
});

// ---------------------------------------------------------------- questions

function readQuestion(b: Record<string, any>) {
  const options = b.options;
  if (!Array.isArray(options) || options.length !== 4 || options.some((o) => typeof o !== 'string' || !o.trim())) {
    throw bad('A question needs exactly 4 filled-in options.');
  }
  const opts = options.map((o: string) => o.trim());
  return {
    class_level: int(b, 'class_level', { min: 6, max: 12 })!,
    chapter_id: uuidOpt(b.chapter_id, 'chapter'),
    subject_id: uuidOpt(b.subject_id, 'subject'),
    text: str(b, 'text', { max: 4000 })!,
    options: opts,
    correct_option: int(b, 'correct_option', { min: 0, max: 3 })!,
    solution: str(b, 'solution', { max: 4000, optional: true }) ?? null,
    marks: b.marks === undefined || b.marks === null ? 1 : Number(b.marks),
    keep_option_order: typeof b.keep_option_order === 'boolean' ? b.keep_option_order : mustKeepOrder(opts),
    image_key: typeof b.image_key === 'string' && b.image_key ? b.image_key : null,
  };
}

const QUESTION_COLS = `qq.id, qq.class_level, qq.chapter_id, ch.name as chapter, qq.subject_id,
  (select name from subjects where id = qq.subject_id) as subject, qq.text, qq.options, qq.correct_option,
  qq.solution, qq.marks, qq.keep_option_order, qq.image_key, qq.source, qq.paper_id, qq.created_at, qq.updated_at,
  (select count(*) from test_questions tq where tq.question_id = qq.id) as used_in`;

// A question's subject: its chapter's subject, else the one sent, else (on create) Maths.
const QUESTION_SUBJECT = (chapterParam: string, subjectParam: string, fallback: string) =>
  `coalesce((select subject_id from chapters where id = ${chapterParam}), ${subjectParam}, ${fallback})`;

async function withImage<T extends { image_key: string | null }>(row: T) {
  return { ...row, image_url: await maybeViewUrl(row.image_key) };
}

teacherRoutes.get('/questions', async (c) => {
  const cls = c.req.query('class');
  const chapter = c.req.query('chapter');
  const subject = c.req.query('subject');
  const search = c.req.query('q');
  const rows = await q(
    `select ${QUESTION_COLS} from questions qq left join chapters ch on ch.id = qq.chapter_id
      where ($1::smallint is null or qq.class_level = $1)
        and ($2::uuid is null or qq.chapter_id = $2)
        and ($3::text is null or qq.text ilike '%' || $3 || '%')
        and ($4::uuid is null or qq.subject_id = $4)
      order by qq.class_level, ch.sort_order nulls last, qq.created_at desc
      limit 300`,
    [cls ? Number(cls) : null, chapter ? uuid(chapter, 'chapter') : null, search?.trim() || null, subject ? uuid(subject, 'subject') : null],
  );
  return c.json({ questions: await Promise.all(rows.map(withImage)) });
});

teacherRoutes.get('/questions/:id', async (c) => {
  const row = await q1(
    `select ${QUESTION_COLS} from questions qq left join chapters ch on ch.id = qq.chapter_id where qq.id = $1`,
    [uuid(c.req.param('id'))],
  );
  if (!row) throw notFound('This question');
  return c.json({ question: await withImage(row) });
});

teacherRoutes.post('/questions', async (c) => {
  const x = readQuestion(await readBody(c));
  if (!(x.marks > 0 && x.marks <= 100)) throw bad('Marks must be between 0 and 100.');
  const row = await q1(
    `insert into questions (class_level, chapter_id, text, options, correct_option, solution, marks, keep_option_order, image_key, created_by,
                            subject_id)
     values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, ${QUESTION_SUBJECT('$2::uuid', '$11::uuid', `'${MATHS}'::uuid`)}) returning id`,
    [x.class_level, x.chapter_id, x.text, x.options, x.correct_option, x.solution, x.marks, x.keep_option_order, x.image_key, c.get('user').id,
      x.subject_id],
  );
  return c.json({ id: row.id }, 201);
});

teacherRoutes.patch('/questions/:id', async (c) => {
  const x = readQuestion(await readBody(c));
  const row = await q1(
    `update questions set class_level = $2, chapter_id = $3, text = $4, options = $5, correct_option = $6, solution = $7,
                          marks = $8, keep_option_order = $9, image_key = $10, updated_at = now(),
                          subject_id = ${QUESTION_SUBJECT('$3::uuid', '$11::uuid', 'subject_id')}
      where id = $1 returning id`,
    [uuid(c.req.param('id')), x.class_level, x.chapter_id, x.text, x.options, x.correct_option, x.solution, x.marks, x.keep_option_order, x.image_key,
      x.subject_id],
  );
  if (!row) throw notFound('This question');
  return c.json({ id: row.id });
});

teacherRoutes.delete('/questions/:id', async (c) => {
  const id = uuid(c.req.param('id'));
  const used = await q1('select count(*) as n from test_questions where question_id = $1', [id]);
  if (used.n > 0) throw new HttpError(409, 'in_use', 'This question is in a test. Remove it from the test first.');
  await pool.query('delete from questions where id = $1', [id]);
  return c.json({ ok: true });
});

/** A direct upload URL for a question diagram. */
teacherRoutes.post('/uploads', async (c) => {
  const key = `questions/${randomUUID()}.jpg`;
  return c.json({ key, put_url: await uploadUrl(key) });
});

// ---------------------------------------------------------------- tests

function readTest(b: Record<string, any>) {
  const ids = b.question_ids;
  if (!Array.isArray(ids) || ids.some((x) => typeof x !== 'string')) throw bad('question_ids must be a list.');
  const students = b.student_ids ?? [];
  if (!Array.isArray(students)) throw bad('student_ids must be a list.');
  const opensAt = date(b, 'opens_at');
  const closesAt = date(b, 'closes_at');
  if (opensAt && closesAt && opensAt >= closesAt) throw bad('The test must close after it opens.');
  const assignAll = bool(b, 'assign_all', true);
  // The app before subjects never sends these: null keeps what the test already has.
  const assignGroup = 'assign_group' in b ? bool(b, 'assign_group', false) : null;
  if (assignAll && assignGroup) throw bad('A test goes to the whole class or to the group, not both.');
  return {
    title: str(b, 'title', { max: 100 })!,
    class_level: int(b, 'class_level', { min: 6, max: 12 })!,
    subject_id: uuidOpt(b.subject_id, 'subject'),
    time_limit_min: int(b, 'time_limit_min', { min: 1, max: 300, optional: true }) ?? null,
    opens_at: opensAt,
    closes_at: closesAt,
    shuffle: bool(b, 'shuffle', true),
    assign_all: assignAll,
    assign_group: assignGroup,
    question_ids: [...new Set(ids.map((x: string) => uuid(x, 'question id')))],
    student_ids: [...new Set(students.map((x: string) => uuid(x, 'student id')))],
  };
}

async function saveTestChildren(c: any, testId: string, t: ReturnType<typeof readTest>) {
  await c.query('delete from test_questions where test_id = $1', [testId]);
  await c.query(
    `insert into test_questions (test_id, question_id, position)
     select $1, x.id, x.ord from unnest($2::uuid[]) with ordinality as x(id, ord)`,
    [testId, t.question_ids],
  );
  await c.query('delete from test_students where test_id = $1', [testId]);
  const chosen = await c.query('select not assign_all and not assign_group as chosen from tests where id = $1', [testId]);
  if (chosen.rows[0]?.chosen && t.student_ids.length) {
    await c.query(`insert into test_students (test_id, student_id) select $1, unnest($2::uuid[])`, [testId, t.student_ids]);
  }
}

teacherRoutes.get('/tests', async (c) => {
  await q('select finalize_expired_attempts()');
  const rows = await q(
    `with ${ASSIGNED_CTE}
     select t.id, t.title, t.class_level, t.time_limit_min, t.opens_at, t.closes_at, t.shuffle, t.assign_all, t.status, t.created_at,
            t.subject_id, (select name from subjects where id = t.subject_id) as subject, t.assign_group,
            (select count(*) from test_questions tq where tq.test_id = t.id) as question_count,
            (select count(*) from assigned a where a.test_id = t.id) as assigned,
            (select count(distinct x.student_id) from attempts x where x.test_id = t.id and x.submitted_at is not null) as submitted,
            (select count(*) from attempts x where x.test_id = t.id and x.submitted_at is null) as writing,
            now() as now
       from tests t
      order by coalesce(t.closes_at, t.opens_at, t.created_at) desc`,
  );
  return c.json({ tests: rows });
});

teacherRoutes.post('/tests', async (c) => {
  const t = readTest(await readBody(c));
  const id = await tx(async (cx) => {
    const row = await q1(
      `insert into tests (title, class_level, time_limit_min, opens_at, closes_at, shuffle, assign_all, created_by, subject_id, assign_group)
       values ($1, $2, $3, $4, $5, $6, $7, $8, coalesce($9, '${MATHS}'::uuid), coalesce($10, false)) returning id`,
      [t.title, t.class_level, t.time_limit_min, t.opens_at, t.closes_at, t.shuffle, t.assign_all, c.get('user').id,
        t.subject_id, t.assign_group],
      cx,
    );
    await saveTestChildren(cx, row.id, t);
    return row.id;
  });
  return c.json({ id }, 201);
});

teacherRoutes.get('/tests/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'test id');
  const t = await q1(
    `select t.*, (select count(*) from attempts x where x.test_id = t.id) as attempts from tests t where t.id = $1`,
    [id],
  );
  if (!t) throw notFound('This test');
  const questions = await q(
    `select ${QUESTION_COLS}, tq.position from test_questions tq join questions qq on qq.id = tq.question_id
       left join chapters ch on ch.id = qq.chapter_id where tq.test_id = $1 order by tq.position`,
    [id],
  );
  const students = await q(
    `select u.id, u.display_name, u.class_level from test_students ts join users u on u.id = ts.student_id
      where ts.test_id = $1 order by u.display_name`,
    [id],
  );
  return c.json({ test: t, questions: await Promise.all(questions.map(withImage)), students });
});

teacherRoutes.patch('/tests/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'test id');
  const t = readTest(await readBody(c));
  const status = await tx(async (cx) => {
    const cur = await q1(
      `select (select count(*) from attempts x where x.test_id = $1) as attempts,
              array(select question_id from test_questions where test_id = $1 order by position) as qids`,
      [id],
      cx,
    );
    const sameQuestions = JSON.stringify(cur.qids) === JSON.stringify(t.question_ids);
    if (cur.attempts > 0 && !sameQuestions) {
      throw new HttpError(409, 'has_attempts', 'Students have already started this test, so its questions cannot change.');
    }
    // Moved to open later: students are told again when it opens. A new closing time gets its
    // own reminder.
    const row = await q1(
      `update tests set title = $2, class_level = $3, time_limit_min = $4, opens_at = $5, closes_at = $6,
                        shuffle = $7, assign_all = $8, subject_id = coalesce($9, subject_id),
                        assign_group = case when $8 then false else coalesce($10, assign_group) end,
                        announced_at = case when $5::timestamptz > now() then null else announced_at end,
                        reminded_at = case when $6::timestamptz is distinct from closes_at then null else reminded_at end
        where id = $1 returning id, status`,
      [id, t.title, t.class_level, t.time_limit_min, t.opens_at, t.closes_at, t.shuffle, t.assign_all, t.subject_id, t.assign_group],
      cx,
    );
    if (!row) throw notFound('This test');
    await saveTestChildren(cx, id, t);
    return row.status as string;
  });
  if (status === 'published') waitUntil(afterTestChange());
  return c.json({ id });
});

teacherRoutes.post('/tests/:id/publish', async (c) => {
  const id = uuid(c.req.param('id'), 'test id');
  const published = bool(await readBody(c), 'published');
  if (published) {
    const n = await q1('select count(*) as n from test_questions where test_id = $1', [id]);
    if (!n || n.n === 0) throw new HttpError(409, 'empty_test', 'Add at least one question before publishing.');
  }
  const t = await q1(
    `update tests set status = $2 where id = $1 returning id, status`,
    [id, published ? 'published' : 'draft'],
  );
  if (!t) throw notFound('This test');
  // Students hear about it after the teacher's screen has its answer.
  if (published) waitUntil(afterTestChange());
  return c.json({ test: t });
});

teacherRoutes.delete('/tests/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'test id');
  const n = await q1('select count(*) as n from attempts where test_id = $1', [id]);
  if (n.n > 0) throw new HttpError(409, 'has_attempts', 'Students have written this test. Unpublish it instead of deleting.');
  await pool.query('delete from tests where id = $1', [id]);
  return c.json({ ok: true });
});

teacherRoutes.get('/tests/:id/results', async (c) => {
  const id = uuid(c.req.param('id'), 'test id');
  await q('select finalize_expired_attempts()');
  const t = await q1(
    `select id, title, class_level, opens_at, closes_at, time_limit_min, status, now() as now, subject_id, assign_group,
            (select name from subjects where id = tests.subject_id) as subject
       from tests where id = $1`,
    [id],
  );
  if (!t) throw notFound('This test');
  const students = await q(
    `with ${ASSIGNED_CTE}, pool as (
       select student_id from assigned where test_id = $1
       union select student_id from attempts where test_id = $1)
     select u.id, u.display_name, u.class_level,
            la.id as attempt_id, la.attempt_no, la.started_at, la.submitted_at, la.score, la.max_score,
            la.correct_count, la.wrong_count, la.skipped_count, la.auto_submitted,
            exists (select 1 from retake_grants g where g.test_id = $1 and g.student_id = u.id and g.used_at is null) as retake_pending
       from pool p join users u on u.id = p.student_id
       left join lateral (select * from attempts a where a.test_id = $1 and a.student_id = u.id
                           order by attempt_no desc limit 1) la on true
      order by la.score desc nulls last, u.display_name`,
    [id],
  );
  const now: Date = t.now;
  const rows = students.map((s) => ({
    ...s,
    status: s.submitted_at ? 'submitted' : s.attempt_id ? 'writing' : t.closes_at && now >= t.closes_at ? 'missed' : 'not_started',
    pct: pct(s.score, s.max_score),
    time_taken_sec: s.submitted_at ? Math.round((s.submitted_at.getTime() - s.started_at.getTime()) / 1000) : null,
  }));
  const done = rows.filter((r) => r.status === 'submitted' && r.pct !== null);
  const pcts = done.map((r) => r.pct as number);

  const qs = await q(
    `select qq.id, tq.position, qq.text, qq.options, qq.correct_option from test_questions tq
       join questions qq on qq.id = tq.question_id where tq.test_id = $1 order by tq.position`,
    [id],
  );
  const counts = await q(
    `select an.question_id, an.chosen_option, count(*) as n
       from answers an join attempts a on a.id = an.attempt_id
      where a.test_id = $1 and a.submitted_at is not null and an.chosen_option is not null
      group by 1, 2`,
    [id],
  );
  const submittedAttempts = (await q1('select count(*) as n from attempts where test_id = $1 and submitted_at is not null', [id])).n;
  const questions = qs.map((qq) => {
    const optionCounts = [0, 1, 2, 3].map((o) => counts.find((k) => k.question_id === qq.id && k.chosen_option === o)?.n ?? 0);
    const answered = optionCounts.reduce((s, n) => s + n, 0);
    const wrong = optionCounts.map((n, o) => (o === qq.correct_option ? -1 : n));
    const topWrong = Math.max(...wrong);
    return {
      id: qq.id,
      n: qq.position,
      text: qq.text,
      options: qq.options,
      correct_option: qq.correct_option,
      option_counts: optionCounts,
      skipped: submittedAttempts - answered,
      correct_pct: submittedAttempts ? optionCounts[qq.correct_option] / submittedAttempts : null,
      most_picked_wrong: topWrong > 0 ? wrong.indexOf(topWrong) : null,
    };
  });
  return c.json({
    test: t,
    summary: {
      assigned: rows.length,
      submitted: done.length,
      writing: rows.filter((r) => r.status === 'writing').length,
      missed: rows.filter((r) => r.status === 'missed').length,
      average_pct: pcts.length ? pcts.reduce((s, x) => s + x, 0) / pcts.length : null,
      high_pct: pcts.length ? Math.max(...pcts) : null,
      low_pct: pcts.length ? Math.min(...pcts) : null,
    },
    students: rows,
    questions,
  });
});

teacherRoutes.post('/tests/:id/retake', async (c) => {
  const id = uuid(c.req.param('id'), 'test id');
  const studentId = uuid((await readBody(c)).student_id, 'student id');
  const pending = await q1('select id from retake_grants where test_id = $1 and student_id = $2 and used_at is null', [id, studentId]);
  if (!pending) await pool.query('insert into retake_grants (test_id, student_id) values ($1, $2)', [id, studentId]);
  return c.json({ ok: true });
});

teacherRoutes.get('/attempts/:id', async (c) => {
  return c.json(await resultPayload(uuid(c.req.param('id'), 'attempt id'), {}));
});

// ---------------------------------------------------------------- settings

teacherRoutes.get('/settings', async (c) => {
  const s = await q1(`select value #>> '{}' as name from app_settings where key = 'tuition_name'`);
  const sample = await q1(
    `select (select count(*) from users where is_sample) as users,
            (select count(*) from questions where is_sample) as questions,
            (select count(*) from tests where is_sample) as tests,
            (select count(*) from papers where is_sample) as papers`,
  );
  const ai = await q1(
    `select count(*) filter (where created_at > now() - interval '1 day') as calls_today,
            count(*) filter (where not ok and created_at > now() - interval '1 day') as failed_today
       from ai_usage`,
  );
  return c.json({ tuition_name: s?.name ?? 'Core Academy', me: c.get('user'), sample, ai });
});

teacherRoutes.patch('/settings', async (c) => {
  const b = await readBody(c);
  const name = str(b, 'tuition_name', { max: 60, optional: true });
  const displayName = str(b, 'display_name', { max: 60, optional: true });
  if (name) await pool.query(`update app_settings set value = to_jsonb($1::text) where key = 'tuition_name'`, [name]);
  if (displayName) await pool.query('update users set display_name = $2 where id = $1', [c.get('user').id, displayName]);
  return c.json({ ok: true });
});

teacherRoutes.post('/password', async (c) => {
  const b = await readBody(c);
  const me = await q1('select secret_hash, secret_salt from users where id = $1', [c.get('user').id]);
  if (!(await verifySecret(String(b.current ?? ''), me.secret_hash, me.secret_salt))) {
    throw new HttpError(400, 'wrong_password', 'Your current password is not right.');
  }
  const { hash, salt } = await hashSecret(checkPassword(b.next));
  await pool.query('update users set secret_hash = $2, secret_salt = $3 where id = $1', [c.get('user').id, hash, salt]);
  return c.json({ ok: true });
});

/** Removes everything the seed created. Real students, questions and tests are untouched. */
teacherRoutes.delete('/sample-data', async (c) => {
  const keys = await q<{ k: string }>(
    `select object_key as k from paper_pages pp join papers p on p.id = pp.paper_id where p.is_sample
     union all select image_key from questions where is_sample and image_key is not null`,
  );
  const counts = await tx(async (cx) => {
    const del = async (sql: string) => (await cx.query(sql)).rowCount ?? 0;
    // Real tests may use sample questions; detach those first so the questions can go.
    await cx.query(`delete from test_questions tq using questions qq where qq.id = tq.question_id and qq.is_sample
                     and not exists (select 1 from tests t where t.id = tq.test_id and t.is_sample)`);
    const tests = await del('delete from tests where is_sample');
    const questions = await del('delete from questions where is_sample');
    const papers = await del('delete from papers where is_sample');
    const users = await del(`delete from users where is_sample and role = 'student'`);
    const chapters = await del('delete from chapters where is_sample');
    const schools = await del('delete from schools where is_sample and not exists (select 1 from users u where u.school_id = schools.id)');
    return { tests, questions, papers, users, chapters, schools };
  });
  await deleteObjects(keys.map((r) => r.k)).catch(() => {});
  return c.json({ removed: counts });
});
