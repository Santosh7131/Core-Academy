import { pool, type Db } from './db.ts';

/**
 * What the app suggests for a student's login: "Harini Venkatesh" becomes "harini.v", a single
 * name stays as it is. Letters only, at most 20 so a number fits after it.
 */
export function usernameBase(name: string): string {
  const parts = name
    .toLowerCase()
    .replace(/[^a-z\s]/g, '')
    .trim()
    .split(/\s+/)
    .filter(Boolean);
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
