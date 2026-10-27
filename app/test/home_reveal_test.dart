// The tutor's Home never leaves a card invisible. A card the list reveals is laid out and takes taps from the first
// frame, so one stuck at zero opacity is a black gap that opens a group when it is touched. These read every reveal's
// opacity after the screen has settled, whatever happened to the list before: it was scrolled, it loaded again, or the
// data under it changed shape (a request arrived, a test ended, a course was made).
//   flutter test test/home_reveal_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/home_screen.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

var _home = <String, Object?>{};
var _homeCalls = 0;

Future<http.Response> _answer(http.Request r) async {
  if (r.url.path == '/teacher/home') {
    _homeCalls++;
    return http.Response.bytes(utf8.encode(jsonEncode(_home)), 200, headers: {'content-type': 'application/json'});
  }
  return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.url.path}'}}), 404);
}

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();

Map<String, Object?> _group(int cls, String subject, int students, {List<Object?> live = const [], List<Object?> posted = const []}) =>
    {'class_level': cls, 'subject_id': 'sub-$subject', 'subject': subject, 'students': students, 'live': live, 'posted': posted};

/// What Home showed on the phone in the report: a group with a test live, two groups with nothing running, a course
/// with two tests live and two courses with none.
Map<String, Object?> _data({int pending = 0, bool groupLive = true, bool courses = true, int quietGroups = 2, bool courseLive = true}) {
  final liveTest = {'id': 'x1', 'title': 'Sample paper, set 6', 'closes_at': _iso(const Duration(hours: 3)), 'opens_at': null, 'time_limit_min': 30, 'submitted': 0, 'assigned': 1, 'writing': 0};
  return {
    'server_now': _iso(Duration.zero),
    'tuition': {'id': 't-1', 'name': 'Core Academy', 'join_code': 'KR74MQ'},
    'pending_requests': pending,
    'groups': [
      _group(11, 'Science', 1, live: groupLive ? [liveTest] : const []),
      for (var i = 0; i < quietGroups; i++) _group(9 + i, 'Maths', 3 + i),
    ],
    'totals': {'live': groupLive ? 1 : 0, 'writing': 0},
    if (courses)
      'courses': [
        {
          'id': 'c-1', 'name': 'Maths Mock Test Series', 'people': 3,
          'live': courseLive
              ? [
                  {'id': 'y1', 'title': 'Area Related to Circles, Mock Test', 'closes_at': _iso(const Duration(hours: 3)), 'opens_at': null, 'submitted': 0, 'assigned': 3, 'writing': 1},
                  {'id': 'y2', 'title': 'Surface Area and Volume, Set 1', 'closes_at': _iso(const Duration(days: 7)), 'opens_at': null, 'submitted': 0, 'assigned': 3, 'writing': 0},
                ]
              : <Object?>[],
          'posted': <Object?>[],
        },
        {'id': 'c-2', 'name': 'Test Course', 'people': 1, 'live': <Object?>[], 'posted': <Object?>[]},
        {'id': 'c-3', 'name': 'Science Mock Test Series', 'people': 3, 'live': <Object?>[], 'posted': <Object?>[]},
      ],
  };
}

Future<void> _advance(WidgetTester t, int ms) async {
  for (var left = ms; left > 0; left -= 16) {
    await t.pump(Duration(milliseconds: left < 16 ? left : 16));
  }
}

/// The reveals showing less than they should: every one with some of its card in the visible part of the list, and the
/// opacity it is at. A card with only a sliver showing may still be waiting for the list to be scrolled to it.
List<String> _hidden(WidgetTester t, double height) {
  final out = <String>[];
  var i = 0;
  for (final e in find.byType(Reveal, skipOffstage: false).evaluate()) {
    final box = e.renderObject;
    final at = box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero).dy : null;
    final size = box is RenderBox && box.hasSize ? box.size.height : 0.0;
    final opacity = t.widget<Opacity>(find.descendant(of: find.byWidget(e.widget, skipOffstage: false), matching: find.byType(Opacity, skipOffstage: false), skipOffstage: false).first).opacity;
    if (at != null && size > 0 && at + size > 0 && at < height - 60 && opacity < 0.999) {
      out.add('reveal #$i at ${at.round()} dp, ${size.round()} dp tall, opacity ${opacity.toStringAsFixed(2)}');
    }
    i++;
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient(_answer));
  });

  setUp(() {
    _home = _data();
    _homeCalls = 0;
    api.token = 'test';
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'karthiga', 'display_name': 'Karthiga', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Core Academy', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
  });

  Future<void> open(WidgetTester t, double height) async {
    t.view.physicalSize = Size(360 * 2.5, height * 2.5);
    t.view.devicePixelRatio = 2.5;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: TutorHome())));
    await _advance(t, 3000);
  }

  /// The keyboard of a card on another tab, or of the page above: the tab bar's page is squeezed to what is left, and
  /// given its height back when the keyboard goes.
  Future<void> keyboard(WidgetTester t, {required bool up}) async {
    t.view.viewPadding = const FakeViewPadding(top: 24 * 2.5, bottom: 16 * 2.5);
    t.view.padding = FakeViewPadding(top: 24 * 2.5, bottom: up ? 0 : 16 * 2.5);
    t.view.viewInsets = FakeViewPadding(bottom: up ? 318 * 2.5 : 0);
    await _advance(t, 400);
  }

  /// The data changes and Home loads it again, as it does every 30 seconds.
  Future<void> poll(WidgetTester t, Map<String, Object?> next) async {
    _home = next;
    final before = _homeCalls;
    await t.pump(const Duration(seconds: 31));
    await _advance(t, 3000);
    expect(_homeCalls, greaterThan(before), reason: 'Home did not load again');
  }

  for (final height in [640.0, 800.0, 915.0]) {
    testWidgets('Home on a ${height.round()} dp phone: rows made while the keyboard is up are there once it has gone', (t) async {
      _home = _data(courses: false);
      await open(t, height);
      await keyboard(t, up: true);
      // Home loads again behind the card that has the keyboard (a course was made): the Courses part is new.
      await poll(t, _data());
      await keyboard(t, up: false);
      await _advance(t, 1500);
      expect(_hidden(t, height), isEmpty, reason: 'once the keyboard has gone');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Home on a ${height.round()} dp phone: the first load while the keyboard is up leaves nothing behind once it has gone', (t) async {
      t.view.physicalSize = Size(360 * 2.5, height * 2.5);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      await keyboard(t, up: true);
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: TutorHome())));
      await _advance(t, 1500);
      await keyboard(t, up: false);
      await _advance(t, 1500);
      expect(_hidden(t, height), isEmpty, reason: 'once the keyboard has gone');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Home on a ${height.round()} dp phone: every card is there once it has come in', (t) async {
      await open(t, height);
      expect(_hidden(t, height), isEmpty);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Home on a ${height.round()} dp phone: after a scroll, every card in view is there', (t) async {
      await open(t, height);
      await t.drag(find.byType(ListView).first, const Offset(0, -260));
      await _advance(t, 1500);
      expect(_hidden(t, height), isEmpty);
      await t.drag(find.byType(ListView).first, const Offset(0, 500));
      await _advance(t, 1500);
      expect(_hidden(t, height), isEmpty);
      await t.pumpWidget(const SizedBox.shrink());
    });

    for (final (name, next) in <(String, Map<String, Object?>)>[
      ('nothing changed', _data()),
      ('the test in the group ended, so the group is quiet now', _data(groupLive: false)),
      ('a request to join arrived', _data(pending: 1)),
      ('the course tests ended', _data(courseLive: false)),
      ('another quiet group was added', _data(quietGroups: 3)),
      ('the courses are gone', _data(courses: false)),
    ]) {
      testWidgets('Home on a ${height.round()} dp phone, then loaded again when $name: every card in view is there', (t) async {
        await open(t, height);
        await poll(t, next);
        expect(_hidden(t, height), isEmpty, reason: 'straight after the new data');
        await t.drag(find.byType(ListView).first, const Offset(0, -200));
        await _advance(t, 1500);
        expect(_hidden(t, height), isEmpty, reason: 'after a scroll');
        await t.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('Home on a ${height.round()} dp phone, scrolled first and then loaded again when $name: every card in view is there', (t) async {
        await open(t, height);
        await t.drag(find.byType(ListView).first, const Offset(0, -260));
        await _advance(t, 1500);
        await poll(t, next);
        expect(_hidden(t, height), isEmpty, reason: 'straight after the new data');
        await t.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
