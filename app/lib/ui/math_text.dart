import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

final _tex = RegExp(r'\$([^$]+)\$');
final _openingRun = RegExp(r'''[(\[{"'“‘-]+$''');
final _touchingRun = RegExp(r'^[^\s$]{1,12}');

/// Text with `$...$` LaTeX segments rendered inline. A formula that fails to parse
/// falls back to its source so a typo never blanks out a question.
class MathText extends StatelessWidget {
  const MathText(this.source, {super.key, required this.style, this.maxLines, this.textAlign = TextAlign.start, this.display = false});

  final String source;
  final TextStyle style;
  final int? maxLines;
  final TextAlign textAlign;

  /// Display style sets fractions full size; used for answer options so 3/5 is easy to read.
  final bool display;

  @override
  Widget build(BuildContext context) {
    final parts = <(bool, String)>[];
    var last = 0;
    for (final m in _tex.allMatches(source)) {
      if (m.start > last) parts.add((false, source.substring(last, m.start)));
      parts.add((true, m.group(1)!));
      last = m.end;
    }
    if (last < source.length) parts.add((false, source.substring(last)));

    // Normal weight keeps variables in math italic; a bold surrounding style would
    // otherwise switch KaTeX to upright bold letters.
    final mathStyle = style.copyWith(fontSize: (style.fontSize ?? 14) * 1.08, letterSpacing: 0, fontWeight: FontWeight.normal);
    final spans = <InlineSpan>[];
    for (var i = 0; i < parts.length; i++) {
      final (isMath, value) = parts[i];
      if (!isMath) {
        spans.add(TextSpan(text: value));
        continue;
      }
      // Characters touching the formula ("(", "4,", "y-axis?") go into the same piece:
      // the layout treats an embedded formula as a break point, so they would otherwise wrap apart.
      var lead = '';
      if (spans.isNotEmpty && spans.last is TextSpan) {
        final prev = (spans.last as TextSpan).text ?? '';
        final m = _openingRun.firstMatch(prev);
        if (m != null) {
          lead = m.group(0)!;
          spans[spans.length - 1] = TextSpan(text: prev.substring(0, m.start));
        }
      }
      var trail = '';
      if (i + 1 < parts.length && !parts[i + 1].$1) {
        final next = parts[i + 1].$2;
        final m = _touchingRun.firstMatch(next);
        if (m != null) {
          trail = m.group(0)!;
          parts[i + 1] = (false, next.substring(m.end));
        }
      }
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          if (lead.isNotEmpty) Text(lead, style: style),
          Math.tex(
            value,
            mathStyle: display ? MathStyle.display : MathStyle.text,
            textStyle: mathStyle,
            onErrorFallback: (_) => Text(value, style: style),
          ),
          if (trail.isNotEmpty) Text(trail, style: style),
        ]),
      ));
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      semanticsLabel: plainMath(source),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      textAlign: textAlign,
    );
  }
}

/// Plain text for screen readers: what a sighted student reads, without the LaTeX.
/// `$\frac{\sqrt{3}}{4}$` becomes "√3/4" and `$A = \{1, 2\}$` keeps its set braces.
String plainMath(String s) {
  var t = s.replaceAll(r'\{', _openSet).replaceAll(r'\}', _closeSet);
  t = t.replaceAllMapped(_command, (m) {
    final name = m[1]!;
    if (_structural.contains(name)) return m[0]!;
    return _commands[name] ?? name;
  });
  // Innermost groups first, so a root inside a fraction comes out whole.
  for (var before = ''; before != t;) {
    before = t;
    t = t
        .replaceAllMapped(_sqrt, (m) => '√${_group(m[1]!)}')
        .replaceAllMapped(_frac, (m) => '${_group(m[1]!)}/${_group(m[2]!)}')
        .replaceAllMapped(_bracedPower, (m) => _power(m[1]!));
  }
  return t
      .replaceAll(RegExp(r'\\sqrt\s*'), '√')
      .replaceAllMapped(RegExp(r'\^([0-9°])'), (m) => _power(m[1]!))
      .replaceAll(RegExp(r'\\[,;:! ]'), '')
      .replaceAll(RegExp(r'[\$\\{}]'), '')
      .replaceAll(_openSet, '{')
      .replaceAll(_closeSet, '}')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

const _openSet = '\uE000';
const _closeSet = '\uE001';
final _command = RegExp(r'\\([a-zA-Z]+)');
final _sqrt = RegExp(r'\\sqrt\{([^{}]*)\}');
final _frac = RegExp(r'\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}');
final _bracedPower = RegExp(r'\^\{([^{}]*)\}');
final _token = RegExp(r'^[\p{L}\p{N}√.°]+$', unicode: true);
const _structural = {'frac', 'dfrac', 'tfrac', 'sqrt'};
const _commands = {
  'times': '×', 'div': '÷', 'cdot': '·', 'pm': '±', 'circ': '°', 'degree': '°',
  'le': '≤', 'leq': '≤', 'ge': '≥', 'geq': '≥', 'ne': '≠', 'neq': '≠', 'approx': '≈',
  'pi': 'π', 'theta': 'θ', 'alpha': 'α', 'beta': 'β', 'infty': '∞',
  'cap': '∩', 'cup': '∪', 'in': '∈', 'ldots': '…', 'dots': '…', 'cdots': '…',
  'left': '', 'right': '', 'text': '', 'mathrm': '', 'displaystyle': '',
};

String _group(String x) {
  final t = x.trim();
  return _token.hasMatch(t) ? t : '($t)';
}

String _power(String p) => switch (p.trim()) {
      '2' => '²',
      '3' => '³',
      '°' => '°',
      final t => '^${_group(t)}',
    };
