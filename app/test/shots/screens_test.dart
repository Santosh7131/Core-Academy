// Draws the multi-tuition screens to PNG files on this PC (no phone, no emulator): the real widgets and
// fonts, answers from a stub server. Without SHOTS=1 it only checks that each screen builds.
//   SHOTS=1 flutter test test/shots/screens_test.dart
// Pictures go to ../tools/out/shots (git-ignored).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/auth/login_screen.dart';
import 'package:core_academy/features/auth/start_screen.dart';
import 'package:core_academy/features/auth/signup_screen.dart';
import 'package:core_academy/features/student/home_screen.dart';
import 'package:core_academy/features/student/join_screen.dart';
import 'package:core_academy/features/student/profile_screen.dart';
import 'package:core_academy/features/student/result_screen.dart';
import 'package:core_academy/features/student/test_screen.dart';
import 'package:core_academy/features/teacher/group_screens.dart';
import 'package:core_academy/features/teacher/join_requests_screen.dart';
import 'package:core_academy/features/teacher/papers_screens.dart';
import 'package:core_academy/features/teacher/settings_screen.dart';
import 'package:core_academy/features/teacher/setup_screen.dart';
import 'package:core_academy/features/teacher/students_screens.dart';
import 'package:core_academy/features/teacher/share_code_screen.dart';
import 'package:core_academy/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _shots = Platform.environment['SHOTS'] == '1';

/// LANDSCAPE=1 draws every screen on its side (a phone turned round), to find what no longer fits.
final _landscape = Platform.environment['LANDSCAPE'] == '1';
final _boundary = GlobalKey();
const _ratio = 2.625;

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();

/// What the stub server answers, by path. Replaced by each test.
final routes = <String, Object? Function(http.Request)>{};

/// A route that answers only when its future completes, so a screen can be drawn while it waits.
final holds = <String, Future<void>>{};

Future<http.Response> _answer(http.Request r) async {
  final key = '${r.method} ${r.url.path}';
  final hold = holds[key] ?? holds[r.url.path];
  if (hold != null) await hold;
  final h = routes[key] ?? routes[r.url.path];
  if (h == null) {
    return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.url.path}'}}), 404);
  }
  return http.Response.bytes(utf8.encode(jsonEncode(h(r))), 200, headers: {'content-type': 'application/json'});
}

Map<String, Object?> _tuition({int pending = 2, bool open = true, String role = 'owner'}) => {
      'id': 't-1', 'name': 'Priya Maths Classes', 'join_code': 'KR74MQ', 'join_code_shown': 'KR7-4MQ', 'join_open': open,
      'role': role, 'pending': pending, 'students': 18, 'tutors': 2, 'groups': 4,
    };

Future<void> _show(WidgetTester t, Widget screen, {bool dark = false, double height = 2400}) async {
  setResolvedDark(dark);
  t.view.physicalSize = _landscape ? const Size(2400, 1080) : Size(1080, height);
  t.view.devicePixelRatio = _ratio;
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(
    key: _boundary,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(dark ? Brightness.dark : Brightness.light), home: screen),
  ));
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 34; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  if (!_shots) return;
  await t.runAsync(() async {
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_boundary));
    final image = await boundary.toImage(pixelRatio: _ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../tools/out/shots/$name${_landscape ? '-land' : ''}.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// The screen in light and dark, each saved as `name-light` and `name-dark`.
Future<void> _both(WidgetTester t, String name, Widget Function() screen, {double height = 2400, Future<void> Function(WidgetTester)? then}) async {
  for (final dark in [false, true]) {
    await _show(t, screen(), dark: dark, height: height);
    if (then != null) await then(t);
    await _shot(t, '$name-${dark ? 'dark' : 'light'}');
    await t.pumpWidget(const SizedBox.shrink()); // dispose: stops the screens' refresh timers
  }
}

void _sessionAs({required String role, List<Map<String, dynamic>> tuitions = const [], String? tuitionId}) {
  api.token = 'test';
  session.user = {'id': 'u-1', 'role': role, 'username': role == 'teacher' ? 'priya' : 'harini.v', 'display_name': role == 'teacher' ? 'Priya' : 'Harini Venkatesh', 'class_level': role == 'teacher' ? null : 9};
  session.tuitions = tuitions;
  session.tuitionId = tuitionId ?? (tuitions.isEmpty ? null : tuitions.first['id'] as String);
  final active = session.activeTuition;
  if (active != null) session.tuitionName = '${active['name']}';
}

/// A screenshot test. Tests draw shadows as flat blocks by default; the pictures should show them as a phone
/// does, and the test framework wants the default back before the test ends.
void shotTest(String name, Future<void> Function(WidgetTester t) body) => testWidgets(name, (t) async {
      debugDisableShadows = false;
      try {
        await body(t);
      } finally {
        debugDisableShadows = true;
      }
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    for (final (family, asset) in [('Geist', 'assets/fonts/Geist.ttf'), ('GeistMono', 'assets/fonts/GeistMono.ttf'), ('PhosphorLight', 'assets/fonts/PhosphorLight.ttf')]) {
      final loader = FontLoader(family)..addFont(rootBundle.load(asset));
      await loader.load();
    }
    // The maths package's own fonts, so formulas draw as they do on a phone and not as boxes.
    const katex = {
      'KaTeX_Main': ['Regular', 'Italic', 'Bold', 'BoldItalic'],
      'KaTeX_Math': ['Italic', 'BoldItalic'],
      'KaTeX_AMS': ['Regular'],
      'KaTeX_Size1': ['Regular'],
      'KaTeX_Size2': ['Regular'],
      'KaTeX_Size3': ['Regular'],
      'KaTeX_Size4': ['Regular'],
      'KaTeX_SansSerif': ['Regular', 'Italic', 'Bold'],
      'KaTeX_Typewriter': ['Regular'],
    };
    for (final e in katex.entries) {
      final loader = FontLoader('packages/flutter_math_fork/${e.key}');
      for (final style in e.value) {
        loader.addFont(rootBundle.load('packages/flutter_math_fork/lib/katex_fonts/fonts/${e.key}-$style.ttf'));
      }
      await loader.load();
    }
    // The first use of the API client makes its http client, so it is made with the stub.
    http.runWithClient(() => api.token = 'test', () => MockClient(_answer));
  });

  setUp(routes.clear);

  shotTest('login, as a tutor', (t) async {
    api.token = null;
    session.user = null;
    session.tuitionName = 'Core Academy';
    await _both(t, 'login-student', () => const LoginScreen());
    await _both(t, 'login-tutor', () => const LoginScreen(), then: (t) async {
      await t.tap(find.text('Tutor'));
      await _settle(t);
    });
  });

  shotTest('the opening', (t) async {
    session.splashDone = false;
    session.restored = false;
    setResolvedDark(false);
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = _ratio;
    addTearDown(t.view.reset);
    await t.pumpWidget(RepaintBoundary(
      key: _boundary,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.light), home: const StartScreen()),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    await _shot(t, 'opening-1');
    await t.pump(const Duration(milliseconds: 450));
    await _shot(t, 'opening-2');
    await t.pump(const Duration(milliseconds: 1100));
    await _shot(t, 'opening-3');
    await t.pumpWidget(const SizedBox.shrink());
    session.restored = true;
  });

  shotTest('sign up', (t) async {
    await _both(t, 'signup', () => const TutorSignUpScreen());
  });

  shotTest('set up the tuition', (t) async {
    _sessionAs(role: 'teacher');
    routes['/auth/standard-subjects'] = (_) => {
          'subjects': [for (final (i, n) in ['Maths', 'Science', 'Physics', 'Chemistry', 'Biology', 'English', 'Hindi', 'Tamil', 'Social Science', 'Computer Science'].indexed) {'id': 'std-$i', 'name': n}],
        };
    await _both(t, 'setup-empty', () => const SetupScreen());
    // Add 10th Maths and 9th Science, then name the tuition.
    for (final dark in [false, true]) {
      await _show(t, const SetupScreen(), dark: dark);
      await t.tap(find.text('Add a class and subject'));
      await _settle(t);
      await _shot(t, 'setup-dialog-${dark ? 'dark' : 'light'}');
      for (final (cls, subject) in [(10, 'Maths'), (9, 'Science')]) {
        if (cls == 9) {
          await t.tap(find.text('Add a class and subject'));
          await _settle(t);
        }
        await t.tap(find.text('Choose a class'));
        await _settle(t);
        await t.tap(find.text('Class $cls').last);
        await _settle(t);
        await t.tap(find.text('Choose a subject'));
        await _settle(t);
        await t.tap(find.text(subject).last);
        await _settle(t);
        await t.tap(find.text('Add group'));
        await _settle(t);
      }
      await t.enterText(find.byType(TextField).first, 'Priya Maths Classes');
      await _settle(t);
      await _shot(t, 'setup-filled-${dark ? 'dark' : 'light'}');
      await t.pumpWidget(const SizedBox.shrink());
    }
  });

  shotTest('the join code', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    routes['/teacher/tuition'] = (_) => {'tuition': _tuition()};
    await _both(t, 'code-first', () => const ShareCodeScreen(first: true));
  });

  shotTest('join requests', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    routes['/teacher/join-requests'] = (_) => {
          'requests': [
            {'id': 's-1', 'display_name': 'Harini Venkatesh', 'username': 'harini.v', 'class_level': 9, 'asked_at': _iso(const Duration(minutes: -42))},
            {'id': 's-2', 'display_name': 'Arjun Krishnan', 'username': 'arjun.k', 'class_level': 10, 'asked_at': _iso(const Duration(hours: -5))},
          ],
        };
    routes['/teacher/subjects'] = (_) => {
          'subjects': [
            for (final (i, n) in ['Maths', 'Science', 'Physics'].indexed) {'id': 'sub-$i', 'name': n, 'sort_order': i, 'is_default': i == 0, 'standard': true, 'students': 8}
          ],
        };
    await _both(t, 'requests', () => const JoinRequestsScreen());
    for (final dark in [false, true]) {
      await _show(t, const JoinRequestsScreen(), dark: dark);
      await t.tap(find.text('Harini Venkatesh'));
      await _settle(t);
      await t.tap(find.text('Maths').last);
      await _settle(t);
      await _shot(t, 'requests-dialog-${dark ? 'dark' : 'light'}');
      await t.pumpWidget(const SizedBox.shrink());
    }
  });

  shotTest('tutor home', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    Map<String, Object?> group(int cls, String subject, int students, {List<Object?> live = const [], List<Object?> posted = const []}) =>
        {'class_level': cls, 'subject_id': 'sub-$subject', 'subject': subject, 'students': students, 'live': live, 'posted': posted};
    routes['/teacher/home'] = (_) => {
          'server_now': _iso(Duration.zero),
          'tuition': {'id': 't-1', 'name': 'Priya Maths Classes', 'join_code': 'KR74MQ'},
          'pending_requests': 2,
          'groups': [
            group(10, 'Maths', 12, live: [
              {'id': 'x1', 'title': 'Quadratic equations', 'closes_at': _iso(const Duration(hours: 3)), 'opens_at': null, 'time_limit_min': 30, 'submitted': 7, 'assigned': 12, 'writing': 2}
            ]),
            group(9, 'Science', 9, posted: [
              {'id': 'x2', 'title': 'Life processes', 'opens_at': _iso(const Duration(days: 1)), 'closes_at': _iso(const Duration(days: 1, hours: 2)), 'assigned': 9, 'submitted': 0, 'writing': 0}
            ]),
            group(10, 'Physics', 6),
          ],
          'totals': {'live': 1, 'writing': 2},
        };
    // Home is a tab inside the tutor shell, which supplies the Scaffold.
    await _both(t, 'home-requests', () => const Scaffold(body: TutorHome()));
    // A tuition that is just starting: no students yet, so Home shows how to invite them.
    routes['/teacher/home'] = (_) => {
          'server_now': _iso(Duration.zero),
          'tuition': {'id': 't-1', 'name': 'Priya Maths Classes', 'join_code': 'KR74MQ'},
          'pending_requests': 0,
          'groups': [group(10, 'Maths', 0), group(9, 'Science', 0)],
          'totals': {'live': 0, 'writing': 0},
        };
    await _both(t, 'home-new', () => const Scaffold(body: TutorHome()));
  });

  shotTest('settings', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    routes['/teacher/settings'] = (_) => {
          'tuition_name': 'Priya Maths Classes', 'tuition': {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner'},
          'me': {'id': 'u-1', 'display_name': 'Priya'}, 'sample': {'users': 0, 'questions': 0, 'tests': 0, 'papers': 0}, 'ai': {'calls_today': 0, 'failed_today': 0},
        };
    routes['/teacher/tuition'] = (_) => {'tuition': _tuition()};
    routes['/teacher/tutors'] = (_) => {
          'me': 'u-1',
          'tutors': [
            {'id': 'u-1', 'display_name': 'Priya', 'username': 'priya', 'active': true, 'owner': true},
            {'id': 'u-2', 'display_name': 'Ravi Kumar', 'username': 'ravi.k', 'active': true, 'owner': false},
          ],
        };
    routes['/teacher/subjects'] = (_) => {
          'subjects': [
            {'id': 'sub-0', 'name': 'Maths', 'sort_order': 0, 'is_default': false, 'standard': true, 'students': 12},
            {'id': 'sub-1', 'name': 'Science', 'sort_order': 1, 'is_default': false, 'standard': true, 'students': 9},
          ],
        };
    await _both(t, 'settings', () => const SettingsScreen(), height: 5600);
  });

  shotTest('student join', (t) async {
    // Waiting to be let into the first tuition.
    _sessionAs(role: 'student', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'pending', 'class_level': 9}]);
    await _both(t, 'join-waiting', () => const JoinScreen());
    // In one tuition already, asking to join a second.
    _sessionAs(role: 'student', tuitions: [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9},
      {'id': 't-2', 'name': 'Ravi Science Tuition', 'role': 'student', 'status': 'pending', 'class_level': 9},
    ]);
    await _both(t, 'join-second', () => const JoinScreen());
  });

  shotTest('student home with two tuitions', (t) async {
    _sessionAs(role: 'student', tuitions: [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9},
      {'id': 't-2', 'name': 'Ravi Science Tuition', 'role': 'student', 'status': 'active', 'class_level': 9},
    ]);
    routes['/student/home'] = (_) => {
          'server_now': _iso(Duration.zero),
          'tuition': {'id': 't-1', 'name': 'Priya Maths Classes'},
          'tests': [
            {
              'id': 'a', 'title': 'Linear equations', 'class_level': 9, 'time_limit_min': 20, 'opens_at': null, 'closes_at': _iso(const Duration(hours: 5)),
              'question_count': 12, 'max_marks': 12, 'state': 'open', 'retake': false, 'results_open': false, 'attempt': null,
            },
            {
              'id': 'b', 'title': 'Number systems', 'class_level': 9, 'time_limit_min': 15, 'opens_at': null, 'closes_at': _iso(const Duration(days: -1)),
              'question_count': 10, 'max_marks': 10, 'state': 'done', 'retake': false, 'results_open': true,
              'attempt': {'id': 'att', 'attempt_no': 1, 'submitted_at': _iso(const Duration(days: -1, hours: -2)), 'deadline_at': null, 'score': 8, 'max_score': 10},
            },
          ],
        };
    await _both(t, 'student-home', () => const StudentHome());
    await _both(t, 'student-start', () => const StudentHome(), then: (t) async {
      await t.tap(find.text('Start test').first);
      await _settle(t);
    });
    for (final dark in [false, true]) {
      await _show(t, const StudentHome(), dark: dark);
      await t.tap(find.byWidgetPredicate((w) => w is Text && (w.textSpan?.toPlainText() ?? w.data ?? '').contains('PRIYA MATHS CLASSES')).first);
      await _settle(t);
      await _shot(t, 'student-switch-${dark ? 'dark' : 'light'}');
      await t.pumpWidget(const SizedBox.shrink());
    }
  });

  // ---- the screens as they are today, for comparing with the redesign comps (design/comps/s2-*.html)
  shotTest('student: taking a test', (t) async {
    _sessionAs(role: 'student', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9}]);
    routes['POST /student/tests/a/start'] = (_) => {
          'attempt': {'id': 'att-1', 'server_now': _iso(Duration.zero), 'title': 'Linear equations', 'deadline_at': _iso(const Duration(minutes: 14, seconds: 42))},
          'questions': [
            for (var i = 1; i <= 12; i++)
              {
                'id': 'q$i', 'n': i, 'image_url': null, 'flagged': false,
                'chosen': i < 7 ? 1 : null,
                'text': i == 7 ? r'If $x = 2,\ y = -1$ is a solution of $3x + ky = 4$, what is the value of $k$?' : 'Question $i',
                'options': i == 7 ? [r'$-2$', r'$2$', r'$\tfrac{1}{2}$', r'$10$'] : ['1', '2', '3', '4'],
              },
          ],
        };
    await _both(t, 'test-taking', () => const TestScreen(testId: 'a'));
  });

  shotTest('student: a result', (t) async {
    _sessionAs(role: 'student', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9}]);
    final marks = [true, true, true, false, true, true, true, true, false, true];
    final names = [
      r'What is $\sqrt{16}$ equal to?', 'Which of these is an irrational number?', r'$0.\overline{3}$ is equal to', r'Which of these is a rational number?', 'Every integer is a',
      r'The decimal form of $\frac{7}{16}$ is', r'Between $1$ and $2$ there are', r'$\sqrt{2} \times \sqrt{8}$ equals', r'Which is the smallest?', 'The number 0 is',
    ];
    routes['/student/attempts/att-9/result'] = (_) => {
          'waiting': false,
          'attempt': {
            'id': 'att-9', 'title': 'Number systems', 'score': 8, 'max_score': 10, 'correct': 8, 'wrong': 2, 'skipped': 0, 'time_taken_sec': 372,
            'submitted_at': _iso(const Duration(days: -1, hours: -2)), 'auto_submitted': false,
          },
          'review': [
            for (var i = 0; i < 10; i++)
              {
                'n': i + 1, 'text': names[i], 'options': ['1', '2', '3', '4'], 'correct': 2, 'chosen': marks[i] ? 2 : 0, 'is_correct': marks[i], 'solution': null, 'image_url': null,
              },
          ],
        };
    await _both(t, 'result', () => const ResultScreen(attemptId: 'att-9'), height: 3000);
  });

  shotTest('tutor: a student', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    routes['/teacher/students/s-1'] = (_) => {
          'student': {
            'id': 's-1', 'display_name': 'Harini Venkatesh', 'username': 'harini.v', 'class_level': 9, 'active': true,
            'last_seen_at': _iso(const Duration(hours: -2)),
            'subjects': [{'id': 'm', 'name': 'Maths'}, {'id': 's', 'name': 'Science'}],
          },
          'attempts': [
            for (final (i, (title, score)) in [('Number systems', 8), ('Polynomials', 6), ('Linear equations', 9), ('Quadratic equations', 7), ('Triangles', 5)].indexed)
              {
                'id': 'at-$i', 'title': title, 'attempt_no': 1, 'score': score, 'max_score': 10,
                'started_at': _iso(Duration(days: -i - 1, hours: -3)), 'submitted_at': _iso(Duration(days: -i - 1, hours: -3, minutes: 12 + i)),
              },
          ],
          'chapters': [
            for (final (n, c, tt) in [('Polynomials', 9, 20), ('Linear equations', 12, 20), ('Number systems', 18, 25), ('Triangles', 7, 10), ('Quadratic equations', 14, 15), ('Statistics', 8, 8), ('Probability', 6, 6), ('Coordinate geometry', 5, 6)])
              {'chapter': n, 'correct': c, 'total': tt},
          ],
          'missed': [{'id': 'x', 'title': 'Unit test 2', 'closes_at': _iso(const Duration(days: -6))}],
        };
    await _both(t, 'tutor-student', () => const StudentDetailScreen(id: 's-1'), height: 2600);
    await _both(t, 'tutor-student-menu', () => const StudentDetailScreen(id: 's-1'), height: 2400, then: (t) async {
      await t.tap(find.bySemanticsLabel('More'));
      await _settle(t);
    });
  });

  shotTest('tutor: checking a paper', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    var seq = 0;
    Map<String, Object?> d(String n, int page, String text, List<String> opts,
            {int? correct, String? source, double? conf, String? note, Map<String, int>? picks, int? writer, String? chapter, bool diagram = false}) =>
        {
          'id': 'd-${++seq}', 'paper_id': 'p-1', 'page_no': page, 'seq': seq, 'number_label': n, 'kind': 'mcq', 'status': 'draft', 'text': text, 'options': opts,
          'correct_option': correct, 'answer_source': source, 'ai_confidence': conf, 'ai_note': note, 'ai_picks': picks, 'ai_votes': null,
          'proposed_option': writer, 'answer_checked': true, 'needs_diagram': diagram, 'image_key': null, 'image_url': null, 'chapter': chapter, 'chapter_id': null,
          'ai_chapter_guess': chapter,
        };
    final abcd = ['3', '-3', '5 over 3', '9'];
    routes['/teacher/papers/p-1'] = (_) => {
          'paper': {
            'id': 'p-1', 'class_level': 10, 'exam_name': 'Practice Paper 2', 'category': null, 'subject': 'Maths', 'subject_id': 'sub-0', 'chapter': null,
            'chapter_id': null, 'ai_details': {'ok': true}, 'page_count': 4, 'missing': <String>[],
          },
          'pages': [for (var i = 1; i <= 4; i++) {'page_no': i, 'ai_status': 'done', 'uploaded': true, 'image_url': null}],
          'drafts': [
            d('7', 2, 'The sum of the roots of the equation 3x squared minus 9x plus 5 equals 0 is', abcd,
                note: 'disagree', picks: {'solver': 0, 'checker': 2}, chapter: 'Quadratic Equations'),
            d('11', 3, 'In the figure, DE is parallel to BC. Find the length of EC.', ['2 cm', '3 cm', '4 cm', '6.75 cm'], diagram: true, chapter: 'Triangles'),
            d('14', 3, 'If tan theta equals 3 over 4, then sin theta is', ['3 over 5', '4 over 5', '5 over 3', '3 over 4'],
                note: 'unclear', chapter: 'Trigonometry'),
            d('9', 2, 'Which of these is a quadratic equation?', ['x + 1 = 0', 'x squared + 2x + 1 = 0', 'x cubed = 8', '2x = 5'],
                correct: 1, source: 'ai', conf: 0.97, chapter: 'Quadratic Equations'),
            d('1', 1, 'The decimal expansion of 17 over 8 terminates after how many places?', ['1', '2', '3', '4'], correct: 2, source: 'key', chapter: 'Real Numbers'),
            d('2', 1, 'If one zero of x squared plus kx minus 6 is 2, then k is', ['1', '-1', '2', '-2'], correct: 1, source: 'ai', conf: 0.99, chapter: 'Polynomials'),
          ],
          'chapters': <Object?>[], 'questions': <Object?>[], 'tests': <Object?>[],
        };
    await _both(t, 'paper-check', () => const PaperReviewScreen(id: 'p-1'), height: 4000);
  });

  shotTest('tutor: adding a paper', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    await _both(t, 'upload-add', () => const UploadPaperScreen(classLevel: 10, subjectId: 'sub-0', subjectName: 'Maths'));
  });

  shotTest('tutor: a paper being read', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    final gate = Completer<void>();
    holds['POST /teacher/papers/p-2/pages/2/read'] = gate.future;
    holds['POST /teacher/papers/p-2/pages/3/read'] = gate.future;
    holds['POST /teacher/papers/p-2/pages/4/read'] = gate.future;
    Map<String, Object?> d(int n, int page, String text, {int? correct}) => {
          'id': 'r-$n', 'paper_id': 'p-2', 'page_no': page, 'seq': n, 'number_label': '$n', 'kind': 'mcq', 'status': 'draft', 'text': text,
          'options': ['1', '2', '3', '4'], 'correct_option': correct, 'answer_source': correct == null ? null : 'ai', 'ai_confidence': correct == null ? null : 0.98,
          'ai_note': null, 'ai_picks': null, 'ai_votes': null, 'proposed_option': null, 'answer_checked': correct != null, 'needs_diagram': false, 'image_key': null,
          'image_url': null, 'chapter': null, 'chapter_id': null, 'ai_chapter_guess': null,
        };
    routes['/teacher/papers/p-2'] = (_) => {
          'paper': {
            'id': 'p-2', 'class_level': 10, 'exam_name': 'Paper 10 Oct', 'category': null, 'subject': 'Maths', 'subject_id': 'sub-0', 'chapter': null,
            'chapter_id': null, 'ai_details': {'ok': true}, 'page_count': 4, 'missing': <String>[],
          },
          'pages': [
            for (var i = 1; i <= 4; i++) {'page_no': i, 'ai_status': i == 1 ? 'done' : (i == 2 ? 'reading' : 'pending'), 'uploaded': true, 'image_url': null},
          ],
          'drafts': [
            d(1, 1, 'The decimal expansion of 17 over 8 terminates after how many places?', correct: 2),
            d(2, 1, 'If one zero of x squared plus kx minus 6 is 2, then k is', correct: 1),
            d(3, 1, 'The common difference of the AP is', correct: 0),
            d(4, 1, 'The sum of the roots is'),
            d(5, 1, 'The distance between the points is', correct: 2),
            d(6, 1, 'Which of these is a quadratic equation?'),
          ],
          'chapters': <Object?>[], 'questions': <Object?>[], 'tests': <Object?>[],
        };
    routes['POST /teacher/papers/p-2/answers'] = (_) => {'from_key': 0, 'by_ai': 0, 'tried': 0, 'left': 0, 'second': 0};
    await _both(t, 'paper-reading', () => const PaperReviewScreen(id: 'p-2', autoRead: true), height: 2400);
    gate.complete();
    holds.clear();
  });

  shotTest('student profile', (t) async {
    _sessionAs(role: 'student', tuitions: [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9},
      {'id': 't-2', 'name': 'Ravi Science Tuition', 'role': 'student', 'status': 'active', 'class_level': 9},
      {'id': 't-3', 'name': 'Meena Hindi Classes', 'role': 'student', 'status': 'pending', 'class_level': 9},
    ]);
    await _both(t, 'student-profile', () => const ProfileScreen(), height: 3000);
  });
}
