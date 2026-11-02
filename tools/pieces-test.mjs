// Checks for the boxes a page reader gives and for putting a question that ran over a page edge back together.
// Run: node tools/pieces-test.mjs
import { cleanBox, cleanPlaced, cleanPlacedList, joinParts, looksCut, placed } from '../api/src/lib/pieces.ts';
let fail = 0;
const eq = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) {
    fail++;
    console.log('FAIL', name, '\n  got ', JSON.stringify(got), '\n  want', JSON.stringify(want));
  } else console.log('ok  ', name);
};

// boxes as models write them
eq('fractions stay', cleanBox([0.1, 0.2, 0.5, 0.6]), [0.1, 0.2, 0.5, 0.6]);
eq('0 to 1000 becomes fractions', cleanBox([100, 200, 500, 600]), [0.1, 0.2, 0.5, 0.6]);
eq('wrapped in one more list', cleanBox([[0.1, 0.2, 0.5, 0.6]]), [0.1, 0.2, 0.5, 0.6]);
eq('right edge first is swapped', cleanBox([0.5, 0.2, 0.1, 0.6]), [0.1, 0.2, 0.5, 0.6]);
eq('bottom edge first is swapped', cleanBox([0.1, 0.6, 0.5, 0.2]), [0.1, 0.2, 0.5, 0.6]);
eq('outside the page is pulled in', cleanBox([-0.2, 0.1, 1.2, 0.9]), [0, 0.1, 1, 0.9]);
eq('not four numbers', cleanBox([0.1, 0.2, 0.5]), null);
eq('numbers as text', cleanBox(['0.1', '0.2', '0.5', '0.6']), null);
eq('null', cleanBox(null), null);
eq('a sliver is no box', cleanBox([0.1, 0.2, 0.11, 0.6]), null);
eq('a line is no box', cleanBox([0.1, 0.2, 0.5, 0.21]), null);
eq('NaN', cleanBox([0.1, NaN, 0.5, 0.6]), null);
eq('rounds to four places', cleanBox([0.123456, 0.2, 0.55555, 0.6]), [0.1235, 0.2, 0.5556, 0.6]);

// a box on a page
eq('placed', placed(2, [0.1, 0.2, 0.5, 0.6]), { page: 2, box: [0.1, 0.2, 0.5, 0.6] });
eq('placed with a bad box', placed(2, 'no'), null);
eq('cleanPlaced', cleanPlaced({ page: 3, box: [100, 200, 500, 600] }), { page: 3, box: [0.1, 0.2, 0.5, 0.6] });
eq('cleanPlaced page 0', cleanPlaced({ page: 0, box: [0.1, 0.2, 0.5, 0.6] }), null);
eq('cleanPlaced page as text', cleanPlaced({ page: '3', box: [0.1, 0.2, 0.5, 0.6] }), null);
eq('cleanPlaced not an object', cleanPlaced('x'), null);
eq('cleanPlacedList keeps good ones', cleanPlacedList([{ page: 1, box: [0.1, 0.1, 0.9, 0.5] }, { page: 2, box: 'no' }]), [{ page: 1, box: [0.1, 0.1, 0.9, 0.5] }]);
eq('cleanPlacedList of nothing', cleanPlacedList([]), null);

// joining
const part = (o) => ({ number_label: '4', kind: 'other', text: '', options: [], needs_diagram: false, unclear: false, question_boxes: null, figure_box: null, cont_next: false, cont_prev: false, ...o });

const cutInTheOptions = joinParts(
  part({ text: 'A lens forms a sharp image 15 cm away. Its power is nearly', options: ['6.67 D', '0.15 D'], cont_next: true, question_boxes: [{ page: 1, box: [0.1, 0.7, 0.9, 0.95] }] }),
  part({ number_label: null, options: ['1.5 D', '15 D'], cont_prev: true, question_boxes: [{ page: 2, box: [0.1, 0.05, 0.9, 0.15] }] }),
);
eq('options cut in two: text kept', cutInTheOptions?.text, 'A lens forms a sharp image 15 cm away. Its power is nearly');
eq('options cut in two: four options in order', cutInTheOptions?.options, ['6.67 D', '0.15 D', '1.5 D', '15 D']);
eq('options cut in two: multiple choice now', cutInTheOptions?.kind, 'mcq');
eq('options cut in two: not unclear', cutInTheOptions?.unclear, false);
eq('options cut in two: number kept', cutInTheOptions?.number_label, '4');
eq('options cut in two: both pictures', cutInTheOptions?.question_boxes?.map((b) => b.page), [1, 2]);
eq('options cut in two: no longer cut', [cutInTheOptions?.cont_next, cutInTheOptions?.cont_prev], [false, false]);

const cutInTheWords = joinParts(
  part({ text: 'A body of mass 2 kg moves at 3 m/s. Its kinetic', cont_next: true }),
  part({ number_label: null, text: 'energy is', options: ['9 J', '6 J', '3 J', '12 J'], cont_prev: true }),
);
eq('words cut in two: joined with one space', cutInTheWords?.text, 'A body of mass 2 kg moves at 3 m/s. Its kinetic energy is');
eq('words cut in two: four options', cutInTheWords?.options.length, 4);
eq('words cut in two: multiple choice', cutInTheWords?.kind, 'mcq');

const onlyOptions = joinParts(part({ text: 'Which is right?', options: ['a', 'b'], cont_next: true }), part({ number_label: null, text: '', options: ['c', 'd'], cont_prev: true }));
eq('rest with no words: text is not doubled or padded', onlyOptions?.text, 'Which is right?');

const lost = joinParts(part({ text: 'Which is right?', options: ['a', 'b'], cont_next: true }), part({ number_label: null, options: ['c'], cont_prev: true }));
eq('three options between them: joined but unclear', [lost?.kind, lost?.options.length, lost?.unclear], ['other', 3, true]);

eq('more than four options cannot be one question', joinParts(part({ text: 'q', options: ['a', 'b', 'c'], cont_next: true }), part({ options: ['d', 'e'], cont_prev: true })), null);
eq('nothing to say cannot be a question', joinParts(part({ text: '', cont_next: true }), part({ text: '', cont_prev: true })), null);

const figureOnTheRest = joinParts(part({ text: 'See the figure.', cont_next: true }), part({ number_label: null, options: ['a', 'b', 'c', 'd'], needs_diagram: true, figure_box: { page: 2, box: [0.1, 0.1, 0.6, 0.4] }, cont_prev: true }));
eq('a figure on the second page comes with it', [figureOnTheRest?.needs_diagram, figureOnTheRest?.figure_box?.page], [true, 2]);
const figureOnTheFirst = joinParts(
  part({ text: 'See the figure.', needs_diagram: true, figure_box: { page: 1, box: [0.1, 0.1, 0.6, 0.4] }, cont_next: true }),
  part({ number_label: null, options: ['a', 'b', 'c', 'd'], needs_diagram: true, figure_box: { page: 2, box: [0.1, 0.1, 0.6, 0.4] }, cont_prev: true }),
);
eq('two figures: the first one is kept', figureOnTheFirst?.figure_box?.page, 1);

eq('unclear on either part carries over', joinParts(part({ text: 'q', unclear: true, cont_next: true }), part({ options: ['a', 'b', 'c', 'd'], cont_prev: true }))?.unclear, true);
eq('a third page can follow', joinParts(part({ text: 'a', cont_next: true }), part({ text: 'b', cont_prev: true, cont_next: true }))?.cont_next, true);

eq('looksCut: two options', looksCut({ options: ['a', 'b'] }), true);
eq('looksCut: none', looksCut({ options: [] }), false);
eq('looksCut: four', looksCut({ options: ['a', 'b', 'c', 'd'] }), false);

console.log(fail ? `\n${fail} failed` : '\nall passed');
process.exit(fail ? 1 : 0);
