import { Hono } from 'hono';
import {
  checkPassword, checkUsername, createSession, hashSecret, LOCK_MINUTES, MAX_FAILED, requireUser, tokenHash, verifySecret, type AppEnv,
} from '../lib/auth.ts';
import { clientInfo, recordInstall } from '../lib/client.ts';
import { pool, q, q1, tx } from '../lib/db.ts';
import { bad, HttpError, int, str, uuidOpt } from '../lib/http.ts';
import { addLevel, CLASS_MAX, CLASS_MIN, LEVELS_JSON } from '../lib/levels.ts';
import { ensureGroup, freeJoinCode, showCode } from '../lib/tuition.ts';
import { readBody } from './body.ts';

export const authRoutes = new Hono<AppEnv>();

/** The tuitions a person is in or waiting to join. Only a tutor is shown the join code. */
const myTuitions = (userId: string) =>
  q(
    `select t.id, t.name, m.role, m.status, m.class_level, m.joined_at, ${LEVELS_JSON},
            case when m.role in ('owner', 'tutor') and m.status = 'active' then t.join_code end as join_code
       from memberships m join tuitions t on t.id = m.tuition_id
      where m.user_id = $1 and m.status in ('active', 'pending')
      order by m.joined_at`,
    [userId],
  );

authRoutes.post('/login', async (c) => {
  const b = await readBody(c);
  const username = typeof b.username === 'string' ? b.username.trim().toLowerCase() : '';
  const secret = typeof b.secret === 'string' ? b.secret : '';
  const wrong = new HttpError(401, 'wrong_login', 'That username and PIN do not match.');
  if (!username || !secret) throw wrong;
  const ci = clientInfo(c);
  // Every attempt goes into the login history the admin app shows.
  const log = (outcome: string, userId: string | null = null) =>
    pool.query(
      `insert into auth_events (username, user_id, outcome, install_id, app_version) values ($1, $2, $3, $4, $5)`,
      [username.slice(0, 40), userId, outcome, ci.installId, ci.appVersion],
    );

  const u = await q1(
    `select id, role, username, display_name, class_level, secret_hash, secret_salt,
            active, failed_count, locked_until, now() as now
       from users where username = $1`,
    [username],
  );
  if (!u) {
    // The same work as a real attempt, so how long the reply takes does not say whether the username exists.
    await hashSecret(secret);
    await log('unknown_user');
    throw wrong;
  }
  if (!u.active) {
    // Only the person who knows the login is told it is off; anyone else sees what they would for a wrong guess.
    const right = await verifySecret(secret, u.secret_hash, u.secret_salt);
    await log(right ? 'inactive' : 'wrong_secret', u.id);
    if (!right) throw wrong;
    throw new HttpError(403, 'inactive', 'This login has been turned off. Please ask your teacher.');
  }
  if (u.locked_until && u.locked_until > u.now) {
    await log('locked', u.id);
    const mins = Math.max(1, Math.ceil((u.locked_until.getTime() - u.now.getTime()) / 60_000));
    throw new HttpError(429, 'locked', `Too many wrong tries. Try again in ${mins} minute${mins === 1 ? '' : 's'}.`);
  }
  if (!(await verifySecret(secret, u.secret_hash, u.secret_salt))) {
    const failed = u.failed_count + 1;
    if (failed >= MAX_FAILED) {
      await pool.query(
        `update users set failed_count = 0, locked_until = now() + make_interval(mins => $2) where id = $1`,
        [u.id, LOCK_MINUTES],
      );
      await log('lockout', u.id);
      throw new HttpError(429, 'locked', `Too many wrong tries. Try again in ${LOCK_MINUTES} minutes.`);
    }
    await pool.query('update users set failed_count = $2 where id = $1', [u.id, failed]);
    await log('wrong_secret', u.id);
    if (u.role !== 'student') throw new HttpError(401, 'wrong_login', 'That username and password do not match.');
    throw wrong;
  }

  await pool.query('update users set failed_count = 0, locked_until = null, last_seen_at = now() where id = $1', [u.id]);
  await recordInstall(u.id, ci);
  const token = await createSession(u.id, ci.installId);
  await log('ok', u.id);
  return c.json({
    token,
    user: {
      id: u.id, role: u.role, username: u.username, display_name: u.display_name,
      class_level: u.class_level,
    },
    tuitions: u.role === 'developer' ? [] : await myTuitions(u.id),
  });
});

const MAX_SIGNUPS_PER_HOUR = 30;
const MAX_SIGNUPS_PER_PHONE_PER_DAY = 3;

/**
 * A tutor signs themselves up. They get a login but no tuition yet: the app then asks them to
 * create one (POST /auth/tuitions). Sign-ups are capped, so the open door cannot be used to fill the database.
 */
authRoutes.post('/signup-tutor', async (c) => {
  const b = await readBody(c);
  const displayName = str(b, 'display_name', { max: 60 })!;
  const username = checkUsername(b.username);
  const password = checkPassword(b.password);
  const ci = clientInfo(c);
  const recent = await q1(
    `select (select count(*) from users where role = 'teacher' and created_at > now() - interval '1 hour') as hour,
            (select count(*) from auth_events where outcome = 'signup' and install_id = $1 and at > now() - interval '1 day') as phone_day`,
    [ci.installId],
  );
  if (recent.hour >= MAX_SIGNUPS_PER_HOUR || (ci.installId && recent.phone_day >= MAX_SIGNUPS_PER_PHONE_PER_DAY)) {
    throw new HttpError(429, 'too_many_signups', 'Too many new accounts were made just now. Please try again later.');
  }
  const { hash, salt } = await hashSecret(password);
  let u: { id: string; role: string; username: string; display_name: string };
  try {
    u = (await q1(
      `insert into users (role, username, display_name, secret_hash, secret_salt) values ('teacher', $1, $2, $3, $4)
       returning id, role, username, display_name`,
      [username, displayName, hash, salt],
    ))!;
  } catch (e: any) {
    if (e.code === '23505') throw new HttpError(409, 'username_taken', `The username ${username} is already taken.`);
    throw e;
  }
  await recordInstall(u.id, ci);
  const token = await createSession(u.id, ci.installId);
  await pool.query(
    `insert into auth_events (username, user_id, outcome, install_id, app_version) values ($1, $2, 'signup', $3, $4)`,
    [username, u.id, ci.installId, ci.appVersion],
  );
  return c.json({ token, user: { ...u, class_level: null }, tuitions: [] }, 201);
});

/** The standard subjects a new tuition can pick from while it is being set up (it has no tuition yet). */
authRoutes.get('/standard-subjects', requireUser('teacher', { tuition: 'none' }), async (c) =>
  c.json({ subjects: await q('select id, name from subjects where tuition_id is null order by sort_order, name') }));

const MAX_OWNED = 3;

/**
 * Creates a tuition for the signed-in tutor, who becomes its owner, with the subjects and groups
 * they teach: { name, groups: [{ class_level, subject_id | subject_name }] }. A subject is a
 * standard one (by id or by name) or, for a name nobody has used, one of the tuition's own.
 */
authRoutes.post('/tuitions', requireUser('teacher', { tuition: 'none' }), async (c) => {
  const me = c.get('user');
  const b = await readBody(c);
  const name = str(b, 'name', { max: 60 })!;
  const rawGroups: any[] = Array.isArray(b.groups) ? b.groups : [];
  if (rawGroups.length > 40) throw bad('That is too many groups to start with. Add the rest later.');
  const groups = rawGroups.map((g) => {
    const subjectId = uuidOpt(g?.subject_id, 'subject');
    const subjectName = str(g ?? {}, 'subject_name', { max: 40, optional: true }) ?? null;
    if (!subjectId && !subjectName) throw bad('Each group needs a subject.');
    // A new tuition has named no levels yet, so a group is Class 1 to 12 or gives the name of a level of its own.
    const levelName = str(g ?? {}, 'level_name', { max: 30, optional: true }) ?? null;
    const cls = levelName ? null : int(g, 'class_level', { min: CLASS_MIN, max: CLASS_MAX })!;
    return { cls, levelName, subjectId, subjectName };
  });
  const owned = await q1(`select count(*) as n from memberships where user_id = $1 and role = 'owner'`, [me.id]);
  if (owned.n >= MAX_OWNED) throw new HttpError(409, 'too_many_tuitions', `You already run ${MAX_OWNED} tuitions.`);

  const t = await tx(async (cx) => {
    const row = await q1<{ id: string; name: string; join_code: string }>(
      `insert into tuitions (name, join_code, created_by) values ($1, $2, $3) returning id, name, join_code`,
      [name, await freeJoinCode(cx), me.id],
      cx,
    );
    await cx.query(`insert into memberships (tuition_id, user_id, role, status) values ($1, $2, 'owner', 'active')`, [row!.id, me.id]);
    for (const g of groups) {
      let subject: { id: string } | undefined;
      if (g.subjectId) {
        subject = await q1('select id from subjects where id = $1 and tuition_id is null', [g.subjectId], cx);
        if (!subject) throw bad('Choose one of the listed subjects, or type a new one.', 'unknown_subject');
      } else {
        subject = await q1('select id from subjects where tuition_id is null and lower(name) = lower($1)', [g.subjectName], cx);
        subject ??= await q1('select id from subjects where tuition_id = $1 and lower(name) = lower($2)', [row!.id, g.subjectName], cx);
        subject ??= await q1(
          `insert into subjects (name, sort_order, tuition_id)
           values ($1, coalesce((select max(sort_order) + 1 from subjects where tuition_id = $2), 100), $2) returning id`,
          [g.subjectName, row!.id],
          cx,
        );
      }
      await cx.query('insert into tuition_subjects (tuition_id, subject_id) values ($1, $2) on conflict do nothing', [row!.id, subject!.id]);
      const cls = g.levelName ? (await addLevel(row!.id, g.levelName, cx)).code : g.cls!;
      await ensureGroup(row!.id, cls, subject!.id, cx);
    }
    return row!;
  });
  return c.json({ tuition: { id: t.id, name: t.name, role: 'owner', join_code: t.join_code, join_code_shown: showCode(t.join_code) } }, 201);
});

authRoutes.post('/logout', requireUser(), async (c) => {
  const header = c.req.header('authorization') ?? '';
  await pool.query('delete from sessions where token_hash = $1', [tokenHash(header.slice(7).trim())]);
  return c.json({ ok: true });
});

authRoutes.get('/me', requireUser(), async (c) => {
  const u = c.get('user');
  const tuitions = u.role === 'developer' ? [] : await myTuitions(u.id);
  const s = await q1(`select value #>> '{}' as name from app_settings where key = 'tuition_name'`);
  return c.json({
    user: u,
    // The apps from before tuitions show this as the tuition's name.
    tuition_name: c.get('tuition')?.name ?? tuitions.find((t: any) => t.status === 'active')?.name ?? s?.name ?? 'Core Academy',
    tuitions,
  });
});
