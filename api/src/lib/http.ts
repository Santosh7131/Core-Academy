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

export function str(b: Body, key: string, opts: { max?: number; optional?: boolean } = {}): string | undefined {
  const v = b[key];
  if (v === undefined || v === null || (typeof v === 'string' && v.trim() === '')) {
    if (opts.optional) return undefined;
    throw bad(`${key} is required.`);
  }
  if (typeof v !== 'string') throw bad(`${key} must be text.`);
  const s = v.trim();
  if (opts.max && s.length > opts.max) throw bad(`${key} is too long (max ${opts.max} characters).`);
  return s;
}

export function int(b: Body, key: string, opts: { min?: number; max?: number; optional?: boolean } = {}): number | undefined {
  const v = b[key];
  if (v === undefined || v === null || v === '') {
    if (opts.optional) return undefined;
    throw bad(`${key} is required.`);
  }
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isInteger(n)) throw bad(`${key} must be a whole number.`);
  if (opts.min !== undefined && n < opts.min) throw bad(`${key} must be at least ${opts.min}.`);
  if (opts.max !== undefined && n > opts.max) throw bad(`${key} must be at most ${opts.max}.`);
  return n;
}

export function bool(b: Body, key: string, fallback?: boolean): boolean {
  const v = b[key];
  if (v === undefined || v === null) {
    if (fallback === undefined) throw bad(`${key} is required.`);
    return fallback;
  }
  if (typeof v !== 'boolean') throw bad(`${key} must be true or false.`);
  return v;
}

export function date(b: Body, key: string): Date | null {
  const v = b[key];
  if (v === undefined || v === null || v === '') return null;
  const d = new Date(String(v));
  if (Number.isNaN(d.getTime())) throw bad(`${key} is not a valid date and time.`);
  return d;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function uuid(v: unknown, what = 'id'): string {
  if (typeof v !== 'string' || !UUID.test(v)) throw bad(`${what} is not valid.`);
  return v;
}
export function uuidOpt(v: unknown, what = 'id'): string | null {
  return v === undefined || v === null || v === '' ? null : uuid(v, what);
}
