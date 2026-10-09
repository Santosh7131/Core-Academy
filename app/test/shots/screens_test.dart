// Draws the multi-tuition screens to PNG files on this PC (no phone, no emulator): the real widgets and
// fonts, answers from a stub server. Without SHOTS=1 it only checks that each screen builds.
//   SHOTS=1 flutter test test/shots/screens_test.dart
// Pictures go to ../tools/out/shots (git-ignored).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/auth/login_screen.dart';
import 'package:core_academy/features/auth/signup_screen.dart';
import 'package:core_academy/features/student/home_screen.dart';
import 'package:core_academy/features/student/join_screen.dart';
import 'package:core_academy/features/student/profile_screen.dart';
import 'package:core_academy/features/teacher/group_screens.dart';
import 'package:core_academy/features/teacher/join_requests_screen.dart';
import 'package:core_academy/features/teacher/settings_screen.dart';
import 'package:core_academy/features/teacher/setup_screen.dart';
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
final _boundary = GlobalKey();
const _ratio = 2.625;

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();

/// What the stub server answers, by path. Replaced by each test.
final routes = <String, Object? Function(http.Request)>{};

Future<http.Response> _answer(http.Request r) async {
  final h = routes['${r.method} ${r.url.path}'] ?? routes[r.url.path];
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
  t.view.physicalSize = Size(1080, height);
  t.view.devicePixelRatio = _ratio;
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(
    key: _boundary,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(dark ? Brightness.dark : Brightness.light), home: screen),
  ));
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  if (!_shots) return;
  await t.runAsync(() async {
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_boundary));
    final image = await boundary.toImage(pixelRatio: _ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../tools/out/shots/$name.png')
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    for (final (family, asset) in [('Geist', 'assets/fonts/Geist.ttf'), ('GeistMono', 'assets/fonts/GeistMono.ttf'), ('PhosphorLight', 'assets/fonts/PhosphorLight.ttf')]) {
      final loader = FontLoader(family)..addFont(rootBundle.load(asset));
      await loader.load();
    }
    // The first use of the API client makes its http client, so it is made with the stub.
    http.runWithClient(() => api.token = 'test', () => MockClient(_answer));
  });

  setUp(routes.clear);

  testWidgets('login, as a tutor', (t) async {
    api.token = null;
    session.user = null;
    session.tuitionName = 'Core Academy';
    await _both(t, 'login-tutor', () => const LoginScreen(), then: (t) async {
      await t.tap(find.text('I am a tutor'));
      await _settle(t);
    });
  });

  testWidgets('sign up', (t) async {
    await _both(t, 'signup', () => const TutorSignUpScreen());
  });

  testWidgets('set up the tuition', (t) async {
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

  testWidgets('the join code', (t) async {
    _sessionAs(role: 'teacher', tuitions: [{'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'}]);
    routes['/teacher/tuition'] = (_) => {'tuition': _tuition()};
    await _both(t, 'code-first', () => const ShareCodeScreen(first: true));
  });

  testWidgets('join requests', (t) async {
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

  testWidgets('tutor home', (t) async {
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

  testWidgets('settings', (t) async {
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

  testWidgets('student join', (t) async {
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

  testWidgets('student home with two tuitions', (t) async {
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
    for (final dark in [false, true]) {
      await _show(t, const StudentHome(), dark: dark);
      await t.tap(find.byWidgetPredicate((w) => w is Text && (w.textSpan?.toPlainText() ?? w.data ?? '').contains('PRIYA MATHS CLASSES')).first);
      await _settle(t);
      await _shot(t, 'student-switch-${dark ? 'dark' : 'light'}');
      await t.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('student profile', (t) async {
    _sessionAs(role: 'student', tuitions: [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': 9},
      {'id': 't-2', 'name': 'Ravi Science Tuition', 'role': 'student', 'status': 'active', 'class_level': 9},
      {'id': 't-3', 'name': 'Meena Hindi Classes', 'role': 'student', 'status': 'pending', 'class_level': 9},
    ]);
    await _both(t, 'student-profile', () => const ProfileScreen(), height: 3000);
  });
}
