// The page of a group and the page of a course: the tests and the people each on their own tab, and a tag on every test
// that says whether it is open now, coming up, not posted or finished (no small headings).
//   flutter test test/class_tabs_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/course_screens.dart';
import 'package:core_academy/features/teacher/group_screens.dart';
import 'package:core_academy/features/teacher/tests_screens.dart' show testStateTag;
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
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

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();

Map<String, Object?> _t(String id, String title, {String status = 'published', Duration? opens, Duration? closes, int submitted = 0, int assigned = 12, int writing = 0, bool everyoneDone = false}) => {
      'id': id,
      'title': title,
      'status': status,
      'opens_at': opens == null ? null : _iso(opens),
      'closes_at': closes == null ? null : _iso(closes),
      'question_count': 10,
      'submitted': submitted,
      'assigned': assigned,
      'writing': writing,
      'everyone_done': everyoneDone,
    };

/// One test in every state: two open (one with people writing), one coming up, one not posted, two finished (one early).
List<Object?> _everyState() => [
      _t('a1', 'Open quiz', closes: const Duration(hours: 3), submitted: 7),
      _t('a2', 'Writing quiz', closes: const Duration(hours: 5), submitted: 2, writing: 3),
      _t('b1', 'Later test', opens: const Duration(days: 2), closes: const Duration(days: 2, hours: 4)),
      _t('c1', 'Draft test', status: 'draft'),
      _t('d1', 'Closed test', opens: const Duration(days: -3), closes: const Duration(days: -1), submitted: 11),
      _t('d2', 'Early test', opens: const Duration(days: -1), closes: const Duration(days: 2), submitted: 12, everyoneDone: true),
    ];

List<Object?> _people(int n, String prefix) => [
      for (var i = 0; i < n; i++) {'id': '$prefix$i', 'display_name': '${prefix == 's' ? 'Student' : 'Person'} $i', 'active': true, 'tests_done': 0, 'avg_pct': null},
    ];

void _screen(WidgetTester t, {double h = 2400}) {
  t.view.physicalSize = Size(411, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void _tutor() {
  api.token = 'test';
  session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
  session.tuitions = [
    {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'},
  ];
  session.tuitionId = 't-1';
}

Future<void> _group(WidgetTester t, {List<Object?>? tests, List<Object?>? students}) async {
  _tutor();
  _routes['/teacher/groups/10/sub-maths'] = () => {'tests': tests ?? _everyState(), 'students': students ?? _people(3, 's')};
  _screen(t);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const GroupScreen(classLevel: 10, subjectId: 'sub-maths', subjectName: 'Maths')));
  await _settle(t);
}

Future<void> _course(WidgetTester t, {List<Object?>? tests, List<Object?>? people}) async {
  _tutor();
  _routes['/teacher/courses/c-1'] = () => {
        'course': {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'people': (people ?? _people(2, 'p')).length},
        'tests': tests ?? _everyState(),
        'people': people ?? _people(2, 'p'),
      };
  _screen(t);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const CourseScreen(id: 'c-1', name: 'Spoken English, Batch 1')));
  await _settle(t);
}

Future<void> _settle(WidgetTester t, [int ms = 2500]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await _settle(t, 900);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient(_answer));
  });

  setUp(() {
    _routes.clear();
    setResolvedDark(false);
  });

  group('a group page', () {
    testWidgets('opens on its tests, each with a tag for its state and no small headings', (t) async {
      await _group(t);
      for (final heading in ['OPEN NOW', 'COMING UP', 'NOT POSTED YET', 'FINISHED', 'STUDENTS']) {
        expect(find.text(heading), findsNothing, reason: '$heading is a tag or a tab now, not a small heading');
      }
      expect(find.text('Open now'), findsNWidgets(2));
      expect(find.text('Coming up'), findsOneWidget);
      expect(find.text('Not posted'), findsOneWidget);
      expect(find.text('Finished'), findsNWidgets(2), reason: 'a test that closed and a test that finished early');
      // How many handed in goes under the tag of a test that has people to count; a test not open yet and a draft have none.
      expect(find.text('7/12 handed in'), findsOneWidget);
      expect(find.text('3 writing now'), findsOneWidget);
      expect(find.text('11/12 handed in'), findsOneWidget);
      expect(find.text('12/12 handed in'), findsOneWidget);
      expect(find.textContaining('/12 handed in'), findsNWidgets(3), reason: 'a test not open yet and a draft have no count');
      // Open first, then coming up, then not posted, then finished.
      double y(String title) => t.getTopLeft(find.text(title)).dy;
      expect(y('Open quiz'), lessThan(y('Writing quiz')));
      expect(y('Writing quiz'), lessThan(y('Later test')));
      expect(y('Later test'), lessThan(y('Draft test')));
      expect(y('Draft test'), lessThan(y('Early test')));
      expect(y('Early test'), lessThan(y('Closed test')));
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the tabs say how many tests and how many students there are', (t) async {
      final semantics = t.ensureSemantics();
      await _group(t);
      expect(find.bySemanticsLabel('Tests, 6'), findsOneWidget);
      expect(find.bySemanticsLabel('Students, 3'), findsOneWidget);
      semantics.dispose();
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the Students tab shows the students and the button to add one; the tests are on the other tab', (t) async {
      await _group(t);
      expect(find.text('Student 0'), findsNothing);
      expect(find.text('Add student'), findsNothing);
      await _tap(t, find.text('Students'));
      expect(find.text('Student 0'), findsOneWidget);
      expect(find.text('Student 2'), findsOneWidget);
      expect(find.text('Add student'), findsOneWidget);
      expect(find.text('Open quiz'), findsNothing);
      expect(find.text('Make tests'), findsOneWidget, reason: 'the button stays above the tabs');
      await _tap(t, find.text('Tests'));
      expect(find.text('Open quiz'), findsOneWidget);
      expect(find.text('Student 0'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a group with nothing in it says so on each tab and can be removed', (t) async {
      await _group(t, tests: [], students: []);
      expect(find.text('No tests yet'), findsOneWidget);
      expect(find.text('Remove this group'), findsOneWidget);
      await _tap(t, find.text('Students'));
      expect(find.text('No students in this group yet.'), findsOneWidget);
      expect(find.text('Remove this group'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('five finished tests show three, and the rest on a tap', (t) async {
      await _group(t, tests: [for (var i = 0; i < 5; i++) _t('f$i', 'Old test $i', opens: Duration(days: -10 - i), closes: Duration(days: -9 - i), submitted: 10)]);
      expect(find.textContaining('Old test'), findsNWidgets(3));
      await _tap(t, find.text('Show all 5 finished tests'));
      expect(find.textContaining('Old test'), findsNWidgets(5));
      await _tap(t, find.text('Show fewer'));
      expect(find.textContaining('Old test'), findsNWidgets(3));
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('a course page', () {
    testWidgets('opens on its tests with the same tags, and keeps the rename link and the button above the tabs', (t) async {
      await _course(t);
      expect(find.text('Open now'), findsNWidgets(2));
      expect(find.text('Coming up'), findsOneWidget);
      expect(find.text('Not posted'), findsOneWidget);
      expect(find.text('Finished'), findsNWidgets(2));
      expect(find.text('Rename course'), findsOneWidget);
      expect(find.text('Make tests'), findsOneWidget);
      expect(find.text('Delete this course'), findsOneWidget);
      expect(find.text('Add people'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the People tab shows the people and the button to add more, and the delete link stays at the bottom', (t) async {
      await _course(t);
      await _tap(t, find.text('People'));
      expect(find.text('Person 0'), findsOneWidget);
      expect(find.text('Add people'), findsOneWidget);
      expect(find.text('Open quiz'), findsNothing);
      expect(find.text('Rename course'), findsOneWidget);
      expect(find.text('Delete this course'), findsOneWidget);
      double y(String s) => t.getTopLeft(find.text(s)).dy;
      expect(y('Add people'), lessThan(y('Delete this course')));
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a new course says there are no tests, and no one in it', (t) async {
      await _course(t, tests: [], people: []);
      expect(find.text('No tests yet'), findsOneWidget);
      await _tap(t, find.text('People'));
      expect(find.text('No one is in this course yet. Add the people who join it.'), findsOneWidget);
      expect(find.text('Add people'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the tag and the tab', () {
    testWidgets('each state has its own tag: Finished is outlined, Coming up is bold, Open now is green', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: Column(children: [testStateTag('open'), testStateTag('upcoming'), testStateTag('draft'), testStateTag('closed'), testStateTag('done')])),
      ));
      TagChip chip(String text) => t.widget<TagChip>(find.widgetWithText(TagChip, text).first);
      expect(chip('Open now').tone, Tone.success);
      expect(chip('Coming up').strong, isTrue);
      expect(chip('Not posted').outlined, isFalse);
      expect(chip('Not posted').strong, isFalse);
      expect(chip('Finished').outlined, isTrue);
      expect(find.text('Finished'), findsNWidgets(2), reason: 'closed and done both read Finished');
    });

    testWidgets('in the dark the chosen tab is a step lighter than its track, so it can be seen', (t) async {
      setResolvedDark(true);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: SegmentedToggle(labels: const ['Tests', 'People'], index: 0, onChanged: (_) {}, counts: const [3, 2])),
      ));
      final thumb = find.descendant(of: find.byType(AnimatedAlign), matching: find.byType(Container)).first;
      final decoration = t.widget<Container>(thumb).decoration! as BoxDecoration;
      expect(decoration.color, actionFill);
      expect(decoration.color, isNot(fill), reason: 'the track is drawn in the fill colour');
      setResolvedDark(false);
    });

    testWidgets('a tab with no number shows only its name', (t) async {
      final semantics = t.ensureSemantics();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SegmentedToggle(labels: const ['Tests', 'Library', 'People'], index: 1, onChanged: (_) {}, counts: const [3, null, 2])),
      ));
      expect(find.bySemanticsLabel('Tests, 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Library'), findsOneWidget);
      expect(find.bySemanticsLabel('People, 2'), findsOneWidget);
      semantics.dispose();
    });
  });

  // A test draws text in a plain square font, about twice as wide as the real one, so what these check is the choice the row makes: the tag
  // beside the title when there is room for both, under the details when there is not, and nothing cut short either way.
  group('a row with a tag', () {
    const longMeta = 'Maths · closes Sat 31 Oct, 9:58 am';

    Future<void> show(WidgetTester t,
        {required double width, double scale = 1.0, String title = 'Unit 1 quiz', String? meta = longMeta, String tag = 'Open now', String? note = '7/12 handed in'}) async {
      setResolvedDark(false);
      t.view.physicalSize = Size(width * 2.625, 2400);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        // In a list, as on the real screens: a row has all the height it needs.
        home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(20), child: TaggedRow(title: title, meta: meta, tag: TagChip(tag), note: note))),
      ));
      await t.pump();
    }

    bool cut(WidgetTester t, String text) => t.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

    testWidgets('with room for both, the tag is beside the title', (t) async {
      await show(t, width: 900);
      final title = t.getTopLeft(find.text('Unit 1 quiz'));
      final tag = t.getTopLeft(find.byType(TagChip));
      expect(tag.dx, greaterThan(title.dx + 300), reason: 'to the right of the title');
      expect((tag.dy - title.dy).abs(), lessThan(30), reason: 'on the title\'s line');
    });

    testWidgets('a short row at the usual size keeps its tag beside it', (t) async {
      await show(t, width: 411, title: 'Maths', meta: '12 students', tag: 'Group', note: null);
      expect(t.getTopLeft(find.byType(TagChip)).dx, greaterThan(t.getTopLeft(find.text('Maths')).dx + 100));
    });

    testWidgets('without room beside the title, the tag and its line go under the details, and nothing is cut', (t) async {
      await show(t, width: 411);
      expect(t.getTopLeft(find.byType(TagChip)).dy, greaterThan(t.getBottomLeft(find.text(longMeta)).dy), reason: 'under the details');
      expect(t.getTopLeft(find.byType(TagChip)).dx, t.getTopLeft(find.text('Unit 1 quiz')).dx, reason: 'lined up with the title');
      expect(find.text('7/12 handed in'), findsOneWidget);
      expect(cut(t, 'Unit 1 quiz'), isFalse);
      expect(cut(t, longMeta), isFalse);
    });

    testWidgets('at double text size on a narrow phone the tag goes under and nothing overflows', (t) async {
      await show(t, width: 320, scale: 2.0, title: 'Maths', meta: '12 students', tag: 'Group', note: null);
      expect(t.getTopLeft(find.byType(TagChip)).dy, greaterThan(t.getBottomLeft(find.text('12 students')).dy));
      expect(t.takeException(), isNull);
    });

    testWidgets('at every width and text size the title and the details are whole', (t) async {
      for (final width in [320.0, 360.0, 411.0, 600.0, 900.0]) {
        for (final scale in [1.0, 1.3, 1.6, 2.0]) {
          await show(t, width: width, scale: scale, title: 'Maths', meta: '12 students', tag: 'Group', note: '1 open');
          expect(t.takeException(), isNull, reason: 'width $width, text $scale');
          expect(cut(t, 'Maths'), isFalse, reason: 'the title at width $width, text $scale');
          expect(cut(t, '12 students'), isFalse, reason: 'the details at width $width, text $scale');
        }
      }
    });
  });
}
