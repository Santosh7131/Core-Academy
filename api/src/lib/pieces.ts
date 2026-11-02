// Where a question and its figure sit on a page of a paper, and how a question that ran over the page edge is put back together.
// Pure functions with no database, so tools/pieces-test.mjs can check them.

/** [x1, y1, x2, y2] as fractions of the page picture: 0,0 is its top left corner and 1,1 its bottom right. */
export type Box = [number, number, number, number];

/** A box and the page it is on. */
export type Placed = { page: number; box: Box };

const round = (v: number) => Math.round(v * 10000) / 10000;

/**
 * A box the way a model wrote it, made into one the app can cut a picture with, or null when it cannot be trusted.
 * Models differ: some wrap the four numbers in one more list, some answer 0 to 1000 instead of 0 to 1, and a
 * model that mixes up the corners gives the right edge first. A box too small to hold anything is no box.
 */
export function cleanBox(raw: unknown): Box | null {
  let b: unknown = raw;
  while (Array.isArray(b) && b.length === 1 && Array.isArray(b[0])) b = b[0];
  if (!Array.isArray(b) || b.length !== 4 || b.some((v) => typeof v !== 'number' || !Number.isFinite(v))) return null;
  const nums = b as number[];
  const scale = nums.some((v) => v > 1.5) ? 1000 : 1;
  const edge = (v: number) => Math.min(Math.max(v / scale, 0), 1);
  let [x1, y1, x2, y2] = nums.map(edge);
  if (x1 > x2) [x1, x2] = [x2, x1];
  if (y1 > y2) [y1, y2] = [y2, y1];
  if (x2 - x1 < 0.03 || y2 - y1 < 0.02) return null;
  return [round(x1), round(y1), round(x2), round(y2)];
}

/** A box on a page, or null when the box is not usable. */
export const placed = (page: number, raw: unknown): Placed | null => {
  const box = cleanBox(raw);
  return box ? { page, box } : null;
};

/** A stored or sent {page, box}, or null when it is not one. */
export function cleanPlaced(raw: unknown): Placed | null {
  if (!raw || typeof raw !== 'object') return null;
  const { page, box } = raw as { page?: unknown; box?: unknown };
  if (typeof page !== 'number' || !Number.isInteger(page) || page < 1 || page > 99) return null;
  return placed(page, box);
}

/** A stored list of {page, box}, each one checked. */
export function cleanPlacedList(raw: unknown): Placed[] | null {
  if (!Array.isArray(raw)) return null;
  const list = raw.map(cleanPlaced).filter((p): p is Placed => p != null);
  return list.length ? list : null;
}

/** The parts of a draft that joining two of them changes. */
export type Part = {
  number_label: string | null;
  kind: 'mcq' | 'other';
  text: string;
  options: string[];
  needs_diagram: boolean;
  /** AI could not read some of it, or did not find the rest of it. */
  unclear: boolean;
  question_boxes: Placed[] | null;
  figure_box: Placed | null;
  /** The question goes on over the page edge. */
  cont_next: boolean;
  /** The question is the rest of one from the page before. */
  cont_prev: boolean;
};

/**
 * `first` is a question cut by the bottom of its page and `rest` is what the next page printed of it: the end of its
 * words, its last options, or both. Together they are one question. Null when they cannot be one (more than four
 * options between them), and the two stay as they are for the tutor to look at.
 */
export function joinParts(first: Part, rest: Part): Part | null {
  const options = [...first.options, ...rest.options];
  if (options.length > 4) return null;
  const text = [first.text, rest.text].map((s) => s.trim()).filter(Boolean).join(' ');
  if (!text) return null;
  const whole = options.length === 4;
  return {
    number_label: first.number_label || rest.number_label,
    kind: whole ? 'mcq' : 'other',
    text,
    options,
    needs_diagram: first.needs_diagram || rest.needs_diagram,
    // Options that still do not add up to four mean something was lost between the pages.
    unclear: first.unclear || rest.unclear || (options.length > 0 && !whole),
    question_boxes: [...(first.question_boxes ?? []), ...(rest.question_boxes ?? [])].length
      ? [...(first.question_boxes ?? []), ...(rest.question_boxes ?? [])]
      : null,
    figure_box: first.figure_box ?? rest.figure_box,
    cont_next: rest.cont_next,
    cont_prev: first.cont_prev,
  };
}

/**
 * Whether a question that was not flagged still looks cut off: some of its options but not all four. A page's rest-of-question
 * item can then join it even when the page before did not say it went on.
 */
export const looksCut = (p: Pick<Part, 'options'>) => p.options.length > 0 && p.options.length < 4;
