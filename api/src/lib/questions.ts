/** Options that refer to other options ("Both (a) and (b)", "None of these") must keep their printed order. */
export function mustKeepOrder(options: string[]) {
  return options.some((o) =>
    /\b(all|none|both|neither)\b\s*(of\s+)?(the\s+)?(above|these|options)\b|\bboth\s*\(?[a-d]\)?\s*and\b|\(\s*[a-d]\s*\)\s*(and|or)\s*\(\s*[a-d]\s*\)/i.test(o),
  );
}

/** How hard a question is (028_question_difficulty.sql). Every question has one: AI sets it, and it is DEFAULT_DIFFICULTY when AI cannot tell. */
export const DIFFICULTIES = ['easy', 'medium', 'hard'] as const;
export type Difficulty = (typeof DIFFICULTIES)[number];

/** The level of a question nobody could judge (AI gave none, or the tutor typed it and has not chosen). 029_question_difficulty_default.sql is the same default. */
export const DEFAULT_DIFFICULTY: Difficulty = 'medium';

/** A difficulty as the app sent it or a model guessed it: "easy", "medium" or "hard" in any case, else null. */
export function difficultyOf(v: unknown): Difficulty | null {
  const s = typeof v === 'string' ? v.trim().toLowerCase() : '';
  return (DIFFICULTIES as readonly string[]).includes(s) ? (s as Difficulty) : null;
}
