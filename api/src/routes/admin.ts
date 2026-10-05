import { waitUntil } from '@neon/functions';
import { Hono } from 'hono';
import type { AppEnv } from '../lib/auth.ts';
import { pool, q, q1 } from '../lib/db.ts';
import { aiConfigured } from '../lib/groq.ts';
import { HttpError, notFound, uuid } from '../lib/http.ts';
import { pushConfigured } from '../lib/push.ts';
import { listObjects, readObject, viewUrl } from '../lib/storage.ts';
import { readBody } from './body.ts';

/** The developer's admin app. Read-only, apart from signing a phone out and unlocking a login. */
export const adminRoutes = new Hono<AppEnv>();

// Midnight today, India time, as a timestamptz.
const IST_TODAY = `(date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata')`;
/** An account signed in on this many phones or more is flagged. */
const MANY_PHONES = 3;
/** The compute is fixed at 0.25 CU, and the free plan allows 100 CU-hours a month. */
const CU = 0.25;
const FREE_CU_HOURS = 100;
/** Neon's branch size limit for this project (its project record, 5 Oct 2026). */
const BRANCH_LIMIT_BYTES = 1024 ** 3;

// Phones an account used in the last 30 days: known installs, plus sessions from apps before 1.2.1,
// which do not say which phone they are on (each counts as one).
const PHONES_OF = (u: string) => `(
  (select count(*) from account_devices d where d.user_id = ${u}.id and d.last_seen_at > now() - interval '30 days')
  + (select count(*) from sessions s where s.user_id = ${u}.id and s.install_id is null
       and s.expires_at > now() and s.last_used_at > now() - interval '30 days'))`;

/** Seconds the database was awake on each day this month (UTC), from its recorded starts. */
async function computeThisMonth() {
  const days = await q<{ day: string; seconds: number }>(
    `with w as (
       select started_at, last_seen_at, lead(started_at) over (order by started_at) as next_start from compute_wakes
     )
     select to_char(started_at at time zone 'UTC', 'YYYY-MM-DD') as day,
            sum(extract(epoch from least(last_seen_at + interval '5 minutes', coalesce(next_start, now()), now()) - started_at))::float as seconds
       from w
      where started_at >= date_trunc('month', now() at time zone 'UTC') at time zone 'UTC'
      group by 1 order by 1`,
  );
  const first = await q1<{ since: Date | null }>(`select min(started_at) as since from compute_wakes`);
  const seconds = days.reduce((a, d) => a + d.seconds, 0);
  const now = new Date();
  const monthStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1);
  const monthEnd = Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1);
  const since = Math.max(monthStart, first?.since?.getTime() ?? now.getTime());
  const elapsed = Math.max(1, now.getTime() - since);
  const cuHours = (seconds / 3600) * CU;
  return {
    cu_hours: Math.round(cuHours * 10) / 10,
    free_cu_hours: FREE_CU_HOURS,
    // At this rate until the month ends; a guess from less than a day of data would mislead.
    projected_cu_hours: elapsed < 24 * 3600_000 ? null : Math.round(((cuHours * (monthEnd - since)) / elapsed) * 10) / 10,
    counting_since: new Date(since).toISOString(),
    resets_at: new Date(monthEnd).toISOString(),
    days: days.map((d) => ({ day: d.day, cu_hours: Math.round((d.seconds / 3600) * CU * 100) / 100 })),
  };
}

function prune() {
  waitUntil(
    (async () => {
      await pool.query(`delete from auth_events where at < now() - interval '90 days'`);
      await pool.query(`delete from api_errors where at < now() - interval '30 days'`);
      await pool.query(`delete from api_daily where day < current_date - 90`);
      await pool.query(`delete from compute_wakes where started_at < now() - interval '120 days'`);
    })().catch(() => {}),
  );
}

adminRoutes.get('/overview', async (c) => {
  prune();
  const people = await q1(
    `select count(*) filter (where role <> 'developer') as accounts,
            count(*) filter (where role = 'student' and active) as students,
            count(*) filter (where role <> 'developer' and last_seen_at > now() - interval '5 minutes') as active_now,
            count(*) filter (where role <> 'developer' and last_seen_at >= ${IST_TODAY}) as today,
            count(*) filter (where role <> 'developer' and last_seen_at > now() - interval '7 days') as week,
            count(*) filter (where role <> 'developer' and active and (last_seen_at is null or last_seen_at <= now() - interval '7 days')) as quiet,
            count(*) filter (where role <> 'developer' and locked_until > now()) as locked
       from users`,
  );
  const phones = await q1(
    `select (select count(*) from app_installs where app = 'core_academy' and last_seen_at > now() - interval '30 days')
          + (select count(*) from sessions s join users u on u.id = s.user_id
              where s.install_id is null and u.role <> 'developer' and s.expires_at > now()
                and s.last_used_at > now() - interval '30 days') as phones,
            (select count(*) from users u where u.role <> 'developer' and ${PHONES_OF('u')} >= ${MANY_PHONES}) as many_phones`,
  );
  const versions = await q(
    `select v.version, count(*) as phones from (
       select coalesce(app_version, 'unknown') as version from app_installs
        where app = 'core_academy' and last_seen_at > now() - interval '7 days'
       union all
       select 'older' from sessions s join users u on u.id = s.user_id
        where s.install_id is null and u.role <> 'developer' and s.last_used_at > now() - interval '7 days'
     ) v group by v.version
      order by v.version in ('older', 'unknown'), case when v.version ~ '^[0-9]+([.][0-9]+)*$' then string_to_array(v.version, '.')::int[] end desc`,
  );
  const today = await q1(
    `select (select count(*) from attempts where submitted_at >= ${IST_TODAY}) as tests_written,
            (select count(*) from attempts where submitted_at is null and started_at > now() - interval '3 hours') as writing_now,
            (select count(*) from auth_events where at >= ${IST_TODAY} and outcome = 'ok') as logins,
            (select count(*) from auth_events where at >= ${IST_TODAY} and outcome in ('wrong_secret', 'lockout')) as wrong_secrets,
            (select count(*) from auth_events where at >= ${IST_TODAY} and outcome = 'lockout') as lockouts,
            (select coalesce(sum(requests), 0) from api_daily where day = (now() at time zone 'Asia/Kolkata')::date) as requests,
            (select coalesce(sum(errors), 0) from api_daily where day = (now() at time zone 'Asia/Kolkata')::date) as errors,
            (select count(*) from ai_usage where created_at >= ${IST_TODAY}) as ai_calls,
            (select count(*) from ai_usage where created_at >= ${IST_TODAY} and not ok) as ai_failed`,
  );
  // Things worth a look, newest first.
  const alerts: { kind: string; title: string; detail: string; user_id?: string; at?: string }[] = [];
  for (const r of await q(
    `select u.id, u.display_name, u.username, ${PHONES_OF('u')} as phones,
            (select i.model from account_devices d join app_installs i on i.install_id = d.install_id
              where d.user_id = u.id order by d.first_seen_at desc limit 1) as newest
       from users u where u.role <> 'developer' and ${PHONES_OF('u')} >= ${MANY_PHONES}
      order by phones desc limit 5`,
  )) {
    alerts.push({ kind: 'phones', user_id: r.id, title: `${r.display_name} is signed in on ${r.phones} phones`, detail: r.newest ? `newest: ${r.newest}` : r.username });
  }
  for (const r of await q(
    `select id, display_name, username, locked_until from users where role <> 'developer' and locked_until > now() order by locked_until desc`,
  )) {
    alerts.push({ kind: 'locked', user_id: r.id, title: `${r.display_name} is locked after 5 wrong tries`, detail: `unlocks by itself`, at: r.locked_until });
  }
  const errs = await q1(`select count(*) as n, max(at) as last from api_errors where at > now() - interval '24 hours'`);
  if (errs?.n) alerts.push({ kind: 'errors', title: `${errs.n} server error${errs.n === 1 ? '' : 's'} in the last 24 hours`, detail: 'see Server', at: errs.last });
  if (today?.ai_failed) alerts.push({ kind: 'ai', title: `${today.ai_failed} AI read${today.ai_failed === 1 ? '' : 's'} failed today`, detail: 'see Log' });

  return c.json({
    branch: process.env.NEON_BRANCH ?? null,
    server_time: new Date().toISOString(),
    services: { ai: aiConfigured(), push: pushConfigured() },
    people,
    phones: { ...phones, many_threshold: MANY_PHONES },
    versions,
    today,
    compute: await computeThisMonth(),
    alerts,
  });
});

adminRoutes.get('/people', async (c) => {
  const rows = await q(
    `select u.id, u.role, u.username, u.display_name, u.class_level, u.active, u.last_seen_at, u.created_at,
            u.locked_until > now() as locked,
            ${PHONES_OF('u')} as phones,
            (select i.app_version from account_devices d join app_installs i on i.install_id = d.install_id
              where d.user_id = u.id order by d.last_seen_at desc limit 1) as app_version,
            exists (select 1 from sessions s where s.user_id = u.id and s.install_id is null and s.expires_at > now()) as on_old_app
       from users u
      where u.role <> 'developer'
      order by u.last_seen_at desc nulls last, u.display_name`,
  );
  return c.json({ people: rows, many_threshold: MANY_PHONES });
});

adminRoutes.get('/people/:id', async (c) => {
  const id = uuid(c.req.param('id'), 'account id');
  const u = await q1(
    `select u.id, u.role, u.username, u.display_name, u.class_level, u.active, u.last_seen_at, u.created_at,
            u.locked_until, u.locked_until > now() as locked, u.failed_count,
            array(select sj.name from student_subjects ss join subjects sj on sj.id = ss.subject_id
                   where ss.student_id = u.id order by sj.sort_order, sj.name) as subjects
       from users u where u.id = $1 and u.role <> 'developer'`,
    [id],
  );
  if (!u) throw notFound('This account');
  const stats = await q1(
    `select count(*) filter (where submitted_at is not null) as tests_written,
            round(avg(100.0 * score / nullif(max_score, 0)) filter (where submitted_at is not null)) as average_pct,
            round(max(100.0 * score / nullif(max_score, 0)) filter (where submitted_at is not null)) as best_pct,
            max(submitted_at) as last_submitted_at
       from attempts where student_id = $1`,
    [id],
  );
  const phones = await q(
    `select i.install_id, i.model, i.os_version, i.app_version, i.app_build, d.first_seen_at, d.last_seen_at,
            exists (select 1 from sessions s where s.user_id = d.user_id and s.install_id = d.install_id and s.expires_at > now()) as signed_in,
            (select count(*) from account_devices o join users ou on ou.id = o.user_id and ou.role <> 'developer'
              where o.install_id = d.install_id and o.user_id <> d.user_id) as other_accounts
       from account_devices d join app_installs i on i.install_id = d.install_id
      where d.user_id = $1 order by d.last_seen_at desc`,
    [id],
  );
  // Sessions from apps before 1.2.1: no phone details, but each is a phone that is signed in.
  const oldSessions = await q(
    `select left(token_hash, 12) as session, created_at, last_used_at from sessions
      where user_id = $1 and install_id is null and expires_at > now() order by last_used_at desc`,
    [id],
  );
  const logins = await q(
    `select e.at, e.outcome, e.app_version, i.model
       from auth_events e left join app_installs i on i.install_id = e.install_id
      where e.user_id = $1 order by e.at desc limit 30`,
    [id],
  );
  const tests = await q(
    `select a.id, t.title, a.score, a.max_score, a.submitted_at, a.auto_submitted, a.attempt_no
       from attempts a join tests t on t.id = a.test_id
      where a.student_id = $1 and a.submitted_at is not null order by a.submitted_at desc limit 10`,
    [id],
  );
  return c.json({ account: u, stats, phones, old_sessions: oldSessions, logins, tests });
});

/** Signs an account out of one phone: a known install, or an old app's session by its short id. */
adminRoutes.post('/people/:id/sign-out', async (c) => {
  const id = uuid(c.req.param('id'), 'account id');
  const b = await readBody(c);
  const install = typeof b.install_id === 'string' ? b.install_id : null;
  const session = typeof b.session === 'string' && /^[0-9a-f]{12}$/.test(b.session) ? b.session : null;
  if (!install && !session) throw new HttpError(400, 'bad_request', 'Say which phone to sign out.');
  const r = install
    ? await pool.query('delete from sessions where user_id = $1 and install_id = $2', [id, install])
    : await pool.query('delete from sessions where user_id = $1 and install_id is null and left(token_hash, 12) = $2', [id, session]);
  return c.json({ signed_out: r.rowCount ?? 0 });
});

adminRoutes.post('/people/:id/unlock', async (c) => {
  const id = uuid(c.req.param('id'), 'account id');
  const r = await q1(
    `update users set failed_count = 0, locked_until = null where id = $1 and role <> 'developer' returning id`,
    [id],
  );
  if (!r) throw notFound('This account');
  return c.json({ ok: true });
});

adminRoutes.get('/phones', async (c) => {
  const phones = await q(
    `select i.install_id, i.app, i.model, i.os_version, i.app_version, i.app_build, i.first_seen_at, i.last_seen_at,
            coalesce(json_agg(json_build_object(
              'id', u.id, 'display_name', u.display_name, 'username', u.username, 'role', u.role,
              'signed_in', exists (select 1 from sessions s where s.user_id = u.id and s.install_id = i.install_id and s.expires_at > now())
            ) order by d.last_seen_at desc) filter (where u.id is not null), '[]') as accounts
       from app_installs i
       left join account_devices d on d.install_id = i.install_id
       -- The developer trying a login on a student's phone does not make it a shared phone.
       left join users u on u.id = d.user_id and (u.role <> 'developer' or i.app = 'admin')
      group by i.install_id
      order by i.last_seen_at desc`,
  );
  const old = await q(
    `select u.id, u.display_name, u.username, u.role, count(*) as sessions, max(s.last_used_at) as last_used_at
       from sessions s join users u on u.id = s.user_id
      where s.install_id is null and s.expires_at > now() and u.role <> 'developer'
      group by u.id order by last_used_at desc`,
  );
  return c.json({ phones, old_app_sessions: old });
});

adminRoutes.get('/server', async (c) => {
  const db = await q1(`select pg_database_size(current_database()) as bytes, current_setting('server_version') as version`);
  const tables = await q(
    `select c.relname as name, pg_total_relation_size(c.oid) as bytes, greatest(c.reltuples, 0)::bigint as rows
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
      order by bytes desc limit 10`,
  );
  // Storage, grouped by the first part of each key (pages of uploaded papers, question images, ...).
  const objects = await listObjects();
  const byPrefix = new Map<string, { files: number; bytes: number }>();
  for (const o of objects) {
    const top = o.key.includes('/') ? o.key.slice(0, o.key.indexOf('/')) : '(top level)';
    const g = byPrefix.get(top) ?? { files: 0, bytes: 0 };
    g.files += 1;
    g.bytes += o.size;
    byPrefix.set(top, g);
  }
  const days = await q(
    `select to_char(day, 'YYYY-MM-DD') as day, sum(requests) as requests, sum(errors) as errors
       from api_daily where day > current_date - 14 group by day order by day`,
  );
  const routes = await q(
    `select route, sum(requests) as requests, sum(errors) as errors,
            round(sum(total_ms)::numeric / nullif(sum(requests), 0)) as avg_ms, max(max_ms) as max_ms
       from api_daily where day > current_date - 7 group by route order by avg_ms desc nulls last limit 8`,
  );
  const errors = await q(`select at, method, route, status, message, app_version from api_errors order by at desc limit 20`);
  const ai = await q1(
    `select count(*) filter (where created_at >= ${IST_TODAY}) as today,
            count(*) filter (where created_at >= ${IST_TODAY} and not ok) as failed_today,
            count(*) filter (where created_at > now() - interval '7 days') as week,
            count(*) filter (where created_at > now() - interval '7 days' and not ok) as failed_week,
            round(avg(ms) filter (where ok and created_at > now() - interval '7 days')) as avg_ms,
            coalesce(sum(coalesce(prompt_tokens, 0) + coalesce(completion_tokens, 0)) filter (where created_at > now() - interval '7 days'), 0) as tokens_week
       from ai_usage`,
  );
  const push = await q1(`select count(*) as tokens from device_tokens`);
  return c.json({
    branch: process.env.NEON_BRANCH ?? null,
    database: { bytes: db?.bytes ?? 0, limit_bytes: BRANCH_LIMIT_BYTES, version: db?.version ?? null, tables },
    storage: {
      files: objects.length,
      bytes: objects.reduce((a, o) => a + o.size, 0),
      groups: [...byPrefix.entries()].map(([name, g]) => ({ name, ...g })).sort((a, b) => b.bytes - a.bytes),
    },
    compute: await computeThisMonth(),
    api: { days, routes, errors },
    ai: { configured: aiConfigured(), ...ai },
    push: { configured: pushConfigured(), tokens: push?.tokens ?? 0 },
  });
});

/** Recent happenings across the app, newest first: logins, tests, papers, AI reads and errors. */
adminRoutes.get('/log', async (c) => {
  const before = c.req.query('before');
  const until = before && !Number.isNaN(Date.parse(before)) ? new Date(before) : new Date(Date.now() + 60_000);
  const rows = await q(
    `select * from (
       select e.at, 'login' as kind, e.outcome as what, coalesce(u.display_name, e.username) as who, u.id as user_id,
              i.model as detail,
              case when e.app_version is null then null when i.app = 'admin' then 'Admin app ' || e.app_version
                   else 'app ' || e.app_version end as extra
         from auth_events e left join users u on u.id = e.user_id left join app_installs i on i.install_id = e.install_id
        where e.at < $1
       union all
       select a.submitted_at, 'test', case when a.auto_submitted then 'auto' else 'submitted' end, u.display_name, u.id,
              t.title, (trim_scale(a.score)::text || '/' || trim_scale(a.max_score)::text)
         from attempts a join users u on u.id = a.student_id join tests t on t.id = a.test_id
        where a.submitted_at is not null and a.submitted_at < $1
       union all
       select p.created_at, 'paper', 'uploaded', coalesce(u.display_name, 'teacher'), u.id, p.exam_name,
              (p.page_count::text || case when p.page_count = 1 then ' page' else ' pages' end)
         from papers p left join users u on u.id = p.uploaded_by
        where p.created_at < $1
       union all
       select x.created_at, 'ai', case when x.ok then 'ok' else 'failed' end, x.task, x.user_id, left(coalesce(x.error, ''), 160), (x.ms::text || ' ms')
         from ai_usage x where x.created_at < $1
       union all
       select r.at, 'error', r.status::text, r.method || ' ' || r.route, r.user_id, left(coalesce(r.message, ''), 160), r.app_version
         from api_errors r where r.at < $1
     ) ev order by at desc limit 80`,
    [until],
  );
  return c.json({ events: rows });
});

/** The admin app's own update: kept in private storage, so only this login can fetch it. */
adminRoutes.get('/app', async (c) => {
  let feed: Record<string, unknown>;
  try {
    feed = JSON.parse((await readObject('admin/update.json')).bytes.toString('utf8'));
  } catch {
    return c.json({ update: null });
  }
  const key = typeof feed.key === 'string' ? feed.key : null;
  if (!key) return c.json({ update: null });
  return c.json({ update: { ...feed, apk: await viewUrl(key, 1800) } });
});
