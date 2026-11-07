// The clock on the test screen counts down every second without drawing the question and its options again. A question can be a
// formula, which costs more to draw than a sentence, and the phones students have are not the fastest. The screen is the real one,
// against a stub server; the drawing is counted with Flutter's own hook for it.
//   flutter test test/clock_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/student/test_screen.dart';
import 'package:core_academy/ui/math_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _iso(Duration from) => DateTime.now().toUtc().add(from).toIso8601String();

http.Response _json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});

Future<http.Response> _server(http.Request r) async {
  if (r.method == 'POST' && r.url.path == '/student/tests/t1/start') {
    return _json({
      'attempt': {'id': 'a1', 'server_now': _iso(Duration.zero), 'deadline_at': _iso(const Duration(minutes: 14))},
      'questions': [
        {
          'id': 'q1', 'n': 1, 'image_url': null, 'chosen': null, 'flagged': false,
          'text': r'If $x^2 = 9$ and $x > 0$, what is $x + 1$?',
          'options': [r'$3$', r'$4$', r'$\frac{9}{2}$', r'$10$'],
        },
        {'id': 'q2', 'n': 2, 'image_url': null, 'chosen': null, 'flagged': false, 'text': 'Which is prime?', 'options': ['4', '6', '7', '9']},
      ],
    });
  }
  if (r.method == 'PUT' && r.url.path == '/student/attempts/a1/answers') return _json({});
  return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.method} ${r.url.path}'}}), 404);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient(_server));
  });

  testWidgets('a second passing redraws the clock, not the question and its options', (t) async {
    await t.pumpWidget(const MaterialApp(home: TestScreen(testId: 't1')));
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(MathText), findsNWidgets(5), reason: 'the question and its four options are on the screen');

    var formulas = 0;
    var clocks = 0;
    debugOnRebuildDirtyWidget = (e, _) {
      if (e.widget is MathText) formulas++;
      if (e.widget.runtimeType.toString() == '_ClockPill') clocks++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    debugOnRebuildDirtyWidget = null;

    // ignore: avoid_print
    print('five seconds of the clock: the question and options were drawn $formulas times, the clock $clocks times');
    expect(formulas, 0, reason: 'the question and its options stay as they are while the clock runs');
    expect(clocks, greaterThanOrEqualTo(5), reason: 'the clock is drawn every second');

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('choosing an answer still draws the question', (t) async {
    await t.pumpWidget(const MaterialApp(home: TestScreen(testId: 't1')));
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    var formulas = 0;
    debugOnRebuildDirtyWidget = (e, _) {
      if (e.widget is MathText) formulas++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    await t.tap(find.byType(MathText).at(1));
    await t.pump(const Duration(milliseconds: 50));
    debugOnRebuildDirtyWidget = null;
    expect(formulas, greaterThan(0), reason: 'the picked option is marked, so the options are drawn');

    await t.pumpWidget(const SizedBox());
  });
}
