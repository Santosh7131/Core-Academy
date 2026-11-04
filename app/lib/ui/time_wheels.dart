// Any time of day, picked on wheels: the hour, the minute and am or pm. It replaces the lists of half hours, which could not say 8:10 or
// 4:45 and stopped at 5:00 am and 11:30 pm.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'kit.dart';

/// A card with the time on wheels. Returns the minutes after midnight (0 to 1439) when Done is tapped, and null when the card is
/// closed without it.
Future<int?> pickTimeOfDay(BuildContext context, {required String title, required int minutes}) => showCentredCard<int>(
      context,
      title: title,
      builder: (ctx) => TimeWheels(minutes: minutes, onDone: (m) => Navigator.of(ctx).pop(m)),
    );

/// The three wheels, the hour (1 to 12), the minute (00 to 59) and am or pm, with Done under them. The row in the middle is the time.
class TimeWheels extends StatefulWidget {
  const TimeWheels({super.key, required this.minutes, required this.onDone});

  /// Where the wheels start, in minutes after midnight.
  final int minutes;
  final ValueChanged<int> onDone;

  /// The wheels, so a test can turn them.
  static const hourKey = ValueKey<String>('time-hour');
  static const minuteKey = ValueKey<String>('time-minute');
  static const ampmKey = ValueKey<String>('time-ampm');

  @override
  State<TimeWheels> createState() => _TimeWheelsState();
}

class _TimeWheelsState extends State<TimeWheels> {
  late final int _start = widget.minutes.clamp(0, 24 * 60 - 1).toInt();

  /// 0 to 11, and the wheel shows 0 as 12: 12:30 am and 12:30 pm are both hour 0, told apart by am or pm.
  late int _hour = (_start ~/ 60) % 12;
  late int _minute = _start % 60;
  late int _pm = _start >= 12 * 60 ? 1 : 0;

  late final _hours = FixedExtentScrollController(initialItem: _hour);
  late final _minutes = FixedExtentScrollController(initialItem: _minute);
  late final _ampm = FixedExtentScrollController(initialItem: _pm);

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    _ampm.dispose();
    super.dispose();
  }

  int get _value => (_hour + 12 * _pm) * 60 + _minute;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(24) / 24;
    // Five rows show the numbers either side of the one chosen; large text makes a row tall, so three then.
    final rows = scale > 1.35 ? 3 : 5;
    final extent = math.max(46.0, 24 * scale * 1.75);
    final digits = numStyle(size: 24, weight: FontWeight.w600);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: extent * rows,
        child: Stack(alignment: Alignment.center, children: [
          Container(height: extent, decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(rSmall))),
          Row(children: [
            Expanded(
              flex: 3,
              child: _Wheel(
                key: TimeWheels.hourKey,
                name: 'Hour',
                controller: _hours,
                extent: extent,
                count: 12,
                loops: true,
                selected: _hour,
                label: (i) => '${i == 0 ? 12 : i}',
                style: digits,
                align: Alignment.centerRight,
                onChanged: (i) => setState(() => _hour = i),
              ),
            ),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 5), child: Text(':', style: digits.copyWith(color: muted))),
            Expanded(
              flex: 3,
              child: _Wheel(
                key: TimeWheels.minuteKey,
                name: 'Minute',
                controller: _minutes,
                extent: extent,
                count: 60,
                loops: true,
                selected: _minute,
                label: (i) => i.toString().padLeft(2, '0'),
                style: digits,
                align: Alignment.centerLeft,
                onChanged: (i) => setState(() => _minute = i),
              ),
            ),
            Expanded(
              flex: 3,
              child: _Wheel(
                key: TimeWheels.ampmKey,
                name: 'am or pm',
                controller: _ampm,
                extent: extent,
                count: 2,
                loops: false,
                selected: _pm,
                label: (i) => i == 0 ? 'am' : 'pm',
                style: rowTitleStyle.copyWith(fontSize: 21),
                align: Alignment.center,
                onChanged: (i) => setState(() => _pm = i),
              ),
            ),
          ]),
        ]),
      ),
      const SizedBox(height: 20),
      PrimaryButton('Done', onTap: () => widget.onDone(_value)),
    ]);
  }
}

/// One wheel. A [loops] wheel has no end (after 59 comes 00); the others stop at their first and last. A tap on a number turns the
/// wheel to it, and a screen reader can step it up and down.
class _Wheel extends StatelessWidget {
  const _Wheel({
    super.key,
    required this.name,
    required this.controller,
    required this.extent,
    required this.count,
    required this.loops,
    required this.selected,
    required this.label,
    required this.style,
    required this.align,
    required this.onChanged,
  });

  final String name;
  final FixedExtentScrollController controller;
  final double extent;
  final int count;
  final bool loops;

  /// The number in the middle, 0 to [count] - 1.
  final int selected;
  final String Function(int) label;
  final TextStyle style;
  final Alignment align;
  final ValueChanged<int> onChanged;

  void _step(int by) => controller.animateToItem(controller.selectedItem + by, duration: const Duration(milliseconds: 180), curve: Curves.easeOutCubic);

  @override
  Widget build(BuildContext context) {
    final canUp = loops || selected < count - 1;
    final canDown = loops || selected > 0;
    return Semantics(
      container: true,
      label: name,
      value: label(selected),
      increasedValue: canUp ? label((selected + 1) % count) : null,
      decreasedValue: canDown ? label((selected - 1) % count) : null,
      onIncrease: canUp ? () => _step(1) : null,
      onDecrease: canDown ? () => _step(-1) : null,
      child: ExcludeSemantics(
        child: ListWheelScrollView.useDelegate(
          controller: controller,
          itemExtent: extent,
          physics: const FixedExtentScrollPhysics(),
          diameterRatio: 3,
          perspective: 0.0025,
          // The numbers either side of the middle one fade (the opacity only applies with the magnifier on, at its own size).
          useMagnifier: true,
          magnification: 1.0,
          overAndUnderCenterOpacity: 0.35,
          onSelectedItemChanged: (i) => onChanged(i % count),
          childDelegate: ListWheelChildBuilderDelegate(
            childCount: loops ? null : count,
            builder: (context, i) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => controller.animateToItem(i, duration: const Duration(milliseconds: 180), curve: Curves.easeOutCubic),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Align(
                  alignment: align,
                  child: FittedBox(fit: BoxFit.scaleDown, alignment: align, child: Text(label(i % count), style: style, maxLines: 1, softWrap: false)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
