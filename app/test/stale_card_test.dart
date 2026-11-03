// A test left open for a week, on the tutor's Home: the card, the two buttons, and what each one asks before it does anything.
//   flutter test test/stale_card_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/format.dart' as f;
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/home_screen.dart';
import 'package:core_academy/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

var _home = <String, Object?>{};
final _posts = <String>[];

/// When set, a reminder or a close is refused with this message.
String? _refuse;

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

Future<http.Response> _answer(http.Request r) async {
  if (r.method == 'POST') {
    _posts.add(r.url.path);
    if (_refuse != null) return _json({'error': {'code': 'just_reminded', 'message': _refuse}}, 409);
    if (r.url.path.endsWith('/remind')) return _json({'students': 5, 'phones': 4});
    if (r.url.path.endsWith('/close')) return _json({'test': {'id': 't-1'}});
  }
  if (r.url.path == '/teacher/home') return _json(_home);
  return _json({'error': {'code': 'not_found', 'message': 'No stub for ${r.url.path}'}}, 404);
}

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();

Map<String, Object?> _stale(String id, String title, {int days = 8, int waiting = 5, int assigned = 12, Duration? closes = const Duration(days: 5)}) => {
      'id': id, 'title': title, 'class_level': 10, 'subject_id': 'sub-Maths', 'subject': 'Maths', 'course_id': null, 'course': null,
      'opened_at': _iso(Duration(days: -days)), 'days_open': days, 'closes_at': closes == null ? null : _iso(closes), 'assigned': assigned, 'waiting': waiting,
    };

Map<String, Object?> _data({List<Object?>? stale, bool oldServer = false}) => {
      'server_now': _iso(Duration.zero),
      'tuition': {'id': 't-1', 'name': 'Core Academy', 'join_code': 'KR74MQ'},
      'pending_requests': 0,
      'groups': [
        {'class_level': 10, 'subject_id': 'sub-Maths', 'subject': 'Maths', 'students': 12, 'live': <Object?>[], 'posted': <Object?>[]},
      ],
      'totals': {'live': 0, 'writing': 0},
      'courses': <Object?>[],
      'finished': <Object?>[],
      'papers': <Object?>[],
      if (!oldServer) 'stale': stale ?? <Object?>[],
    };

Future<void> _open(WidgetTester t, {double height = 900, double width = 411, double scale = 1}) async {
  t.view.physicalSize = Size(width * 2.625, height * 2.625);
  t.view.devicePixelRatio = 2.625;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAllTestValues);
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const Scaffold(body: TutorHome()))]);
  await t.pumpWidget(MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router));
  await _settle(t);
}

Future<void> _settle(WidgetTester t, [int ms = 2500]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester t, Finder at) async {
  await t.ensureVisible(at);
  await _settle(t, 300);
  await t.tap(at);
  await _settle(t, 800);
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
    _posts.clear();
    _refuse = null;
    api.token = 'test';
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Core Academy', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
  });

  testWidgets('a test open for a week gets a card that says how long and who has not handed it in', (t) async {
    _home = _data(stale: [_stale('t-1', 'Unit 2 quiz')]);
    await _open(t);
    expect(find.text('OPEN FOR 8 DAYS'), findsOneWidget);
    expect(find.text('Unit 2 quiz'), findsOneWidget);
    expect(find.text('10th Maths · 5 of 12 have not handed it in'), findsOneWidget);
    expect(find.text('Remind the students'), findsOneWidget);
    expect(find.text('Close the test'), findsOneWidget);
  });

  testWidgets('no card without a test left open, or from a server that does not know about them', (t) async {
    _home = _data();
    await _open(t);
    expect(find.text('Remind the students'), findsNothing);
    _home = _data(oldServer: true);
    await _open(t);
    expect(find.text('Remind the students'), findsNothing);
    expect(find.text('Make tests'), findsOneWidget);
  });

  testWidgets('Remind the students shows the notification each one gets, and sends nothing until the tutor says so', (t) async {
    _home = _data(stale: [_stale('t-1', 'Unit 2 quiz')]);
    await _open(t);
    final closes = f.parseTime(_home['stale'] is List ? ((_home['stale'] as List).first as Map)['closes_at'] : null)!;
    await _tap(t, find.text('Remind the students'));
    expect(find.text('Remind the students?'), findsOneWidget);
    expect(find.textContaining('have not handed in Unit 2 quiz. Each one gets this notification:'), findsOneWidget);
    expect(find.text('Your tutor reminds you to write this test. It closes ${f.when(closes)}.'), findsOneWidget);
    expect(find.text('After you send it, this card goes away for a week.'), findsOneWidget);
    await _tap(t, find.text('Not now'));
    expect(find.text('Remind the students?'), findsNothing);
    expect(_posts, isEmpty);
  });

  testWidgets('Send reminder sends it, says how many students got it, and the card goes when the server stops listing the test', (t) async {
    _home = _data(stale: [_stale('t-1', 'Unit 2 quiz')]);
    await _open(t);
    await _tap(t, find.text('Remind the students'));
    _home = _data(stale: []); // the server leaves it out for a week once the students are reminded
    await _tap(t, find.text('Send reminder'));
    expect(_posts, ['/teacher/tests/t-1/remind']);
    expect(find.text('Reminder sent to 5 students.'), findsOneWidget);
    expect(find.text('Remind the students'), findsNothing);
  });

  testWidgets('a test with no closing time says it is still open', (t) async {
    _home = _data(stale: [_stale('t-1', 'Unit 2 quiz', closes: null)]);
    await _open(t);
    await _tap(t, find.text('Remind the students'));
    expect(find.text('Your tutor reminds you to write this test. It is still open.'), findsOneWidget);
  });

  testWidgets('one student left is told in the singular', (t) async {
    _home = _data(stale: [_stale('t-1', 'Unit 2 quiz', waiting: 1)]);
    await _open(t);
    expect(find.text('10th Maths · 1 of 12 have not handed it in'), findsOneWidget);
    await _tap(t, find.text('Remind the students'));
    expect(find.textContaining('1 student has not handed in Unit 2 quiz. They get this notification:'), findsOneWidget);
  });

  testWidgets('Close the test says what it does, and closes nothing until the tutor says so', (t) async {
    _home = _data(stale: [_stale('t-1', 'Unit 2 quiz')]);
    await _open(t);
    await _tap(t, find.text('Close the test'));
    expect(find.text('Close this test now?'), findsOneWidget);
    expect(find.text('Students who have not started it can no longer write it.'), findsOneWidget);
    expect(find.textContaining('Anyone writing it right now gets 10 minutes to finish.'), findsOneWidget);
    expect(find.text('Everyone who handed it in keeps their marks.'), findsOneWidget);
    await _tap(t, find.text('Keep it open'));
    expect(find.text('Close this test now?'), findsNothing);
    expect(_posts, isEmpty);
  });

  testWidgets('closing it posts the close and says so', (t) async {
    _home = _data(stale: [_stale('t-1', 'Unit 2 quiz')]);
    await _open(t);
    await _tap(t, find.text('Close the test'));
    _home = _data(stale: []);
    await _tap(t, find.text('Close the test').last);
    expect(_posts, ['/teacher/tests/t-1/close']);
    expect(find.text('Unit 2 quiz is closed. Anyone still writing it has 10 minutes.'), findsOneWidget);
  });

  testWidgets('a refusal from the server is shown in words, and the card stays', (t) async {
    _home = _data(stale: [_stale('t-1', 'Unit 2 quiz')]);
    _refuse = 'You reminded the students about this test less than a day ago. Try again tomorrow.';
    await _open(t);
    await _tap(t, find.text('Remind the students'));
    await _tap(t, find.text('Send reminder'));
    expect(find.text('That did not work'), findsOneWidget);
    expect(find.text(_refuse!), findsOneWidget);
    await _tap(t, find.text('OK'));
    expect(find.text('Remind the students'), findsOneWidget);
  });

  testWidgets('more than two tests show two, and the rest on a tap', (t) async {
    _home = _data(stale: [_stale('t-1', 'First test'), _stale('t-2', 'Second test'), _stale('t-3', 'Third test')]);
    await _open(t);
    expect(find.text('First test'), findsOneWidget);
    expect(find.text('Second test'), findsOneWidget);
    expect(find.text('Third test'), findsNothing);
    await _tap(t, find.text('Show all 3 tests open for a week'));
    expect(find.text('Third test'), findsOneWidget);
    await _tap(t, find.text('Show fewer'));
    expect(find.text('Third test'), findsNothing);
  });

  testWidgets('the card and both confirm cards fit a small phone with very large text', (t) async {
    _home = _data(stale: [_stale('t-1', 'Unit 2 quiz: quadratic equations and their graphs, set 1')]);
    await _open(t, width: 320, scale: 2.0);
    expect(t.takeException(), isNull);
    await _tap(t, find.text('Remind the students'));
    expect(t.takeException(), isNull);
    await _tap(t, find.text('Not now'));
    await _tap(t, find.text('Close the test'));
    expect(t.takeException(), isNull);
  });
}
