import { pool, tq, tq1, type Db } from './db.ts';
import { bad, HttpError, int } from './http.ts';

// A class is stored as a number. 1 to 12 are Class 1 to Class 12. A level a tuition names itself
// (LKG, "NEET 2027", "B.Com year 1") is 101 or more, with its name in tuition_levels
// (013_levels.sql), so the same columns, groups and checks serve both.
export const CLASS_MIN = 1;
export const CLASS_MAX = 12;
export const CUSTOM_MIN = 101;
export const CUSTOM_MAX = 999;
export const MAX_CUSTOM_LEVELS = 20;

export type Level = { code: number; label: string; custom: boolean };

/**
 * SQL for a query that joins tuitions as t: the levels the tuition named itself, as [{code, label}], so
 * an app can show them. Class 1 to 12 need no list.
 */
export const LEVELS_JSON = `coalesce((select json_agg(json_build_object('code', l.code, 'label', l.label) order by l.code)
                                       from tuition_levels l where l.tuition_id = t.id), '[]'::json) as levels`;

export const isClassNumber = (n: number) => Number.isInteger(n) && n >= CLASS_MIN && n <= CLASS_MAX;

export const standardLevels = (): Level[] =>
  Array.from({ length: CLASS_MAX }, (_, i) => ({ code: i + 1, label: `Class ${i + 1}`, custom: false }));

/** The levels a tuition named itself, oldest first. */
export const customLevels = (tuition: string, db: Db = pool) =>
  tq<{ code: number; label: string }>(tuition, 'select code, label from tuition_levels where tuition_id = @T order by code', [], db);

/** Every level the tuition can use: Class 1 to 12, then the ones it named. */
export async function levelsOf(tuition: string, db: Db = pool): Promise<Level[]> {
  return [...standardLevels(), ...(await customLevels(tuition, db)).map((l) => ({ ...l, custom: true }))];
}

/** True when the tuition has this level: Class 1 to 12, or one it named. */
export async function hasLevel(tuition: string, code: number, db: Db = pool): Promise<boolean> {
  if (isClassNumber(code)) return true;
  if (!Number.isInteger(code) || code < CUSTOM_MIN || code > CUSTOM_MAX) return false;
  return !!(await tq1(tuition, 'select 1 as x from tuition_levels where tuition_id = @T and code = $1', [code], db));
}

/** The level must be one of the tuition's: a number nobody named is refused. */
export async function assertLevel(tuition: string, code: number, db: Db = pool): Promise<number> {
  if (!(await hasLevel(tuition, code, db))) throw bad('That class is not one this tuition has.', 'unknown_level');
  return code;
}

/** A class sent in a request body: a whole number that is one of the tuition's levels. */
export async function levelIn(
  b: Record<string, unknown>,
  key: string,
  tuition: string,
  opts: { optional?: boolean } = {},
  db: Db = pool,
): Promise<number | undefined> {
  const code = int(b, key, { min: CLASS_MIN, max: CUSTOM_MAX, optional: opts.optional });
  return code === undefined ? undefined : assertLevel(tuition, code, db);
}

/** A class in a URL path. */
export async function levelParam(raw: unknown, tuition: string, db: Db = pool): Promise<number> {
  const n = Number(raw);
  if (!Number.isInteger(n) || n < CLASS_MIN || n > CUSTOM_MAX) throw bad('Choose a class.', 'unknown_level');
  return assertLevel(tuition, n, db);
}

/** What the tuition calls a level, for the words an AI model reads: "Class 9" or the name it gave. */
export async function levelLabel(tuition: string, code: number, db: Db = pool): Promise<string> {
  if (isClassNumber(code)) return `Class ${code}`;
  const l = await tq1<{ label: string }>(tuition, 'select label from tuition_levels where tuition_id = @T and code = $1', [code], db);
  return l?.label ?? `Level ${code}`;
}

/**
 * How a level is named to an AI model: "Class 9 CBSE" for a class (the apps began as CBSE tuition),
 * and just the tuition's own name for a level it named ("NEET 2027"), which may be any syllabus.
 */
export async function studyOf(tuition: string, code: number, db: Db = pool): Promise<string> {
  const label = await levelLabel(tuition, code, db);
  return isClassNumber(code) ? `${label} CBSE` : label;
}

/** A name for a level, as typed: trimmed, one space between words, 1 to 30 characters, and not Class 1 to 12 again. */
export function cleanLabel(raw: unknown): string {
  const s = typeof raw === 'string' ? raw.trim().replace(/\s+/g, ' ') : '';
  if (!s) throw bad('Give the class a name.', 'invalid_level');
  if (s.length > 30) throw bad('Keep the name to 30 characters.', 'invalid_level');
  const m = /^(class|std|standard|grade)\.?\s*(\d{1,2})(st|nd|rd|th)?$/i.exec(s);
  if (m && isClassNumber(Number(m[2]))) throw bad(`Class ${Number(m[2])} is already in the list.`, 'level_exists');
  return s;
}

/**
 * Names a new level for the tuition and returns it. A name the tuition already has gives that level
 * back, so asking twice is safe. A tuition can name up to MAX_CUSTOM_LEVELS.
 */
export async function addLevel(tuition: string, rawLabel: unknown, db: Db = pool): Promise<Level> {
  const label = cleanLabel(rawLabel);
  for (let attempt = 0; ; attempt++) {
    const have = await customLevels(tuition, db);
    const same = have.find((l) => l.label.toLowerCase() === label.toLowerCase());
    if (same) return { ...same, custom: true };
    if (have.length >= MAX_CUSTOM_LEVELS) {
      throw new HttpError(409, 'too_many_levels', `A tuition can name up to ${MAX_CUSTOM_LEVELS} classes of its own.`);
    }
    const code = Math.max(CUSTOM_MIN - 1, ...have.map((l) => l.code)) + 1;
    if (code > CUSTOM_MAX) throw new HttpError(409, 'too_many_levels', 'This tuition has used up its class numbers.');
    try {
      const row = await tq1<{ code: number; label: string }>(
        tuition,
        'insert into tuition_levels (tuition_id, code, label) values (@T, $1, $2) returning code, label',
        [code, label],
        db,
      );
      return { ...row!, custom: true };
    } catch (e: any) {
      // Two tutors named levels at once and took the same number: look again.
      if (e.code === '23505' && attempt < 3) continue;
      throw e;
    }
  }
}

/** True when anything of the tuition still uses this level: students, groups, tests, papers, questions or chapters. */
export async function levelInUse(tuition: string, code: number, db: Db = pool): Promise<boolean> {
  const r = await tq1<{ n: number }>(
    tuition,
    `select (select count(*) from memberships where tuition_id = @T and class_level = $1)
          + (select count(*) from groups      where tuition_id = @T and class_level = $1)
          + (select count(*) from tests       where tuition_id = @T and class_level = $1)
          + (select count(*) from papers      where tuition_id = @T and class_level = $1)
          + (select count(*) from questions   where tuition_id = @T and class_level = $1)
          + (select count(*) from chapters    where tuition_id = @T and class_level = $1) as n`,
    [code],
    db,
  );
  return Number(r?.n ?? 0) > 0;
}
