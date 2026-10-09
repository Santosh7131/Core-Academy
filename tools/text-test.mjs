// Checks that questions in Hindi and Tamil go through the matching, repeat detection and number reading
// the way English ones do. Run: node tools/text-test.mjs
import { answerIndex, sameKey } from '../api/src/routes/papers.ts';
import { asciiDigits, hasIndicText, hasNonLatinText, indicLabelIndex, namesIndicLanguage } from '../api/src/lib/text.ts';
import { wrapBareMath } from '../api/src/lib/latex-json.ts';

let fail = 0;
const eq = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) {
    fail++;
    console.log('FAIL', name, '\n  got ', JSON.stringify(got), '\n  want', JSON.stringify(want));
  } else console.log('ok  ', name);
};

// digits
eq('devanagari digits', asciiDigits('प्रश्न १२'), 'प्रश्न 12');
eq('tamil digits', asciiDigits('வினா ௧௨'), 'வினா 12');
eq('ascii untouched', asciiDigits('Q 12'), 'Q 12');

// script detection
eq('latin is not indic', hasIndicText('Solve x^2 = 4'), false);
eq('hindi is indic', hasIndicText('हल कीजिए'), true);
eq('tamil is indic', hasIndicText('தீர்க்கவும்'), true);
eq('non latin text', hasNonLatinText('2 + 2 = 4'), false);
eq('non latin text, hindi', hasNonLatinText('2 + 2 का मान'), true);
eq('a request naming a language', namesIndicLanguage('Ten questions in Tamil on fractions'), true);
eq('a request in english only', namesIndicLanguage('Ten questions on fractions'), false);

// printed answers
const opts = ['2', '3', '4', '5'];
eq('english letter', answerIndex('(b)', opts), 1);
eq('number', answerIndex('3', opts), 2);
eq('hindi क ख ग घ', ['क', 'ख', 'ग', 'घ'].map((l) => answerIndex(`(${l})`, opts)), [0, 1, 2, 3]);
eq('hindi अ ब स द', ['अ', 'ब', 'स', 'द'].map((l) => answerIndex(l, opts)), [0, 1, 2, 3]);
eq('tamil அ ஆ இ ஈ', ['அ', 'ஆ', 'இ', 'ஈ'].map((l) => answerIndex(`(${l})`, opts)), [0, 1, 2, 3]);
eq('hindi prefix', answerIndex('उत्तर: (ख)', opts), 1);
eq('hindi long prefix', answerIndex('सही उत्तर: ग', opts), 2);
eq('tamil prefix', answerIndex('விடை: ஆ', opts), 1);
eq('hindi digit', answerIndex('३', opts), 2);
eq('tamil digit', answerIndex('௪', opts), 3);
eq('option text in hindi', answerIndex('चार', ['दो', 'तीन', 'चार', 'पाँच']), 2);
eq('unknown label', answerIndex('ज', opts), null);
eq('label helper', indicLabelIndex('ஆ'), 1);

// repeats: different questions in Hindi or Tamil must not look the same
const hi1 = sameKey('एक संख्या का दोगुना 10 है, संख्या बताइए', ['3', '4', '5', '6']);
const hi2 = sameKey('एक संख्या का तिगुना 15 है, संख्या बताइए', ['3', '4', '5', '6']);
eq('two hindi questions differ', hi1 === hi2, false);
const ta1 = sameKey('ஒரு எண்ணின் இரு மடங்கு பத்து எனில் எண் என்ன', ['ஒன்று', 'இரண்டு', 'மூன்று', 'நான்கு']);
const ta2 = sameKey('ஒரு முக்கோணத்தின் கோணங்களின் கூடுதல் என்ன', ['ஒன்று', 'இரண்டு', 'மூன்று', 'நான்கு']);
eq('two tamil questions differ', ta1 === ta2, false);
eq('the same hindi question read twice is equal', sameKey('हल कीजिए: 12 + 4', ['१६', '15', '17', '18']), sameKey('हल  कीजिए : १२ + ४', ['16', '15', '17', '18']));
eq('english still equal', sameKey('18 seats', ['a']), sameKey('$18$ seats', ['a']));
eq('english still different', sameKey('18 seats', ['a']) === sameKey('19 seats', ['a']), false);

// bare maths
eq('hindi option is not wrapped', wrapBareMath('x^2 का मान'), 'x^2 का मान');
eq('tamil option is not wrapped', wrapBareMath('x^2 இன் மதிப்பு'), 'x^2 இன் மதிப்பு');
eq('plain maths is still wrapped', wrapBareMath('x^2 + 1'), '$x^2 + 1$');

console.log(fail ? `${fail} FAILED` : 'all passed');
process.exit(fail ? 1 : 0);
