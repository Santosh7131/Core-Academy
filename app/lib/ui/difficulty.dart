import 'package:flutter/material.dart';

import '../theme.dart';
import 'kit.dart';
import 'tokens.dart';

// How hard a question is: easy, medium or hard (the tutor sees it as the question's "level"; a class is a different kind of level, see
// core/levels.dart). Every question has one. AI sets it when it reads or writes the question, and it is Medium when AI could not tell or
// nobody said (a question typed by hand, or one from before this existed). Only the tutor sees it, never a student.

/// The three levels of difficulty, easiest first. The names are what the server stores.
enum Difficulty {
  easy('Easy'),
  medium('Medium'),
  hard('Hard');

  const Difficulty(this.label);
  final String label;
}

/// The difficulty a question carries: what the server sent, or Medium when it sent none.
Difficulty difficultyOf(Object? value) => switch ('$value'.trim().toLowerCase()) {
      'easy' => Difficulty.easy,
      'hard' => Difficulty.hard,
      _ => Difficulty.medium,
    };

/// Whether AI chose this question's difficulty and the tutor has not looked at it yet: it is shown in the AI colour until she agrees or
/// picks another.
bool aiChose(Map<String, dynamic> question) => question['difficulty_by'] == 'ai';

/// How many of the questions are at each difficulty.
Map<Difficulty, int> difficultyCounts(Iterable<Map<String, dynamic>> questions) {
  final out = {for (final d in Difficulty.values) d: 0};
  for (final q in questions) {
    out.update(difficultyOf(q['difficulty']), (n) => n + 1);
  }
  return out;
}

/// "6 easy · 9 medium · 5 hard": the mix of a set of questions, leaving out a level that has none. Empty for no questions.
String difficultyMix(Iterable<Map<String, dynamic>> questions) {
  final counts = difficultyCounts(questions);
  return [for (final d in Difficulty.values) if (counts[d]! > 0) '${counts[d]} ${d.label.toLowerCase()}'].join(' · ');
}

/// A difficulty as a small chip: a ladder of bars with as many filled as the level is high, and its name. Plain for the tutor's own
/// choice, in the AI colour while it is AI's guess.
class DifficultyChip extends StatelessWidget {
  const DifficultyChip(this.difficulty, {super.key, this.ai = false});
  final Difficulty difficulty;
  final bool ai;

  @override
  Widget build(BuildContext context) {
    final fg = ai ? aiAccentInk : ink;
    return Semantics(
      label: ai ? '${difficulty.label}, chosen by AI' : difficulty.label,
      excludeSemantics: true,
      child: Container(
        // 24 high at the usual text size, and taller when the phone's text is larger, so the word is never cut off.
        constraints: const BoxConstraints(minHeight: 24),
        padding: const EdgeInsets.fromLTRB(8, 2, 10, 2),
        decoration: BoxDecoration(color: ai ? aiAccentSoft : fill, borderRadius: BorderRadius.circular(rPill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _Bars(difficulty.index + 1, color: fg),
          const SizedBox(width: 6),
          Flexible(child: Text(difficulty.label, style: tagStyle.copyWith(fontSize: 11, color: fg, letterSpacing: -0.1), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
      ),
    );
  }
}

/// Three bars of rising height, the first [filled] of them solid and the rest faint.
class _Bars extends StatelessWidget {
  const _Bars(this.filled, {required this.color});
  final int filled;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 11,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Container(
              width: 3,
              height: const [5.0, 8.0, 11.0][i],
              decoration: BoxDecoration(color: color.withValues(alpha: i < filled ? 1 : 0.28), borderRadius: BorderRadius.circular(2)),
            ),
          ],
        ]),
      );
}

/// "How hard is it?" as a field: the difficulty as a chip, and a caret; a tap opens the three levels. While [aiChose] is true a line under
/// it says AI chose the level and that the tutor can pick another. [onPicked] hears the one she picked, even when it is the one shown (she
/// agreed).
class DifficultyField extends StatelessWidget {
  const DifficultyField({super.key, required this.difficulty, required this.aiChose, required this.onPicked});
  final Difficulty difficulty;
  final bool aiChose;
  final ValueChanged<Difficulty> onPicked;

  Future<void> _choose(BuildContext context) async {
    final c = await showChoices<Difficulty>(
      context,
      title: 'How hard is it?',
      options: [for (final d in Difficulty.values) Choice(d, d.label)],
      selected: difficulty,
    );
    if (c?.value != null) onPicked(c!.value!);
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Pressable(
          label: 'How hard is it? ${difficulty.label}',
          onTap: () => _choose(context),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
            decoration: surface(radius: 15, shadow: e1),
            child: Row(children: [
              DifficultyChip(difficulty, ai: aiChose),
              const Spacer(),
              Icon(Ph.caretDown, size: 15, color: faint),
            ]),
          ),
        ),
        if (aiChose) ...[
          const SizedBox(height: 9),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Ph.sparkle, size: 15, color: aiAccentInk),
            const SizedBox(width: 8),
            Expanded(
              child: Fig(
                'AI guessed this from the question. Pick another level if you disagree.',
                style: labelStyle.copyWith(color: aiAccentInk, fontWeight: FontWeight.w600, fontSize: 12, height: 1.42),
              ),
            ),
          ]),
        ],
      ]);
}
