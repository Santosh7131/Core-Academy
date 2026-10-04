import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/tokens.dart';

/// Results are fetched once per attempt and shared by the result and review screens.
final _cache = <String, Map<String, dynamic>>{};

Future<Map<String, dynamic>> loadResult(String attemptId, {bool teacher = false, bool fresh = false}) async {
  final key = '${teacher ? 't' : 's'}:$attemptId';
  if (!fresh && _cache[key] != null) return _cache[key]!;
  final r = await api.get(teacher ? '/teacher/attempts/$attemptId' : '/student/attempts/$attemptId/result');
  return _cache[key] = Map<String, dynamic>.from(r as Map);
}

enum Outcome { correct, wrong, skipped }

Outcome outcomeOf(Map<String, dynamic> item) =>
    item['chosen'] == null ? Outcome.skipped : (item['is_correct'] == true ? Outcome.correct : Outcome.wrong);

/// The completion ring (guide section 5) as a marking: filled success with a tick when
/// correct, a danger ring when wrong, an idle ring when skipped.
class OutcomeRing extends StatelessWidget {
  const OutcomeRing(this.outcome, {super.key, this.size = 21});
  final Outcome outcome;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: outcome == Outcome.correct ? success : null,
          border: outcome == Outcome.correct ? null : Border.all(color: outcome == Outcome.wrong ? danger : ringIdle, width: 1.8),
        ),
        child: switch (outcome) {
          Outcome.correct => Icon(Ph.check, size: size * 0.6, color: Colors.white),
          Outcome.wrong => Icon(Ph.x, size: size * 0.55, color: danger),
          Outcome.skipped => null,
        },
      );
}
