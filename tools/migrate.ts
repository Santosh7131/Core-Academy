// Applies api/migrations/*.sql in order to the branch in the env file (default .env.local).
// Usage: node tools/migrate.ts [--env .env.local]
import { readdirSync, readFileSync } from 'node:fs';
import pg from 'pg';

const envFile = process.argv.includes('--env') ? process.argv[process.argv.indexOf('--env') + 1] : '.env.local';
process.loadEnvFile(envFile);
const url = process.env.DATABASE_URL_UNPOOLED ?? process.env.DATABASE_URL;
if (!url) throw new Error(`no DATABASE_URL in ${envFile}`);

const client = new pg.Client({ connectionString: url });
await client.connect();
try {
  await client.query(`create table if not exists schema_migrations (
    name text primary key, applied_at timestamptz not null default now())`);
  const done = new Set((await client.query('select name from schema_migrations')).rows.map((r) => r.name));
  const files = readdirSync('api/migrations').filter((f) => f.endsWith('.sql')).sort();
  let applied = 0;
  for (const f of files) {
    if (done.has(f)) continue;
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
