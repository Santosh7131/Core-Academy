import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import 'result_data.dart';

/// Marks straight after submitting, then the questions that went wrong first (that is what there is
/// to learn from), with the right ones folded away underneath.
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
  bool _rightOpen = false;

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
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(rows: 3),
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
                ? 'Your test is in. Your marks show once everyone has finished.'
                : 'Your test is in. Your marks and the right answers show after ${f.when(at)}, or sooner once everyone has finished.',
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
    final missed = [for (final item in review) if (outcomeOf(item) != Outcome.correct) item];
    final right = [for (final item in review) if (outcomeOf(item) == Outcome.correct) item];
    final open = _rightOpen || missed.isEmpty;

    Widget row(Map<String, dynamic> item) => RowTile(
          leading: OutcomeRing(outcomeOf(item)),
          titleWidget: MathText('${item['text']}', style: rowTitleStyle, maxLines: 2),
          meta: _metaFor(item),
          chevron: true,
          onTap: () => context.push('$reviewPath?n=${item['n']}'),
        );

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
        Reveal(
          child: _ScoreCard(
            label: widget.teacher ? 'Marks' : 'Your marks',
            score: score,
            max: max,
            note: '${f.percent(max > 0 ? score / max : null)} · ${a['correct']} right, ${a['wrong']} wrong'
                '${(a['skipped'] as num? ?? 0) > 0 ? ', ${a['skipped']} skipped' : ''}'
                '${a['time_taken_sec'] == null ? '' : ' · ${f.duration(a['time_taken_sec'] as int)}'}',
          ),
        ),
        if (missed.isNotEmpty) ...[
          const SizedBox(height: 14),
          PrimaryButton(
            widget.teacher ? 'See the ${f.count(missed.length, 'miss', 'misses')}' : 'Review the ${missed.length} you missed',
            icon: Ph.arrowRight,
            onTap: () => context.push('$reviewPath?n=${missed.first['n']}'),
          ),
          SectionRule(widget.teacher ? 'Wrong or skipped' : 'To review', count: missed.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
          for (final (i, item) in missed.indexed) ...[if (i > 0) const SizedBox(height: gapRow), row(item)],
        ] else ...[
          const SizedBox(height: 14),
          InlineNotice(widget.teacher ? 'Every answer was right.' : 'Every answer was right. Well done.', tone: Tone.success, icon: Ph.checkCircle),
        ],
        if (right.isNotEmpty) ...[
          SectionRule('Right', count: right.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
          Pressable(
            onTap: missed.isEmpty ? null : () => setState(() => _rightOpen = !_rightOpen),
            child: Container(
              padding: const EdgeInsets.fromLTRB(17, 15, 15, 15),
              decoration: surface(radius: rCard, shadow: e1),
              child: Row(children: [
                const OutcomeRing(Outcome.correct),
                const SizedBox(width: 14),
                Expanded(child: Text(f.count(right.length, 'right answer'), style: rowTitleStyle)),
                if (missed.isNotEmpty) Icon(open ? Ph.caretUp : Ph.caretDown, size: 16, color: faint),
              ]),
            ),
          ),
          AnimatedSize( // motion: approved
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: open
                ? Padding(
                    padding: const EdgeInsets.only(top: gapRow),
                    child: Column(children: [for (final (i, item) in right.indexed) ...[if (i > 0) const SizedBox(height: gapRow), row(item)]]),
                  )
                : const SizedBox(width: double.infinity),
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

/// The marks: one big figure that counts up, a bar that fills, one line of detail.
class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.label, required this.score, required this.max, required this.note});
  final String label;
  final num score;
  final num max;
  final String note;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 17),
        decoration: surface(radius: rHero, shadow: e3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: labelStyle),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            CountUp(
              value: score.toDouble(),
              builder: (context, v) => Text(score == score.roundToDouble() ? '${v.round()}' : f.marks(v), style: numStyle(size: 52)),
            ),
            const SizedBox(width: 6),
            Text('/ ${f.marks(max)}', style: numStyle(size: 18, weight: FontWeight.w600, color: muted)),
          ]),
          const SizedBox(height: 15),
          Track(max > 0 ? score / max : 0),
          const SizedBox(height: 11),
          Fig(note, style: bodyStyle.copyWith(color: muted), numColor: body),
        ]),
      );
}
