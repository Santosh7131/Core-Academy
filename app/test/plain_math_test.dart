import 'package:core_academy/ui/plain_math.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formulas become plain symbols', () {
    final cases = <String, String>{
      r'The sum is $18$ seats': 'The sum is 18 seats',
      r'$x^2$': 'x²',
      r'$x^{2}$': 'x²',
      r'$3n^2 + 5n$': '3n² + 5n',
      r'$x^{10}$': 'x¹⁰',
      r'$10^{-3}$': '10⁻³',
      r'$x^{n+1}$': 'xⁿ⁺¹',
      r'$x^{n + 1}$': 'xⁿ⁺¹',
      r'$x^{a+b}$': 'x^(a+b)',
      r'$e^x$': 'e^x',
      r'$a_1$': 'a₁',
      r'$t_n = 3n - 4$': 'tₙ = 3n - 4',
      r'$t_{n+1} = 2t_n$': 'tₙ₊₁ = 2tₙ',
      r'$x_{AB}$': 'x_AB',
      r'$H_2O$': 'H₂O',
      r'$CO_2$': 'CO₂',
      r'$\sqrt{2}$': '√2',
      r'$\sqrt{x+1}$': '√(x+1)',
      r'$\sqrt[3]{8}$': '∛8',
      r'$\sqrt{x^2+y^2}$': '√(x²+y²)',
      r'$\frac{1}{2}$': '½',
      r'$\frac{3}{4}$': '¾',
      r'$\frac{7}{9}$': '7/9',
      r'$\frac{a}{b}$': 'a/b',
      r'$\frac{a+b}{c}$': '(a+b)/c',
      r'$\frac{x+1}{x-1}$': '(x+1)/(x-1)',
      r'$\frac{\sqrt{3}}{2}$': '√3/2',
      r'$90^\circ$': '90°',
      r'$90^{\circ}$': '90°',
      r'$\angle ABC = 60^\circ$': '∠ABC = 60°',
      r'$3 \times 4 = 12$': '3 × 4 = 12',
      r'$6 \div 2$': '6 ÷ 2',
      r'$\pi r^2$': 'πr²',
      r'$\theta \le 90$': 'θ ≤ 90',
      r'$a \ge b$': 'a ≥ b',
      r'$a \neq b$': 'a ≠ b',
      r'$\pm 5$': '± 5',
      r'$\alpha + \beta$': 'α + β',
      r'$\Delta = b^2 - 4ac$': 'Δ = b² - 4ac',
      r'$64\text{ cm}^3$': '64 cm³',
      r'$3\,\text{m}$': '3 m',
      r'$\sin^2\theta + \cos^2\theta = 1$': 'sin²θ + cos²θ = 1',
      r'$\sin \theta$': 'sin θ',
      r'$\sin\theta$': 'sin θ',
      r'$\tan 45^\circ = 1$': 'tan 45° = 1',
      r'$\log_2 8$': 'log₂ 8',
      r'$A = \{1, 2, 3\}$': 'A = {1, 2, 3}',
      r'$A \cup B$': 'A ∪ B',
      r'$x \in \mathbb{R}$': 'x ∈ ℝ',
      r'$\vec{v}$': 'v⃗',
      r'$\overline{x}$': 'x̄',
      r'$\left(\frac{1}{2}\right)^2$': '(½)²',
      r'$2\Omega$': '2Ω',
      r'$10\%$': '10%',
      r'$1\text{ kg}\cdot\text{m}$': '1 kg·m',
      r'$x \to \infty$': 'x → ∞',
      r'$\triangle ABC \cong \triangle DEF$': '△ABC ≅ △DEF',
      r'$AB \parallel CD$': 'AB ∥ CD',
      r'$AB \perp CD$': 'AB ⊥ CD',
      r'Find $x$ if $2x + 3 = 11$.': 'Find x if 2x + 3 = 11.',
      r'$\lim_{x \to 0} \frac{\sin x}{x}$': 'lim_(x → 0) (sin x)/x',
    };
    cases.forEach((tex, plain) {
      test(tex, () => expect(plainSymbols(tex), plain));
    });
  });

  group('what cannot be written plainly stays as it was', () {
    for (final tex in [
      r'$\begin{matrix} 1 & 2 \end{matrix}$',
      r'$\sum_{i=1}^{n} i$ is a hard one',
      r'$\underbrace{a+b}_{2}$',
      r'$\unknowncommand$',
      r'$\frac{1}$',
      r'$x^$',
    ]) {
      test(tex, () => expect(plainSymbols(tex), tex));
    }
  });

  group('text with no formulas', () {
    test('is left alone', () {
      expect(plainSymbols('Plain text, 5 + 3 = 8.'), 'Plain text, 5 + 3 = 8.');
      expect(plainSymbols(''), '');
      expect(plainSymbols('x² + √2 and ½ typed by hand'), 'x² + √2 and ½ typed by hand');
    });
    test('a single dollar sign is not a formula', () {
      expect(plainSymbols(r'It costs $5'), r'It costs $5');
    });
    test('a formula among words keeps the words', () {
      expect(plainSymbols(r'Two cubes of $64\text{ cm}^3$ each are joined. The new volume is'), 'Two cubes of 64 cm³ each are joined. The new volume is');
    });
    test('only the formula that cannot be written is kept, the others still change', () {
      expect(plainSymbols(r'$x^2$ and $\begin{matrix}1\end{matrix}$'), r'x² and $\begin{matrix}1\end{matrix}$');
    });
  });

  group('PlainBaseline', () {
    test('shows plain symbols and gives the original back when untouched', () {
      final b = PlainBaseline(r'The area is $\pi r^2$');
      final box = TextEditingController(text: b.initial);
      expect(box.text, 'The area is πr²');
      expect(b.touched(box), false);
      expect(b.value(box), r'The area is $\pi r^2$');
      box.dispose();
    });
    test('gives what she typed once she changes it', () {
      final b = PlainBaseline(r'The area is $\pi r^2$');
      final box = TextEditingController(text: b.initial);
      box.text = 'The area is πr² cm';
      expect(b.touched(box), true);
      expect(b.value(box), 'The area is πr² cm');
      box.dispose();
    });
    test('text without formulas is returned trimmed', () {
      final b = PlainBaseline('  Plain  ');
      final box = TextEditingController(text: b.initial);
      expect(b.value(box), 'Plain');
      box.dispose();
    });
    test('a new, empty box gives what is typed in it', () {
      final b = PlainBaseline();
      final box = TextEditingController();
      expect(b.value(box), '');
      box.text = ' x² ';
      expect(b.value(box), 'x²');
      box.dispose();
    });
  });
}
