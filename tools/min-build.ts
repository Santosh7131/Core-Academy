// Shows, sets or clears the oldest build of the main app that the server still serves (app_settings.min_app_build).
// An app below it gets 426 update_required on every call but signing out, and shows the "Please update" page;
// the admin app and a caller that names no build are never held to it. It is off until the row exists.
//   node tools/min-build.ts [--env .env.local] status [build]    what is set, and how many phones a build would turn away
//   node tools/min-build.ts [--env .env.local] set <build> --yes
//   node tools/min-build.ts [--env .env.local] clear --yes
// On main (--env .env.main) set and clear decide what real students can open: that needs Santosh's go-ahead first,
// after the release is out and the in-app update has been seen to work. Without --yes nothing is written.
import pg from 'pg';

const args = process.argv.slice(2);
const envFile = args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local';
const words = args.filter((a, i) => !a.startsWith('--') && args[i - 1] !== '--env');
const [cmd = 'status', value] = words;
process.loadEnvFile(envFile);
const branch = process.env.NEON_BRANCH ?? 'unknown';
const yes = args.includes('--yes');

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();

async function current(): Promise<number | null> {
  const r = await db.query(`select case when jsonb_typeof(value) = 'number' then (value #>> '{}')::int end as n from app_settings where key = 'min_app_build'`);
  return r.rows[0]?.n ?? null;
}

/** Phones of the main app seen in the last 30 days, by build. A phone that sent no build is never held to the minimum. */
async function phones() {
  return (await db.query(
    `select app_build, count(*)::int as phones, max(app_version) as version
       from app_installs where app = 'core_academy' and last_seen_at > now() - interval '30 days'
      group by app_build order by app_build nulls first`,
  )).rows as { app_build: number | null; phones: number; version: string | null }[];
}

try {
  console.log(`Database branch: ${branch}`);
  const now = await current();
  if (cmd === 'status') {
    console.log(now === null ? 'Minimum build: not set (every build is served)' : `Minimum build: ${now}`);
    const rows = await phones();
    console.log('Main-app phones seen in the last 30 days, by build:');
    for (const r of rows) console.log(`  ${r.app_build ?? 'no build sent'}${r.version ? ` (${r.version})` : ''}: ${r.phones}`);
    const target = value === undefined ? now : Number(value);
    if (target !== null && Number.isInteger(target)) {
      const turned = rows.filter((r) => r.app_build !== null && r.app_build < target).reduce((s, r) => s + r.phones, 0);
      const all = rows.reduce((s, r) => s + r.phones, 0);
      console.log(`A minimum of ${target} would turn away ${turned} of ${all} phones until they update.`);
    }
  } else if (cmd === 'set') {
    const n = Number(value);
    if (!Number.isInteger(n) || n < 1) throw new Error('Give the build number to set, for example: set 8 --yes');
    if (!yes) throw new Error(`Not written. Add --yes to set the minimum build to ${n} on ${branch}.`);
    await db.query(`insert into app_settings (key, value) values ('min_app_build', to_jsonb($1::int)) on conflict (key) do update set value = excluded.value`, [n]);
    console.log(`Minimum build set to ${n} on ${branch}.`);
  } else if (cmd === 'clear') {
    if (!yes) throw new Error(`Not written. Add --yes to clear the minimum build on ${branch}.`);
    await db.query(`delete from app_settings where key = 'min_app_build'`);
    console.log(`Minimum build cleared on ${branch} (every build is served).`);
  } else {
    throw new Error('Commands: status [build] | set <build> --yes | clear --yes');
  }
} catch (e) {
  console.error((e as Error).message);
  process.exitCode = 1;
} finally {
  await db.end();
}
