// The Bank tab: every paper the tutor has posted, once each, to post again. It lists them (from GET /teacher/bank), narrows them by
// class or course and by subject, and a tap on one asks when to post it again and makes a new test from the questions of its latest.
//   flutter test test/bank_test.dart
import 'dart:async';
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/format.dart' as f;
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/bank_screen.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/time_wheels.dart';

// ---------------------------------------------------------------- the stand-in server

var _papers = <Map<String, dynamic>>[];
String? _bankFails;
var _publishFails = false;

/// Holds the making of a test back, as a slow network would.
Completer<void>? _hold;

/// What happens on the server once a test is posted: the Bank changes.
void Function()? _onPublish;
final _calls = <String>[];
final _bodies = <String, Map<String, dynamic>>{};

DateTime _day(int days, [int hour = 0, int minute = 0]) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + days, hour, minute);
}

String _iso(DateTime t) => t.toUtc().toIso8601String();

/// A paper as GET /teacher/bank describes it.
Map<String, dynamic> _paper(
  String id,
  String title, {
  int cls = 9,
  String subject = 'Maths',
  int questions = 20,
  int uses = 1,
  DateTime? given,
  DateTime? opens,
  DateTime? closes,
  int? limit = 30,
  bool shuffle = true,
  bool group = true,
  int chosen = 0,
  String? courseId,
  String? course,
}) {
  final last = given ?? _day(-5, 8);
  return {
    'id': id,
    'title': title,
    'class_level': courseId == null ? cls : null,
    'course_id': courseId,
    'course': course,
    'subject_id': courseId == null ? 'sub-$subject' : null,
    'subject': courseId == null ? subject : null,
    'question_count': questions,
    'time_limit_min': limit,
    'shuffle': shuffle,
    'opens_at': _iso(opens ?? last),
    'closes_at': _iso(closes ?? last.add(const Duration(hours: 13))),
    'assign_all': false,
    'assign_group': group,
    'chosen': chosen,
    'last_given': _iso(last),
    'first_made': _iso(last.subtract(const Duration(days: 30))),
    'uses': uses,
  };
}

/// What GET /teacher/tests/:id sends for a paper: its test, its questions in order and the students chosen for it.
Map<String, dynamic> _testOf(Map<String, dynamic> p) => {
      'test': {
        'id': p['id'],
        'title': p['title'],
        'class_level': p['class_level'],
        'course_id': p['course_id'],
        'subject_id': p['subject_id'],
        'status': 'published',
        'assign_group': p['assign_group'],
        'assign_all': p['assign_all'],
        'paper_id': 'paper-${p['id']}',
      },
      'questions': [for (var i = 1; i <= (p['question_count'] as int); i++) {'id': 'q-${p['id']}-$i', 'position': i - 1}],
      'students': [for (var i = 1; i <= (p['chosen'] as int); i++) {'id': 's-${p['id']}-$i', 'display_name': 'Student $i', 'class_level': p['class_level']}],
    };

Future<http.Response> _answer(http.Request r) async {
  final key = '${r.method} ${r.url.path}';
  _calls.add(key);
  if (r.body.isNotEmpty) _bodies[key] = jsonDecode(r.body) as Map<String, dynamic>;
  http.Response ok(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});
  http.Response no(int status, String code, String message) => ok({'error': {'code': code, 'message': message}}, status);
  if (key == 'GET /teacher/bank') return _bankFails != null ? no(500, 'broken', _bankFails!) : ok({'papers': _papers});
  if (r.method == 'GET' && r.url.path.startsWith('/teacher/tests/')) {
    final id = r.url.pathSegments.last;
    final p = _papers.where((x) => x['id'] == id).firstOrNull;
    return p == null ? no(404, 'not_found', 'This test was not found.') : ok(_testOf(p));
  }
  if (key == 'POST /teacher/tests') {
    await _hold?.future;
    return ok({'id': 'new-1'}, 201);
  }
  if (key == 'POST /teacher/tests/new-1/publish') {
    if (_publishFails) return no(400, 'closing_passed', 'The closing time has already passed. Choose a later one.');
    _onPublish?.call();
    return ok({'test': {'id': 'new-1', 'status': 'published'}});
  }
  if (key == 'DELETE /teacher/tests/new-1') return ok({'ok': true, 'results_deleted': 0});
  return no(404, 'not_found', 'No stub for $key');
}

// ---------------------------------------------------------------- the screen

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester t, Finder at) async {
  await t.tap(at);
  await _settle(t, 400);
}

late GoRouter _router;

Future<void> _open(WidgetTester t, {double width = 411, double scale = 1, bool dark = false}) async {
  setResolvedDark(dark);
  t.view.physicalSize = Size(width * 2.625, 900 * 2.625);
  t.view.devicePixelRatio = 2.625;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAllTestValues);
  _router = GoRouter(initialLocation: '/t/bank', routes: [
    GoRoute(path: '/t/bank', builder: (_, _) => const Scaffold(body: BankScreen())),
    GoRoute(path: '/t/tests/:id', builder: (_, s) => Scaffold(body: Center(child: Text('the test ${s.pathParameters['id']}')))),
  ]);
  await t.pumpWidget(MaterialApp.router(theme: buildTheme(dark ? Brightness.dark : Brightness.light), routerConfig: _router));
  await _settle(t);
}

String _clock(int h, [int m = 0]) => f.time(DateTime(2000, 1, 1, h, m));

/// The box [field] opens the wheels: turn them to [hour] and [minute] and tap Done.
Future<void> _setClock(WidgetTester t, Finder field, int hour, [int minute = 0]) async {
  await _tap(t, field);
  turnWheels(t, hour, minute);
  await t.pump(const Duration(milliseconds: 100));
  await _tap(t, find.text('Done'));
}

Finder get _post => find.text('Post');

/// Taps Post. The card scrolls when the screen is short or the text large, so Post is scrolled into view first.
Future<void> _postIt(WidgetTester t) async {
  await t.ensureVisible(_post);
  await t.pump();
  await _tap(t, _post);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient(_answer));
  });

  setUp(() {
    api.token = 'test';
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Core Academy', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
    _papers = [];
    _bankFails = null;
    _publishFails = false;
    _hold = null;
    _onPublish = null;
    _calls.clear();
    _bodies.clear();
  });

  group('the list', () {
    testWidgets('a Bank with nothing in it says so', (t) async {
      await _open(t);
      expect(find.text('Bank'), findsOneWidget);
      expect(find.text('SAVED PAPERS'), findsOneWidget);
      expect(find.text('Nothing in the Bank yet'), findsOneWidget);
      expect(find.byType(FilterBar), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('each paper is a row with its name, its class and subject, its size and when it was given', (t) async {
      _papers = [
        _paper('a', 'Real Numbers test', uses: 3, given: _day(-6, 8)),
        _paper('b', 'Polynomials test', cls: 10, subject: 'Science', questions: 12, given: _day(-1, 8)),
      ];
      await _open(t);
      expect(find.text('2 PAPERS'), findsOneWidget);
      expect(find.text('Real Numbers test'), findsOneWidget);
      expect(find.text('9th Maths · 20 questions\nGiven 3 times · last ${f.dayDate(_day(-6, 8))}'), findsOneWidget);
      expect(find.text('Polynomials test'), findsOneWidget);
      expect(find.text('10th Science · 12 questions\nGiven ${f.dayDate(_day(-1, 8))}'), findsOneWidget);
      expect(find.text('Every test you post is kept here. Tap one to post it again.'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a paper whose test has not opened yet is coming up', (t) async {
      _papers = [_paper('a', 'Algebra test', given: _day(3, 16)), _paper('b', 'Again', uses: 2, given: _day(2, 16))];
      await _open(t);
      expect(find.text('9th Maths · 20 questions\nComing up ${f.dayDate(_day(3, 16))}'), findsOneWidget);
      expect(find.text('9th Maths · 20 questions\nGiven 2 times · next ${f.dayDate(_day(2, 16))}'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a course\'s paper names its course, and has no class or subject', (t) async {
      _papers = [_paper('c', 'Tenses quiz', courseId: 'c-1', course: 'Spoken English')];
      await _open(t);
      expect(find.text('Spoken English · 20 questions\nGiven ${f.dayDate(_day(-5, 8))}'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a Bank that cannot be loaded says why and can be tried again', (t) async {
      _bankFails = 'The server is down.';
      await _open(t);
      expect(find.text('The server is down.'), findsOneWidget);
      _bankFails = null;
      _papers = [_paper('a', 'Real Numbers test')];
      await _tap(t, find.text('Try again'));
      expect(find.text('Real Numbers test'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the filters', () {
    final mixed = [
      _paper('a', 'Real Numbers test', given: _day(-1, 8)),
      _paper('b', 'Polynomials test', given: _day(-2, 8)),
      _paper('c', 'Cells quiz', subject: 'Science', given: _day(-3, 8)),
      _paper('d', 'Trigonometry test', cls: 10, given: _day(-4, 8)),
      _paper('e', 'Light quiz', cls: 10, subject: 'Science', given: _day(-5, 8)),
      _paper('f', 'Tenses quiz', courseId: 'c-1', course: 'Spoken English', given: _day(-6, 8)),
    ];

    testWidgets('both start on All, with every paper showing', (t) async {
      _papers = mixed;
      await _open(t);
      expect(find.text('All classes & courses'), findsOneWidget);
      expect(find.text('All subjects'), findsOneWidget);
      for (final p in mixed) {
        expect(find.text('${p['title']}'), findsOneWidget);
      }
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the class list names every class and course the papers are for, with how many each has', (t) async {
      _papers = mixed;
      await _open(t);
      await _tap(t, find.text('All classes & courses'));
      expect(find.text('Class 9'), findsOneWidget);
      expect(find.text('Class 10'), findsOneWidget);
      expect(find.text('Spoken English'), findsOneWidget);
      expect(find.text('Class 8'), findsNothing, reason: 'only what the papers have');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('choosing a class narrows the list to it, and says how many of how many', (t) async {
      _papers = mixed;
      await _open(t);
      await _tap(t, find.text('All classes & courses'));
      await _tap(t, find.text('Class 10'));
      expect(find.text('Trigonometry test'), findsOneWidget);
      expect(find.text('Light quiz'), findsOneWidget);
      expect(find.text('Real Numbers test'), findsNothing);
      expect(find.text('Tenses quiz'), findsNothing);
      expect(find.text('2 OF 6 PAPERS'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('choosing a subject narrows it further, and the subjects offered are the class\'s own', (t) async {
      _papers = mixed;
      await _open(t);
      await _tap(t, find.text('All classes & courses'));
      await _tap(t, find.text('Class 9'));
      await _tap(t, find.text('All subjects'));
      expect(find.text('Maths'), findsOneWidget);
      expect(find.text('Science'), findsOneWidget);
      await _tap(t, find.text('Science'));
      expect(find.text('Cells quiz'), findsOneWidget);
      expect(find.text('Real Numbers test'), findsNothing);
      expect(find.text('Light quiz'), findsNothing, reason: 'that is class 10');
      expect(find.text('1 OF 6 PAPERS'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a subject across every class, when no class is chosen', (t) async {
      _papers = mixed;
      await _open(t);
      await _tap(t, find.text('All subjects'));
      await _tap(t, find.text('Science'));
      expect(find.text('Cells quiz'), findsOneWidget);
      expect(find.text('Light quiz'), findsOneWidget);
      expect(find.text('Tenses quiz'), findsNothing, reason: 'a course has no subject');
      expect(find.text('Trigonometry test'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a course has no subjects, so the subject box goes while it is chosen', (t) async {
      _papers = mixed;
      await _open(t);
      await _tap(t, find.text('All classes & courses'));
      await _tap(t, find.text('Spoken English'));
      expect(find.text('Tenses quiz'), findsOneWidget);
      expect(find.text('Real Numbers test'), findsNothing);
      expect(find.text('All subjects'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('changing the class drops a subject it does not have', (t) async {
      _papers = [_paper('a', 'Real Numbers test'), _paper('b', 'Cells quiz', subject: 'Science'), _paper('d', 'Trigonometry test', cls: 10)];
      await _open(t);
      await _tap(t, find.text('All subjects'));
      await _tap(t, find.text('Science'));
      expect(find.text('Cells quiz'), findsOneWidget);
      await _tap(t, find.text('All classes'));
      await _tap(t, find.text('Class 10'));
      expect(find.text('Trigonometry test'), findsOneWidget);
      expect(find.text('All subjects'), findsOneWidget, reason: 'class 10 has no Science');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('only classes: the box says All classes, only courses: All courses', (t) async {
      _papers = [_paper('a', 'Real Numbers test')];
      await _open(t);
      expect(find.text('All classes'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
      _papers = [_paper('c', 'Tenses quiz', courseId: 'c-1', course: 'Spoken English')];
      await _open(t);
      expect(find.text('All courses'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('posting again', () {
    final fourToSix = _paper('a', 'Real Numbers test', uses: 2, given: _day(-6, 16, 30), closes: _day(-6, 18), limit: 45, shuffle: false);

    testWidgets('a tap on a paper asks when, starting from tomorrow and the times, limit and order its test had', (t) async {
      _papers = [fourToSix];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      expect(find.text('Post again'), findsOneWidget);
      expect(find.text('9th Maths · 20 questions\nGoes to the whole group'), findsOneWidget);
      expect(find.text('Real Numbers test'), findsNWidgets(2), reason: 'in the list, and the name to change');
      expect(find.text(f.dayTitle(_day(1))), findsOneWidget);
      expect(find.text(_clock(16, 30)), findsOneWidget, reason: 'it opened at half past four');
      expect(find.text(_clock(18)), findsOneWidget, reason: 'and closed at six');
      expect(find.text('45 min'), findsOneWidget);
      expect(find.text('Same for all'), findsOneWidget);
      expect(_calls, ['GET /teacher/bank'], reason: 'nothing is made by asking');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Post makes the test from the paper\'s questions, for the group, as asked, and posts it', (t) async {
      _papers = [fourToSix];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await _postIt(t);
      expect(_calls, containsAllInOrder(['GET /teacher/bank', 'GET /teacher/tests/a', 'POST /teacher/tests', 'POST /teacher/tests/new-1/publish']));
      final body = _bodies['POST /teacher/tests']!;
      expect(body['title'], 'Real Numbers test');
      expect(body['question_ids'], [for (var i = 1; i <= 20; i++) 'q-a-$i']);
      expect(body['class_level'], 9);
      expect(body['subject_id'], 'sub-Maths');
      expect(body['assign_all'], false);
      expect(body['assign_group'], true);
      expect(body['student_ids'], isEmpty);
      expect(body['time_limit_min'], 45);
      expect(body['shuffle'], false);
      expect(body['paper_id'], 'paper-a');
      expect(body.containsKey('course_id'), isFalse);
      expect(DateTime.parse(body['opens_at'] as String).toLocal(), _day(1, 16, 30));
      expect(DateTime.parse(body['closes_at'] as String).toLocal(), _day(1, 18));
      expect(_bodies['POST /teacher/tests/new-1/publish'], {'published': true});
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('then it says it is posted and when, and OK goes back to the list', (t) async {
      _papers = [fourToSix];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await _postIt(t);
      expect(find.text('Posted'), findsOneWidget);
      expect(
        find.text('Real Numbers test opens ${f.whenDate(_day(1, 16, 30))} and closes at ${f.time(_day(1, 18))}. Students are told when it opens.'),
        findsOneWidget,
      );
      await _tap(t, find.text('OK'));
      expect(find.text('Posted'), findsNothing);
      expect(find.text('Real Numbers test'), findsOneWidget);
      expect(_router.state.uri.path, '/t/bank');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Open the test goes to the new test', (t) async {
      _papers = [fourToSix];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await _postIt(t);
      await _tap(t, find.text('Open the test'));
      expect(_router.state.uri.path, '/t/tests/new-1');
      expect(find.text('the test new-1'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the name, the day and the times can be changed first', (t) async {
      _papers = [fourToSix];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await t.enterText(find.byType(EditableText), 'Real Numbers, week 2');
      await t.pump();
      await _tap(t, find.text(f.dayTitle(_day(1))));
      await _tap(t, find.text(f.dayTitle(_day(4))));
      await _setClock(t, find.text(_clock(16, 30)), 7, 5);
      await _setClock(t, find.text(_clock(18)), 23, 40);
      await _postIt(t);
      final body = _bodies['POST /teacher/tests']!;
      expect(body['title'], 'Real Numbers, week 2');
      expect(DateTime.parse(body['opens_at'] as String).toLocal(), _day(4, 7, 5));
      expect(DateTime.parse(body['closes_at'] as String).toLocal(), _day(4, 23, 40));
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a name cleared goes back to the paper\'s own', (t) async {
      _papers = [fourToSix];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await t.enterText(find.byType(EditableText), '   ');
      await t.pump();
      await _postIt(t);
      expect(_bodies['POST /teacher/tests']!['title'], 'Real Numbers test');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a paper with no time limit is given a minute and a half a question, as the others are', (t) async {
      _papers = [_paper('a', 'Real Numbers test', limit: null, questions: 20)];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      expect(find.text('1½ minutes a question'), findsOneWidget);
      await _postIt(t);
      expect(_bodies['POST /teacher/tests']!['time_limit_min'], 30);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('students chosen one by one are chosen again, and the card says how many', (t) async {
      _papers = [_paper('a', 'Remedial test', group: false, chosen: 3, questions: 5)];
      await _open(t);
      await _tap(t, find.text('Remedial test'));
      expect(find.text('9th Maths · 5 questions\nGoes to the 3 students chosen before'), findsOneWidget);
      await _postIt(t);
      final body = _bodies['POST /teacher/tests']!;
      expect(body['assign_group'], false);
      expect(body['assign_all'], false);
      expect(body['student_ids'], ['s-a-1', 's-a-2', 's-a-3']);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a course\'s paper is posted to the course, with no class or subject', (t) async {
      _papers = [_paper('c', 'Tenses quiz', courseId: 'c-1', course: 'Spoken English', questions: 8)];
      await _open(t);
      await _tap(t, find.text('Tenses quiz'));
      expect(find.text('Spoken English · 8 questions\nGoes to everyone in the course'), findsOneWidget);
      await _postIt(t);
      final body = _bodies['POST /teacher/tests']!;
      expect(body['course_id'], 'c-1');
      for (final k in ['class_level', 'subject_id', 'assign_all', 'assign_group', 'student_ids']) {
        expect(body.containsKey(k), isFalse, reason: '$k is not sent for a course');
      }
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a test that ran over midnight starts from the usual times, not from a closing time before the opening', (t) async {
      _papers = [_paper('a', 'Night test', given: _day(-3, 21), closes: _day(-2, 6))];
      await _open(t);
      await _tap(t, find.text('Night test'));
      expect(find.text(_clock(8)), findsOneWidget);
      expect(find.text(_clock(21)), findsOneWidget);
      expect(find.text('The test has to close after it opens.'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('closing the card without Post makes nothing', (t) async {
      _papers = [fourToSix];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await _tap(t, find.byIcon(Ph.x));
      expect(find.text('Post again'), findsNothing);
      expect(_calls, ['GET /teacher/bank']);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a closing time that has passed cannot be posted, and the card says so', (t) async {
      final now = DateTime.now();
      if (now.hour == 0 && now.minute < 15) return;
      _papers = [fourToSix];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await _tap(t, find.text(f.dayTitle(_day(1))));
      await _tap(t, find.text(f.dayTitle(_day(0))));
      await _setClock(t, find.text(_clock(16, 30)), 0, 1);
      await _setClock(t, find.text(_clock(18)), 0, 5);
      expect(find.text('That closing time has already passed. Choose a later time or day.'), findsOneWidget);
      await _postIt(t);
      expect(find.text('Post again'), findsOneWidget, reason: 'the card stays');
      expect(_calls, ['GET /teacher/bank']);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an opening time that has passed opens the test at once', (t) async {
      final now = DateTime.now();
      if (now.hour == 0 && now.minute < 15 || now.hour == 23 && now.minute > 40) return;
      _papers = [fourToSix];
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await _tap(t, find.text(f.dayTitle(_day(1))));
      await _tap(t, find.text(f.dayTitle(_day(0))));
      await _setClock(t, find.text(_clock(16, 30)), 0, 1);
      await _setClock(t, find.text(_clock(18)), 23, 55);
      await _postIt(t);
      final body = _bodies['POST /teacher/tests']!;
      expect(body.containsKey('opens_at'), isFalse, reason: 'no opening time is open now');
      expect(DateTime.parse(body['closes_at'] as String).toLocal(), _day(0, 23, 55));
      expect(find.text('Real Numbers test is open now and closes ${f.whenDate(_day(0, 23, 55))}. Students are told when it opens.'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a test that could not be posted is taken away again and the problem is shown', (t) async {
      _papers = [fourToSix];
      _publishFails = true;
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await _postIt(t);
      expect(_calls, containsAllInOrder(['POST /teacher/tests', 'POST /teacher/tests/new-1/publish', 'DELETE /teacher/tests/new-1']));
      expect(find.text('That did not work'), findsOneWidget);
      expect(find.text('The closing time has already passed. Choose a later one.'), findsOneWidget);
      expect(find.text('Posted'), findsNothing);
      await _tap(t, find.text('OK'));
      expect(find.text('Real Numbers test'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('while it posts, no other paper can be started, and the list says so', (t) async {
      _papers = [fourToSix, _paper('b', 'Polynomials test')];
      _hold = Completer<void>();
      await _open(t);
      await _tap(t, find.text('Real Numbers test'));
      await _postIt(t);
      expect(find.text('Posting the test…'), findsOneWidget);
      await _tap(t, find.text('Polynomials test'));
      expect(find.text('Post again'), findsNothing, reason: 'the second tap does nothing');
      _hold!.complete();
      await _settle(t);
      expect(find.text('Posted'), findsOneWidget);
      expect(find.text('Posting the test…'), findsNothing);
      expect(_calls.where((c) => c == 'POST /teacher/tests'), hasLength(1));
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the Bank loads again once a test is posted, so the paper shows its new use', (t) async {
      _papers = [fourToSix];
      _onPublish = () => _papers = [_paper('a', 'Real Numbers test', uses: 3, given: _day(1, 16, 30))];
      await _open(t);
      expect(find.text('9th Maths · 20 questions\nGiven 2 times · last ${f.dayDate(_day(-6, 16, 30))}'), findsOneWidget);
      await _tap(t, find.text('Real Numbers test'));
      await _postIt(t);
      await _tap(t, find.text('OK'));
      await _settle(t);
      expect(find.text('9th Maths · 20 questions\nGiven 3 times · next ${f.dayDate(_day(1, 16, 30))}'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('how it looks', () {
    testWidgets('in the dark', (t) async {
      _papers = [_paper('a', 'Real Numbers test', uses: 2), _paper('b', 'Tenses quiz', courseId: 'c-1', course: 'Spoken English')];
      await _open(t, dark: true);
      expect(t.takeException(), isNull);
      await _tap(t, find.text('Real Numbers test'));
      expect(find.text('Post again'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('on a narrow phone with the largest text the list and the card fit, and Post can be reached', (t) async {
      _papers = [
        _paper('a', 'Arithmetic progressions and the nth term of one', uses: 12, given: _day(-6, 8), cls: 12, subject: 'Mathematics'),
        _paper('b', 'Tenses quiz', courseId: 'c-1', course: 'Spoken English for working adults'),
      ];
      await _open(t, width: 320, scale: 2.0);
      expect(t.takeException(), isNull);
      await _tap(t, find.textContaining('Arithmetic progressions'));
      expect(t.takeException(), isNull);
      expect(find.text('Post'), findsOneWidget);
      await _postIt(t);
      expect(_bodies['POST /teacher/tests']!['class_level'], 12);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });
}
