import { waitUntil } from '@neon/functions';
import { Hono } from 'hono';
import { tuitionOf, type AppEnv } from '../lib/auth.ts';
import { assignedCte, releaseFinishedTests, TEST_COUNTS } from '../lib/attempts.ts';
import { courseCards, ownCourse } from '../lib/courses.ts';
import { q, q1, tq, tq1, tx } from '../lib/db.ts';
import { bad, HttpError, notFound, str, uuid } from '../lib/http.ts';
import { afterTestChange } from '../lib/notify.ts';
import { deleteObjects } from '../lib/storage.ts';
import { createWithLogin, pinOf, planLogin } from '../lib/students.ts';
import { memberStudents } from '../lib/tuition.ts';
import { readBody } from './body.ts';

// A course is a list of people a tutor chooses, with papers, questions and tests of its own. Mounted with the
// teacher routes, behind requireUser('teacher'). Every tutor of the tuition sees every course of it.
//
// What makes a test a course's, and keeps it out of the groups, is course_id on the row (019_courses.sql); the
// group routes leave those rows out, and the tests, papers and questions routes take a course_id to make them.
export const courseRoutes = new Hono<AppEnv>();

/** A tuition can have this many courses: each one is a page the tutors scroll past. */
const MAX_COURSES = 100;

/** Courses the way Home shows them: each with its people count and the tests running or coming. */
courseRoutes.get('/courses', async (c) => {
  const T = tuitionOf(c).id;
  await q('select finalize_expired_attempts()');
  return c.json({ courses: await courseCards(T) });
});

courseRoutes.post('/courses', async (c) => {
  const T = tuitionOf(c).id;
  const name = str(await readBody(c), 'name', { max: 60 })!;
  const have = await tq1<{ n: number }>(T, 'select count(*) as n from courses where tuition_id = @T');
  if ((have?.n ?? 0) >= MAX_COURSES) throw new HttpError(409, 'too_many_courses', `A tuition can have up to ${MAX_COURSES} courses.`);
  try {
    const co = await tq1(
      T,
      `insert into courses (tuition_id, name, created_by) values (@T, $1, $2) returning id, name, created_at`,
      [name, c.get('user').id],
    );
    return c.json({ course: { ...co, people: 0, live: [], posted: [] } }, 201);
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'duplicate', `You already have a course called ${name}.`);
    throw e;
  }
});

/** One course's page: its people (with how they did in this course) and its tests (live, posted, finished, drafts). */
courseRoutes.get('/courses/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'course id');
  const course = await ownCourse(T, id);
  await q('select finalize_expired_attempts()');
  await releaseFinishedTests(T);
  const people = await tq(
    T,
    `select u.id, u.display_name, u.username, (m.status = 'active') as active, u.last_seen_at, cm.added_at,
            (select avg(a.score / nullif(a.max_score, 0)) from attempts a join tests t on t.id = a.test_id
              where a.student_id = u.id and t.course_id = $1 and a.submitted_at is not null) as avg_pct,
            (select count(*) from attempts a join tests t on t.id = a.test_id
              where a.student_id = u.id and t.course_id = $1 and a.submitted_at is not null) as tests_done
       from course_members cm join users u on u.id = cm.student_id
       join memberships m on m.tuition_id = @T and m.user_id = u.id and m.role = 'student' and m.status in ('active', 'off')
      where cm.course_id = $1
      order by (m.status = 'active') desc, u.display_name`,
    [id],
  );
  const tests = await tq(
    T,
    `with ${assignedCte('@T')}
     select t.id, t.title, t.status, t.opens_at, t.closes_at, t.results_released_at, t.time_limit_min, now() as now,
            (select count(*) from test_questions tq where tq.test_id = t.id) as question_count, ${TEST_COUNTS}
       from tests t
      where t.tuition_id = @T and t.course_id = $1
      order by coalesce(t.closes_at, t.opens_at, t.created_at) desc, t.title
      limit 100`,
    [id],
  );
  return c.json({ course: { id: course.id, name: course.name, people: people.filter((p) => p.active).length }, people, tests });
});

/**
 * Deletes a course with its tests, their results, and its papers and questions. The people stay: they keep their
 * logins and their places in any group, and are simply in no course. Results go only with ?with_results=1, like
 * deleting a test. The tests go first because a test holds on to its questions.
 */
courseRoutes.delete('/courses/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'course id');
  await ownCourse(T, id);
  const n = await q1<{ n: number }>(
    'select count(distinct a.student_id) as n from attempts a join tests t on t.id = a.test_id where t.course_id = $1',
    [id],
  );
  if (n && n.n > 0 && c.req.query('with_results') !== '1') {
    throw new HttpError(409, 'has_attempts', `${n.n} ${n.n === 1 ? 'person has' : 'people have'} written tests in this course. Deleting it deletes their results too.`);
  }
  const keys = await q<{ k: string }>(
    `select pp.object_key as k from paper_pages pp join papers p on p.id = pp.paper_id where p.course_id = $1
     union all select d.image_key from paper_drafts d join papers p on p.id = d.paper_id where p.course_id = $1 and d.image_key is not null
     union all select image_key from questions where course_id = $1 and image_key is not null`,
    [id],
  );
  const gone = await tx(async (cx) => {
    const people = await q1<{ n: number }>('select count(*) as n from course_members where course_id = $1', [id], cx);
    const tests = await cx.query('delete from tests where course_id = $1', [id]);
    const questions = await cx.query('delete from questions where course_id = $1', [id]);
    const papers = await cx.query('delete from papers where course_id = $1', [id]);
    await cx.query('delete from courses where id = $1', [id]);
    return { people_kept: Number(people?.n ?? 0), tests_deleted: tests.rowCount ?? 0, questions_deleted: questions.rowCount ?? 0, papers_deleted: papers.rowCount ?? 0 };
  });
  await deleteObjects([...new Set(keys.map((k) => k.k))]).catch(() => {});
  return c.json({ ok: true, results_deleted: n?.n ?? 0, ...gone });
});

// ---------------------------------------------------------------- people

/** Adds people the tuition already has, from any class. Someone already in the course is left as they are. */
courseRoutes.post('/courses/:id/people', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'course id');
  await ownCourse(T, id);
  const b = await readBody(c);
  const raw = b.student_ids;
  if (!Array.isArray(raw) || raw.some((x) => typeof x !== 'string')) throw bad('student_ids must be a list.');
  if (raw.length > 500) throw bad('Add up to 500 people at a time.');
  const ids = [...new Set(raw.map((x: string) => uuid(x, 'student id')))];
  await memberStudents(T, ids);
  const added = ids.length
    ? await q<{ student_id: string }>(
        `insert into course_members (course_id, student_id) select $1::uuid, unnest($2::uuid[]) on conflict do nothing returning student_id`,
        [id, ids],
      )
    : [];
  // They may have a test open already: they are told now, as a student added to a group is.
  if (added.length) waitUntil(afterTestChange());
  return c.json({ added: added.length });
});

/**
 * Makes a new person who is only in this course: a student with a login and no class and no group. The login
 * is suggested and made the way a group's student's is (see POST /students).
 */
courseRoutes.post('/courses/:id/people/new', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'course id');
  await ownCourse(T, id);
  const b = await readBody(c);
  const displayName = str(b, 'display_name', { max: 60 })!;
  const plan = await planLogin(b.username, displayName, c.get('user').id, T);
  const pin = pinOf(b);
  const { result: student, username } = await createWithLogin(plan, pin, async (cx, login) => {
    const row = await q1(
      `insert into users (role, username, display_name, secret_hash, secret_salt) values ('student', $1, $2, $3, $4)
       returning id, username, display_name`,
      [login.username, displayName, login.hash, login.salt],
      cx,
    );
    await cx.query(`insert into memberships (tuition_id, user_id, role, status) values ($1, $2, 'student', 'active')`, [T, row.id]);
    await cx.query('insert into course_members (course_id, student_id) values ($1, $2)', [id, row.id]);
    return { ...row, class_level: null };
  });
  waitUntil(afterTestChange());
  return c.json({ student, login: { username, pin } }, 201);
});

/** Takes a person out of the course. They stay a student with their login and groups, and what they wrote stays in the results. */
courseRoutes.delete('/courses/:id/people/:studentId', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'course id');
  const studentId = uuid(c.req.param('studentId'), 'student id');
  await ownCourse(T, id);
  const gone = await q1('delete from course_members where course_id = $1 and student_id = $2 returning student_id', [id, studentId]);
  if (!gone) throw notFound('This person');
  return c.json({ ok: true });
});
