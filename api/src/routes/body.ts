import type { Context } from 'hono';
import { bad } from '../lib/http.ts';

export async function readBody(c: Context): Promise<Record<string, any>> {
  const text = await c.req.text();
  if (!text) return {};
  try {
    const v = JSON.parse(text);
    if (v && typeof v === 'object' && !Array.isArray(v)) return v;
  } catch {
    /* fall through */
  }
  throw bad('The request body must be a JSON object.');
}
