/** Options that refer to other options ("Both (a) and (b)", "None of these") must keep their printed order. */
export function mustKeepOrder(options: string[]) {
  return options.some((o) =>
    /\b(all|none|both|neither)\b\s*(of\s+)?(the\s+)?(above|these|options)\b|\bboth\s*\(?[a-d]\)?\s*and\b|\(\s*[a-d]\s*\)\s*(and|or)\s*\(\s*[a-d]\s*\)/i.test(o),
  );
}
