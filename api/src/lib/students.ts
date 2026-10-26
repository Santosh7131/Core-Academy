import type pg from 'pg';
import { checkPin, checkUsername, hashSecret, newPin } from './auth.ts';
import { pool, q1, tx } from './db.ts';
import { HttpError } from './http.ts';
import { freeUsername, latinName, usernameBase } from './usernames.ts';

/** The login chosen for a new student, before it is made. */
export type LoginPlan = { username: string; latin: string; suggested: boolean };

/**
 * The username a new student gets. The one the app suggests from the name ("harini.v", or "harini.v.2"),
 * when it is taken, becomes the next free one, so nobody has to think of a login for a second student with the
 * same name. Any other username that is taken is refused later, so the tutor can pick another. A name typed in
 * Tamil or Hindi is spelled out in English letters first, as the suggestion was.
 */
export async function planLogin(rawUsername: unknown, displayName: string, userId: string, tuitionId: string): Promise<LoginPlan> {
  const requested = checkUsername(rawUsername);
  const latin = await latinName(displayName, userId, tuitionId);
  const base = usernameBase(latin);
  const suggested = requested.startsWith(base) && /^(\.\d+)?$/.test(requested.slice(base.length));
  let username = requested;
  if (suggested && (await q1('select 1 as x from users where username = $1', [requested]))) username = await freeUsername(latin);
  return { username, latin, suggested };
}

/** The PIN a request names, or a new one when it names none. */
export const pinOf = (b: Record<string, unknown>) =>
  b.pin === undefined || b.pin === null || b.pin === '' ? newPin() : checkPin(b.pin);

/**
 * Runs `insert` (which makes the student's rows, in one transaction) with the login hashed. When someone took the
 * suggested username between the check and the insert, the next free one is tried; a username the tutor chose
 * themselves that is taken is refused. Returns what `insert` returned and the username that was used.
 */
export async function createWithLogin<T>(
  plan: LoginPlan,
  pin: string,
  insert: (cx: pg.PoolClient, login: { username: string; hash: string; salt: string }) => Promise<T>,
): Promise<{ result: T; username: string }> {
  const { hash, salt } = await hashSecret(pin);
  let username = plan.username;
  for (let attempt = 0; ; attempt++) {
    try {
      const result = await tx((cx) => insert(cx, { username, hash, salt }));
      return { result, username };
    } catch (e: any) {
      if (e.code === '23505') {
        // Someone took it between the check and the insert: try the next free one.
        if (plan.suggested && attempt < 3) {
          username = await freeUsername(plan.latin, pool, [username]);
          continue;
        }
        throw new HttpError(409, 'username_taken', `The username ${username} is already taken.`);
      }
      throw e;
    }
  }
}
