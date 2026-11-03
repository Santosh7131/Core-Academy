// How hard a question is: the level every question carries (AI sets it, Medium when it cannot tell), where the tutor sees it and
// changes it, and how she narrows the questions for a test by it. The screens are the real ones, against a stub server that remembers
// what it was sent.
//   flutter test test/difficulty_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/papers_screens.dart' show DraftEditor;
import 'package:core_academy/features/teacher/questions_screens.dart' show QuestionEditor;
import 'package:core_academy/features/teacher/tests_screens.dart' show QuestionPicker;
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/difficulty.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _hint = 'AI guessed this from the question. Pick another level if you disagree.';

Map<String, dynamic> _q(String id, String text, {String? chapter, String? level, String? by, String source = 'tutor'}) =>
    {'id': id, 'text': text, 'chapter': chapter, 'difficulty': level, 'difficulty_by': by, 'source': source};

/// 10th Maths: eight questions of the tutor's (3 easy, 2 medium, 3 hard; one has no level at all, as every question did before levels
/// existed) and one from the ready-made library, which the picker never offers.
List<Map<String, dynamic>> _bank() => [
      _q('q1', 'Value of sin 30', chapter: 'Trigonometry', level: 'easy', by: 'ai'),
      _q('q2', 'Value of tan 45', chapter: 'Trigonometry', level: 'easy', by: 'tutor'),
      _q('q3', 'Prove an identity', chapter: 'Trigonometry', level: 'hard', by: 'ai'),
      _q('q4', 'HCF of 12 and 18', chapter: 'Real numbers', level: 'easy', by: 'ai'),
      _q('q5', 'Euclid division lemma', chapter: 'Real numbers', level: 'medium', by: 'ai'),
      _q('q6', 'Prove that root 2 is irrational', chapter: 'Real numbers', level: 'hard', by: 'ai'),
      _q('q7', 'Zeros of a polynomial'),
      _q('q8', 'Sum of the roots', level: 'hard', by: 'tutor'),
      _q('lib1', 'A ready-made question', level: 'hard', by: 'ai', source: 'library'),
    ];

/// The question the editor opens: AI rated it Hard.
Map<String, dynamic> _stored({String? level = 'hard', String? by = 'ai'}) => {
      'id': 'q-1', 'text': 'Find the zeros of x² − 5x + 6', 'options': ['2 and 3', '1 and 6', '−2 and −3', '5 and 6'], 'correct_option': 0,
      'solution': null, 'marks': 1, 'course_id': null, 'class_level': 10, 'subject_id': 'sub-Maths', 'chapter_id': null, 'image_key': null,
      'image_url': null, 'used_in': 0, 'difficulty': level, 'difficulty_by': by,
    };

/// The server's side: what it answers, and the last body it was sent on each call.
class _Server {
  List<Map<String, dynamic>> questions = _bank();
  Map<String, dynamic> stored = _stored();
  final bodies = <String, Map<String, dynamic>>{};

  http.Response _ok(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    final call = '${r.method} ${r.url.path}';
    if (r.body.isNotEmpty) bodies[call] = jsonDecode(r.body) as Map<String, dynamic>;
    switch (call) {
      case 'GET /teacher/questions':
        return _ok({'questions': questions});
      case 'GET /teacher/questions/q-1':
        return _ok({'question': stored});
      case 'PATCH /teacher/questions/q-1':
        return _ok({'ok': true, 'regraded': 0});
      case 'GET /teacher/subjects':
        return _ok({
          'subjects': [
            {'id': 'sub-Maths', 'name': 'Maths', 'is_default': true},
          ],
        });
      case 'GET /teacher/chapters':
        return _ok({'chapters': <Object?>[]});
    }
    return _ok({'error': {'code': 'not_found', 'message': 'No stub for $call'}}, 404);
  }
}

late _Server _s;

Future<void> _pump(WidgetTester t, [int ms = 600]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Taps, then lets the clock run long enough for a card or a screen to arrive or leave.
Future<void> _tap(WidgetTester t, Finder finder, [int ms = 600]) async {
  await t.ensureVisible(finder);
  await t.pump();
  await t.tap(finder);
  await _pump(t, ms);
}

void _phone(WidgetTester t, {double width = 411, double height = 2600}) {
  setResolvedDark(false);
  t.view.physicalSize = Size(width * 2.625, height * 2.625);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
}

/// What a screen opened with a push gave back.
class _Opened {
  Object? result;
  bool closed = false;
}

/// Opens [screen] on top of a first page and keeps what it gives back.
Future<_Opened> _push(WidgetTester t, Widget screen, {double width = 411, double scale = 1.0}) async {
  _phone(t, width: width);
  final o = _Opened();
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              o.result = await Navigator.of(context).push<Object>(MaterialPageRoute(builder: (_) => screen));
              o.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await _pump(t, 800);
  return o;
}

/// Opens the question editor (a saved question by default, a new one with [id] null) on the stub server.
Future<void> _openEditor(WidgetTester t, {String? id = 'q-1'}) async {
  _phone(t);
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (c, _) => Scaffold(body: Center(child: TextButton(onPressed: () => c.push<bool>('/edit'), child: const Text('open editor')))),
    ),
    GoRoute(path: '/edit', builder: (_, _) => QuestionEditor(id: id)),
  ]);
  await t.pumpWidget(MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router));
  await _pump(t, 200);
  await _tap(t, find.text('open editor'), 1200);
}

Future<void> _openPicker(WidgetTester t, {List<Map<String, dynamic>> selected = const [], double width = 411, double scale = 1.0}) async {
  await _push(t, QuestionPicker(classLevel: 10, subjectId: 'sub-Maths', subjectName: 'Maths', selected: selected), width: width, scale: scale);
}

/// The chip beside a question, read from the widget.
List<Difficulty> _chips(WidgetTester t) => [for (final c in t.widgetList<DifficultyChip>(find.byType(DifficultyChip))) c.difficulty];

/// The options of the card open on top, each with the figure beside it ('' when it has none). The card's widgets come last in the tree.
Map<String, String> _card(WidgetTester t, List<String> options) {
  final out = <String, String>{};
  for (final label in options) {
    final row = find.ancestor(of: find.text(label).last, matching: find.byType(Row)).first;
    final figures = [
      for (final x in t.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))) x.data ?? x.textSpan?.toPlainText() ?? '',
    ].where((s) => int.tryParse(s) != null);
    out[label] = figures.isEmpty ? '' : figures.first;
  }
  return out;
}

const _levels = ['All levels', 'Easy', 'Medium', 'Hard'];

/// Picks a level in the card for "Level" and waits for it to close.
Future<void> _filterTo(WidgetTester t, String level) async {
  await _tap(t, find.text('All levels'));
  await _tap(t, find.text(level).last);
}

/// The coloured ground of the chip: the AI colour while it is AI's guess, a plain one otherwise.
Color? _ground(WidgetTester t) => (t.widget<Container>(find.descendant(of: find.byType(DifficultyChip), matching: find.byType(Container)).first).decoration as BoxDecoration).color;

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

  group('reading a level', () {
    test('what the server sends is the level, and anything else is Medium', () {
      expect(difficultyOf('easy'), Difficulty.easy);
      expect(difficultyOf('medium'), Difficulty.medium);
      expect(difficultyOf('hard'), Difficulty.hard);
      expect(difficultyOf(' Hard '), Difficulty.hard, reason: 'spaces and capitals do not matter');
      expect(difficultyOf(null), Difficulty.medium, reason: 'a question from before levels');
      expect(difficultyOf('impossible'), Difficulty.medium);
      expect(difficultyOf(3), Difficulty.medium);
    });

    test('the levels are named for the tutor, easiest first, and the names are what the server stores', () {
      expect([for (final d in Difficulty.values) d.label], ['Easy', 'Medium', 'Hard']);
      expect([for (final d in Difficulty.values) d.name], ['easy', 'medium', 'hard']);
    });

    test('AI chose a level only when the server says so', () {
      expect(aiChose({'difficulty_by': 'ai'}), isTrue);
      expect(aiChose({'difficulty_by': 'tutor'}), isFalse);
      expect(aiChose({'difficulty_by': null}), isFalse, reason: 'a hand-typed question, or one from before levels');
      expect(aiChose({}), isFalse);
    });

    test('questions are counted by level, and one with no level counts as Medium', () {
      final q = _bank().where((x) => x['source'] != 'library').toList();
      expect(difficultyCounts(q), {Difficulty.easy: 3, Difficulty.medium: 2, Difficulty.hard: 3});
      expect(difficultyCounts(const []), {Difficulty.easy: 0, Difficulty.medium: 0, Difficulty.hard: 0});
    });

    test('the mix reads "6 easy · 9 medium · 5 hard" and leaves out a level that has none', () {
      Map<String, dynamic> at(String? l) => {'difficulty': l};
      expect(difficultyMix([for (var i = 0; i < 6; i++) at('easy'), for (var i = 0; i < 9; i++) at('medium'), for (var i = 0; i < 5; i++) at('hard')]), '6 easy · 9 medium · 5 hard');
      expect(difficultyMix([at('hard'), at('hard')]), '2 hard');
      expect(difficultyMix([at('easy'), at(null)]), '1 easy · 1 medium');
      expect(difficultyMix(const []), '');
    });
  });

  group('the chip and the field', () {
    Future<void> show(WidgetTester t, Widget w) async {
      _phone(t);
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: w))));
      await t.pump();
    }

    testWidgets('a chip says the level in words, with a bar more for each step up', (t) async {
      for (final d in Difficulty.values) {
        await show(t, DifficultyChip(d));
        expect(find.text(d.label), findsOneWidget);
      }
    });

    testWidgets('the chip is plain for the tutor\'s own choice and in the AI colour while it is AI\'s guess', (t) async {
      await show(t, const DifficultyChip(Difficulty.hard));
      expect(_ground(t), fill);
      await show(t, const DifficultyChip(Difficulty.hard, ai: true));
      expect(_ground(t), aiAccentSoft);
    });

    testWidgets('a screen reader hears who chose the level', (t) async {
      final handle = t.ensureSemantics();
      await show(t, const DifficultyChip(Difficulty.easy, ai: true));
      expect(find.bySemanticsLabel('Easy, chosen by AI'), findsOneWidget);
      await show(t, const DifficultyChip(Difficulty.easy));
      expect(find.bySemanticsLabel('Easy'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the field shows the level, and a tap opens the three to choose from', (t) async {
      Difficulty? picked;
      await show(t, DifficultyField(difficulty: Difficulty.medium, aiChose: false, onPicked: (d) => picked = d));
      expect(find.text('Medium'), findsOneWidget);
      expect(find.text(_hint), findsNothing);
      await _tap(t, find.text('Medium'));
      expect(find.text('How hard is it?'), findsOneWidget, reason: 'the card');
      expect([for (final l in ['Easy', 'Medium', 'Hard']) find.text(l).evaluate().length], [1, 2, 1], reason: 'Medium is in the field and in the card');
      await _tap(t, find.text('Hard'));
      expect(picked, Difficulty.hard);
    });

    testWidgets('choosing the level it already shows still counts as choosing: she agreed', (t) async {
      Difficulty? picked;
      await show(t, DifficultyField(difficulty: Difficulty.medium, aiChose: true, onPicked: (d) => picked = d));
      await _tap(t, find.text('Medium'));
      await _tap(t, find.text('Medium').last);
      expect(picked, Difficulty.medium);
    });

    testWidgets('closing the card without choosing says nothing', (t) async {
      Difficulty? picked;
      await show(t, DifficultyField(difficulty: Difficulty.easy, aiChose: false, onPicked: (d) => picked = d));
      await _tap(t, find.text('Easy'));
      await t.tapAt(const Offset(8, 8));
      await _pump(t);
      expect(picked, isNull);
      expect(find.text('How hard is it?'), findsNothing, reason: 'the card is gone');
    });

    testWidgets('while it is AI\'s guess a line says so, and tells her she can pick another', (t) async {
      await show(t, DifficultyField(difficulty: Difficulty.hard, aiChose: true, onPicked: (_) {}));
      expect(find.text(_hint), findsOneWidget);
    });
  });

  group('fixing a question from a paper', () {
    Map<String, dynamic> draft({String? level, String? by, bool mcq = true}) => {
          'id': 'd1', 'page_no': 1, 'number_label': '3', 'kind': mcq ? 'mcq' : 'other', 'text': 'Area of a circle of radius r is',
          'options': ['a', 'b', 'c', 'd'], 'difficulty': level, 'difficulty_by': by,
        };

    testWidgets('AI\'s level is shown as AI\'s, with the line that says so', (t) async {
      await _push(t, DraftEditor(draft: draft(level: 'hard', by: 'ai')));
      expect(find.text('How hard is it?'), findsOneWidget);
      expect(_chips(t), [Difficulty.hard]);
      expect(_ground(t), aiAccentSoft);
      expect(find.text(_hint), findsOneWidget);
    });

    testWidgets('a draft with no level shows Medium, and no line about AI', (t) async {
      await _push(t, DraftEditor(draft: draft()));
      expect(_chips(t), [Difficulty.medium]);
      expect(_ground(t), fill);
      expect(find.text(_hint), findsNothing);
    });

    testWidgets('saving without touching the level does not send one, so AI\'s stays AI\'s', (t) async {
      final o = await _push(t, DraftEditor(draft: draft(level: 'hard', by: 'ai')));
      await _tap(t, find.text('Save question'));
      expect((o.result as Map).containsKey('difficulty'), isFalse);
    });

    testWidgets('choosing another level sends it, and the line about AI goes', (t) async {
      final o = await _push(t, DraftEditor(draft: draft(level: 'hard', by: 'ai')));
      await _tap(t, find.text('Hard'));
      await _tap(t, find.text('Easy').last);
      expect(_chips(t), [Difficulty.easy]);
      expect(_ground(t), fill, reason: 'it is hers now');
      expect(find.text(_hint), findsNothing);
      await _tap(t, find.text('Save question'));
      expect((o.result as Map)['difficulty'], 'easy');
    });

    testWidgets('agreeing with AI sends its level, so it becomes hers', (t) async {
      final o = await _push(t, DraftEditor(draft: draft(level: 'medium', by: 'ai')));
      await _tap(t, find.text('Medium'));
      await _tap(t, find.text('Medium').last);
      expect(find.text(_hint), findsNothing);
      await _tap(t, find.text('Save question'));
      expect((o.result as Map)['difficulty'], 'medium');
    });

    testWidgets('a question that is not multiple choice has no level to choose', (t) async {
      await _push(t, DraftEditor(draft: draft(level: 'hard', by: 'ai')));
      await _tap(t, find.text('This is not a multiple choice question'));
      expect(find.text('How hard is it?'), findsNothing);
      expect(find.byType(DifficultyChip), findsNothing);
    });

    testWidgets('it sits below the options and above the way out', (t) async {
      await _push(t, DraftEditor(draft: draft(level: 'easy', by: 'ai')));
      final options = t.getTopLeft(find.text('Options. Tap the circle of the right answer.')).dy;
      final label = t.getTopLeft(find.text('How hard is it?')).dy;
      final out = t.getTopLeft(find.text('This is not a multiple choice question')).dy;
      expect(options, lessThan(label));
      expect(label, lessThan(out));
    });
  });

  group('the question editor', () {
    testWidgets('a question AI rated shows its level in the AI colour, with the line that says so', (t) async {
      await _openEditor(t);
      expect(find.text('Edit question'), findsOneWidget);
      expect(find.text('How hard is it?'), findsOneWidget);
      expect(_chips(t), [Difficulty.hard]);
      expect(_ground(t), aiAccentSoft);
      expect(find.text(_hint), findsOneWidget);
    });

    testWidgets('a question the tutor rated herself is plain', (t) async {
      _s.stored = _stored(level: 'easy', by: 'tutor');
      await _openEditor(t);
      expect(_chips(t), [Difficulty.easy]);
      expect(_ground(t), fill);
      expect(find.text(_hint), findsNothing);
    });

    testWidgets('a question from before levels shows Medium', (t) async {
      _s.stored = _stored(level: null, by: null);
      await _openEditor(t);
      expect(_chips(t), [Difficulty.medium]);
      expect(find.text(_hint), findsNothing);
    });

    testWidgets('saving without touching the level does not send one', (t) async {
      await _openEditor(t);
      await _tap(t, find.text('Save question'), 1000);
      final body = _s.bodies['PATCH /teacher/questions/q-1']!;
      expect(body.containsKey('difficulty'), isFalse);
      expect(body['text'], 'Find the zeros of x² − 5x + 6');
    });

    testWidgets('choosing another level sends it, and the AI colour goes', (t) async {
      await _openEditor(t);
      await _tap(t, find.text('Hard'));
      await _tap(t, find.text('Easy').last);
      expect(_chips(t), [Difficulty.easy]);
      expect(find.text(_hint), findsNothing);
      await _tap(t, find.text('Save question'), 1000);
      expect(_s.bodies['PATCH /teacher/questions/q-1']!['difficulty'], 'easy');
    });

    testWidgets('agreeing with AI sends its level too', (t) async {
      await _openEditor(t);
      await _tap(t, find.text('Hard'));
      await _tap(t, find.text('Hard').last);
      await _tap(t, find.text('Save question'), 1000);
      expect(_s.bodies['PATCH /teacher/questions/q-1']!['difficulty'], 'hard');
    });

    testWidgets('a new question starts at Medium, as the tutor\'s own, and she can change it', (t) async {
      await _openEditor(t, id: null);
      expect(find.text('New question'), findsWidgets);
      expect(_chips(t), [Difficulty.medium]);
      expect(_ground(t), fill);
      expect(find.text(_hint), findsNothing);
      await _tap(t, find.text('Medium'));
      await _tap(t, find.text('Hard').last);
      expect(_chips(t), [Difficulty.hard]);
    });
  });

  group('choosing questions for a test', () {
    testWidgets('every question shows its level, and one with none shows Medium', (t) async {
      await _openPicker(t);
      expect(find.text('Choose questions'), findsWidgets);
      expect(_chips(t), [
        Difficulty.easy, Difficulty.easy, Difficulty.hard, Difficulty.easy, Difficulty.medium, Difficulty.hard, Difficulty.medium, Difficulty.hard,
      ], reason: 'in the order the server sent them, without the ready-made question');
      expect(find.text('A ready-made question'), findsNothing);
    });

    testWidgets('the level is a filter of its own, beside the chapters, and starts on all of them', (t) async {
      await _openPicker(t);
      expect(find.text('All chapters'), findsOneWidget);
      expect(find.text('All levels'), findsOneWidget);
      expect(find.text('Value of sin 30'), findsOneWidget);
      expect(find.text('Sum of the roots'), findsOneWidget);
    });

    testWidgets('the card for it counts the questions at each level', (t) async {
      await _openPicker(t);
      await _tap(t, find.text('All levels'));
      expect(find.text('Level'), findsOneWidget);
      expect(_card(t, _levels), {'All levels': '', 'Easy': '3', 'Medium': '2', 'Hard': '3'});
    });

    testWidgets('choosing Hard lists only the hard questions, and the filter says so', (t) async {
      await _openPicker(t);
      await _filterTo(t, 'Hard');
      expect([for (final x in ['Prove an identity', 'Prove that root 2 is irrational', 'Sum of the roots']) find.text(x).evaluate().length], [1, 1, 1]);
      expect(find.text('Value of sin 30'), findsNothing);
      expect(find.text('Zeros of a polynomial'), findsNothing);
      expect(find.text('All levels'), findsNothing);
      expect(_chips(t), [Difficulty.hard, Difficulty.hard, Difficulty.hard]);
    });

    testWidgets('Medium takes in a question that was never given a level', (t) async {
      await _openPicker(t);
      await _filterTo(t, 'Medium');
      expect(find.text('Euclid division lemma'), findsOneWidget);
      expect(find.text('Zeros of a polynomial'), findsOneWidget);
      expect(_chips(t).length, 2);
    });

    testWidgets('the counts follow the chapter chosen first', (t) async {
      await _openPicker(t);
      await _tap(t, find.text('All chapters'));
      await _tap(t, find.text('Trigonometry').last);
      await _tap(t, find.text('All levels'));
      expect(_card(t, _levels), {'All levels': '', 'Easy': '2', 'Medium': '0', 'Hard': '1'});
    });

    testWidgets('chapter and level narrow the list together', (t) async {
      await _openPicker(t);
      await _tap(t, find.text('All chapters'));
      await _tap(t, find.text('Real numbers').last);
      await _filterTo(t, 'Hard');
      expect(find.text('Prove that root 2 is irrational'), findsOneWidget);
      expect(find.text('Prove an identity'), findsNothing, reason: 'hard, but in another chapter');
      expect(find.text('HCF of 12 and 18'), findsNothing, reason: 'in the chapter, but easy');
    });

    testWidgets('a level with nothing in it says so, and offers nothing to add', (t) async {
      await _openPicker(t);
      await _tap(t, find.text('All chapters'));
      await _tap(t, find.text('Trigonometry').last);
      await _filterTo(t, 'Medium');
      expect(find.text('No medium questions in this chapter'), findsOneWidget);
      expect(find.text('Choose another level or chapter to see more.'), findsOneWidget);
      expect(find.byType(DifficultyChip), findsNothing);
      expect(find.textContaining('Add all'), findsNothing);
    });

    testWidgets('going back to all levels brings every question back', (t) async {
      await _openPicker(t);
      await _filterTo(t, 'Easy');
      expect(_chips(t).length, 3);
      await _tap(t, find.text('Easy').first);
      await _tap(t, find.text('All levels').last);
      expect(_chips(t).length, 8);
    });

    testWidgets('"Add all" takes in what is shown, at that level', (t) async {
      await _openPicker(t);
      expect(find.textContaining('Add all'), findsNothing, reason: 'nothing narrowed yet');
      await _filterTo(t, 'Hard');
      await _tap(t, find.text('Add all 3 shown'));
      expect(find.text('Use 3 questions'), findsOneWidget);
      expect(find.text('3 hard'), findsOneWidget);
      expect(find.textContaining('Add all'), findsNothing, reason: 'all of them are in');
    });

    testWidgets('with only a chapter chosen "Add all" still says it is from the chapter', (t) async {
      await _openPicker(t);
      await _tap(t, find.text('All chapters'));
      await _tap(t, find.text('Real numbers').last);
      expect(find.text('Add all 3 from this chapter'), findsOneWidget);
    });

    testWidgets('under the button the mix of what is picked, as questions are added and taken out', (t) async {
      await _openPicker(t);
      expect(find.text('Choose questions'), findsNWidgets(2), reason: 'the title and the button, which waits');
      expect(find.textContaining(' easy'), findsNothing);
      await _tap(t, find.text('Value of sin 30'));
      expect(find.text('Use 1 question'), findsOneWidget);
      expect(find.text('1 easy'), findsOneWidget);
      await _tap(t, find.text('Prove an identity'));
      await _tap(t, find.text('Euclid division lemma'));
      expect(find.text('Use 3 questions'), findsOneWidget);
      expect(find.text('1 easy · 1 medium · 1 hard'), findsOneWidget);
      await _tap(t, find.text('Value of sin 30'));
      expect(find.text('1 medium · 1 hard'), findsOneWidget);
      await _tap(t, find.text('Prove an identity'));
      await _tap(t, find.text('Euclid division lemma'));
      expect(find.textContaining(' medium'), findsNothing, reason: 'nothing picked, no mix');
    });

    testWidgets('the mix counts what was already in the test, and what is picked at another level too', (t) async {
      final inTest = _bank().where((x) => x['id'] == 'q1').toList();
      await _openPicker(t, selected: inTest);
      expect(find.text('Use 1 question'), findsOneWidget);
      expect(find.text('1 easy'), findsOneWidget);
      await _filterTo(t, 'Hard');
      await _tap(t, find.text('Sum of the roots'));
      expect(find.text('1 easy · 1 hard'), findsOneWidget, reason: 'the easy one is out of sight, but still in the test');
    });

    testWidgets('"Use" gives the questions back with their levels', (t) async {
      final o = await _push(t, QuestionPicker(classLevel: 10, subjectId: 'sub-Maths', subjectName: 'Maths', selected: const []));
      await _tap(t, find.text('Prove an identity'));
      await _tap(t, find.text('Use 1 question'));
      final back = (o.result as List).cast<Map<String, dynamic>>();
      expect([for (final q in back) q['id']], ['q3']);
      expect(back.single['difficulty'], 'hard');
    });

    testWidgets('a subject with no questions has no level filter, and says there are none', (t) async {
      _s.questions = [];
      await _openPicker(t);
      expect(find.text('No 10th Maths questions'), findsOneWidget);
      expect(find.text('All levels'), findsNothing);
      expect(find.text('All chapters'), findsNothing);
    });

    testWidgets('at twice the text size on a small phone nothing overflows', (t) async {
      await _openPicker(t, width: 320, scale: 2.0);
      expect(t.takeException(), isNull);
      await _tap(t, find.text('All levels'));
      expect(t.takeException(), isNull);
      await _tap(t, find.text('Hard').last);
      expect(t.takeException(), isNull);
      await _tap(t, find.text('Add all 3 shown'));
      expect(t.takeException(), isNull);
    });
  });
}
