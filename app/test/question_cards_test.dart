// What the tutor sees and does on the check list of a paper whose pages AI read with pictures: a misprinted question shown beside
// its picture from the paper, a figure cut out of its page by itself (and cut again, or taken off), a question that ran over the page
// edge joined into one (and taken apart again), and one that could not be joined, marked "Cut off". The review screen is the real
// one, against a stub server that remembers what it was told (test/support/page_images.dart makes the pages).
//   flutter test test/question_cards_test.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/page_pictures.dart';
import 'package:core_academy/features/teacher/papers_screens.dart';
import 'package:core_academy/ui/kit.dart';
import 'package:core_academy/ui/option_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/page_images.dart';

const _box1 = [0.1, 0.8, 0.9, 0.95];
const _box2 = [0.1, 0.05, 0.9, 0.2];

Map<String, dynamic> _draft(
  String id, {
  int page = 1,
  String n = '7',
  String text = 'A body of mass 2 kg moves at 4 m/s. Its momentum is',
  List<String> options = const ['2', '4', '8', '16'],
  int? correct,
  String? note,
  bool cutNext = false,
  bool cutPrev = false,
  List<Map<String, Object?>>? boxes,
  bool diagram = false,
  Map<String, Object?>? figureBox,
  String? imageKey,
  bool joined = false,
  Map<String, Object?>? joinedFrom,
  bool edited = false,
}) =>
    {
      'id': id, 'paper_id': 'p1', 'page_no': page, 'seq': 1, 'number_label': n, 'kind': 'mcq', 'status': 'draft', 'text': text, 'options': options,
      'correct_option': correct, 'answer_source': correct == null ? null : 'ai', 'ai_confidence': correct == null ? null : 0.98, 'ai_note': note,
      'ai_picks': null, 'ai_votes': null, 'proposed_option': null, 'answer_checked': true, 'needs_diagram': diagram, 'image_key': imageKey,
      'image_url': imageKey == null ? null : 'https://figs.test/$imageKey', 'chapter': null, 'chapter_id': null, 'ai_chapter_guess': null, 'edited': edited,
      'question_boxes': boxes, 'figure_box': figureBox, 'cont_next': cutNext, 'cont_prev': cutPrev, 'joined': joined, 'joined_from': joinedFrom,
    };

List<Map<String, Object?>> _at(int page, List<double> box) => [
      {'page': page, 'box': box},
    ];

/// The server's side of one paper, remembered between calls.
class _Server {
  _Server(this.drafts, this.pages);

  final List<Map<String, dynamic>> drafts;
  final List<Map<String, dynamic>> pages;

  final calls = <String>[];
  final patches = <Map<String, dynamic>>[];
  final uploads = <Map<String, dynamic>>[];
  final putBodies = <Uint8List>[];

  /// Make the next upload fail, as the server does when it is busy.
  bool uploadFails = false;
  int _n = 0;

  http.Response _ok(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    final call = '${r.method} ${r.url.path}';
    calls.add(call);
    if (call == 'GET /teacher/papers/p1') {
      return _ok({
        'paper': {
          'id': 'p1', 'class_level': 9, 'exam_name': 'Physics, unit test', 'category': 'Worksheet', 'subject': 'Physics', 'subject_id': 'sub-0', 'chapter': null,
          'chapter_id': null, 'course_id': null, 'ai_details': {'ok': true}, 'page_count': pages.length, 'missing': <String>[],
        },
        'pages': pages,
        'drafts': jsonDecode(jsonEncode(drafts)),
        'chapters': <Object?>[],
        'questions': <Object?>[],
        'tests': <Object?>[],
      });
    }
    if (call == 'POST /teacher/uploads') {
      uploads.add(jsonDecode(r.body) as Map<String, dynamic>);
      if (uploadFails) return _ok({'error': {'code': 'busy', 'message': 'The server is busy. Try again in a moment.'}}, 503);
      final n = ++_n;
      return _ok({'put_url': 'https://put.test/up/$n', 'key': 'figs/cut-$n.png'});
    }
    if (call.startsWith('PUT /up/')) {
      putBodies.add(r.bodyBytes);
      return http.Response('', 200);
    }
    if (r.method == 'PATCH' && r.url.path.startsWith('/teacher/drafts/')) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      patches.add({'id': r.url.pathSegments.last, ...body});
      final d = drafts.firstWhere((x) => x['id'] == r.url.pathSegments.last);
      for (final e in body.entries) {
        d[e.key] = e.value;
      }
      if (body.containsKey('image_key')) d['image_url'] = body['image_key'] == null ? null : 'https://figs.test/${body['image_key']}';
      if (body.containsKey('text') || body.containsKey('options')) d['edited'] = true;
      return _ok({'draft': d});
    }
    if (r.method == 'POST' && r.url.path.endsWith('/unjoin')) {
      final id = r.url.pathSegments[2];
      final i = drafts.indexWhere((x) => x['id'] == id);
      final d = drafts[i];
      final snap = d['joined_from'] as Map<String, dynamic>;
      final before = snap['before'] as Map<String, dynamic>;
      final part = snap['part'] as Map<String, dynamic>;
      final boxes = (d['question_boxes'] as List).cast<Map<String, Object?>>();
      d
        ..['options'] = before['options']
        ..['joined'] = false
        ..['joined_from'] = null
        ..['cont_next'] = true
        ..['ai_note'] = 'unclear'
        ..['correct_option'] = null
        ..['question_boxes'] = [boxes.first];
      drafts.insert(
        i + 1,
        _draft('${id}b', page: part['page_no'] as int, n: '', text: '${part['text']}', options: (part['options'] as List).cast<String>(), cutPrev: true, note: 'unclear', boxes: [boxes.last]),
      );
      return _ok({'drafts': drafts});
    }
    if (call == 'POST /teacher/papers/p1/answers') return _ok({'from_key': 0, 'by_ai': 0, 'tried': 0, 'left': 0, 'second': 0});
    if (call == 'POST /teacher/papers/p1/second-opinion') return _ok({'by_ai': 0, 'tried': 0, 'asked': 0, 'left': 0});
    return _ok({'error': {'code': 'not_found', 'message': 'No stub for $call'}}, 404);
  }
}

late _Server _s;
late FakePages _fake;

/// Two pages: page 1 has a red block where a figure is printed, page 2 a blue block at its top.
Future<void> _setUp(WidgetTester t, List<Map<String, dynamic>> drafts, {bool warm = true, Set<int> noPicture = const {}}) async {
  final pages = <int, Uint8List>{
    1: (await t.runAsync(() => pagePng(blocks: [(box: _box1, color: red)])))!,
    2: (await t.runAsync(() => pagePng(blocks: [(box: _box2, color: blue)])))!,
  };
  _fake = FakePages(pages);
  if (warm) await t.runAsync(_fake.warm);
  _s = _Server(drafts, _fake.rows(without: noPicture));
  // Where the cut figures, and the pages themselves, will be found when a screen shows them by their address.
  await cacheNetworkImage(t, 'https://figs.test/figs/cut-1.png', pages[1]!);
  await cacheNetworkImage(t, 'https://figs.test/figs/cut-2.png', pages[1]!);
  for (final n in pages.keys) {
    await cacheNetworkImage(t, _fake.url(n), pages[n]!);
  }
}

Future<void> _open(WidgetTester t, {PaperPictures? pictures, int rounds = 6}) async {
  t.view.physicalSize = const Size(1200, 7000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: PaperReviewScreen(id: 'p1', pictures: pictures ?? _fake.pictures)));
  await settle(t, rounds: rounds);
}

Future<void> _close(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(milliseconds: 100));
}

/// The card with this kicker ("Q 7 · page 1").
Finder _card(String kicker) => find.ancestor(of: find.text(kicker.toUpperCase()), matching: find.byType(Surface)).first;

Finder _in(Finder card, String text) => find.descendant(of: card, matching: find.text(text));

Finder _inRich(Finder card, String text) => find.descendant(of: card, matching: find.textContaining(text, findRichText: true));

int _tab(WidgetTester t, String label) => t.widget<SegChip>(find.widgetWithText(SegChip, label)).count!;

Future<void> _tapText(WidgetTester t, Finder f, {int rounds = 10}) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await settle(t, rounds: rounds);
}

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

  tearDown(forgetNetworkImages);

  group('a misprinted question', () {
    List<Map<String, dynamic>> misprint() => [
          _draft('m1', text: 'A body of mass ■ kg moves at 4 m/s. Its momentum is 20 kg m/s, so the mass is', options: ['■', '4', '5', '6'], note: 'unclear', boxes: _at(1, _box1)),
        ];

    testWidgets('shows its picture from the paper above what AI typed, with the box marked', (t) async {
      await _setUp(t, misprint());
      await _open(t);
      final card = _card('Q 7 · page 1');
      expect(_in(card, 'Misprinted'), findsOneWidget);
      expect(find.descendant(of: card, matching: find.byType(FromYourPaper)), findsOneWidget);
      expect(_in(card, 'FROM YOUR PAPER'), findsOneWidget);
      expect(_in(card, 'What AI typed'), findsOneWidget);
      expect(_inRich(card, 'A body of mass'), findsOneWidget);
      expect(find.descendant(of: card, matching: find.byKey(const ValueKey('unreadable box'))), findsNWidgets(2), reason: 'a box in the words and one in the first option');
      expect(_inRich(card, '■'), findsNothing, reason: 'drawn, not typed');
      expect(_inRich(card, 'Part of this question printed as boxes, so AI could not type it. Check it against the picture.'), findsOneWidget);
      expect(_in(card, 'Fix it'), findsOneWidget);
      expect(_in(card, 'Skip'), findsOneWidget);
      await _close(t);
    });

    testWidgets('with no picture of its page it says "the page", and offers nothing to look at', (t) async {
      await _setUp(t, misprint(), noPicture: {1});
      await _open(t, pictures: PaperPictures(fetch: (_) async => null));
      final card = _card('Q 7 · page 1');
      expect(find.descendant(of: card, matching: find.byType(FromYourPaper)), findsNothing);
      expect(_inRich(card, 'Check it against the page.'), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('See page')), findsNothing);
      expect(_in(card, 'Fix it'), findsOneWidget, reason: 'it can still be fixed');
      await _close(t);
    });

    testWidgets('with the page but not the question\'s box, a link opens the page', (t) async {
      await _setUp(t, [_draft('m1', text: 'Part of this is ■', note: 'unclear')]);
      await _open(t);
      final card = _card('Q 7 · page 1');
      expect(find.descendant(of: card, matching: find.byType(FromYourPaper)), findsNothing);
      expect(_in(card, 'See page 1'), findsOneWidget);
      await _tapText(t, _in(card, 'See page 1'));
      expect(find.byType(WholePageScreen), findsOneWidget);
      expect(find.text('Page 1'), findsOneWidget);
      await _close(t);
    });

    testWidgets('"Fix it" opens the editor with the picture on top, and what is saved goes to the server', (t) async {
      await _setUp(t, misprint());
      await _open(t);
      await _tapText(t, _in(_card('Q 7 · page 1'), 'Fix it'));
      expect(find.text('Fix question'), findsOneWidget);
      final editor = find.byType(DraftEditor);
      expect(find.descendant(of: editor, matching: find.byType(FromYourPaper)), findsOneWidget);
      final fields = find.descendant(of: editor, matching: find.byType(EditableText));
      await t.enterText(fields.first, 'A body of mass 5 kg moves at 4 m/s. Its momentum is 20 kg m/s, so the mass is');
      await t.enterText(fields.at(1), '5');
      await t.pump();
      await _tapText(t, find.text('Save question'));
      expect(_s.patches, hasLength(1));
      final body = _s.patches.single;
      expect(body['id'], 'm1');
      expect(body['text'], startsWith('A body of mass 5 kg'));
      expect((body['options'] as List).first, '5');
      expect(body['kind'], 'mcq');
      expect(body.containsKey('correct_option'), isFalse, reason: 'she did not mark an answer');
      await settle(t, rounds: 6); // the editor slides away
      expect(find.text('Fix question'), findsNothing, reason: 'back on the list');
      await _close(t);
    });

    testWidgets('"Skip" asks first, and skips only when she says so', (t) async {
      await _setUp(t, misprint());
      await _open(t);
      await _tapText(t, _in(_card('Q 7 · page 1'), 'Skip'));
      expect(find.text('Skip this question?'), findsOneWidget);
      await _tapText(t, find.text('Cancel'));
      expect(_s.patches, isEmpty);
      await _tapText(t, _in(_card('Q 7 · page 1'), 'Skip'));
      await _tapText(t, find.widgetWithText(SecondaryButton, 'Skip it'));
      expect(_s.patches, [
        {'id': 'm1', 'status': 'discarded'},
      ]);
      await _close(t);
    });

    testWidgets('formulas AI typed with dollar signs are shown as plain symbols', (t) async {
      await _setUp(t, [_draft('m1', text: r'If $x^2 = 9$ then $x$ is', options: [r'$3$', r'$-3$', r'$\pm 3$', r'$9$'], note: 'unclear', boxes: _at(1, _box1))]);
      await _open(t);
      final card = _card('Q 7 · page 1');
      expect(_inRich(card, 'If x² = 9 then x is'), findsOneWidget);
      expect(_inRich(card, '± 3'), findsOneWidget);
      expect(_inRich(card, r'$'), findsNothing, reason: 'no dollar signs on the card');
      await _close(t);
    });
  });

  group('a question cut off at the page edge', () {
    List<Map<String, dynamic>> pair() => [
          _draft('a', n: '12', text: 'A car goes 60 km in the first hour and', options: ['2'], cutNext: true, note: 'unclear', boxes: _at(1, _box1)),
          _draft('b', page: 2, n: '', text: 'then 40 km in the next hour. The average speed is', options: ['40', '50', '60', '100'], cutPrev: true, note: 'unclear', boxes: _at(2, _box2)),
        ];

    testWidgets('each half says it was cut off, and why, with its picture', (t) async {
      await _setUp(t, pair());
      await _open(t);
      expect(_tab(t, 'Needs you'), 2);
      final first = _card('Q 12 · page 1');
      expect(_in(first, 'Cut off'), findsOneWidget);
      expect(_inRich(first, 'This question runs over the page, and the rest of it was not found. Check it against the picture.'), findsOneWidget);
      expect(find.descendant(of: first, matching: find.byType(FromYourPaper)), findsOneWidget);
      expect(_in(first, 'Fix it'), findsOneWidget);
      expect(_in(first, 'Skip'), findsOneWidget);
      final second = _card('Q · page 2');
      expect(_in(second, 'Cut off'), findsOneWidget);
      expect(_inRich(second, 'This looks like the rest of a question from the page before, and that question was not found. Check it against the picture.'), findsOneWidget);
      await _close(t);
    });

    testWidgets('a cut-off question is never offered "Use A", and has no answer to mark', (t) async {
      await _setUp(t, pair());
      await _open(t);
      expect(find.textContaining('Use A'), findsNothing);
      expect(find.byType(OptionMark), findsNothing, reason: 'the options are shown as typed, not as a list to mark');
      await _close(t);
    });
  });

  group('a question joined from two pages', () {
    Map<String, dynamic> joined({bool edited = false}) => _draft(
          'j1',
          text: 'The sum of the first n terms of an AP is 3n² + 5n. Its 10th term is',
          options: ['62', '65', '59', '68'],
          correct: 1,
          joined: true,
          edited: edited,
          boxes: [
            {'page': 1, 'box': _box1},
            {'page': 2, 'box': _box2},
          ],
          joinedFrom: {
            'before': {'options': ['62', '65'], 'text': 'The sum of the first n terms of an AP is 3n² + 5n. Its 10th term is'},
            'part': {'page_no': 2, 'text': '', 'options': ['59', '68']},
          },
        );

    Future<void> openReady(WidgetTester t, {bool edited = false}) async {
      await _setUp(t, [joined(edited: edited)]);
      await _open(t);
      await _tapText(t, find.widgetWithText(SegChip, 'Ready'));
      // The ready questions are one line each; this one opens when it is tapped.
      await _tapText(t, find.textContaining('The sum of the first n terms', findRichText: true));
    }

    testWidgets('is marked in the list of ready questions', (t) async {
      await _setUp(t, [joined(), _draft('r2', n: '8', text: 'The next question is', correct: 0)]);
      await _open(t);
      await _tapText(t, find.widgetWithText(SegChip, 'Ready'));
      expect(find.text('Pages 1 and 2 · Joined'), findsOneWidget);
      expect(find.text('Page 1'), findsOneWidget, reason: 'the other ready question is just on its page');
      await _close(t);
    });

    testWidgets('says it was one question, and which options came from the second page', (t) async {
      await openReady(t);
      final card = _card('Q 7 · pages 1 and 2');
      expect(_in(card, 'Joined'), findsOneWidget);
      expect(_inRich(card, 'One question, not two.'), findsOneWidget);
      expect(_inRich(card, 'It ran over the page, so AI joined the two parts. Options C and D were on page 2.'), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('page 2')), findsNWidgets(2), reason: 'a small label beside C and D');
      expect(_in(card, 'Undo the join'), findsOneWidget);
      await _close(t);
    });

    testWidgets('"Undo the join" gives the two parts back, each cut off', (t) async {
      await openReady(t);
      await _tapText(t, _in(_card('Q 7 · pages 1 and 2'), 'Undo the join'));
      expect(_s.calls, contains('POST /teacher/drafts/j1/unjoin'));
      expect(_tab(t, 'Ready'), 0);
      expect(_tab(t, 'Needs you'), 2);
      await _tapText(t, find.widgetWithText(SegChip, 'Needs you'));
      expect(_in(_card('Q 7 · page 1'), 'Cut off'), findsOneWidget);
      expect(_in(_card('Q · page 2'), 'Cut off'), findsOneWidget);
      await _close(t);
    });

    testWidgets('a joined question she changed asks before it is taken apart', (t) async {
      await openReady(t, edited: true);
      await _tapText(t, _in(_card('Q 7 · pages 1 and 2'), 'Undo the join'));
      expect(find.text('Undo the join?'), findsOneWidget);
      expect(find.textContaining('You changed this question'), findsOneWidget);
      await _tapText(t, find.text('Cancel'));
      expect(_s.calls, isNot(contains('POST /teacher/drafts/j1/unjoin')));
      await _tapText(t, _in(_card('Q 7 · pages 1 and 2'), 'Undo the join'));
      await _tapText(t, find.widgetWithText(PrimaryButton, 'Undo the join'));
      expect(_s.calls, contains('POST /teacher/drafts/j1/unjoin'));
      await _close(t);
    });

    testWidgets('the editor names both pages and shows both parts', (t) async {
      await openReady(t);
      await _tapText(t, find.descendant(of: _card('Q 7 · pages 1 and 2'), matching: find.byIcon(Ph.pencilSimple)));
      expect(find.text('PAGES 1 AND 2 · QUESTION 7'), findsOneWidget);
      expect(find.descendant(of: find.byType(DraftEditor), matching: find.byType(PagePiece)), findsNWidgets(2));
      await _close(t);
    });
  });

  group('a figure cut out of its page', () {
    List<Map<String, dynamic>> figure() => [
          _draft('f1', n: '11', text: 'In the figure, DE is parallel to BC. Find EC.', diagram: true, figureBox: {'page': 1, 'box': _box1}, boxes: _at(1, [0.1, 0.7, 0.9, 0.97])),
        ];

    testWidgets('is cut by itself, uploaded, and put on its question', (t) async {
      await _setUp(t, figure());
      await _open(t, rounds: 16);
      expect(_s.uploads, [
        {'size': _s.putBodies.single.length, 'type': 'png'},
      ]);
      final png = _s.putBodies.single;
      final size = (await t.runAsync(() => sizeOfPng(png)))!;
      expect(size.width, closeTo(492, 2), reason: 'the box, 0.01 wider each side');
      expect(size.height, closeTo(132, 2));
      expect((await t.runAsync(() => pixelOfPng(png, 0.5, 0.5)))!, red, reason: 'it is the red block of the page');
      expect(_s.patches, [
        {'id': 'f1', 'image_key': 'figs/cut-1.png'},
      ]);
      final card = _card('Q 11 · page 1');
      expect(_in(card, 'FROM PAGE 1'), findsOneWidget);
      expect(_in(card, 'Cut again'), findsOneWidget);
      expect(_in(card, 'Remove'), findsOneWidget);
      expect(_in(card, 'Needs a figure'), findsNothing);
      await _close(t);
    });

    testWidgets('"Cut again" opens the page with the box where it was, and cuts what she gives back', (t) async {
      await _setUp(t, figure());
      await _open(t, rounds: 16);
      await _tapText(t, _in(_card('Q 11 · page 1'), 'Cut again'));
      expect(find.text('Cut the diagram'), findsOneWidget);
      await _tapText(t, find.text('Use this cut'), rounds: 16);
      expect(find.text('Cut the diagram'), findsNothing);
      expect(_s.uploads, hasLength(2));
      expect(_s.patches, hasLength(2));
      final second = _s.patches.last;
      expect(second['image_key'], 'figs/cut-2.png');
      expect(second['figure_box'], {'page': 1, 'box': _box1}, reason: 'where she cut, to start from next time');
      final size = (await t.runAsync(() => sizeOfPng(_s.putBodies.last)))!;
      expect(size.width, closeTo(480, 2), reason: 'her cut has no margin of its own');
      expect(size.height, closeTo(120, 2));
      await _close(t);
    });

    testWidgets('"Remove" takes it off, and the question asks for a figure again', (t) async {
      await _setUp(t, figure());
      await _open(t, rounds: 16);
      await _tapText(t, _in(_card('Q 11 · page 1'), 'Remove'));
      expect(_s.patches.last, {'id': 'f1', 'image_key': null});
      final card = _card('Q 11 · page 1');
      expect(_in(card, 'Needs a figure'), findsOneWidget);
      expect(_in(card, 'Add the figure'), findsOneWidget);
      expect(_s.uploads, hasLength(1), reason: 'it is not cut again by itself');
      await _close(t);
    });

    testWidgets('a page that will not load leaves the question asking for its figure', (t) async {
      await _setUp(t, figure(), warm: false);
      _fake.broken.add(_fake.url(1));
      await _open(t, rounds: 10);
      expect(_s.uploads, isEmpty);
      expect(_s.patches, isEmpty);
      final card = _card('Q 11 · page 1');
      expect(_in(card, 'Needs a figure'), findsOneWidget);
      expect(_in(card, 'Add the figure'), findsOneWidget);
      await _close(t);
    });

    testWidgets('an upload that fails leaves the question asking for its figure', (t) async {
      await _setUp(t, figure());
      _s.uploadFails = true;
      await _open(t, rounds: 16);
      expect(_s.putBodies, isEmpty);
      expect(_s.patches, isEmpty);
      expect(_in(_card('Q 11 · page 1'), 'Needs a figure'), findsOneWidget);
      await _close(t);
    });

    testWidgets('a question whose figure was not located is not cut by itself', (t) async {
      await _setUp(t, [_draft('f2', n: '5', text: 'In the figure, find x.', diagram: true)]);
      await _open(t, rounds: 10);
      expect(_s.uploads, isEmpty);
      final card = _card('Q 5 · page 1');
      expect(_in(card, 'Needs a figure'), findsOneWidget);
      expect(_inRich(card, 'AI cannot see figures. Cut the diagram from the page or add a photo of it, or skip the question.'), findsOneWidget);
      await _close(t);
    });

    testWidgets('"Add the figure" offers cutting it from the page, or a photo', (t) async {
      await _setUp(t, [_draft('f2', n: '5', text: 'In the figure, find x.', diagram: true)]);
      await _open(t);
      await _tapText(t, _in(_card('Q 5 · page 1'), 'Add the figure'));
      expect(find.text('Add the diagram'), findsOneWidget);
      expect(find.text('Cut it from the page'), findsOneWidget);
      expect(find.text('Take a photo'), findsOneWidget);
      expect(find.text('Choose from gallery'), findsOneWidget);
      await _close(t);
    });

    testWidgets('without a picture of the page only the photo choices are offered', (t) async {
      await _setUp(t, [_draft('f2', n: '5', text: 'In the figure, find x.', diagram: true)], noPicture: {1});
      await _open(t, pictures: PaperPictures(fetch: (_) async => null));
      await _tapText(t, _in(_card('Q 5 · page 1'), 'Add the figure'));
      expect(find.text('Add the diagram'), findsOneWidget);
      expect(find.text('Cut it from the page'), findsNothing);
      expect(find.text('Take a photo'), findsOneWidget);
      await _close(t);
    });
  });
}
