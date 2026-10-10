// Applies api/migrations/*.sql in order to the branch in the env file (default .env.local).
// Usage: node tools/migrate.ts [--env .env.local] [--up-to 017]
// --up-to stops after that migration (a number such as 017, or a file name). A migration that removes
// something the running API still uses waits until the new API is deployed (see "Going live" in the README).
import { readdirSync, readFileSync } from 'node:fs';
import pg from 'pg';

const envFile = process.argv.includes('--env') ? process.argv[process.argv.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
const url = process.env.DATABASE_URL_UNPOOLED ?? process.env.DATABASE_URL;
if (!url) throw new Error(`no DATABASE_URL in ${envFile}`);

const upTo = process.argv.includes('--up-to') ? process.argv[process.argv.indexOf('--up-to') + 1] : null;

const client = new pg.Client({ connectionString: url });
await client.connect();
try {
  await client.query(`create table if not exists schema_migrations (
    name text primary key, applied_at timestamptz not null default now())`);
  const done = new Set((await client.query('select name from schema_migrations')).rows.map((r) => r.name));
  const files = readdirSync('api/migrations').filter((f) => f.endsWith('.sql')).sort();
  if (upTo && !files.some((f) => f.startsWith(upTo))) throw new Error(`--up-to ${upTo}: no such migration`);
  let applied = 0;
  for (const f of files) {
    if (done.has(f)) continue;
    // Anything after the named migration waits.
    if (upTo && f.slice(0, upTo.length) > upTo.slice(0, f.length > upTo.length ? upTo.length : f.length) && !f.startsWith(upTo)) break;
    const sql = readFileSync(`api/migrations/${f}`, 'utf8');
    await client.query('begin');
    try {
      await client.query(sql);
      await client.query('insert into schema_migrations (name) values ($1)', [f]);
      await client.query('commit');
      console.log(`applied ${f}`);
      applied++;
    } catch (e) {
      await client.query('rollback');
      throw new Error(`${f}: ${(e as Error).message}`);
    }
  }
  console.log(`branch ${process.env.NEON_BRANCH ?? '?'}: ${applied} applied, ${files.length - applied} already up to date`);
} finally {
  await client.end();
}
