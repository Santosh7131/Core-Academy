import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import '../../ui/tokens.dart';
import 'result_data.dart';

/// One question after marking: the student's choice, the correct option and the solution.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.attemptId, this.start = 1, this.teacher = false});
  final String attemptId;
  final int start;
  final bool teacher;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  List<Map<String, dynamic>>? _items;
  String? _error;
  late int _i = widget.start - 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await loadResult(widget.attemptId, teacher: widget.teacher);
      if (mounted) setState(() => _items = (d['review'] as List).cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) {
      return PushedPanel(title: 'Answer', children: [
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(),
      ]);
    }
    _i = _i.clamp(0, items.length - 1);
    final item = items[_i];
    final outcome = outcomeOf(item);
    final chosen = item['chosen'] as int?;
    final correct = item['correct'] as int;
    final who = widget.teacher ? 'Their' : 'Your';

    return PushedPanel(
      kicker: 'Question ${item['n']} of ${items.length}',
      title: switch (outcome) {
        Outcome.correct => 'Right',
        Outcome.wrong => 'Not right',
        Outcome.skipped => 'Not answered',
      },
      footer: Row(children: [
        Expanded(child: SecondaryButton('Previous', icon: Ph.arrowLeft, onTap: _i > 0 ? () => setState(() => _i--) : null)),
        const SizedBox(width: 10),
        Expanded(child: SecondaryButton('Next', icon: Ph.arrowRight, onTap: _i < items.length - 1 ? () => setState(() => _i++) : null)),
      ]),
      children: [
        const SizedBox(height: 22),
        MathText('${item['text']}', style: questionStyle),
        if (item['image_url'] != null) ...[
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(rSmall),
            child: Image.network('${item['image_url']}', errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ),
        ],
        const SizedBox(height: 22),
        for (final (i, o) in (item['options'] as List).cast<String>().indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          _ReviewOption(
            letter: 'ABCD'[i],
            text: o,
            isCorrect: i == correct,
            isChosen: i == chosen,
            note: i == correct
                ? (i == chosen ? '$who answer, right' : 'Right answer')
                : (i == chosen ? '$who answer' : null),
          ),
        ],
        if ((item['solution'] as String?)?.isNotEmpty == true) ...[
          const SectionRule('Solution', padding: EdgeInsets.fromLTRB(0, 26, 0, 11)),
          MathText('${item['solution']}', style: bodyStyle.copyWith(fontSize: 15, color: ink)),
        ],
      ],
    );
  }
}

class _ReviewOption extends StatelessWidget {
  const _ReviewOption({required this.letter, required this.text, required this.isCorrect, required this.isChosen, this.note});
  final String letter;
  final String text;
  final bool isCorrect;
  final bool isChosen;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final wrongChoice = isChosen && !isCorrect;
    return Container(
      padding: const EdgeInsets.fromLTRB(17, 13, 17, 13),
      constraints: const BoxConstraints(minHeight: 58),
      decoration: BoxDecoration(
        color: isCorrect ? successSoft : (wrongChoice ? dangerSoft : card),
        borderRadius: BorderRadius.circular(rCard),
        border: isDark && !isCorrect && !wrongChoice ? Border.all(color: hairline) : null,
        boxShadow: isCorrect || wrongChoice ? const [] : e1,
      ),
      child: Row(children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isCorrect ? success : null,
            border: isCorrect ? null : Border.all(color: wrongChoice ? danger : ringIdle, width: 1.8),
          ),
          child: Text(letter, style: tagStyle.copyWith(fontSize: 12, color: isCorrect ? Colors.white : (wrongChoice ? danger : muted))),
        ),
        const SizedBox(width: 14),
        Expanded(child: MathText(text, style: optionStyle, display: true)),
        if (note != null) ...[
          const SizedBox(width: 8),
          Text(note!, style: labelStyle.copyWith(color: isCorrect ? success : danger)),
        ],
      ]),
    );
  }
}
