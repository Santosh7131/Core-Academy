// How lists come in. A picture cannot show this: the screen tests wait two seconds and draw the end
// state, where a row that never animated looks exactly like one that did. These read each row's
// opacity over time instead.
//   flutter test test/motion_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/group_screens.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _routes = <String, Object? Function()>{};

Future<http.Response> _answer(http.Request r) async {
  final h = _routes[r.url.path];
  if (h == null) return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.url.path}'}}), 404);
  return http.Response.bytes(utf8.encode(jsonEncode(h())), 200, headers: {'content-type': 'application/json'});
}

/// Time passes in frames, the way it does on a phone: an animation started in the middle of a long jump
/// would otherwise show no progress at its first frame.
Future<void> _advance(WidgetTester t, int ms) async {
  for (var left = ms; left > 0; left -= 16) {
    await t.pump(Duration(milliseconds: left < 16 ? left : 16));
  }
}

/// The opacity the row's own reveal is giving it right now.
double _opacity(WidgetTester t, Finder row) {
  // A row built just below the edge of the list counts as off stage to the finders, so look there too.
  final reveal = find.ancestor(of: row, matching: find.byType(Reveal, skipOffstage: false)).first;
  return t.widget<Opacity>(find.descendant(of: reveal, matching: find.byType(Opacity, skipOffstage: false)).first).opacity;
}

Finder _revealAround(Finder row) => find.ancestor(of: row, matching: find.byType(Reveal));

List<Widget> _rows(int n, {bool gaps = false}) => [
      for (var i = 0; i < n; i++) ...[
        if (gaps && i > 0) const SizedBox(height: 10),
        SizedBox(height: 50, child: Align(alignment: Alignment.centerLeft, child: Text('row $i'))),
      ],
    ];

Widget _list(List<Widget> children, {bool reduce = false}) => MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduce), child: child!),
      home: Scaffold(body: ListView(children: children)),
    );

void _screen(WidgetTester t, double w, double h) {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient(_answer));
  });

  setUp(_routes.clear);

  testWidgets('every row of a long list is revealed, not only the first nine', (t) async {
    _screen(t, 800, 1600);
    await t.pumpWidget(_list(staggered(_rows(25), scope: Object())));
    for (var i = 0; i < 25; i++) {
      expect(_revealAround(find.text('row $i')), findsOneWidget, reason: 'row $i has no reveal around it');
    }
  });

  testWidgets('spacers between rows are left alone and do not use up the order', (t) async {
    _screen(t, 800, 1600);
    await t.pumpWidget(_list(staggered(_rows(14, gaps: true), scope: Object())));
    expect(find.byType(Reveal), findsNWidgets(14));
    expect(_revealAround(find.text('row 13')), findsOneWidget);
  });

  testWidgets('rows come in one after another, and a late row still comes in', (t) async {
    _screen(t, 800, 1600);
    await t.pumpWidget(_list(staggered(_rows(25), scope: Object())));
    await _advance(t, 100);
    expect(_opacity(t, find.text('row 12')), 0, reason: 'a late row waits for its turn');
    await _advance(t, 600);
    final mid = _opacity(t, find.text('row 12'));
    expect(mid, greaterThan(0), reason: 'row 12 should be on its way in');
    expect(mid, lessThan(1), reason: 'row 12 should not have jumped in');
    expect(_opacity(t, find.text('row 0')), closeTo(1, 0.001));
    await _advance(t, 1500);
    for (var i = 0; i < 25; i++) {
      expect(_opacity(t, find.text('row $i')), closeTo(1, 0.001), reason: 'row $i never came in');
    }
  });

  testWidgets('a row below the visible part waits there and comes in as it is scrolled to', (t) async {
    _screen(t, 400, 600);
    await t.pumpWidget(_list(staggered(_rows(40), scope: Object())));
    await _advance(t, 2000);
    expect(_opacity(t, find.text('row 3')), closeTo(1, 0.001));
    expect(find.text('row 13', skipOffstage: false), findsOneWidget, reason: 'row 13 is built, just below the edge');
    expect(_opacity(t, find.text('row 13', skipOffstage: false)), 0, reason: 'it must not play out of sight');
    await t.drag(find.byType(ListView), const Offset(0, -300));
    await t.pump();
    await _advance(t, 100);
    final mid = _opacity(t, find.text('row 13'));
    expect(mid, greaterThan(0), reason: 'it should have started when it came into view');
    expect(mid, lessThan(1), reason: 'it should still be on its way in');
    await _advance(t, 700);
    expect(_opacity(t, find.text('row 13')), closeTo(1, 0.001));
  });

  testWidgets('a row that was already shown does not play again', (t) async {
    _screen(t, 400, 600);
    await t.pumpWidget(_list(staggered(_rows(40), scope: Object())));
    await _advance(t, 2000);
    await t.drag(find.byType(ListView), const Offset(0, -900));
    await _advance(t, 1500);
    await t.drag(find.byType(ListView), const Offset(0, 900));
    await t.pump();
    expect(find.text('row 2'), findsOneWidget);
    expect(_opacity(t, find.text('row 2')), closeTo(1, 0.001), reason: 'it was shown once; scrolling back must not hide it again');
  });

  testWidgets('with animations removed the rows are just there', (t) async {
    _screen(t, 800, 1600);
    await t.pumpWidget(_list(staggered(_rows(12), scope: Object()), reduce: true));
    await t.pump();
    expect(find.descendant(of: find.byType(Reveal), matching: find.byType(Opacity)), findsNothing);
    expect(find.text('row 11'), findsOneWidget);
  });

  testWidgets('the group page: every student row comes in, not only the first two', (t) async {
    api.token = 'test';
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
    final closes = DateTime.now().add(const Duration(hours: 3)).toUtc().toIso8601String();
    _routes['/teacher/groups/10/sub-maths'] = () => {
          'tests': [
            {'id': 'x1', 'title': 'Quadratic equations', 'status': 'published', 'opens_at': null, 'closes_at': closes, 'question_count': 18, 'submitted': 7, 'assigned': 16, 'writing': 2},
          ],
          'students': [
            for (var i = 0; i < 16; i++) {'id': 's$i', 'display_name': 'Student $i', 'active': true, 'tests_done': i % 3, 'avg_pct': i % 3 == 0 ? null : 60.0 + i},
          ],
        };
    _screen(t, 411, 914);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const GroupScreen(classLevel: 10, subjectId: 'sub-maths', subjectName: 'Maths'),
    ));
    for (var i = 0; i < 20 && find.text('Student 0').evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Student 0'), findsOneWidget, reason: 'the group never loaded');
    final built = [for (var i = 0; i < 16; i++) if (find.text('Student $i').evaluate().isNotEmpty) i];
    expect(built.length, greaterThan(5), reason: 'the first screenful should show several students');
    for (final i in built) {
      expect(_revealAround(find.text('Student $i')), findsOneWidget, reason: 'student $i has no reveal around it');
    }
    // They come in one after another, from the first student down.
    await _advance(t, 80);
    expect(_opacity(t, find.text('Student 0')), lessThan(0.05));
    await _advance(t, 300);
    expect(_opacity(t, find.text('Student 0')), greaterThan(0.3));
    expect(_opacity(t, find.text('Student 5')), 0, reason: 'the sixth student waits for its turn');
    await _advance(t, 1200);
    for (final i in built) {
      expect(_opacity(t, find.text('Student $i')), closeTo(1, 0.001), reason: 'student $i never came in');
    }
    // The ones further down come in as the list is scrolled to them.
    await t.scrollUntilVisible(find.text('Student 15'), 120, scrollable: find.byType(Scrollable).first);
    await _advance(t, 100);
    expect(_revealAround(find.text('Student 15')), findsOneWidget);
    expect(_opacity(t, find.text('Student 15')), lessThan(1), reason: 'the last student should be coming in');
    await _advance(t, 800);
    expect(_opacity(t, find.text('Student 15')), closeTo(1, 0.001));
    await t.pumpWidget(const SizedBox.shrink()); // stops the screen's refresh timers
  });
}
