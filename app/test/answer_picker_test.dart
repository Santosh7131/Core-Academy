// The tutor's tap on an answer: on an option, or on "Use B" under a question AI could not settle. It marks the answer at once,
// tells the server, and stays marked whatever else the screen is doing (the paper loading again while AI works, a slow save, a
// failed one). The review screen is the real one, against a stub server that remembers what it was told.
//   flutter test test/answer_picker_test.dart
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

Map<String, dynamic> _draft(int n, String text, {int? correct, String? note, Map<String, int>? picks, Object? votes}) => {
      'id': 'd$n', 'paper_id': 'p1', 'page_no': 1, 'seq': n, 'number_label': '$n', 'kind': 'mcq', 'status': 'draft', 'text': text,
      'options': ['2', '3', '4', '5'], 'correct_option': correct, 'answer_source': correct == null ? null : 'ai', 'ai_confidence': correct == null ? null : 0.98,
      'ai_note': note, 'ai_picks': picks, 'ai_votes': votes, 'proposed_option': null, 'answer_checked': true, 'needs_diagram': false, 'image_key': null,
      'image_url': null, 'chapter': null, 'chapter_id': null, 'ai_chapter_guess': null, 'edited': false,
    };

class _Server {
  _Server(this.drafts);
  final List<Map<String, dynamic>> drafts;

  /// While set, the next GET of the paper takes its picture of the drafts now and answers when this completes.
  Completer<void>? getGate;

  /// While set, the next PATCH of a draft waits for this before the server applies it.
  Completer<void>? patchGate;

  /// Make the next PATCH fail, as the server does when it is busy or the line drops.
  bool failPatch = false;

  final patches = <Map<String, dynamic>>[];
  var gets = 0;

  http.Response _ok(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    final call = '${r.method} ${r.url.path}';
    if (call == 'GET /teacher/papers/p1') {
      gets++;
      final snapshot = jsonDecode(jsonEncode(drafts));
      final g = getGate;
      if (g != null) {
        getGate = null;
        await g.future;
      }
      return _ok({
        'paper': {
          'id': 'p1', 'class_level': 9, 'exam_name': 'Worksheet 1', 'category': 'Worksheet', 'subject': 'Maths', 'subject_id': 'sub-0', 'chapter': null,
          'chapter_id': null, 'course_id': null, 'ai_details': {'ok': true}, 'page_count': 1, 'missing': <String>[],
        },
        'pages': [
          {'page_no': 1, 'object_key': 'k', 'uploaded': true, 'ai_status': 'done', 'ai_error': null, 'read_at': '2026-10-27T10:00:00Z', 'answer_key': null},
        ],
        'drafts': snapshot,
        'chapters': <Object?>[],
        'questions': <Object?>[],
        'tests': <Object?>[],
      });
    }
    if (call.startsWith('PATCH /teacher/drafts/')) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      patches.add({'id': r.url.pathSegments.last, ...body});
      final g = patchGate;
      if (g != null) {
        patchGate = null;
        await g.future;
      }
      if (failPatch) {
        failPatch = false;
        return _ok({'error': {'code': 'ai_busy', 'message': 'The server is busy. Try again in a moment.'}}, 503);
      }
      final d = drafts.firstWhere((x) => x['id'] == r.url.pathSegments.last);
      d['correct_option'] = body['correct_option'];
      d['answer_source'] = 'teacher';
      d['ai_confidence'] = null;
      d['ai_note'] = null;
      d['ai_picks'] = null;
      d['ai_votes'] = null;
      return _ok({'draft': d});
    }
    if (call == 'POST /teacher/papers/p1/second-opinion') return _ok({'by_ai': 0, 'tried': 0, 'asked': 0, 'left': 0});
    return _ok({'error': {'code': 'not_found', 'message': 'No stub for $call'}}, 404);
  }
}

late _Server _s;

/// Four questions: one AI answered; one its checks split on (B or C); one it found nothing for; one waiting for a stronger model.
List<Map<String, dynamic>> _paper() => [
      _draft(1, 'What is 1 + 1?', correct: 0),
      _draft(2, 'What is 2 + 2?', note: 'disagree', picks: {'solver': 1, 'checker': 2}),
      _draft(3, 'What is 3 + 3?'),
      _draft(4, 'What is 4 + 4?', picks: {'solver': 0, 'checker': 3}, votes: {'tries': 0}),
    ];

Future<void> _wait(WidgetTester t, [int ms = 600]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

int _tab(WidgetTester t, String label) => t.widget<SegChip>(find.widgetWithText(SegChip, label)).count!;

Future<void> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(1200, 6000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(const MaterialApp(home: PaperReviewScreen(id: 'p1')));
  await _wait(t, 900);
}

/// The card of question [n] ("What is n + n?").
Finder _card(int n) => find.ancestor(of: find.text('What is $n + $n?', findRichText: true), matching: find.byType(Surface)).first;

/// Option [letter] of question [n].
Finder _option(int n, String letter) => find.descendant(of: _card(n), matching: find.bySemanticsLabel(RegExp('^Mark option $letter as right')));

/// What the tabs say: how many questions need the tutor and how many are ready. A question she marks leaves the first list for the second.
String _counts(WidgetTester t) => '${_tab(t, 'Needs you')} need you, ${_tab(t, 'Ready')} ready';

Finder _tag(int n, String text) => find.descendant(of: _card(n), matching: find.text(text));

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

  setUp(() => _s = _Server(_paper()));

  testWidgets('tapping an option marks it at once and tells the server', (t) async {
    final sem = t.ensureSemantics();
    await _open(t);
    expect(_tag(3, 'Mark the answer'), findsOneWidget);
    expect(_counts(t), '3 need you, 1 ready');

    await t.ensureVisible(_option(3, 'C'));
    await t.tap(_option(3, 'C'));
    await t.pump(); // the tap has been made; the server has not answered yet
    expect(_counts(t), '2 need you, 2 ready', reason: 'marked before the server has answered');
    await _wait(t);
    expect(_s.patches, [
      {'id': 'd3', 'correct_option': 2},
    ]);
    expect(_counts(t), '2 need you, 2 ready');
    sem.dispose();
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('"Use B" under a split question marks B', (t) async {
    final sem = t.ensureSemantics();
    await _open(t);
    expect(_tag(2, 'AI is split'), findsOneWidget);
    final use = find.descendant(of: _card(2), matching: find.bySemanticsLabel('Use B'));
    expect(use, findsOneWidget);
    await t.ensureVisible(use);
    await t.tap(use);
    await _wait(t);
    expect(_s.patches, [
      {'id': 'd2', 'correct_option': 1},
    ]);
    expect(_counts(t), '2 need you, 2 ready');
    sem.dispose();
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a question waiting for a second opinion can be marked by hand meanwhile', (t) async {
    final sem = t.ensureSemantics();
    await _open(t);
    expect(_tag(4, 'Second look'), findsOneWidget);
    await t.ensureVisible(_option(4, 'D'));
    await t.tap(_option(4, 'D'));
    await _wait(t);
    expect(_s.patches.single['correct_option'], 3);
    expect(_counts(t), '2 need you, 2 ready');
    sem.dispose();
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a save that fails puts the mark back and says so', (t) async {
    final sem = t.ensureSemantics();
    await _open(t);
    _s.failPatch = true;
    await t.ensureVisible(_option(3, 'C'));
    await t.tap(_option(3, 'C'));
    await _wait(t);
    expect(_counts(t), '3 need you, 1 ready', reason: 'the server did not take it');
    expect(_tag(3, 'Mark the answer'), findsOneWidget);
    expect(find.textContaining('busy'), findsWidgets, reason: 'the tutor is told');
    sem.dispose();
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the paper loading again while the tap is on its way does not undo the mark', (t) async {
    final sem = t.ensureSemantics();
    // Nothing waits for a second opinion here, so the screen has no work of its own that would load the paper again.
    _s = _Server(_paper().take(3).toList());
    await _open(t);
    // Back from another app: the screen looks at the paper again. The server takes its picture of the paper now (before the tap)
    // and the reply is slow.
    final before = _s.gets;
    final slowGet = Completer<void>();
    _s.getGate = slowGet;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(_s.gets, greaterThan(before), reason: 'the screen looked at the paper again');

    await t.ensureVisible(_option(3, 'C'));
    await t.tap(_option(3, 'C'));
    await _wait(t);
    expect(_s.patches.length, 1);
    expect(_counts(t), '1 need you, 2 ready', reason: 'the server has it');

    // The slow picture of the paper arrives, taken before the tap: it must not put the question back to unanswered.
    slowGet.complete();
    // Two frames: the old picture is in, and nothing has had time to ask for a newer one.
    await t.pump();
    await t.pump();
    expect(_counts(t), '1 need you, 2 ready', reason: 'an older picture of the paper arrived after the tap');
    expect(_s.drafts[2]['correct_option'], 2, reason: 'and the server still has the mark');
    sem.dispose();
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the paper loading again while the save is under way does not flicker the mark off', (t) async {
    final sem = t.ensureSemantics();
    _s = _Server(_paper().take(3).toList());
    await _open(t);
    final slowPatch = Completer<void>();
    _s.patchGate = slowPatch;
    await t.ensureVisible(_option(3, 'C'));
    await t.tap(_option(3, 'C'));
    await t.pump();
    expect(_counts(t), '1 need you, 2 ready');

    // While the save is on its way the screen looks at the paper again; the server has not applied the mark yet.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _wait(t, 400);
    expect(_counts(t), '1 need you, 2 ready', reason: 'the paper as it was before the save came back and replaced the tutor\'s mark');

    slowPatch.complete();
    await _wait(t);
    expect(_counts(t), '1 need you, 2 ready');
    sem.dispose();
    await t.pumpWidget(const SizedBox.shrink());
  });
}
