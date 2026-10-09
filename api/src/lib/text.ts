// Helpers so questions in Hindi, Tamil or any other script go through the app the way English ones do.
// The screens stay English; the questions are whatever language the tutor works in.

/** Devanagari (U+0966..U+096F) and Tamil (U+0BE6..U+0BEF) digits as 0 to 9. */
export function asciiDigits(s: string): string {
  return s.replace(/[०-९௦-௯]/g, (ch) => {
    const c = ch.charCodeAt(0);
    return String(c >= 0x0be6 ? c - 0x0be6 : c - 0x0966);
  });
}

/** Whether a text has letters or vowel signs of a script other than Latin (Devanagari, Tamil, ...). */
export const hasNonLatinText = (s: string): boolean => /[\p{L}\p{M}]/u.test(s.replace(/[A-Za-z]/g, ''));

/** Hindi and Tamil are the languages the tutors named; the rest of Indic text is counted the same way. */
export const hasIndicText = (s: string): boolean => /[ऀ-෿]/.test(s);

/** The text of a request mentions one of these languages by name, in English or in its own script. */
export const namesIndicLanguage = (s: string): boolean => /hindi|tamil|telugu|kannada|malayalam|marathi|bengali|हिन्दी|हिंदी|தமிழ்/i.test(s);

/**
 * The printed labels of an option, as a Hindi or Tamil paper writes them: (क)(ख)(ग)(घ), (अ)(ब)(स)(द),
 * (अ)(आ)(इ)(ई), (ए)(बी)(सी)(डी) and (அ)(ஆ)(இ)(ஈ). Each is the position of the option, 0 to 3.
 */
const INDIC_LABELS: Record<string, number> = {
  'क': 0, 'ख': 1, 'ग': 2, 'घ': 3,
  'अ': 0, 'ब': 1, 'स': 2, 'द': 3,
  'आ': 1, 'इ': 2, 'ई': 3,
  'ए': 0, 'बी': 1, 'सी': 2, 'डी': 3,
  'அ': 0, 'ஆ': 1, 'இ': 2, 'ஈ': 3,
};

/** The option an Indic label stands for, or null when it is not one. */
export const indicLabelIndex = (s: string): number | null => (s in INDIC_LABELS ? INDIC_LABELS[s] : null);
