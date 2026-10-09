import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';

class TestIntroScreen extends StatefulWidget {
  const TestIntroScreen({super.key, required this.testId});
  final String testId;

  @override
  State<TestIntroScreen> createState() => _TestIntroScreenState();
}

class _TestIntroScreenState extends State<TestIntroScreen> {
  Map<String, dynamic>? _test;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await api.get('/student/home');
      final t = (r['tests'] as List).cast<Map<String, dynamic>>().where((x) => x['id'] == widget.testId);
      setState(() => _test = t.isEmpty ? null : t.first);
      if (t.isEmpty) setState(() => _error = 'This test is no longer available.');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _test;
    if (t == null) {
      return PushedPanel(title: 'Test', children: [
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(),
      ]);
    }
    final closes = f.parseTime(t['closes_at']);
    final opens = f.parseTime(t['opens_at']);
    final limit = t['time_limit_min'] as int?;
    final state = t['state'] as String;
    final canStart = state == 'open' || state == 'in_progress';
    final timed = limit != null || closes != null;

    Widget fact(String label, String value) => Padding(
          padding: const EdgeInsets.fromLTRB(17, 14, 17, 14),
          child: Row(children: [
            Expanded(child: Text(label, style: bodyStyle.copyWith(color: muted))),
            Fig(value, style: rowTitleStyle),
          ]),
        );
    Widget rule(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: muted),
            const SizedBox(width: 12),
            Expanded(child: Fig(text, style: bodyStyle)),
          ]),
        );

    return PushedPanel(
      kicker: 'Class ${t['class_level']} · ${f.count(t['question_count'] as int, 'question')}',
      title: '${t['title']}',
      footer: PrimaryButton(
        state == 'in_progress' ? 'Continue test' : 'Start test',
        icon: Ph.arrowRight,
        onTap: canStart ? () => context.pushReplacement('/s/write/${widget.testId}') : null,
        disabledReason: switch (state) {
          'upcoming' => 'This test opens ${opens == null ? 'later' : f.when(opens)}.',
          'missed' => 'This test has closed.',
          'done' => 'You have already written this test.',
          _ => null,
        },
      ),
      children: [
        const SizedBox(height: 22),
        Surface(
          shadow: e1,
          child: Column(children: [
            fact('Time limit', limit == null ? 'None' : '$limit min'),
            Container(height: 1, margin: const EdgeInsets.only(left: 17), color: hairline),
            fact('Marks', f.marks(t['max_marks'])),
            if (closes != null) ...[
              Container(height: 1, margin: const EdgeInsets.only(left: 17), color: hairline),
              fact('Closes', f.when(closes)),
            ],
          ]),
        ),
        const SectionRule('Before you start', padding: EdgeInsets.fromLTRB(0, 26, 0, 14)),
        rule(
          Ph.eyeSlash,
          closes == null
              ? 'You will see your marks and the right answers as soon as you submit.'
              : 'Your marks and the right answers show after ${f.when(closes)}, or earlier once everyone has finished.',
        ),
        rule(Ph.check, 'Every answer is saved as you choose it, even if the app closes.'),
        if (timed) rule(Ph.timer, 'When the time runs out, the test is submitted for you.'),
        rule(Ph.flag, 'Flag a question to come back to it before you submit.'),
      ],
    );
  }
}
