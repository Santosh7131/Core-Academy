import 'package:flutter/material.dart';

import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';

/// The test to write now, with its one button. On the home screen and on a course's page.
class TestHero extends StatelessWidget {
  const TestHero({super.key, required this.test, required this.onStart});
  final Map<String, dynamic> test;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final resume = test['state'] == 'in_progress';
    final closes = f.parseTime(test['closes_at']);
    final deadline = f.parseTime(test['attempt']?['deadline_at']);
    final soon = closes != null && closes.difference(DateTime.now()).inHours < 3;
    final limit = test['time_limit_min'] as int?;
    final facts = [
      f.count(test['question_count'] as int, 'question'),
      if (limit != null) '$limit min',
      if (!resume && closes != null) 'closes ${f.time(closes)}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      decoration: surface(radius: rHero, shadow: e3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Kicker(resume ? 'Under way' : 'Open now'),
          const Spacer(),
          if (resume && deadline != null)
            TagChip('Ends ${f.time(deadline)}', tone: Tone.warning)
          else if (closes != null)
            TagChip('${f.left(closes)} left', tone: soon ? Tone.warning : Tone.neutral),
        ]),
        const SizedBox(height: 14),
        Fig('${test['title']}', style: titleStyle, maxLines: 2),
        const SizedBox(height: 9),
        Fig(facts, style: labelStyle.copyWith(fontSize: 12.5), numColor: ink),
        const SizedBox(height: 20),
        PrimaryButton(resume ? 'Continue test' : 'Start test', icon: Ph.arrowRight, onTap: onStart),
      ]),
    );
  }
}

/// Nothing to write right now: says so, and when the next test opens if there is one.
class AllCaughtUp extends StatelessWidget {
  const AllCaughtUp({super.key, this.next});
  final Map<String, dynamic>? next;

  @override
  Widget build(BuildContext context) {
    final opens = next == null ? null : f.parseTime(next!['opens_at']);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
      decoration: surface(radius: rHero, shadow: e3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: successSoft, shape: BoxShape.circle),
          child: Icon(Ph.check, size: 22, color: success),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Nothing to write now', style: sectionStyle),
            const SizedBox(height: 4),
            Fig(
              next == null ? 'Your next test shows up here.' : '${next!['title']} opens ${opens == null ? 'soon' : f.when(opens)}.',
              style: labelStyle.copyWith(fontSize: 12.5),
              maxLines: 2,
            ),
          ]),
        ),
      ]),
    );
  }
}

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
