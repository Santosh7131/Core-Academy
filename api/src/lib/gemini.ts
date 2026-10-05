import type { ChatOptions, Content } from './groq.ts';

// Google's Gemini reads the paper pages: its free tier allows far more image tokens a minute than
// Groq's, and Groq's vision model stays behind it for when Gemini is busy or will not answer.
// One key, GEMINI_API_KEY, set on the function like the Groq keys (tools/upload-groq-keys.ps1).
const key = (process.env.GEMINI_API_KEY ?? '').trim();

export const geminiConfigured = () => key !== '';
export const isGemini = (model: string) => model.startsWith('gemini-');

export type GeminiReply =
  | { ok: true; content: string; prompt?: number; completion?: number }
  | { ok: false; error: string; retryAfter?: number; prompt?: number; completion?: number };

const parts = (c: Content) =>
  typeof c === 'string'
    ? [{ text: c }]
    : c.map((p) => {
        if (p.type === 'text') return { text: p.text };
        const m = /^data:([^;,]+);base64,(.+)$/s.exec(p.image_url.url);
        if (!m) throw new Error('Gemini takes images inline (data: URLs) only.');
        return { inlineData: { mimeType: m[1], data: m[2] } };
      });

/** The chat in Gemini's own shape: the system text apart, images inline. */
function request(opts: ChatOptions) {
  const system = opts.messages.filter((m) => m.role === 'system');
  return {
    ...(system.length ? { systemInstruction: { parts: system.flatMap((m) => parts(m.content)) } } : {}),
    contents: opts.messages
      .filter((m) => m.role !== 'system')
      .map((m) => ({ role: m.role === 'assistant' ? 'model' : 'user', parts: parts(m.content) })),
    generationConfig: {
      // No temperature: Google asks for Gemini 3's default, as lower ones can make it loop.
      // Gemini charges for what it writes, not for what it is allowed, so a dense page gets room.
      maxOutputTokens: Math.max(opts.maxTokens ?? 4096, 8192),
      ...(opts.json ? { responseMimeType: 'application/json' } : {}),
      ...(opts.reasoning ? { thinkingConfig: { thinkingLevel: opts.reasoning } } : {}),
    },
  };
}

export async function geminiChat(model: string, opts: ChatOptions): Promise<GeminiReply> {
  let res: Response;
  try {
    res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST',
      headers: { 'x-goog-api-key': key, 'content-type': 'application/json' },
      body: JSON.stringify(request(opts)),
      signal: AbortSignal.timeout(120_000),
    });
  } catch (e) {
    return { ok: false, error: String(e) };
  }
  const body = await res.text();
  if (!res.ok) {
    // A 429 says when to try again in its RetryInfo detail, e.g. "retryDelay": "17s".
    const delay = Number(/"retryDelay":\s*"([\d.]+)s"/.exec(body)?.[1]);
    return { ok: false, error: `${res.status} ${body.slice(0, 500)}`, retryAfter: res.status === 429 && delay > 0 ? delay : undefined };
  }
  let j: any;
  try {
    j = JSON.parse(body);
  } catch {
    return { ok: false, error: `unreadable reply: ${body.slice(0, 200)}` };
  }
  const u = j.usageMetadata ?? {};
  const usage = { prompt: u.promptTokenCount, completion: (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0) };
  const cand = j.candidates?.[0];
  const content = (cand?.content?.parts ?? []).filter((p: any) => !p.thought).map((p: any) => p.text ?? '').join('');
  // Gemini can stop part way: RECITATION when the page matches text it was trained on,
  // MAX_TOKENS on a runaway reply, SAFETY. Groq gets the page then.
  if (!content || (cand?.finishReason && cand.finishReason !== 'STOP')) {
    return { ok: false, error: `stopped: ${cand?.finishReason ?? j.promptFeedback?.blockReason ?? 'empty reply'}`, ...usage };
  }
  return { ok: true, content, ...usage };
}
