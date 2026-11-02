import 'package:flutter/widgets.dart';

// What a question says with its `$...$` formulas written the way you would write them on paper: `$\frac{3}{4}$` is ¾,
// `$x^2$` is x², `$\sqrt{2}$` is √2, `$90^\circ$` is 90°. The tutor reads and edits this, so she never meets a dollar sign
// or a backslash. A formula that cannot be written plainly (a matrix, a limit with working under it) stays as it is.

final _segment = RegExp(r'\$([^$]+)\$');

/// [source] with every `$...$` formula written in plain symbols. A formula this cannot write plainly is left as it was.
String plainSymbols(String source) {
  if (!source.contains(r'$')) return source;
  return source.replaceAllMapped(_segment, (m) => _Tex(m[1]!).plain() ?? m[0]!);
}

class _Unsupported implements Exception {
  const _Unsupported();
}

/// What a text box the tutor edits first showed, and the text that stood for. The box shows [original] in plain symbols;
/// [value] gives back [original] itself while she has not touched the box, so a question she only looked at keeps its
/// fractions and roots on the students' screens.
class PlainBaseline {
  PlainBaseline([this.original = '']) : shown = plainSymbols(original);

  final String original;
  final String shown;

  /// A box that starts with [original] shown plainly. Give its [shown] to the controller.
  String get initial => shown;

  /// What to save: the original text while [box] still shows what it first showed, else what she typed.
  String value(TextEditingController box) => (box.text == shown ? original : box.text).trim();

  /// Whether she has changed what the box showed.
  bool touched(TextEditingController box) => box.text != shown;
}

const _symbols = <String, String>{
  // Greek
  'alpha': 'α', 'beta': 'β', 'gamma': 'γ', 'delta': 'δ', 'epsilon': 'ε', 'varepsilon': 'ε', 'zeta': 'ζ', 'eta': 'η',
  'theta': 'θ', 'vartheta': 'ϑ', 'iota': 'ι', 'kappa': 'κ', 'lambda': 'λ', 'mu': 'μ', 'nu': 'ν', 'xi': 'ξ', 'pi': 'π',
  'rho': 'ρ', 'sigma': 'σ', 'tau': 'τ', 'upsilon': 'υ', 'phi': 'φ', 'varphi': 'φ', 'chi': 'χ', 'psi': 'ψ', 'omega': 'ω',
  'Gamma': 'Γ', 'Delta': 'Δ', 'Theta': 'Θ', 'Lambda': 'Λ', 'Xi': 'Ξ', 'Pi': 'Π', 'Sigma': 'Σ', 'Phi': 'Φ', 'Psi': 'Ψ', 'Omega': 'Ω',
  // signs
  'times': '×', 'div': '÷', 'cdot': '·', 'pm': '±', 'mp': '∓', 'ast': '∗', 'circ': '°', 'degree': '°', 'bullet': '•',
  'le': '≤', 'leq': '≤', 'ge': '≥', 'geq': '≥', 'ne': '≠', 'neq': '≠', 'approx': '≈', 'equiv': '≡', 'sim': '∼', 'cong': '≅',
  'propto': '∝', 'll': '≪', 'gg': '≫',
  // arrows
  'to': '→', 'rightarrow': '→', 'leftarrow': '←', 'Rightarrow': '⇒', 'Leftarrow': '⇐', 'leftrightarrow': '↔',
  'Leftrightarrow': '⇔', 'implies': '⟹', 'iff': '⟺', 'mapsto': '↦', 'uparrow': '↑', 'downarrow': '↓',
  // sets and logic
  'in': '∈', 'notin': '∉', 'ni': '∋', 'subset': '⊂', 'subseteq': '⊆', 'supset': '⊃', 'supseteq': '⊇', 'cup': '∪', 'cap': '∩',
  'emptyset': '∅', 'varnothing': '∅', 'setminus': '∖', 'forall': '∀', 'exists': '∃', 'neg': '¬', 'land': '∧', 'lor': '∨',
  // geometry and the rest
  'infty': '∞', 'angle': '∠', 'triangle': '△', 'perp': '⊥', 'parallel': '∥', 'nparallel': '∦', 'therefore': '∴', 'because': '∵',
  'partial': '∂', 'nabla': '∇', 'ldots': '…', 'dots': '…', 'cdots': '⋯', 'prime': '′', 'square': '□', 'int': '∫',
  // spacing
  ',': ' ', ';': ' ', ':': ' ', ' ': ' ', 'quad': ' ', 'qquad': ' ', '!': '', 'left': '', 'right': '',
  // characters that need a backslash
  '{': '{', '}': '}', '%': '%', '&': '', r'\': ' ', '|': '‖',
};

/// Written out as they are, with a space after them when a letter or number follows.
const _functions = {
  'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'arcsin', 'arccos', 'arctan', 'sinh', 'cosh', 'tanh', 'log', 'ln', 'exp', 'lim',
  'min', 'max', 'gcd', 'lcm', 'det', 'sup', 'inf', 'deg', 'dim',
};

const _textLike = {'text', 'mathrm', 'mathbf', 'mathit', 'textbf', 'textit', 'operatorname', 'mbox', 'boldsymbol'};

const _vulgar = <String, String>{
  '1/2': '½', '1/3': '⅓', '2/3': '⅔', '1/4': '¼', '3/4': '¾', '1/5': '⅕', '2/5': '⅖', '3/5': '⅗', '4/5': '⅘',
  '1/6': '⅙', '5/6': '⅚', '1/8': '⅛', '3/8': '⅜', '5/8': '⅝', '7/8': '⅞',
};

const _super = <String, String>{
  '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴', '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
  '+': '⁺', '-': '⁻', '−': '⁻', '=': '⁼', '(': '⁽', ')': '⁾', 'n': 'ⁿ', 'i': 'ⁱ',
};

const _sub = <String, String>{
  '0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄', '5': '₅', '6': '₆', '7': '₇', '8': '₈', '9': '₉',
  '+': '₊', '-': '₋', '−': '₋', '=': '₌', '(': '₍', ')': '₎',
  'a': 'ₐ', 'e': 'ₑ', 'h': 'ₕ', 'i': 'ᵢ', 'j': 'ⱼ', 'k': 'ₖ', 'l': 'ₗ', 'm': 'ₘ', 'n': 'ₙ', 'o': 'ₒ', 'p': 'ₚ', 'r': 'ᵣ',
  's': 'ₛ', 't': 'ₜ', 'u': 'ᵤ', 'v': 'ᵥ', 'x': 'ₓ',
};

const _combining = {'bar': '̄', 'overline': '̄', 'vec': '⃗', 'hat': '̂', 'tilde': '̃'};
const _blackboard = {'N': 'ℕ', 'Z': 'ℤ', 'Q': 'ℚ', 'R': 'ℝ', 'C': 'ℂ'};

bool _isLetter(String c) => RegExp(r'[A-Za-z0-9]').hasMatch(c);

/// One formula's source, read left to right.
class _Tex {
  _Tex(this.s);
  final String s;
  int i = 0;

  /// The plain text, or null when something in it has no plain form.
  String? plain() {
    try {
      final out = _sequence(inGroup: false);
      if (i < s.length) return null;
      // LaTeX swallows the space after a command: "\pi r" is πr and "\angle ABC" is ∠ABC.
      return out.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAllMapped(RegExp(r'([α-ωΑ-Ω∠△]) (?=[A-Za-z0-9])'), (m) => m[1]!).trim();
    } on _Unsupported {
      return null;
    }
  }

  /// Everything up to the end, or (inside braces) up to the brace that closes the group.
  String _sequence({required bool inGroup}) {
    final b = StringBuffer();
    while (i < s.length) {
      final c = s[i];
      if (c == '}') {
        if (inGroup) return b.toString();
        throw const _Unsupported();
      }
      if (c == '{') {
        i++;
        b.write(_group());
      } else if (c == r'\') {
        b.write(_command());
      } else if (c == '^' || c == '_') {
        i++;
        b.write(_script(c == '^'));
      } else {
        b.write(c);
        i++;
      }
    }
    if (inGroup) throw const _Unsupported();
    return b.toString();
  }

  /// A group whose opening brace has been read.
  String _group() {
    final inner = _sequence(inGroup: true);
    i++; // the closing brace
    return inner;
  }

  /// One argument: a braced group, or the next single character or command.
  String _arg() {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
    if (i >= s.length) throw const _Unsupported();
    final c = s[i];
    if (c == '{') {
      i++;
      return _group();
    }
    if (c == r'\') return _command();
    if (c == '}' || c == '^' || c == '_') throw const _Unsupported();
    i++;
    return c;
  }

  String _command() {
    i++; // the backslash
    if (i >= s.length) throw const _Unsupported();
    var name = s[i];
    if (RegExp(r'[A-Za-z]').hasMatch(name)) {
      final start = i;
      while (i < s.length && RegExp(r'[A-Za-z]').hasMatch(s[i])) {
        i++;
      }
      name = s.substring(start, i);
    } else {
      i++;
    }
    switch (name) {
      case 'frac' || 'dfrac' || 'tfrac':
        final a = _arg();
        final b = _arg();
        return _fraction(a, b);
      case 'sqrt':
        String? index;
        if (i < s.length && s[i] == '[') {
          final end = s.indexOf(']', i);
          if (end < 0) throw const _Unsupported();
          index = s.substring(i + 1, end).trim();
          i = end + 1;
        }
        return _root(index, _arg());
      case 'mathbb':
        final a = _arg();
        return _blackboard[a] ?? (throw const _Unsupported());
    }
    if (_textLike.contains(name)) return _arg();
    final mark = _combining[name];
    if (mark != null) {
      final a = _arg();
      if (a.runes.length != 1) throw const _Unsupported();
      return '$a$mark';
    }
    final symbol = _symbols[name];
    if (symbol != null) return symbol;
    if (_functions.contains(name)) {
      // "sin x" and "sin θ" need their space; "sin²θ" and "sin(x)" do not.
      final next = i < s.length ? s[i] : '';
      return next.isNotEmpty && (_isLetter(next) || next == r'\' || next == '{') ? '$name ' : name;
    }
    throw const _Unsupported();
  }

  String _script(bool up) {
    // Straight after the mark: a degree sign or a prime is written on its own, with no caret.
    final arg = _arg().trim();
    if (up && (arg == '°' || arg == '′' || arg == '″')) return arg;
    final table = up ? _super : _sub;
    final chars = arg.replaceAll(' ', '').split('');
    if (chars.isNotEmpty && chars.every(table.containsKey)) return chars.map((c) => table[c]!).join();
    final mark = up ? '^' : '_';
    if (arg.isEmpty) return '';
    if (RegExp(r'^[A-Za-z0-9]+$').hasMatch(arg) && (up ? arg.length == 1 : true)) return '$mark$arg';
    return '$mark($arg)';
  }

  String _fraction(String a, String b) {
    final top = a.trim();
    final bottom = b.trim();
    final v = _vulgar['$top/$bottom'];
    if (v != null) return v;
    return '${_wrapped(top)}/${_wrapped(bottom)}';
  }

  String _root(String? index, String arg) {
    final inside = arg.trim();
    final body = RegExp(r'^[\p{L}\p{N}.°²³]+$', unicode: true).hasMatch(inside) ? inside : _wrapped(inside, force: true);
    return switch (index) {
      null || '2' || '' => '√$body',
      '3' => '∛$body',
      '4' => '∜$body',
      final n => '${n.split('').map((c) => _super[c] ?? c).join()}√$body',
    };
  }

  /// [x] in brackets when it is more than one thing (a sum, a product), unless it already is.
  String _wrapped(String x, {bool force = false}) {
    if (x.isEmpty) return x;
    if (_inBrackets(x)) return x;
    if (!force && !RegExp(r'[\s+\-−×÷·/]').hasMatch(x)) return x;
    return '($x)';
  }

  /// Whether the opening bracket at the start of [x] closes at its very end.
  bool _inBrackets(String x) {
    if (!x.startsWith('(') || !x.endsWith(')')) return false;
    var depth = 0;
    for (var k = 0; k < x.length; k++) {
      if (x[k] == '(') depth++;
      if (x[k] == ')') depth--;
      if (depth == 0 && k < x.length - 1) return false;
    }
    return depth == 0;
  }
}
