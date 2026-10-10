import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart' as f;
import '../theme.dart';
import 'kit.dart';

// The main app's screen helpers (app/lib/features/teacher/common.dart), for the admin screens,
// plus the two small things only the admin app needs: a bar chart and a version tag.

/// A tab's header: kicker, one display line, optional actions at the right.
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

/// Bottom spacing so the last row clears the floating navigation.
const navClearance = SizedBox(height: 110);

/// Rows in one list with the main app's row gap.
class Rows extends StatelessWidget {
  const Rows(this.children, {super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        child: Column(children: [
          for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: gapRow), c],
        ]),
      );
}

/// A small bar chart in the measurement card's colours: one bar per value, with optional
/// labels centred under the bars they name (the key is the bar's index).
class Bars extends StatelessWidget {
  const Bars(this.values, {super.key, this.height = 56, this.labels = const {}});
  final List<double> values;
  final double height;
  final Map<int, String> labels;

  Widget _slots(Widget Function(int i, double v) slot) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final (i, v) in values.indexed) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(child: slot(i, v)),
        ],
      ]);

  @override
  Widget build(BuildContext context) {
    final top = values.fold<double>(0, (a, v) => v > a ? v : a);
    final bars = SizedBox(
      height: height,
      child: _slots((i, v) => Container(
            height: top <= 0 || v <= 0 ? 3 : (v / top * height).clamp(3, height).toDouble(),
            decoration: BoxDecoration(color: v > 0 ? measureFill : fill, borderRadius: BorderRadius.circular(3)),
          )),
    );
    if (labels.isEmpty) return bars;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      bars,
      const SizedBox(height: 6),
      SizedBox(
        height: 14,
        child: _slots((i, _) => labels[i] == null
            ? const SizedBox()
            : OverflowBox(
                minWidth: 0,
                maxWidth: 80,
                child: Fig(labels[i]!, maxLines: 1, style: labelStyle.copyWith(fontSize: 11, color: faint)),
              )),
      ),
    ]);
  }
}

/// An app version as a tag: success when it is the newest release, warning when behind.
Widget versionTag(String? version, String? newest) {
  if (version == null || version == 'older' || version == 'unknown') return TagChip(version == null ? 'no phone' : '1.2.0 or older');
  // A build newer than the latest release is a test build, not one that is behind.
  return TagChip(version, tone: newest == null || f.compareVersions(version, newest) > 0 ? Tone.neutral : (version == newest ? Tone.success : Tone.warning));
}
