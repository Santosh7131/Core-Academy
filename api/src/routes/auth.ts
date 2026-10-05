import { Hono } from 'hono';
import { createSession, LOCK_MINUTES, MAX_FAILED, requireUser, tokenHash, verifySecret, type AppEnv } from '../lib/auth.ts';
import { clientInfo, recordInstall } from '../lib/client.ts';
import { pool, q1 } from '../lib/db.ts';
import { HttpError } from '../lib/http.ts';
import { readBody } from './body.ts';

export const authRoutes = new Hono<AppEnv>();

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
    await log('unknown_user');
    throw wrong;
  }
  if (!u.active) {
    await log('inactive', u.id);
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
  });
});

authRoutes.post('/logout', requireUser(), async (c) => {
  const header = c.req.header('authorization') ?? '';
  await pool.query('delete from sessions where token_hash = $1', [tokenHash(header.slice(7).trim())]);
  return c.json({ ok: true });
});

authRoutes.get('/me', requireUser(), async (c) => {
  const s = await q1(`select value #>> '{}' as name from app_settings where key = 'tuition_name'`);
  return c.json({ user: c.get('user'), tuition_name: s?.name ?? 'Core Academy' });
});
