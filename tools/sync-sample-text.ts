// Copies wording changes in tools/sample-data.ts onto the already-seeded sample questions,
// matched by class and question text, without re-seeding (logins and results stay as they are).
// Usage: node tools/sync-sample-text.ts [--env .env.local]
import pg from 'pg';
import { questions } from './sample-data.ts';

const args = process.argv.slice(2);
process.loadEnvFile(args.includes('--env') ? args[args.indexOf('--env') + 1] : '.env.local');
const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED });
await db.connect();
let changed = 0;
for (const [cls, list] of Object.entries(questions)) {
  for (const qq of list) {
    const r = await db.query(
      `update questions set options = $3, solution = $4, correct_option = $5, updated_at = now()
        where is_sample and class_level = $1 and text = $2
          and (options <> $3 or solution is distinct from $4 or correct_option <> $5)`,
      [cls, qq.text, qq.options, qq.solution, qq.correct],
    );
    changed += r.rowCount ?? 0;
  }
}
await db.end();
console.log(`branch ${process.env.NEON_BRANCH}: ${changed} sample question${changed === 1 ? '' : 's'} updated`);
