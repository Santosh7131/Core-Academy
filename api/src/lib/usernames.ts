import { pool, type Db } from './db.ts';
import { chat, parseJson, WRITE_MODELS } from './groq.ts';
import { hasNonLatinText } from './text.ts';

/** Words in front of a name that are not part of it. */
const TITLES = new Set(['dr', 'mr', 'mrs', 'ms', 'miss', 'master', 'baby', 'shri', 'shree', 'sri', 'smt', 'kum', 'kumari', 'prof']);

/**
 * What the app suggests for a student's login: "Harini Venkatesh" becomes "harini.v", a single
 * name stays as it is. A title ("Dr.") or an initial in front ("K. Rajesh") is not the first name.
 * Letters only, at most 20 so a number fits after it.
 */
export function usernameBase(name: string): string {
  const all = name
    .toLowerCase()
    .split(/\s+/)
    .map((p) => p.replace(/[^a-z]/g, ''))
    .filter(Boolean);
  // Drop what stands in front of the first name, as long as a name is left.
  let parts = all;
  while (parts.length > 1 && (TITLES.has(parts[0]) || parts[0].length === 1)) parts = parts.slice(1);
  const base = parts.length === 0 ? 'student' : parts.length === 1 ? parts[0] : `${parts[0]}.${parts[parts.length - 1][0]}`;
  return base.slice(0, 20);
}

/**
 * The first free username for this name: the suggestion itself, or the suggestion with .2, .3, .4
 * and so on after it when it is taken. Two students called Harini Venkatesh get harini.v and
 * harini.v.2 (a bare 2 on the end would read like a version number).
 */
export async function freeUsername(name: string, db: Db = pool, skip: string[] = []): Promise<string> {
  const base = usernameBase(name);
  const rows = await db.query<{ username: string }>('select username from users where username like $1', [`${base}%`]);
  const taken = new Set([...rows.rows.map((r) => r.username), ...skip]);
  if (base.length >= 3 && !taken.has(base)) return base;
  for (let n = 2; ; n++) {
    const candidate = `${base}.${n}`;
    if (candidate.length >= 3 && !taken.has(candidate)) return candidate;
  }
}

/**
 * A student's name in English letters, for a username. A name typed in Tamil or Hindi is written the
 * way it is usually spelled in English (ஹரிணி வெங்கடேஷ் becomes Harini Venkatesh); one that is already
 * in English letters, or that AI cannot spell out, is returned as it is.
 */
export async function latinName(name: string, userId: string | null, tuitionId: string): Promise<string> {
  if (name.replace(/[^A-Za-z]/g, '').length >= 3 || !hasNonLatinText(name)) return name;
  try {
    const { content } = await chat({
      task: 'spell_name',
      userId,
      tuitionId,
      models: WRITE_MODELS,
      json: true,
      maxTokens: 200,
      temperature: 0,
      messages: [
        { role: 'system', content: 'You write Indian names in English letters.' },
        {
          role: 'user',
          content: `Write this name in English letters, the way it is usually spelled in English: ${JSON.stringify(name)}.
Reply only as JSON: {"name":"<the name in English letters>"}. Examples: "ஹரிணி வெங்கடேஷ்" is "Harini Venkatesh", "राजेश शर्मा" is "Rajesh Sharma".`,
        },
      ],
    });
    const out = String(parseJson<{ name?: unknown }>(content)?.name ?? '').trim();
    return /[A-Za-z]{2,}/.test(out) ? out.slice(0, 60) : name;
  } catch {
    return name;
  }
}
