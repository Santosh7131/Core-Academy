import { Hono } from 'hono';
import { requireUser, tuitionOf, type AppEnv } from '../lib/auth.ts';
import { ASSIGNED, releaseFinishedTests, resultsOpenFor, saveAnswers, startOrResume, studentResult, submitAttempt } from '../lib/attempts.ts';
import { holdsResults } from '../lib/client.ts';
import { pool, q, q1, tq } from '../lib/db.ts';
import { HttpError, uuid } from '../lib/http.ts';
import { readCode } from '../lib/tuition.ts';
import { readBody } from './body.ts';

// A student's tuitions, and asking to join one. These need no active tuition, so a student who is
// still waiting to be let in can open them. Mounted before studentRoutes, whose middleware refuses
// a student with no tuition.
export const studentOpenRoutes = new Hono<AppEnv>();

/** The tuitions the student is in or waiting to join. The app switches between them with the x-tuition header. */
studentOpenRoutes.get('/tuitions', requireUser('student', { tuition: 'none' }), async (c) => {
  const rows = await q(
    `select t.id, t.name, m.status, m.class_level, m.joined_at
       from memberships m join tuitions t on t.id = m.tuition_id
      where m.user_id = $1 and m.role = 'student' and m.status in ('active', 'pending')
      order by m.joined_at`,
    [c.get('user').id],
  );
  return c.json({ tuitions: rows });
});

const MAX_WRONG_CODES = 8;

/**
 * Asks to join a tuition with its code. The student waits (status pending) until a tutor lets them
 * in, so a code that gets passed around cannot put strangers into a tuition. Wrong codes are
 * counted, so a code cannot be guessed.
 */
studentOpenRoutes.post('/join', requireUser('student', { tuition: 'none' }), async (c) => {
  const me = c.get('user');
  const code = readCode((await readBody(c)).code);
  const wrong = await q1(`select count(*) as n from join_attempts where user_id = $1 and not ok and at > now() - interval '1 hour'`, [me.id]);
  if (wrong.n >= MAX_WRONG_CODES) throw new HttpError(429, 'too_many_tries', 'Too many wrong codes. Please try again in an hour.');
  const t = await q1<{ id: string; name: string; join_open: boolean }>('select id, name, join_open from tuitions where join_code = $1', [code]);
  if (!t) {
    await pool.query('insert into join_attempts (user_id, ok) values ($1, false)', [me.id]);
    throw new HttpError(404, 'unknown_code', 'No tuition has that code. Check it with your tutor.');
  }
  const have = await q1<{ status: string }>('select status from memberships where tuition_id = $1 and user_id = $2', [t.id, me.id]);
  if (have?.status === 'active') throw new HttpError(409, 'already_member', `You are already in ${t.name}.`);
  if (have?.status === 'off') throw new HttpError(403, 'turned_off', `${t.name} has turned off your place. Please ask your tutor.`);
  if (have?.status === 'pending') return c.json({ tuition: { id: t.id, name: t.name }, status: 'pending' });
  if (!t.join_open) throw new HttpError(403, 'not_joinable', `${t.name} is not taking new students right now.`);
  await pool.query(
    `insert into memberships (tuition_id, user_id, role, status, class_level) values ($1, $2, 'student', 'pending', $3)`,
    [t.id, me.id, me.class_level],
  );
  await pool.query('insert into join_attempts (user_id, ok) values ($1, true)', [me.id]);
  return c.json({ tuition: { id: t.id, name: t.name }, status: 'pending' }, 201);
});

export const studentRoutes = new Hono<AppEnv>();
studentRoutes.use('*', requireUser('student'));

type TestState = 'open' | 'in_progress' | 'upcoming' | 'done' | 'missed';

/** Every test given to this student in this tuition, each with the state the home screen sorts by. */
studentRoutes.get('/home', async (c) => {
  const me = c.get('user');
  const t = tuitionOf(c);
  await q('select finalize_expired_attempts()');
  await releaseFinishedTests(t.id);
  const open = resultsOpenFor(holdsResults(c));
  const rows = await tq(
    t.id,
    `select t.id, t.title, t.class_level, t.time_limit_min, t.opens_at, t.closes_at, now() as now,
            ${open} as results_open,
            (select count(*) from test_questions tq where tq.test_id = t.id) as question_count,
            (select coalesce(sum(qq.marks), 0) from test_questions tq join questions qq on qq.id = tq.question_id
              where tq.test_id = t.id) as max_marks,
            la.id as attempt_id, la.attempt_no, la.submitted_at, la.deadline_at, la.score, la.max_score,
            exists (select 1 from retake_grants g where g.test_id = t.id and g.student_id = $1 and g.used_at is null) as retake
       from tests t
       left join lateral (select * from attempts a where a.test_id = t.id and a.student_id = $1
                           order by a.attempt_no desc limit 1) la on true
      where t.tuition_id = @T and t.status = 'published' and ${ASSIGNED}
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
      // Marks stay hidden until the test closes, everyone has finished, or the tutor opens them.
      results_open: r.results_open,
      attempt: r.attempt_id
        ? {
            id: r.attempt_id, attempt_no: r.attempt_no, submitted_at: r.submitted_at, deadline_at: r.deadline_at,
            score: r.results_open ? r.score : null, max_score: r.results_open ? r.max_score : null,
          }
        : null,
    };
  });
  const now = await q1('select now()');
  return c.json({ server_now: now.now, tuition: { id: t.id, name: t.name }, tests });
});

studentRoutes.post('/tests/:id/start', async (c) => {
  return c.json(await startOrResume(c.get('user'), uuid(c.req.param('id'), 'test id'), tuitionOf(c).id));
});

studentRoutes.put('/attempts/:id/answers', async (c) => {
  const b = await readBody(c);
  return c.json(await saveAnswers(c.get('user').id, uuid(c.req.param('id'), 'attempt id'), b.answers));
});

studentRoutes.post('/attempts/:id/submit', async (c) => {
  const b = await readBody(c);
  return c.json(await submitAttempt(c.get('user').id, uuid(c.req.param('id'), 'attempt id'), b.answers, b.auto === true, holdsResults(c)));
});

studentRoutes.get('/attempts/:id/result', async (c) => {
  return c.json(await studentResult(uuid(c.req.param('id'), 'attempt id'), c.get('user').id, holdsResults(c)));
});

studentRoutes.get('/results', async (c) => {
  const T = tuitionOf(c).id;
  await releaseFinishedTests(T);
  const open = resultsOpenFor(holdsResults(c));
  const rows = await tq(
    T,
    `select a.id, a.test_id, t.title, t.closes_at, a.attempt_no, a.started_at, a.submitted_at, a.auto_submitted,
            ${open} as results_open,
            case when ${open} then a.score end as score, case when ${open} then a.max_score end as max_score,
            case when ${open} then a.correct_count end as correct_count,
            case when ${open} then a.wrong_count end as wrong_count,
            case when ${open} then a.skipped_count end as skipped_count
       from attempts a join tests t on t.id = a.test_id
      where a.student_id = $1 and t.tuition_id = @T and a.submitted_at is not null
      order by a.submitted_at desc`,
    [c.get('user').id],
  );
  return c.json({ results: rows });
});
