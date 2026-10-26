// Errors carry a stable code the app can branch on and a sentence it can show as-is.
export class HttpError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const bad = (message: string, code = 'invalid') => new HttpError(400, code, message);
export const notFound = (what = 'That item') => new HttpError(404, 'not_found', `${what} was not found.`);

type Body = Record<string, unknown>;

/**
 * What a field is called in the app, so the sentence about it reads the way the person would say it
 * ("Name is too long"), not the way the JSON does ("display_name is too long").
 */
const FIELD_NAMES: Record<string, string> = {
  display_name: 'Name',
  tuition_name: 'Tuition name',
  exam_name: 'Paper name',
  title: 'Test name',
  request: 'Description',
  text: 'Question',
  solution: 'Explanation',
};
const sentenceStart = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const fieldName = (key: string) => FIELD_NAMES[key] ?? sentenceStart(key.replace(/_/g, ' '));

/** Postgres cannot store a NUL character in text, so a value that holds one would end as a server error. It is refused up front instead. */
export const hasNul = (s: string) => s.includes('\u0000');

/** The most characters one option of a question may have (the longest saved today is 111; the AI readers cut theirs at 500). */
export const MAX_OPTION_CHARS = 1000;

/** The four options of a question, each trimmed: filled in, free of NUL, and not longer than MAX_OPTION_CHARS. */
export function optionList(options: unknown): string[] {
  if (!Array.isArray(options) || options.length !== 4 || options.some((o) => typeof o !== 'string' || !o.trim())) {
    throw bad('A question needs exactly 4 filled-in options.');
  }
  const opts = (options as string[]).map((o) => o.trim());
  if (opts.some(hasNul)) throw bad('An option has a character that cannot be used.');
  if (opts.some((o) => o.length > MAX_OPTION_CHARS)) throw bad(`An option is too long (max ${MAX_OPTION_CHARS} characters).`);
  return opts;
}

export function str(b: Body, key: string, opts: { max?: number; optional?: boolean } = {}): string | undefined {
  const v = b[key];
  if (v === undefined || v === null || (typeof v === 'string' && v.trim() === '')) {
    if (opts.optional) return undefined;
    throw bad(`${fieldName(key)} is required.`);
  }
  if (typeof v !== 'string') throw bad(`${fieldName(key)} must be text.`);
  if (hasNul(v)) throw bad(`${fieldName(key)} has a character that cannot be used.`);
  const s = v.trim();
  if (opts.max && s.length > opts.max) throw bad(`${fieldName(key)} is too long (max ${opts.max} characters).`);
  return s;
}

export function int(b: Body, key: string, opts: { min?: number; max?: number; optional?: boolean } = {}): number | undefined {
  const v = b[key];
  if (v === undefined || v === null || v === '') {
    if (opts.optional) return undefined;
    throw bad(`${fieldName(key)} is required.`);
  }
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isInteger(n)) throw bad(`${fieldName(key)} must be a whole number.`);
  if (opts.min !== undefined && n < opts.min) throw bad(`${fieldName(key)} must be at least ${opts.min}.`);
  if (opts.max !== undefined && n > opts.max) throw bad(`${fieldName(key)} must be at most ${opts.max}.`);
  return n;
}

export function bool(b: Body, key: string, fallback?: boolean): boolean {
  const v = b[key];
  if (v === undefined || v === null) {
    if (fallback === undefined) throw bad(`${fieldName(key)} is required.`);
    return fallback;
  }
  if (typeof v !== 'boolean') throw bad(`${fieldName(key)} must be true or false.`);
  return v;
}

export function date(b: Body, key: string): Date | null {
  const v = b[key];
  if (v === undefined || v === null || v === '') return null;
  const d = new Date(String(v));
  if (Number.isNaN(d.getTime())) throw bad(`${fieldName(key)} is not a valid date and time.`);
  return d;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function uuid(v: unknown, what = 'id'): string {
  if (typeof v !== 'string' || !UUID.test(v)) throw bad(`${sentenceStart(what)} is not valid.`);
  return v;
}
export function uuidOpt(v: unknown, what = 'id'): string | null {
  return v === undefined || v === null || v === '' ? null : uuid(v, what);
}
