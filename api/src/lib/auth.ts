import { createHash, pbkdf2 as pbkdf2Cb, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { createMiddleware } from 'hono/factory';
import { clientInfo, recordInstall } from './client.ts';
import { pool, q1, type Db } from './db.ts';
import { HttpError } from './http.ts';

const pbkdf2 = promisify(pbkdf2Cb);
const ITERATIONS = 120_000;
const SESSION_DAYS = 120;
export const MAX_FAILED = 5;
export const LOCK_MINUTES = 5;

export type SessionUser = {
  id: string;
  role: 'teacher' | 'student' | 'developer';
  username: string;
  display_name: string;
  class_level: number | null;
};
export type AppEnv = { Variables: { user: SessionUser } };

export async function hashSecret(secret: string, salt = randomBytes(16).toString('base64')) {
  const hash = (await pbkdf2(secret, salt, ITERATIONS, 32, 'sha256')).toString('base64');
  return { hash, salt };
}

export async function verifySecret(secret: string, hash: string, salt: string) {
  const { hash: candidate } = await hashSecret(secret, salt);
  const a = Buffer.from(candidate);
  const b = Buffer.from(hash);
  return a.length === b.length && timingSafeEqual(a, b);
}

export const tokenHash = (token: string) => createHash('sha256').update(token).digest('hex');
export const newPin = () => String(randomInt(0, 10_000)).padStart(4, '0');

export function checkPin(pin: unknown): string {
  if (typeof pin !== 'string' || !/^\d{4}$/.test(pin)) throw new HttpError(400, 'invalid_pin', 'The PIN must be exactly 4 digits.');
  return pin;
}

export function checkPassword(pw: unknown): string {
  if (typeof pw !== 'string' || pw.length < 8) throw new HttpError(400, 'weak_password', 'The password must be at least 8 characters.');
  return pw;
}

export function checkUsername(u: unknown): string {
  const s = typeof u === 'string' ? u.trim().toLowerCase() : '';
  if (!/^[a-z0-9._]{3,24}$/.test(s)) {
    throw new HttpError(400, 'invalid_username', 'Usernames use 3–24 lowercase letters, numbers, dots or underscores.');
  }
  return s;
}

/** Creates a session and returns the bearer token (only its hash is stored). */
export async function createSession(userId: string, installId: string | null = null, db: Db = pool): Promise<string> {
  const token = randomBytes(32).toString('base64url');
  await db.query(
    `insert into sessions (token_hash, user_id, expires_at, install_id) values ($1, $2, now() + make_interval(days => $3), $4)`,
    [tokenHash(token), userId, SESSION_DAYS, installId],
  );
  return token;
}

export const killSessions = (userId: string, db: Db = pool) => db.query('delete from sessions where user_id = $1', [userId]);

const FORBIDDEN: Record<SessionUser['role'], string> = {
  teacher: 'This is only for the teacher.',
  student: 'This is only for students.',
  developer: 'This is only for the developer.',
};

/** Bearer-token auth. With a role, other roles get 403. */
export const requireUser = (role?: SessionUser['role']) =>
  createMiddleware<AppEnv>(async (c, next) => {
    const header = c.req.header('authorization') ?? '';
    if (!header.startsWith('Bearer ')) throw new HttpError(401, 'signed_out', 'Please log in again.');
    const hash = tokenHash(header.slice(7).trim());
    const user = await q1<SessionUser & { stale: boolean }>(
      `select u.id, u.role, u.username, u.display_name, u.class_level,
              s.last_used_at < now() - interval '2 minutes' as stale
         from sessions s join users u on u.id = s.user_id
        where s.token_hash = $1 and s.expires_at > now() and u.active`,
      [hash],
    );
    if (!user) throw new HttpError(401, 'signed_out', 'Please log in again.');
    if (role && user.role !== role) throw new HttpError(403, 'forbidden', FORBIDDEN[role]);
    if (user.stale) {
      // Sliding expiry and "last seen", written at most every 2 minutes per session: often enough
      // for the admin app's "active now", rarely enough to add almost nothing to the database's work.
      const ci = clientInfo(c);
      await recordInstall(user.id, ci);
      await pool.query(
        `update sessions set last_used_at = now(), expires_at = now() + make_interval(days => $2),
                install_id = coalesce($3, install_id)
          where token_hash = $1`,
        [hash, SESSION_DAYS, ci.installId],
      );
      await pool.query('update users set last_seen_at = now() where id = $1', [user.id]);
    }
    const { stale: _stale, ...sessionUser } = user;
    c.set('user', sessionUser);
    await next();
  });
