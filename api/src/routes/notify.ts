import { parseTriggerInvocation } from '@neon/functions/triggers';
import { Hono } from 'hono';
import { requireUser, tokenHash, type AppEnv } from '../lib/auth.ts';
import { q } from '../lib/db.ts';
import { HttpError, str } from '../lib/http.ts';
import { runIfDue } from '../lib/notify.ts';
import { readBody } from './body.ts';

export const notifyRoutes = new Hono<AppEnv>();

// The app sends the phone's Firebase token after logging in, and again whenever Firebase
// replaces it. The token is tied to this login, so logging out stops the notifications.
notifyRoutes.post('/devices', requireUser(), async (c) => {
  const token = str(await readBody(c), 'token', { max: 4096 })!;
  const session = tokenHash((c.req.header('authorization') ?? '').slice(7).trim());
  await q(
    `insert into device_tokens (token, session_hash) values ($1, $2)
     on conflict (token) do update set session_hash = excluded.session_hash, last_seen_at = now()`,
    [token, session],
  );
  return c.json({ ok: true });
});

// Neon's scheduled trigger calls this every five minutes. Only Neon can send the
// x-neon-trigger-invocation-id header: its proxy drops x-neon-* headers from anyone else.
notifyRoutes.post('/cron/notify', async (c) => {
  const parsed = await parseTriggerInvocation(c.req.raw);
  if (!parsed.ok) throw new HttpError(401, 'not_a_trigger', 'Only the scheduled trigger can call this.');
  return c.json(await runIfDue());
});
