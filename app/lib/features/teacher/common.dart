import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';

const classLevels = [6, 7, 8, 9, 10, 11, 12];

/// Header for a teacher tab: kicker, one display line, trailing actions.
class TabHeader extends StatelessWidget {
  const TabHeader({super.key, required this.kicker, required this.title, this.actions = const []});
  final String kicker;
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Kicker(kicker),
              const SizedBox(height: 6),
              Fig(title, style: displayStyle, maxLines: 1),
            ]),
          ),
          for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 10), a],
        ]),
      );
}

/// A horizontally scrolling row of segmented chips that bleeds to the screen edge.
class ChipRow extends StatelessWidget {
  const ChipRow({super.key, required this.children, this.padding = const EdgeInsets.symmetric(horizontal: gutter)});
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        clipBehavior: Clip.none,
        child: Row(children: [
          for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(width: 8), c],
        ]),
      );
}

class ClassChips extends StatelessWidget {
  const ClassChips({super.key, required this.value, required this.onChanged, this.allowAll = false, this.padding = const EdgeInsets.symmetric(horizontal: gutter)});
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool allowAll;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ChipRow(padding: padding, children: [
        if (allowAll) SegChip('All classes', selected: value == null, onTap: () => onChanged(null)),
        for (final c in classLevels) SegChip('Class $c', selected: value == c, onTap: () => onChanged(c)),
      ]);
}

/// Label above a form group, small and muted (not a labelled form box).
class FormLabel extends StatelessWidget {
  const FormLabel(this.text, {super.key, this.top = 22});
  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: top, bottom: 10),
        child: Text(text, style: labelStyle),
      );
}

/// Picks a day and a time with chips: no dialogs, so nothing animates in.
class DayTimeChooser extends StatelessWidget {
  const DayTimeChooser({super.key, required this.value, required this.onChanged, this.noneLabel, this.days = 14});

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  /// When set, a first chip that clears the value ("Now", "No closing time").
  final String? noneLabel;
  final int days;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final day0 = DateTime(today.year, today.month, today.day);
    final selDay = value == null ? null : DateTime(value!.year, value!.month, value!.day);
    final selMinutes = value == null ? null : value!.hour * 60 + value!.minute;
    String dayLabel(int i) {
      if (i == 0) return 'Today';
      if (i == 1) return 'Tomorrow';
      return DateFormat('EEE d').format(day0.add(Duration(days: i)));
    }

    // 6:00 am to 9:30 pm in half hours.
    final times = [for (var m = 6 * 60; m <= 21 * 60 + 30; m += 30) m];
    String timeLabel(int m) => DateFormat('h:mm a').format(DateTime(2000, 1, 1, m ~/ 60, m % 60)).toLowerCase();

    void pick({DateTime? dayValue, int? minutes}) {
      final d = dayValue ?? selDay ?? day0;
      final m = minutes ?? selMinutes ?? 18 * 60;
      onChanged(DateTime(d.year, d.month, d.day, m ~/ 60, m % 60));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ChipRow(padding: EdgeInsets.zero, children: [
        if (noneLabel != null) SegChip(noneLabel!, selected: value == null, onTap: () => onChanged(null)),
        for (var i = 0; i < days; i++)
          SegChip(dayLabel(i), selected: selDay == day0.add(Duration(days: i)), onTap: () => pick(dayValue: day0.add(Duration(days: i)))),
      ]),
      if (value != null) ...[
        const SizedBox(height: 8),
        ChipRow(padding: EdgeInsets.zero, children: [
          for (final m in times) SegChip(timeLabel(m), selected: selMinutes == m, onTap: () => pick(minutes: m)),
        ]),
      ],
    ]);
  }
}

String loginMessage(String name, String username, String pin) =>
    '${session.tuitionName} login for $name\n'
    'Username: $username\n'
    'PIN: $pin\n'
    'Open the ${session.tuitionName} app and log in with these.';

/// The login card shown after creating a student or resetting a PIN.
Future<void> showLoginCard(BuildContext context, {required String name, required String username, required String pin}) {
  return showCentredCard<void>(
    context,
    title: 'Login for ${name.split(' ').first}',
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Surface(
        shadow: e1,
        color: fill,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Username', style: labelStyle),
          const SizedBox(height: 4),
          Text(username, style: numStyle(size: 22, weight: FontWeight.w600)),
          const SizedBox(height: 14),
          Text('PIN', style: labelStyle),
          const SizedBox(height: 4),
          Text(pin, style: numStyle(size: 30, weight: FontWeight.w700).copyWith(letterSpacing: 6)),
        ]),
      ),
      const SizedBox(height: 12),
      Fig('Share it with the student or a parent. You can reset the PIN at any time.', style: bodyStyle.copyWith(color: muted)),
      const SizedBox(height: 18),
      Row(children: [
        Expanded(
          child: SecondaryButton('Copy', icon: Ph.copy, onTap: () {
            Clipboard.setData(ClipboardData(text: loginMessage(name, username, pin)));
          }),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: PrimaryButton('Share', icon: Ph.shareNetwork, onTap: () {
            SharePlus.instance.share(ShareParams(text: loginMessage(name, username, pin)));
          }),
        ),
      ]),
    ]),
  );
}

/// Shows an API problem in a centred card.
Future<void> showProblem(BuildContext context, Object e) => showCentredCard<void>(
      context,
      title: 'That did not work',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Fig(e is ApiException ? e.message : 'Something went wrong. Please try again.', style: bodyStyle),
        const SizedBox(height: 18),
        PrimaryButton('OK', onTap: () => Navigator.of(ctx).pop()),
      ]),
    );

/// A read-only fact list inside one surface.
class FactList extends StatelessWidget {
  const FactList(this.facts, {super.key});
  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) => Surface(
        shadow: e1,
        child: Column(children: [
          for (final (i, (label, value)) in facts.indexed) ...[
            if (i > 0) Container(height: 1, margin: const EdgeInsets.only(left: 17), color: hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(17, 14, 17, 14),
              child: Row(children: [
                Text(label, style: bodyStyle.copyWith(color: muted)),
                const SizedBox(width: 16),
                Expanded(child: Fig(value, style: rowTitleStyle, textAlign: TextAlign.right)),
              ]),
            ),
          ],
        ]),
      );
}

/// Bottom spacing so the last row clears the floating navigation.
const navClearance = SizedBox(height: 110);
