import { waitUntil } from '@neon/functions';
import { Hono } from 'hono';
import {
  checkPassword, checkPin, checkUsername, hashSecret, killSessions, newPin, tuitionOf, verifySecret, type AppEnv,
} from '../lib/auth.ts';
import { assignedCte, releaseFinishedTests, resultPayload } from '../lib/attempts.ts';
import { pool, q, q1, tq, tq1, tx } from '../lib/db.ts';
import { bad, bool, date, HttpError, int, notFound, str, uuid, uuidOpt } from '../lib/http.ts';
import { assertLevel, CLASS_MIN, CUSTOM_MAX, levelIn, levelLabel, levelParam } from '../lib/levels.ts';
import { afterTestChange } from '../lib/notify.ts';
import { pushConfigured, pushToUsers } from '../lib/push.ts';
import { mustKeepOrder } from '../lib/questions.ts';
import { deleteObjects, maybeViewUrl, uploadUrl } from '../lib/storage.ts';
import { MATHS, studentSubjects, subjectIds } from '../lib/subjects.ts';
import {
  defaultSubject, elsewhere, ensureGroup, FIRST_TUITION, memberStudents, newImageKey, ownImageKey, ownQuestions, refreshLogin, taughtSubject,
  taughtSubjectIds,
} from '../lib/tuition.ts';
import { freeUsername, latinName, usernameBase } from '../lib/usernames.ts';
import { readBody } from './body.ts';

// Mounted behind requireUser('teacher') in index.ts, which also gives every request its tuition:
// everything below reads and writes that tuition's data only.
export const teacherRoutes = new Hono<AppEnv>();

const pct = (score: number | null, max: number | null) => (score == null || !max ? null : score / max);

/**
 * Every test closes: students see their marks after that, so a test posted without a closing time
 * (by an older app, or by someone who skipped it) closes at the next 9:00 pm India time that is at
 * least three hours away.
 */
export function defaultClosing(now = new Date()): Date {
  const ist = 5.5 * 3_600_000;
  const local = new Date(now.getTime() + ist); // shifted, so the UTC getters read India time
  let t = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate(), 21) - ist;
  if (t - now.getTime() < 3 * 3_600_000) t += 86_400_000;
  return new Date(t);
}

// ---------------------------------------------------------------- dashboard

teacherRoutes.get('/dashboard', async (c) => {
  const T = tuitionOf(c).id;
  await q('select finalize_expired_attempts()');
  const b = await q1(
    `select now() as now,
            (date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata') as d0`,
  );
  const stats = await tq1(
    T,
    `with ${assignedCte('@T')}
     select
       (select count(*) from attempts x join tests t on t.id = x.test_id where t.tuition_id = @T and x.submitted_at >= $1::timestamptz) as submitted_today,
       (select count(*) from assigned a join tests t on t.id = a.test_id
         where (t.opens_at is not null or t.closes_at is not null)
           and coalesce(t.opens_at, '-infinity') < $1::timestamptz + interval '1 day'
           and coalesce(t.closes_at, 'infinity') > $1::timestamptz) as due_today,
       (select count(*) from attempts x join tests t on t.id = x.test_id
         where t.tuition_id = @T and x.submitted_at is null and (x.deadline_at is null or x.deadline_at > now())) as writing_now,
       (select count(*) from assigned a join tests t on t.id = a.test_id
         where t.closes_at between now() - interval '7 days' and now()
           and not exists (select 1 from attempts x where x.test_id = a.test_id and x.student_id = a.student_id)) as missed_week`,
    [b.d0],
  );
  const live = await tq(
    T,
    `with ${assignedCte('@T')}
     select t.id, t.title, t.class_level, t.opens_at, t.closes_at, (select name from subjects where id = t.subject_id) as subject,
            (select count(*) from assigned a where a.test_id = t.id) as assigned,
            (select count(distinct x.student_id) from attempts x where x.test_id = t.id and x.submitted_at is not null) as submitted,
            (select count(*) from attempts x where x.test_id = t.id and x.submitted_at is null) as writing
       from tests t
      where t.tuition_id = @T and t.status = 'published'
        and (t.opens_at is null or t.opens_at <= now())
        and (t.closes_at is null or t.closes_at > now()
             or exists (select 1 from attempts x where x.test_id = t.id and x.submitted_at is null))
      order by t.closes_at nulls last, coalesce(t.opens_at, t.created_at) desc
      limit 20`,
  );
  const attention = await tq(
    T,
    `with ${assignedCte('@T')},
     missed as (
       select a.student_id, count(*) as missed from assigned a join tests t on t.id = a.test_id
        where t.closes_at between now() - interval '7 days' and now()
          and not exists (select 1 from attempts x where x.test_id = a.test_id and x.student_id = a.student_id)
        group by 1),
     recent as (
       select student_id, avg(score / nullif(max_score, 0)) as avg_pct, count(*) as n
         from (select a.student_id, a.score, a.max_score,
                      row_number() over (partition by a.student_id order by a.submitted_at desc) as rn
                 from attempts a join tests t on t.id = a.test_id
                where t.tuition_id = @T and a.submitted_at is not null) z
        where rn <= 3 group by 1)
     select u.id, u.display_name, m.class_level, coalesce(ms.missed, 0) as missed, r.avg_pct, coalesce(r.n, 0) as recent_count
       from memberships m join users u on u.id = m.user_id
       left join missed ms on ms.student_id = u.id left join recent r on r.student_id = u.id
      where m.tuition_id = @T and m.role = 'student' and m.status = 'active' and u.active
        and (coalesce(ms.missed, 0) >= 2 or (r.n >= 2 and r.avg_pct < 0.4))
      order by coalesce(ms.missed, 0) desc, r.avg_pct asc nulls last
      limit 10`,
  );
  const activity = await tq(
    T,
    `select * from (
       select a.id as attempt_id, 'submitted' as kind, a.submitted_at as at, u.id as student_id, u.display_name,
              t.title, a.score, a.max_score
         from attempts a join users u on u.id = a.student_id join tests t on t.id = a.test_id
        where t.tuition_id = @T and a.submitted_at is not null
       union all
       select a.id, 'started', a.started_at, u.id, u.display_name, t.title, null, null
         from attempts a join users u on u.id = a.student_id join tests t on t.id = a.test_id
        where t.tuition_id = @T and a.submitted_at is null
     ) e order by at desc limit 12`,
  );
  return c.json({ server_now: b.now, stats, live, attention, activity });
});

// ---------------------------------------------------------------- students

/** A student's results in this tuition only: another tutor's tests are theirs to see. */
const OWN_RESULTS = `from attempts a join tests t on t.id = a.test_id where a.student_id = u.id and t.tuition_id = @T and a.submitted_at is not null`;

teacherRoutes.get('/students', async (c) => {
  const T = tuitionOf(c).id;
  const cls = c.req.query('class');
  const subject = c.req.query('subject');
  const rows = await tq(
    T,
    `select u.id, u.display_name, u.username, m.class_level, (m.status = 'active') as active, u.last_seen_at,
            (select avg(a.score / nullif(a.max_score, 0)) ${OWN_RESULTS}) as avg_pct,
            (select count(*) ${OWN_RESULTS}) as tests_done,
            ${studentSubjects('@T')}
       from memberships m join users u on u.id = m.user_id
      where m.tuition_id = @T and m.role = 'student' and m.status in ('active', 'off')
        and ($1::smallint is null or m.class_level = $1)
        and ($2::uuid is null or exists (select 1 from student_subjects ss where ss.tuition_id = @T and ss.student_id = u.id and ss.subject_id = $2))
      order by (m.status = 'active') desc, m.class_level, u.display_name`,
    [cls ? Number(cls) : null, subject ? uuid(subject, 'subject') : null],
  );
  return c.json({ students: rows });
});

/** Sets the subjects a student studies in this tuition, and makes sure each has its group. */
async function setStudentSubjects(cx: any, tuition: string, studentId: string, ids: string[]) {
  await cx.query('delete from student_subjects where tuition_id = $1 and student_id = $2', [tuition, studentId]);
  if (ids.length) {
    await cx.query(
      'insert into student_subjects (tuition_id, student_id, subject_id) select $1::uuid, $2::uuid, unnest($3::uuid[])',
      [tuition, studentId, ids],
    );
  }
  const m = await q1<{ class_level: number }>(
    'select class_level from memberships where tuition_id = $1 and user_id = $2',
    [tuition, studentId],
    cx,
  );
  if (m) for (const id of ids) await ensureGroup(tuition, m.class_level, id, cx);
}

/** The login to suggest for a student of this name, free right now: two called Harini Venkatesh get harini.v and harini.v.2. */
teacherRoutes.get('/username-suggestion', async (c) => {
  const name = await latinName((c.req.query('name') ?? '').slice(0, 60), c.get('user').id);
  return c.json({ username: await freeUsername(name) });
});

teacherRoutes.post('/students', async (c) => {
  const T = tuitionOf(c).id;
  const b = await readBody(c);
  const displayName = str(b, 'display_name', { max: 60 })!;
  const classLevel = (await levelIn(b, 'class_level', T))!;
  const requested = checkUsername(b.username);
  // The username the app suggests from the name ("harini.v", or "harini.v.2"), when it is taken, becomes the
  // next free one, so nobody has to think of a login for a second student with the same name. Any other
  // username that is taken is refused, so the tutor can pick another.
  // A name typed in Tamil or Hindi is spelled out in English letters first, as the suggestion was.
  const latin = await latinName(displayName, c.get('user').id);
  const base = usernameBase(latin);
  const suggested = requested.startsWith(base) && /^(\.\d+)?$/.test(requested.slice(base.length));
  let username = requested;
  if (suggested && (await q1('select 1 as x from users where username = $1', [requested]))) username = await freeUsername(latin);
  // The app before subjects sends none: its students study maths (or the tuition's first subject).
  const subjects = 'subject_ids' in b ? subjectIds(b.subject_ids) : [await defaultSubject(T)];
  await taughtSubjectIds(T, subjects);
  const pin = b.pin === undefined || b.pin === null || b.pin === '' ? newPin() : checkPin(b.pin);
  const { hash, salt } = await hashSecret(pin);
  for (let attempt = 0; ; attempt++) {
    try {
      const u = await tx(async (cx) => {
        const row = await q1(
          `insert into users (role, username, display_name, class_level, secret_hash, secret_salt)
           values ('student', $1, $2, $3, $4, $5) returning id, username, display_name, class_level`,
          [username, displayName, classLevel, hash, salt],
          cx,
        );
        await cx.query(
          `insert into memberships (tuition_id, user_id, role, status, class_level) values ($1, $2, 'student', 'active', $3)`,
          [T, row.id, classLevel],
        );
        await setStudentSubjects(cx, T, row.id, subjects);
        return row;
      });
      waitUntil(afterTestChange());
      return c.json({ student: u, login: { username, pin } }, 201);
    } catch (e: any) {
      if (e.code === '23505') {
        // Someone took it between the check and the insert: try the next free one.
        if (suggested && attempt < 3) {
          username = await freeUsername(latin, pool, [username]);
          continue;
        }
        throw new HttpError(409, 'username_taken', `The username ${username} is already taken.`);
      }
      if (e.code === '23503') throw bad('One of those subjects no longer exists.');
      throw e;
    }
  }
});

teacherRoutes.get('/students/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'student id');
  await q('select finalize_expired_attempts()');
  const s = await tq1(
    T,
    `select u.id, u.display_name, u.username, m.class_level, (m.status = 'active') as active, u.last_seen_at, m.joined_at as created_at,
            ${studentSubjects('@T')}
       from memberships m join users u on u.id = m.user_id
      where m.tuition_id = @T and m.user_id = $1 and m.role = 'student' and m.status in ('active', 'off')`,
    [id],
  );
  if (!s) throw notFound('This student');
  const attempts = await tq(
    T,
    `select a.id, a.test_id, t.title, a.attempt_no, a.score, a.max_score, a.correct_count, a.wrong_count, a.skipped_count,
            a.started_at, a.submitted_at, a.auto_submitted
       from attempts a join tests t on t.id = a.test_id where a.student_id = $1 and t.tuition_id = @T order by a.started_at desc`,
    [id],
  );
  const chapters = await tq(
    T,
    `select coalesce(ch.name, 'No chapter') as chapter, count(*) as total,
            count(*) filter (where an.chosen_option = qq.correct_option) as correct
       from attempts a join tests t on t.id = a.test_id and t.tuition_id = @T
       cross join lateral unnest(a.question_order) as qo(qid)
       join questions qq on qq.id = qo.qid
       left join answers an on an.attempt_id = a.id and an.question_id = qq.id
       left join chapters ch on ch.id = qq.chapter_id
      where a.student_id = $1 and a.submitted_at is not null
      group by 1 order by 1`,
    [id],
  );
  const missed = await tq(
    T,
    `with ${assignedCte('@T')}
     select t.id, t.title, t.closes_at from assigned a join tests t on t.id = a.test_id
      where a.student_id = $1 and t.closes_at < now()
        and not exists (select 1 from attempts x where x.test_id = t.id and x.student_id = $1)
      order by t.closes_at desc`,
    [id],
  );
  return c.json({ student: s, attempts, chapters, missed });
});

teacherRoutes.patch('/students/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'student id');
  const b = await readBody(c);
  const name = str(b, 'display_name', { max: 60, optional: true }) ?? null;
  const cls = (await levelIn(b, 'class_level', T, { optional: true })) ?? null;
  const subjects = 'subject_ids' in b ? subjectIds(b.subject_ids) : null;
  if (subjects) await taughtSubjectIds(T, subjects);
  const u = await tx(async (cx) => {
    const cur = await tq1<{ display_name: string; class_level: number }>(
      T,
      `select u.display_name, m.class_level from memberships m join users u on u.id = m.user_id
        where m.tuition_id = @T and m.user_id = $1 and m.role = 'student' and m.status in ('active', 'off') for update of m`,
      [id],
      cx,
    );
    if (!cur) return null;
    // A name belongs to the person, not to one tuition: another tutor's student keeps the name they were given.
    if (name && name !== cur.display_name) {
      if (await elsewhere(T, id, cx)) {
        throw new HttpError(409, 'shared_student', 'This student also learns with another tutor, so the name stays as it is.');
      }
      await cx.query('update users set display_name = $2 where id = $1', [id, name]);
    }
    if (cls) await tq(T, 'update memberships set class_level = $2 where tuition_id = @T and user_id = $1', [id, cls], cx);
    if (subjects) await setStudentSubjects(cx, T, id, subjects);
    else if (cls) {
      const have = await tq<{ subject_id: string }>(T, 'select subject_id from student_subjects where tuition_id = @T and student_id = $1', [id], cx);
      for (const s of have) await ensureGroup(T, cls, s.subject_id, cx);
    }
    return q1('select u.id, u.display_name, m.class_level from users u join memberships m on m.user_id = u.id and m.tuition_id = $2 where u.id = $1', [id, T], cx);
  });
  // New subjects can put the student in groups with open tests.
  if (u && (subjects || cls)) waitUntil(afterTestChange());
  if (!u) throw notFound('This student');
  return c.json({ student: u });
});

teacherRoutes.post('/students/:id/reset-pin', async (c) => {
  const t = tuitionOf(c);
  const id = uuid(c.req.param('id'), 'student id');
  const b = await readBody(c);
  const pin = b.pin ? checkPin(b.pin) : newPin();
  const { hash, salt } = await hashSecret(pin);
  const own = await tq1(
    t.id,
    `select 1 as x from memberships where tuition_id = @T and user_id = $1 and role = 'student' and status in ('active', 'off')`,
    [id],
  );
  if (!own) throw notFound('This student');
  const u = await q1(
    `update users set secret_hash = $2, secret_salt = $3, failed_count = 0, locked_until = null
      where id = $1 and role = 'student' returning username`,
    [id, hash, salt],
  );
  // A student who learns with other tutors too is told who changed the PIN, before every phone is signed out.
  if (pushConfigured() && (await elsewhere(t.id, id))) {
    await pushToUsers([id], { title: 'Your PIN was changed', body: `${t.name} set a new PIN for your login.` }).catch(() => 0);
  }
  await killSessions(id);
  return c.json({ login: { username: u.username, pin } });
});

/**
 * Takes a student out of this tuition, with their results in it. A student who is nowhere else is
 * deleted with their login; one who learns with another tutor too keeps their login and the rest.
 * Turning the student off instead keeps the results.
 */
teacherRoutes.delete('/students/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'student id');
  const found = await tx(async (cx) => {
    const own = await tq1(
      T,
      `select 1 as x from memberships where tuition_id = @T and user_id = $1 and role = 'student'`,
      [id],
      cx,
    );
    if (!own) return false;
    const other = await tq1(T, 'select 1 as x from memberships where user_id = $1 and tuition_id <> @T', [id], cx);
    if (!other) {
      await cx.query(`delete from users where id = $1 and role = 'student'`, [id]);
      return true;
    }
    await tq(T, 'delete from attempts a using tests t where t.id = a.test_id and t.tuition_id = @T and a.student_id = $1', [id], cx);
    await tq(T, 'delete from test_students ts using tests t where t.id = ts.test_id and t.tuition_id = @T and ts.student_id = $1', [id], cx);
    await tq(T, 'delete from retake_grants g using tests t where t.id = g.test_id and t.tuition_id = @T and g.student_id = $1', [id], cx);
    await tq(T, 'delete from test_notices n using tests t where t.id = n.test_id and t.tuition_id = @T and n.student_id = $1', [id], cx);
    await tq(T, 'delete from student_subjects where tuition_id = @T and student_id = $1', [id], cx);
    await tq(T, 'delete from memberships where tuition_id = @T and user_id = $1', [id], cx);
    return true;
  });
  if (!found) throw notFound('This student');
  return c.json({ ok: true });
});

teacherRoutes.post('/students/:id/active', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'student id');
  const active = bool(await readBody(c), 'active');
  const m = await tq1(
    T,
    `update memberships set status = $2 where tuition_id = @T and user_id = $1 and role = 'student' and status in ('active', 'off') returning user_id`,
    [id, active ? 'active' : 'off'],
  );
  if (!m) throw notFound('This student');
  // The login itself goes off only when this was the student's last place.
  const loginOn = await refreshLogin(id);
  if (!active && !loginOn) await killSessions(id);
  else if (active) waitUntil(afterTestChange());
  return c.json({ student: { id, active } });
});

// ---------------------------------------------------------------- schools (gone)

// The app before 1.3 still asks for its school list; it gets an empty one until it updates.
teacherRoutes.get('/schools', (c) => c.json({ schools: [] }));
teacherRoutes.post('/schools', () => {
  throw new HttpError(410, 'gone', 'Schools are no longer used. Update the app to the newest version.');
});

// ---------------------------------------------------------------- subjects and groups

teacherRoutes.get('/subjects', async (c) => {
  const T = tuitionOf(c).id;
  const rows = await tq(
    T,
    `select sj.id, sj.name, sj.sort_order, sj.id = $1 as is_default, (sj.tuition_id is null) as standard,
            (select count(*) from student_subjects ss join memberships m on m.tuition_id = ss.tuition_id and m.user_id = ss.student_id and m.status = 'active'
              where ss.tuition_id = @T and ss.subject_id = sj.id) as students,
            (select count(*) from chapters ch where ch.tuition_id = @T and ch.subject_id = sj.id) as chapters,
            (select count(*) from questions qq where qq.tuition_id = @T and qq.subject_id = sj.id) as questions,
            (select count(*) from tests t where t.tuition_id = @T and t.subject_id = sj.id) as tests
       from subjects sj join tuition_subjects ts on ts.subject_id = sj.id and ts.tuition_id = @T
      order by sj.sort_order, sj.name`,
    [MATHS],
  );
  return c.json({ subjects: rows });
});

/** The standard subjects this tuition could add. */
teacherRoutes.get('/subject-catalogue', async (c) => {
  const rows = await tq(
    tuitionOf(c).id,
    `select sj.id, sj.name from subjects sj
      where sj.tuition_id is null and not exists (select 1 from tuition_subjects ts where ts.tuition_id = @T and ts.subject_id = sj.id)
      order by sj.sort_order, sj.name`,
  );
  return c.json({ subjects: rows });
});

/** Adds a subject to the tuition: a standard one of that name, else a new subject of its own. */
teacherRoutes.post('/subjects', async (c) => {
  const T = tuitionOf(c).id;
  const name = str(await readBody(c), 'name', { max: 40 })!;
  const duplicate = new HttpError(409, 'duplicate', `${name} is already a subject.`);
  const standard = await q1<{ id: string; name: string; sort_order: number }>(
    'select id, name, sort_order from subjects where tuition_id is null and lower(name) = lower($1)',
    [name],
  );
  try {
    const sj = await tx(async (cx) => {
      const row =
        standard ??
        (await tq1(
          T,
          `insert into subjects (name, sort_order, tuition_id)
           values ($1, coalesce((select max(sort_order) + 1 from subjects where tuition_id = @T), 100), @T)
           returning id, name, sort_order`,
          [name],
          cx,
        ))!;
      const linked = await tq1(T, 'insert into tuition_subjects (tuition_id, subject_id) values (@T, $1) on conflict do nothing returning subject_id', [row.id], cx);
      if (!linked) throw duplicate;
      return row;
    });
    return c.json({ subject: sj }, 201);
  } catch (e: any) {
    if (e.code === '23505') throw duplicate;
    throw e;
  }
});

teacherRoutes.patch('/subjects/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'));
  const name = str(await readBody(c), 'name', { max: 40 })!;
  try {
    const sj = await tq1(T, 'update subjects set name = $2 where id = $1 and tuition_id = @T returning id, name, sort_order', [id, name]);
    if (sj) return c.json({ subject: sj });
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'duplicate', `${name} is already a subject.`);
    throw e;
  }
  const std = await q1('select 1 as x from subjects where id = $1 and tuition_id is null', [id]);
  if (std) throw new HttpError(409, 'standard_subject', 'This is a standard subject, so its name stays as it is.');
  throw notFound('This subject');
});

teacherRoutes.delete('/subjects/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'));
  const link = await tq1<{ tuition_id: string | null }>(
    T,
    `select sj.tuition_id from tuition_subjects ts join subjects sj on sj.id = ts.subject_id where ts.tuition_id = @T and ts.subject_id = $1`,
    [id],
  );
  if (!link) throw notFound('This subject');
  // The apps from before subjects send none and mean Maths, so the first tuition keeps it.
  if (id === MATHS && T === FIRST_TUITION) throw new HttpError(409, 'default_subject', 'Maths is the main subject, so it stays.');
  const used = await tq1(
    T,
    `select (select count(*) from chapters where tuition_id = @T and subject_id = $1) + (select count(*) from questions where tuition_id = @T and subject_id = $1)
          + (select count(*) from tests where tuition_id = @T and subject_id = $1) + (select count(*) from papers where tuition_id = @T and subject_id = $1) as n`,
    [id],
  );
  if (used.n > 0) throw new HttpError(409, 'in_use', 'This subject has chapters, questions, papers or tests. Delete those first.');
  await tx(async (cx) => {
    await tq(T, 'delete from groups where tuition_id = @T and subject_id = $1', [id], cx);
    await tq(T, 'delete from student_subjects where tuition_id = @T and subject_id = $1', [id], cx);
    await tq(T, 'delete from tuition_subjects where tuition_id = @T and subject_id = $1', [id], cx);
    if (link.tuition_id) await cx.query('delete from subjects where id = $1 and tuition_id = $2', [id, T]);
  });
  return c.json({ ok: true });
});

/** Every group of the tuition, with its active students: a class and a subject, e.g. "10th Science". */
const GROUPS = `select g.class_level, sj.id as subject_id, sj.name as subject,
       (select count(*) from memberships m join users u on u.id = m.user_id and u.active
          join student_subjects ss on ss.tuition_id = m.tuition_id and ss.student_id = m.user_id and ss.subject_id = g.subject_id
         where m.tuition_id = g.tuition_id and m.role = 'student' and m.status = 'active' and m.class_level = g.class_level) as students
  from groups g join subjects sj on sj.id = g.subject_id
 where g.tuition_id = @T
 order by g.class_level, sj.sort_order, sj.name`;

teacherRoutes.get('/groups', async (c) => c.json({ groups: await tq(tuitionOf(c).id, GROUPS) }));

/** Starts a group, so it is there before its first student: a class and a subject the tuition teaches. */
teacherRoutes.post('/groups', async (c) => {
  const T = tuitionOf(c).id;
  const b = await readBody(c);
  const cls = (await levelIn(b, 'class_level', T))!;
  const subject = await taughtSubject(T, uuid(b.subject_id, 'subject'));
  await ensureGroup(T, cls, subject.id);
  return c.json({ group: { class_level: cls, subject_id: subject.id, subject: subject.name } }, 201);
});

/** Removes an empty group: one with no students and no tests. */
teacherRoutes.delete('/groups/:cls/:subject', async (c) => {
  const T = tuitionOf(c).id;
  const cls = await levelParam(c.req.param('cls'), T);
  const subjectId = uuid(c.req.param('subject'), 'subject');
  const used = await tq1(
    T,
    `select (select count(*) from memberships m join student_subjects ss on ss.tuition_id = m.tuition_id and ss.student_id = m.user_id and ss.subject_id = $2
              where m.tuition_id = @T and m.role = 'student' and m.status in ('active', 'off') and m.class_level = $1)
          + (select count(*) from tests where tuition_id = @T and class_level = $1 and subject_id = $2) as n`,
    [cls, subjectId],
  );
  if (used.n > 0) throw new HttpError(409, 'in_use', 'This group has students or tests. Move or delete those first.');
  const gone = await tq1(T, 'delete from groups where tuition_id = @T and class_level = $1 and subject_id = $2 returning id', [cls, subjectId]);
  if (!gone) throw notFound('This group');
  return c.json({ ok: true });
});

/**
 * SQL condition: the test was given to someone and every student it was given to has handed it in.
 * Such a test is finished, whatever its closing time says (releaseFinishedTests opens its marks on the
 * same condition). Needs the `assigned` CTE.
 */
const EVERYONE_DONE = `(exists (select 1 from assigned a where a.test_id = t.id)
   and not exists (select 1 from assigned a where a.test_id = t.id
                    and not exists (select 1 from attempts x where x.test_id = t.id and x.student_id = a.student_id and x.submitted_at is not null)))`;

/** The counts a test row shows: students given it, submitted, and writing right now. */
const TEST_COUNTS = `${EVERYONE_DONE} as everyone_done,
            (select count(*) from assigned a where a.test_id = t.id) as assigned,
            (select count(distinct x.student_id) from attempts x where x.test_id = t.id and x.submitted_at is not null) as submitted,
            (select count(*) from attempts x where x.test_id = t.id and x.submitted_at is null
                and (x.deadline_at is null or x.deadline_at > now())) as writing`;

/**
 * The home screen: every group, each with the tests its students can write now (live) and the
 * ones posted to open later, with how many students have submitted and how many are writing.
 */
teacherRoutes.get('/home', async (c) => {
  const t = tuitionOf(c);
  const T = t.id;
  await q('select finalize_expired_attempts()');
  await releaseFinishedTests(T);
  const groups = await tq<any>(T, GROUPS);
  const tests = await tq<any>(
    T,
    `with ${assignedCte('@T')}
     select t.id, t.title, t.class_level, t.subject_id, (select name from subjects where id = t.subject_id) as subject,
            t.opens_at, t.closes_at, t.time_limit_min, now() as now, ${TEST_COUNTS}
       from tests t
      where t.tuition_id = @T and t.status = 'published'
        and (exists (select 1 from attempts x where x.test_id = t.id and x.submitted_at is null
                      and (x.deadline_at is null or x.deadline_at > now()))
             or ((t.closes_at is null or t.closes_at > now()) and not ${EVERYONE_DONE}))
      order by t.closes_at nulls last, coalesce(t.opens_at, t.created_at) desc`,
  );
  const out: { class_level: number; subject_id: string; subject: string; students: number; live: any[]; posted: any[] }[] = groups.map((g) => ({
    class_level: g.class_level, subject_id: g.subject_id, subject: g.subject, students: Number(g.students), live: [], posted: [],
  }));
  for (const x of tests) {
    let g = out.find((y) => y.class_level === x.class_level && y.subject_id === x.subject_id);
    if (!g) {
      // A test for a group nobody has started yet still shows.
      g = { class_level: x.class_level, subject_id: x.subject_id, subject: x.subject, students: 0, live: [], posted: [] };
      out.push(g);
    }
    const { now, ...row } = x;
    (x.opens_at && x.opens_at > now ? g.posted : g.live).push(row);
  }
  out.sort((a, b) => a.class_level - b.class_level || a.subject.localeCompare(b.subject));
  const meta = await tq1(
    T,
    `select now() as now, (select join_code from tuitions where id = @T) as join_code,
            (select count(*) from memberships where tuition_id = @T and role = 'student' and status = 'pending') as pending`,
  );
  return c.json({
    server_now: meta.now,
    tuition: { id: T, name: t.name, join_code: meta.join_code },
    pending_requests: Number(meta.pending),
    groups: out,
    totals: {
      live: out.reduce((s, g) => s + g.live.length, 0),
      writing: out.reduce((s, g) => s + g.live.reduce((n, x) => n + Number(x.writing), 0), 0),
    },
  });
});

/**
 * One group's page: its students and its tests (live, posted, finished, drafts). The ready-made
 * chapter tests of the library are left out: the app does not offer them.
 */
teacherRoutes.get('/groups/:cls/:subject', async (c) => {
  const T = tuitionOf(c).id;
  const cls = await levelParam(c.req.param('cls'), T);
  const subjectId = uuid(c.req.param('subject'), 'subject');
  const subject = await tq1(
    T,
    `select sj.id, sj.name from subjects sj join tuition_subjects ts on ts.subject_id = sj.id and ts.tuition_id = @T where sj.id = $1`,
    [subjectId],
  );
  if (!subject) throw notFound('This subject');
  await q('select finalize_expired_attempts()');
  await releaseFinishedTests(T);
  const students = await tq(
    T,
    `select u.id, u.display_name, u.username, (m.status = 'active') as active, u.last_seen_at,
            (select avg(a.score / nullif(a.max_score, 0)) ${OWN_RESULTS}) as avg_pct,
            (select count(*) ${OWN_RESULTS}) as tests_done
       from memberships m join users u on u.id = m.user_id
      where m.tuition_id = @T and m.role = 'student' and m.status in ('active', 'off') and m.class_level = $1
        and exists (select 1 from student_subjects ss where ss.tuition_id = @T and ss.student_id = u.id and ss.subject_id = $2)
      order by (m.status = 'active') desc, u.display_name`,
    [cls, subjectId],
  );
  const tests = await tq(
    T,
    `with ${assignedCte('@T')}
     select t.id, t.title, t.status, t.opens_at, t.closes_at, t.results_released_at, t.time_limit_min, now() as now,
            (select count(*) from test_questions tq where tq.test_id = t.id) as question_count, ${TEST_COUNTS}
       from tests t
      where t.tuition_id = @T and t.class_level = $1 and t.subject_id = $2 and not (t.status = 'draft' and t.library_key is not null)
      order by coalesce(t.closes_at, t.opens_at, t.created_at) desc, t.title
      limit 100`,
    [cls, subjectId],
  );
  return c.json({ group: { class_level: cls, subject_id: subjectId, subject: subject.name }, students, tests });
});

// ---------------------------------------------------------------- tutors

/** The tuition's tutors: they share its groups, students, papers and tests. */
teacherRoutes.get('/tutors', async (c) => {
  const rows = await tq(
    tuitionOf(c).id,
    `select u.id, u.display_name, u.username, (m.status = 'active') as active, u.last_seen_at, m.joined_at as created_at, (m.role = 'owner') as owner
       from memberships m join users u on u.id = m.user_id
      where m.tuition_id = @T and m.role in ('owner', 'tutor') and m.status in ('active', 'off')
      order by m.joined_at`,
  );
  return c.json({ tutors: rows, me: c.get('user').id });
});

/** Adds a tutor to the tuition, with a login of their own. */
teacherRoutes.post('/tutors', async (c) => {
  const T = tuitionOf(c).id;
  const b = await readBody(c);
  const displayName = str(b, 'display_name', { max: 60 })!;
  const username = checkUsername(b.username);
  const { hash, salt } = await hashSecret(checkPassword(b.password));
  try {
    const u = await tx(async (cx) => {
      const row = await q1(
        `insert into users (role, username, display_name, secret_hash, secret_salt) values ('teacher', $1, $2, $3, $4)
         returning id, display_name, username, active, created_at`,
        [username, displayName, hash, salt],
        cx,
      );
      await cx.query(`insert into memberships (tuition_id, user_id, role, status) values ($1, $2, 'tutor', 'active')`, [T, row.id]);
      return row;
    });
    return c.json({ tutor: u }, 201);
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'username_taken', `The username ${username} is already taken.`);
    throw e;
  }
});

/** Turns a tutor's place in this tuition off (signing them out if it was their last) or back on. Not your own. */
teacherRoutes.post('/tutors/:id/active', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'tutor id');
  if (id === c.get('user').id) throw new HttpError(409, 'self', 'You cannot turn off your own login.');
  const active = bool(await readBody(c), 'active');
  const m = await tq1(
    T,
    `update memberships set status = $2 where tuition_id = @T and user_id = $1 and role = 'tutor' and status in ('active', 'off') returning user_id`,
    [id, active ? 'active' : 'off'],
  );
  if (!m) throw notFound('This tutor');
  const loginOn = await refreshLogin(id);
  if (!active && !loginOn) await killSessions(id);
  return c.json({ tutor: { id, active } });
});

teacherRoutes.get('/chapters', async (c) => {
  const cls = c.req.query('class');
  const subject = c.req.query('subject');
  const rows = await tq(
    tuitionOf(c).id,
    `select ch.id, ch.class_level, ch.subject_id, ch.name, ch.sort_order,
            (select count(*) from questions qq where qq.chapter_id = ch.id) as questions
       from chapters ch
      where ch.tuition_id = @T and ($1::smallint is null or ch.class_level = $1) and ($2::uuid is null or ch.subject_id = $2)
      order by ch.class_level, ch.sort_order, ch.name`,
    [cls ? Number(cls) : null, subject ? uuid(subject, 'subject') : null],
  );
  return c.json({ chapters: rows });
});

teacherRoutes.post('/chapters', async (c) => {
  const T = tuitionOf(c).id;
  const b = await readBody(c);
  const cls = (await levelIn(b, 'class_level', T))!;
  const name = str(b, 'name', { max: 80 })!;
  const subject = uuidOpt(b.subject_id, 'subject') ?? (await defaultSubject(T));
  await taughtSubject(T, subject);
  try {
    const ch = await tq1(
      T,
      `insert into chapters (tuition_id, class_level, subject_id, name, sort_order)
       values (@T, $1, $2, $3, coalesce((select max(sort_order) + 1 from chapters where tuition_id = @T and class_level = $1 and subject_id = $2), 0))
       returning id, class_level, subject_id, name, sort_order`,
      [cls, subject, name],
    );
    return c.json({ chapter: ch }, 201);
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'duplicate', `This subject already has a ${await levelLabel(T, cls)} chapter called ${name}.`);
    if (e.code === '23503') throw bad('That subject no longer exists.');
    throw e;
  }
});

teacherRoutes.patch('/chapters/:id', async (c) => {
  const b = await readBody(c);
  const ch = await tq1(
    tuitionOf(c).id,
    `update chapters set name = coalesce($2, name), sort_order = coalesce($3, sort_order) where id = $1 and tuition_id = @T
     returning id, class_level, name, sort_order`,
    [uuid(c.req.param('id')), str(b, 'name', { max: 80, optional: true }) ?? null, int(b, 'sort_order', { optional: true }) ?? null],
  );
  if (!ch) throw notFound('This chapter');
  return c.json({ chapter: ch });
});

teacherRoutes.delete('/chapters/:id', async (c) => {
  await tq(tuitionOf(c).id, 'delete from chapters where id = $1 and tuition_id = @T', [uuid(c.req.param('id'))]);
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
    class_level: int(b, 'class_level', { min: CLASS_MIN, max: CUSTOM_MAX })!,
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
  (select exam_name from papers where id = qq.paper_id) as paper, (select category from papers where id = qq.paper_id) as category,
  (select count(*) from test_questions tq where tq.question_id = qq.id) as used_in`;

/**
 * A question's subject: its chapter's subject, else the one sent (a subject the tuition teaches),
 * else null: a new question then gets the tuition's default, an edited one keeps its own.
 */
async function questionSubject(T: string, x: { chapter_id: string | null; subject_id: string | null }, cx?: any): Promise<string | null> {
  if (x.chapter_id) {
    const ch = await tq1<{ subject_id: string }>(T, 'select subject_id from chapters where id = $1 and tuition_id = @T', [x.chapter_id], cx);
    if (!ch) throw bad('That chapter is not in this tuition.', 'unknown_chapter');
    return ch.subject_id;
  }
  if (x.subject_id) return (await taughtSubject(T, x.subject_id, cx)).id;
  return null;
}

async function withImage<T extends { image_key: string | null }>(row: T) {
  return { ...row, image_url: await maybeViewUrl(row.image_key) };
}

/**
 * Where questions came from, for the Questions tab: one group per paper category ("NCERT
 * Exemplar"), papers with no category, the ready-made library, and questions typed by hand.
 * Keys: 'cat:<category>', 'papers', 'library', 'manual'.
 */
teacherRoutes.get('/question-groups', async (c) => {
  const rows = await tq(
    tuitionOf(c).id,
    `select case when qq.source = 'paper' then coalesce('cat:' || pa.category, 'papers') else qq.source end as key,
            min(pa.category) as category, count(*) as questions, count(distinct qq.paper_id) as papers,
            array_agg(distinct qq.class_level order by qq.class_level) as classes,
            array_agg(distinct sj.name) filter (where sj.name is not null) as subjects,
            max(qq.created_at) as latest
       from questions qq left join papers pa on pa.id = qq.paper_id left join subjects sj on sj.id = qq.subject_id
      where qq.tuition_id = @T
      group by 1`,
  );
  return c.json({ groups: rows });
});

/** A group key as filters: the source, and for papers which category (null: none). */
function groupFilter(group: string | undefined) {
  if (!group) return { source: null, category: null, uncategorised: false };
  if (group === 'library' || group === 'manual') return { source: group, category: null, uncategorised: false };
  if (group === 'papers') return { source: 'paper', category: null, uncategorised: true };
  if (group.startsWith('cat:') && group.length > 4) return { source: 'paper', category: group.slice(4), uncategorised: false };
  throw bad('That question group is not known.');
}

teacherRoutes.get('/questions', async (c) => {
  const cls = c.req.query('class');
  const chapter = c.req.query('chapter');
  const subject = c.req.query('subject');
  const search = c.req.query('q');
  const g = groupFilter(c.req.query('group'));
  const rows = await tq(
    tuitionOf(c).id,
    `select ${QUESTION_COLS} from questions qq left join chapters ch on ch.id = qq.chapter_id left join papers pa on pa.id = qq.paper_id
      where qq.tuition_id = @T
        and ($1::smallint is null or qq.class_level = $1)
        and ($2::uuid is null or qq.chapter_id = $2)
        and ($3::text is null or qq.text ilike '%' || $3 || '%')
        and ($4::uuid is null or qq.subject_id = $4)
        and ($5::text is null or qq.source = $5)
        and ($6::text is null or pa.category = $6)
        and (not $7 or pa.category is null)
      order by ${g.source === 'paper'
        // A paper group: newest paper first, each paper's questions in the order they were printed.
        ? `pa.created_at desc, qq.paper_id, (select d.page_no * 1000 + d.seq from paper_drafts d where d.question_id = qq.id limit 1)`
        : `qq.class_level, (select sort_order from subjects where id = qq.subject_id), qq.subject_id,
               ch.sort_order nulls last, ch.name, qq.created_at desc`}
      limit ${g.source ? 1000 : 300}`,
    [cls ? Number(cls) : null, chapter ? uuid(chapter, 'chapter') : null, search?.trim() || null, subject ? uuid(subject, 'subject') : null,
      g.source, g.category, g.uncategorised],
  );
  return c.json({ questions: await Promise.all(rows.map(withImage)) });
});

teacherRoutes.get('/questions/:id', async (c) => {
  const row = await tq1(
    tuitionOf(c).id,
    `select ${QUESTION_COLS} from questions qq left join chapters ch on ch.id = qq.chapter_id where qq.id = $1 and qq.tuition_id = @T`,
    [uuid(c.req.param('id'))],
  );
  if (!row) throw notFound('This question');
  return c.json({ question: await withImage(row) });
});

teacherRoutes.post('/questions', async (c) => {
  const T = tuitionOf(c).id;
  const x = readQuestion(await readBody(c));
  x.image_key = ownImageKey(T, x.image_key);
  await assertLevel(T, x.class_level);
  if (!(x.marks > 0 && x.marks <= 100)) throw bad('Marks must be between 0 and 100.');
  const subject = (await questionSubject(T, x)) ?? (await defaultSubject(T));
  const row = await tq1(
    T,
    `insert into questions (tuition_id, class_level, chapter_id, text, options, correct_option, solution, marks, keep_option_order, image_key, created_by,
                            subject_id)
     values (@T, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) returning id`,
    [x.class_level, x.chapter_id, x.text, x.options, x.correct_option, x.solution, x.marks, x.keep_option_order, x.image_key, c.get('user').id,
      subject],
  );
  await ensureGroup(T, x.class_level, subject);
  return c.json({ id: row.id }, 201);
});

teacherRoutes.patch('/questions/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'));
  const x = readQuestion(await readBody(c));
  await assertLevel(T, x.class_level);
  const subject = await questionSubject(T, x);
  const regraded = await tx(async (cx) => {
    const before = await tq1(T, 'select correct_option, marks, image_key from questions where id = $1 and tuition_id = @T for update', [id], cx);
    if (!before) throw notFound('This question');
    x.image_key = ownImageKey(T, x.image_key, before.image_key);
    await cx.query(
      `update questions set class_level = $2, chapter_id = $3, text = $4, options = $5, correct_option = $6, solution = $7,
                            marks = $8, keep_option_order = $9, image_key = $10, updated_at = now(),
                            subject_id = coalesce($11::uuid, subject_id)
        where id = $1`,
      [id, x.class_level, x.chapter_id, x.text, x.options, x.correct_option, x.solution, x.marks, x.keep_option_order, x.image_key, subject],
    );
    // A corrected answer or new marks re-mark every submitted test that had this question, so
    // a student who chose the right option gets the mark even if the key was wrong when she wrote it.
    if (before.correct_option === x.correct_option && Number(before.marks) === Number(x.marks)) return 0;
    const r = await cx.query('select grade_attempt(a.id) from attempts a where a.submitted_at is not null and $1 = any(a.question_order)', [id]);
    return r.rowCount ?? 0;
  });
  return c.json({ id, regraded });
});

/**
 * Deletes a question. It is taken out of tests nobody has written; a test students have written
 * keeps it, so their results stay whole, and then the question cannot be deleted.
 */
teacherRoutes.delete('/questions/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'));
  const mine = await tq1(T, 'select 1 as x from questions where id = $1 and tuition_id = @T', [id]);
  if (!mine) throw notFound('This question');
  const written = await q1(
    `select count(*) as n from test_questions tq where tq.question_id = $1
        and exists (select 1 from attempts a where a.test_id = tq.test_id)`,
    [id],
  );
  if (written.n > 0) {
    throw new HttpError(409, 'in_use', 'Students have written a test with this question, so it stays to keep their results whole.');
  }
  const removed = await tx(async (cx) => {
    const r = await cx.query('delete from test_questions where question_id = $1', [id]);
    await cx.query('delete from questions where id = $1', [id]);
    return r.rowCount ?? 0;
  });
  return c.json({ ok: true, removed_from_tests: removed });
});

/** A direct upload URL for a question diagram. */
teacherRoutes.post('/uploads', async (c) => {
  const key = newImageKey(tuitionOf(c).id);
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
    class_level: int(b, 'class_level', { min: CLASS_MIN, max: CUSTOM_MAX })!,
    subject_id: uuidOpt(b.subject_id, 'subject'),
    time_limit_min: int(b, 'time_limit_min', { min: 1, max: 300, optional: true }) ?? null,
    opens_at: opensAt,
    closes_at: closesAt,
    shuffle: bool(b, 'shuffle', true),
    assign_all: assignAll,
    assign_group: assignGroup,
    question_ids: [...new Set(ids.map((x: string) => uuid(x, 'question id')))],
    student_ids: [...new Set(students.map((x: string) => uuid(x, 'student id')))],
    paper_id: uuidOpt(b.paper_id, 'paper'),
  };
}

/** The questions, chosen students and paper of a test must all belong to the tuition it is in. */
async function checkTestParts(T: string, t: ReturnType<typeof readTest>, cx?: any) {
  await assertLevel(T, t.class_level, cx);
  await ownQuestions(T, t.question_ids, cx);
  await memberStudents(T, t.student_ids, cx);
  if (t.paper_id && !(await tq1(T, 'select 1 as x from papers where id = $1 and tuition_id = @T', [t.paper_id], cx))) {
    throw bad('That paper is not in this tuition.', 'unknown_paper');
  }
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
  const T = tuitionOf(c).id;
  await q('select finalize_expired_attempts()');
  const rows = await tq(
    T,
    `with ${assignedCte('@T')}
     select t.id, t.title, t.class_level, t.time_limit_min, t.opens_at, t.closes_at, t.shuffle, t.assign_all, t.status, t.created_at,
            t.subject_id, (select name from subjects where id = t.subject_id) as subject, t.assign_group,
            (select count(*) from test_questions tq where tq.test_id = t.id) as question_count,
            (select count(*) from assigned a where a.test_id = t.id) as assigned,
            (select count(distinct x.student_id) from attempts x where x.test_id = t.id and x.submitted_at is not null) as submitted,
            (select count(*) from attempts x where x.test_id = t.id and x.submitted_at is null) as writing,
            now() as now
       from tests t
      where t.tuition_id = @T
      order by coalesce(t.closes_at, t.opens_at, t.created_at) desc, t.title`,
  );
  return c.json({ tests: rows });
});

teacherRoutes.post('/tests', async (c) => {
  const T = tuitionOf(c).id;
  const t = readTest(await readBody(c));
  const subject = t.subject_id ? (await taughtSubject(T, t.subject_id)).id : await defaultSubject(T);
  await checkTestParts(T, t);
  const id = await tx(async (cx) => {
    const row = await q1(
      `insert into tests (tuition_id, title, class_level, time_limit_min, opens_at, closes_at, shuffle, assign_all, created_by, subject_id, assign_group,
                          paper_id)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, coalesce($11, false), $12) returning id`,
      [T, t.title, t.class_level, t.time_limit_min, t.opens_at, t.closes_at, t.shuffle, t.assign_all, c.get('user').id,
        subject, t.assign_group, t.paper_id],
      cx,
    );
    await saveTestChildren(cx, row.id, t);
    await ensureGroup(T, t.class_level, subject, cx);
    return row.id;
  });
  return c.json({ id }, 201);
});

teacherRoutes.get('/tests/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'test id');
  const t = await tq1(
    T,
    `select t.*, (select count(*) from attempts x where x.test_id = t.id) as attempts from tests t where t.id = $1 and t.tuition_id = @T`,
    [id],
  );
  if (!t) throw notFound('This test');
  const questions = await q(
    `select ${QUESTION_COLS}, tq.position from test_questions tq join questions qq on qq.id = tq.question_id
       left join chapters ch on ch.id = qq.chapter_id where tq.test_id = $1 order by tq.position`,
    [id],
  );
  const students = await tq(
    T,
    `select u.id, u.display_name, m.class_level from test_students ts join users u on u.id = ts.student_id
       join memberships m on m.user_id = u.id and m.tuition_id = @T
      where ts.test_id = $1 order by u.display_name`,
    [id],
  );
  return c.json({ test: t, questions: await Promise.all(questions.map(withImage)), students });
});

teacherRoutes.patch('/tests/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'test id');
  const t = readTest(await readBody(c));
  if (t.subject_id) await taughtSubject(T, t.subject_id);
  const done = await tx(async (cx) => {
    const own = await tq1<{ status: string; subject_id: string }>(T, 'select status, subject_id from tests where id = $1 and tuition_id = @T for update', [id], cx);
    if (!own) throw notFound('This test');
    await checkTestParts(T, t, cx);
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
    // A published test always has a closing time: students see their marks after it.
    if (own.status === 'published' && !t.closes_at) t.closes_at = defaultClosing();
    // Moved to open later: students are told again when it opens. A new closing time gets its
    // own reminder.
    const row = await q1(
      `update tests set title = $2, class_level = $3, time_limit_min = $4, opens_at = $5, closes_at = $6,
                        shuffle = $7, assign_all = $8, subject_id = coalesce($9, subject_id),
                        assign_group = case when $8 then false else coalesce($10, assign_group) end,
                        announced_at = case when $5::timestamptz > now() then null else announced_at end,
                        reminded_at = case when $6::timestamptz is distinct from closes_at then null else reminded_at end
        where id = $1 returning id, status, subject_id`,
      [id, t.title, t.class_level, t.time_limit_min, t.opens_at, t.closes_at, t.shuffle, t.assign_all, t.subject_id, t.assign_group],
      cx,
    );
    await saveTestChildren(cx, id, t);
    await ensureGroup(T, t.class_level, row.subject_id, cx);
    return row.status as string;
  });
  if (done === 'published') waitUntil(afterTestChange());
  return c.json({ id });
});

teacherRoutes.post('/tests/:id/publish', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'test id');
  const published = bool(await readBody(c), 'published');
  const own = await tq1(T, 'select closes_at, now() as now from tests where id = $1 and tuition_id = @T', [id]);
  if (!own) throw notFound('This test');
  if (published) {
    const n = await q1('select count(*) as n from test_questions where test_id = $1', [id]);
    if (!n || n.n === 0) throw new HttpError(409, 'empty_test', 'Add at least one question before publishing.');
    // Every test closes: students see their marks after that, so it cannot stay open for ever.
    // Posted with no closing time, it gets the default one.
    if (!own.closes_at) await pool.query('update tests set closes_at = $2 where id = $1', [id, defaultClosing()]);
    else if (own.closes_at <= own.now) throw new HttpError(400, 'closing_passed', 'The closing time has already passed. Choose a later one.');
  }
  const t = await q1(
    `update tests set status = $2 where id = $1 returning id, status`,
    [id, published ? 'published' : 'draft'],
  );
  // Students hear about it after the teacher's screen has its answer.
  if (published) waitUntil(afterTestChange());
  return c.json({ test: t });
});

/** Deletes a test. One students have written goes only with ?with_results=1, and takes their results with it. */
teacherRoutes.delete('/tests/:id', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'test id');
  if (!(await tq1(T, 'select 1 as x from tests where id = $1 and tuition_id = @T', [id]))) throw notFound('This test');
  const n = await q1('select count(distinct student_id) as n from attempts where test_id = $1', [id]);
  if (n.n > 0 && c.req.query('with_results') !== '1') {
    throw new HttpError(409, 'has_attempts', `${n.n} student${n.n === 1 ? ' has' : 's have'} written this test. Deleting it deletes their results too.`);
  }
  await pool.query('delete from tests where id = $1', [id]);
  return c.json({ ok: true, results_deleted: n.n });
});

/** Opens the marks and answers to the test's students now, without waiting for the closing time. */
teacherRoutes.post('/tests/:id/release-results', async (c) => {
  const id = uuid(c.req.param('id'), 'test id');
  const t = await tq1(
    tuitionOf(c).id,
    `update tests set results_released_at = coalesce(results_released_at, now())
      where id = $1 and tuition_id = @T and status = 'published' returning id, results_released_at`,
    [id],
  );
  if (!t) throw new HttpError(409, 'not_published', 'Only a published test has marks to show.');
  return c.json({ ok: true, results_released_at: t.results_released_at });
});

teacherRoutes.get('/tests/:id/results', async (c) => {
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'test id');
  await q('select finalize_expired_attempts()');
  await releaseFinishedTests(T);
  const t = await tq1(
    T,
    `select id, title, class_level, opens_at, closes_at, time_limit_min, status, now() as now, subject_id, assign_group, shuffle,
            results_released_at,
            (results_released_at is not null or closes_at is null or closes_at <= now()) as results_open,
            (select name from subjects where id = tests.subject_id) as subject
       from tests where id = $1 and tuition_id = @T`,
    [id],
  );
  if (!t) throw notFound('This test');
  const students = await tq(
    T,
    `with ${assignedCte('@T')}, pool as (
       select student_id from assigned where test_id = $1
       union select student_id from attempts where test_id = $1)
     select u.id, u.display_name, m.class_level,
            la.id as attempt_id, la.attempt_no, la.started_at, la.submitted_at, la.score, la.max_score,
            la.correct_count, la.wrong_count, la.skipped_count, la.auto_submitted,
            exists (select 1 from retake_grants g where g.test_id = $1 and g.student_id = u.id and g.used_at is null) as retake_pending
       from pool p join users u on u.id = p.student_id
       join memberships m on m.user_id = u.id and m.tuition_id = @T
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
  const T = tuitionOf(c).id;
  const id = uuid(c.req.param('id'), 'test id');
  const studentId = uuid((await readBody(c)).student_id, 'student id');
  if (!(await tq1(T, 'select 1 as x from tests where id = $1 and tuition_id = @T', [id]))) throw notFound('This test');
  await memberStudents(T, [studentId]);
  const pending = await q1('select id from retake_grants where test_id = $1 and student_id = $2 and used_at is null', [id, studentId]);
  if (!pending) await pool.query('insert into retake_grants (test_id, student_id) values ($1, $2)', [id, studentId]);
  return c.json({ ok: true });
});

teacherRoutes.get('/attempts/:id', async (c) => {
  return c.json(await resultPayload(uuid(c.req.param('id'), 'attempt id'), { tuitionId: tuitionOf(c).id }));
});

// ---------------------------------------------------------------- settings

teacherRoutes.get('/settings', async (c) => {
  const t = tuitionOf(c);
  const sample = await tq1(
    t.id,
    `select (select count(*) from memberships m join users u on u.id = m.user_id where m.tuition_id = @T and u.is_sample) as users,
            (select count(*) from questions where tuition_id = @T and is_sample) as questions,
            (select count(*) from tests where tuition_id = @T and is_sample) as tests,
            (select count(*) from papers where tuition_id = @T and is_sample) as papers`,
  );
  const ai = await tq1(
    t.id,
    // Pages read, and real failures: a busy minute that AI waited out is not a failure.
    `select count(*) filter (where task = 'read_paper_page' and ok and created_at > now() - interval '1 day') as calls_today,
            count(*) filter (where not ok and coalesce(error, '') not like '429%' and created_at > now() - interval '1 day') as failed_today
       from ai_usage where tuition_id = @T`,
  );
  return c.json({ tuition_name: t.name, tuition: { id: t.id, name: t.name, role: t.role }, me: c.get('user'), sample, ai });
});

teacherRoutes.patch('/settings', async (c) => {
  const t = tuitionOf(c);
  const b = await readBody(c);
  const name = str(b, 'tuition_name', { max: 60, optional: true });
  const displayName = str(b, 'display_name', { max: 60, optional: true });
  if (name) {
    await pool.query('update tuitions set name = $2 where id = $1', [t.id, name]);
    // The apps from before tuitions read the name from here.
    if (t.id === FIRST_TUITION) await pool.query(`update app_settings set value = to_jsonb($1::text) where key = 'tuition_name'`, [name]);
  }
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

/** Removes everything the seed created in this tuition. Real students, questions and tests are untouched. */
teacherRoutes.delete('/sample-data', async (c) => {
  const T = tuitionOf(c).id;
  const keys = await tq<{ k: string }>(
    T,
    `select object_key as k from paper_pages pp join papers p on p.id = pp.paper_id where p.is_sample and p.tuition_id = @T
     union all select image_key from questions where is_sample and tuition_id = @T and image_key is not null`,
  );
  const counts = await tx(async (cx) => {
    const del = async (sql: string) => (await tq(T, sql, [], cx)).length;
    // Real tests may use sample questions; detach those first so the questions can go.
    await tq(
      T,
      `delete from test_questions tq using questions qq where qq.id = tq.question_id and qq.is_sample and qq.tuition_id = @T
                     and not exists (select 1 from tests t where t.id = tq.test_id and t.is_sample)`,
      [],
      cx,
    );
    const tests = await del('delete from tests where is_sample and tuition_id = @T returning id');
    const questions = await del('delete from questions where is_sample and tuition_id = @T returning id');
    const papers = await del('delete from papers where is_sample and tuition_id = @T returning id');
    const users = await del(
      `delete from users u where u.is_sample and u.role = 'student'
          and exists (select 1 from memberships m where m.user_id = u.id and m.tuition_id = @T) returning u.id`,
    );
    const chapters = await del('delete from chapters where is_sample and tuition_id = @T returning id');
    return { tests, questions, papers, users, chapters };
  });
  await deleteObjects(keys.map((r) => r.k)).catch(() => {});
  return c.json({ removed: counts });
});
