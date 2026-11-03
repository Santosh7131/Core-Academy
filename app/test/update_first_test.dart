// Updating before a test, and updating by itself when the app is too old to be used: a student who taps Start while a newer version is
// out is offered the update first (and may start anyway), a test already under way never asks, and the screen that says the app must be
// updated begins the update on its own, once. The cards and screens are the real ones; Android's side is a stub that records what it is asked.
//   flutter test test/update_first_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/format.dart' as f;
import 'package:core_academy/core/session.dart';
import 'package:core_academy/core/updater.dart';
import 'package:core_academy/features/auth/update_required_screen.dart';
import 'package:core_academy/features/student/course_screen.dart';
import 'package:core_academy/features/student/start_card.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('core_academy/updater');

/// What Android was asked, in order, and whether it lets the app install updates yet.
final _asked = <String>[];
var _canInstall = false;

Release _release() => Release.fromJson({
      'version': '1.8.0', 'build': 10, 'apk': 'https://example.test/core-academy.apk', 'sha256': 'ab', 'size': 39 * 1024 * 1024, 'notes': '',
    });

/// A newer version found, nothing started.
void _newerIsOut() {
  updater.available = _release();
  updater.step = UpdateStep.ready;
  updater.progress = 0;
  updater.problem = null;
}

void _nothingNewer() {
  updater.available = null;
  updater.step = UpdateStep.ready;
  updater.progress = 0;
  updater.problem = null;
}

/// Tells the screens the updater changed, the way its own download does.
void _changed() {
  // ignore: invalid_use_of_protected_member
  updater.notifyListeners();
}

/// [days] from today at [hour]:[minute], to the minute.
DateTime _at(int days, {int hour = 21, int minute = 0}) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + days, hour, minute);
}

Map<String, dynamic> _test({DateTime? closes, bool noClose = false}) => {
      'id': 't1', 'title': 'Linear equations', 'state': 'open', 'question_count': 12, 'max_marks': 12, 'time_limit_min': 20,
      'closes_at': noClose ? null : (closes ?? _at(0)).toUtc().toIso8601String(),
    };

Future<void> _pump(WidgetTester t, [int ms = 600]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester t, Finder finder, [int ms = 600]) async {
  await t.ensureVisible(finder);
  await t.pump();
  await t.tap(finder);
  await _pump(t, ms);
}

void _phone(WidgetTester t, {double width = 411, double height = 900}) {
  setResolvedDark(false);
  t.view.physicalSize = Size(width * 2.625, height * 2.625);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
}

Widget _app(Widget home, {double scale = 1.0}) => MaterialApp(
      theme: buildTheme(Brightness.light),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

class _Answer {
  bool? value;
}

/// Opens the card a student sees between Home and a test, on a button, and keeps the answer it gives.
Future<_Answer> _openStart(WidgetTester t, Map<String, dynamic> test, {double width = 411, double scale = 1.0}) async {
  _phone(t, width: width);
  final a = _Answer();
  await t.pumpWidget(_app(
    Builder(
      builder: (context) => Scaffold(
        body: Center(child: TextButton(onPressed: () async => a.value = await confirmStart(context, test), child: const Text('open'))),
      ),
    ),
    scale: scale,
  ));
  await t.tap(find.text('open'));
  await _pump(t);
  return a;
}

const _first = 'Update now, then start your test. It takes about a minute, and your login, tests and results stay as they are.';
const _usual = 'The timer starts when you tap Start. Every answer is saved as you choose it.';

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});

/// The course page's server: one test of the course, open or already under way.
var _underWay = false;

Future<http.Response> _server(http.Request r) async {
  if (r.method == 'GET' && r.url.path == '/student/courses/c1') {
    return _json({
      'course': {'id': 'c1', 'name': 'Spoken English'},
      'tests': [
        {
          ..._test(closes: _at(2)),
          'title': 'Everyday phrases',
          'state': _underWay ? 'in_progress' : 'open',
          if (_underWay) 'attempt': {'id': 'a1', 'deadline_at': DateTime.now().toUtc().add(const Duration(minutes: 14)).toIso8601String()},
        },
      ],
    });
  }
  return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.method} ${r.url.path}'}}), 404);
}

/// The course page, and a stand-in for the test itself.
Future<void> _openCourse(WidgetTester t) async {
  _phone(t);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, _) => const StudentCourseScreen(id: 'c1', name: 'Spoken English')),
    GoRoute(path: '/s/write/:id', builder: (_, s) => Scaffold(body: Center(child: Text('THE TEST ${s.pathParameters['id']}')))),
  ]);
  await t.pumpWidget(MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router));
  await _pump(t, 800);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient(_server));
    session.user = {'id': 'u-1', 'role': 'student', 'username': 'aarav', 'display_name': 'Aarav', 'class_level': 9};
    session.tuitions = [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9},
    ];
    session.tuitionId = 't-1';
    session.tuitionName = 'Priya Maths Classes';
  });

  setUp(() {
    _asked.clear();
    _canInstall = false;
    _underWay = false;
    _nothingNewer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      _asked.add(call.method);
      return call.method == 'info' ? {'version': '1.7.0', 'build': 9, 'silent': true, 'dir': null, 'canInstall': _canInstall} : null;
    });
  });

  tearDown(() {
    _nothingNewer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  group('the card before a test', () {
    testWidgets('with nothing newer out, the usual card comes up and Start starts the test', (t) async {
      final a = await _openStart(t, _test());
      expect(find.text('Update first'), findsNothing);
      expect(find.text(_usual), findsOneWidget);
      await _tap(t, find.text('Start test'));
      expect(a.value, isTrue);
    });

    testWidgets('with a newer version out, it is offered first: the version, its size, what it does, and when the test closes', (t) async {
      _newerIsOut();
      final a = await _openStart(t, _test());
      expect(find.text('Update first'), findsOneWidget);
      expect(find.text('Version 1.8.0 is ready · 39 MB'), findsOneWidget);
      expect(find.text(_first), findsOneWidget);
      expect(find.text('Linear equations stays open until ${f.whenDate(_at(0))}.'), findsOneWidget);
      expect(find.text('Update to version 1.8.0'), findsOneWidget);
      expect(find.text('Start anyway'), findsOneWidget);
      expect(find.text(_usual), findsNothing, reason: 'the usual card waits');
      expect(a.value, isNull, reason: 'nothing chosen yet');
    });

    testWidgets('the closing time keeps the day name and date, like every other start and end', (t) async {
      _newerIsOut();
      await _openStart(t, _test(closes: _at(2, hour: 18, minute: 30)));
      expect(find.text('Linear equations stays open until ${f.whenDate(_at(2, hour: 18, minute: 30))}.'), findsOneWidget);
      expect(find.textContaining('tonight'), findsNothing);
    });

    testWidgets('a test with no closing time leaves that line out', (t) async {
      _newerIsOut();
      await _openStart(t, _test(noClose: true));
      expect(find.text('Update first'), findsOneWidget);
      expect(find.textContaining('stays open'), findsNothing);
    });

    testWidgets('Start anyway goes on to the usual card, and Start there starts the test', (t) async {
      _newerIsOut();
      final a = await _openStart(t, _test());
      await _tap(t, find.text('Start anyway'));
      expect(find.text('Update first'), findsNothing);
      expect(find.text(_usual), findsOneWidget);
      expect(a.value, isNull);
      await _tap(t, find.text('Start test'));
      expect(a.value, isTrue);
      expect(_asked, isEmpty, reason: 'Android was never asked to update');
    });

    testWidgets('closing the card starts nothing', (t) async {
      _newerIsOut();
      final a = await _openStart(t, _test());
      await _tap(t, find.byIcon(Ph.x));
      expect(a.value, isFalse);
      expect(find.text(_usual), findsNothing);
    });

    testWidgets('Update asks Android; when installs are not allowed yet, the card says so, and Start anyway is still there', (t) async {
      _newerIsOut();
      final a = await _openStart(t, _test());
      await _tap(t, find.text('Update to version 1.8.0'));
      expect(_asked, ['info']);
      expect(find.text('Allow updates'), findsOneWidget);
      expect(find.text('Open Android settings'), findsOneWidget);
      expect(find.text('Update to version 1.8.0'), findsNothing, reason: 'the card moved on to the next step');
      expect(find.text('Start anyway'), findsOneWidget);
      expect(a.value, isNull);
    });

    testWidgets('a download that stops says so, with Try again, and she can still start anyway', (t) async {
      _newerIsOut();
      _canInstall = true;
      final a = await _openStart(t, _test());
      await _tap(t, find.text('Update to version 1.8.0'));
      expect(find.text('The update did not finish'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Start anyway'), findsOneWidget);
      await _tap(t, find.text('Start anyway'));
      expect(find.text(_usual), findsOneWidget);
      await _tap(t, find.text('Start test'));
      expect(a.value, isTrue);
    });

    testWidgets('while the download runs the card shows how far it is, and there is no way to start the test', (t) async {
      _newerIsOut();
      await _openStart(t, _test());
      updater.step = UpdateStep.downloading;
      updater.progress = 0.41;
      _changed();
      await t.pump();
      expect(find.text('Downloading version 1.8.0'), findsOneWidget);
      expect(find.text('41% of 39 MB'), findsOneWidget);
      expect(find.text('Start anyway'), findsNothing, reason: 'Android closes the app when the new version goes in');
      expect(find.text('Update to version 1.8.0'), findsNothing);
    });

    testWidgets('and while it installs', (t) async {
      _newerIsOut();
      await _openStart(t, _test());
      updater.step = UpdateStep.installing;
      _changed();
      await t.pump();
      expect(find.text('Installing version 1.8.0'), findsOneWidget);
      expect(find.text('Start anyway'), findsNothing);
    });

    testWidgets('on a small phone at twice the text size everything fits and can be reached', (t) async {
      _newerIsOut();
      final a = await _openStart(t, _test(), width: 320, scale: 2.0);
      expect(t.takeException(), isNull);
      expect(find.text('Update first'), findsOneWidget);
      await _tap(t, find.text('Start anyway'));
      expect(t.takeException(), isNull);
      await _tap(t, find.text('Start test'));
      expect(a.value, isTrue);
    });
  });

  group('from the course page', () {
    testWidgets('Start test with an update waiting offers it first, and Start anyway goes on to the usual card and the test', (t) async {
      _newerIsOut();
      await _openCourse(t);
      await _tap(t, find.text('Start test'));
      expect(find.text('Update first'), findsOneWidget);
      expect(find.text('Everyday phrases stays open until ${f.whenDate(_at(2))}.'), findsOneWidget);
      await _tap(t, find.text('Start anyway'));
      expect(find.text(_usual), findsOneWidget);
      await _tap(t, find.text('Start test').last, 900);
      expect(find.text('THE TEST t1'), findsOneWidget);
    });

    testWidgets('closing the card leaves the student on the course page', (t) async {
      _newerIsOut();
      await _openCourse(t);
      await _tap(t, find.text('Start test'));
      await _tap(t, find.byIcon(Ph.x));
      expect(find.text('THE TEST t1'), findsNothing);
      expect(find.text('Start test'), findsOneWidget);
    });

    testWidgets('with nothing newer out, Start test shows the usual card', (t) async {
      await _openCourse(t);
      await _tap(t, find.text('Start test'));
      expect(find.text('Update first'), findsNothing);
      expect(find.text(_usual), findsOneWidget);
    });

    testWidgets('a test already under way goes straight back in, even with an update waiting', (t) async {
      _newerIsOut();
      _underWay = true;
      await _openCourse(t);
      await _tap(t, find.text('Continue test'), 900);
      expect(find.text('Update first'), findsNothing);
      expect(find.text('THE TEST t1'), findsOneWidget);
    });
  });

  group('the screen that says the app must be updated', () {
    Future<void> open(WidgetTester t, {bool startByItself = true, double width = 411, double scale = 1.0}) async {
      _phone(t, width: width);
      await t.pumpWidget(_app(UpdateRequiredScreen(startByItself: startByItself), scale: scale));
      await _pump(t, 400);
    }

    testWidgets('it begins the update by itself, without a tap', (t) async {
      _newerIsOut();
      await open(t);
      expect(_asked, ['info'], reason: 'it asked Android whether updates may go in');
      expect(find.text('Please update Core Academy'), findsOneWidget);
      expect(find.text('Allow updates'), findsOneWidget, reason: 'the first step, since Android has not been told yet');
    });

    testWidgets('and goes on to the download when Android already allows it', (t) async {
      _newerIsOut();
      _canInstall = true;
      await open(t);
      // The stub has nowhere to put the file, so the download stops; what matters is that it was tried, once.
      expect(_asked, ['info']);
      expect(find.text('The update did not finish'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('it does not try again by itself after it failed: Try again is hers to tap', (t) async {
      _newerIsOut();
      _canInstall = true;
      await open(t);
      await _pump(t, 3000);
      expect(_asked, ['info'], reason: 'one try, however long the screen stays');
      await _tap(t, find.text('Try again'));
      expect(_asked, ['info', 'info']);
    });

    testWidgets('an update already under way is left alone', (t) async {
      _newerIsOut();
      updater.step = UpdateStep.downloading;
      updater.progress = 0.41;
      await open(t);
      expect(_asked, isEmpty);
      expect(find.text('Downloading version 1.8.0'), findsOneWidget);
      expect(find.text('41% of 39 MB'), findsOneWidget);
      expect(find.text('Update to version 1.8.0'), findsNothing, reason: 'no button while it downloads');
    });

    testWidgets('a failed update is not started again just because the screen opens', (t) async {
      _newerIsOut();
      updater.step = UpdateStep.failed;
      updater.problem = 'The download stopped. Check the internet and try again.';
      await open(t);
      expect(_asked, isEmpty);
      expect(find.text('The update did not finish'), findsOneWidget);
    });

    testWidgets('looked at without starting it, the button is there and Android is not asked until it is tapped', (t) async {
      _newerIsOut();
      await open(t, startByItself: false);
      expect(_asked, isEmpty);
      expect(find.text('Update to version 1.8.0'), findsOneWidget);
      expect(find.text('39 MB · uses your internet'), findsOneWidget);
      await _tap(t, find.text('Update to version 1.8.0'));
      expect(_asked, ['info']);
    });

    testWidgets('a build that does not look for updates says so and starts nothing', (t) async {
      await open(t);
      expect(_asked, isEmpty);
      expect(find.text('This test build does not look for updates.'), findsOneWidget);
    });

    testWidgets('on a small phone at twice the text size the progress card fits', (t) async {
      _newerIsOut();
      updater.step = UpdateStep.downloading;
      updater.progress = 0.41;
      await open(t, width: 320, scale: 2.0);
      expect(t.takeException(), isNull);
      expect(find.text('41% of 39 MB'), findsOneWidget);
    });
  });
}
