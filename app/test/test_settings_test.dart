// The settings of a test, as a tutor reads and changes them: the test in one card (its name, when it opens, how many questions), then
// When, Time to finish and Who and how, and a switch for mixing the questions up. The screen is the real one, against a stub server that
// remembers what it was sent; what is saved is the same as before the screen was simplified.
//   flutter test test/test_settings_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/format.dart' as f;
import 'package:core_academy/core/levels.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/tests_screens.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/difficulty.dart';
import 'package:core_academy/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [days] from today at [hour]:[minute], to the minute.
DateTime _at(int days, {int hour = 13, int minute = 20}) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + days, hour, minute);
}

String _iso(DateTime t) => t.toUtc().toIso8601String();

Map<String, dynamic> _subject(String name, {bool isDefault = false}) => {'id': 'sub-$name', 'name': name, 'is_default': isDefault};

const _names = [
  'Aarav Kumar', 'Diya Nair', 'Ishaan Rao', 'Meera Pillai', 'Rohan Krishnan', 'Sana Sheikh',
  'Tara Menon', 'Vikram Iyer', 'Yash Gupta', 'Zoya Ali', 'Kabir Das', 'Leela Reddy',
];

/// A group's test: 10th Maths, 20 questions, opening tomorrow and closing four days later, for the whole group.
Map<String, dynamic> _groupTest({String status = 'draft', int attempts = 0, int? limit = 30, bool shuffle = true, bool noOpens = false}) => {
      'test': {
        'id': 't-8', 'title': 'Unit 2 quiz', 'course_id': null, 'course': null, 'class_level': 10, 'subject_id': 'sub-Maths',
        'time_limit_min': limit, 'opens_at': noOpens ? null : _iso(_at(1)), 'closes_at': _iso(_at(4)), 'status': status,
        'shuffle': shuffle, 'assign_group': true, 'assign_all': false, 'attempts': attempts,
      },
      'questions': [for (var i = 1; i <= 20; i++) {'id': 'q$i', 'text': 'Question number $i', 'chapter': i.isEven ? 'Real numbers' : null}],
      'students': <Object?>[],
    };

/// The server's side: what it answers, and the last body it was sent on each call.
class _Server {
  Map<String, dynamic> test = _groupTest();
  int courseSize = 14;

  /// The subject the twelve students of 10th take.
  String studentsTake = 'Maths';
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};

  http.Response _ok(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

  Map<String, dynamic> _student(int i) => {
        'id': 's$i', 'display_name': _names[i], 'username': 's$i', 'class_level': 10, 'active': true,
        'subjects': [_subject(studentsTake)], 'courses': <Object?>[],
      };

  Future<http.Response> handle(http.Request r) async {
    final call = '${r.method} ${r.url.path}';
    calls.add(call);
    if (r.body.isNotEmpty) bodies[call] = jsonDecode(r.body) as Map<String, dynamic>;
    switch (call) {
      case 'GET /teacher/subjects':
        return _ok({'subjects': [_subject('Maths', isDefault: true), _subject('Science')]});
      case 'GET /teacher/students':
        return _ok({'students': [for (var i = 0; i < _names.length; i++) _student(i)]});
      case 'GET /teacher/courses/c-1':
        return _ok({'course': {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'people': courseSize}, 'people': <Object?>[], 'tests': <Object?>[]});
      case 'GET /teacher/tests/t-8':
        return _ok(test);
      case 'PATCH /teacher/tests/t-8':
      case 'POST /teacher/tests/t-8/publish':
      case 'POST /teacher/tests/t-new/publish':
        return _ok({'ok': true});
      case 'POST /teacher/tests':
        return _ok({'id': 't-new'});
    }
    return _ok({'error': {'code': 'not_found', 'message': 'No stub for $call'}}, 404);
  }
}

late _Server _s;

/// What the editor popped with, once the tutor saved (null while it is still open).
bool? _saved;

Future<void> _pump(WidgetTester t, [int ms = 600]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Taps, then lets the clock run long enough for a screen to finish arriving or leaving (the phone's page change takes most of a second).
Future<void> _tap(WidgetTester t, Finder finder, [int ms = 1000]) async {
  await t.ensureVisible(finder);
  await t.pump();
  await t.tap(finder);
  await _pump(t, ms);
}

/// Opens the editor on the stub server. [id] is a test; [courseId] a new test of a course; neither is a new group test.
Future<void> _open(WidgetTester t, {String? id = 't-8', String? courseId, double width = 411, double height = 2600, double scale = 1.0}) async {
  setResolvedDark(false);
  t.view.physicalSize = Size(width * 2.625, height * 2.625);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  _saved = null;
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (c, _) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async => _saved = await c.push<bool>('/edit'),
            child: const Text('open editor'),
          ),
        ),
      ),
    ),
    GoRoute(path: '/edit', builder: (_, _) => TestEditor(id: id, courseId: courseId, courseName: courseId == null ? null : 'Spoken English, Batch 1')),
  ]);
  await t.pumpWidget(MaterialApp.router(
    theme: buildTheme(Brightness.light),
    routerConfig: router,
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
  ));
  await _pump(t, 200);
  await _tap(t, find.text('open editor'), 1200);
}

/// Whether the pill with this label is the chosen one (it has the filled action ground).
bool _chosen(WidgetTester t, String label) {
  final box = find.ancestor(of: find.text(label), matching: find.byType(Container)).first;
  return (t.widget<Container>(box).decoration as BoxDecoration).color == actionFill;
}

/// The labels in the order they are read on the screen: line by line, then left to right. A test draws text in a plain square font,
/// wider than the real one, so the pills can wrap onto a second line that the real font does not need.
List<String> _readingOrder(WidgetTester t, List<String> labels) {
  final at = {for (final l in labels) l: t.getTopLeft(find.text(l))};
  return [...labels]..sort((a, b) {
      final dy = (at[a]!.dy - at[b]!.dy).round();
      return dy.abs() > 4 ? dy : at[a]!.dx.compareTo(at[b]!.dx);
    });
}

/// The Day box in the card: the day on two lines beside the time ("Tomorrow" over "Sat 31 Oct") for today or tomorrow, else one line.
Finder _dayBox(DateTime day) {
  final title = f.dayTitle(day);
  return find.byWidgetPredicate((w) {
    if (w is! Text || w.textSpan == null) return false;
    final shown = w.textSpan!.toPlainText();
    return shown == title || shown == title.replaceFirst(' · ', '\n');
  });
}

const _switch = 'Mix the questions up for each student';
const _marks = 'Students see their marks and the right answers as soon as they hand it in.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient((r) => _s.handle(r)));
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
    session.tuitionName = 'Priya Maths Classes';
  });

  setUp(() => _s = _Server());

  group('the test in one card', () {
    testWidgets('its name, when it opens and how many questions it has, under "Test settings"', (t) async {
      await _open(t);
      expect(find.text('Test settings'), findsOneWidget);
      expect(find.text('${groupName(10, 'Maths')} · Not posted yet'.toUpperCase()), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Unit 2 quiz'), findsOneWidget);
      expect(find.text('Opens ${f.whenTitle(_at(1))}'), findsOneWidget);
      expect(find.text('20 questions'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
    });

    testWidgets('a test with no opening time says it opens as soon as it is posted', (t) async {
      _s.test = _groupTest(noOpens: true);
      await _open(t);
      expect(find.text('Opens as soon as you post it'), findsOneWidget);
      expect(find.text('As soon as you post it'), findsOneWidget, reason: 'and so does the Opens row');
    });

    testWidgets('the questions are folded away until "See the questions" is tapped', (t) async {
      await _open(t);
      expect(find.text('Question number 1'), findsNothing);
      await _tap(t, find.text('See the questions'));
      expect(find.text('Question number 1'), findsOneWidget);
      expect(find.text('Question number 20'), findsOneWidget, reason: 'all of them, not only the first two');
      await _tap(t, find.text('Hide the questions'));
      expect(find.text('Question number 1'), findsNothing);
    });

    testWidgets('with no questions it says so, and offers to choose them', (t) async {
      _s.test = {..._groupTest(), 'questions': <Object?>[]};
      await _open(t);
      expect(find.text('No questions yet'), findsOneWidget);
      expect(find.text('Choose'), findsOneWidget);
      expect(find.text('See the questions'), findsNothing);
      expect(find.byIcon(Ph.chartBarHorizontal), findsNothing, reason: 'no questions, no line about how hard they are');
    });

    testWidgets('under the count it says how hard the questions are, and "See the questions" gives each one its level', (t) async {
      _s.test = {
        ..._groupTest(),
        'questions': [
          for (var i = 1; i <= 20; i++)
            {'id': 'q$i', 'text': 'Question number $i', 'chapter': null, 'difficulty': i <= 6 ? 'easy' : (i <= 15 ? 'medium' : 'hard')},
        ],
      };
      await _open(t);
      expect(find.text('20 questions'), findsOneWidget);
      expect(find.text('6 easy · 9 medium · 5 hard'), findsOneWidget);
      expect(find.byType(DifficultyChip), findsNothing, reason: 'folded away with the questions');
      await _tap(t, find.text('See the questions'));
      final chips = [for (final c in t.widgetList<DifficultyChip>(find.byType(DifficultyChip))) c.difficulty];
      expect(chips, [for (var i = 1; i <= 20; i++) i <= 6 ? Difficulty.easy : (i <= 15 ? Difficulty.medium : Difficulty.hard)]);
    });

    testWidgets('a question with no level counts as Medium', (t) async {
      await _open(t);
      expect(find.text('20 medium'), findsOneWidget);
    });

    testWidgets('at twice the text size on a small phone the line and the chips fit', (t) async {
      _s.test = {
        ..._groupTest(),
        'questions': [
          for (var i = 1; i <= 20; i++)
            {'id': 'q$i', 'text': 'Question number $i', 'chapter': null, 'difficulty': i <= 6 ? 'easy' : (i <= 15 ? 'medium' : 'hard')},
        ],
      };
      await _open(t, width: 320, scale: 2.0);
      expect(find.text('6 easy · 9 medium · 5 hard'), findsOneWidget);
      await _tap(t, find.text('See the questions'));
      expect(t.takeException(), isNull);
    });
  });

  group('When', () {
    testWidgets('Opens and Closes are rows that say the day, the date and the time, with a chevron', (t) async {
      await _open(t);
      expect(find.text('WHEN'), findsOneWidget);
      expect(find.text('Opens'), findsOneWidget);
      expect(find.text('Closes'), findsOneWidget);
      expect(find.text(f.whenTitle(_at(1))), findsOneWidget);
      expect(find.text(f.whenTitle(_at(4))), findsOneWidget);
      expect(find.byIcon(Ph.caretRight), findsNWidgets(3), reason: 'Opens, Closes and Who writes it');
    });

    testWidgets('a tap opens a card for that one, with its day, its time and Done', (t) async {
      await _open(t);
      await _tap(t, find.text('Closes'));
      expect(find.text('Closes'), findsNWidgets(2), reason: 'the row, and the title of the card');
      expect(_dayBox(_at(4)), findsOneWidget);
      expect(find.text(f.time(_at(4))), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('choosing another day for Closes changes the row, and it is saved', (t) async {
      await _open(t);
      await _tap(t, find.text('Closes'));
      await _tap(t, _dayBox(_at(4)));
      await _tap(t, find.text(f.dayTitle(_at(6))));
      await _tap(t, find.text('Done'));
      expect(find.text(f.whenTitle(_at(6))), findsOneWidget, reason: 'the row has the new day, at the same time');
      expect(find.text(f.whenTitle(_at(4))), findsNothing);
      await _tap(t, find.text('Post test'));
      expect(_s.bodies['PATCH /teacher/tests/t-8']!['closes_at'], _iso(_at(6)));
    });

    testWidgets('closing the card without Done changes nothing', (t) async {
      await _open(t);
      await _tap(t, find.text('Closes'));
      await _tap(t, _dayBox(_at(4)));
      await _tap(t, find.text(f.dayTitle(_at(6))));
      await _tap(t, find.byIcon(Ph.x).last);
      expect(find.text(f.whenTitle(_at(4))), findsOneWidget);
      expect(find.text(f.whenTitle(_at(6))), findsNothing);
    });

    testWidgets('Opens can be "Now": no opening time, open as soon as it is posted', (t) async {
      await _open(t);
      await _tap(t, find.text('Opens'));
      await _tap(t, _dayBox(_at(1)));
      await _tap(t, find.text('Now'));
      await _tap(t, find.text('Done'));
      expect(find.text('As soon as you post it'), findsOneWidget);
      expect(find.text('Opens as soon as you post it'), findsOneWidget, reason: 'the card at the top follows');
      await _tap(t, find.text('Post test'));
      expect(_s.bodies['PATCH /teacher/tests/t-8']!['opens_at'], isNull);
    });

    testWidgets('a closing time before the opening time is refused, with the reason beside the button', (t) async {
      await _open(t);
      await _tap(t, find.text('Closes'));
      await _tap(t, _dayBox(_at(4)));
      await _tap(t, find.text(f.dayTitle(_at(0))));
      await _tap(t, find.text('Done'));
      expect(find.text('The closing time must be after the opening time.'), findsOneWidget);
      expect(find.text('Save as a draft for now'), findsNothing);
    });
  });

  group('Time to finish', () {
    testWidgets('No limit, 15, 20, 30, 45 and 60 minutes, with the test\'s own chosen', (t) async {
      await _open(t);
      expect(find.text('TIME TO FINISH, IN MINUTES'), findsOneWidget);
      for (final label in ['No limit', '15', '20', '30', '45', '60']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(_chosen(t, '30'), isTrue);
      for (final label in ['No limit', '15', '20', '45', '60']) {
        expect(_chosen(t, label), isFalse, reason: label);
      }
    });

    testWidgets('they are read in that order', (t) async {
      await _open(t);
      const labels = ['No limit', '15', '20', '30', '45', '60'];
      expect(_readingOrder(t, labels), labels);
    });

    testWidgets('a tap chooses one, and only one is chosen', (t) async {
      await _open(t);
      await _tap(t, find.text('45'));
      expect(_chosen(t, '45'), isTrue);
      expect(_chosen(t, '30'), isFalse);
      await _tap(t, find.text('No limit'));
      expect(_chosen(t, 'No limit'), isTrue);
      expect(_chosen(t, '45'), isFalse);
    });

    testWidgets('a test with no limit has "No limit" chosen', (t) async {
      _s.test = _groupTest(limit: null);
      await _open(t);
      expect(_chosen(t, 'No limit'), isTrue);
      expect(_chosen(t, '30'), isFalse);
    });

    testWidgets('a time that is none of them gets a button of its own, in its place', (t) async {
      _s.test = _groupTest(limit: 25);
      await _open(t);
      expect(_chosen(t, '25'), isTrue);
      expect(_readingOrder(t, ['No limit', '15', '20', '25', '30', '45', '60']), ['No limit', '15', '20', '25', '30', '45', '60']);
    });

    testWidgets('"Other" lists more times, and the one picked becomes a button', (t) async {
      await _open(t);
      expect(find.text('90'), findsNothing);
      await _tap(t, find.text('Other'));
      expect(find.text('5 min'), findsOneWidget);
      expect(find.text('180 min'), findsOneWidget);
      await _tap(t, find.text('90 min'));
      expect(find.text('90'), findsOneWidget);
      expect(_chosen(t, '90'), isTrue);
      expect(_chosen(t, '30'), isFalse);
      await _tap(t, find.text('Post test'));
      expect(_s.bodies['PATCH /teacher/tests/t-8']!['time_limit_min'], 90);
    });

    testWidgets('"No limit" is saved as no time limit', (t) async {
      await _open(t);
      await _tap(t, find.text('No limit'));
      await _tap(t, find.text('Post test'));
      expect(_s.bodies['PATCH /teacher/tests/t-8']!['time_limit_min'], isNull);
    });
  });

  group('Who and how', () {
    testWidgets('a group\'s test says how many students it goes to', (t) async {
      await _open(t);
      expect(find.text('WHO AND HOW'), findsOneWidget);
      expect(find.text('All 12 students'), findsOneWidget);
    });

    testWidgets('a tap opens "Who writes it": all of them, or some', (t) async {
      await _open(t);
      await _tap(t, find.text('All 12 students'));
      expect(find.text('Who writes it'), findsOneWidget);
      expect(find.text('All 12 students'), findsOneWidget);
      expect(find.text('Some of them'), findsOneWidget);
      expect(find.text('Aarav Kumar'), findsNothing, reason: 'the names are only listed when some are to be chosen');
    });

    testWidgets('"Some of them" lists the students, and Done waits for at least one', (t) async {
      await _open(t);
      await _tap(t, find.text('All 12 students'));
      await _tap(t, find.text('Some of them'));
      expect(find.text('Aarav Kumar'), findsOneWidget);
      expect(find.text('Leela Reddy'), findsOneWidget);
      expect(find.text('Choose at least one student.'), findsOneWidget);
      await _tap(t, find.text('Aarav Kumar'));
      await _tap(t, find.text('Diya Nair'));
      expect(find.text('2 chosen'), findsOneWidget);
      expect(find.text('Choose at least one student.'), findsNothing);
      await _tap(t, find.text('Aarav Kumar'));
      expect(find.text('1 chosen'), findsOneWidget);
    });

    testWidgets('the ones chosen come back to the settings, and are what is saved', (t) async {
      await _open(t);
      await _tap(t, find.text('All 12 students'));
      await _tap(t, find.text('Some of them'));
      await _tap(t, find.text('Aarav Kumar'));
      await _tap(t, find.text('Diya Nair'));
      await _tap(t, find.text('Done'));
      expect(find.text('Who writes it'), findsNothing);
      expect(find.text('2 of 12 students'), findsOneWidget);
      await _tap(t, find.text('Post test'));
      final body = _s.bodies['PATCH /teacher/tests/t-8']!;
      expect(body['assign_group'], isFalse);
      expect(body['student_ids'], ['s0', 's1']);
      expect(_saved, isTrue);
    });

    testWidgets('going back from "Who writes it" without Done changes nothing', (t) async {
      await _open(t);
      await _tap(t, find.text('All 12 students'));
      await _tap(t, find.text('Some of them'));
      await _tap(t, find.text('Aarav Kumar'));
      await _tap(t, find.byIcon(Ph.arrowLeft).last);
      expect(find.text('All 12 students'), findsOneWidget);
      expect(find.text('1 of 12 students'), findsNothing);
    });

    testWidgets('a whole group is saved as the group, with no names', (t) async {
      await _open(t);
      await _tap(t, find.text('Post test'));
      final body = _s.bodies['PATCH /teacher/tests/t-8']!;
      expect(body['assign_group'], isTrue);
      expect(body['assign_all'], isFalse);
      expect(body['student_ids'], isEmpty);
    });

    testWidgets('a group with nobody in it says so and warns, and has no one to choose', (t) async {
      _s.studentsTake = 'Science';
      await _open(t);
      expect(find.text('No students in the group yet'), findsOneWidget);
      expect(find.text('No ${className(10)} student takes Maths yet, so nobody will see this test. Add students to the group first.'), findsOneWidget);
      await t.tap(find.text('No students in the group yet'));
      await _pump(t);
      expect(find.text('Who writes it'), findsNothing);
      expect(find.byIcon(Ph.caretRight), findsNWidgets(2), reason: 'Opens and Closes, but no list to open');
    });

    testWidgets('the switch is on for a test that mixes the questions up, and a tap turns it off and back on', (t) async {
      final handle = t.ensureSemantics();
      await _open(t);
      expect(find.bySemanticsLabel('$_switch, on'), findsOneWidget);
      await _tap(t, find.text(_switch));
      expect(find.bySemanticsLabel('$_switch, off'), findsOneWidget);
      await _tap(t, find.text(_switch));
      expect(find.bySemanticsLabel('$_switch, on'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('turned off, it is saved as the same order for everyone', (t) async {
      await _open(t);
      await _tap(t, find.text(_switch));
      await _tap(t, find.text('Post test'));
      expect(_s.bodies['PATCH /teacher/tests/t-8']!['shuffle'], isFalse);
    });

    testWidgets('a test that does not mix them up starts with the switch off', (t) async {
      _s.test = _groupTest(shuffle: false);
      final handle = t.ensureSemantics();
      await _open(t);
      expect(find.bySemanticsLabel('$_switch, off'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the last line says students see their marks and the answers at once', (t) async {
      await _open(t);
      expect(find.text(_marks), findsOneWidget);
    });
  });

  group('a course\'s test', () {
    testWidgets('goes to everyone in the course, with nobody to choose', (t) async {
      await _open(t, id: null, courseId: 'c-1');
      expect(find.text('Everyone in Spoken English, Batch 1 · 14 people'), findsOneWidget);
      expect(find.text('People added to the course before it closes get the test too.'), findsOneWidget);
      expect(find.byIcon(Ph.caretRight), findsNWidgets(2), reason: 'Opens and Closes, but no list of people to open');
      await t.tap(find.text('Everyone in Spoken English, Batch 1 · 14 people'));
      await _pump(t);
      expect(find.text('Who writes it'), findsNothing);
    });

    testWidgets('an empty course warns that nobody will see the test', (t) async {
      _s.courseSize = 0;
      await _open(t, id: null, courseId: 'c-1');
      expect(find.text('No one is in this course yet, so nobody will see this test. Add people to the course first.'), findsOneWidget);
    });

    testWidgets('a new one asks for a name, then for questions', (t) async {
      await _open(t, id: null, courseId: 'c-1');
      expect(find.text('NEW TEST · SPOKEN ENGLISH, BATCH 1'), findsOneWidget);
      expect(find.text('Give the test a name.'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Greetings');
      await _pump(t);
      expect(find.text('Choose at least one question.'), findsOneWidget);
      expect(find.text('Choose'), findsOneWidget, reason: 'a course needs no class or subject first');
    });
  });

  group('a new test for a group', () {
    testWidgets('asks for the class and subject first, because they decide which questions can be chosen', (t) async {
      await _open(t, id: null);
      expect(find.text('Choose a class'), findsOneWidget);
      expect(find.text('Maths'), findsOneWidget);
      expect(find.text('Choose a class and subject first'), findsNWidgets(2), reason: 'on the questions line, and where it says who writes it');
      expect(t.getTopLeft(find.text('Choose a class')).dy, lessThan(t.getTopLeft(find.text('Choose a class and subject first').first).dy));
      expect(find.text('Choose'), findsOneWidget, reason: 'there is a Choose, but it cannot be tapped yet');
      expect(find.text('NEW TEST'), findsOneWidget);
    });
  });

  group('a test students have started', () {
    setUp(() => _s.test = _groupTest(status: 'published', attempts: 3));

    testWidgets('keeps its questions: no "Change", and it says why', (t) async {
      await _open(t);
      expect(find.text('Students have started this test, so its questions cannot change.'), findsOneWidget);
      expect(find.text('Change'), findsNothing);
      expect(find.text('Choose'), findsNothing);
    });

    testWidgets('is saved with "Save changes", and can still be deleted', (t) async {
      await _open(t);
      expect(find.text('${groupName(10, 'Maths')} · Posted'.toUpperCase()), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
      expect(find.text('Post test'), findsNothing);
      expect(find.text('Save as a draft for now'), findsNothing);
      expect(find.text('Delete this test'), findsOneWidget);
      await _tap(t, find.text('Save changes'));
      expect(_s.calls, contains('PATCH /teacher/tests/t-8'));
      expect(_s.calls, isNot(contains('POST /teacher/tests/t-8/publish')), reason: 'it is already posted');
      expect(_saved, isTrue);
    });
  });

  testWidgets('a test nobody has started can change its questions', (t) async {
    await _open(t);
    expect(find.text('Students have started this test, so its questions cannot change.'), findsNothing);
    expect(find.text('Change'), findsOneWidget);
  });

  group('saving', () {
    testWidgets('a draft is saved with every setting, and posted', (t) async {
      await _open(t);
      await _tap(t, find.text('Post test'));
      expect(_s.bodies['PATCH /teacher/tests/t-8'], {
        'title': 'Unit 2 quiz',
        'question_ids': [for (var i = 1; i <= 20; i++) 'q$i'],
        'time_limit_min': 30,
        'opens_at': _iso(_at(1)),
        'closes_at': _iso(_at(4)),
        'shuffle': true,
        'class_level': 10,
        'subject_id': 'sub-Maths',
        'assign_all': false,
        'assign_group': true,
        'student_ids': <String>[],
      });
      expect(_s.bodies['POST /teacher/tests/t-8/publish'], {'published': true});
      expect(_saved, isTrue);
    });

    testWidgets('"Save as a draft for now" saves and leaves it unposted', (t) async {
      await _open(t);
      await _tap(t, find.text('Save as a draft for now'));
      expect(_s.calls, contains('PATCH /teacher/tests/t-8'));
      expect(_s.calls, isNot(contains('POST /teacher/tests/t-8/publish')));
      expect(_saved, isTrue);
    });

    testWidgets('a test without a name cannot be posted, and says why', (t) async {
      await _open(t);
      await t.enterText(find.byType(TextField), '');
      await _pump(t);
      expect(find.text('Give the test a name.'), findsOneWidget);
      expect(find.text('Save as a draft for now'), findsNothing);
    });
  });

  group('large text on a small phone', () {
    testWidgets('every part of the settings is there, with nothing running off the screen', (t) async {
      await _open(t, width: 320, height: 4200, scale: 2.0);
      expect(find.text('Test settings'), findsOneWidget);
      for (final label in ['WHEN', 'TIME TO FINISH, IN MINUTES', 'WHO AND HOW', _switch, _marks, 'Post test']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });
  });
}
