// Making several tests at once: the tutor adds papers, chooses the days, AI reads them one after another, and the tests that are
// ready are posted. The screen is the real one, against a stand-in server that keeps papers, pages, questions and tests the way the
// real one does; the phone's files and camera are stand-ins too.
//   flutter test test/make_tests_test.dart
import 'dart:typed_data';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/format.dart' as f;
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/make_test.dart';
import 'package:core_academy/features/teacher/make_tests_screen.dart';
import 'package:core_academy/features/teacher/paper_runner.dart' show suggestedLimit;
import 'package:core_academy/features/teacher/papers_screens.dart' show PaperReviewScreen;
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/make_fakes.dart';

late PaperServer _s;

// ---------------------------------------------------------------- driving the screen

String? _at;

final _maths = TestTarget.group(classLevel: 10, subjectId: 'sub-Maths', subjectName: 'Maths', size: 12);
final _english = TestTarget.course(id: 'c-1', name: 'Spoken English, Batch 1', size: 14);

Future<void> _open(WidgetTester t, {TestTarget? target, List<TestTarget> targets = const [], FakeSources? sources}) async {
  t.view.physicalSize = const Size(411 * 2.625, 1700 * 2.625);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  _at = null;
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (c, _) => Scaffold(body: Center(child: TextButton(onPressed: () => c.push('/make'), child: const Text('open make')))),
    ),
    GoRoute(path: '/make', builder: (_, _) => MakeTestsScreen(target: target, targets: targets, sources: sources ?? FakeSources())),
    GoRoute(
      path: '/t/papers/:id',
      builder: (c, s) {
        _at = s.uri.toString();
        return Scaffold(body: Center(child: TextButton(onPressed: () => c.pop(), child: Text('paper ${s.pathParameters['id']}'))));
      },
    ),
    GoRoute(
      path: '/t/groups/:cls/:subject/chat',
      builder: (c, s) {
        _at = s.uri.toString();
        return Scaffold(body: Center(child: TextButton(onPressed: () => c.pop(), child: const Text('chat page'))));
      },
    ),
  ]);
  await t.pumpWidget(MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router));
  await _pump(t, 200);
  await _tap(t, find.text('open make'));
}

Future<void> _pump(WidgetTester t, [int ms = 600]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester t, Finder finder, [int ms = 500]) async {
  await t.ensureVisible(finder);
  await t.pump();
  await t.tap(finder);
  await _pump(t, ms);
}

/// Lets the clock run until [done], for the work that goes on by itself (uploading, reading, waiting out a busy moment).
Future<void> _until(WidgetTester t, bool Function() done, {int seconds = 120}) async {
  for (var i = 0; i < seconds * 10 && !done(); i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue, reason: 'it had not happened after $seconds s');
}

String _day(DateTime d) => f.shortDate(d);

DateTime _inDays(int n) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + n);
}

String _clock(int h, [int m = 0]) => f.time(DateTime(2000, 1, 1, h, m));

/// Taps Choose PDFs: whatever files the stand-in holds are added.
Future<void> _addFive(WidgetTester t) async {
  await _tap(t, find.text('Choose PDFs'));
}

final _names = ['Real Numbers test', 'Polynomials test', 'Pair of linear equations', 'Quadratic equations', 'Arithmetic progressions'];

FakeSources _fiveFiles() => FakeSources(pdfs: [
      fakePdf('Real_Numbers test.pdf', 4),
      fakePdf('Polynomials test.pdf', 3),
      fakePdf('Pair of linear equations.PDF', 4),
      fakePdf('Quadratic equations.pdf', 5),
      fakePdf('Arithmetic progressions.pdf', 3),
    ]);

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

  setUp(() {
    _s = PaperServer();
    setResolvedDark(false);
  });

  // ---------------------------------------------------------------- the names

  group('a paper\'s name from its file', () {
    test('drops .pdf and the underscores', () {
      expect(testNameFromFile('Real_Numbers test.pdf'), 'Real Numbers test');
      expect(testNameFromFile('Pair of linear equations.PDF'), 'Pair of linear equations');
      expect(testNameFromFile('  chapter__4   quiz .pdf'), 'chapter 4 quiz');
    });

    test('is never empty, and never longer than the server takes', () {
      expect(testNameFromFile('.pdf'), 'Paper');
      expect(testNameFromFile('${'a' * 120}.pdf').length, lessThanOrEqualTo(80));
    });
  });

  // ---------------------------------------------------------------- adding the papers

  group('adding the papers', () {
    testWidgets('an empty list offers PDFs, photos and AI, and cannot go on yet', (t) async {
      await _open(t, target: _maths);
      expect(find.text('Add the papers'), findsOneWidget);
      expect(find.text('10TH MATHS · STEP 2 OF 4'), findsOneWidget);
      expect(find.text('Choose PDFs'), findsOneWidget);
      expect(find.text('Add a paper from photos'), findsOneWidget);
      expect(find.text('No paper? Let AI write a test'), findsOneWidget);
      expect(find.text('Add at least one paper.'), findsOneWidget);
      await _tap(t, find.text('Next: choose the days'), 200);
      expect(find.text('Choose the days'), findsNothing, reason: 'there is nothing to choose days for');
    });

    testWidgets('several PDFs at once each become a paper, named from the file, with its pages', (t) async {
      await _open(t, target: _maths, sources: _fiveFiles());
      await _addFive(t);
      for (final n in _names) {
        expect(find.text(n), findsOneWidget);
      }
      expect(find.text('4 pages'), findsNWidgets(2));
      expect(find.text('3 pages'), findsNWidgets(2));
      expect(find.text('5 pages'), findsOneWidget);
      expect(find.text('5 papers · 19 pages'), findsOneWidget);
      expect(find.text('Add another paper'), findsOneWidget);
      expect(find.text('Each paper becomes its own test.'), findsOneWidget);
    });

    testWidgets('a paper can be taken out again', (t) async {
      final semantics = t.ensureSemantics();
      await _open(t, target: _maths, sources: _fiveFiles());
      await _addFive(t);
      await _tap(t, find.bySemanticsLabel('Remove Polynomials test'));
      expect(find.text('Polynomials test'), findsNothing);
      expect(find.text('4 papers · 16 pages'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a PDF that cannot be opened is said so, and the others are still added', (t) async {
      await _open(t, target: _maths, sources: FakeSources(pdfs: [fakePdf('Good one.pdf', 2), fakePdf('Broken.pdf', 1, broken: true)]));
      await _addFive(t);
      expect(find.text('Good one'), findsOneWidget);
      expect(find.text('Broken'), findsNothing);
      expect(find.textContaining('"Broken.pdf" could not be opened'), findsOneWidget);
    });

    testWidgets('ten papers are the most: the rest are left out and the tutor is told', (t) async {
      final many = FakeSources(pdfs: [for (var i = 1; i <= 12; i++) fakePdf('Paper $i.pdf', 1)]);
      await _open(t, target: _maths, sources: many);
      await _addFive(t);
      expect(find.text('10 papers · 10 pages'), findsOneWidget);
      expect(find.textContaining('Ten papers at a time is the most, so 2 PDFs were left out'), findsOneWidget);
    });

    testWidgets('a long PDF keeps its first 20 pages and says so', (t) async {
      await _open(t, target: _maths, sources: FakeSources(pdfs: [fakePdf('Long book.pdf', 34)]));
      await _addFive(t);
      expect(find.text('20 pages · first 20 of 34 pages'), findsOneWidget);
    });

    testWidgets('photos make a paper too, with a name AI replaces once it has read it', (t) async {
      final photos = FakeSources(photoSets: [
        [Uint8List.fromList([1]), Uint8List.fromList([2])],
      ]);
      await _open(t, target: _maths, sources: photos);
      await _tap(t, find.text('Add a paper from photos'));
      expect(find.text('Paper from photos 1'), findsOneWidget);
      expect(find.text('2 pages'), findsOneWidget);
    });

    testWidgets('coming back from the photos with none adds nothing', (t) async {
      await _open(t, target: _maths, sources: FakeSources());
      await _tap(t, find.text('Add a paper from photos'));
      expect(find.text('Add at least one paper.'), findsOneWidget);
    });

    testWidgets('Back goes out of the screen when the class was already known', (t) async {
      await _open(t, target: _maths);
      await _tap(t, find.byIcon(Ph.arrowLeft));
      expect(find.text('Add the papers'), findsNothing);
      expect(find.text('open make'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------- the days

  group('choosing the days', () {
    Future<void> toDays(WidgetTester t, {FakeSources? sources, TestTarget? target}) async {
      await _open(t, target: target ?? _maths, sources: sources ?? _fiveFiles());
      await _addFive(t);
      await _tap(t, find.text('Next: choose the days'));
    }

    testWidgets('the first test is tomorrow and each paper is the day after the one before', (t) async {
      await toDays(t);
      expect(find.text('Choose the days'), findsOneWidget);
      expect(find.text('10TH MATHS · STEP 3 OF 4'), findsOneWidget);
      expect(find.text('First test on'), findsOneWidget);
      // The first day shows twice: in the pill at the top and on the first paper.
      expect(find.text(_day(_inDays(1))), findsNWidgets(2));
      for (var i = 2; i <= 5; i++) {
        expect(find.text(_day(_inDays(i))), findsOneWidget, reason: 'paper $i is on day $i from today');
      }
      expect(find.text('Every test: ${_clock(8)} to ${_clock(21)}'), findsOneWidget);
      expect(find.text('1½ minutes a question · shuffled'), findsOneWidget);
      expect(find.text('${_clock(8)} to ${_clock(21)}'), findsNWidgets(5));
      expect(find.text('Read the 5 papers with AI'), findsOneWidget);
    });

    testWidgets('moving the first day moves every paper that has no day of its own', (t) async {
      await toDays(t);
      await _tap(t, find.text(_day(_inDays(1))).first);
      await _tap(t, find.text(f.dayTitle(_inDays(7))).last);
      expect(find.text(_day(_inDays(7))), findsNWidgets(2));
      expect(find.text(_day(_inDays(11))), findsOneWidget);
      expect(find.text(_day(_inDays(2))), findsNothing);
    });

    testWidgets('a paper given its own day keeps it when the first day moves', (t) async {
      await toDays(t);
      // The third paper to the day after tomorrow's week: day 9.
      await _tap(t, find.text(_day(_inDays(3))));
      await _tap(t, find.text(f.dayTitle(_inDays(9))).last);
      expect(find.text(_day(_inDays(9))), findsOneWidget);
      await _tap(t, find.text(_day(_inDays(1))).first);
      await _tap(t, find.text(f.dayTitle(_inDays(2))).last);
      expect(find.text(_day(_inDays(9))), findsOneWidget, reason: 'the third paper stayed on its own day');
      expect(find.text(_day(_inDays(3))), findsOneWidget, reason: 'the second paper moved with the first');
    });

    testWidgets('a test\'s own times show in its row, and "the same as the others" takes them back', (t) async {
      await toDays(t);
      await _tap(t, find.text('Quadratic equations'));
      expect(find.text('Test 4 of 5 · 5 pages'), findsOneWidget);
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'Quadratic equations', reason: 'the field holds the name');
      await _tap(t, find.text(_clock(8)).first);
      await _tap(t, find.text(_clock(16)));
      await _tap(t, find.text(_clock(21)).last);
      await _tap(t, find.text(_clock(20)));
      await _tap(t, find.text('1½ minutes a question').last);
      await _tap(t, find.text('45 min'));
      await _tap(t, find.text('Same for all'));
      await _tap(t, find.text('Save'));
      expect(find.text('${_clock(16)} to ${_clock(20)} · 45 min · same order for all'), findsOneWidget);
      expect(find.text('${_clock(8)} to ${_clock(21)}'), findsNWidgets(4));

      await _tap(t, find.text('Quadratic equations'));
      await _tap(t, find.text('Use the same as the others'));
      expect(find.text('${_clock(8)} to ${_clock(21)}'), findsNWidgets(5));
    });

    testWidgets('the name can be changed on the test\'s own card', (t) async {
      await toDays(t);
      await _tap(t, find.text('Polynomials test'));
      await t.enterText(find.byType(TextField), 'Polynomials, part 1');
      await _tap(t, find.text('Save'));
      expect(find.text('Polynomials test'), findsNothing);
      expect(find.text('Polynomials, part 1'), findsOneWidget);
    });

    testWidgets('the times every test shares can be changed in one place', (t) async {
      await toDays(t);
      await _tap(t, find.text('Change'));
      expect(find.text('For the tests that do not have times of their own.'), findsOneWidget);
      await _tap(t, find.text(_clock(21)).last);
      await _tap(t, find.text(_clock(20)));
      await _tap(t, find.text('Save'));
      expect(find.text('Every test: ${_clock(8)} to ${_clock(20)}'), findsOneWidget);
      expect(find.text('${_clock(8)} to ${_clock(20)}'), findsNWidgets(5));
    });

    testWidgets('a test cannot close before it opens: the card says so and will not save', (t) async {
      await toDays(t);
      await _tap(t, find.text('Change'));
      await _tap(t, find.text(_clock(21)).last);
      await _tap(t, find.text(_clock(7)));
      expect(find.text('The test has to close after it opens.'), findsOneWidget);
      await _tap(t, find.text('Save'), 200);
      expect(find.text('Every test'), findsOneWidget, reason: 'the card stays open');
    });

    testWidgets('a closing time that has passed stops the reading and says which test', (t) async {
      await toDays(t);
      await _tap(t, find.text(_day(_inDays(1))).first);
      await _tap(t, find.text(f.dayTitle(_inDays(0))).last);
      await _tap(t, find.text('Change'));
      await _tap(t, find.text(_clock(8)).last);
      await _tap(t, find.text(_clock(5)));
      await _tap(t, find.text(_clock(21)).last);
      await _tap(t, find.text(_clock(5, 30)));
      await _tap(t, find.text('Save'));
      expect(find.text('Test 1 closes in the past. Change its day or its times.'), findsOneWidget);
      await _tap(t, find.text('Read the 5 papers with AI'), 200);
      expect(find.text('Reading your papers'), findsNothing);
      // Before 6 am no closing time the form offers (the earliest is 5:30 am) has passed yet.
    }, skip: DateTime.now().hour < 6);

    testWidgets('Back from the days goes to the papers, which are still there', (t) async {
      await toDays(t);
      await _tap(t, find.byIcon(Ph.arrowLeft));
      expect(find.text('Add the papers'), findsOneWidget);
      expect(find.text('5 papers · 19 pages'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------- reading and posting

  group('reading and posting', () {
    Future<void> toReading(WidgetTester t, FakeSources sources, {TestTarget? target}) async {
      await _open(t, target: target ?? _maths, sources: sources);
      await _addFive(t);
      await _tap(t, find.text('Next: choose the days'));
      await _tap(t, find.text(sources.pdfs.length == 1 ? 'Read the paper with AI' : 'Read the ${sources.pdfs.length} papers with AI'));
    }

    testWidgets('each paper is made on the server with its plan, its name and its class, and its pages are uploaded', (t) async {
      await toReading(t, _fiveFiles());
      await _until(t, () => _s.sent.length == 5);
      final b = _s.sent[3];
      expect(b['exam_name'], 'Quadratic equations');
      expect(b['pages'], 5);
      expect(b['sizes'], [3, 3, 3, 3, 3]);
      expect(b['class_level'], 10);
      expect(b['subject_id'], 'sub-Maths');
      expect(b.containsKey('course_id'), isFalse);
      final plan = b['plan'] as Map<String, dynamic>;
      final opens = DateTime.parse(plan['opens_at'] as String).toLocal();
      final closes = DateTime.parse(plan['closes_at'] as String).toLocal();
      expect(DateTime(opens.year, opens.month, opens.day, opens.hour), DateTime(_inDays(4).year, _inDays(4).month, _inDays(4).day, 8), reason: 'the fourth paper opens at 8:00 am on day 4');
      expect(DateTime(closes.year, closes.month, closes.day, closes.hour), DateTime(_inDays(4).year, _inDays(4).month, _inDays(4).day, 21));
      expect(plan['shuffle'], true);
      expect(plan.containsKey('time_limit_min'), isFalse, reason: 'no limit of its own: a minute and a half a question, worked out when it is posted');
      await _until(t, () => find.text('Check and post').evaluate().isNotEmpty || find.text('Ready to post').evaluate().isNotEmpty);
    });

    testWidgets('a course\'s papers are the course\'s: no class or subject is sent', (t) async {
      await _open(t, target: _english, sources: FakeSources(pdfs: [fakePdf('Reading.pdf', 2)]));
      await _addFive(t);
      await _tap(t, find.text('Next: choose the days'));
      await _tap(t, find.text('Read the paper with AI'));
      await _until(t, () => _s.sent.length == 1);
      expect(_s.sent.first['course_id'], 'c-1');
      expect(_s.sent.first.containsKey('class_level'), isFalse);
      expect(_s.sent.first.containsKey('subject_id'), isFalse);
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
    });

    testWidgets('a paper from photos is sent without a name, so AI can name it', (t) async {
      final photos = FakeSources(photoSets: [
        [Uint8List.fromList([1, 1]), Uint8List.fromList([2, 2])],
      ]);
      await _open(t, target: _maths, sources: photos);
      await _tap(t, find.text('Add a paper from photos'));
      await _tap(t, find.text('Next: choose the days'));
      await _tap(t, find.text('Read the paper with AI'));
      await _until(t, () => _s.sent.length == 1);
      expect(_s.sent.first.containsKey('exam_name'), isFalse);
      expect(_s.sent.first['sizes'], [2, 2]);
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
    });

    testWidgets('while it reads, the screen counts the papers read and says what each is doing', (t) async {
      await toReading(t, _fiveFiles());
      expect(find.text('Reading your papers'), findsOneWidget);
      expect(find.text('10TH MATHS · STEP 4 OF 4'), findsOneWidget);
      expect(find.text('AI PAPER READER'), findsOneWidget);
      expect(find.text('Posting opens when every paper is read.'), findsOneWidget);
      expect(find.text('Waiting'), findsWidgets);
      expect(find.text('Keep the app open while AI reads. If you leave, it carries on where it stopped when you come back.'), findsOneWidget);
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
      // One paper after another, so no two were being read at the same time: the papers were made in the order they were added.
      expect([for (final b in _s.sent) b['exam_name']], _names);
    });

    testWidgets('every paper ready: the week is listed with each test\'s questions, limit and times, and posting makes the tests as planned', (t) async {
      await toReading(t, _fiveFiles());
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
      expect(find.text('Each test opens on its day for the 12 students in 10th Maths.'), findsOneWidget);
      expect(find.text('THE WEEK'), findsOneWidget);
      expect(find.text('4 questions · 20 min · ${_clock(8)} to ${_clock(21)}'), findsNWidgets(5), reason: '4 questions is 6 minutes, so the smallest limit the editor offers');
      expect(find.text('Students see their marks and the right answers as soon as they hand a test in.'), findsOneWidget);
      expect(find.text('Post 5 tests'), findsOneWidget);

      await _tap(t, find.text('Post 5 tests'));
      await _until(t, () => find.text('5 tests are set').evaluate().isNotEmpty);
      expect(_s.testBodies.length, 5);
      final one = _s.testBodies[1];
      expect(one['title'], 'Polynomials test');
      expect(one['class_level'], 10);
      expect(one['subject_id'], 'sub-Maths');
      expect(one['assign_group'], true);
      expect(one['assign_all'], false);
      expect(one['time_limit_min'], suggestedLimit(4));
      expect(one['shuffle'], true);
      expect((one['question_ids'] as List).length, 4);
      expect(one['paper_id'], 'p2');
      expect(DateTime.parse(one['closes_at'] as String).toLocal().hour, 21);
      expect(DateTime.parse(one['opens_at'] as String).toLocal().hour, 8);
      expect(_s.papers.values.every((p) => p.tests.single['status'] == 'published'), isTrue, reason: 'every test was posted');
      expect(find.text('They open on their days, from ${_day(_inDays(1))} to ${_day(_inDays(5))}. You will find them under Coming up on Home.'), findsOneWidget);
      expect(find.text('Back to 10th Maths'), findsOneWidget);
    });

    testWidgets('a course\'s tests are made for the course', (t) async {
      await _open(t, target: _english, sources: FakeSources(pdfs: [fakePdf('Reading.pdf', 2)]));
      await _addFive(t);
      await _tap(t, find.text('Next: choose the days'));
      await _tap(t, find.text('Read the paper with AI'));
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
      expect(find.text('Each test opens on its day for the 14 people in Spoken English, Batch 1.'), findsOneWidget);
      await _tap(t, find.text('Post 1 test'));
      await _until(t, () => find.text('1 test is set').evaluate().isNotEmpty);
      final b = _s.testBodies.single;
      expect(b['course_id'], 'c-1');
      expect(b.containsKey('class_level'), isFalse);
      expect(b.containsKey('assign_group'), isFalse);
    });

    testWidgets('a paper that needs the tutor waits: the ready ones are posted, the other says how many questions to check', (t) async {
      _s.unsureOf['Polynomials test'] = 2;
      _s.unsureOf['Quadratic equations'] = 1;
      await toReading(t, _fiveFiles());
      await _until(t, () => find.text('Check and post').evaluate().isNotEmpty);
      expect(find.textContaining('3 of 5 are ready'), findsOneWidget);
      expect(find.textContaining('tap a paper to check what it needs'), findsOneWidget);
      expect(find.text('2 to check'), findsOneWidget);
      expect(find.text('1 to check'), findsOneWidget);
      expect(find.text('ready'), findsNWidgets(3));
      expect(find.text('Post the 3 that are ready'), findsOneWidget);
      expect(find.text('The other 2 wait here until you check them.'), findsOneWidget);

      await _tap(t, find.text('Post the 3 that are ready'));
      await _until(t, () => _s.testBodies.length == 3);
      await _pump(t, 800);
      expect({for (final b in _s.testBodies) b['title']}, {'Real Numbers test', 'Pair of linear equations', 'Arithmetic progressions'});
      expect(find.text('Post the 3 that are ready'), findsNothing);
      expect(find.text('posted'), findsNWidgets(3));
      expect(find.text('Back to Home'), findsOneWidget);
      expect(find.text('What is left is under Needs you on Home.'), findsOneWidget);
    });

    testWidgets('a paper opened to be checked is posted with the rest once it is ready', (t) async {
      _s.unsureOf['Polynomials test'] = 2;
      await toReading(t, _fiveFiles());
      await _until(t, () => find.text('Check and post').evaluate().isNotEmpty);
      await _tap(t, find.text('Post the 4 that are ready'));
      await _until(t, () => _s.testBodies.length == 4);
      await _pump(t, 800);

      await _tap(t, find.text('Polynomials test'));
      expect(_at, '/t/papers/p2', reason: 'the paper opens on its own page');
      _s.checked('Polynomials test');
      await _tap(t, find.text('paper p2'));
      expect(find.text('Ready to post'), findsOneWidget, reason: 'the one paper left is ready, so it is the ready page');
      expect(find.text('Post 1 test'), findsOneWidget);
      await _tap(t, find.text('Post 1 test'));
      await _until(t, () => find.text('5 tests are set').evaluate().isNotEmpty);
      expect(_s.testBodies.length, 5);
      expect(_s.testBodies.last['title'], 'Polynomials test');
    });

    testWidgets('a paper that already has a posted test is not given a second one', (t) async {
      await toReading(t, _fiveFiles());
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
      // The tutor posted the third paper from its own page in the meantime.
      final third = _s.papers['p3']!;
      third.tests.add({'id': 't901', 'title': third.name, 'status': 'published', 'opens_at': null, 'closes_at': null, 'question_count': 4});
      await _tap(t, find.text('Post 5 tests'));
      await _until(t, () => find.text('5 tests are set').evaluate().isNotEmpty);
      expect(_s.testBodies.length, 4, reason: 'four were made; the third already had its test');
      expect(_s.testBodies.any((b) => b['paper_id'] == 'p3'), isFalse);
    });

    testWidgets('a draft test left by an earlier try is posted instead of a new one being made', (t) async {
      await toReading(t, _fiveFiles());
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
      final second = _s.papers['p2']!;
      second.tests.add({'id': 't902', 'title': second.name, 'status': 'draft', 'opens_at': null, 'closes_at': null, 'question_count': 4});
      await _tap(t, find.text('Post 5 tests'));
      await _until(t, () => find.text('5 tests are set').evaluate().isNotEmpty);
      expect(_s.testBodies.any((b) => b['paper_id'] == 'p2'), isFalse);
      expect(second.tests.single['status'], 'published');
    });

    testWidgets('a limit chosen for every test goes to the server as it is; no limit chosen is a minute and a half a question', (t) async {
      _s.questionsOf['Real Numbers test'] = 20;
      await _open(t, target: _maths, sources: FakeSources(pdfs: [fakePdf('Real Numbers test.pdf', 4), fakePdf('Polynomials test.pdf', 3)]));
      await _addFive(t);
      await _tap(t, find.text('Next: choose the days'));
      await _tap(t, find.text('Polynomials test'));
      await _tap(t, find.text('1½ minutes a question').last);
      await _tap(t, find.text('45 min'));
      await _tap(t, find.text('Save'));
      await _tap(t, find.text('Read the 2 papers with AI'));
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
      await _tap(t, find.text('Post 2 tests'));
      await _until(t, () => find.text('2 tests are set').evaluate().isNotEmpty);
      expect(_s.testBodies[0]['time_limit_min'], 30, reason: '20 questions at a minute and a half is 30 minutes');
      expect(_s.testBodies[1]['time_limit_min'], 45, reason: 'the limit the tutor chose for that test');
    });

    testWidgets('a paper that did not upload says so and can be tried again', (t) async {
      _s.failUpload.add('p1');
      await toReading(t, FakeSources(pdfs: [fakePdf('Real_Numbers test.pdf', 4), fakePdf('Polynomials test.pdf', 3)]));
      await _until(t, () => find.text('Try again').evaluate().isNotEmpty);
      expect(find.text('The upload did not go through. Try again.'), findsOneWidget);
      expect(_s.papers.containsKey('p1'), isFalse, reason: 'the half-made paper was taken back, so trying again starts clean');
      // The other paper was read all the same.
      await _until(t, () => find.text('Check and post').evaluate().isNotEmpty);
      expect(_s.papers.values.any((p) => p.name == 'Polynomials test' && p.read.length == 3), isTrue, reason: 'the other paper was read all the same');
      await _tap(t, find.text('Try again'));
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
      expect(find.text('Real Numbers test'), findsOneWidget);
    });

    testWidgets('a paper with no questions in it can be left out', (t) async {
      _s.questionsOf['Empty one'] = 0;
      await toReading(t, FakeSources(pdfs: [fakePdf('Empty one.pdf', 1), fakePdf('Real_Numbers test.pdf', 4)]));
      await _until(t, () => find.text('Check and post').evaluate().isNotEmpty);
      expect(find.text('No multiple-choice questions found'), findsOneWidget);
      await _tap(t, find.text('Leave out'));
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
      expect(find.text('Empty one'), findsNothing);
      expect(_s.papers.values.where((p) => p.name == 'Empty one'), isEmpty, reason: 'it was taken off the server too');
    });

    testWidgets('leaving while AI reads asks first, and Stay carries on', (t) async {
      await toReading(t, _fiveFiles());
      await _tap(t, find.byIcon(Ph.arrowLeft));
      expect(find.text('Leave this page?'), findsOneWidget);
      expect(find.textContaining('AI stops reading. The papers are kept'), findsOneWidget);
      await _tap(t, find.text('Stay'));
      expect(find.text('Leave this page?'), findsNothing);
      expect(find.text('Reading your papers'), findsOneWidget);
      await _until(t, () => find.text('Ready to post').evaluate().isNotEmpty);
    });

    testWidgets('Leave goes back to where the tutor came from, and nothing more is sent', (t) async {
      await toReading(t, _fiveFiles());
      await _until(t, () => _s.sent.isNotEmpty);
      await _tap(t, find.byIcon(Ph.arrowLeft));
      await _tap(t, find.text('Leave'));
      expect(find.text('open make'), findsOneWidget);
      final seen = _s.sent.length;
      await _pump(t, 5000);
      expect(_s.sent.length, seen, reason: 'no new paper was started after the tutor left');
    });
  });

  // ---------------------------------------------------------------- a paper opened later

  group('a paper left half way is posted with the days that were planned for it', () {
    Future<void> openPaper(WidgetTester t, String id) async {
      t.view.physicalSize = const Size(411 * 2.625, 1700 * 2.625);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (c, _) => Scaffold(body: Center(child: TextButton(onPressed: () => c.push('/paper'), child: const Text('open paper'))))),
        GoRoute(path: '/paper', builder: (_, _) => PaperReviewScreen(id: id)),
      ]);
      await t.pumpWidget(MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router));
      await _pump(t, 200);
      await _tap(t, find.text('open paper'));
      await _pump(t, 800);
    }

    Map<String, dynamic> plan({int? limit, bool shuffle = true, Duration opens = const Duration(days: 1), Duration closes = const Duration(days: 1, hours: 12)}) => {
          'opens_at': DateTime.now().add(opens).toUtc().toIso8601String(),
          'closes_at': DateTime.now().add(closes).toUtc().toIso8601String(),
          'time_limit_min': ?limit,
          'shuffle': shuffle,
        };

    /// Saves the ready questions and says yes to posting.
    Future<void> saveAndPost(WidgetTester t) async {
      await _tap(t, find.text('Save 4 ready questions'));
      await _pump(t, 1200);
      expect(find.text('Post it as a test?'), findsOneWidget);
      await _tap(t, find.text('Post now'));
      await _until(t, () => _s.testBodies.isNotEmpty, seconds: 10);
    }

    testWidgets('the test opens and closes when the tutor chose, with the limit and the order', (t) async {
      final p = _s.seed('Polynomials test', plan: plan(limit: 45, shuffle: false));
      await openPaper(t, p.id);
      await _tap(t, find.text('Save 4 ready questions'));
      await _pump(t, 1200);
      final opens = DateTime.parse(p.plan!['opens_at'] as String).toLocal();
      final closes = DateTime.parse(p.plan!['closes_at'] as String).toLocal();
      expect(find.text('4 questions · 45 min · opens ${f.whenDate(opens)} · closes ${f.whenDate(closes)}'), findsOneWidget);
      await _tap(t, find.text('Post now'));
      await _until(t, () => _s.testBodies.isNotEmpty, seconds: 10);
      final b = _s.testBodies.single;
      expect(b['time_limit_min'], 45);
      expect(b['shuffle'], false);
      expect(b['opens_at'], p.plan!['opens_at']);
      expect(b['closes_at'], p.plan!['closes_at']);
      expect(b['title'], 'Polynomials test');
      expect(p.tests.single['status'], 'published');
    });

    testWidgets('no limit in the plan is a minute and a half a question', (t) async {
      final p = _s.seed('Polynomials test', questions: 4, plan: plan());
      await openPaper(t, p.id);
      await saveAndPost(t);
      expect(_s.testBodies.single['time_limit_min'], suggestedLimit(4));
      expect(_s.testBodies.single['shuffle'], true);
    });

    testWidgets('a paper with no plan is posted as it always was: open now, the usual limit, closing at the next 9 pm', (t) async {
      final p = _s.seed('Old paper');
      await openPaper(t, p.id);
      await saveAndPost(t);
      final b = _s.testBodies.single;
      expect(b.containsKey('opens_at'), isFalse);
      expect(b['time_limit_min'], suggestedLimit(4));
      expect(DateTime.parse(b['closes_at'] as String).toLocal().hour, 21);
    });

    testWidgets('a plan whose closing time has passed is not used, and the tutor is told', (t) async {
      final p = _s.seed('Late paper', plan: plan(limit: 45, opens: const Duration(days: -2), closes: const Duration(days: -1)));
      await openPaper(t, p.id);
      await _tap(t, find.text('Save 4 ready questions'));
      await _pump(t, 1200);
      expect(find.textContaining('The closing time you planned for this paper has passed'), findsOneWidget);
      await _tap(t, find.text('Post now'));
      await _until(t, () => _s.testBodies.isNotEmpty, seconds: 10);
      final b = _s.testBodies.single;
      expect(b['time_limit_min'], suggestedLimit(4), reason: 'the plan as a whole is left behind');
      expect(b.containsKey('opens_at'), isFalse);
      expect(DateTime.parse(b['closes_at'] as String).isAfter(DateTime.now().toUtc()), isTrue);
    });
  });

  // ---------------------------------------------------------------- the class list

  group('which class', () {
    final targets = [_maths, TestTarget.group(classLevel: 9, subjectId: 'sub-Sci', subjectName: 'Science', size: 9), _english];

    testWidgets('lists every class with who is in it, the first one chosen', (t) async {
      await _open(t, targets: targets);
      expect(find.text('Which group or course are the tests for?'), findsOneWidget);
      expect(find.text('MAKE TESTS · STEP 1 OF 4'), findsOneWidget);
      expect(find.text('10th Maths'), findsOneWidget);
      expect(find.text('9th Science'), findsOneWidget);
      expect(find.text('Spoken English, Batch 1'), findsOneWidget);
      expect(find.text('12 students · group'), findsOneWidget);
      expect(find.text('14 people · course'), findsOneWidget);
      expect(find.text('Every paper you add becomes a test for this group or course.'), findsOneWidget);
      await _tap(t, find.text('Next'));
      expect(find.text('10TH MATHS · STEP 2 OF 4'), findsOneWidget);
    });

    testWidgets('the tutor\'s choice is the class the papers are made for', (t) async {
      await _open(t, targets: targets, sources: FakeSources(pdfs: [fakePdf('Reading.pdf', 1)]));
      await _tap(t, find.text('Spoken English, Batch 1'));
      await _tap(t, find.text('Next'));
      await _addFive(t);
      await _tap(t, find.text('Next: choose the days'));
      await _tap(t, find.text('Read the paper with AI'));
      await _until(t, () => _s.sent.length == 1);
      expect(_s.sent.single['course_id'], 'c-1');
    });

    testWidgets('Back from the papers returns to the list, then out', (t) async {
      await _open(t, targets: targets);
      await _tap(t, find.text('Next'));
      await _tap(t, find.byIcon(Ph.arrowLeft));
      expect(find.text('Which group or course are the tests for?'), findsOneWidget);
      await _tap(t, find.byIcon(Ph.arrowLeft));
      expect(find.text('open make'), findsOneWidget);
    });

    testWidgets('no paper: AI writes the test, and the chat page opens for the chosen group', (t) async {
      await _open(t, targets: targets);
      await _tap(t, find.text('Next'));
      await _tap(t, find.text('No paper? Let AI write a test'));
      expect(_at, '/t/groups/10/sub-Maths/chat?name=Maths');
    });
  });
}
