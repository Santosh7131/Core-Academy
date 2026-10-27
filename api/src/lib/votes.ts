/**
 * What one model said about one question: the options it found correct and how sure it is (0 to 1). `set` lists every option it
 * called correct (0 to 3): one is an answer, several mean the question has two right answers, none means it has no right answer
 * (or needs a figure, or is unclear). `answer` is the one option when there is exactly one, else null. `by` is the model.
 * A pick stored before models were asked for the whole list has no `set`: its `answer` is all there is.
 */
export type Pick = { answer: number | null; confidence: number; set?: number[]; by?: string };

/** One answer given with less than this much sureness is a hesitation, which counts as "could not tell", not as a vote. */
export const HESITANT = 0.8;

/** How a model read a question: one right option, none (or it could not tell), or several. */
export type Reading = 'one' | 'none' | 'several';

export function readingOf(p: Pick): Reading {
  const n = p.set ? p.set.length : p.answer == null ? 0 : 1;
  if (n > 1) return 'several';
  return n === 1 && p.confidence >= HESITANT ? 'one' : 'none';
}

/** The option a pick chose, when it read the question as having exactly one right option. */
const chose = (p: Pick): number | null => (readingOf(p) === 'one' ? (p.set ? p.set[0] : p.answer) : null);

/**
 * The family a model belongs to. Models of one family make the same mistakes, so their agreement says little: gpt-oss-120b and
 * gpt-oss-20b both put the wrong answer to a Tamil grammar question as often as one in three, and both went along with a maths question
 * whose options lacked the right value, while Gemini and gpt-oss were wrong about different questions. A model this does not know
 * is its own family, and so is a pick with no model named (one stored before models were recorded), by the slot it filled.
 */
export function familyOf(by: string | undefined, slot: string): string {
  if (!by) return `slot:${slot}`;
  if (by.startsWith('openai/')) return 'openai';
  if (by.startsWith('gemini-')) return 'google';
  if (by.startsWith('qwen/')) return 'alibaba';
  return by;
}

/** What the checks have said so far about a question: the solver, the checker, and a stronger model asked later. */
export type Votes = { solver?: Pick; checker?: Pick; tiebreak?: Pick };

export type Verdict = {
  /** The option the checks agree on, and how sure the least sure of them is. */
  mark: { answer: number; confidence: number } | null;
  /** What the card tells the tutor; null when the answer is marked and nothing needs a second look. */
  note: 'writer_differs' | 'no_option' | 'disagree' | 'unsure' | null;
  /** What each check chose, kept on a card that is left to the tutor or marked against the writer's answer. */
  picks: { writer?: number; solver?: number; checker?: number; tiebreak?: number } | null;
  /** Another model's vote could still settle it: fewer than two were heard, or two chose different options. */
  more: boolean;
  /** How many different models were heard. */
  heard: number;
};

/**
 * What the checks on one question add up to.
 *
 * Every model is asked for every option that is right, so a question with two right answers or none shows itself, and a question
 * like that is the question's fault: it is never marked. It is marked only when at least two different models were heard, from at
 * least two families, each read it as having exactly one right option, and they all chose the same one. Models that chose different
 * options are asked another (a stronger) model; with that one's vote, the option most of them chose is marked when no more than one
 * disagrees (not for a question AI wrote: a split there is left as it is); a mark needs two families behind it, unless the stronger model that was asked to settle a split took that side. Heard
 * from one family only, a question is asked again of another family, and never marked on that family's say-so.
 *
 * `writer` is the option the question's writer chose (for a question AI wrote itself): one more opinion, which can ask the tutor to
 * look at a mark but does not block it. A question AI wrote (`written`) whose writer could not say which option is right (its answer
 * is none of the options, or two of them read the same) is a faulty question however the checks voted, and is not marked.
 */
export function verdict(votes: Votes, writer: number | null, opts: { written?: boolean } = {}): Verdict {
  // A model is heard once: the same model answering for two of the slots (one stood in for the other) counts as one vote.
  const seen = new Set<string>();
  const slots = (['solver', 'checker', 'tiebreak'] as const).flatMap((slot) => {
    const pick = votes[slot];
    if (!pick) return [];
    if (pick.by) {
      if (seen.has(pick.by)) return [];
      seen.add(pick.by);
    }
    return [{ slot, pick, reading: readingOf(pick), option: chose(pick), family: familyOf(pick.by, slot) }];
  });
  const heard = slots.length;
  const ones = slots.filter((s) => s.option != null);
  const doubts = slots.filter((s) => s.option == null);
  const chosen = (): NonNullable<Verdict['picks']> => ({
    ...(writer != null ? { writer } : {}),
    ...(Object.fromEntries(ones.map((s) => [s.slot, s.option!])) as { solver?: number; checker?: number; tiebreak?: number }),
  });
  const stuck = (note: NonNullable<Verdict['note']>, more: boolean): Verdict => ({ mark: null, note, picks: chosen(), more, heard });

  if (heard < 2) return stuck('unsure', true);
  if (doubts.length) {
    if (doubts.every((s) => s.reading === 'none') && !ones.length) return stuck('no_option', false);
    return stuck(doubts.some((s) => s.reading === 'several') || new Set(ones.map((s) => s.option)).size > 1 ? 'disagree' : 'unsure', false);
  }

  const count = new Map<number, number>();
  for (const s of ones) count.set(s.option!, (count.get(s.option!) ?? 0) + 1);
  const [lead, votesFor] = [...count.entries()].sort((a, b) => b[1] - a[1])[0];
  // Two models that split on a question AI wrote say something about the question, and it is cheap to write another: only a question
  // from an uploaded paper, which is somebody's own, is worth a stronger model's time.
  if (count.size > 1 && !(heard >= 3 && votesFor >= 2 && heard - votesFor <= 1)) return stuck('disagree', heard === 2 && !opts.written);

  // Models of one family agree on faulty questions as readily as on sound ones: the option has to be backed by two families. A split
  // that the stronger model settled is the exception: it was asked to take a side, and it took one.
  const backers = ones.filter((s) => s.option === lead);
  if (new Set(backers.map((s) => s.family)).size < 2 && !(count.size > 1 && backers.some((s) => s.slot === 'tiebreak'))) {
    return count.size > 1 ? stuck('disagree', false) : stuck('unsure', true);
  }

  if (opts.written && writer == null) return stuck('unsure', false);

  const confidence = Math.min(...ones.filter((s) => s.option === lead).map((s) => s.pick.confidence));
  const writerDiffers = writer != null && writer !== lead;
  return {
    mark: { answer: lead, confidence },
    note: writerDiffers ? 'writer_differs' : null,
    picks: writerDiffers ? chosen() : null,
    more: false,
    heard,
  };
}
