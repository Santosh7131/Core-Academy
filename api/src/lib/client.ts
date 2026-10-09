import type { Context } from 'hono';
import { pool, type Db } from './db.ts';

/** What an app says about itself. Apps before 1.2.1 send none of it. */
export type ClientInfo = {
  /** Made up by the app on first launch, so a phone keeps it until the app is reinstalled. */
  installId: string | null;
  /** Which app: the main app or the developer's admin app. */
  app: 'core_academy' | 'admin';
  appVersion: string | null;
  appBuild: number | null;
  /** "samsung SM-M146B" */
  model: string | null;
  /** "Android 14 (SDK 34)" */
  os: string | null;
};

const clean = (v: string | undefined, max: number) => {
  const s = (v ?? '').replace(/[\u0000-\u001f]/g, '').trim();
  return s ? s.slice(0, max) : null;
};

/** Reads X-Install-Id, X-App ("core_academy/1.2.1+4"), X-Device and X-OS. */
export function clientInfo(c: Context): ClientInfo {
  const id = clean(c.req.header('x-install-id'), 64);
  const m = /^(core_academy|admin)\/(\d+\.\d+\.\d+)(?:\+(\d+))?$/.exec(clean(c.req.header('x-app'), 60) ?? '');
  return {
    installId: id && /^[A-Za-z0-9-]{8,64}$/.test(id) ? id : null,
    app: m?.[1] === 'admin' ? 'admin' : 'core_academy',
    appVersion: m?.[2] ?? null,
    appBuild: m?.[3] ? Number(m[3]) : null,
    model: clean(c.req.header('x-device'), 80),
    os: clean(c.req.header('x-os'), 40),
  };
}

/**
 * Whether this app can show "your marks come later". Apps before 1.4.0 would read marks that are not in
 * the reply, so they keep seeing theirs straight away until they update. A caller that does not say which
 * app it is (a script, or a build before 1.2.1) counts as old for the same reason.
 */
export function holdsResults(c: Context): boolean {
  const v = clientInfo(c).appVersion;
  if (!v) return false;
  const [major, minor] = v.split('.').map(Number);
  return major > 1 || (major === 1 && minor >= 4);
}

/** Notes that this account used this install, and what the install is running now. */
export async function recordInstall(userId: string, ci: ClientInfo, db: Db = pool) {
  if (!ci.installId) return;
  await db.query(
    `insert into app_installs (install_id, app, model, os_version, app_version, app_build)
     values ($1, $2, $3, $4, $5, $6)
     on conflict (install_id) do update set
       app = excluded.app,
       model = coalesce(excluded.model, app_installs.model),
       os_version = coalesce(excluded.os_version, app_installs.os_version),
       app_version = coalesce(excluded.app_version, app_installs.app_version),
       app_build = coalesce(excluded.app_build, app_installs.app_build),
       last_seen_at = now()`,
    [ci.installId, ci.app, ci.model, ci.os, ci.appVersion, ci.appBuild],
  );
  await db.query(
    `insert into account_devices (user_id, install_id) values ($1, $2)
     on conflict (user_id, install_id) do update set last_seen_at = now()`,
    [userId, ci.installId],
  );
}
