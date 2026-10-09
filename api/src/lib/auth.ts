import { createHash, pbkdf2 as pbkdf2Cb, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { createMiddleware } from 'hono/factory';
import { clientInfo, recordInstall } from './client.ts';
import { pool, q1, type Db } from './db.ts';
import { HttpError } from './http.ts';
import { noTuition } from './tuition.ts';

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
/** The tuition a request is for: the one named in the x-tuition header, else the person's first. */
export type Tuition = { id: string; name: string; role: 'owner' | 'tutor' | 'student'; class_level: number | null };
export type AppEnv = { Variables: { user: SessionUser; tuition: Tuition | null } };

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

const TUITION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Bearer-token auth. With a role, other roles get 403. A teacher or student also gets a tuition:
 * the one the app names in x-tuition (they must be an active member of it), else their first.
 * `tuition: 'required'` (the default when a teacher or student route names its role) refuses a
 * person who has none yet; a route with no role, or `tuition: 'none'`, lets them through.
 */
export const requireUser = (role?: SessionUser['role'], opts: { tuition?: 'required' | 'none' } = {}) =>
  createMiddleware<AppEnv>(async (c, next) => {
    const header = c.req.header('authorization') ?? '';
    if (!header.startsWith('Bearer ')) throw new HttpError(401, 'signed_out', 'Please log in again.');
    const hash = tokenHash(header.slice(7).trim());
    const wanted = c.req.header('x-tuition')?.trim() || null;
    if (wanted && !TUITION_ID.test(wanted)) throw new HttpError(400, 'bad_tuition', 'That tuition id is not valid.');
    const row = await q1<SessionUser & { stale: boolean; t_id: string | null; t_name: string | null; t_role: Tuition['role'] | null; t_class: number | null }>(
      `select u.id, u.role, u.username, u.display_name, u.class_level,
              s.last_used_at < now() - interval '2 minutes' as stale,
              m.id as t_id, m.name as t_name, m.mrole as t_role, m.mclass as t_class
         from sessions s join users u on u.id = s.user_id
         left join lateral (select t.id, t.name, mm.role as mrole, mm.class_level as mclass
                              from memberships mm join tuitions t on t.id = mm.tuition_id
                             where mm.user_id = u.id and mm.status = 'active' and ($2::uuid is null or mm.tuition_id = $2)
                             order by mm.joined_at limit 1) m on true
        where s.token_hash = $1 and s.expires_at > now() and u.active`,
      [hash, wanted],
    );
    if (!row) throw new HttpError(401, 'signed_out', 'Please log in again.');
    if (role && row.role !== role) throw new HttpError(403, 'forbidden', FORBIDDEN[role]);
    const mode = opts.tuition ?? (role === 'teacher' || role === 'student' ? 'required' : 'none');
    const tuition: Tuition | null = row.t_id ? { id: row.t_id, name: row.t_name!, role: row.t_role!, class_level: row.t_class } : null;
    if (mode === 'required' && row.role !== 'developer') {
      if (!tuition && wanted) throw new HttpError(403, 'not_a_member', 'You are not part of that tuition.');
      if (!tuition) throw noTuition(row.role === 'teacher' ? 'teacher' : 'student');
    }
    if (row.stale) {
      // Sliding expiry and "last seen", written at most every 2 minutes per session: often enough
      // for the admin app's "active now", rarely enough to add almost nothing to the database's work.
      const ci = clientInfo(c);
      await recordInstall(row.id, ci);
      await pool.query(
        `update sessions set last_used_at = now(), expires_at = now() + make_interval(days => $2),
                install_id = coalesce($3, install_id)
          where token_hash = $1`,
        [hash, SESSION_DAYS, ci.installId],
      );
      await pool.query('update users set last_seen_at = now() where id = $1', [row.id]);
    }
    const sessionUser: SessionUser = {
      id: row.id, role: row.role, username: row.username, display_name: row.display_name,
      // A student's class is the one their tuition has them in.
      class_level: row.role === 'student' && tuition ? tuition.class_level : row.class_level,
    };
    c.set('user', sessionUser);
    c.set('tuition', tuition);
    await next();
  });

/** The tuition of a request that went through requireUser with a tuition. */
export const tuitionOf = (c: { get(key: 'tuition'): Tuition | null }): Tuition => {
  const t = c.get('tuition');
  if (!t) throw new HttpError(409, 'no_tuition', 'This needs a tuition.');
  return t;
};
