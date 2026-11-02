// Draws the multi-tuition screens to PNG files on this PC (no phone, no emulator): the real widgets and
// fonts, answers from a stub server. Without SHOTS=1 it only checks that each screen builds.
//   SHOTS=1 flutter test test/shots/screens_test.dart
// Pictures go to ../tools/out/shots (git-ignored).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/format.dart' show time;
import 'package:core_academy/core/library.dart' show LibFile, LibraryEnv, UploadJob, UploadState;
import 'package:core_academy/core/session.dart';
import 'package:core_academy/core/updater.dart';
import 'package:core_academy/features/auth/login_screen.dart';
import 'package:core_academy/features/auth/start_screen.dart';
import 'package:core_academy/features/auth/signup_screen.dart';
import 'package:core_academy/features/auth/update_required_screen.dart';
import 'package:core_academy/features/library/file_viewer.dart' show FileViewerArgs, FileViewerScreen, pdfPages;
import 'package:core_academy/features/student/course_screen.dart';
import 'package:core_academy/features/student/home_screen.dart';
import 'package:core_academy/features/student/join_screen.dart';
import 'package:core_academy/features/student/library_screens.dart' show LibraryClassScreen;
import 'package:core_academy/features/student/profile_screen.dart';
import 'package:core_academy/features/student/result_screen.dart';
import 'package:core_academy/features/student/test_screen.dart';
import 'package:core_academy/features/teacher/classes_screen.dart';
import 'package:core_academy/features/teacher/course_screens.dart';
import 'package:core_academy/features/teacher/group_screens.dart' show GroupScreen;
import 'package:core_academy/features/teacher/home_screen.dart';
import 'package:core_academy/features/teacher/join_requests_screen.dart';
import 'package:core_academy/features/teacher/make_test.dart' show TestTarget;
import 'package:core_academy/features/teacher/make_tests_screen.dart';
import 'package:core_academy/features/teacher/page_pictures.dart' show FigureCutScreen, cutOut;
import 'package:core_academy/features/teacher/papers_screens.dart';
import 'package:core_academy/features/teacher/settings_screen.dart';
import 'package:core_academy/features/teacher/teacher_routes.dart';
import 'package:core_academy/features/teacher/setup_screen.dart';
import 'package:core_academy/features/teacher/students_screens.dart';
import 'package:core_academy/features/teacher/share_code_screen.dart';
import 'package:core_academy/features/teacher/tests_screens.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/kit.dart' show Pressable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/library_fakes.dart' as lib;
import '../support/make_fakes.dart';
import '../support/page_images.dart' show FakePages, cacheNetworkImage, forgetNetworkImages, settle;
import '../support/printed_pages.dart';

final _shots = Platform.environment['SHOTS'] == '1';

/// LANDSCAPE=1 draws every screen on its side (a phone turned round), to find what no longer fits.
final _landscape = Platform.environment['LANDSCAPE'] == '1';

/// TEXTSCALE=2.0 draws every screen with the phone's text size at double, and WIDTH_DP=320 on a narrow phone: the two ways a
/// screen that fits at the usual size stops fitting. Without them the screens draw at 1.0 on a 411 dp wide phone.
final _textScale = double.tryParse(Platform.environment['TEXTSCALE'] ?? '') ?? 1.0;
final _widthDp = double.tryParse(Platform.environment['WIDTH_DP'] ?? '') ?? 1080 / 2.625;

/// KEYBOARD=318 draws every screen on a phone 800 dp tall with a keyboard of that many dp up, as Android gives it to the window,
/// to find what the keyboard covers or squeezes: a screen that does not scroll then overflows and fails its test.
final _keyboard = double.tryParse(Platform.environment['KEYBOARD'] ?? '') ?? 0;
Widget _scaled(BuildContext context, Widget? child) =>
    MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(_textScale)), child: child!);
final _boundary = GlobalKey();
const _ratio = 2.625;

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();

/// What the stub server answers, by path. Replaced by each test.
final routes = <String, Object? Function(http.Request)>{};

/// A route that answers only when its future completes, so a screen can be drawn while it waits.
final holds = <String, Future<void>>{};

/// While a scene of making several tests at once is drawn, a stand-in for the whole paper side of the server answers instead.
PaperServer? makeServer;

/// While a scene of the Library is drawn, a stand-in for the Library side of the server answers instead.
lib.LibraryServer? libraryServer;

Future<http.Response> _answer(http.Request r) async {
  final fake = makeServer;
  if (fake != null) return fake.handle(r);
  final shelf = libraryServer;
  if (shelf != null) return shelf.handle(r);
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

/// The app's theme, with the maths package's faces to fall back on for the symbols Geist does not have (the box a reader leaves where a
/// page could not be read, theta): the phone's own fonts fill those in, and a test has none.
ThemeData _theme(bool dark) {
  final base = buildTheme(dark ? Brightness.dark : Brightness.light);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamilyFallback: const ['packages/flutter_math_fork/KaTeX_AMS', 'packages/flutter_math_fork/KaTeX_Main', 'packages/flutter_math_fork/KaTeX_Math']),
  );
}

Future<void> _show(WidgetTester t, Widget screen, {bool dark = false, double height = 2400}) async {
  setResolvedDark(dark);
  t.view.physicalSize = _landscape ? const Size(2400, 1080) : Size(_widthDp * _ratio, _keyboard > 0 ? 800 * _ratio : height);
  t.view.devicePixelRatio = _ratio;
  if (_keyboard > 0) {
    t.view.viewPadding = const FakeViewPadding(top: 24 * _ratio, bottom: 16 * _ratio);
    t.view.padding = const FakeViewPadding(top: 24 * _ratio, bottom: 16 * _ratio);
    t.view.viewInsets = const FakeViewPadding(bottom: 0);
  }
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(
    key: _boundary,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: _theme(dark), builder: _scaled, home: screen),
  ));
  await _settle(t);
  if (_keyboard > 0) {
    t.view.padding = const FakeViewPadding(top: 24 * _ratio);
    t.view.viewInsets = FakeViewPadding(bottom: _keyboard * _ratio);
    await _settle(t);
  }
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
        // The card scrolls when the text is large and the phone narrow, so each button is scrolled to before it is tapped.
        for (final f in [find.text('Choose a class'), find.text('Class $cls').last, find.text('Choose a subject'), find.text(subject).last, find.text('Add group')]) {
          await t.ensureVisible(f);
          await t.pump();
          await t.tap(f);
          await _settle(t);
        }
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
              'question_count': 12, 'max_marks': 12, 'state': 'open', 'retake': false, 'results_open': true, 'attempt': null,
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

  shotTest('tutor: a paper AI wrote, replacing the questions it could not answer', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    Map<String, Object?> d(int n, String text, List<String> opts, {int? correct, String status = 'draft', String? note}) => {
          'id': 'w-$n-$status', 'paper_id': 'p-3', 'page_no': 1, 'seq': n, 'number_label': '$n', 'kind': 'mcq', 'status': status, 'text': text, 'options': opts,
          'correct_option': correct, 'answer_source': correct == null ? null : 'ai', 'ai_confidence': correct == null ? null : 0.98, 'ai_note': note, 'ai_picks': null,
          'ai_votes': null, 'proposed_option': null, 'answer_checked': true, 'needs_diagram': false, 'image_key': null, 'image_url': null, 'chapter': null,
          'chapter_id': null, 'ai_chapter_guess': null, 'edited': false,
        };
    Map<String, Object?> paper(bool replaceable) => {
          'id': 'p-3', 'class_level': 9, 'exam_name': 'Algebra, Monday', 'category': 'Made with AI', 'subject': 'Maths', 'subject_id': 'sub-0', 'chapter': null,
          'chapter_id': null, 'course_id': null, 'ai_details': {'ok': true}, 'page_count': 0, 'missing': <String>[], 'replaceable': replaceable,
        };
    final settled = [
      d(1, 'Which of these is a linear equation in one variable?', ['x + 2 = 5', 'x squared = 4', 'xy = 6', 'x + y = 3'], correct: 0),
      d(2, 'The value of x in 3x + 5 = 20 is', ['3', '5', '15', '25'], correct: 1),
      d(3, 'If 2x - 7 = 11, then x equals', ['2', '4', '9', '18'], correct: 2),
      d(4, 'The degree of the polynomial 5x cubed + 2x is', ['1', '2', '3', '5'], correct: 2),
    ];
    const cant = ['A number added to its double gives 36. The number is', 'The sum of two consecutive even numbers is 50. The smaller one is'];
    // One stub for the whole run, the way the server behaves: the paper has two questions the checks could not settle until the
    // writer is asked to replace them, and after that it has two new ones with their answers.
    var replaced = false;
    final before = <String, Object?>{
      'paper': paper(true),
      'pages': <Object?>[],
      'drafts': [...settled, d(5, cant[0], ['9', '12', '18', '24']), d(6, cant[1], ['22', '24', '26', '28'])],
      'chapters': <Object?>[], 'questions': <Object?>[], 'tests': <Object?>[],
    };
    final after = <String, Object?>{
      'paper': paper(false),
      'pages': <Object?>[],
      'drafts': [
        ...settled,
        d(5, cant[0], ['9', '12', '18', '24'], status: 'discarded', note: 'replaced'),
        d(6, cant[1], ['22', '24', '26', '28'], status: 'discarded', note: 'replaced'),
        d(5, 'The sum of three consecutive numbers is 72. The middle number is', ['23', '24', '25', '26'], correct: 1),
        d(6, 'Twice a number decreased by 5 is 27. The number is', ['11', '16', '17', '22'], correct: 1),
      ],
      'chapters': <Object?>[], 'questions': <Object?>[], 'tests': <Object?>[],
    };
    routes['/teacher/papers/p-3'] = (_) => replaced ? after : before;
    routes['POST /teacher/papers/p-3/answers'] = (_) => {'from_key': 0, 'by_ai': 0, 'tried': 0, 'left': 0, 'second': 0};
    routes['POST /teacher/papers/p-3/second-opinion'] = (_) => {'by_ai': 0, 'tried': 0, 'asked': 0, 'left': 0};
    routes['POST /teacher/papers/p-3/replace'] = (_) {
      replaced = true;
      return {'replaced': 2, 'left': 0};
    };
    Widget fresh() {
      replaced = false;
      return const PaperReviewScreen(id: 'p-3');
    }

    // While the writer is at work (its call is held): two questions the checks could not settle, a notice, and the review there to be used.
    final gate = Completer<void>();
    holds['POST /teacher/papers/p-3/replace'] = gate.future;
    await _both(t, 'paper-replacing', fresh, height: 3000);
    gate.complete();
    await t.pump(const Duration(milliseconds: 100)); // the calls the closed screens left waiting run out
    holds.clear();
    // The whole run: the writer replaces the two, the new ones are checked, and the list ends on Ready with a line saying what happened.
    await _both(t, 'paper-replaced-ready', fresh, height: 3000);
    await _both(t, 'paper-replaced-skipped', fresh, height: 2400, then: (t) async {
      await t.tap(find.text('Skipped'));
      await _settle(t);
    });
  });

  shotTest('tutor: a paper AI could not check', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    Map<String, Object?> d(int n, String text, List<String> opts, {int? correct, String? note}) => {
          'id': 'u-$n', 'paper_id': 'p-4', 'page_no': 1, 'seq': n, 'number_label': '$n', 'kind': 'mcq', 'status': 'draft', 'text': text, 'options': opts,
          'correct_option': correct, 'answer_source': correct == null ? null : 'ai', 'ai_confidence': correct == null ? null : 0.98, 'ai_note': note, 'ai_picks': null,
          'ai_votes': null, 'proposed_option': null, 'answer_checked': true, 'needs_diagram': false, 'image_key': null, 'image_url': null, 'chapter': null,
          'chapter_id': null, 'ai_chapter_guess': null, 'edited': false,
        };
    // The models were down: two questions could not be checked. They are not replaced, and the paper asks again by itself.
    routes['/teacher/papers/p-4'] = (_) => {
          'paper': {
            'id': 'p-4', 'class_level': 9, 'exam_name': 'Mensuration, Tuesday', 'category': 'Made with AI', 'subject': 'Maths', 'subject_id': 'sub-0', 'chapter': null,
            'chapter_id': null, 'course_id': null, 'ai_details': {'ok': true}, 'page_count': 0, 'missing': <String>[], 'replaceable': true,
          },
          'pages': <Object?>[],
          'drafts': [
            d(1, 'The area of a rectangle 8 cm long and 5 cm wide is', ['13 cm squared', '26 cm squared', '40 cm squared', '80 cm squared'], correct: 2),
            d(2, 'The volume of a cube of side 3 cm is', ['9 cm cubed', '18 cm cubed', '27 cm cubed', '54 cm cubed'], correct: 2),
            d(3, 'The total surface area of a cube of side 5 cm is', ['100 cm squared', '125 cm squared', '150 cm squared', '250 cm squared'], note: 'unchecked'),
            d(4, 'The curved surface area of a cylinder of radius 7 cm and height 10 cm is (take pi as 22/7)', ['220 cm squared', '440 cm squared', '880 cm squared', '1540 cm squared'], note: 'unchecked'),
          ],
          'chapters': <Object?>[], 'questions': <Object?>[], 'tests': <Object?>[],
        };
    routes['POST /teacher/papers/p-4/answers'] = (_) => {'from_key': 0, 'by_ai': 0, 'tried': 0, 'left': 0, 'second': 0};
    routes['POST /teacher/papers/p-4/second-opinion'] = (_) => {'by_ai': 0, 'tried': 0, 'asked': 0, 'left': 0};
    await _both(t, 'paper-not-checked', () => const PaperReviewScreen(id: 'p-4'), height: 2600);
  });

  // ---- the question builder (design/comps/q1-*.html): a misprinted question beside its picture from the paper, a figure cut out of its
  // page, a question joined from two pages (and two that could not be), the editor that opens with the picture on top, and the page
  // with the box to drag. The pages are made up for the pictures (test/support/printed_pages.dart).
  shotTest('tutor: question builder', (t) async {
    addTearDown(forgetNetworkImages);
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    final p1 = PrintedPage(header: '10th Standard  ·  Physics  ·  Unit Test 2  ·  page 1')
      ..question('q1', '1', 'Which of these is a vector quantity?', options: ['(a) mass', '(b) speed', '(c) force', '(d) time'])
      ..question('q2', '2', 'In the circuit shown, the equivalent resistance between the points A and B is', options: ['(a) 2 Ω', '(b) 4 Ω', '(c) 11 Ω', '(d) 1 Ω'], figure: drawCircuit)
      ..space(0.27)
      ..question('q4a', '4', 'A student finds the focal length of a convex lens by focusing a distant object on a screen. The sharp image is 15 cm from the lens. The power of the lens is nearly',
          options: ['(a) 6.67 D', '(b) 0.15 D']);
    final p2 = PrintedPage(header: '10th Standard  ·  Physics  ·  Unit Test 2  ·  page 2')
      ..continuation('q4b', ['(c) 1.5 D', '(d) 15 D'])
      ..question('q5', '5', 'The speed of light in vacuum is nearly', options: ['(a) 300 000 km/s', '(b) 3 000 km/s', '(c) 30 000 km/s', '(d) 300 km/s'])
      ..question('q7', '7', 'The sum of the first n terms of an AP is 3n² + 5n. Its 10th term is', options: ['(a) 62', '(b) 65', '(c) 59', '(d) 68']);
    final pages = (await t.runAsync(() async => {1: await p1.png(), 2: await p2.png()}))!;
    final fake = FakePages(pages);
    await t.runAsync(fake.warm);
    // The circuit as the app cuts it out of page 1, found at the address its card asks for.
    final cut = (await t.runAsync(() async => cutOut((await fake.pictures.image(1))!, p1.boxes['q2.figure']!, margin: 0.01)))!;
    await cacheNetworkImage(t, 'https://figs.test/figs/q2.png', cut);
    for (final n in pages.keys) {
      await cacheNetworkImage(t, fake.url(n), pages[n]!); // the strip of pages under the title
    }
    if (_shots) {
      await t.runAsync(() async {
        File('../tools/out/shots/qb-page-1.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(pages[1]!);
        File('../tools/out/shots/qb-page-2.png').writeAsBytesSync(pages[2]!);
        File('../tools/out/shots/qb-figure-cut.png').writeAsBytesSync(cut);
      });
    }

    var seq = 0;
    Map<String, Object?> d(String n, int page, String text, List<String> opts,
            {int? correct, String? note, Map<String, int>? picks, List<Map<String, Object?>>? boxes, bool diagram = false, Map<String, Object?>? figure, String? imageKey,
            bool joined = false, Map<String, Object?>? joinedFrom, bool cutNext = false, bool cutPrev = false, String status = 'draft', String paper = 'p-q1'}) =>
        {
          'id': '$paper-${++seq}', 'paper_id': paper, 'page_no': page, 'seq': seq, 'number_label': n, 'kind': 'mcq', 'status': status, 'text': text, 'options': opts,
          'correct_option': correct, 'answer_source': correct == null ? null : 'ai', 'ai_confidence': correct == null ? null : 0.98, 'ai_note': note, 'ai_picks': picks,
          'ai_votes': null, 'proposed_option': null, 'answer_checked': true, 'needs_diagram': diagram, 'image_key': imageKey,
          'image_url': imageKey == null ? null : 'https://figs.test/$imageKey', 'chapter': null, 'chapter_id': null, 'ai_chapter_guess': null, 'edited': false,
          'question_boxes': boxes, 'figure_box': figure, 'cont_next': cutNext, 'cont_prev': cutPrev, 'joined': joined, 'joined_from': joinedFrom,
        };
    List<Map<String, Object?>> at(int page, String id) => [
          {'page': page, 'box': (page == 1 ? p1 : p2).boxes[id]},
        ];

    const lensText = 'A student finds the focal length of a convex lens by focusing a distant object on a screen. The sharp image is 15 cm from the lens. The power of the lens is nearly';
    final misprint = d('7', 2, 'The sum of the first ■ terms of an AP is 3■² + 5■. Its 10th term is', ['62', '65', '59', '68'], note: 'unclear', boxes: at(2, 'q7'));
    final fillers = [
      for (final (i, q) in [
        'Which of these is a vector quantity?',
        'The SI unit of force is',
        'A body at rest has a speed of',
        'Light travels fastest in',
        'The unit of electric current is',
        'The image in a plane mirror is',
        'The energy of a moving body is called',
        'Sound cannot travel through',
        'The bending of light is called',
        'The unit of resistance is',
        'The lens used in a magnifying glass is',
      ].indexed)
        d('${i + 8}', 2, q, ['Option A', 'Option B', 'Option C', 'Option D'], correct: i % 4),
    ];
    final drafts = [
      misprint,
      d('9', 2, 'The focal length of a plane mirror is', ['0', '10 cm', 'infinite', '1 m'], note: 'disagree', picks: {'solver': 2, 'checker': 0}),
      d('12', 2, 'A ray of light passes through the centre of a lens. It', ['bends up', 'bends down', 'goes straight', 'stops']),
      d('2', 1, 'In the circuit shown, the equivalent resistance between the points A and B is', ['2 Ω', '4 Ω', '11 Ω', '1 Ω'],
          correct: 1, diagram: true, imageKey: 'figs/q2.png', figure: {'page': 1, 'box': p1.boxes['q2.figure']}, boxes: at(1, 'q2')),
      d('4', 1, lensText, ['6.67 D', '0.15 D', '1.5 D', '15 D'],
          correct: 0,
          joined: true,
          boxes: [...at(1, 'q4a'), ...at(2, 'q4b')],
          joinedFrom: {
            'before': {'options': ['6.67 D', '0.15 D']},
            'part': {'page_no': 2},
          }),
      ...fillers,
      d('3', 1, 'The unit of work is', ['watt', 'joule', 'newton', 'pascal'], status: 'discarded'),
      d('6', 2, 'The unit of frequency is', ['metre', 'second', 'hertz', 'kelvin'], status: 'discarded'),
    ];
    Map<String, Object?> paper(String id) => {
          'id': id, 'class_level': 10, 'exam_name': 'Unit Test 2', 'category': null, 'subject': 'Physics', 'subject_id': 'sub-0', 'chapter': null, 'chapter_id': null,
          'ai_details': {'ok': true}, 'page_count': 2, 'missing': <String>[],
        };
    routes['/teacher/papers/p-q1'] = (_) => {'paper': paper('p-q1'), 'pages': fake.rows(), 'drafts': drafts, 'chapters': <Object?>[], 'questions': <Object?>[], 'tests': <Object?>[]};
    final cutOff = [
      d('4', 1, lensText, ['6.67 D', '0.15 D'], note: 'unclear', cutNext: true, boxes: at(1, 'q4a'), paper: 'p-q2'),
      d('', 2, '', ['1.5 D', '15 D'], note: 'unclear', cutPrev: true, boxes: at(2, 'q4b'), paper: 'p-q2'),
      d('5', 2, 'The speed of light in vacuum is nearly', ['300 000 km/s', '3 000 km/s', '30 000 km/s', '300 km/s'], correct: 0, paper: 'p-q2'),
    ];
    routes['/teacher/papers/p-q2'] = (_) => {'paper': paper('p-q2'), 'pages': fake.rows(), 'drafts': cutOff, 'chapters': <Object?>[], 'questions': <Object?>[], 'tests': <Object?>[]};
    for (final id in ['p-q1', 'p-q2']) {
      routes['POST /teacher/papers/$id/answers'] = (_) => {'from_key': 0, 'by_ai': 0, 'tried': 0, 'left': 0, 'second': 0};
      routes['POST /teacher/papers/$id/second-opinion'] = (_) => {'by_ai': 0, 'tried': 0, 'asked': 0, 'left': 0};
    }

    Future<void> pictures(WidgetTester t) => settle(t, rounds: 4);
    Future<void> readyRow(WidgetTester t, String text) async {
      await t.tap(find.text('Ready'));
      await settle(t, rounds: 3);
      await t.tap(find.textContaining(text, findRichText: true));
      await settle(t, rounds: 8);
    }

    await _both(t, 'qb-misprint', () => PaperReviewScreen(id: 'p-q1', pictures: fake.pictures), height: 3000, then: pictures);
    await _both(t, 'qb-figure', () => PaperReviewScreen(id: 'p-q1', pictures: fake.pictures), height: 3000, then: (t) => readyRow(t, 'In the circuit shown'));
    await _both(t, 'qb-joined', () => PaperReviewScreen(id: 'p-q1', pictures: fake.pictures), height: 3000, then: (t) => readyRow(t, 'A student finds the focal length'));
    await _both(t, 'qb-cutoff', () => PaperReviewScreen(id: 'p-q2', pictures: fake.pictures), height: 3600, then: pictures);
    await _both(t, 'qb-fix', () => DraftEditor(draft: misprint, pictures: fake.pictures), height: 2800, then: pictures);
    await _both(t, 'qb-cut', () => FigureCutScreen(pictures: fake.pictures, page: 1, start: p1.boxes['q2.figure']!), height: 2400, then: pictures);
  });

  shotTest('student profile', (t) async {
    _sessionAs(role: 'student', tuitions: [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9},
      {'id': 't-2', 'name': 'Ravi Science Tuition', 'role': 'student', 'status': 'active', 'class_level': 9},
      {'id': 't-3', 'name': 'Meena Hindi Classes', 'role': 'student', 'status': 'pending', 'class_level': 9},
    ]);
    await _both(t, 'student-profile', () => const ProfileScreen(), height: 3000);
  });

  // ---- courses (design/comps/c1-*.html)
  final tutorTuition = [
    {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'},
  ];
  const people = [
    'Aarav Kumar', 'Diya Nair', 'Ishaan Rao', 'Meera Pillai', 'Rohan Krishnan', 'Sana Sheikh', 'Tara Menon',
    'Vikram Iyer', 'Yash Gupta', 'Zoya Ali', 'Kabir Das', 'Leela Reddy', 'Nikhil Varma', 'Pooja Shetty',
  ];

  Map<String, Object?> courseTest(String id, String title, {String status = 'published', Duration? opens, Duration? closes, int assigned = 14, int submitted = 0, int writing = 0}) => {
        'id': id, 'title': title, 'status': status, 'opens_at': opens == null ? null : _iso(opens), 'closes_at': closes == null ? null : _iso(closes),
        'results_released_at': null, 'time_limit_min': 15, 'question_count': 10, 'assigned': assigned, 'submitted': submitted, 'writing': writing,
        'everyone_done': false,
      };

  final springEnglish = <String, Object?>{
    'id': 'c-1', 'name': 'Spoken English, Batch 1', 'created_at': _iso(const Duration(days: -9)), 'people': 14,
    'live': [
      {'id': 'y1', 'title': 'Unit 1 quiz', 'closes_at': _iso(const Duration(hours: 3)), 'opens_at': null, 'time_limit_min': 15, 'submitted': 6, 'assigned': 14, 'writing': 3},
    ],
    'posted': <Object?>[],
  };
  final olympiad = <String, Object?>{'id': 'c-2', 'name': 'Olympiad Prep', 'created_at': _iso(const Duration(days: -20)), 'people': 8, 'live': <Object?>[], 'posted': <Object?>[]};

  // ---- the tutor's Home, the Classes tab and the papers waiting (design/comps/w2-*.html)
  Map<String, Object?> group(int cls, String subject, int students, {List<Object?> live = const [], List<Object?> posted = const []}) =>
      {'class_level': cls, 'subject_id': 'sub-$subject', 'subject': subject, 'students': students, 'live': live, 'posted': posted};
  Map<String, Object?> openTest(String id, String title, {Duration? opens, Duration? closes, int assigned = 12, int submitted = 0, int writing = 0}) => {
        'id': id, 'title': title, 'opens_at': opens == null ? null : _iso(opens), 'closes_at': closes == null ? null : _iso(closes),
        'time_limit_min': 30, 'assigned': assigned, 'submitted': submitted, 'writing': writing,
      };
  Map<String, Object?> finishedTest(String id, String title, {int? cls, String? subject, String? course, required Duration closed, int assigned = 12, int submitted = 11}) => {
        'id': id, 'title': title, 'class_level': cls, 'subject_id': subject == null ? null : 'sub-$subject', 'subject': subject,
        'course_id': course == null ? null : 'c-1', 'course': course, 'closes_at': _iso(closed), 'everyone_done': false,
        'assigned': assigned, 'submitted': submitted, 'writing': 0,
      };
  Map<String, Object?> waitingPaper(String id, String name, {int? cls, String? subject, String? course, int pages = 2, int read = 2, int toCheck = 0, int saved = 0}) => {
        'id': id, 'exam_name': name, 'class_level': cls, 'subject_id': subject == null ? null : 'sub-$subject', 'subject': subject,
        'course_id': course == null ? null : 'c-1', 'course': course, 'page_count': pages, 'pages_read': read, 'to_check': toCheck, 'saved': saved,
        'has_test': false, 'created_at': _iso(const Duration(hours: -3)),
      };
  Map<String, Object?> home({
    int pending = 0,
    List<Object?>? groups,
    List<Object?>? courses,
    List<Object?> finished = const [],
    List<Object?> papers = const [],
  }) =>
      {
        'server_now': _iso(Duration.zero),
        'tuition': {'id': 't-1', 'name': 'Priya Maths Classes', 'join_code': 'KR74MQ'},
        'pending_requests': pending,
        'groups': groups ?? [],
        'totals': {'live': 0, 'writing': 0},
        'courses': courses ?? [],
        'finished': finished,
        'papers': papers,
      };
  Map<String, Object?> busyHome({bool open = true}) => home(
        pending: 1,
        groups: [
          group(10, 'Maths', 12, live: open ? [openTest('x1', 'Practice Paper 2', closes: const Duration(hours: 3), submitted: 7)] : const [], posted: [
            openTest('x3', 'Real Numbers test', opens: const Duration(days: 5), closes: const Duration(days: 5, hours: 13)),
          ]),
          group(9, 'Science', 9, posted: [openTest('x2', 'Linear equations', opens: const Duration(days: 3), closes: const Duration(days: 3, hours: 13), assigned: 9)]),
          group(11, 'Physics', 6),
        ],
        courses: [
          {
            ...springEnglish,
            'live': open ? springEnglish['live'] : <Object?>[],
            'posted': [openTest('y2', 'Unit 2 quiz', opens: const Duration(days: 1), closes: const Duration(days: 1, hours: 13), assigned: 14)],
          },
          olympiad,
        ],
        finished: [
          finishedTest('f1', 'Greetings', course: 'Spoken English, Batch 1', closed: const Duration(days: -3), assigned: 14, submitted: 12),
          finishedTest('f2', 'Number systems', cls: 9, subject: 'Science', closed: const Duration(days: -5), assigned: 9, submitted: 8),
        ],
        papers: [
          waitingPaper('p1', 'Quadratic equations', cls: 10, subject: 'Maths', toCheck: 4, saved: 12),
          waitingPaper('p2', 'Triangles, unit test', cls: 9, subject: 'Maths', pages: 3, read: 1),
        ],
      );

  shotTest('tutor home', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    routes['/teacher/home'] = (_) => busyHome();
    await _both(t, 'home-full', () => const Scaffold(body: TutorHome()), height: 2700);
    // Nothing open right now.
    routes['/teacher/home'] = (_) => busyHome(open: false);
    await _both(t, 'home-quiet', () => const Scaffold(body: TutorHome()), height: 3000);
    // One student waiting and one paper: a short "Needs you".
    routes['/teacher/home'] = (_) => home(
          pending: 2,
          groups: [group(10, 'Maths', 12), group(9, 'Science', 9)],
          papers: [waitingPaper('p1', 'Quadratic equations', cls: 10, subject: 'Maths', toCheck: 4)],
        );
    await _both(t, 'home-needs-you', () => const Scaffold(body: TutorHome()));
    // Classes exist but no test has been made yet.
    routes['/teacher/home'] = (_) => home(groups: [group(10, 'Maths', 12), group(9, 'Science', 9)]);
    await _both(t, 'home-no-tests', () => const Scaffold(body: TutorHome()));
    // A tuition that is just starting: no students yet, so Home shows how to invite them.
    routes['/teacher/home'] = (_) => home(groups: [group(10, 'Maths', 0), group(9, 'Science', 0)]);
    await _both(t, 'home-new', () => const Scaffold(body: TutorHome()));
    // The first day: no class at all.
    routes['/teacher/home'] = (_) => home();
    await _both(t, 'home-first-day', () => const Scaffold(body: TutorHome()));
    // ... and its one button asks which kind to add.
    await _both(t, 'home-add-choice', () => const Scaffold(body: TutorHome()), then: (t) async {
      final add = find.text('Add a group or course');
      await t.ensureVisible(add);
      await t.pump();
      await t.tap(add);
      await _settle(t);
    });
  });

  shotTest('tutor: groups and courses', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    routes['/teacher/home'] = (_) => home();
    await _both(t, 'gc-empty', () => const Scaffold(body: ClassesScreen()));
    routes['/teacher/home'] = (_) => busyHome();
    // A button is scrolled to before it is tapped: on a phone on its side, or with very large text, it may start below the edge.
    Future<void> tapIt(WidgetTester t, Finder f) async {
      await t.ensureVisible(f);
      await t.pump();
      await t.tap(f);
      await _settle(t);
    }

    // The groups show first; the switch changes the list to the courses.
    await _both(t, 'gc-groups', () => const Scaffold(body: ClassesScreen()));
    await _both(t, 'gc-courses', () => const Scaffold(body: ClassesScreen()), then: (t) async {
      await tapIt(t, find.text('Courses'));
    });
    await _both(t, 'gc-new-course', () => const Scaffold(body: ClassesScreen()), then: (t) async {
      await tapIt(t, find.text('Courses'));
      await tapIt(t, find.text('Add a course'));
    });
    // Groups but no course yet, and the Courses side of that.
    routes['/teacher/home'] = (_) => home(groups: [group(10, 'Maths', 12), group(9, 'Science', 9)]);
    await _both(t, 'gc-no-courses', () => const Scaffold(body: ClassesScreen()), then: (t) async {
      await tapIt(t, find.text('Courses'));
    });
  });

  shotTest('tutor: the two tabs', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    routes['/teacher/home'] = (_) => busyHome();
    // The real routes, so the floating tab bar is there: Home and Classes.
    await _both(t, 'tabs-home', () => Router.withConfig(config: GoRouter(initialLocation: '/t', routes: teacherRoutes)));
    await _both(t, 'tabs-classes', () => Router.withConfig(config: GoRouter(initialLocation: '/t/classes', routes: teacherRoutes)));
  });

  shotTest('tutor: papers to finish', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    routes['/teacher/home'] = (_) => busyHome();
    await _both(t, 'papers-to-finish', () => const PapersToFinishScreen());
    routes['/teacher/home'] = (_) => home(groups: [group(10, 'Maths', 12)]);
    await _both(t, 'papers-to-finish-none', () => const PapersToFinishScreen());
  });

  shotTest('courses: a course page', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    routes['/teacher/courses/c-1'] = (_) => {
          'course': {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'people': 14},
          'people': [
            for (final (i, n) in people.indexed)
              {
                'id': 'p$i', 'display_name': n, 'username': 'u$i', 'active': i != 13, 'last_seen_at': _iso(Duration(hours: -i)), 'added_at': _iso(const Duration(days: -8)),
                'avg_pct': i < 5 ? null : 0.5 + i / 40, 'tests_done': i < 5 ? 0 : 2,
              },
          ],
          'tests': [
            courseTest('y1', 'Unit 1 quiz', closes: const Duration(hours: 3), submitted: 6, writing: 3),
            courseTest('y2', 'Unit 2 quiz', opens: const Duration(days: 2), closes: const Duration(days: 2, hours: 3)),
            courseTest('y3', 'Unit 3 quiz', status: 'draft'),
            courseTest('y0', 'Greetings', closes: const Duration(days: -3), submitted: 12),
          ],
        };
    await _both(t, 'course-page', () => const CourseScreen(id: 'c-1', name: 'Spoken English, Batch 1'), height: 3600);
    await _both(t, 'course-rename', () => const CourseScreen(id: 'c-1', name: 'Spoken English, Batch 1'), then: (t) async {
      await t.tap(find.text('Rename course'));
      await _settle(t);
    });
    await _both(t, 'course-delete', () => const CourseScreen(id: 'c-1', name: 'Spoken English, Batch 1'), height: 3600, then: (t) async {
      await t.scrollUntilVisible(find.text('Delete this course'), 300, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('Delete this course'));
      await _settle(t);
    });
    // The second tab: the people of the course.
    await _both(t, 'course-people', () => const CourseScreen(id: 'c-1', name: 'Spoken English, Batch 1'), height: 3600, then: (t) async {
      await t.tap(find.text('People'));
      await _settle(t);
    });
    // A course just made: nobody in it and no test yet.
    routes['/teacher/courses/c-1'] = (_) => {
          'course': {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'people': 0},
          'people': <Object?>[],
          'tests': <Object?>[],
        };
    await _both(t, 'course-new', () => const CourseScreen(id: 'c-1', name: 'Spoken English, Batch 1'));
  });

  // A group's page has the same two tabs as a course's: Tests, and the students.
  shotTest('groups: a group page', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    routes['/teacher/groups/10/sub-Maths'] = (_) => {
          'students': [
            for (final (i, n) in people.take(12).indexed)
              {
                'id': 's$i', 'display_name': n, 'username': 'u$i', 'active': i != 11, 'last_seen_at': _iso(Duration(hours: -i)),
                'avg_pct': i < 3 ? null : 0.5 + i / 40, 'tests_done': i < 3 ? 0 : 2,
              },
          ],
          'tests': [
            courseTest('g1', 'Practice Paper 2', closes: const Duration(hours: 3), submitted: 7, writing: 2, assigned: 12),
            courseTest('g2', 'Real Numbers test', opens: const Duration(days: 5), closes: const Duration(days: 5, hours: 13), assigned: 12),
            courseTest('g3', 'Polynomials', status: 'draft'),
            courseTest('g0', 'Quadratic equations', closes: const Duration(days: -3), submitted: 12, assigned: 12),
          ],
        };
    await _both(t, 'group-page', () => const GroupScreen(classLevel: 10, subjectId: 'sub-Maths', subjectName: 'Maths'), height: 2600);
    await _both(t, 'group-students', () => const GroupScreen(classLevel: 10, subjectId: 'sub-Maths', subjectName: 'Maths'), height: 3000, then: (t) async {
      await t.tap(find.text('Students'));
      await _settle(t);
    });
  });

  // Making tests from several papers at once: which class, the papers, the days, the reading, the check, the posting, the end. The
  // real screen against a stand-in for the paper side of the server, so every step is what the tutor would see. Without SHOTS=1 only the
  // light picture is made, to keep the run short.
  shotTest('make tests: the steps', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    final maths = TestTarget.group(classLevel: 10, subjectId: 'sub-Maths', subjectName: 'Maths', size: 12);
    final classes = [
      maths,
      TestTarget.group(classLevel: 9, subjectId: 'sub-Science', subjectName: 'Science', size: 9),
      TestTarget.group(classLevel: 11, subjectId: 'sub-Physics', subjectName: 'Physics', size: 6),
      TestTarget.course(id: 'c-1', name: 'Spoken English, Batch 1', size: 14),
      TestTarget.course(id: 'c-2', name: 'Olympiad Prep', size: 8),
    ];
    final files = FakeSources(pdfs: [
      fakePdf('Real Numbers test.pdf', 4),
      fakePdf('Polynomials test.pdf', 3),
      fakePdf('Pair of linear equations.pdf', 4),
      fakePdf('Quadratic equations.pdf', 5),
      fakePdf('Arithmetic progressions.pdf', 3),
    ]);
    final server = PaperServer()
      ..questionsOf.addAll({'Real Numbers test': 20, 'Polynomials test': 18, 'Pair of linear equations': 15, 'Quadratic equations': 22, 'Arithmetic progressions': 12});
    makeServer = server;
    addTearDown(() => makeServer = null);

    Future<void> tapText(WidgetTester t, String text, {bool last = false}) async {
      final f = last ? find.text(text).last : find.text(text).first;
      await t.ensureVisible(f);
      await t.pump();
      await t.tap(f);
      await _settle(t);
    }

    /// Lets the clock run until [done]: the uploading and the reading go on by themselves, a busy moment is waited out.
    Future<void> until(WidgetTester t, bool Function() done, {int seconds = 240}) async {
      for (var i = 0; i < seconds * 10 && !done(); i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue, reason: 'it had not happened after $seconds s');
      await _settle(t);
    }

    bool shows(String text) => find.text(text).evaluate().isNotEmpty;
    String clock(int h) => time(DateTime(2000, 1, 1, h));

    Future<void> each(String name, Widget Function() screen, Future<void> Function(WidgetTester t) drive, {double height = 2400, Future<void> Function(WidgetTester t)? after}) async {
      for (final dark in _shots ? [false, true] : [false]) {
        server.reset();
        // Large text makes every screen taller, and a list builds only what is on screen: so the view grows with the text.
        await _show(t, screen(), dark: dark, height: height * (_textScale > 1 ? _textScale : 1));
        await drive(t);
        await _shot(t, '$name-${dark ? 'dark' : 'light'}');
        if (after != null) await after(t);
        await t.pumpWidget(const SizedBox.shrink());
      }
    }

    Widget inMaths() => MakeTestsScreen(target: maths, sources: files);
    Future<void> toDays(WidgetTester t) async {
      await tapText(t, 'Choose PDFs');
      await tapText(t, 'Next: choose the days');
    }

    /// Quadratic equations on its own times: 4:00 pm to 8:00 pm, 45 minutes.
    Future<void> ownTimes(WidgetTester t) async {
      await tapText(t, 'Quadratic equations');
      await tapText(t, clock(8));
      await tapText(t, clock(16), last: true);
      await tapText(t, clock(21), last: true);
      await tapText(t, clock(20), last: true);
      await tapText(t, '1½ minutes a question', last: true);
      await tapText(t, '45 min', last: true);
    }

    Future<void> toReading(WidgetTester t) async {
      await toDays(t);
      await tapText(t, 'Read the 5 papers with AI');
    }

    await each('make-which', () => MakeTestsScreen(targets: classes, sources: files), (t) async {});
    await each('make-papers-empty', inMaths, (t) async {});
    await each('make-papers', inMaths, (t) async => tapText(t, 'Choose PDFs'));
    await each('make-days', inMaths, (t) async {
      await toDays(t);
      await ownTimes(t);
      await tapText(t, 'Save', last: true);
    });
    await each('make-own', inMaths, (t) async {
      await toDays(t);
      await ownTimes(t);
    });

    // Half way: two papers read, the third on its second page, the last two waiting.
    var gate = Completer<void>();
    server.hold = (name, page) => (name == 'Pair of linear equations' && page >= 2) || name == 'Quadratic equations' || name == 'Arithmetic progressions' ? gate.future : null;
    await each('make-reading', inMaths, (t) async {
      gate = Completer<void>(); // a new hold for the dark picture: the light one let its papers through
      await toReading(t);
      await until(t, () => shows('Reading page 2 of 4'));
    }, after: (t) async {
      gate.complete();
      await until(t, () => shows('Ready to post'));
    });
    server.hold = null;

    // Two papers need the tutor: the others are ready to post.
    server.unsureOf.addAll({'Polynomials test': 2, 'Quadratic equations': 1});
    await each('make-check', inMaths, (t) async {
      await toReading(t);
      await until(t, () => shows('Check and post'));
    });
    server.unsureOf.clear();

    await each('make-ready', inMaths, (t) async {
      await toReading(t);
      await until(t, () => shows('Ready to post'));
    });
    await each('make-done', inMaths, (t) async {
      await toReading(t);
      await until(t, () => shows('Ready to post'));
      await tapText(t, 'Post 5 tests');
      await until(t, () => shows('5 tests are set'));
    });
  });

  // A test that opens tomorrow and closes four days later: the Day box and the lines under it say which day and date each is.
  shotTest('tests: when a test opens and closes', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    routes['/teacher/subjects'] = (_) => {'subjects': <Object?>[]};
    routes['/teacher/courses/c-1'] = (_) => {
          'course': {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'people': 14},
          'people': <Object?>[],
          'tests': <Object?>[],
        };
    routes['/teacher/tests/t-9'] = (_) => {
          'test': {
            'id': 't-9', 'title': 'Unit 2 quiz', 'course_id': 'c-1', 'course': 'Spoken English, Batch 1', 'class_level': null, 'subject_id': null,
            'time_limit_min': 15, 'opens_at': _iso(const Duration(days: 1)), 'closes_at': _iso(const Duration(days: 4)), 'status': 'draft',
            'shuffle': true, 'assign_group': false, 'assign_all': false, 'attempts': 0,
          },
          'questions': <Object?>[],
          'students': <Object?>[],
        };
    await _both(t, 'test-times', () => const TestEditor(id: 't-9'));
  });

  // The settings of a group's test as they are meant to be read: the test in one card, then When, Time to finish and Who and how.
  // Also the card a tap on Closes opens, and "Who writes it" with two students chosen.
  shotTest('tests: test settings', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    final maths = {'id': 'sub-Maths', 'name': 'Maths', 'is_default': true};
    routes['/teacher/subjects'] = (_) => {'subjects': [maths]};
    routes['/teacher/students'] = (_) => {
          'students': [
            for (var i = 0; i < 12; i++)
              {'id': 's$i', 'display_name': people[i], 'username': 's$i', 'class_level': 10, 'active': true, 'subjects': [maths], 'courses': <Object?>[]},
          ],
        };
    Map<String, Object?> groupTest({String status = 'draft', int attempts = 0, Duration opens = const Duration(days: 1)}) => {
          'test': {
            'id': 't-8', 'title': 'Unit 2 quiz', 'course_id': null, 'course': null, 'class_level': 10, 'subject_id': 'sub-Maths',
            'time_limit_min': 30, 'opens_at': _iso(opens), 'closes_at': _iso(const Duration(days: 4)), 'status': status,
            'shuffle': true, 'assign_group': true, 'assign_all': false, 'attempts': attempts,
          },
          'questions': [
            for (var i = 1; i <= 20; i++) {'id': 'q$i', 'text': 'Question number $i', 'chapter': i.isEven ? 'Real numbers' : null},
          ],
          'students': <Object?>[],
        };
    routes['/teacher/tests/t-8'] = (_) => groupTest();
    await _both(t, 'test-settings', () => const TestEditor(id: 't-8'), height: 2700);
    // With large text the screen is longer than the window: scroll to each thing before tapping it.
    Future<void> tapScrolled(WidgetTester t, String text) async {
      await t.scrollUntilVisible(find.text(text), 100, scrollable: find.byType(Scrollable).first, maxScrolls: 30);
      await t.ensureVisible(find.text(text));
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.text(text));
      await _settle(t);
    }

    await _both(t, 'test-settings-when', () => const TestEditor(id: 't-8'), height: 2700, then: (t) async {
      await tapScrolled(t, 'Closes');
    });
    await _both(t, 'test-settings-who', () => const TestEditor(id: 't-8'), height: 2700, then: (t) async {
      await tapScrolled(t, 'All 12 students');
      await tapScrolled(t, 'Some of them');
      await tapScrolled(t, 'Aarav Kumar');
      await tapScrolled(t, 'Diya Nair');
    });
    // A new test for a group (no link leads to it in the app, but the page is there): its class and subject come first.
    await _both(t, 'test-settings-new', () => const TestEditor(), height: 2700);
    // One students have started: its questions are fixed, it is saved with "Save changes", and it can still be deleted.
    routes['/teacher/tests/t-8'] = (_) => groupTest(status: 'published', attempts: 3, opens: const Duration(days: -1));
    await _both(t, 'test-settings-posted', () => const TestEditor(id: 't-8'), height: 2700);
  });

  // A posted test that opened yesterday and closes in three hours: the kicker and the Opens and Closes rows name the day and date.
  shotTest('tests: a posted test', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    routes['/teacher/tests/t-9/results'] = (_) => {
          'test': {
            'id': 't-9', 'title': 'Unit 1 quiz', 'status': 'published', 'course_id': 'c-1', 'course': 'Spoken English, Batch 1', 'class_level': null,
            'subject': null, 'time_limit_min': 15, 'opens_at': _iso(const Duration(days: -1)), 'closes_at': _iso(const Duration(hours: 3)), 'shuffle': true,
          },
          'summary': {'average_pct': 0.62, 'high_pct': 0.9, 'low_pct': 0.3, 'submitted': 6, 'assigned': 14, 'missed': 0, 'writing': 3},
          'students': [
            {
              'id': 's1', 'display_name': 'Aarav Kumar', 'status': 'submitted', 'submitted_at': _iso(const Duration(hours: -2)), 'time_taken_sec': 600,
              'attempt_no': 1, 'auto_submitted': false, 'score': 7, 'max_score': 10, 'attempt_id': 'a1',
            },
            {'id': 's2', 'display_name': 'Diya Menon', 'status': 'writing'},
          ],
          'questions': <Object?>[],
        };
    await _both(t, 'test-page', () => const TestResultsScreen(id: 't-9'));
  });

  shotTest('courses: adding people', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    Map<String, Object?> student(String id, String name, int? cls, List<String> subjects, {bool inCourse = false}) => {
          'id': id, 'display_name': name, 'username': id, 'class_level': cls, 'active': true,
          'subjects': [for (final s in subjects) {'id': 'sub-$s', 'name': s}],
          'courses': [if (inCourse) {'id': 'c-1', 'name': 'Spoken English, Batch 1'}],
        };
    routes['/teacher/students'] = (_) => {
          'students': [
            student('s1', 'Aarav Kumar', 10, ['Maths', 'Science']),
            student('s2', 'Diya Nair', 10, ['Maths']),
            student('s3', 'Ishaan Rao', 9, ['Science'], inCourse: true),
            student('s4', 'Meera Pillai', 9, ['Maths', 'Science']),
            student('s5', 'Rohan Krishnan', null, [], inCourse: false),
            student('s6', 'Sana Sheikh', 11, ['Physics']),
          ],
        };
    await _both(t, 'courses-add', () => const AddPeopleScreen(courseId: 'c-1', courseName: 'Spoken English, Batch 1'), then: (t) async {
      // The list is long and the window can be short (a phone on its side, a keyboard up): scroll to each person first.
      for (final name in ['Aarav Kumar', 'Diya Nair']) {
        await t.scrollUntilVisible(find.text(name), 100, scrollable: find.byType(Scrollable).first, maxScrolls: 30);
        await t.tap(find.text(name));
      }
      await _settle(t);
    });
    await _both(t, 'courses-add-filter', () => const AddPeopleScreen(courseId: 'c-1', courseName: 'Spoken English, Batch 1'), then: (t) async {
      await t.tap(find.text('All students').first);
      await _settle(t);
    });
    await _both(t, 'courses-add-new', () => const AddPeopleScreen(courseId: 'c-1', courseName: 'Spoken English, Batch 1'), then: (t) async {
      await t.tap(find.text('New person'));
      await _settle(t);
      await t.enterText(find.byType(TextField).first, 'Harini Venkatesh');
      await _settle(t);
    });
  });

  shotTest('courses: a person in a course', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    routes['/teacher/students/s-9'] = (_) => {
          'student': {
            'id': 's-9', 'display_name': 'Aarav Kumar', 'username': 'aarav.k', 'class_level': 10, 'active': true,
            'last_seen_at': _iso(const Duration(hours: -2)), 'subjects': [{'id': 'm', 'name': 'Maths'}, {'id': 's', 'name': 'Science'}],
            'courses': [{'id': 'c-1', 'name': 'Spoken English, Batch 1'}],
          },
          'attempts': [
            {'id': 'at-1', 'title': 'Greetings', 'attempt_no': 1, 'score': 8, 'max_score': 10, 'started_at': _iso(const Duration(days: -3, hours: -3)), 'submitted_at': _iso(const Duration(days: -3, hours: -3, minutes: 12))},
            {'id': 'at-2', 'title': 'Everyday phrases', 'attempt_no': 1, 'score': 6, 'max_score': 10, 'started_at': _iso(const Duration(days: -8, hours: -3)), 'submitted_at': _iso(const Duration(days: -8, hours: -3, minutes: 14))},
          ],
          'chapters': <Object?>[],
          'missed': <Object?>[],
        };
    await _both(t, 'course-person', () => const StudentDetailScreen(id: 's-9', courseId: 'c-1', courseName: 'Spoken English, Batch 1'), height: 2200);
    await _both(t, 'course-person-menu', () => const StudentDetailScreen(id: 's-9', courseId: 'c-1', courseName: 'Spoken English, Batch 1'), then: (t) async {
      await t.tap(find.bySemanticsLabel('More'));
      await _settle(t);
    });
  });

  shotTest('courses: the student app', (t) async {
    Map<String, Object?> test(String id, String title, String state, {Duration? closes, Duration? opens, int? score}) => {
          'id': id, 'course_id': 'c-1', 'title': title, 'class_level': null, 'time_limit_min': 15, 'opens_at': opens == null ? null : _iso(opens),
          'closes_at': closes == null ? null : _iso(closes), 'question_count': 10, 'max_marks': 10, 'state': state, 'retake': false, 'results_open': true,
          'attempt': state == 'done'
              ? {'id': 'att-$id', 'attempt_no': 1, 'submitted_at': _iso(const Duration(days: -3)), 'deadline_at': null, 'score': score, 'max_score': 10}
              : null,
        };
    final classTests = [
      {
        'id': 'a', 'title': 'Linear equations', 'course_id': null, 'class_level': 9, 'time_limit_min': 20, 'opens_at': null, 'closes_at': _iso(const Duration(hours: 3, minutes: 10)),
        'question_count': 12, 'max_marks': 12, 'state': 'open', 'retake': false, 'results_open': true, 'attempt': null,
      },
    ];
    routes['/student/home'] = (_) => {'server_now': _iso(Duration.zero), 'tuition': {'id': 't-1', 'name': 'Priya Maths Classes'}, 'tests': classTests, 'courses': 2};
    routes['/student/courses'] = (_) => {
          'courses': [
            {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'open': 1, 'closes_at': _iso(const Duration(hours: 9))},
            {'id': 'c-2', 'name': 'Olympiad Prep', 'open': 0, 'closes_at': null},
          ],
        };
    routes['/student/courses/c-1'] = (_) => {
          'server_now': _iso(Duration.zero),
          'course': {'id': 'c-1', 'name': 'Spoken English, Batch 1'},
          'tests': [
            test('y1', 'Unit 1 quiz', 'open', closes: const Duration(hours: 3, minutes: 10)),
            test('y0', 'Greetings', 'done', score: 8),
            test('yb', 'Everyday phrases', 'done', score: 6),
            test('y2', 'Unit 2 quiz', 'upcoming', opens: const Duration(days: 2)),
          ],
        };
    // A student in a class and a course: two tabs, Tests and Courses.
    _sessionAs(role: 'student', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9}]);
    await _both(t, 'courses-student-tests', () => const StudentHome());
    await _both(t, 'courses-student-courses', () => const StudentHome(), then: (t) async {
      await t.tap(find.text('Courses'));
      await _settle(t);
    });
    await _both(t, 'courses-student-course', () => const StudentCourseScreen(id: 'c-1', name: 'Spoken English, Batch 1'), height: 2400);
    // Someone who is only in courses has no class: their home is the list of courses.
    _sessionAs(role: 'student', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': null}]);
    session.user = {...session.user!, 'display_name': 'Rohan Krishnan', 'class_level': null};
    routes['/student/home'] = (_) => {'server_now': _iso(Duration.zero), 'tuition': {'id': 't-1', 'name': 'Priya Maths Classes'}, 'tests': <Object?>[], 'courses': 2};
    await _both(t, 'courses-student-only', () => const StudentHome());
    // ... and who has been taken out of every course has nothing yet.
    routes['/student/home'] = (_) => {'server_now': _iso(Duration.zero), 'tuition': {'id': 't-1', 'name': 'Priya Maths Classes'}, 'tests': <Object?>[], 'courses': 0};
    await _both(t, 'courses-student-nothing', () => const StudentHome());
  });

  // ---- the Library (design/comps/w4-library.html and w4-s-library*.html): the real screens against a stand-in for the Library side of the
  // server and for the phone, so each picture is what a person would see.
  Finder buttonCalled(String text) => find.byWidgetPredicate((w) => w is Pressable && w.label == text);

  Future<void> press(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    await _settle(t);
  }

  shotTest('library: the tutor\'s shelf', (t) async {
    _sessionAs(role: 'teacher', tuitions: tutorTuition);
    final server = lib.LibraryServer()
      ..people = 12
      ..tests = [for (var i = 0; i < 5; i++) courseTest('g$i', 'Test ${i + 1}', closes: Duration(days: -3 - i), submitted: 12, assigned: 12)];
    libraryServer = server;
    LibraryEnv.store = lib.FakeStore();
    LibraryEnv.uploads.clear();
    addTearDown(() {
      libraryServer = null;
      LibraryEnv.uploads.clear();
    });
    Widget group() => const GroupScreen(classLevel: 10, subjectId: 'sub-maths', subjectName: 'Maths');
    Future<void> openLibrary(WidgetTester t) => press(t, find.text('Library'));

    // Nothing on the shelf yet, and the card that makes its first section.
    await _both(t, 'lib-t-empty', group, height: 2000, then: openLibrary);
    await _both(t, 'lib-t-new-section', group, height: 2000, then: (t) async {
      await openLibrary(t);
      await press(t, buttonCalled('Add a section'));
      await t.enterText(find.byType(TextField), 'Test papers');
      await _settle(t);
    });

    // Three sections with their files, and what can be done from them.
    server.seed('PDFs', [('Chapter 4 notes.pdf', (3.8 * lib.mb).round())]);
    server.seed('Books', [('NCERT Mathematics Class 10.pdf', (62.4 * lib.mb).round())]);
    server.seed('Test papers', [('Mid-term 2025.pdf', (2.1 * lib.mb).round()), ('Blueprint (photo).jpg', (3.4 * lib.mb).round())]);
    void dated(int section, int file, String day) => (server.sections[section]['files'] as List)[file]['created_at'] = '${day}T10:00:00Z';
    dated(0, 0, '2026-10-29');
    dated(1, 0, '2026-10-28');
    dated(2, 0, '2026-10-27');
    dated(2, 1, '2026-10-27');
    await _both(t, 'lib-t-shelf', group, height: 3000, then: openLibrary);
    await _both(t, 'lib-t-add-file', group, height: 3000, then: (t) async {
      await openLibrary(t);
      await press(t, buttonCalled('Add a file').at(1));
    });
    await _both(t, 'lib-t-file-menu', group, height: 3000, then: (t) async {
      await openLibrary(t);
      await press(t, buttonCalled('Options for Chapter 4 notes.pdf'));
    });
    await _both(t, 'lib-t-section-menu', group, height: 3000, then: (t) async {
      await openLibrary(t);
      await press(t, buttonCalled('Options for Books'));
    });

    // Two files on their way into Books: one 41% sent, one stopped for lack of signal.
    (server.sections[1]['files'] as List)[0]['name'] = 'Maths formulas.pdf';
    final big = LibraryEnv.fake('NCERT Mathematics Class 10.pdf', (62.4 * lib.mb).round());
    final workbook = LibraryEnv.fake('Algebra workbook.pdf', (18.3 * lib.mb).round());
    LibraryEnv.uploads.jobs
      ..add(UploadJob('group:10:sub-maths', 's2', big)
        ..state = UploadState.sending
        ..sent = (big.size * 0.412).round())
      ..add(UploadJob('group:10:sub-maths', 's2', workbook)
        ..state = UploadState.stopped
        ..sent = (workbook.size * 0.182).round()
        ..offline = true
        ..problem = 'no signal');
    await _both(t, 'lib-t-uploading', group, height: 3000, then: openLibrary);
  });

  shotTest('library: the student\'s Library', (t) async {
    _sessionAs(role: 'student', tuitions: [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 10},
    ]);
    session.user = {...session.user!, 'display_name': 'Aarav Kumar', 'class_level': 10};
    final server = lib.LibraryServer();
    libraryServer = server;
    LibraryEnv.store = lib.FakeStore();
    final firstViewer = pdfPages;
    addTearDown(() {
      libraryServer = null;
      pdfPages = firstViewer;
    });
    Map<String, dynamic> file(String id, String section, String name, double size, String day) =>
        {...lib.LibraryServer.fileJson(id, section, name, (size * lib.mb).round()), 'created_at': '${day}T10:00:00Z'};
    server.student = {
      'groups': [
        {
          'class_level': 10,
          'subject_id': 'sub-maths',
          'subject': 'Maths',
          'sections': [
            {'id': 's1', 'name': 'PDFs', 'files': [file('f1', 's1', 'Chapter 4 notes.pdf', 3.8, '2026-10-29')]},
            {'id': 's2', 'name': 'Books', 'files': [file('f2', 's2', 'NCERT Mathematics Class 10.pdf', 62.4, '2026-10-28')]},
            {
              'id': 's3',
              'name': 'Test papers',
              'files': [file('f3', 's3', 'Mid-term 2025.pdf', 2.1, '2026-10-27'), file('f4', 's3', 'Blueprint (photo).jpg', 3.4, '2026-10-27')],
            },
          ],
        },
      ],
      'courses': [
        {
          'id': 'c-1',
          'name': 'Spoken English, Batch 1',
          'sections': [
            {'id': 's4', 'name': 'Handouts', 'files': [file('f5', 's4', 'Grammar basics.pdf', 1.2, '2026-10-26'), file('f6', 's4', 'Everyday phrases.pdf', 0.8, '2026-10-26')]},
          ],
        },
      ],
    };
    Map<String, Object?> done(String id, String title, int score, Duration ago) => {
          'id': id, 'course_id': null, 'title': title, 'class_level': 10, 'time_limit_min': 15, 'opens_at': null, 'closes_at': _iso(ago), 'question_count': 10,
          'max_marks': 10, 'state': 'done', 'retake': false, 'results_open': true,
          'attempt': {'id': 'att-$id', 'attempt_no': 1, 'submitted_at': _iso(ago), 'deadline_at': null, 'score': score, 'max_score': 10},
        };
    server.home = {
      'server_now': _iso(Duration.zero),
      'tuition': {'id': 't-1', 'name': 'Priya Maths Classes'},
      'tests': [
        {
          'id': 'a', 'title': 'Linear equations', 'course_id': null, 'class_level': 10, 'time_limit_min': 20, 'opens_at': null, 'closes_at': _iso(const Duration(hours: 3, minutes: 10)),
          'question_count': 12, 'max_marks': 12, 'state': 'open', 'retake': false, 'results_open': true, 'attempt': null,
        },
        done('d1', 'Number systems', 8, const Duration(days: -11)),
        done('d2', 'Polynomials', 6, const Duration(days: -14)),
      ],
      'courses': 2,
      'library': 6,
    };
    server.courseList = [
      {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'open': 1, 'closes_at': _iso(const Duration(hours: 9))},
      {'id': 'c-2', 'name': 'Olympiad Prep', 'open': 0, 'closes_at': null},
    ];

    // Home with Courses and Library in the bar; the Library tab; and Home with only the Library next to it.
    await _both(t, 'lib-s-home', () => const StudentHome());
    await _both(t, 'lib-s-list', () => const StudentHome(), then: (t) async {
      await press(t, find.text('Library'));
    });
    server.home = {...server.home, 'courses': 0};
    await _both(t, 'lib-s-home-only', () => const StudentHome());

    // One class's files, and the note after a download.
    const classPage = LibraryClassScreen(shelfKey: 'group:10:sub-maths', name: '10th Maths');
    await _both(t, 'lib-s-class', () => classPage);
    await _both(t, 'lib-s-class-saved', () => classPage, then: (t) async {
      await press(t, buttonCalled('Download Chapter 4 notes.pdf'));
    });

    // A PDF opened in the app. Its own pages need the phone, so a page is drawn here in their place.
    pdfPages = (file, onPage) => Builder(builder: (context) {
          onPage(3, 12);
          return Padding(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FractionallySizedBox(widthFactor: 0.5, child: Container(height: 16, decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(4)))),
              for (var p = 0; p < 4; p++) ...[
                SizedBox(height: p == 0 ? 22 : 36),
                for (var l = 0; l < 3; l++) ...[
                  if (l > 0) const SizedBox(height: 8),
                  FractionallySizedBox(widthFactor: l == 2 ? 0.6 : 1, child: Container(height: 6, decoration: BoxDecoration(color: hairline, borderRadius: BorderRadius.circular(3)))),
                ],
              ],
            ]),
          );
        });
    final chapter = LibFile.fromJson(file('f1', 's1', 'Chapter 4 notes.pdf', 3.8, '2026-10-29'));
    await _both(t, 'lib-s-viewer', () => FileViewerScreen(args: FileViewerArgs(chapter, where: '10th Maths · PDFs', teacher: false)));
  });

  shotTest('courses: the update screen', (t) async {
    _sessionAs(role: 'student', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9}]);
    updater.available = Release.fromJson({'version': '1.6.0', 'build': 8, 'apk': 'https://example.test/core-academy.apk', 'sha256': 'ab', 'size': 39 * 1024 * 1024, 'notes': ''});
    updater.step = UpdateStep.ready;
    await _both(t, 'update-needed', () => const UpdateRequiredScreen());
    updater.step = UpdateStep.allow;
    await _both(t, 'update-allow', () => const UpdateRequiredScreen());
    updater.step = UpdateStep.downloading;
    updater.progress = 0.42;
    await _both(t, 'update-downloading', () => const UpdateRequiredScreen());
    updater.available = null;
    updater.step = UpdateStep.ready;
  });
}
