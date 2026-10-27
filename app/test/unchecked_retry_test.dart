// When the AI models are down, a question is left "Not checked yet" and the paper asks again by itself once the server's cooldown is
// over, a few times, as long as the screen stays open; the tutor is not left marking by hand. The review screen is the real one,
// against a stub server that gives up on a batch when the models are down, and keeps those questions cooling until a call is allowed
// to try them again.
//   flutter test test/unchecked_retry_test.dart
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

const _answers = 'POST /teacher/papers/p1/answers';

Map<String, dynamic> _draft(int n, String text, {int? correct, bool checked = true, String? note}) => {
      'id': 'd$n', 'paper_id': 'p1', 'page_no': 1, 'seq': n, 'number_label': '$n', 'kind': 'mcq', 'status': 'draft', 'text': text,
      'options': ['2', '3', '4', '5'], 'correct_option': correct, 'answer_source': correct == null ? null : 'ai', 'ai_confidence': correct == null ? null : 0.98,
      'ai_note': note, 'ai_picks': null, 'ai_votes': null, 'proposed_option': null, 'answer_checked': checked, 'needs_diagram': false, 'image_key': null,
      'image_url': null, 'chapter': null, 'chapter_id': null, 'ai_chapter_guess': null, 'edited': false,
    };

/// The server's side of one paper AI wrote, remembered between calls.
class _Server {
  _Server(this.drafts);

  final List<Map<String, dynamic>> drafts;

  /// Whether the models answer. When they do not, a batch is given up on and its questions are left "unchecked".
  bool down = true;

  /// Whether the server's cooldown on the unchecked questions is over, so a call may take them again.
  bool cooled = false;

  /// How many batches were given up on.
  int gaveUp = 0;

  final calls = <String>[];

  int count(String call) => calls.where((c) => c == call).length;

  http.Response _ok(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    final call = '${r.method} ${r.url.path}';
    calls.add(call);
    switch (call) {
      case 'GET /teacher/papers/p1':
        return _ok({
          'paper': {
            'id': 'p1', 'class_level': 9, 'exam_name': 'Algebra, one day', 'category': 'Made with AI', 'subject': 'Maths', 'subject_id': 'sub-0',
            'chapter': null, 'chapter_id': null, 'course_id': null, 'ai_details': {'ok': true}, 'page_count': 0, 'missing': <String>[], 'replaceable': false,
          },
          'pages': <Object?>[],
          'drafts': drafts,
          'chapters': <Object?>[],
          'questions': <Object?>[],
          'tests': <Object?>[],
        });
      case _answers:
        final todo = drafts
            .where((d) =>
                d['status'] == 'draft' &&
                d['kind'] == 'mcq' &&
                d['correct_option'] == null &&
                (d['answer_checked'] != true || (d['ai_note'] == 'unchecked' && cooled)))
            .toList();
        if (todo.isEmpty) return _ok({'from_key': 0, 'by_ai': 0, 'tried': 0, 'left': 0, 'second': 0});
        if (down) {
          gaveUp++;
          for (final d in todo) {
            d['answer_checked'] = true;
            d['ai_note'] = 'unchecked';
          }
          cooled = false;
          return _ok({'from_key': 0, 'by_ai': 0, 'tried': todo.length, 'left': 0, 'second': 0});
        }
        for (final d in todo) {
          d['answer_checked'] = true;
          d['ai_note'] = null;
          d['correct_option'] = 1;
          d['answer_source'] = 'ai';
          d['ai_confidence'] = 0.97;
        }
        return _ok({'from_key': 0, 'by_ai': todo.length, 'tried': todo.length, 'left': 0, 'second': 0});
      case 'POST /teacher/papers/p1/second-opinion':
        return _ok({'by_ai': 0, 'tried': 0, 'asked': 0, 'left': 0});
    }
    return _ok({'error': {'code': 'not_found', 'message': 'No stub for $call'}}, 404);
  }
}

late _Server _s;

Future<void> _wait(WidgetTester t, Duration d) async {
  for (var left = d.inMilliseconds; left > 0; left -= 500) {
    await t.pump(const Duration(milliseconds: 500));
  }
}

/// The count on a tab of the review ("Ready 3"), and whether it is the one showing.
int _tab(WidgetTester t, String label) => t.widget<SegChip>(find.widgetWithText(SegChip, label)).count!;

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
    http.runWithClient(() => api.token = 'test', () => MockClient((r) => _s.handle(r)));
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
    session.tuitionName = 'Priya Maths Classes';
  });

  /// Three questions: one settled, one the models never got to, and one they gave up on last time.
  setUp(() => _s = _Server([
        _draft(1, 'What is 1 + 1?', correct: 0),
        _draft(2, 'What is 2 + 2?', checked: false),
        _draft(3, 'What is 3 + 3?', note: 'unchecked'),
      ]));

  testWidgets('questions the models could not check are asked about again by themselves, after the cooldown', (t) async {
    await _open(t);
    await _wait(t, const Duration(seconds: 3));

    // The models are down: the batch was given up on, and the two questions say so instead of waiting for the tutor to tap.
    expect(_s.gaveUp, 1);
    expect(find.text('Not checked yet'), findsNWidgets(2));
    expect(_tab(t, 'Needs you'), 2);
    expect(_tab(t, 'Ready'), 1);
    final before = _s.count(_answers);

    // Before the cooldown is over nothing is asked again.
    await _wait(t, const Duration(minutes: 3));
    expect(_s.count(_answers), before, reason: 'the server keeps them cooling for three minutes, so the paper waits too');

    // The models are back, and the cooldown is over: the paper asks again on its own and the answers are found.
    _s.down = false;
    _s.cooled = true;
    await _wait(t, const Duration(seconds: 30));
    expect(_s.count(_answers), greaterThan(before), reason: 'the paper asked again without anybody tapping');
    expect(find.text('Not checked yet'), findsNothing);
    expect(_tab(t, 'Needs you'), 0);
    expect(_tab(t, 'Ready'), 3);
    final settled = _s.count(_answers);

    // Nothing is left, so nothing is asked again.
    await _wait(t, const Duration(minutes: 10));
    expect(_s.count(_answers), settled);
    await _close(t);
  });

  testWidgets('models that stay down are tried a few times and then left, not for ever', (t) async {
    await _open(t);
    await _wait(t, const Duration(seconds: 3));
    expect(_s.gaveUp, 1);

    // Every time the cooldown is over the models are still down.
    for (var i = 0; i < 12; i++) {
      _s.cooled = true;
      await _wait(t, const Duration(minutes: 3, seconds: 30));
    }
    expect(_s.gaveUp, 6, reason: 'the first run and five more, then the paper waits until it is opened again');
    expect(find.text('Not checked yet'), findsNWidgets(2), reason: 'the tutor still sees what AI could not check');
    await _close(t);
  });

  testWidgets('a screen that is closed asks about nothing', (t) async {
    await _open(t);
    await _wait(t, const Duration(seconds: 3));
    expect(_s.gaveUp, 1);
    final before = _s.count(_answers);
    await _close(t);
    _s.cooled = true;
    await _wait(t, const Duration(minutes: 20));
    expect(_s.count(_answers), before, reason: 'nobody is looking, so no models are asked');
  });
}
