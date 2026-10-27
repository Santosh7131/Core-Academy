// A paper AI wrote keeps the number of questions the tutor asked for: a question the checks cannot settle is left out and a
// new one takes its place, a few rounds over, and nothing the tutor has touched is replaced. The review screen is the real
// one, against a stub server that answers the way the API does (a batch to a call, `left`, `replaceable` on the paper).
//   flutter test test/replace_loop_test.dart
import 'dart:async';
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/papers_screens.dart';
import 'package:core_academy/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _replace = 'POST /teacher/papers/p1/replace';
const _answers = 'POST /teacher/papers/p1/answers';

Map<String, dynamic> _draft(int n, String text, {int? correct, bool checked = true, String? note, bool edited = false, int? page, int? seq}) => {
      'id': 'd$n', 'paper_id': 'p1', 'page_no': page ?? 1, 'seq': seq ?? n, 'number_label': '${seq ?? n}', 'kind': 'mcq', 'status': 'draft', 'text': text,
      'options': ['2', '3', '4', '5'], 'correct_option': correct, 'answer_source': correct == null ? null : 'ai', 'ai_confidence': correct == null ? null : 0.98,
      'ai_note': note, 'ai_picks': null, 'ai_votes': null, 'proposed_option': null, 'answer_checked': checked, 'needs_diagram': false, 'image_key': null,
      'image_url': null, 'chapter': null, 'chapter_id': null, 'ai_chapter_guess': null, 'edited': edited,
    };

/// What the server counts as a question to replace: the checks are finished with it and could not settle it, and nobody has touched it.
bool _unsettled(Map<String, dynamic> d) =>
    d['status'] == 'draft' &&
    d['kind'] == 'mcq' &&
    d['edited'] != true &&
    d['answer_checked'] == true &&
    d['ai_votes'] == null &&
    (d['correct_option'] == null || d['ai_note'] == 'writer_differs');

/// The server's side of one paper that AI wrote, remembered between calls.
class _Writer {
  _Writer(this.drafts, {this.offers = true});

  final List<Map<String, dynamic>> drafts;

  /// The paper's `replaceable`: true while it can have questions replaced, false at the server's cap, and absent (null) from a
  /// server that has no replacing.
  bool? offers;

  /// Whether the checks find an answer for a new question. When they do not, the new question is unsettled too.
  bool settles = true;

  /// How many questions one /replace call takes, as one reply of the writer does.
  final int batch = 2;

  /// What /replace does besides replacing: answers 404 (a server from before replacing), or gives nothing back (a busy writer).
  bool missing = false;
  bool silent = false;

  /// The next /replace waits for this, so the screen can be looked at while the writer is at work.
  Completer<void>? gate;

  final calls = <String>[];
  var _next = 100;

  int count(String call) => calls.where((c) => c == call).length;
  List<Map<String, dynamic>> get live => drafts.where((d) => d['status'] != 'discarded').toList();

  http.Response _ok(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    final call = '${r.method} ${r.url.path}';
    calls.add(call);
    switch (call) {
      case 'GET /teacher/papers/p1':
        return _ok({
          'paper': {
            'id': 'p1', 'class_level': 9, 'exam_name': 'Algebra, one day', 'category': 'Made with AI', 'subject': 'Maths', 'subject_id': 'sub-0',
            'chapter': null, 'chapter_id': null, 'course_id': null, 'ai_details': {'ok': true}, 'page_count': 0, 'missing': <String>[],
            if (offers != null) 'replaceable': offers,
          },
          'pages': <Object?>[],
          'drafts': drafts,
          'chapters': <Object?>[],
          'questions': <Object?>[],
          'tests': <Object?>[],
        });
      case _answers:
        final todo = drafts.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] == null && d['answer_checked'] != true).toList();
        for (final d in todo) {
          d['answer_checked'] = true;
          if (settles) {
            d['correct_option'] = 1;
            d['answer_source'] = 'ai';
            d['ai_confidence'] = 0.97;
          }
        }
        return _ok({'from_key': 0, 'by_ai': settles ? todo.length : 0, 'tried': todo.length, 'left': 0, 'second': 0});
      case 'POST /teacher/papers/p1/second-opinion':
        return _ok({'by_ai': 0, 'tried': 0, 'asked': 0, 'left': 0});
      case _replace:
        final g = gate;
        if (g != null) {
          gate = null;
          await g.future;
        }
        if (missing) return _ok({'error': {'code': 'not_found', 'message': 'No such route'}}, 404);
        if (silent) return _ok({'replaced': 0, 'left': 0});
        final stuck = drafts.where(_unsettled).take(batch).toList();
        for (final d in stuck) {
          d['status'] = 'discarded';
          d['ai_note'] = 'replaced';
          drafts.add(_draft(_next++, 'A new question written for number ${d['number_label']}', page: d['page_no'] as int, seq: d['seq'] as int, checked: false));
        }
        return _ok({'replaced': stuck.length, 'left': drafts.where(_unsettled).length});
    }
    return _ok({'error': {'code': 'not_found', 'message': 'No stub for $call'}}, 404);
  }
}

late _Writer _w;

Future<void> _wait(WidgetTester t, [int ms = 600]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// The count on a tab of the review ("Skipped 3"), and whether it is the one showing.
int _tab(WidgetTester t, String label) => t.widget<SegChip>(find.widgetWithText(SegChip, label)).count!;
bool _showing(WidgetTester t, String label) => t.widget<SegChip>(find.widgetWithText(SegChip, label)).selected;

Future<void> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(1200, 6000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(const MaterialApp(home: PaperReviewScreen(id: 'p1')));
}

Future<void> _close(WidgetTester t) async => t.pumpWidget(const SizedBox());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient((r) => _w.handle(r)));
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
    session.tuitionName = 'Priya Maths Classes';
  });

  /// Five questions: two with their answers settled, and three the checks could not settle (no answer found, no answer found,
  /// and an answer against what the writer meant).
  setUp(() => _w = _Writer([
        _draft(1, 'What is 1 + 1?', correct: 0),
        _draft(2, 'What is 2 + 2?', correct: 2),
        _draft(3, 'What is 3 + 3?'),
        _draft(4, 'What is 4 + 4?', correct: 2, note: 'writer_differs'),
        _draft(5, 'What is 5 + 5?'),
      ]));

  testWidgets('questions the checks could not settle are replaced, and the new ones get their answers', (t) async {
    final gate = Completer<void>();
    _w.gate = gate;
    await _open(t);
    await _wait(t, 900);

    // The writer is at work: the tutor is told, the review is there to be used, and the first call is waiting.
    expect(find.text('AI was not sure about 3 questions, so it is writing new ones. You can carry on meanwhile.'), findsOneWidget);
    expect(_w.count(_replace), 1);
    expect(_tab(t, 'Needs you'), 2);
    expect(_tab(t, 'Ready'), 3);

    gate.complete();
    await _wait(t, 1200);

    // A call takes two questions, so the third needed a second call, and nothing was asked for again after that.
    expect(_w.count(_replace), 2);
    expect(find.textContaining('it is writing'), findsNothing, reason: 'the notice goes when the writer is done');
    expect(_w.live.length, 5, reason: 'the paper has the number of questions it was asked for');
    expect(_w.live.every((d) => d['correct_option'] != null), isTrue, reason: 'every new question went through the answer check');
    expect(_w.calls.lastIndexOf(_answers), greaterThan(_w.calls.lastIndexOf(_replace)), reason: 'the new questions were checked after they were written');
    expect(_tab(t, 'Needs you'), 0);
    expect(_tab(t, 'Ready'), 5);
    expect(_tab(t, 'Skipped'), 3);
    expect(_showing(t, 'Ready'), isTrue, reason: 'with nothing left for the tutor the list shows the ready questions, not an empty one');
    expect(find.text('AI replaced 3 questions it was not sure about with new ones. The paper still has 5 questions.'), findsOneWidget,
        reason: 'the three under Skipped are not three questions lost, and the screen says so');

    // The three that were left out are under Skipped and say why, and each can be brought back.
    await t.tap(find.widgetWithText(SegChip, 'Skipped'));
    await _wait(t);
    expect(find.text('Replaced'), findsNWidgets(3));
    expect(find.text('AI was not sure of the answer to this one, so a new question took its place. Bring it back if you want it anyway.'), findsNWidgets(3));
    await _close(t);
  });

  testWidgets('a single question says so in the singular', (t) async {
    _w = _Writer([_draft(1, 'What is 1 + 1?', correct: 0), _draft(2, 'What is 2 + 2?')]);
    final gate = Completer<void>();
    _w.gate = gate;
    await _open(t);
    await _wait(t, 900);
    expect(find.text('AI was not sure about 1 question, so it is writing a new one. You can carry on meanwhile.'), findsOneWidget);
    gate.complete();
    await _wait(t, 1200);
    expect(_w.count(_replace), 1);
    expect(find.textContaining('it is writing'), findsNothing);
    expect(find.text('AI replaced 1 question it was not sure about with a new one. The paper still has 2 questions.'), findsOneWidget);
    await _close(t);
  });

  testWidgets('a topic AI can never settle is given three rounds, and what is left stays with the tutor', (t) async {
    _w.settles = false;
    _w.drafts.removeWhere((d) => d['seq'] != 3);
    await _open(t);
    await _wait(t, 3000);

    expect(_w.count(_replace), 3, reason: 'one question a round, three rounds, then it stops asking');
    expect(_tab(t, 'Skipped'), 3);
    expect(_tab(t, 'Needs you'), 1, reason: 'the last new question is the tutor\'s to mark');
    expect(_showing(t, 'Needs you'), isTrue, reason: 'and the list stays where she has something to do');
    expect(find.text('AI replaced 3 questions it was not sure about with new ones. The paper still has 1 question.'), findsOneWidget, reason: 'the paper is not a question short');
    expect(find.text('Try again'), findsNothing, reason: 'not an error: the tutor is not told AI failed');
    await _close(t);
  });

  testWidgets('a server that does not say the paper can be replaced is left alone', (t) async {
    for (final offers in <bool?>[null, false]) {
      _w = _Writer([_draft(1, 'What is 1 + 1?', correct: 0), _draft(2, 'What is 2 + 2?')], offers: offers);
      await _open(t);
      await _wait(t, 900);
      expect(_w.count(_replace), 0, reason: 'replaceable: $offers');
      expect(_tab(t, 'Needs you'), 1);
      expect(find.textContaining('it is writing'), findsNothing);
      expect(find.textContaining('AI replaced'), findsNothing);
      await _close(t);
    }
  });

  testWidgets('a question the tutor has marked or reworded is never replaced', (t) async {
    _w = _Writer([_draft(1, 'What is 1 + 1?', correct: 0), _draft(2, 'What is 2 + 2?', edited: true), _draft(3, 'What is 3 + 3?', edited: true, correct: 1, note: 'writer_differs')]);
    await _open(t);
    await _wait(t, 900);
    expect(_w.count(_replace), 0);
    expect(_tab(t, 'Needs you'), 1);
    await _close(t);
  });

  testWidgets('a writer that gives nothing back, or a server with no such route, changes nothing and shows no error', (t) async {
    for (final (name, setUpWriter) in <(String, void Function(_Writer))>[('busy writer', (w) => w.silent = true), ('no such route', (w) => w.missing = true)]) {
      _w = _Writer([_draft(1, 'What is 1 + 1?', correct: 0), _draft(2, 'What is 2 + 2?')]);
      setUpWriter(_w);
      await _open(t);
      await _wait(t, 1500);
      expect(_w.count(_replace), 1, reason: '$name: one try, no loop');
      expect(_w.live.length, 2, reason: name);
      expect(_tab(t, 'Needs you'), 1, reason: '$name: the question stays with the tutor');
      expect(find.text('Try again'), findsNothing, reason: name);
      expect(find.textContaining('it is writing'), findsNothing, reason: '$name: the notice is gone');
      expect(find.textContaining('AI replaced'), findsNothing, reason: '$name: nothing was replaced, so nothing is claimed');
      await _close(t);
    }
  });
}
