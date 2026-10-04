// The ready-made question library: original, exam-style MCQs written for Core Academy, chapter by
// chapter, following the CBSE/NCERT books for 2026-27. Nothing here is copied from a paper or book.
//
// Every question carries `expect`, computed independently of the options: tools/check-library.ts
// proves the marked option equals it and that no other option does. Word problems can also carry
// `verify`, a check that the stated answer satisfies the question.

export type LibraryQuestion = {
  text: string;
  options: [string, string, string, string];
  correct: 0 | 1 | 2 | 3;
  expect: number | string;
  solution: string;
  verify?: () => boolean;
};

export type LibraryChapter = { name: string; questions: LibraryQuestion[] };

export type LibraryBook = {
  classLevel: number;
  subject: string;
  /** The textbook these chapters follow, for the record. */
  book: string;
  chapters: LibraryChapter[];
};

/** LaTeX without doubled backslashes: m`$\frac{1}{2}$`. */
export const m = String.raw;

export function q(
  text: string,
  options: [string, string, string, string],
  correct: 0 | 1 | 2 | 3,
  expect: number | string,
  solution: string,
  verify?: () => boolean,
): LibraryQuestion {
  return { text, options, correct, expect, solution, verify };
}

/**
 * A fact question: the right answer is written first. There is nothing to compute, so the check
 * is the review that went into writing it; the checker still proves the options are sound.
 */
export function fact(text: string, options: [string, string, string, string], solution: string): LibraryQuestion {
  return { text, options, correct: 0, expect: options[0], solution };
}

export const gcd = (a: number, b: number): number => (b === 0 ? a : gcd(b, a % b));
export const lcm = (...xs: number[]) => xs.reduce((a, b) => (a * b) / gcd(a, b));
