import 'package:flutter/material.dart';

import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';

/// The card between the home screen and a test: how big it is, when the marks show, one button.
/// Returns true when the student taps Start.
Future<bool> confirmStart(BuildContext context, Map<String, dynamic> t) async {
  final limit = t['time_limit_min'] as int?;
  final closes = f.parseTime(t['closes_at']);
  final facts = [
    f.count(t['question_count'] as int, 'question'),
    if (limit != null) '$limit min',
    '${f.marks(t['max_marks'] as num?)} marks',
  ].join(' · ');
  final ok = await showCentredCard<bool>(
    context,
    title: '${t['title']}',
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Fig(facts, style: labelStyle.copyWith(fontSize: 12.5), numColor: ink),
      const SizedBox(height: 16),
      Fig(
        limit == null ? 'There is no time limit. Every answer is saved as you choose it.' : 'The timer starts when you tap Start. Every answer is saved as you choose it.',
        style: bodyStyle,
      ),
      const SizedBox(height: 8),
      Fig(
        closes == null ? 'You see your marks as soon as you submit.' : 'Your marks show after ${f.when(closes)}, or sooner once everyone has finished.',
        style: bodyStyle,
      ),
      const SizedBox(height: 22),
      PrimaryButton('Start test', icon: Ph.arrowRight, onTap: () => Navigator.of(ctx).pop(true)),
    ]),
  );
  return ok ?? false;
}
