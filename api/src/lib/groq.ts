import { pool } from './db.ts';
import { geminiChat, geminiConfigured, isGemini } from './gemini.ts';
import { HttpError } from './http.ts';

// One chat() for both providers: models named gemini-* go to Google (lib/gemini.ts), the rest to
// Groq. Groq keys rotate per call, starting at a random one so a fresh server does not always lean
// on the first. A 429 or 5xx moves on to another key, then to the next model. Groq's limits are per
// account (organisation), not per key: keys made in one account share one budget, so after a few
// tries on a rate limit there is no point trying the rest.
const keys = (process.env.GROQ_API_KEYS ?? '').split(',').map((k) => k.trim()).filter(Boolean);
let next = Math.floor(Math.random() * Math.max(keys.length, 1));
const TRIES_PER_MODEL = 2;

const list = (v: string | undefined, fallback: string) => (v ?? fallback).split(',').map((s) => s.trim()).filter(Boolean);
// Pages are read by Gemini when its key is set, with Groq's vision model behind it.
export const VISION_MODELS = list(process.env.GROQ_VISION_MODELS, `${geminiConfigured() ? 'gemini-3.5-flash-lite,' : ''}qwen/qwen3.8-27b`);
export const TEXT_MODELS = list(process.env.GROQ_TEXT_MODELS, 'openai/gpt-oss-120b,openai/gpt-oss-20b');
// Answers are worked out by one model and checked by another family, so the two can disagree.
// The checker was chosen by running one 82-question worksheet through each candidate (29 of its
// questions had split the others). Gemini 3.1 Flash-Lite never contradicted the solver there, and
// gpt-oss-20b did as well; Qwen and Gemini 3.5 Flash-Lite, each sure of itself, disputed 8 to 10
// answers that were right. Gemini 3.5 Flash was best too, but its free plan allows only 20 requests
// a day, so it is a late stand-in. gpt-oss-20b is the same family as the solver, so it comes
// after Gemini: a second opinion that is less independent is still better than none.
export const SOLVE_MODELS = list(process.env.GROQ_SOLVE_MODELS, 'openai/gpt-oss-120b');
export const CHECK_MODELS = list(
  process.env.GROQ_CHECK_MODELS,
  geminiConfigured()
    ? 'gemini-3.1-flash-lite,openai/gpt-oss-20b,gemini-3.5-flash,qwen/qwen3.8-27b'
    : 'openai/gpt-oss-20b,qwen/qwen3.8-27b',
);

export type Content = string | Array<{ type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string } }>;
export type ChatMessage = { role: 'system' | 'user' | 'assistant'; content: Content };

export type ChatOptions = {
  task: string;
  userId: string | null;
  models: string[];
  messages: ChatMessage[];
  json?: boolean;
  maxTokens?: number;
  temperature?: number;
  /** How hard the model thinks before answering; solving questions wants more than reading them. */
  reasoning?: 'low' | 'medium' | 'high';
};

function modelParams(model: string, reasoning: ChatOptions['reasoning']): Record<string, unknown> {
  if (model.startsWith('openai/gpt-oss')) return { include_reasoning: false, reasoning_effort: reasoning ?? 'low' };
  if (model.startsWith('qwen/')) {
    return reasoning ? { reasoning_format: 'hidden', reasoning_effort: 'default' } : { reasoning_format: 'hidden', reasoning_effort: 'none' };
  }
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

export const aiConfigured = () => keys.length > 0 || geminiConfigured();
const usable = (model: string) => (isGemini(model) ? geminiConfigured() : keys.length > 0);

export async function chat(opts: ChatOptions): Promise<{ content: string; model: string }> {
  const models = opts.models.filter(usable);
  if (!models.length) throw new HttpError(503, 'ai_not_configured', 'AI is not set up on the server yet.');
  let retryAfter: number | null = null;

  for (const model of models) {
    if (isGemini(model)) {
      // "High demand" (503) on Google's side passes in seconds, and so does the free plan's
      // per-minute limit (it says how long: a few seconds when pages are read side by side).
      // The models behind this one are weaker, so it gets one more try before they do. A limit
      // that lasts longer, such as a day's quota, goes straight on to them.
      for (let tries = 0; tries < 2; tries++) {
        const started = Date.now();
        const r = await geminiChat(model, opts);
        await logUsage({
          userId: opts.userId, task: opts.task, model, slot: null, ok: r.ok, error: r.ok ? undefined : r.error,
          prompt: r.prompt, completion: r.completion, ms: Date.now() - started,
        });
        if (r.ok) return { content: r.content, model };
        if (r.retryAfter) retryAfter = Math.min(retryAfter ?? r.retryAfter, r.retryAfter);
        const brief = r.error.startsWith('503') ? 2 : r.retryAfter !== undefined && r.retryAfter <= 10 ? r.retryAfter + 0.5 : null;
        if (brief === null || tries > 0) break;
        await new Promise((ok) => setTimeout(ok, brief * 1000));
      }
      continue;
    }
    for (let tries = 0; tries < Math.min(keys.length, TRIES_PER_MODEL); tries++) {
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
            ...modelParams(model, opts.reasoning),
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
    retryAfter
      ? `AI is busy right now. Try again in about ${Math.ceil(retryAfter)} second${Math.ceil(retryAfter) === 1 ? '' : 's'}.`
      : 'AI could not read this right now. Try again in a minute.',
  );
}

/** Parses a model's JSON reply, tolerating a stray code fence. */
export function parseJson<T>(text: string): T {
  const cleaned = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  return JSON.parse(cleaned) as T;
}
