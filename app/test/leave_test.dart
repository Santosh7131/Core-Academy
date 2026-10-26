// Leaving a test goes back to the screen it was opened from, and the test is one tap away again with the
// answers that were already given. The course page and the test screen are the real ones, against a stub server.
//   flutter test test/leave_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/student/course_screen.dart';
import 'package:core_academy/features/student/test_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the stub server remembers between calls, the way the real one does.
var _started = false;
final _chosen = <String, int?>{};
var _starts = 0;

String _iso(Duration from) => DateTime.now().toUtc().add(from).toIso8601String();

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});

Future<http.Response> _server(http.Request r) async {
  final path = r.url.path;
  if (r.method == 'GET' && path == '/student/courses/c1') {
    return _json({
      'course': {'id': 'c1', 'name': 'Spoken English'},
      'tests': [
        {
          'id': 't1',
          'title': 'Everyday phrases',
          'state': _started ? 'in_progress' : 'open',
          'question_count': 2,
          'max_marks': 2,
          'time_limit_min': 15,
          'closes_at': _iso(const Duration(days: 2)),
          if (_started) 'attempt': {'id': 'a1', 'deadline_at': _iso(const Duration(minutes: 14))},
        },
      ],
    });
  }
  if (r.method == 'POST' && path == '/student/tests/t1/start') {
    _started = true;
    _starts++;
    return _json({
      'attempt': {'id': 'a1', 'server_now': _iso(Duration.zero), 'deadline_at': _iso(const Duration(minutes: 14))},
      'questions': [
        {'id': 'q1', 'n': 1, 'text': 'Which sentence is correct?', 'image_url': null, 'options': ["She don't like tea.", "She doesn't like tea."], 'chosen': _chosen['q1'], 'flagged': false},
        {'id': 'q2', 'n': 2, 'text': 'Which word fits the gap?', 'image_url': null, 'options': ['was', 'were'], 'chosen': _chosen['q2'], 'flagged': false},
      ],
    });
  }
  if (r.method == 'PUT' && path == '/student/attempts/a1/answers') {
    for (final a in (jsonDecode(r.body)['answers'] as List)) {
      _chosen[a['question_id'] as String] = a['choice'] as int?;
    }
    return _json({});
  }
  return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.method} $path'}}), 404);
}

/// Time passes in frames, with room for the card and page transitions.
Future<void> _wait(WidgetTester t, [int ms = 600]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _leaveTest(WidgetTester t) async {
  await t.tap(find.bySemanticsLabel('Leave test'));
  await _wait(t);
  expect(find.text('Leave the test?'), findsOneWidget);
  await t.tap(find.text('Leave'));
  await _wait(t);
}

/// The stack a student has: the home list, then the course page, then the test.
GoRouter _router({String start = '/s'}) => GoRouter(
      initialLocation: start,
      routes: [
        GoRoute(path: '/s', builder: (_, _) => const _Home()),
        GoRoute(path: '/s/courses/:id', builder: (_, s) => StudentCourseScreen(id: s.pathParameters['id']!, name: 'Spoken English')),
        GoRoute(path: '/s/write/:id', builder: (_, s) => TestScreen(testId: s.pathParameters['id']!)),
      ],
    );

/// A home list with one class test, opened the way the real home opens it: push, then look again when it comes back.
class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  int back = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          const Text('HOME'),
          Text('came back $back times'),
          TextButton(
            onPressed: () async {
              await context.push('/s/write/t1');
              if (mounted) setState(() => back++);
            },
            child: const Text('Open class test'),
          ),
          TextButton(onPressed: () => context.push('/s/courses/c1'), child: const Text('Open course')),
        ]),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient(_server));
  });

  setUp(() {
    _started = false;
    _chosen.clear();
    _starts = 0;
  });

  testWidgets('leaving a course test lands on the course page, and Continue brings the test back with its answers', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(MaterialApp.router(routerConfig: _router()));
    await _wait(t);
    await t.tap(find.text('Open course'));
    await _wait(t);
    expect(find.text('Start test'), findsOneWidget);

    // Start it: the card first, then the test.
    await t.tap(find.text('Start test'));
    await _wait(t);
    await t.tap(find.text('Start test').last);
    await _wait(t, 900);
    expect(find.text('Which sentence is correct?'), findsOneWidget);

    // Answer the first question, then leave.
    await t.tap(find.text("She doesn't like tea."));
    await _wait(t, 900);
    expect(_chosen['q1'], 1, reason: 'the answer reaches the server before the student leaves');
    await _leaveTest(t);

    // Back on the course page, not the home list, and the test shows as under way.
    expect(find.text('Which sentence is correct?'), findsNothing);
    expect(find.text('Spoken English'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
    expect(find.text('Continue test'), findsOneWidget);

    // One tap and they are back in, on the question they have not answered.
    await t.tap(find.text('Continue test'));
    await _wait(t, 900);
    expect(_starts, 2);
    expect(find.text('Which word fits the gap?'), findsOneWidget);

    await t.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('leaving a class test goes back to the home list, which looks again', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(MaterialApp.router(routerConfig: _router()));
    await _wait(t);
    await t.tap(find.text('Open class test'));
    await _wait(t, 900);
    expect(find.text('Which sentence is correct?'), findsOneWidget);
    await _leaveTest(t);
    expect(find.text('HOME'), findsOneWidget);
    expect(find.text('came back 1 times'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('a test opened with nothing underneath goes home', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(MaterialApp.router(routerConfig: _router(start: '/s/write/t1')));
    await _wait(t, 900);
    expect(find.text('Which sentence is correct?'), findsOneWidget);
    await _leaveTest(t);
    expect(find.text('HOME'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    semantics.dispose();
  });
}
