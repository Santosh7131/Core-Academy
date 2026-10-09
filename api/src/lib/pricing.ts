/**
 * What AI work costs at the vendors' list prices, so the admin app can say what each client's use is
 * worth. The app runs on free tiers today and nothing is billed; these are the figures the same work
 * would cost on a paid plan, in rupees.
 *
 * US dollars per million tokens (input, output), read from Google's and Groq's price pages on
 * 2026-10-10. Images count as input tokens. Gemini 3.6 Flash is $0.75 / $3.75 until 31 December 2026
 * and $1.50 / $7.50 from 1 January 2027. Gemini 3.5 Flash is not on Google's page any more; it is
 * priced like 3.6 Flash, and `estimated` says so.
 */
const PRICES: Record<string, readonly [number, number]> = {
  'gemini-3.5-flash-lite': [0.3, 2.5],
  'gemini-3.1-flash-lite': [0.25, 1.5],
  'gemini-3.6-flash': [0.75, 3.75],
  'gemini-3.5-flash': [0.75, 3.75],
  'openai/gpt-oss-120b': [0.15, 0.6],
  'openai/gpt-oss-20b': [0.075, 0.3],
  'qwen/qwen3.8-27b': [0.8, 4],
};

/** Rupees to the dollar for these estimates (October 2026). */
export const USD_INR = 96;

const ESTIMATED = new Set(['gemini-3.5-flash']);

function priceOf(model: string, at: Date): readonly [number, number] {
  if (model === 'gemini-3.6-flash' && at.getTime() >= Date.UTC(2027, 0, 1)) return [1.5, 7.5];
  // A model not on the list is priced like the cheapest one that does real work, so it never reads as free.
  return PRICES[model] ?? PRICES['openai/gpt-oss-120b'];
}

/** The cost of one model's tokens, in rupees. */
export function costInr(model: string, promptTokens: number, completionTokens: number, at = new Date()): number {
  const [input, output] = priceOf(model, at);
  return ((promptTokens * input + completionTokens * output) / 1_000_000) * USD_INR;
}

/** True when a model's price is a guess (a model off Google's and Groq's lists). */
export const isEstimated = (model: string) => ESTIMATED.has(model) || !(model in PRICES);

/** Rounds rupees for display: paise are noise at this size. */
export const rupees = (n: number) => Math.round(n * 100) / 100;
