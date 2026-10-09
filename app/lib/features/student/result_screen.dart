import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import 'result_data.dart';

/// Marks straight after submitting, then every question with its marking.
class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.attemptId, this.autoSubmitted = false, this.teacher = false});
  final String attemptId;
  final bool autoSubmitted;
  final bool teacher;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await loadResult(widget.attemptId, teacher: widget.teacher, fresh: true);
      if (mounted) setState(() => _data = d);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(widget.teacher ? '/t' : '/s');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) {
      return PushedPanel(title: 'Result', onBack: _back, children: [
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(),
      ]);
    }
    // Submitted, but the marks are not open yet: they open when the test closes, once everyone has
    // finished, or when the tutor shows them.
    if (d['waiting'] == true) {
      final at = f.parseTime(d['results_at']);
      return PushedPanel(
        onBack: _back,
        kicker: 'Submitted',
        title: '${d['title']}',
        children: [
          const SizedBox(height: 22),
          InlineNotice(
            at == null
                ? 'Your test is submitted. Your marks show once everyone has finished.'
                : 'Your test is submitted. Your marks and the right answers show after ${f.when(at)}, or earlier once everyone has finished.',
            tone: Tone.success,
            icon: Ph.checkCircle,
          ),
          const SizedBox(height: 18),
          SecondaryButton('Check again', icon: Ph.arrowsClockwise, onTap: _load),
          const SizedBox(height: 10),
          PrimaryButton('Back to my tests', onTap: _back),
        ],
      );
    }
    final a = d['attempt'] as Map<String, dynamic>;
    final review = (d['review'] as List).cast<Map<String, dynamic>>();
    final score = a['score'] as num? ?? 0;
    final max = a['max_score'] as num? ?? 0;
    final submitted = f.parseTime(a['submitted_at']);
    final auto = widget.autoSubmitted || a['auto_submitted'] == true;
    final reviewPath = widget.teacher ? '/t/attempts/${widget.attemptId}/review' : '/s/review/${widget.attemptId}';

    return PushedPanel(
      onBack: _back,
      kicker: [
        if (widget.teacher) '${a['student_name']}',
        if (submitted != null) 'Submitted ${f.when(submitted)}',
      ].join(' · '),
      title: '${a['title']}',
      children: [
        if (auto) ...[
          const SizedBox(height: 16),
          InlineNotice(widget.teacher ? 'Submitted automatically when the time ran out.' : 'Time was up, so your test was submitted for you.', icon: Ph.timer),
        ],
        const SizedBox(height: 22),
        MeasurementCard(
          label: widget.teacher ? 'Marks' : 'Your marks',
          value: f.marks(score),
          unit: '/ ${f.marks(max)}',
          fraction: max > 0 ? score / max : 0,
          note: '${f.percent(max > 0 ? score / max : null)} · ${a['correct']} right, ${a['wrong']} wrong, ${a['skipped']} skipped'
              '${a['time_taken_sec'] == null ? '' : ' · ${f.duration(a['time_taken_sec'] as int)}'}',
        ),
        SectionRule('Answers', count: review.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
        for (final (i, item) in review.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          RowTile(
            leading: OutcomeRing(outcomeOf(item)),
            titleWidget: MathText('${item['text']}', style: rowTitleStyle, maxLines: 2),
            meta: _metaFor(item),
            chevron: true,
            onTap: () => context.push('$reviewPath?n=${item['n']}'),
          ),
        ],
      ],
    );
  }

  String _metaFor(Map<String, dynamic> item) {
    final letters = 'ABCD';
    final correct = letters[item['correct'] as int];
    return switch (outcomeOf(item)) {
      Outcome.correct => 'Q${item['n']} · chose $correct, right',
      Outcome.wrong => 'Q${item['n']} · chose ${letters[item['chosen'] as int]}, right answer $correct',
      Outcome.skipped => 'Q${item['n']} · not answered, right answer $correct',
    };
  }
}
