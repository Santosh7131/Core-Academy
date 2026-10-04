import { Hono } from 'hono';
import { requireUser, type AppEnv } from '../lib/auth.ts';
import { ASSIGNED, resultPayload, saveAnswers, startOrResume, submitAttempt } from '../lib/attempts.ts';
import { q, q1 } from '../lib/db.ts';
import { uuid } from '../lib/http.ts';
import { readBody } from './body.ts';

export const studentRoutes = new Hono<AppEnv>();
studentRoutes.use('*', requireUser('student'));

type TestState = 'open' | 'in_progress' | 'upcoming' | 'done' | 'missed';

/** Every test given to this student, each with the state the home screen sorts by. */
studentRoutes.get('/home', async (c) => {
  const me = c.get('user');
  await q('select finalize_expired_attempts()');
  const rows = await q(
    `select t.id, t.title, t.class_level, t.time_limit_min, t.opens_at, t.closes_at, now() as now,
            (select count(*) from test_questions tq where tq.test_id = t.id) as question_count,
            (select coalesce(sum(qq.marks), 0) from test_questions tq join questions qq on qq.id = tq.question_id
              where tq.test_id = t.id) as max_marks,
            la.id as attempt_id, la.attempt_no, la.submitted_at, la.deadline_at, la.score, la.max_score,
            exists (select 1 from retake_grants g where g.test_id = t.id and g.student_id = $1 and g.used_at is null) as retake
       from tests t
       left join lateral (select * from attempts a where a.test_id = t.id and a.student_id = $1
                           order by a.attempt_no desc limit 1) la on true
      where t.status = 'published' and ${ASSIGNED}
      order by coalesce(t.closes_at, t.opens_at, t.created_at) desc`,
    [me.id, me.class_level],
  );
  const tests = rows.map((r) => {
    const now: Date = r.now;
    let state: TestState;
    if (r.attempt_id && !r.submitted_at) state = 'in_progress';
    else if (r.attempt_id && !r.retake) state = 'done';
    else if (r.opens_at && now < r.opens_at) state = 'upcoming';
    else if (r.closes_at && now >= r.closes_at) state = r.attempt_id ? 'done' : 'missed';
    else state = 'open';
    return {
      id: r.id,
      title: r.title,
      class_level: r.class_level,
      time_limit_min: r.time_limit_min,
      opens_at: r.opens_at,
      closes_at: r.closes_at,
      question_count: r.question_count,
      max_marks: r.max_marks,
      state,
      retake: r.retake,
      attempt: r.attempt_id
        ? { id: r.attempt_id, attempt_no: r.attempt_no, submitted_at: r.submitted_at, deadline_at: r.deadline_at, score: r.score, max_score: r.max_score }
        : null,
    };
  });
  const now = await q1('select now()');
  return c.json({ server_now: now.now, tests });
});

studentRoutes.post('/tests/:id/start', async (c) => {
  return c.json(await startOrResume(c.get('user'), uuid(c.req.param('id'), 'test id')));
});

studentRoutes.put('/attempts/:id/answers', async (c) => {
  const b = await readBody(c);
  return c.json(await saveAnswers(c.get('user').id, uuid(c.req.param('id'), 'attempt id'), b.answers));
});

studentRoutes.post('/attempts/:id/submit', async (c) => {
  const b = await readBody(c);
  return c.json(await submitAttempt(c.get('user').id, uuid(c.req.param('id'), 'attempt id'), b.answers, b.auto === true));
});

studentRoutes.get('/attempts/:id/result', async (c) => {
  return c.json(await resultPayload(uuid(c.req.param('id'), 'attempt id'), { studentId: c.get('user').id }));
});

studentRoutes.get('/results', async (c) => {
  const rows = await q(
    `select a.id, a.test_id, t.title, a.attempt_no, a.score, a.max_score, a.correct_count, a.wrong_count,
            a.skipped_count, a.started_at, a.submitted_at, a.auto_submitted
       from attempts a join tests t on t.id = a.test_id
      where a.student_id = $1 and a.submitted_at is not null
      order by a.submitted_at desc`,
    [c.get('user').id],
  );
  return c.json({ results: rows });
});
