// All ready-made question books, and the order their options are stored in.
import { createHash } from 'node:crypto';
import { book as c7Maths } from './c7-maths.ts';
import { book as c8Maths } from './c8-maths.ts';
import { book as c9Maths } from './c9-maths.ts';
import { book as c9Science } from './c9-science.ts';
import { book as c10Maths } from './c10-maths.ts';
import { book as c10Science } from './c10-science.ts';
import type { LibraryBook, LibraryQuestion } from './types.ts';

export const books: LibraryBook[] = [c7Maths, c8Maths, c9Maths, c9Science, c10Maths, c10Science];

/**
 * The questions are written with the right answer first. Before they are stored, each one's
 * options get a fixed shuffle seeded by its text, so answers are spread over A to D even when
 * a test uses the same order for every student, and a reseed gives the same order again.
 */
export function arrange(question: LibraryQuestion): { options: string[]; correct: number } {
  const order = [0, 1, 2, 3];
  const seed = createHash('sha256').update(question.text).digest();
  // Fisher-Yates, one fresh byte of the hash per step.
  for (let i = order.length - 1, k = 0; i > 0; i--, k++) {
    const j = seed[k] % (i + 1);
    [order[i], order[j]] = [order[j], order[i]];
  }
  return { options: order.map((k) => question.options[k]), correct: order.indexOf(question.correct) };
}
