import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';

const classLevels = [6, 7, 8, 9, 10, 11, 12];

/// Every test has a closing time (students see their marks after it), so a new one starts with
/// the next 9:00 pm that is at least three hours away.
DateTime defaultClosing() {
  final now = DateTime.now();
  var t = DateTime(now.year, now.month, now.day, 21);
  if (t.difference(now) < const Duration(hours: 3)) t = t.add(const Duration(days: 1));
  return t;
}

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

/// A short group of segmented chips that wraps onto the next line instead of scrolling
/// sideways. Long lists (classes, subjects, chapters, days) use a select instead.
class ChipRow extends StatelessWidget {
  const ChipRow({super.key, required this.children, this.padding = const EdgeInsets.symmetric(horizontal: gutter)});
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 8, runSpacing: 8, children: children)),
      );
}

Future<Choice<int>?> _pickClass(BuildContext context, int? value, {required bool allowAll}) => showChoices<int>(
      context,
      title: 'Class',
      options: [if (allowAll) const Choice(null, 'All classes'), for (final c in classLevels) Choice(c, 'Class $c')],
      selected: value,
    );

/// The class as a filter pill: "All classes" or "Class 9".
class ClassFilter extends StatelessWidget {
  const ClassFilter({super.key, required this.value, required this.onChanged, this.allowAll = true});
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool allowAll;

  @override
  Widget build(BuildContext context) => SelectPill(
        label: value == null ? 'All classes' : 'Class $value',
        active: value != null,
        onTap: () async {
          final c = await _pickClass(context, value, allowAll: allowAll);
          if (c != null) onChanged(c.value);
        },
      );
}

/// The class in a form.
class ClassField extends StatelessWidget {
  const ClassField({super.key, required this.value, required this.onChanged, this.enabled = true});
  final int? value;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SelectField(
        value: value == null ? null : 'Class $value',
        placeholder: 'Choose a class',
        onTap: !enabled
            ? null
            : () async {
                final c = await _pickClass(context, value, allowAll: false);
                if (c?.value != null) onChanged(c!.value!);
              },
      );
}

/// A chapter row from the API: {id, name, questions?}.
typedef ChapterRow = Map<String, dynamic>;

/// The chapter as a filter pill, for a class and subject that are already chosen.
class ChapterFilter extends StatelessWidget {
  const ChapterFilter({super.key, required this.chapters, required this.value, required this.onChanged, this.subtitle});
  final List<ChapterRow> chapters;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final current = chapters.where((c) => c['id'] == value).map((c) => '${c['name']}').firstOrNull;
    return SelectPill(
      label: current ?? 'All chapters',
      active: current != null,
      onTap: () async {
        final c = await showChoices<String>(
          context,
          title: 'Chapter',
          subtitle: subtitle,
          options: [
            const Choice(null, 'All chapters'),
            for (final ch in chapters) Choice('${ch['id']}', '${ch['name']}', count: ch['questions'] as int?),
          ],
          selected: value,
        );
        if (c != null) onChanged(c.value);
      },
    );
  }
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

/// Picks a day and a time with two selects side by side.
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

    // A value from before the 14-day window, or not on a half hour, still shows as itself.
    String? currentDay() {
      if (selDay == null) return noneLabel;
      final i = selDay.difference(day0).inDays;
      return i >= 0 && i < days ? dayLabel(i) : DateFormat('EEE d MMM').format(selDay);
    }

    return Row(children: [
      Expanded(
        child: SelectField(
          value: currentDay(),
          placeholder: 'Day',
          onTap: () async {
            final c = await showChoices<int>(
              context,
              title: 'Day',
              options: [if (noneLabel != null) Choice(-1, noneLabel!), for (var i = 0; i < days; i++) Choice(i, dayLabel(i))],
              selected: selDay == null ? (noneLabel != null ? -1 : null) : selDay.difference(day0).inDays,
            );
            if (c == null) return;
            if (c.value == -1) {
              onChanged(null);
            } else {
              pick(dayValue: day0.add(Duration(days: c.value!)));
            }
          },
        ),
      ),
      if (value != null) ...[
        const SizedBox(width: 10),
        Expanded(
          child: SelectField(
            value: timeLabel(selMinutes!),
            onTap: () async {
              final c = await showChoices<int>(context, title: 'Time', options: [for (final m in times) Choice(m, timeLabel(m))], selected: selMinutes);
              if (c?.value != null) pick(minutes: c!.value);
            },
          ),
        ),
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

/// Bottom spacing on a tab with a [FloatingAdd]: clears the tab bar and the button above it.
const fabClearance = SizedBox(height: 180);
