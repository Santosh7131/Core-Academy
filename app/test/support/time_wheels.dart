// Turning the wheels of a time card that is open, for tests: a drag on a phone is the same as jumping the wheel to the number.
import 'package:core_academy/ui/time_wheels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FixedExtentScrollController _wheel(WidgetTester t, Key key) =>
    t.widget<ListWheelScrollView>(find.descendant(of: find.byKey(key), matching: find.byType(ListWheelScrollView))).controller! as FixedExtentScrollController;

/// Turns a wheel that goes round to [target] (0 to [count] - 1), by the shortest way down from where it is.
void _turn(FixedExtentScrollController c, int count, int target) => c.jumpToItem(c.selectedItem - c.selectedItem % count + target);

/// Turns the open card's wheels to [hour] (0 to 23) and [minute]. It does not tap Done.
void turnWheels(WidgetTester t, int hour, [int minute = 0]) {
  _turn(_wheel(t, TimeWheels.hourKey), 12, hour % 12);
  _turn(_wheel(t, TimeWheels.minuteKey), 60, minute);
  _wheel(t, TimeWheels.ampmKey).jumpToItem(hour >= 12 ? 1 : 0);
}

/// The time the wheels show now, in minutes after midnight.
int wheelsShow(WidgetTester t) {
  final hour = _wheel(t, TimeWheels.hourKey).selectedItem % 12;
  final minute = _wheel(t, TimeWheels.minuteKey).selectedItem % 60;
  final pm = _wheel(t, TimeWheels.ampmKey).selectedItem;
  return (hour + 12 * pm) * 60 + minute;
}
