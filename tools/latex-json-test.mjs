// Checks for the LaTeX repair that model replies pass through before they are parsed. Run: node tools/latex-json-test.mjs
import { fixLatexEscapes, wrapBareMath } from '../api/src/lib/latex-json.ts';
let fail = 0;
const eq = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) {
    fail++;
    console.log('FAIL', name, '\n  got ', JSON.stringify(got), '\n  want', JSON.stringify(want));
  } else console.log('ok  ', name);
};
const parse = (s) => JSON.parse(fixLatexEscapes(s));

// single-backslash LaTeX as a model writes it
eq('frac', parse('{"a":"$\\frac{1}{x^2}$"}').a, '$\\frac{1}{x^2}$');
eq('times', parse('{"a":"$3 \\times 4$"}').a, '$3 \\times 4$');
eq('theta+text', parse('{"a":"$\\theta = \\text{deg}$"}').a, '$\\theta = \\text{deg}$');
eq('beta bar', parse('{"a":"$\\beta + \\bar{x}$"}').a, '$\\beta + \\bar{x}$');
eq('rightarrow', parse('{"a":"$A \\rightarrow B$"}').a, '$A \\rightarrow B$');
eq('sqrt (invalid \\s)', parse('{"a":"$\\sqrt{2}$"}').a, '$\\sqrt{2}$');
eq('alpha pi circ', parse('{"a":"$\\alpha \\pi 90^\\circ$"}').a, '$\\alpha \\pi 90^\\circ$');
eq('neq', parse('{"a":"$a \\neq b$"}').a, '$a \\neq b$');
eq('nu', parse('{"a":"$\\nu$"}').a, '$\\nu$');
eq('Delta uppercase', parse('{"a":"$\\Delta = b^2$"}').a, '$\\Delta = b^2$');
// already doubled stays the same
eq('doubled frac', parse('{"a":"$\\\\frac{3}{4}$"}').a, '$\\frac{3}{4}$');
eq('doubled sqrt+times', parse('{"a":"$\\\\sqrt{2} \\\\times 3$"}').a, '$\\sqrt{2} \\times 3$');
// real escapes survive
eq('newline then Capital', parse('{"a":"Line one.\\nLine two"}').a, 'Line one.\nLine two');
eq('newline then digit', parse('{"a":"A\\n1. x"}').a, 'A\n1. x');
eq('newline then lowercase word', parse('{"a":"first\\nnext line"}').a, 'first\nnext line');
eq('quote', parse('{"a":"He said \\"hi\\""}').a, 'He said "hi"');
eq('slash', parse('{"a":"1\\/2"}').a, '1/2');
eq('unicode degree', parse('{"a":"90\\u00b0"}').a, '90°');
eq('tab then space', parse('{"a":"x\\t y"}').a, 'x\t y');
// a whole reply, like a real one
const reply =
  '{"name":"Quadratics","questions":[{"text":"Solve $x^2 - 5x + 6 = 0$","options":["$x = 2, 3$","x + \\frac{1}{x} = 2","$\\sqrt{3}$","$\\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}$"],"answer":"A"}]}';
const j = parse(reply);
eq('reply option 2', j.questions[0].options[1], 'x + \\frac{1}{x} = 2');
eq('reply option 4', j.questions[0].options[3], '$\\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}$');
// the old behaviour, for contrast
eq('plain JSON.parse mangled it', JSON.parse('{"a":"\\frac"}').a === '\frac', true);

// bare maths
eq('wrap frac', wrapBareMath('x + \\frac{1}{x} = 2'), '$x + \\frac{1}{x} = 2$');
eq('wrap power', wrapBareMath('2x^3 + x^2 + 5 = 0'), '$2x^3 + x^2 + 5 = 0$');
eq('wrap formula', wrapBareMath('Na_2CO_3'), '$Na_2CO_3$');
eq('leave dollars', wrapBareMath('$x^2$'), '$x^2$');
eq('leave words', wrapBareMath('Both roots are real and x^2 > 0'), 'Both roots are real and x^2 > 0');
eq('leave plain number', wrapBareMath('12'), '12');
eq('leave plain text', wrapBareMath('Two distinct real roots'), 'Two distinct real roots');
console.log(fail ? `${fail} FAILED` : 'all passed');
process.exit(fail ? 1 : 0);
