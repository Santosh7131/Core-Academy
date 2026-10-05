import { randomInt } from 'node:crypto';
import type pg from 'pg';
import { q, q1, tx, type Db } from './db.ts';
import { HttpError, notFound } from './http.ts';
import { maybeViewUrl } from './storage.ts';

export const GRACE_SECONDS = 30;

export function shuffle<T>(items: T[]): T[] {
  const a = [...items];
  for (let i = a.length - 1; i > 0; i--) {
    const j = randomInt(0, i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

// Students each published test is given to: the whole class, the class's group for the test's
// subject, or the chosen students.
// A test is for a group: the students of its class who take its subject. "Whole class" tests
// (assign_all, from before groups) also stay inside the subject, so a 10th Maths test never
// reaches a student who takes only Science.
export const ASSIGNED_CTE = `assigned as (
  select t.id as test_id, u.id as student_id
    from tests t join users u on u.role = 'student' and u.active and u.class_level = t.class_level
   where t.status = 'published'
     and (t.assign_all or t.assign_group)
     and exists (select 1 from student_subjects ss where ss.student_id = u.id and ss.subject_id = t.subject_id)
  union
  select t.id, ts.student_id
    from tests t join test_students ts on ts.test_id = t.id join users u on u.id = ts.student_id and u.active
   where t.status = 'published' and not t.assign_all and not t.assign_group
)`;

/** SQL condition: test t is given to student $1 in class $2. */
export const ASSIGNED = `((t.assign_all or t.assign_group) and t.class_level = $2
      and exists (select 1 from student_subjects ss where ss.student_id = $1 and ss.subject_id = t.subject_id)
   or exists (select 1 from test_students ts where ts.test_id = t.id and ts.student_id = $1))`;

type AttemptRow = {
  id: string; test_id: string; student_id: string; attempt_no: number;
  started_at: Date; deadline_at: Date | null; submitted_at: Date | null; auto_submitted: boolean;
  question_order: string[]; option_orders: Record<string, number[]>;
  score: number | null; max_score: number | null;
  correct_count: number | null; wrong_count: number | null; skipped_count: number | null;
};

type Student = { id: string; class_level: number | null };

async function finalize(attemptId: string, db: Db) {
  await db.query(
    `update attempts set submitted_at = deadline_at, auto_submitted = true
      where id = $1 and submitted_at is null and deadline_at is not null`,
    [attemptId],
  );
  await db.query('select grade_attempt($1)', [attemptId]);
}

const isExpired = (a: AttemptRow, now: Date) =>
  a.deadline_at !== null && now.getTime() > a.deadline_at.getTime() + GRACE_SECONDS * 1000;

/** What the test screen needs. Never includes the correct option. */
export async function attemptPayload(a: AttemptRow, db: Db) {
  const t = await q1(`select title, class_level, time_limit_min, closes_at from tests where id = $1`, [a.test_id], db);
  const qs = await q<{ id: string; text: string; options: string[]; image_key: string | null }>(
    `select id, text, options, image_key from questions where id = any($1::uuid[])`,
    [a.question_order],
    db,
  );
  const answers = await q<{ question_id: string; chosen_option: number | null; flagged: boolean }>(
    `select question_id, chosen_option, flagged from answers where attempt_id = $1`,
    [a.id],
    db,
  );
  const byId = new Map(qs.map((x) => [x.id, x]));
  const ans = new Map(answers.map((x) => [x.question_id, x]));
  const now = await q1<{ now: Date }>('select now()', [], db);
  const questions = await Promise.all(
    a.question_order.map(async (qid, i) => {
      const qq = byId.get(qid)!;
      const order = a.option_orders[qid];
      const saved = ans.get(qid);
      return {
        id: qid,
        n: i + 1,
        text: qq.text,
        image_url: await maybeViewUrl(qq.image_key),
        options: order.map((o) => qq.options[o]),
        chosen: saved?.chosen_option == null ? null : order.indexOf(saved.chosen_option),
        flagged: saved?.flagged ?? false,
      };
    }),
  );
  return {
    attempt: {
      id: a.id,
      test_id: a.test_id,
      title: t.title,
      class_level: t.class_level,
      time_limit_min: t.time_limit_min,
      started_at: a.started_at,
      deadline_at: a.deadline_at,
      server_now: now!.now,
    },
    questions,
  };
}

export async function startOrResume(student: Student, testId: string) {
  return tx(async (c) => {
    await c.query('select pg_advisory_xact_lock(hashtextextended($1, 0))', [`${student.id}:${testId}`]);
    const t = await q1(
      `select t.*, now() as now from tests t where t.id = $3 and t.status = 'published' and ${ASSIGNED}`,
      [student.id, student.class_level, testId],
      c,
    );
    if (!t) throw notFound('This test');
    const now: Date = t.now;

    const last = await q1<AttemptRow>(
      `select * from attempts where test_id = $1 and student_id = $2 order by attempt_no desc limit 1`,
      [testId, student.id],
      c,
    );
    if (last && !last.submitted_at) {
      if (!isExpired(last, now)) return attemptPayload(last, c);
      await finalize(last.id, c);
      last.submitted_at = last.deadline_at;
    }

    if (t.opens_at && now < t.opens_at) throw new HttpError(409, 'not_open_yet', 'This test has not opened yet.');
    if (t.closes_at && now >= t.closes_at) throw new HttpError(409, 'closed', 'This test has closed.');

    let attemptNo = 1;
    if (last) {
      const grant = await q1(
        `select id from retake_grants where test_id = $1 and student_id = $2 and used_at is null
          order by granted_at limit 1 for update`,
        [testId, student.id],
        c,
      );
      if (!grant) throw new HttpError(409, 'already_done', 'You have already written this test.');
      await c.query('update retake_grants set used_at = now() where id = $1', [grant.id]);
      attemptNo = last.attempt_no + 1;
    }

    const qs = await q<{ id: string; keep_option_order: boolean }>(
      `select q.id, q.keep_option_order from test_questions tq join questions q on q.id = tq.question_id
        where tq.test_id = $1 order by tq.position`,
      [testId],
      c,
    );
    if (!qs.length) throw new HttpError(409, 'empty_test', 'This test has no questions yet.');

    const ids = qs.map((x) => x.id);
    const order = t.shuffle ? shuffle(ids) : ids;
    const optionOrders: Record<string, number[]> = {};
    for (const x of qs) optionOrders[x.id] = t.shuffle && !x.keep_option_order ? shuffle([0, 1, 2, 3]) : [0, 1, 2, 3];

    let deadline: Date | null = t.time_limit_min ? new Date(now.getTime() + t.time_limit_min * 60_000) : null;
    if (t.closes_at) deadline = deadline && deadline < t.closes_at ? deadline : t.closes_at;

    const a = await q1<AttemptRow>(
      `insert into attempts (test_id, student_id, attempt_no, started_at, deadline_at, question_order, option_orders)
       values ($1, $2, $3, $4, $5, $6::uuid[], $7) returning *`,
      [testId, student.id, attemptNo, now, deadline, order, JSON.stringify(optionOrders)],
      c,
    );
    return attemptPayload(a!, c);
  });
}

export type AnswerInput = { question_id: string; choice: number | null; flagged?: boolean };

function parseAnswers(raw: unknown): AnswerInput[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw) || raw.length > 200) throw new HttpError(400, 'invalid', 'answers must be a list.');
  return raw.map((r: any) => {
    if (typeof r?.question_id !== 'string') throw new HttpError(400, 'invalid', 'Each answer needs a question_id.');
    const choice = r.choice === null || r.choice === undefined ? null : Number(r.choice);
    if (choice !== null && !(Number.isInteger(choice) && choice >= 0 && choice <= 3)) {
      throw new HttpError(400, 'invalid', 'choice must be 0–3 or null.');
    }
    return { question_id: r.question_id, choice, flagged: r.flagged === true };
  });
}

async function lockAttempt(c: pg.PoolClient, studentId: string, attemptId: string) {
  const a = await q1<AttemptRow & { now: Date }>(
    `select a.*, now() as now from attempts a where a.id = $1 and a.student_id = $2 for update`,
    [attemptId, studentId],
    c,
  );
  if (!a) throw notFound('This attempt');
  return a;
}

async function writeAnswers(c: pg.PoolClient, a: AttemptRow, answers: AnswerInput[]) {
  for (const x of answers) {
    const order = a.option_orders[x.question_id];
    if (!order) throw new HttpError(400, 'invalid', 'That question is not part of this test.');
    const original = x.choice === null ? null : order[x.choice];
    await c.query(
      `insert into answers (attempt_id, question_id, chosen_option, flagged, answered_at)
       values ($1, $2, $3, $4, now())
       on conflict (attempt_id, question_id)
       do update set chosen_option = excluded.chosen_option, flagged = excluded.flagged, answered_at = now()`,
      [a.id, x.question_id, original, x.flagged ?? false],
    );
  }
}

export async function saveAnswers(studentId: string, attemptId: string, raw: unknown) {
  const answers = parseAnswers(raw);
  // Finalizing must commit, so the time-up error is raised after the transaction.
  const out = await tx(async (c) => {
    const a = await lockAttempt(c, studentId, attemptId);
    if (a.submitted_at) return { status: 'submitted' as const };
    if (isExpired(a, a.now)) {
      await finalize(a.id, c);
      return { status: 'time_up' as const };
    }
    await writeAnswers(c, a, answers);
    return { status: 'ok' as const, saved: answers.length, server_now: a.now };
  });
  if (out.status === 'submitted') throw new HttpError(409, 'submitted', 'This test has already been submitted.');
  if (out.status === 'time_up') throw new HttpError(409, 'time_up', 'Time is up. Your saved answers were submitted.');
  return { saved: out.saved, server_now: out.server_now };
}

export async function submitAttempt(studentId: string, attemptId: string, raw: unknown, auto: boolean) {
  const answers = parseAnswers(raw);
  await tx(async (c) => {
    const a = await lockAttempt(c, studentId, attemptId);
    if (a.submitted_at) return; // already submitted: just return the result
    if (isExpired(a, a.now)) {
      await finalize(a.id, c);
      return;
    }
    await writeAnswers(c, a, answers);
    await c.query(
      `update attempts
          set submitted_at = case when deadline_at is not null and now() > deadline_at then deadline_at else now() end,
              auto_submitted = $2 or (deadline_at is not null and now() > deadline_at)
        where id = $1`,
      [a.id, auto],
    );
    await c.query('select grade_attempt($1)', [a.id]);
  });
  return resultPayload(attemptId, { studentId });
}

/** Marks plus the full review. Only for a submitted attempt: the owner, or the teacher. */
export async function resultPayload(attemptId: string, who: { studentId?: string }) {
  const a = await q1<AttemptRow & { title: string; class_level: number; display_name: string }>(
    `select a.*, t.title, t.class_level, u.display_name
       from attempts a join tests t on t.id = a.test_id join users u on u.id = a.student_id
      where a.id = $1 ${who.studentId ? 'and a.student_id = $2' : ''}`,
    who.studentId ? [attemptId, who.studentId] : [attemptId],
  );
  if (!a) throw notFound('This attempt');
  if (!a.submitted_at) throw new HttpError(409, 'not_submitted', 'This test has not been submitted yet.');

  const qs = await q<{ id: string; text: string; options: string[]; correct_option: number; solution: string | null; image_key: string | null; marks: number }>(
    `select id, text, options, correct_option, solution, image_key, marks from questions where id = any($1::uuid[])`,
    [a.question_order],
  );
  const answers = await q<{ question_id: string; chosen_option: number | null; flagged: boolean }>(
    `select question_id, chosen_option, flagged from answers where attempt_id = $1`,
    [a.id],
  );
  const byId = new Map(qs.map((x) => [x.id, x]));
  const ans = new Map(answers.map((x) => [x.question_id, x]));
  const review = await Promise.all(
    a.question_order.map(async (qid, i) => {
      const qq = byId.get(qid)!;
      const order = a.option_orders[qid];
      const chosen = ans.get(qid)?.chosen_option ?? null;
      return {
        id: qid,
        n: i + 1,
        text: qq.text,
        image_url: await maybeViewUrl(qq.image_key),
        options: order.map((o) => qq.options[o]),
        chosen: chosen === null ? null : order.indexOf(chosen),
        correct: order.indexOf(qq.correct_option),
        is_correct: chosen !== null && chosen === qq.correct_option,
        marks: qq.marks,
        solution: qq.solution,
      };
    }),
  );
  return {
    attempt: {
      id: a.id,
      test_id: a.test_id,
      title: a.title,
      class_level: a.class_level,
      student_name: a.display_name,
      attempt_no: a.attempt_no,
      score: a.score,
      max_score: a.max_score,
      correct: a.correct_count,
      wrong: a.wrong_count,
      skipped: a.skipped_count,
      started_at: a.started_at,
      submitted_at: a.submitted_at,
      time_taken_sec: Math.max(0, Math.round((new Date(a.submitted_at).getTime() - new Date(a.started_at).getTime()) / 1000)),
      auto_submitted: a.auto_submitted,
    },
    review,
  };
}
