import 'package:core_academy/core/format.dart' as f;
import 'package:core_academy/ui/math_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('countdown clock', () {
    expect(f.clock(const Duration(minutes: 18, seconds: 42)), '18:42');
    expect(f.clock(const Duration(hours: 1, minutes: 5, seconds: 2)), '1:05:02');
    expect(f.clock(const Duration(seconds: -5)), '00:00');
  });

  test('marks drop a trailing .0', () {
    expect(f.marks(14), '14');
    expect(f.marks(14.0), '14');
    expect(f.marks(13.5), '13.5');
    expect(f.marks(null), '-');
  });

  test('durations', () {
    expect(f.duration(45), '45 s');
    expect(f.duration(18 * 60), '18 min');
    expect(f.duration(65 * 60), '1 h 5 min');
  });

  test('plain text of LaTeX for screen readers', () {
    expect(plainMath(r'What is $\frac{2}{5} + \frac{1}{5}$?'), 'What is 2/5 + 1/5?');
    expect(plainMath(r'The complement of $35^\circ$'), 'The complement of 35°');
    expect(plainMath(r'What is $\sin 30^\circ \times \cos 60^\circ$?'), 'What is sin 30° × cos 60°?');
    expect(plainMath(r'$\frac{\sqrt{3}}{4}$'), '√3/4');
    expect(plainMath(r'$\frac{x+1}{2}$'), '(x+1)/2');
    expect(plainMath(r'How many subsets does $A = \{1, 2, 3\}$ have?'), 'How many subsets does A = {1, 2, 3} have?');
    expect(plainMath(r'The GP $3, 6, 12, \ldots$'), 'The GP 3, 6, 12, …');
    expect(plainMath(r'What is $A \cap B$?'), 'What is A ∩ B?');
    expect(plainMath(r'$\pi$ radians'), 'π radians');
    expect(plainMath(r'Solve $x^2 - 5x + 6 = 0$ for $x \geq 0$'), 'Solve x² - 5x + 6 = 0 for x ≥ 0');
    expect(plainMath(r'$\sqrt 2$ is irrational'), '√2 is irrational');
  });
}
