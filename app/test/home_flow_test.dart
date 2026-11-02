// The tutor's Home and Classes, as the tutor uses them: Make tests asks which class, then opens the papers step; every row
// opens what it says; a Home with nothing on it says what to do first; the papers waiting are found again.
//   flutter test test/home_flow_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/classes_screen.dart';
import 'package:core_academy/features/teacher/home_screen.dart';
import 'package:core_academy/features/teacher/make_test.dart' show MakeTests;
import 'package:core_academy/features/teacher/make_tests_screen.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

var _home = <String, Object?>{};

Future<http.Response> _answer(http.Request r) async {
  if (r.url.path == '/teacher/home') {
    return http.Response.bytes(utf8.encode(jsonEncode(_home)), 200, headers: {'content-type': 'application/json'});
  }
  return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.url.path}'}}), 404);
}

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();

Map<String, Object?> _group(int cls, String subject, int students, {List<Object?> live = const [], List<Object?> posted = const []}) =>
    {'class_level': cls, 'subject_id': 'sub-$subject', 'subject': subject, 'students': students, 'live': live, 'posted': posted};

Map<String, Object?> _course(String id, String name, int people, {List<Object?> live = const [], List<Object?> posted = const []}) =>
    {'id': id, 'name': name, 'people': people, 'live': live, 'posted': posted};

Map<String, Object?> _test(String id, String title, {Duration? opens, Duration? closes, int assigned = 12, int submitted = 0, int writing = 0}) => {
      'id': id, 'title': title, 'opens_at': opens == null ? null : _iso(opens), 'closes_at': closes == null ? null : _iso(closes),
      'time_limit_min': 30, 'assigned': assigned, 'submitted': submitted, 'writing': writing,
    };

Map<String, Object?> _finished(String id, String title, {int? cls, String? subject, String? course, required Duration closed, int assigned = 12, int submitted = 11}) => {
      'id': id, 'title': title, 'class_level': cls, 'subject_id': subject == null ? null : 'sub-$subject', 'subject': subject,
      'course_id': course == null ? null : 'c-1', 'course': course, 'closes_at': _iso(closed), 'everyone_done': false,
      'assigned': assigned, 'submitted': submitted, 'writing': 0,
    };

Map<String, Object?> _paper(String id, String name, {int? cls, String? subject, int pages = 2, int read = 2, int toCheck = 0, int saved = 0}) => {
      'id': id, 'exam_name': name, 'class_level': cls, 'subject_id': subject == null ? null : 'sub-$subject', 'subject': subject, 'course_id': null,
      'course': null, 'page_count': pages, 'pages_read': read, 'to_check': toCheck, 'saved': saved, 'has_test': false, 'created_at': _iso(const Duration(hours: -3)),
    };

Map<String, Object?> _data({
  int pending = 0,
  List<Object?>? groups,
  List<Object?>? courses,
  List<Object?>? finished,
  List<Object?>? papers,
  bool oldServer = false,
}) =>
    {
      'server_now': _iso(Duration.zero),
      'tuition': {'id': 't-1', 'name': 'Core Academy', 'join_code': 'KR74MQ'},
      'pending_requests': pending,
      'groups': groups ?? [],
      'totals': {'live': 0, 'writing': 0},
      'courses': courses ?? [],
      if (!oldServer) 'finished': finished ?? [],
      if (!oldServer) 'papers': papers ?? [],
    };

/// Where the router took the tutor last, as a string like /t/papers/new?class=10.
String? _at;

GoRouter _router(Widget home) {
  Widget page(GoRouterState s) {
    _at = s.uri.toString();
    return Scaffold(body: Center(child: Text('at ${s.uri}')));
  }

  return GoRouter(routes: [
    GoRoute(path: '/', builder: (_, _) => Scaffold(body: home)),
    // The real Make tests screen, so the steps after the button can be followed.
    GoRoute(
      path: '/t/make',
      builder: (_, s) {
        final m = s.extra as MakeTests?;
        return MakeTestsScreen(target: m?.target, targets: m?.targets ?? const []);
      },
    ),
    for (final p in ['/t/papers/new', '/t/papers/:id', '/t/papers', '/t/groups/:cls/:subject', '/t/groups/:cls/:subject/chat', '/t/courses/:id', '/t/courses/:id/chat', '/t/requests', '/t/code', '/t/tests/:id'])
      GoRoute(path: p, builder: (_, s) => page(s)),
  ]);
}

Future<void> _open(WidgetTester t, Widget home, {double height = 900}) async {
  t.view.physicalSize = Size(411 * 2.625, height * 2.625);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  _at = null;
  await t.pumpWidget(MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: _router(home)));
  await _settle(t);
}

Future<void> _settle(WidgetTester t, [int ms = 2500]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await _settle(t, 300);
  await t.tap(f);
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
    api.token = 'test';
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Core Academy', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
  });

  group('Make tests', () {
    testWidgets('asks which class, then opens the papers step for that class', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12), _group(9, 'Science', 9)], courses: [_course('c-1', 'Spoken English, Batch 1', 14)]);
      await _open(t, const TutorHome());
      await _tap(t, find.text('Make tests'));
      expect(find.text('Which class are the tests for?'), findsOneWidget);
      expect(find.text('10th Maths'), findsWidgets);
      expect(find.text('Spoken English, Batch 1'), findsWidgets);
      expect(find.text('14 people · course'), findsOneWidget);
      expect(find.text('12 students'), findsOneWidget);
      await _tap(t, find.text('9th Science'));
      await _tap(t, find.text('Next'));
      expect(find.text('Add the papers'), findsOneWidget);
      expect(find.text('9TH SCIENCE · STEP 2 OF 4'), findsOneWidget);
      expect(find.text('Choose PDFs'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a course is chosen like a group, and its papers become the course tests', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12)], courses: [_course('c-1', 'Spoken English, Batch 1', 14)]);
      await _open(t, const TutorHome());
      await _tap(t, find.text('Make tests'));
      await _tap(t, find.text('Spoken English, Batch 1').last);
      await _tap(t, find.text('Next'));
      expect(find.text('SPOKEN ENGLISH, BATCH 1 · STEP 2 OF 4'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('with one class there is nothing to choose: it opens on the papers at once', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12)]);
      await _open(t, const TutorHome());
      await _tap(t, find.text('Make tests'));
      expect(find.text('Which class are the tests for?'), findsNothing);
      expect(find.text('Add the papers'), findsOneWidget);
      expect(find.text('10TH MATHS · STEP 2 OF 4'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('no paper: AI can write the test, which opens the description page of that group', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12)]);
      await _open(t, const TutorHome());
      await _tap(t, find.text('Make tests'));
      await _tap(t, find.text('No paper? Let AI write a test'));
      expect(_at, '/t/groups/10/sub-Maths/chat?name=Maths');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('no paper for a course opens the description page of that course', (t) async {
      _home = _data(courses: [_course('c-1', 'Spoken English, Batch 1', 14)]);
      await _open(t, const TutorHome());
      await _tap(t, find.text('Make tests'));
      await _tap(t, find.text('No paper? Let AI write a test'));
      expect(_at, '/t/courses/c-1/chat?name=Spoken%20English%2C%20Batch%201');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Back from the papers goes to the class list, and Back from there to Home', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12), _group(9, 'Science', 9)]);
      await _open(t, const TutorHome());
      await _tap(t, find.text('Make tests'));
      await _tap(t, find.text('Next'));
      expect(find.text('Add the papers'), findsOneWidget);
      await _tap(t, find.byIcon(Ph.arrowLeft));
      expect(find.text('Which class are the tests for?'), findsOneWidget);
      await _tap(t, find.byIcon(Ph.arrowLeft));
      expect(find.text('Which class are the tests for?'), findsNothing);
      expect(find.text('Make tests'), findsOneWidget, reason: 'back on Home');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a tuition with no class says to add one first, and has no Make tests button', (t) async {
      _home = _data();
      await _open(t, const TutorHome());
      expect(find.text('No classes yet'), findsOneWidget);
      expect(find.text('Add a class'), findsOneWidget);
      expect(find.text('Make tests'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Home', () {
    testWidgets('what needs the tutor comes first, and each row opens what it says', (t) async {
      _home = _data(
        pending: 2,
        groups: [_group(10, 'Maths', 12)],
        papers: [_paper('p1', 'Quadratic equations', cls: 10, subject: 'Maths', toCheck: 4), _paper('p2', 'Triangles', cls: 10, subject: 'Maths', pages: 3, read: 1)],
      );
      await _open(t, const TutorHome());
      expect(find.text('NEEDS YOU'), findsNothing, reason: 'the rows that need her carry no small heading');
      expect(find.text('2 students want to join'), findsOneWidget);
      expect(find.text('2 papers to finish'), findsOneWidget);
      expect(find.text('Quadratic equations and 1 more'), findsOneWidget);
      await _tap(t, find.text('2 papers to finish'));
      expect(_at, '/t/papers');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('one paper waiting opens that paper', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12)], papers: [_paper('p1', 'Quadratic equations', cls: 10, subject: 'Maths', toCheck: 4)]);
      await _open(t, const TutorHome());
      expect(find.text('1 paper to finish'), findsOneWidget);
      expect(find.text('Quadratic equations · 10th Maths'), findsOneWidget);
      await _tap(t, find.text('1 paper to finish'));
      expect(_at, '/t/papers/p1');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('students waiting to join open the requests', (t) async {
      _home = _data(pending: 1, groups: [_group(10, 'Maths', 12)]);
      await _open(t, const TutorHome());
      await _tap(t, find.text('1 student wants to join'));
      expect(_at, '/t/requests');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a new tuition with no students is shown how to invite them', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 0)]);
      await _open(t, const TutorHome());
      expect(find.text('Invite your students'), findsOneWidget);
      expect(find.text('Join code KR7-4MQ'), findsOneWidget);
      await _tap(t, find.text('Invite your students'));
      expect(_at, '/t/code');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('every test is in one list with a tag: open now soonest-closing first, then coming up, then finished', (t) async {
      _home = _data(
        groups: [
          _group(10, 'Maths', 12, live: [_test('x1', 'Practice Paper 2', closes: const Duration(hours: 9), submitted: 7)], posted: [_test('x3', 'Real Numbers test', opens: const Duration(days: 5), closes: const Duration(days: 5, hours: 13))]),
          _group(9, 'Science', 9, posted: [_test('x2', 'Linear equations', opens: const Duration(days: 3), closes: const Duration(days: 3, hours: 13), assigned: 9)]),
        ],
        courses: [
          _course('c-1', 'Spoken English, Batch 1', 14, live: [_test('y1', 'Unit 1 quiz', closes: const Duration(hours: 3), submitted: 6, assigned: 14, writing: 3)]),
        ],
        finished: [_finished('f1', 'Greetings', course: 'Spoken English, Batch 1', closed: const Duration(days: -3), assigned: 14, submitted: 12)],
      );
      await _open(t, const TutorHome(), height: 1400);
      // No small headings: each row says what it is with a tag.
      for (final heading in ['OPEN NOW', 'COMING UP', 'FINISHED LATELY']) {
        expect(find.text(heading), findsNothing, reason: '$heading is a tag on each row now, not a heading');
      }
      expect(find.text('Open now'), findsNWidgets(2));
      expect(find.text('Coming up'), findsNWidgets(2));
      expect(find.text('Finished'), findsOneWidget);
      final unit = t.getTopLeft(find.text('Unit 1 quiz')).dy;
      final practice = t.getTopLeft(find.text('Practice Paper 2')).dy;
      expect(unit, lessThan(practice), reason: 'the test that closes first comes first');
      expect(find.textContaining('10th Maths · closes'), findsOneWidget);
      expect(find.text('3 writing now'), findsOneWidget);
      expect(find.text('7/12 handed in'), findsOneWidget);
      // Coming up: the soonest first (Linear equations opens before Real Numbers test), after everything that is open.
      final linear = t.getTopLeft(find.text('Linear equations')).dy;
      expect(linear, lessThan(t.getTopLeft(find.text('Real Numbers test')).dy));
      expect(practice, lessThan(linear), reason: 'what is open comes before what is coming up');
      expect(find.textContaining('9th Science · opens'), findsOneWidget);
      expect(find.textContaining('Spoken English, Batch 1 · closed'), findsOneWidget);
      expect(find.text('12/14 handed in'), findsOneWidget);
      expect(t.getTopLeft(find.text('Greetings')).dy, greaterThan(t.getTopLeft(find.text('Real Numbers test')).dy), reason: 'finished tests come last');
      await _tap(t, find.text('Greetings'));
      expect(_at, '/t/tests/f1');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a test that finished early because everyone handed it in says so', (t) async {
      final early = _finished('f9', 'Fractions', cls: 9, subject: 'Maths', closed: const Duration(days: 2), assigned: 5, submitted: 5);
      _home = _data(groups: [_group(9, 'Maths', 5)], finished: [early]);
      await _open(t, const TutorHome());
      expect(find.text('9th Maths · all handed in'), findsOneWidget);
      expect(find.text('5/5 handed in'), findsOneWidget);
      expect(find.text('Finished'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('with nothing open it says so, under the button', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12)], finished: [_finished('f1', 'Greetings', cls: 10, subject: 'Maths', closed: const Duration(days: -3))]);
      await _open(t, const TutorHome());
      expect(find.text('No test is open right now.'), findsOneWidget);
      expect(find.text('Open now'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('classes but no test yet: it says how to make one', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12)]);
      await _open(t, const TutorHome());
      expect(find.text('No tests yet'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a long list of tests shows eight and the rest on a tap', (t) async {
      _home = _data(groups: [
        _group(10, 'Maths', 12, posted: [for (var i = 0; i < 11; i++) _test('x$i', 'Test number $i', opens: Duration(days: 1 + i), closes: Duration(days: 1 + i, hours: 12))]),
      ]);
      await _open(t, const TutorHome(), height: 2600);
      expect(find.textContaining('Test number'), findsNWidgets(8));
      await _tap(t, find.text('Show all 11'));
      expect(find.textContaining('Test number'), findsNWidgets(11));
      await _tap(t, find.text('Show fewer'));
      expect(find.textContaining('Test number'), findsNWidgets(8));
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a server from before the finished and papers lists still gives a working Home', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12, live: [_test('x1', 'Practice Paper 2', closes: const Duration(hours: 9))])], oldServer: true);
      await _open(t, const TutorHome());
      expect(find.text('Practice Paper 2'), findsOneWidget);
      expect(find.text('Open now'), findsOneWidget);
      expect(find.text('Finished'), findsNothing);
      expect(find.text('NEEDS YOU'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Papers to finish', () {
    testWidgets('lists each paper with what is left on it, and opens it', (t) async {
      _home = _data(
        groups: [_group(10, 'Maths', 12)],
        papers: [
          _paper('p1', 'Quadratic equations', cls: 10, subject: 'Maths', toCheck: 4, saved: 12),
          _paper('p2', 'Triangles, unit test', cls: 9, subject: 'Maths', pages: 3, read: 1),
          _paper('p3', 'Polynomials', cls: 10, subject: 'Maths', saved: 8),
        ],
      );
      await _open(t, const PapersToFinishScreen());
      expect(find.text('Papers to finish'), findsOneWidget);
      expect(find.text('10th Maths · 4 questions to check'), findsOneWidget);
      expect(find.text('9th Maths · 1 of 3 pages read'), findsOneWidget);
      expect(find.text('10th Maths · Ready to make a test'), findsOneWidget);
      await _tap(t, find.text('Triangles, unit test'));
      expect(_at, '/t/papers/p2');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('with none waiting it says so', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12)]);
      await _open(t, const PapersToFinishScreen());
      expect(find.text('Nothing is waiting'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('Classes', () {
    testWidgets('lists groups and courses, with how many are open, and opens each', (t) async {
      _home = _data(
        groups: [_group(10, 'Maths', 12, live: [_test('x1', 'Practice Paper 2', closes: const Duration(hours: 3))]), _group(9, 'Science', 9)],
        courses: [_course('c-1', 'Spoken English, Batch 1', 14, posted: [_test('y2', 'Unit 2 quiz', opens: const Duration(days: 1), closes: const Duration(days: 1, hours: 4))])],
      );
      await _open(t, const ClassesScreen());
      expect(find.text('3 CLASSES'), findsOneWidget);
      // One list, no small headings: each row's tag says whether it is a group or a course.
      expect(find.text('GROUPS'), findsNothing);
      expect(find.text('COURSES'), findsNothing);
      expect(find.text('Group'), findsNWidgets(2));
      expect(find.text('Course'), findsOneWidget);
      expect(find.text('12 students'), findsOneWidget);
      expect(find.text('1 open'), findsOneWidget);
      expect(find.text('14 people · 1 coming up'), findsOneWidget);
      await _tap(t, find.text('10th Maths'));
      expect(_at, '/t/groups/10/sub-Maths?name=Maths');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a course opens its own page', (t) async {
      _home = _data(courses: [_course('c-1', 'Spoken English, Batch 1', 14)]);
      await _open(t, const ClassesScreen());
      expect(find.text('Group'), findsNothing);
      expect(find.text('Course'), findsOneWidget);
      await _tap(t, find.text('Spoken English, Batch 1'));
      expect(_at, '/t/courses/c-1?name=Spoken%20English%2C%20Batch%201');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Add a class asks what kind, and a course asks for its name', (t) async {
      _home = _data(groups: [_group(10, 'Maths', 12)]);
      await _open(t, const ClassesScreen());
      await _tap(t, find.text('Add a class'));
      expect(find.text('What kind?'), findsOneWidget);
      expect(find.text('A group'), findsOneWidget);
      expect(find.text('A course'), findsOneWidget);
      await _tap(t, find.text('A course'));
      expect(find.text('New course'), findsOneWidget);
      expect(find.text('Course name'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a tuition with no class has an Add a class button in the middle of the page', (t) async {
      _home = _data();
      await _open(t, const ClassesScreen());
      expect(find.text('No classes yet'), findsOneWidget);
      expect(find.text('Add a class'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });
}
