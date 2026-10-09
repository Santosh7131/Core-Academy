// Sets the teacher's password on a branch, without changing the app. The password is typed into
// a hidden prompt, so it never shows on screen and never lands in shell history, chat or a file.
// Usage, in a terminal: node tools/set-teacher-password.ts --env .env.main [--username <teacher username>]
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import pg from 'pg';
import { hashSecret } from '../api/src/lib/auth.ts';

const args = process.argv.slice(2);
const arg = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
process.loadEnvFile(arg('--env') ?? '.env.local');
const branch = process.env.NEON_BRANCH ?? 'unknown';

function askHidden(question: string): Promise<string> {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    // Readline echoes each key through _writeToOutput; let the prompt through and nothing after it.
    const r = rl as unknown as { _writeToOutput: (s: string) => void; output: NodeJS.WritableStream };
    let shown = false;
    r._writeToOutput = (s) => {
      if (!shown) r.output.write(s);
      shown = true;
    };
    rl.question(question, (answer) => {
      rl.close();
      process.stdout.write('\n');
      resolve(answer);
    });
  });
}

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED ?? process.env.DATABASE_URL });
await db.connect();
try {
  const username = arg('--username')?.toLowerCase();
  const teachers = (await db.query(
    `select id, username from users where role = 'teacher' ${username ? 'and username = $1' : ''} order by created_at`,
    username ? [username] : [],
  )).rows;
  if (teachers.length !== 1) {
    throw new Error(username ? `There is no teacher login "${username}" on the ${branch} branch.` : `Found ${teachers.length} teachers on the ${branch} branch; pass --username.`);
  }
  const teacher = teachers[0];
  console.log(`Setting the password for teacher "${teacher.username}" on the ${branch} branch.`);
  if (!process.stdin.isTTY) throw new Error('Run this in a terminal: the password is typed into a hidden prompt.');

  const first = await askHidden('New password: ');
  if (first.length < 4) throw new Error('Use at least 4 characters. Nothing changed.');
  const again = await askHidden('Type it again: ');
  if (first !== again) throw new Error('The two entries did not match. Nothing changed.');

  const { hash, salt } = await hashSecret(first);
  await db.query('update users set secret_hash = $2, secret_salt = $3, failed_count = 0, locked_until = null where id = $1', [teacher.id, hash, salt]);
  console.log('Password changed. Use it the next time you log in.');

  // The generated password noted in tools/out stops working now. The new one is never written down.
  const md = `tools/out/logins.${branch}.md`;
  if (existsSync(md)) {
    const today = new Date().toISOString().slice(0, 10);
    writeFileSync(md, readFileSync(md, 'utf8').replace(/password \S+ \(change it in Settings\)/, `password set by Santosh on ${today}, not stored here`));
  }
  const json = `tools/out/sample-logins.${branch}.json`;
  if (existsSync(json)) {
    const logins = JSON.parse(readFileSync(json, 'utf8'));
    if (logins.teacher) {
      logins.teacher.password = null;
      writeFileSync(json, JSON.stringify(logins, null, 2));
    }
  }
} catch (e) {
  console.error((e as Error).message);
  process.exitCode = 1;
} finally {
  await db.end();
}
