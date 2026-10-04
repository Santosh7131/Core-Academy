import { pool } from './db.ts';
import { HttpError } from './http.ts';

// Keys rotate per call; a 429 or 5xx moves on to the next key, then to the next model.
// Groq rate limits are per organisation, so rotation only adds capacity across different accounts.
const keys = (process.env.GROQ_API_KEYS ?? '').split(',').map((k) => k.trim()).filter(Boolean);
let next = 0;

const list = (v: string | undefined, fallback: string) => (v ?? fallback).split(',').map((s) => s.trim()).filter(Boolean);
export const VISION_MODELS = list(process.env.GROQ_VISION_MODELS, 'qwen/qwen3.8-27b');
export const TEXT_MODELS = list(process.env.GROQ_TEXT_MODELS, 'openai/gpt-oss-120b,openai/gpt-oss-20b');

type Content = string | Array<{ type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string } }>;
export type ChatMessage = { role: 'system' | 'user' | 'assistant'; content: Content };

export type ChatOptions = {
  task: string;
  userId: string | null;
  models: string[];
  messages: ChatMessage[];
  json?: boolean;
  maxTokens?: number;
  temperature?: number;
};

function modelParams(model: string): Record<string, unknown> {
  if (model.startsWith('openai/gpt-oss')) return { include_reasoning: false, reasoning_effort: 'low' };
  if (model.startsWith('qwen/')) return { reasoning_format: 'hidden', reasoning_effort: 'none' };
  return {};
}

async function logUsage(row: {
  userId: string | null; task: string; model: string; slot: number | null;
  prompt?: number; completion?: number; ok: boolean; error?: string; ms: number;
}) {
  await pool
    .query(
      `insert into ai_usage (user_id, task, model, key_slot, prompt_tokens, completion_tokens, ok, error, ms)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [row.userId, row.task, row.model, row.slot, row.prompt ?? null, row.completion ?? null, row.ok, row.error ?? null, row.ms],
    )
    .catch(() => {});
}

export const aiConfigured = () => keys.length > 0;

export async function chat(opts: ChatOptions): Promise<{ content: string; model: string }> {
  if (!keys.length) throw new HttpError(503, 'ai_not_configured', 'AI is not set up on the server yet.');
  let retryAfter: number | null = null;

  for (const model of opts.models) {
    for (let tries = 0; tries < keys.length; tries++) {
      const slot = next++ % keys.length;
      const started = Date.now();
      let res: Response;
      try {
        res = await fetch('https://api.groq.com/openai/v1/chat/completions', {
          method: 'POST',
          headers: { authorization: `Bearer ${keys[slot]}`, 'content-type': 'application/json' },
          body: JSON.stringify({
            model,
            messages: opts.messages,
            temperature: opts.temperature ?? 0,
            max_completion_tokens: opts.maxTokens ?? 4096,
            ...(opts.json ? { response_format: { type: 'json_object' } } : {}),
            ...modelParams(model),
          }),
          signal: AbortSignal.timeout(120_000),
        });
      } catch (e) {
        await logUsage({ userId: opts.userId, task: opts.task, model, slot, ok: false, error: String(e), ms: Date.now() - started });
        continue;
      }
      const ms = Date.now() - started;
      if (res.ok) {
        const j: any = await res.json();
        await logUsage({
          userId: opts.userId, task: opts.task, model, slot, ok: true, ms,
          prompt: j.usage?.prompt_tokens, completion: j.usage?.completion_tokens,
        });
        return { content: j.choices?.[0]?.message?.content ?? '', model };
      }
      const body = (await res.text()).slice(0, 500);
      await logUsage({ userId: opts.userId, task: opts.task, model, slot, ok: false, error: `${res.status} ${body}`, ms });
      if (res.status === 429 || res.status >= 500) {
        const ra = Number(res.headers.get('retry-after'));
        if (Number.isFinite(ra) && ra > 0) retryAfter = Math.min(retryAfter ?? ra, ra);
        continue; // next key
      }
      if (res.status === 401 || res.status === 403) continue; // this key is bad; try the other one
      break; // 400/404 for this model (e.g. withdrawn): move to the next model
    }
  }
  throw new HttpError(
    503,
    'ai_busy',
    retryAfter ? `AI is busy right now. Try again in about ${Math.ceil(retryAfter)} seconds.` : 'AI could not read this right now. Try again in a minute.',
  );
}

/** Parses a model's JSON reply, tolerating a stray code fence. */
export function parseJson<T>(text: string): T {
  const cleaned = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  return JSON.parse(cleaned) as T;
}
