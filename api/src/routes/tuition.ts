import { waitUntil } from '@neon/functions';
import { Hono } from 'hono';
import { tuitionOf, type AppEnv } from '../lib/auth.ts';
import { pool, tq, tq1, tx } from '../lib/db.ts';
import { bool, HttpError, int, notFound, str, uuid } from '../lib/http.ts';
import { afterTestChange } from '../lib/notify.ts';
import { pushConfigured, pushToUsers } from '../lib/push.ts';
import { subjectIds } from '../lib/subjects.ts';
import { ensureGroup, freeJoinCode, FIRST_TUITION, showCode, taughtSubjectIds } from '../lib/tuition.ts';
import { readBody } from './body.ts';

// A tutor's own tuition: its name, the code students join with, and the students asking to join.
// Mounted with the teacher routes, behind requireUser('teacher').
export const tuitionRoutes = new Hono<AppEnv>();

const TUITION = `select t.id, t.name, t.join_code, t.join_open, t.plan, t.plan_until, t.created_at,
       (select count(*) from memberships m where m.tuition_id = t.id and m.role = 'student' and m.status = 'active') as students,
       (select count(*) from memberships m where m.tuition_id = t.id and m.role in ('owner', 'tutor') and m.status = 'active') as tutors,
       (select count(*) from groups g where g.tuition_id = t.id) as groups,
       (select count(*) from memberships m where m.tuition_id = t.id and m.role = 'student' and m.status = 'pending') as pending
  from tuitions t where t.id = @T`;

async function tuitionPayload(id: string, role: string) {
  const t = await tq1(id, TUITION);
  return { ...t, join_code_shown: showCode(t.join_code), role };
}

tuitionRoutes.get('/tuition', async (c) => {
  const t = tuitionOf(c);
  return c.json({ tuition: await tuitionPayload(t.id, t.role) });
});

/** Renames the tuition, or opens and closes joining. */
tuitionRoutes.patch('/tuition', async (c) => {
  const t = tuitionOf(c);
  const b = await readBody(c);
  const name = str(b, 'name', { max: 60, optional: true });
  const open = 'join_open' in b ? bool(b, 'join_open') : null;
  await tq(
    t.id,
    `update tuitions set name = coalesce($1, name), join_open = coalesce($2, join_open) where id = @T`,
    [name ?? null, open],
  );
  // The apps from before tuitions read the name from here.
  if (name && t.id === FIRST_TUITION) await pool.query(`update app_settings set value = to_jsonb($1::text) where key = 'tuition_name'`, [name]);
  return c.json({ tuition: await tuitionPayload(t.id, t.role) });
});

/** A new join code: the old one stops working. Only the owner. */
tuitionRoutes.post('/tuition/join-code', async (c) => {
  const t = tuitionOf(c);
  if (t.role !== 'owner') throw new HttpError(403, 'owner_only', 'Only the owner of the tuition can change its join code.');
  await pool.query('update tuitions set join_code = $2 where id = $1', [t.id, await freeJoinCode()]);
  return c.json({ tuition: await tuitionPayload(t.id, t.role) });
});

// ---------------------------------------------------------------- students asking to join

tuitionRoutes.get('/join-requests', async (c) => {
  const rows = await tq(
    tuitionOf(c).id,
    `select u.id, u.display_name, u.username, m.class_level, m.joined_at as asked_at
       from memberships m join users u on u.id = m.user_id
      where m.tuition_id = @T and m.role = 'student' and m.status = 'pending'
      order by m.joined_at`,
  );
  return c.json({ requests: rows });
});

/** Lets a student in, in the class and with the subjects the tutor chooses (their asked class, and none, if not sent). */
tuitionRoutes.post('/join-requests/:id/accept', async (c) => {
  const t = tuitionOf(c);
  const id = uuid(c.req.param('id'), 'student id');
  const b = await readBody(c);
  const cls = int(b, 'class_level', { min: 6, max: 12, optional: true }) ?? null;
  const subjects = 'subject_ids' in b ? subjectIds(b.subject_ids) : [];
  await taughtSubjectIds(t.id, subjects);
  const m = await tx(async (cx) => {
    const row = await tq1<{ class_level: number }>(
      t.id,
      `update memberships set status = 'active', class_level = coalesce($2, class_level)
        where tuition_id = @T and user_id = $1 and role = 'student' and status = 'pending' returning class_level`,
      [id, cls],
      cx,
    );
    if (!row) return null;
    await tq(t.id, 'delete from student_subjects where tuition_id = @T and student_id = $1', [id], cx);
    if (subjects.length) {
      await tq(t.id, 'insert into student_subjects (tuition_id, student_id, subject_id) select @T::uuid, $1::uuid, unnest($2::uuid[])', [id, subjects], cx);
      for (const s of subjects) await ensureGroup(t.id, row.class_level, s, cx);
    }
    return row;
  });
  if (!m) throw notFound('This request');
  if (pushConfigured()) await pushToUsers([id], { title: t.name, body: 'You have been added. Open the app to see your tests.' }).catch(() => 0);
  waitUntil(afterTestChange());
  return c.json({ ok: true });
});

tuitionRoutes.post('/join-requests/:id/decline', async (c) => {
  const id = uuid(c.req.param('id'), 'student id');
  const gone = await tq1(
    tuitionOf(c).id,
    `delete from memberships where tuition_id = @T and user_id = $1 and role = 'student' and status = 'pending' returning user_id`,
    [id],
  );
  if (!gone) throw notFound('This request');
  return c.json({ ok: true });
});
