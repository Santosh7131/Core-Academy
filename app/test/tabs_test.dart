// The tutor's tab bar has two tabs, Home and Classes. The Groups and Courses tabs of the versions before 1.8.0 are the Classes tab now:
// their old addresses still land there, and a page pushed over a tab (the papers waiting) comes back to it.
//   flutter test test/tabs_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/classes_screen.dart';
import 'package:core_academy/features/teacher/home_screen.dart';
import 'package:core_academy/features/teacher/teacher_routes.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/floating_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<http.Response> _answer(http.Request r) async {
  if (r.url.path == '/teacher/home') {
    final body = {
      'server_now': DateTime.now().toUtc().toIso8601String(),
      'tuition': {'id': 't-1', 'name': 'Core Academy', 'join_code': 'KR74MQ'},
      'pending_requests': 0,
      'groups': [
        {'class_level': 10, 'subject_id': 'sub-Maths', 'subject': 'Maths', 'students': 12, 'live': <Object?>[], 'posted': <Object?>[]},
      ],
      'totals': {'live': 0, 'writing': 0},
      'courses': <Object?>[],
      'finished': <Object?>[],
      'papers': <Object?>[],
    };
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});
  }
  return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.url.path}'}}), 404);
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<GoRouter> _open(WidgetTester t, {String at = '/t', double width = 411, double scale = 1}) async {
  t.view.physicalSize = Size(width * 2.625, 900 * 2.625);
  t.view.devicePixelRatio = 2.625;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAllTestValues);
  final router = GoRouter(initialLocation: at, routes: teacherRoutes);
  await t.pumpWidget(MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router));
  await _settle(t);
  return router;
}

Finder _tab(String label) => find.descendant(of: find.byType(FloatingTabs), matching: find.text(label));

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
  });

  testWidgets('the tab bar has two tabs, Home and Groups & courses, and no separate Groups or Courses tab', (t) async {
    await _open(t);
    expect(_tab('Home'), findsOneWidget);
    expect(_tab('Groups & courses'), findsOneWidget);
    expect(_tab('Groups'), findsNothing);
    expect(_tab('Courses'), findsNothing);
    expect(find.byType(TutorHome), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tapping Groups & courses shows them, and tapping Home brings Home back', (t) async {
    await _open(t);
    expect(find.byType(ClassesScreen), findsNothing);
    await t.tap(_tab('Groups & courses'));
    await _settle(t);
    expect(find.byType(ClassesScreen), findsOneWidget);
    expect(find.byType(TutorHome), findsNothing);
    expect(find.text('10th Maths'), findsOneWidget);
    await t.tap(_tab('Home'));
    await _settle(t);
    expect(find.byType(TutorHome), findsOneWidget);
    expect(find.byType(ClassesScreen), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });

  for (final old in ['/t/groups', '/t/courses']) {
    testWidgets('the old address $old lands on the Groups & courses tab', (t) async {
      final router = await _open(t, at: old);
      expect(router.state.uri.path, '/t/classes');
      expect(find.byType(ClassesScreen), findsOneWidget);
      expect(_tab('Groups & courses'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a page pushed over a tab (the papers waiting) comes back to that tab', (t) async {
    final router = await _open(t);
    await t.tap(_tab('Groups & courses'));
    await _settle(t);
    unawaited(router.push('/t/papers'));
    await _settle(t);
    expect(find.text('Papers to finish'), findsOneWidget);
    expect(find.byType(FloatingTabs), findsNothing, reason: 'a pushed page covers the tab bar');
    router.pop();
    await _settle(t);
    expect(find.byType(ClassesScreen), findsOneWidget);
    expect(_tab('Groups & courses'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('at the largest text on a narrow phone the second tab\'s name shrinks to stay inside its half of the bar', (t) async {
    await _open(t, width: 320, scale: 2.0);
    final bar = t.getRect(find.byType(FloatingTabs));
    final label = t.getRect(_tab('Groups & courses'));
    expect(label.left, greaterThanOrEqualTo(bar.center.dx), reason: 'the second tab is the right half of the bar');
    expect(label.right, lessThanOrEqualTo(bar.right));
    expect(t.takeException(), isNull, reason: 'no overflow');
    await t.pumpWidget(const SizedBox.shrink());
  });
}

void unawaited(Future<void> f) {}
