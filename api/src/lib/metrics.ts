import { waitUntil } from '@neon/functions';
import type { Context } from 'hono';
import { routePath } from 'hono/route';
import type { AppEnv, SessionUser } from './auth.ts';
import { clientInfo } from './client.ts';
import { pool } from './db.ts';

/** The route a request matched, such as "GET /teacher/papers/:id". */
export const routeOf = (c: Context) => `${c.req.method} ${routePath(c, -1) || c.req.path}`;

const signedIn = (c: Context<AppEnv>) => c.get('user') as SessionUser | undefined;

/**
 * Counts a request for the admin app, and notes that the database is awake (to estimate compute
 * hours). Only requests that used the database anyway count: signed-in ones and logins. Anything
 * else, such as a bot trying random paths or the notification trigger every 5 minutes, must never
 * wake the database, which Neon bills by the hour it is awake. A request made for a tuition is also
 * counted against that client, in the same statement.
 */
export function countRequest(c: Context<AppEnv>, ms: number) {
  if (!signedIn(c) && !(c.req.method === 'POST' && c.req.path === '/auth/login')) return;
  const tuition = c.get('tuition')?.id ?? null;
  waitUntil(
    pool
      .query(
        `with wake as (
           insert into compute_wakes (started_at, last_seen_at) values (pg_postmaster_start_time(), now())
           on conflict (started_at) do update set last_seen_at = now()
         ), client as (
           insert into api_daily_tuition (day, tuition_id, requests, errors, total_ms)
           select (now() at time zone 'Asia/Kolkata')::date, $4::uuid, 1, $2, $3::int where $4::uuid is not null
           on conflict (day, tuition_id) do update set
             requests = api_daily_tuition.requests + 1,
             errors = api_daily_tuition.errors + excluded.errors,
             total_ms = api_daily_tuition.total_ms + excluded.total_ms
         )
         insert into api_daily (day, route, requests, errors, total_ms, max_ms)
         values ((now() at time zone 'Asia/Kolkata')::date, $1, 1, $2, $3::int, $3::int)
         on conflict (day, route) do update set
           requests = api_daily.requests + 1,
           errors = api_daily.errors + excluded.errors,
           total_ms = api_daily.total_ms + excluded.total_ms,
           max_ms = greatest(api_daily.max_ms, excluded.max_ms)`,
        [routeOf(c), c.res.status >= 500 ? 1 : 0, Math.round(ms), tuition],
      )
      .catch((e) => console.error('countRequest failed:', e)),
  );
}

/** Keeps a server error (HTTP 500) for the admin app's log. */
export function logError(c: Context<AppEnv>, err: unknown) {
  const ci = clientInfo(c);
  const message = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
  waitUntil(
    pool
      .query(
        `insert into api_errors (method, route, status, message, user_id, install_id, app_version)
         values ($1, $2, 500, $3, $4, $5, $6)`,
        [c.req.method, routePath(c, -1) || c.req.path, message.slice(0, 500), signedIn(c)?.id ?? null, ci.installId, ci.appVersion],
      )
      .catch((e) => console.error('logError failed:', e)),
  );
}
