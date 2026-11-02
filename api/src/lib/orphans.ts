// Objects in storage that no file row points to. Pure, so it can be checked without a database or storage (tools/orphans-test.mjs).

/**
 * A signed upload link for a small file works for 15 minutes (uploadUrl), and a send that began just before it ran out can take a while to
 * finish, so an object is only judged once it is this old. A younger one is left alone, whether or not it has a row.
 */
export const ORPHAN_AFTER_MS = 60 * 60 * 1000;

/** The keys in `stored` that no row knows (`known`) and that were written more than `olderThanMs` before `now`. An object with no write time is left alone. */
export function orphansAmong(
  stored: { key: string; modified: Date | null }[],
  known: ReadonlySet<string>,
  now: number,
  olderThanMs = ORPHAN_AFTER_MS,
): string[] {
  return stored.filter((o) => o.modified !== null && now - o.modified.getTime() > olderThanMs && !known.has(o.key)).map((o) => o.key);
}
