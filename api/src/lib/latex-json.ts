/**
 * Models write LaTeX inside JSON strings with one backslash ("\frac{1}{2}"). JSON reads "\f" as a form feed and
 * "\t" as a tab, so the fraction arrives as "<form feed>rac{1}{2}", and it rejects "\s", "\a", "\c" and the like,
 * so a "\sqrt" fails the whole reply. This doubles the backslash of every LaTeX command before the reply is parsed.
 *
 * A reply that already doubled its backslashes comes back unchanged. A real line break ("\n") stays one: it is
 * changed only when the word it starts is a LaTeX command such as \neq or \nu. No question has a form feed, a
 * backspace, a carriage return or a tab in it on purpose, so \b \f \r \t before a letter always mean LaTeX.
 */
const LATEX_N = new Set([
  'ne', 'neq', 'nu', 'ni', 'not', 'notin', 'nabla', 'nmid', 'nsim', 'ncong', 'nless', 'ngtr', 'nleq', 'ngeq',
  'nparallel', 'nrightarrow', 'nleftarrow', 'nsubseteq', 'natural',
]);

export function fixLatexEscapes(json: string): string {
  let out = '';
  for (let i = 0; i < json.length; i++) {
    const ch = json[i];
    if (ch !== '\\') {
      out += ch;
      continue;
    }
    const next = json[i + 1];
    if (next === undefined) {
      out += ch;
      break;
    }
    // An escape JSON means: keep the pair.
    if (next === '"' || next === '\\' || next === '/') {
      out += ch + next;
      i++;
      continue;
    }
    if (next === 'u' && /^[0-9a-fA-F]{4}/.test(json.slice(i + 2, i + 6))) {
      out += json.slice(i, i + 6);
      i += 5;
      continue;
    }
    if (next === 'n') {
      const word = /^[A-Za-z]+/.exec(json.slice(i + 1))?.[0] ?? '';
      if (LATEX_N.has(word)) {
        out += '\\\\';
      } else {
        out += ch + next;
        i++;
      }
      continue;
    }
    if ('bfrt'.includes(next) && !/[A-Za-z]/.test(json[i + 2] ?? '')) {
      out += ch + next;
      i++;
      continue;
    }
    // \frac \times \beta \rightarrow, and every other backslash JSON would refuse (\sqrt \alpha \pi \circ).
    out += '\\\\';
  }
  return out;
}

/**
 * An option that is all maths but came without $...$ (the model forgot): wrap it so the app draws it as maths.
 * Anything that already has a $, or has real words in it, is left as it is.
 */
export function wrapBareMath(s: string): string {
  if (s.includes('$')) return s;
  if (!/\\[A-Za-z]+|[\^_]\{?[A-Za-z0-9]/.test(s)) return s;
  if (/[A-Za-z]{4,}/.test(s.replace(/\\[A-Za-z]+/g, ' '))) return s;
  return `$${s}$`;
}
