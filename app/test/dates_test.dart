// A test's opening and closing times say which day and date they are, even for today and tomorrow: "tomorrow" alone leaves the
// reader to work out which day that is. The Day box on the test page says the same, in two short lines beside the time.
//   flutter test test/dates_test.dart
import 'package:core_academy/core/format.dart' as f;
import 'package:core_academy/features/teacher/common.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

String _short(DateTime t) => DateFormat('EEE d MMM').format(t);

/// [days] from today at [hour]:[minute].
DateTime _at(int days, {int hour = 18, int minute = 0}) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + days, hour, minute);
}

/// [width] in dp, [scale] the phone's text size. A test draws text in a plain square font, wider than the real one, so a one-line day
/// only stays one line on a wide screen.
Future<void> _show(WidgetTester t, DateTime? value,
    {ValueChanged<DateTime?>? onChanged, String? noneLabel, double width = 411, double scale = 1.0}) async {
  setResolvedDark(false);
  t.view.physicalSize = Size(width * 2.625, 900 * 2.625);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Align(alignment: Alignment.topCenter, child: DayTimeChooser(value: value, noneLabel: noneLabel, onChanged: onChanged ?? (_) {})),
      ),
    ),
  ));
  await t.pump();
}

void main() {
  group('the words for a start or an end', () {
    test('today, tomorrow and yesterday keep their word and gain the day name and date', () {
      final today = _at(0), tomorrow = _at(1), yesterday = _at(-1);
      expect(f.dayDate(today), 'today, ${_short(today)}');
      expect(f.dayDate(tomorrow), 'tomorrow, ${_short(tomorrow)}');
      expect(f.dayDate(yesterday), 'yesterday, ${_short(yesterday)}');
      expect(f.whenDate(tomorrow), 'tomorrow, ${_short(tomorrow)}, 6:00 pm');
      expect(f.dayTitle(today), 'Today · ${_short(today)}');
      expect(f.whenTitle(tomorrow), 'Tomorrow · ${_short(tomorrow)}, 6:00 pm');
    });

    test('any other day is the day name, the date and the month', () {
      final later = _at(5, hour: 9, minute: 30);
      expect(f.dayDate(later), _short(later));
      expect(f.whenDate(later), '${_short(later)}, 9:30 am');
      expect(f.dayTitle(later), _short(later));
      expect(f.whenTitle(later), '${_short(later)}, 9:30 am');
    });

    test('every day, near or far, ends with its day name, date and month', () {
      for (var d = -3; d <= 20; d++) {
        expect(f.dayDate(_at(d)), matches(RegExp(r'[A-Z][a-z]{2} \d{1,2} [A-Z][a-z]{2}$')), reason: 'day $d');
      }
    });

    test('the older, shorter wording stays for a time somebody handed something in', () {
      expect(f.when(_at(0, hour: 15, minute: 11)), 'today 3:11 pm');
      expect(f.day(_at(1)), 'tomorrow');
    });
  });

  group('the Day box', () {
    testWidgets('a near day is two lines, the day word over its name and date, beside the time', (t) async {
      final tomorrow = _at(1);
      await _show(t, tomorrow);
      expect(find.text('Tomorrow\n${_short(tomorrow)}'), findsOneWidget);
      expect(find.text('6:00 pm'), findsOneWidget);
    });

    testWidgets('a later day is one line with its day name, date and month', (t) async {
      final later = _at(4);
      await _show(t, later);
      expect(find.text(_short(later)), findsOneWidget);
    });

    testWidgets('the list of days names every day on one line, today and tomorrow first', (t) async {
      await _show(t, _at(1));
      await t.tap(find.text('Tomorrow\n${_short(_at(1))}'));
      await t.pumpAndSettle();
      expect(find.text('Today · ${_short(_at(0))}'), findsOneWidget);
      expect(find.text('Tomorrow · ${_short(_at(1))}'), findsOneWidget);
      expect(find.text(_short(_at(2))), findsOneWidget);
      expect(find.text(_short(_at(3))), findsOneWidget);
    });

    testWidgets('picking a day from the list keeps the time', (t) async {
      DateTime? picked;
      await _show(t, _at(1, hour: 18), onChanged: (v) => picked = v);
      await t.tap(find.text('Tomorrow\n${_short(_at(1))}'));
      await t.pumpAndSettle();
      await t.tap(find.text(_short(_at(3))));
      await t.pumpAndSettle();
      expect(picked, _at(3, hour: 18));
    });

    testWidgets('both boxes are one height, whether the day is near or far', (t) async {
      await _show(t, _at(1), width: 900);
      final near = t.getSize(find.byType(SelectField).first).height;
      final nearTime = t.getSize(find.byType(SelectField).last).height;
      await _show(t, _at(5), width: 900);
      final far = t.getSize(find.byType(SelectField).first).height;
      expect(nearTime, near, reason: 'the time box is as tall as the day box');
      expect(far, near, reason: 'the page does not jump between a near day and a far one');
    });

    testWidgets('at the usual size on a usual phone the day and the time sit side by side', (t) async {
      await _show(t, _at(1));
      final day = t.getTopLeft(find.byType(SelectField).first);
      final time = t.getTopLeft(find.byType(SelectField).last);
      expect(time.dy, day.dy, reason: 'on one row');
      expect(time.dx, greaterThan(day.dx));
    });

    testWidgets('on a narrow phone the time goes under the day, and the day is one line', (t) async {
      final tomorrow = _at(1);
      await _show(t, tomorrow, width: 320);
      final day = t.getTopLeft(find.byType(SelectField).first);
      final time = t.getTopLeft(find.byType(SelectField).last);
      expect(time.dx, day.dx, reason: 'one above the other');
      expect(time.dy, greaterThan(day.dy));
      expect(find.text('Tomorrow · ${_short(tomorrow)}'), findsOneWidget);
    });

    testWidgets('with large text on a usual phone they stack too', (t) async {
      await _show(t, _at(1), scale: 1.8);
      final day = t.getTopLeft(find.byType(SelectField).first);
      final time = t.getTopLeft(find.byType(SelectField).last);
      expect(time.dx, day.dx, reason: 'one above the other');
      expect(time.dy, greaterThan(day.dy));
    });

    testWidgets('with no day chosen there is one box, and it keeps its words', (t) async {
      await _show(t, null, noneLabel: 'Now');
      expect(find.text('Now'), findsOneWidget);
      expect(find.byType(SelectField), findsOneWidget);
    });
  });
}
