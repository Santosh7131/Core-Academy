// Creates the developer's login for the admin app, or gives an existing one a new password (and
// signs it out everywhere). The password is typed into a hidden prompt, so it never shows on
// screen and never lands in shell history, chat or a file.
//   node tools/create-developer.ts --env .env.main --username <name>
// On dev only, --generate makes up a password instead and keeps it in
// tools/out/sample-logins.dev.json (git-ignored), for the admin app checks.
import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import pg from 'pg';
import { hashSecret } from '../api/src/lib/auth.ts';

const args = process.argv.slice(2);
const arg = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
process.loadEnvFile(arg('--env') ?? '.env.local');
const branch = process.env.NEON_BRANCH ?? 'unknown';
const username = (arg('--username') ?? 'developer').trim().toLowerCase();
if (!/^[a-z0-9._]{3,24}$/.test(username)) throw new Error('Usernames use 3-24 lowercase letters, numbers, dots or underscores.');
const generate = args.includes('--generate');
if (generate && branch !== 'dev') throw new Error('--generate is for the dev branch only. Type a password instead.');

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

let password: string;
if (generate) {
  password = randomBytes(12).toString('base64url');
} else {
  password = await askHidden(`New password for "${username}" on ${branch} (12 or more characters): `);
  if (password.length < 12) throw new Error('Use 12 or more characters. Nothing changed.');
  if ((await askHidden('Type it again: ')) !== password) throw new Error('The two did not match. Nothing changed.');
}

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED ?? process.env.DATABASE_URL });
await db.connect();
try {
  const existing = (await db.query('select id, role from users where username = $1', [username])).rows[0];
  if (existing && existing.role !== 'developer') throw new Error(`"${username}" is a ${existing.role} login on ${branch}. Pick another username.`);
  const { hash, salt } = await hashSecret(password);
  if (existing) {
    await db.query('begin');
    await db.query('update users set secret_hash = $2, secret_salt = $3, failed_count = 0, locked_until = null where id = $1', [existing.id, hash, salt]);
    await db.query('delete from sessions where user_id = $1', [existing.id]);
    await db.query('commit');
    console.log(`New password set for the developer login "${username}" on ${branch}; it is signed out everywhere.`);
  } else {
    await db.query(
      `insert into users (role, username, display_name, secret_hash, secret_salt) values ('developer', $1, 'Developer', $2, $3)`,
      [username, hash, salt],
    );
    console.log(`Developer login "${username}" created on ${branch}.`);
  }
  if (generate) {
    const file = `tools/out/sample-logins.${branch}.json`;
    const logins = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {};
    logins.developer = { username, password };
    writeFileSync(file, JSON.stringify(logins, null, 2));
    console.log(`Its password is in ${file} (git-ignored).`);
  }
} catch (e) {
  await db.query('rollback').catch(() => {});
  throw e;
} finally {
  await db.end();
}
