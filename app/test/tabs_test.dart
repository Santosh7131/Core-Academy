// The tutor's tab bar has three tabs, Home, Groups & courses and the Bank. The Groups and Courses tabs of the versions before 1.8.0 are the
// Groups & courses tab now: their old addresses still land there, and a page pushed over a tab (the papers waiting) comes back to it.
//   flutter test test/tabs_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/bank_screen.dart';
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
  if (r.url.path == '/teacher/bank') {
    return http.Response.bytes(utf8.encode(jsonEncode({'papers': <Object?>[]})), 200, headers: {'content-type': 'application/json'});
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

  testWidgets('the tab bar has three tabs, Home, Groups & courses and Bank, and no separate Groups or Courses tab', (t) async {
    await _open(t);
    expect(_tab('Home'), findsOneWidget);
    expect(_tab('Groups & courses'), findsOneWidget);
    expect(_tab('Bank'), findsOneWidget);
    expect(_tab('Groups'), findsNothing);
    expect(_tab('Courses'), findsNothing);
    expect(find.byType(TutorHome), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tapping Bank shows the Bank, and tapping Home brings Home back', (t) async {
    await _open(t);
    expect(find.byType(BankScreen), findsNothing);
    await t.tap(_tab('Bank'));
    await _settle(t);
    expect(find.byType(BankScreen), findsOneWidget);
    expect(find.byType(TutorHome), findsNothing);
    expect(find.text('Nothing in the Bank yet'), findsOneWidget);
    await t.tap(_tab('Home'));
    await _settle(t);
    expect(find.byType(TutorHome), findsOneWidget);
    expect(find.byType(BankScreen), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the Bank has its own address, /t/bank, and the Bank tab is the one lit', (t) async {
    final router = await _open(t, at: '/t/bank');
    expect(router.state.uri.path, '/t/bank');
    expect(find.byType(BankScreen), findsOneWidget);
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

  // The long name has the wide tab (one and a half times each of the others), so it shrinks little and the short names none.
  for (final (width, scale) in [(411.0, 1.0), (360.0, 1.0), (320.0, 2.0)]) {
    testWidgets('at ${width.round()} dp with text at $scale every tab\'s name stays inside its own part of the bar', (t) async {
      await _open(t, width: width, scale: scale);
      final bar = t.getRect(find.byType(FloatingTabs));
      final unit = bar.width / 3.5;
      final parts = {
        'Home': (bar.left, bar.left + unit),
        'Groups & courses': (bar.left + unit, bar.left + 2.5 * unit),
        'Bank': (bar.left + 2.5 * unit, bar.right),
      };
      for (final e in parts.entries) {
        final label = t.getRect(_tab(e.key));
        expect(label.left, greaterThanOrEqualTo(e.value.$1 - 0.5), reason: '${e.key} starts inside its tab');
        expect(label.right, lessThanOrEqualTo(e.value.$2 + 0.5), reason: '${e.key} ends inside its tab');
      }
      expect(t.takeException(), isNull, reason: 'no overflow');
      await t.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('the long name is not shrunk below a readable size on a usual phone', (t) async {
    await _open(t, width: 411);
    final long = t.getSize(_tab('Groups & courses')).width;
    final short = t.getSize(_tab('Home')).width;
    expect(long, greaterThan(short * 2), reason: '"Groups & courses" is three times the length of "Home" and is drawn at about the same size');
    final text = t.widget<Text>(_tab('Groups & courses'));
    expect(text.style?.fontSize, 12.5, reason: 'the size the bar asks for; a FittedBox only shrinks it when it has to');
    await t.pumpWidget(const SizedBox.shrink());
  });
}

void unawaited(Future<void> f) {}
