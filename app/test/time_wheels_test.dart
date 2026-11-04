// Any time of day on wheels: the hour, the minute and am or pm, in the card a tap on Opens, Closes or Time opens. The half-hour lists it
// replaced could not say 8:10 or 4:45 and stopped at 5:00 am and 11:30 pm.
//   flutter test test/time_wheels_test.dart
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/icons.dart';
import 'package:core_academy/ui/time_wheels.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/time_wheels.dart';

/// What the card handed back the last time it closed: null when it was closed without Done.
int? _picked;
var _closed = false;

/// A page with one button that opens the card at [minutes], on a phone [width] dp wide with the text at [scale].
Future<void> _open(WidgetTester t, {int minutes = 8 * 60, double width = 411, double scale = 1.0, bool dark = false}) async {
  setResolvedDark(dark);
  t.view.physicalSize = Size(width * 2.625, 900 * 2.625);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  _picked = null;
  _closed = false;
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(dark ? Brightness.dark : Brightness.light),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              _picked = await pickTimeOfDay(context, title: 'Opens', minutes: minutes);
              _closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

Future<void> _done(WidgetTester t) async {
  await t.tap(find.text('Done'));
  await t.pumpAndSettle();
}

void main() {
  group('the card', () {
    testWidgets('has the title, the three wheels and Done, and starts at the time it was given', (t) async {
      await _open(t, minutes: 8 * 60);
      expect(find.text('Opens'), findsOneWidget);
      expect(find.byKey(TimeWheels.hourKey), findsOneWidget);
      expect(find.byKey(TimeWheels.minuteKey), findsOneWidget);
      expect(find.byKey(TimeWheels.ampmKey), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(wheelsShow(t), 8 * 60);
    });

    testWidgets('starts at a time that is not on the half hour, and in the evening', (t) async {
      await _open(t, minutes: 16 * 60 + 45);
      expect(wheelsShow(t), 16 * 60 + 45);
    });

    testWidgets('Done hands back what the wheels show', (t) async {
      await _open(t, minutes: 8 * 60);
      turnWheels(t, 16, 45);
      await t.pump();
      expect(wheelsShow(t), 16 * 60 + 45);
      await _done(t);
      expect(_closed, isTrue);
      expect(_picked, 16 * 60 + 45);
    });

    testWidgets('Done with nothing turned hands back the time it started at', (t) async {
      await _open(t, minutes: 19 * 60 + 5);
      await _done(t);
      expect(_picked, 19 * 60 + 5);
    });

    testWidgets('closing the card without Done picks nothing', (t) async {
      await _open(t, minutes: 8 * 60);
      turnWheels(t, 3, 3);
      await t.pump();
      await t.tap(find.byIcon(Ph.x));
      await t.pumpAndSettle();
      expect(_closed, isTrue);
      expect(_picked, isNull);
    });
  });

  group('any time', () {
    // The lists stopped at 5:00 am and 11:30 pm, and had nothing between the half hours.
    for (final (hour, minute) in [(0, 0), (0, 1), (0, 30), (4, 20), (8, 10), (11, 59), (12, 0), (12, 1), (12, 15), (16, 45), (23, 30), (23, 59)]) {
      testWidgets('${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} can be chosen', (t) async {
        await _open(t, minutes: 8 * 60);
        turnWheels(t, hour, minute);
        await t.pump();
        await _done(t);
        expect(_picked, hour * 60 + minute);
      });
    }

    testWidgets('every minute of the day can be chosen, and each comes back as itself', (t) async {
      await _open(t, minutes: 0);
      for (var m = 0; m < 24 * 60; m += 7) {
        turnWheels(t, m ~/ 60, m % 60);
        expect(wheelsShow(t), m, reason: 'minute $m of the day');
      }
      turnWheels(t, 23, 59);
      expect(wheelsShow(t), 24 * 60 - 1);
    });

    testWidgets('a start before 0:00 or after 23:59 is brought to the day', (t) async {
      await _open(t, minutes: 24 * 60 + 90);
      expect(wheelsShow(t), 24 * 60 - 1);
      await t.tap(find.byIcon(Ph.x));
      await t.pumpAndSettle();
      await _open(t, minutes: -30);
      expect(wheelsShow(t), 0);
    });
  });

  /// A finger drags [wheel] by [rows] rows: up (negative) turns the wheel forward. The first stretch of a drag only starts it, so the
  /// slop is added to what the wheel is meant to move.
  Future<void> drag(WidgetTester t, Key wheel, int rows) async {
    final row = t.getSize(find.byKey(wheel)).height / 5;
    await t.drag(find.byKey(wheel), Offset(0, -(row * rows + kDragSlopDefault * rows.sign)), warnIfMissed: false);
    await t.pumpAndSettle();
  }

  group('turning a wheel', () {
    testWidgets('a drag on the minutes moves it one number for each row it goes past', (t) async {
      await _open(t, minutes: 8 * 60);
      await drag(t, TimeWheels.minuteKey, 3);
      expect(wheelsShow(t), 8 * 60 + 3, reason: 'three rows up: 8:03');
      await drag(t, TimeWheels.minuteKey, -5);
      expect(wheelsShow(t), 8 * 60 + 58, reason: 'five rows back from :03 goes round to :58, and the hour stays 8');
    });

    testWidgets('the minutes go round: after 59 comes 00 without the hour changing', (t) async {
      await _open(t, minutes: 8 * 60 + 58);
      await drag(t, TimeWheels.minuteKey, 3);
      expect(wheelsShow(t), 8 * 60 + 1);
    });

    testWidgets('a tap on a number above or below the middle turns the wheel to it', (t) async {
      await _open(t, minutes: 8 * 60 + 30);
      await t.tap(find.descendant(of: find.byKey(TimeWheels.hourKey), matching: find.text('10')));
      await t.pumpAndSettle();
      expect(wheelsShow(t), 10 * 60 + 30);
      await t.tap(find.descendant(of: find.byKey(TimeWheels.ampmKey), matching: find.text('pm')));
      await t.pumpAndSettle();
      expect(wheelsShow(t), 22 * 60 + 30);
    });

    testWidgets('am and pm stop at their ends', (t) async {
      await _open(t, minutes: 8 * 60);
      await drag(t, TimeWheels.ampmKey, -4);
      expect(wheelsShow(t), 8 * 60, reason: 'nothing before am');
      await drag(t, TimeWheels.ampmKey, 4);
      expect(wheelsShow(t), 20 * 60, reason: 'and nothing after pm');
    });
  });

  SemanticsData heard(WidgetTester t, Key wheel) => t.getSemantics(find.byKey(wheel)).getSemanticsData();

  group('a screen reader', () {
    testWidgets('hears each wheel by name and value, and can step it up and down', (t) async {
      final handle = t.ensureSemantics();
      await _open(t, minutes: 8 * 60 + 5);
      final hour = heard(t, TimeWheels.hourKey);
      expect((hour.label, hour.value, hour.increasedValue, hour.decreasedValue), ('Hour', '8', '9', '7'));
      expect(hour.hasAction(SemanticsAction.increase) && hour.hasAction(SemanticsAction.decrease), isTrue);
      final minute = heard(t, TimeWheels.minuteKey);
      expect((minute.label, minute.value, minute.increasedValue, minute.decreasedValue), ('Minute', '05', '06', '04'));
      t.semantics.performAction(find.semantics.byLabel('Hour'), SemanticsAction.increase);
      await t.pumpAndSettle();
      expect(wheelsShow(t), 9 * 60 + 5);
      t.semantics.performAction(find.semantics.byLabel('Minute'), SemanticsAction.decrease);
      await t.pumpAndSettle();
      expect(wheelsShow(t), 9 * 60 + 4);
      handle.dispose();
    });

    testWidgets('am has no step down and pm no step up', (t) async {
      final handle = t.ensureSemantics();
      await _open(t, minutes: 8 * 60);
      final am = heard(t, TimeWheels.ampmKey);
      expect((am.label, am.value, am.increasedValue), ('am or pm', 'am', 'pm'));
      expect(am.hasAction(SemanticsAction.increase), isTrue);
      expect(am.hasAction(SemanticsAction.decrease), isFalse, reason: 'nothing before am');
      turnWheels(t, 20);
      await t.pump();
      final pm = heard(t, TimeWheels.ampmKey);
      expect((pm.value, pm.decreasedValue), ('pm', 'am'));
      expect(pm.hasAction(SemanticsAction.decrease), isTrue);
      expect(pm.hasAction(SemanticsAction.increase), isFalse, reason: 'nothing after pm');
      handle.dispose();
    });
  });

  group('how it looks', () {
    testWidgets('in the dark, at the usual size', (t) async {
      await _open(t, minutes: 20 * 60 + 15, dark: true);
      expect(t.takeException(), isNull);
      expect(wheelsShow(t), 20 * 60 + 15);
    });

    // The wheels have no room to spare on a narrow phone with big text: three rows instead of five, and the numbers shrink to fit.
    testWidgets('on a narrow phone with large text it fits, and Done can be reached', (t) async {
      await _open(t, minutes: 12 * 60 + 40, width: 320, scale: 2.0);
      expect(t.takeException(), isNull);
      expect(wheelsShow(t), 12 * 60 + 40);
      expect(find.text('Done'), findsOneWidget);
      final rows = t.getSize(find.byKey(TimeWheels.hourKey)).height;
      expect(rows, lessThan(900 * 0.72), reason: 'inside the card, which is never taller than three quarters of the screen');
      await _done(t);
      expect(_picked, 12 * 60 + 40);
    });

    testWidgets('large text on a usual phone', (t) async {
      await _open(t, minutes: 9 * 60, scale: 1.8);
      expect(t.takeException(), isNull);
      turnWheels(t, 23, 55);
      await t.pump();
      await _done(t);
      expect(_picked, 23 * 60 + 55);
    });
  });
}
