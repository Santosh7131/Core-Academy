/** What one model said about one question: the option it chose (0 to 3, or null when it found none) and how sure it is (0 to 1). */
export type Pick = { answer: number | null; confidence: number };

/** AI marks an answer when two models pick it and each is at least this sure. */
export const SURE = 0.9;

/** When a third model was needed to settle a question, two of the three must agree and each be at least this sure. */
export const SURE_TIEBREAK = 0.85;

/** The option that at least two of the votes chose, each at least [min] sure; how sure is the least sure of them. */
export function agreed(votes: (Pick | undefined)[], min: number): { answer: number; confidence: number } | null {
  const by = new Map<number, number[]>();
  for (const v of votes) if (v && v.answer != null && v.confidence >= min) by.set(v.answer, [...(by.get(v.answer) ?? []), v.confidence]);
  for (const [answer, cs] of by) if (cs.length >= 2) return { answer, confidence: Math.min(...cs) };
  return null;
}

export type Verdict = {
  /** The option the checks agree on, and how sure the least sure of those that chose it is. */
  mark: { answer: number; confidence: number } | null;
  /** What the card tells the tutor; null when the answer is marked and nothing needs a second look. */
  note: 'writer_differs' | 'no_option' | 'disagree' | 'unsure' | null;
  /** What each check chose, kept on a card that is left to the tutor or marked against the writer's answer. */
  picks: { writer?: number; solver?: number; checker?: number; tiebreak?: number } | null;
};

/**
 * What the checks on one question add up to. [x] and [y] are the first two models, [t] the stronger one
 * asked when those could not settle it, and [writer] the option the question's writer chose (for a
 * question AI wrote itself, where the writer's answer is one more opinion that can only ask for a look).
 *
 * The first two settle it on their own at [SURE]. The lower bar of [SURE_TIEBREAK] is for when a third
 * model has actually chosen an option: a third that could not tell does not lower it.
 */
export function verdict(x: Pick | undefined, y: Pick | undefined, t: Pick | undefined, writer: number | null): Verdict {
  const mark = agreed([x, y], SURE) ?? (t?.answer != null ? agreed([x, y, t], SURE_TIEBREAK) : null);
  const writerDiffers = mark != null && writer != null && writer !== mark.answer;
  // Neither of the first two found an option that fits: most often a misprint.
  const none = !mark && x != null && y != null && x.answer == null && y.answer == null;
  const chose = [x, y, t].filter((v): v is Pick => v != null && v.answer != null);
  // Models gave answers and they differ: the tutor decides.
  const differ = !mark && new Set(chose.map((v) => v.answer)).size > 1;
  return {
    mark,
    note: writerDiffers ? 'writer_differs' : mark ? null : none ? 'no_option' : differ ? 'disagree' : 'unsure',
    picks:
      !mark || writerDiffers
        ? {
            ...(writer != null ? { writer } : {}),
            ...(x?.answer != null ? { solver: x.answer } : {}),
            ...(y?.answer != null ? { checker: y.answer } : {}),
            ...(t?.answer != null ? { tiebreak: t.answer } : {}),
          }
        : null,
  };
}
