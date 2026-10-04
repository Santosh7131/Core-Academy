import { createSign } from 'node:crypto';
import { q } from './db.ts';

// Firebase Cloud Messaging (HTTP v1). FIREBASE_SERVICE_ACCOUNT holds the service-account key
// JSON, raw or base64. It is set on the function like the Groq keys and never sent to the app.
// PUSH_DRY_RUN=1 (local testing only) logs each notification instead of sending it.

type ServiceAccount = { project_id: string; client_email: string; private_key: string };

function account(): ServiceAccount | null {
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT?.trim();
  if (!raw) return null;
  try {
    const a = JSON.parse(raw.startsWith('{') ? raw : Buffer.from(raw, 'base64').toString('utf8'));
    return a.project_id && a.client_email && a.private_key ? a : null;
  } catch {
    return null;
  }
}

const dryRun = () => process.env.PUSH_DRY_RUN === '1';

export const pushConfigured = () => dryRun() || account() !== null;

let cached: { token: string; expires: number } | null = null;

/** A short-lived OAuth token, from a JWT signed with the service account's private key. */
async function accessToken(a: ServiceAccount): Promise<string> {
  if (cached && cached.expires > Date.now() + 60_000) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const part = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const unsigned = `${part({ alg: 'RS256', typ: 'JWT' })}.${part({
    iss: a.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  })}`;
  const signature = createSign('RSA-SHA256').update(unsigned).sign(a.private_key).toString('base64url');
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${unsigned}.${signature}` }),
  });
  if (!res.ok) throw new Error(`Firebase sign-in failed with status ${res.status}`);
  const j = (await res.json()) as { access_token: string; expires_in: number };
  cached = { token: j.access_token, expires: Date.now() + j.expires_in * 1000 };
  return j.access_token;
}

export type PushMessage = { title: string; body: string };

/**
 * Sends one notification to every phone these users are logged in on. Tokens Firebase no longer
 * knows (the app was uninstalled) are removed. Returns how many phones it reached.
 */
export async function pushToUsers(userIds: string[], msg: PushMessage): Promise<number> {
  if (!pushConfigured() || userIds.length === 0) return 0;
  const rows = await q<{ token: string }>(
    `select d.token from device_tokens d
       join sessions s on s.token_hash = d.session_hash and s.expires_at > now()
       join users u on u.id = s.user_id and u.active
      where s.user_id = any($1::uuid[])`,
    [userIds],
  );
  if (rows.length === 0) return 0;
  if (dryRun()) {
    console.log(`[push] ${rows.length} phone(s) | ${msg.title} | ${msg.body}`);
    return rows.length;
  }
  const a = account()!;
  const bearer = await accessToken(a);
  let sent = 0;
  const sendOne = async (token: string) => {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${a.project_id}/messages:send`, {
      method: 'POST',
      headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        message: { token, notification: msg, android: { priority: 'high', notification: { channel_id: 'tests' } } },
      }),
    });
    if (res.ok) {
      sent++;
      return;
    }
    const text = await res.text();
    if (res.status === 404 || /UNREGISTERED|not a valid FCM registration token/i.test(text)) {
      await q('delete from device_tokens where token = $1', [token]);
    } else {
      console.error(`push failed with status ${res.status}`);
    }
  };
  // Ten at a time: Firebase has no batch send any more, and one class is a few dozen phones.
  for (let i = 0; i < rows.length; i += 10) {
    await Promise.all(rows.slice(i, i + 10).map((r) => sendOne(r.token).catch((e) => console.error(e))));
  }
  return sent;
}
