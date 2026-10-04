// Sample content for Core Academy: placeholder chapters and original MCQs for CBSE classes 6-12.
// Every row seeded from here is flagged is_sample and can be removed from Settings in the app.
// `expect` is computed independently in tools/check-answers.ts to prove each marked answer is right.

export type SampleQuestion = {
  chapter: string;
  text: string;
  options: [string, string, string, string];
  correct: 0 | 1 | 2 | 3;
  solution: string;
  expect: number | string; // the value the correct option must hold
};

export const chapters: Record<number, string[]> = {
  6: ['Fractions', 'Integers', 'Perimeter and Area'],
  7: ['Integers', 'Simple Equations', 'Lines and Angles'],
  8: ['Linear Equations in One Variable', 'Squares and Square Roots', 'Mensuration'],
  9: ['Number Systems', 'Polynomials', 'Linear Equations in Two Variables'],
  10: ['Real Numbers', 'Polynomials', 'Quadratic Equations', 'Arithmetic Progressions'],
  11: ['Sets', 'Trigonometric Functions', 'Sequences and Series'],
  12: ['Matrices', 'Determinants', 'Integrals'],
};

const gcd = (a: number, b: number): number => (b === 0 ? a : gcd(b, a % b));

export const questions: Record<number, SampleQuestion[]> = {
  6: [
    {
      chapter: 'Fractions',
      text: 'Which fraction is equivalent to $\\frac{3}{4}$?',
      options: ['$\\frac{6}{8}$', '$\\frac{4}{3}$', '$\\frac{3}{8}$', '$\\frac{6}{4}$'],
      correct: 0,
      solution: 'Multiply the numerator and the denominator by 2: $\\frac{3 \\times 2}{4 \\times 2} = \\frac{6}{8}$.',
      expect: 3 / 4,
    },
    {
      chapter: 'Fractions',
      text: 'What is $\\frac{2}{5} + \\frac{1}{5}$?',
      options: ['$\\frac{3}{10}$', '$\\frac{3}{5}$', '$\\frac{2}{25}$', '$\\frac{1}{5}$'],
      correct: 1,
      solution: 'The denominators are the same, so add the numerators: $\\frac{2 + 1}{5} = \\frac{3}{5}$.',
      expect: 2 / 5 + 1 / 5,
    },
    {
      chapter: 'Integers',
      text: 'What is $-7 + 4$?',
      options: ['$3$', '$-11$', '$-3$', '$11$'],
      correct: 2,
      solution: 'Start at $-7$ on the number line and move 4 steps to the right to reach $-3$.',
      expect: -7 + 4,
    },
    {
      chapter: 'Integers',
      text: 'Which of these integers is the smallest?',
      options: ['$-2$', '$0$', '$-9$', '$5$'],
      correct: 2,
      solution: 'On the number line, $-9$ lies furthest to the left, so it is the smallest.',
      expect: Math.min(-2, 0, -9, 5),
    },
    {
      chapter: 'Perimeter and Area',
      text: 'What is the perimeter of a rectangle of length 8 cm and breadth 5 cm?',
      options: ['13 cm', '40 cm', '26 cm', '21 cm'],
      correct: 2,
      solution: 'Perimeter $= 2 \\times (8 + 5) = 26$ cm.',
      expect: 2 * (8 + 5),
    },
    {
      chapter: 'Perimeter and Area',
      text: 'What is the area of a square of side 7 cm?',
      options: ['28 cm²', '49 cm²', '14 cm²', '21 cm²'],
      correct: 1,
      solution: 'Area $= 7 \\times 7 = 49\\ \\text{cm}^2$.',
      expect: 7 * 7,
    },
  ],
  7: [
    {
      chapter: 'Integers',
      text: 'What is $(-6) \\times (-4)$?',
      options: ['$-24$', '$24$', '$-10$', '$10$'],
      correct: 1,
      solution: 'The product of two negative integers is positive: $6 \\times 4 = 24$.',
      expect: -6 * -4,
    },
    {
      chapter: 'Integers',
      text: 'What is $(-36) \\div 9$?',
      options: ['$4$', '$-4$', '$-27$', '$-45$'],
      correct: 1,
      solution: 'A negative number divided by a positive one is negative: $36 \\div 9 = 4$, so the answer is $-4$.',
      expect: -36 / 9,
    },
    {
      chapter: 'Simple Equations',
      text: 'If $3x + 5 = 20$, what is $x$?',
      options: ['$5$', '$15$', '$\\frac{25}{3}$', '$3$'],
      correct: 0,
      solution: '$3x = 20 - 5 = 15$, so $x = 5$.',
      expect: (20 - 5) / 3,
    },
    {
      chapter: 'Simple Equations',
      text: 'If $\\frac{x}{4} = 7$, what is $x$?',
      options: ['$11$', '$3$', '$28$', '$\\frac{7}{4}$'],
      correct: 2,
      solution: 'Multiply both sides by 4: $x = 28$.',
      expect: 7 * 4,
    },
    {
      chapter: 'Lines and Angles',
      text: 'What is the complement of $35^\\circ$?',
      options: ['$145^\\circ$', '$55^\\circ$', '$65^\\circ$', '$45^\\circ$'],
      correct: 1,
      solution: 'Complementary angles add up to $90^\\circ$: $90^\\circ - 35^\\circ = 55^\\circ$.',
      expect: 90 - 35,
    },
    {
      chapter: 'Lines and Angles',
      text: 'What is the supplement of $110^\\circ$?',
      options: ['$70^\\circ$', '$20^\\circ$', '$250^\\circ$', '$90^\\circ$'],
      correct: 0,
      solution: 'Supplementary angles add up to $180^\\circ$: $180^\\circ - 110^\\circ = 70^\\circ$.',
      expect: 180 - 110,
    },
  ],
  8: [
    {
      chapter: 'Linear Equations in One Variable',
      text: 'Solve $2x - 7 = 11$.',
      options: ['$x = 2$', '$x = 9$', '$x = -2$', '$x = 18$'],
      correct: 1,
      solution: '$2x = 11 + 7 = 18$, so $x = 9$.',
      expect: (11 + 7) / 2,
    },
    {
      chapter: 'Linear Equations in One Variable',
      text: 'If $5(x - 2) = 3x + 4$, what is $x$?',
      options: ['$7$', '$3$', '$-7$', '$\\frac{7}{4}$'],
      correct: 0,
      solution: '$5x - 10 = 3x + 4$, so $2x = 14$ and $x = 7$.',
      expect: (4 + 10) / (5 - 3),
    },
    {
      chapter: 'Squares and Square Roots',
      text: 'What is $\\sqrt{196}$?',
      options: ['$13$', '$14$', '$16$', '$98$'],
      correct: 1,
      solution: '$14 \\times 14 = 196$, so $\\sqrt{196} = 14$.',
      expect: Math.sqrt(196),
    },
    {
      chapter: 'Squares and Square Roots',
      text: 'Which of these numbers is a perfect square?',
      options: ['$1000$', '$243$', '$1024$', '$500$'],
      correct: 2,
      solution: '$1024 = 32 \\times 32$. None of the others is the square of a whole number.',
      expect: [1000, 243, 1024, 500].filter((n) => Number.isInteger(Math.sqrt(n)))[0],
    },
    {
      chapter: 'Mensuration',
      text: 'A trapezium has parallel sides of 10 cm and 6 cm, and the distance between them is 4 cm. What is its area?',
      options: ['64 cm²', '32 cm²', '240 cm²', '20 cm²'],
      correct: 1,
      solution: 'Area $= \\frac{1}{2} \\times (10 + 6) \\times 4 = 32\\ \\text{cm}^2$.',
      expect: 0.5 * (10 + 6) * 4,
    },
    {
      chapter: 'Mensuration',
      text: 'What is the volume of a cube of edge 5 cm?',
      options: ['25 cm³', '75 cm³', '150 cm³', '125 cm³'],
      correct: 3,
      solution: 'Volume $= 5^3 = 125\\ \\text{cm}^3$.',
      expect: 5 ** 3,
    },
  ],
  9: [
    {
      chapter: 'Linear Equations in Two Variables',
      text: 'If $x = 2,\\ y = -1$ is a solution of $3x + ky = 4$, what is the value of $k$?',
      options: ['$-2$', '$2$', '$\\frac{1}{2}$', '$10$'],
      correct: 1,
      solution: 'Substitute: $3(2) + k(-1) = 4$, so $6 - k = 4$ and $k = 2$.',
      expect: (3 * 2 - 4) / 1,
    },
    {
      chapter: 'Linear Equations in Two Variables',
      text: 'Where does the line $2x + 3y = 12$ meet the $y$-axis?',
      options: ['$(6, 0)$', '$(0, 4)$', '$(4, 0)$', '$(0, 6)$'],
      correct: 1,
      solution: 'On the $y$-axis $x = 0$, so $3y = 12$ and $y = 4$.',
      expect: `$(0, ${12 / 3})$`,
    },
    {
      chapter: 'Number Systems',
      text: 'Which of these numbers is irrational?',
      options: ['$\\sqrt{16}$', '$\\frac{22}{7}$', '$\\sqrt{5}$', '$0.25$'],
      correct: 2,
      solution: '$\\sqrt{16} = 4$, while $\\frac{22}{7}$ and $0.25$ are fractions. 5 is not a perfect square, so $\\sqrt{5}$ is irrational.',
      expect: '$\\sqrt{5}$',
    },
    {
      chapter: 'Number Systems',
      text: 'Which fraction is equal to $0.\\overline{3}$?',
      options: ['$\\frac{3}{10}$', '$\\frac{1}{3}$', '$\\frac{3}{100}$', '$\\frac{33}{10}$'],
      correct: 1,
      solution: 'Let $x = 0.\\overline{3}$. Then $10x = 3.\\overline{3}$, so $9x = 3$ and $x = \\frac{1}{3}$.',
      expect: 3 / 9,
    },
    {
      chapter: 'Polynomials',
      text: 'What is the degree of $5x^3 - 2x^2 + 7$?',
      options: ['$5$', '$2$', '$3$', '$7$'],
      correct: 2,
      solution: 'The highest power of $x$ is 3, so the degree is 3.',
      expect: 3,
    },
    {
      chapter: 'Polynomials',
      text: 'If $p(x) = x^2 - 3x + 2$, what is $p(2)$?',
      options: ['$0$', '$2$', '$4$', '$-2$'],
      correct: 0,
      solution: '$p(2) = 2^2 - 3(2) + 2 = 4 - 6 + 2 = 0$.',
      expect: 2 ** 2 - 3 * 2 + 2,
    },
  ],
  10: [
    {
      chapter: 'Real Numbers',
      text: 'What is the HCF of 96 and 404?',
      options: ['$4$', '$8$', '$12$', '$16$'],
      correct: 0,
      solution: '$96 = 2^5 \\times 3$ and $404 = 2^2 \\times 101$, so the HCF is $2^2 = 4$.',
      expect: gcd(96, 404),
    },
    {
      chapter: 'Real Numbers',
      text: 'What is the LCM of 12 and 18?',
      options: ['$6$', '$72$', '$36$', '$216$'],
      correct: 2,
      solution: '$12 = 2^2 \\times 3$ and $18 = 2 \\times 3^2$, so the LCM is $2^2 \\times 3^2 = 36$.',
      expect: (12 * 18) / gcd(12, 18),
    },
    {
      chapter: 'Polynomials',
      text: 'If $\\alpha$ and $\\beta$ are the zeroes of $x^2 - 5x + 6$, what is $\\alpha + \\beta$?',
      options: ['$-5$', '$5$', '$6$', '$-6$'],
      correct: 1,
      solution: 'For $ax^2 + bx + c$, the sum of the zeroes is $-\\frac{b}{a} = -\\frac{-5}{1} = 5$.',
      expect: -(-5) / 1,
    },
    {
      chapter: 'Quadratic Equations',
      text: 'What are the roots of $x^2 - 7x + 12 = 0$?',
      options: ['$3$ and $4$', '$-3$ and $-4$', '$2$ and $6$', '$1$ and $12$'],
      correct: 0,
      solution: '$x^2 - 7x + 12 = (x - 3)(x - 4)$, so $x = 3$ or $x = 4$.',
      expect: (() => {
        const d = Math.sqrt(49 - 48);
        const [r1, r2] = [(7 - d) / 2, (7 + d) / 2];
        return `$${r1}$ and $${r2}$`;
      })(),
    },
    {
      chapter: 'Quadratic Equations',
      text: 'What is the discriminant of $2x^2 - 4x + 3 = 0$?',
      options: ['$-8$', '$8$', '$40$', '$-40$'],
      correct: 0,
      solution: '$b^2 - 4ac = (-4)^2 - 4 \\times 2 \\times 3 = 16 - 24 = -8$.',
      expect: (-4) ** 2 - 4 * 2 * 3,
    },
    {
      chapter: 'Arithmetic Progressions',
      text: 'What is the 10th term of the AP $2, 7, 12, \\ldots$?',
      options: ['$52$', '$47$', '$45$', '$50$'],
      correct: 1,
      solution: '$a = 2$ and $d = 5$, so $a_{10} = 2 + 9 \\times 5 = 47$.',
      expect: 2 + 9 * 5,
    },
  ],
  11: [
    {
      chapter: 'Sets',
      text: 'How many subsets does $A = \\{1, 2, 3\\}$ have?',
      options: ['$3$', '$6$', '$8$', '$9$'],
      correct: 2,
      solution: 'A set with $n$ elements has $2^n$ subsets, so $2^3 = 8$.',
      expect: 2 ** 3,
    },
    {
      chapter: 'Sets',
      text: 'If $A = \\{1, 2, 3, 4\\}$ and $B = \\{3, 4, 5\\}$, what is $A \\cap B$?',
      options: ['$\\{3, 4\\}$', '$\\{1, 2, 5\\}$', '$\\{1, 2, 3, 4, 5\\}$', '$\\{5\\}$'],
      correct: 0,
      solution: '$A \\cap B$ contains the elements that are in both sets: 3 and 4.',
      expect: `$\\{${[1, 2, 3, 4].filter((x) => [3, 4, 5].includes(x)).join(', ')}\\}$`,
    },
    {
      chapter: 'Trigonometric Functions',
      text: 'What is $\\sin 30^\\circ \\times \\cos 60^\\circ$?',
      options: ['$\\frac{1}{2}$', '$\\frac{\\sqrt{3}}{4}$', '$\\frac{1}{4}$', '$1$'],
      correct: 2,
      solution: '$\\sin 30^\\circ = \\frac{1}{2}$ and $\\cos 60^\\circ = \\frac{1}{2}$, so the product is $\\frac{1}{4}$.',
      expect: Math.sin(Math.PI / 6) * Math.cos(Math.PI / 3),
    },
    {
      chapter: 'Trigonometric Functions',
      text: '$\\pi$ radians is equal to how many degrees?',
      options: ['$90^\\circ$', '$180^\\circ$', '$270^\\circ$', '$360^\\circ$'],
      correct: 1,
      solution: 'A straight angle is $\\pi$ radians, which is $180^\\circ$.',
      expect: (Math.PI * 180) / Math.PI,
    },
    {
      chapter: 'Sequences and Series',
      text: 'What is the sum of the first 10 natural numbers?',
      options: ['$45$', '$50$', '$55$', '$100$'],
      correct: 2,
      solution: '$\\frac{n(n + 1)}{2} = \\frac{10 \\times 11}{2} = 55$.',
      expect: Array.from({ length: 10 }, (_, i) => i + 1).reduce((s, x) => s + x, 0),
    },
    {
      chapter: 'Sequences and Series',
      text: 'What is the 5th term of the GP $3, 6, 12, \\ldots$?',
      options: ['$24$', '$48$', '$96$', '$30$'],
      correct: 1,
      solution: '$a = 3$ and $r = 2$, so $a_5 = 3 \\times 2^4 = 48$.',
      expect: 3 * 2 ** 4,
    },
  ],
  12: [
    {
      chapter: 'Matrices',
      text: 'If $A$ is a $2 \\times 3$ matrix and $B$ is a $3 \\times 4$ matrix, what is the order of $AB$?',
      options: ['$3 \\times 3$', '$2 \\times 4$', '$4 \\times 2$', 'Not defined'],
      correct: 1,
      solution: 'An $m \\times n$ matrix times an $n \\times p$ matrix is $m \\times p$, here $2 \\times 4$.',
      expect: `$${2} \\times ${4}$`,
    },
    {
      chapter: 'Determinants',
      text: 'What is $\\begin{vmatrix} 2 & 3 \\\\ 1 & 4 \\end{vmatrix}$?',
      options: ['$5$', '$11$', '$-5$', '$8$'],
      correct: 0,
      solution: '$2 \\times 4 - 3 \\times 1 = 8 - 3 = 5$.',
      expect: 2 * 4 - 3 * 1,
    },
    {
      chapter: 'Determinants',
      text: 'If $\\begin{vmatrix} x & 2 \\\\ 3 & 4 \\end{vmatrix} = 2$, what is $x$?',
      options: ['$1$', '$2$', '$-2$', '$\\frac{1}{2}$'],
      correct: 1,
      solution: '$4x - 6 = 2$, so $4x = 8$ and $x = 2$.',
      expect: (2 + 2 * 3) / 4,
    },
    {
      chapter: 'Integrals',
      text: 'What is $\\int 2x \\, dx$?',
      options: ['$x^2 + C$', '$2x^2 + C$', '$2 + C$', '$\\frac{x^2}{2} + C$'],
      correct: 0,
      solution: '$\\int x^n \\, dx = \\frac{x^{n+1}}{n+1} + C$, so $\\int 2x \\, dx = 2 \\cdot \\frac{x^2}{2} + C = x^2 + C$.',
      expect: '$x^2 + C$',
    },
    {
      chapter: 'Integrals',
      text: 'What is $\\int_0^1 x^2 \\, dx$?',
      options: ['$\\frac{1}{2}$', '$1$', '$\\frac{1}{3}$', '$\\frac{2}{3}$'],
      correct: 2,
      solution: '$\\int_0^1 x^2 \\, dx = \\left[\\frac{x^3}{3}\\right]_0^1 = \\frac{1}{3}$.',
      expect: (() => {
        // midpoint rule, independent of the antiderivative
        const n = 100_000;
        let s = 0;
        for (let i = 0; i < n; i++) s += ((i + 0.5) / n) ** 2;
        return s / n;
      })(),
    },
    {
      chapter: 'Matrices',
      text: 'If $A = \\begin{bmatrix} 1 & 2 \\\\ 3 & 4 \\end{bmatrix}$, what is $A\'$, the transpose of $A$?',
      options: [
        '$\\begin{bmatrix} 1 & 3 \\\\ 2 & 4 \\end{bmatrix}$',
        '$\\begin{bmatrix} 4 & 3 \\\\ 2 & 1 \\end{bmatrix}$',
        '$\\begin{bmatrix} 2 & 1 \\\\ 4 & 3 \\end{bmatrix}$',
        '$\\begin{bmatrix} 1 & 2 \\\\ 3 & 4 \\end{bmatrix}$',
      ],
      correct: 0,
      solution: 'Rows become columns: the first row $1, 2$ becomes the first column.',
      expect: (() => {
        const a = [[1, 2], [3, 4]];
        const t = [[a[0][0], a[1][0]], [a[0][1], a[1][1]]];
        return `$\\begin{bmatrix} ${t[0].join(' & ')} \\\\ ${t[1].join(' & ')} \\end{bmatrix}$`;
      })(),
    },
  ],
};

export type SampleStudent = { name: string; username: string; classLevel: number; weekly: number | null; unit1: number | null; practiceToday: number | null };

// Scores are correct answers out of 4 (weekly quiz) and 6 (unit test 1); null = missed.
export const students: SampleStudent[] = [
  { name: 'Arjun Selvam', username: 'arjun.s', classLevel: 6, weekly: 3, unit1: 5, practiceToday: null },
  { name: 'Nila Prakash', username: 'nila.p', classLevel: 7, weekly: 1, unit1: 2, practiceToday: null },
  { name: 'Rohan Balaji', username: 'rohan.b', classLevel: 8, weekly: 3, unit1: 4, practiceToday: 4 },
  { name: 'Harini Venkatesh', username: 'harini.v', classLevel: 9, weekly: 4, unit1: 6, practiceToday: 5 },
  { name: 'Aditi Krishnan', username: 'aditi.k', classLevel: 9, weekly: 2, unit1: 3, practiceToday: null },
  { name: 'Sanjay Murali', username: 'sanjay.m', classLevel: 10, weekly: null, unit1: null, practiceToday: null },
  { name: 'Karthik Raman', username: 'karthik.r', classLevel: 11, weekly: 2, unit1: 4, practiceToday: null },
  { name: 'Meera Subramanian', username: 'meera.s', classLevel: 12, weekly: 4, unit1: 5, practiceToday: 6 },
];
